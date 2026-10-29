import '../models/transaction.dart';
import '../utils/category_guesser.dart';
import '../utils/source_role.dart';
import 'app_state.dart';
import 'database.dart';
import 'notification_listener.dart';

/// 把 Android 支付通知解析结果落库为自动账单。
class PaymentService {
  static final PaymentService instance = PaymentService._();
  PaymentService._();

  /// 同来源判重时间窗。同一笔通知可能被系统重复推送，短时间内只记一条。
  static const Duration dedupeWindow = Duration(minutes: 10);

  /// 跨来源判重时间窗（支付平台通知 ↔ 银行通知）。
  ///
  /// 比同来源窗口短，因为跨来源合并的风险更高：
  /// 万一用户真的在两分钟里用两个渠道付了同价的两笔钱，
  /// 窗口越宽越容易把两笔真交易并成一笔。
  ///
  /// 5 分钟是权衡：银行短信通常在扣款后几秒内到达，
  /// 银行 App 的推送通知一般也在一两分钟内。
  ///
  /// **后来放宽到 10 分钟**：银行 App 的推送经常延迟，
  /// 用户反馈「微信那条和银行那条金额一样、时间也就差个七八分钟，
  /// 结果还是记了两笔」。而判重条件里除了时间窗，
  /// 现在还要求「支付平台 ↔ 银行」或者「同一家银行」——
  /// 身份判据变强了，时间窗就可以放宽一点换回召回。
  static const Duration crossSourceWindow = Duration(minutes: 10);

  /// 金额比较容差。分与厘的进位差异不该被当成两笔。
  static const double amountTolerance = 0.005;

  /// 是否开启「支付平台 + 银行通知」跨来源自动去重。
  ///
  /// 默认开启（用户明确反馈过重复账单）。
  /// 用户如果觉得误合并了，可以在设置里关掉。
  ///
  /// 这是内存副本，真正的值存在数据库里（见 [crossSourceSettingKey]），
  /// 启动时由 [loadSettings] 读进来。
  static bool crossSourceEnabled = true;

  /// 「跨来源自动去重」开关在数据库里的键。
  static const String crossSourceSettingKey = 'cross_source_dedupe';

  /// 从数据库把设置读进内存。
  ///
  /// 必须持久化：这个开关之前只存在静态变量里，
  /// 重启 App 就恢复默认值了——用户在设置里明明关掉了，重新打开又开着。
  static Future<void> loadSettings() async {
    crossSourceEnabled = await DatabaseHelper.instance.getBoolSetting(
      crossSourceSettingKey,
      defaultValue: true,
    );
  }

  /// 改开关并写回数据库。
  static Future<void> setCrossSourceEnabled(bool value) async {
    crossSourceEnabled = value;
    await DatabaseHelper.instance.setBoolSetting(crossSourceSettingKey, value);
  }

  /// 判断一条已存在的自动账单是否就是本次通知的同一笔。
  ///
  /// 必须比较**双边**时间差。原来只在 SQL 里设了下界 `date >= window`，
  /// 结果「12:00 的那笔已入库、11:40 的缓存补记到达」这种乱序场景会被误判为重复
  /// 而丢掉——而缓存补发恰恰是乱序的。
  static bool isSamePaymentEvent({
    required Transaction existing,
    required double eventAmount,
    required DateTime eventTime,
  }) {
    if ((existing.amount - eventAmount).abs() >= amountTolerance) return false;
    return existing.date.difference(eventTime).abs() <= dedupeWindow;
  }

  /// 判断两条记录是不是同一笔钱（跨来源场景）。
  ///
  /// 来源要能配成同一笔，满足其一即可：
  /// 1. **支付平台 ↔ 银行**（原有的规则）；
  /// 2. **同一家银行**（新增，见 [isSamePaymentPair]）。
  ///
  /// 第 2 条是为了堵住原先漏掉的一类重复：
  /// 用户装的银行 App 不在包名表里（信用卡 App、地方银行、数字银行…），
  /// 它的通知被判成「其它」，于是「微信 + 银行 App」配不上，
  /// 同一笔扣费被记成两笔。现在从通知正文里认出银行名，
  /// 两边认得出同一家银行就能合并。
  ///
  /// 其它组合一律返回 false——宁可漏合并，也不把两笔真交易并掉。
  static bool isSameCrossSourceEvent({
    required Transaction existing,
    required double eventAmount,
    required DateTime eventTime,
    required String eventType,
    required SourceRole existingRole,
    required SourceRole eventRole,
    String? existingBankId,
    String? eventBankId,
  }) {
    final pairable = isCrossSourcePair(existingRole, eventRole) ||
        (existingBankId != null && existingBankId == eventBankId);
    if (!pairable) return false;
    if ((existing.amount - eventAmount).abs() >= amountTolerance) return false;
    // 方向必须一致：同一笔不可能既是支出又是收入。
    if (existing.type != eventType) return false;
    return existing.date.difference(eventTime).abs() <= crossSourceWindow;
  }

  /// 判断一条新通知是不是已经记过了。
  ///
  /// 抽成纯函数是为了能完整单测：
  /// 真正跑一遍 `handleEvent` 需要数据库，
  /// 而「同来源 / 跨来源 / 角色配对 / 时间窗」这四件事的组合很多，
  /// 光靠数据库集成测试覆盖不全。
  ///
  /// @param candidates 时间窗内、方向相同的自动账单候选。
  /// @param event 新到的通知。
  /// @param eventTime 通知的实际发生时间。
  /// @return 命中的那条重复记录；null 表示这是一笔新交易。
  static Transaction? findDuplicate({
    required List<Transaction> candidates,
    required PaymentEvent event,
    required DateTime eventTime,
  }) {
    final eventIdentity =
        identityOf(packageName: event.sourceApp, content: event.content);
    for (final existing in candidates) {
      // 同来源：系统把同一条通知重复推送了。
      if (existing.sourceApp == event.sourceApp) {
        if (isSamePaymentEvent(
          existing: existing,
          eventAmount: event.amount,
          eventTime: eventTime,
        )) {
          return existing;
        }
        continue;
      }

      // 跨来源：支付平台 ↔ 银行，或者同一家银行的两个渠道。
      if (!crossSourceEnabled) continue;
      final existingIdentity = identityOf(
        packageName: existing.sourceApp,
        content: existing.note ?? '',
      );
      if (isSameCrossSourceEvent(
        existing: existing,
        eventAmount: event.amount,
        eventTime: eventTime,
        eventType: event.type,
        existingRole: existingIdentity.role,
        eventRole: eventIdentity.role,
        existingBankId: existingIdentity.bankId,
        eventBankId: eventIdentity.bankId,
      )) {
        return existing;
      }
    }
    return null;
  }

  /// 规则：
  /// - **同来源**：[dedupeWindow] 内已存在同来源 + 同金额 + **同收支方向**的自动账单
  ///   -> 跳过（系统重复推送同一笔）
  /// - **跨来源**：支付平台通知与银行通知说的是同一笔钱，
  ///   [crossSourceWindow] 内已存在同金额 + 同方向的自动账单 -> 跳过
  /// - 用户手动编辑过的记录保持原样，不会被后续通知覆盖
  /// - 其余情况新增一条自动账单
  ///
  /// @return true 表示真的新增了一条；false 表示判重命中，没有重复记录。
  Future<bool> handleEvent(PaymentEvent event) async {
    final db = await DatabaseHelper.instance.database;
    // 用事件自身的发生时间，而不是「现在」：
    // 原生层会缓存 App 未运行期间的通知，补记时必须还原原始日期。
    final eventTime = event.timestamp ?? DateTime.now();
    // 预筛用较大的窗口（下界更早），跨来源的候选才不会被漏掉。
    final window = eventTime.subtract(dedupeWindow).toIso8601String();

    // SQL 只用下界做索引预筛，真正的双边判断交给 findDuplicate。
    //
    // 注意这里**不能**加 `sourceApp = ?`：
    // 旧实现加了它，结果微信通知和银行通知永远互相看不见，
    // 同一笔扣费被记成两笔——这正是用户反馈的重复账单。
    final rows = await db.query(
      'transactions',
      where: 'isAuto = 1 AND type = ? AND date >= ?',
      whereArgs: [event.type, window],
    );
    final candidates =
        rows.map((row) => Transaction.fromMap(row as Map<String, dynamic>)).toList();

    if (findDuplicate(
      candidates: candidates,
      event: event,
      eventTime: eventTime,
    ) !=
        null) {
      return false;
    }

    final tx = Transaction(
      amount: event.amount,
      type: event.type,
      category: _guessCategory(event),
      note: event.content,
      date: eventTime,
      isAuto: true,
      isEdited: false,
      sourceApp: event.sourceApp,
    );
    await DatabaseHelper.instance.insertTransaction(tx);
    AppState.instance.bump();
    return true;
  }

  String _guessCategory(PaymentEvent event) {
    // 与账单导入共用同一套规则表（lib/utils/category_guesser.dart）。
    return guessCategory(event.content);
  }

  /// 扫描库里已经存在的账单，找出跨来源的重复（支付平台 + 银行各记了一笔）。
  ///
  /// 用户反馈「总是有重复账单」时，已经记进去的那些也得能清理。
  ///
  /// 判定沿用入库时的规则，保守优先：
  /// - 两条都是自动记录（手动记的绝不动）
  /// - 用户编辑过的记录不参与合并（用户可能已经手动整理过）
  /// - 金额相同、方向相同、时间差在 [crossSourceWindow] 内
  /// - 来源能配成同一笔：支付平台 ↔ 银行，**或者同一家银行**
  ///
  /// 最后一条用的是和入库同一套身份判据，
  /// 所以「微信 + 认不出来的银行 App」这类新覆盖到的重复，
  /// 历史数据也能一起清掉。
  ///
  /// @return 可以删除的重复记录 id 列表（每组重复只保留最早的一条）。
  static Future<List<int>> findCrossSourceDuplicates() async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'transactions',
      where: 'isAuto = 1 AND isEdited = 0',
      orderBy: 'date ASC',
    );
    final list = rows.map((r) => Transaction.fromMap(r as Map<String, dynamic>)).toList();

    final removable = <int>[];
    final kept = <Transaction>[];
    for (final t in list) {
      final identity = identityOf(packageName: t.sourceApp, content: t.note ?? '');
      final dup = kept.any((k) {
        final kIdentity =
            identityOf(packageName: k.sourceApp, content: k.note ?? '');
        return isSameCrossSourceEvent(
          existing: k,
          eventAmount: t.amount,
          eventTime: t.date,
          eventType: t.type,
          existingRole: kIdentity.role,
          eventRole: identity.role,
          existingBankId: kIdentity.bankId,
          eventBankId: identity.bankId,
        );
      });
      if (dup) {
        if (t.id != null) removable.add(t.id!);
      } else {
        kept.add(t);
      }
    }
    return removable;
  }

  /// 清理跨来源重复账单。
  ///
  /// @return 删掉的条数。
  static Future<int> cleanupCrossSourceDuplicates() async {
    final ids = await findCrossSourceDuplicates();
    if (ids.isEmpty) return 0;
    final db = await DatabaseHelper.instance.database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.delete('transactions', where: 'id IN ($placeholders)', whereArgs: ids);
    AppState.instance.bump();
    return ids.length;
  }
}

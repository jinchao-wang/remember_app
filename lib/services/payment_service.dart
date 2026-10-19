import '../models/transaction.dart';
import 'app_state.dart';
import 'database.dart';
import 'notification_listener.dart';

/// 把 Android 支付通知解析结果落库为自动账单。
class PaymentService {
  static final PaymentService instance = PaymentService._();
  PaymentService._();

  /// 判重时间窗。同一笔通知可能被系统重复推送，短时间内只记一条。
  static const Duration dedupeWindow = Duration(minutes: 10);

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
    if ((existing.amount - eventAmount).abs() >= 0.005) return false;
    return existing.date.difference(eventTime).abs() <= dedupeWindow;
  }

  /// 规则：
  /// - [dedupeWindow] 内已存在同来源 + 同金额 + **同收支方向**的自动账单 -> 跳过
  /// - 用户手动编辑过的记录保持原样，不会被后续通知覆盖
  /// - 其余情况新增一条自动账单
  Future<void> handleEvent(PaymentEvent event) async {
    final db = await DatabaseHelper.instance.database;
    // 用事件自身的发生时间，而不是「现在」：
    // 原生层会缓存 App 未运行期间的通知，补记时必须还原原始日期。
    final eventTime = event.timestamp ?? DateTime.now();
    final window = eventTime.subtract(dedupeWindow).toIso8601String();

    // SQL 只用下界做索引预筛，真正的双边判断交给 isSamePaymentEvent。
    final rows = await db.query(
      'transactions',
      where: 'isAuto = 1 AND sourceApp = ? AND type = ? AND date >= ?',
      whereArgs: [event.sourceApp, event.type, window],
    );
    for (final row in rows) {
      final existing = Transaction.fromMap(row);
      if (isSamePaymentEvent(
        existing: existing,
        eventAmount: event.amount,
        eventTime: eventTime,
      )) {
        return;
      }
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
  }

  String _guessCategory(PaymentEvent event) {
    final text = event.content;
    const rules = <String, List<String>>{
      '餐饮': ['美团', '饿了么', '外卖', '餐厅', '饭店', '肯德基', '麦当劳', '瑞幸', '星巴克', '奶茶', '咖啡'],
      '交通': ['滴滴', '高德', '打车', '出租', '加油', '充电', '停车', '地铁', '公交', '12306', '铁路'],
      '购物': ['淘宝', '天猫', '京东', '拼多多', '抖音', '快手', '商城', '购物', '快递', '下单'],
      '日用': ['超市', '便利店', '水果', '买菜', '永辉', '大润发', '沃尔玛'],
      '娱乐': ['电影', '游戏', '视频', '音乐', '会员', '充值', '直播'],
      '转账': ['微信', '支付宝', '转账', '红包', '还款', '收款', '到账', '银行'],
    };
    for (final entry in rules.entries) {
      if (entry.value.any(text.contains)) return entry.key;
    }
    return '其他';
  }
}
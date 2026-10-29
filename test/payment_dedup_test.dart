import 'package:flutter_test/flutter_test.dart';
import 'package:remember_app/models/transaction.dart';
import 'package:remember_app/services/notification_listener.dart';
import 'package:remember_app/services/payment_service.dart';
import 'package:remember_app/utils/source_role.dart';

Transaction _auto({
  double amount = 12.5,
  DateTime? date,
  String type = 'expense',
}) =>
    Transaction(
      amount: amount,
      type: type,
      category: '餐饮',
      date: date ?? DateTime(2026, 10, 19, 12, 0),
      isAuto: true,
    );

void main() {
  final base = DateTime(2026, 10, 19, 12, 0);

  bool same(Transaction existing, double amount, DateTime at) =>
      PaymentService.isSamePaymentEvent(
        existing: existing,
        eventAmount: amount,
        eventTime: at,
      );

  group('isSamePaymentEvent 判重', () {
    test('同一笔通知：金额相同且时间完全一致 -> 判为重复', () {
      expect(same(_auto(date: base), 12.5, base), isTrue);
    });

    test('同一笔通知被重复推送（3 分钟后）-> 判为重复', () {
      expect(
        same(_auto(date: base), 12.5, base.add(const Duration(minutes: 3))),
        isTrue,
      );
    });

    test('窗口边界：正好 10 分钟 -> 判为重复', () {
      expect(
        same(_auto(date: base), 12.5, base.add(const Duration(minutes: 10))),
        isTrue,
      );
    });

    test('超过窗口：11 分钟 -> 视为新交易', () {
      expect(
        same(_auto(date: base), 12.5, base.add(const Duration(minutes: 11))),
        isFalse,
      );
    });

    // 这是修复前的真实缺陷：SQL 只设了 date >= window 下界，没有上界。
    // 缓存补发的到达顺序不可控，于是「12:00 已入库、11:40 的补记后到」
    // 会被误判成重复而整条丢弃。
    test('乱序到达：较早的补记不应被较晚的记录吞掉', () {
      // 库里已有 12:00 那笔，现在补记 11:40 的同额消费。
      expect(
        same(_auto(date: base), 12.5, base.subtract(const Duration(minutes: 20))),
        isFalse,
        reason: '补记时间与已有记录相差 20 分钟，必须算作独立的一笔',
      );
    });

    test('乱序到达：较晚的记录也不应吞掉较早已入库的', () {
      expect(
        same(_auto(date: base), 12.5, base.add(const Duration(minutes: 20))),
        isFalse,
      );
    });

    test('金额不同 -> 不判重', () {
      expect(same(_auto(date: base), 13.0, base), isFalse);
    });

    test('金额差在容差内（0.004）-> 判为重复', () {
      expect(same(_auto(amount: 12.5, date: base), 12.504, base), isTrue);
    });

    test('金额差超出容差（0.006）-> 不判重', () {
      expect(same(_auto(amount: 12.5, date: base), 12.506, base), isFalse);
    });

    test('窗口对称性：前后各 6 分钟都算重复', () {
      expect(same(_auto(date: base), 12.5, base.subtract(const Duration(minutes: 6))), isTrue);
      expect(same(_auto(date: base), 12.5, base.add(const Duration(minutes: 6))), isTrue);
    });
  });

  group('dedupeWindow', () {
    test('固定为 10 分钟', () {
      expect(PaymentService.dedupeWindow, const Duration(minutes: 10));
    });
  });

  group('跨来源判重（微信通知 + 银行通知）', () {
    Transaction autoFrom({
      required String packageName,
      required String content,
      double amount = 31.31,
      String type = 'expense',
      DateTime? date,
    }) =>
        Transaction(
          amount: amount,
          type: type,
          category: '转账',
          date: date ?? base,
          isAuto: true,
          sourceApp: packageName,
          note: content,
        );

    bool cross(Transaction existing, {
      required double amount,
      required DateTime at,
      required String eventType,
      required SourceRole existingRole,
      required SourceRole eventRole,
    }) =>
        PaymentService.isSameCrossSourceEvent(
          existing: existing,
          eventAmount: amount,
          eventTime: at,
          eventType: eventType,
          existingRole: existingRole,
          eventRole: eventRole,
        );

    test('微信通知 + 银行短信，同额同向且相隔 40 秒 -> 判为重复', () {
      // 用户报的真实场景：微信绑了卡，扣费时两个 App 都发了通知。
      final wechat = autoFrom(
        packageName: 'com.tencent.mm',
        content: '微信支付 付款成功 ¥31.31',
      );
      final bank = autoFrom(
        packageName: 'com.android.mms',
        content: '【招商银行】您尾号8888的储蓄卡于10月20日消费支出人民币31.31元',
      );

      expect(
        cross(
          wechat,
          amount: 31.31,
          at: base.add(const Duration(seconds: 40)),
          eventType: 'expense',
          existingRole: roleOf(
            packageName: 'com.tencent.mm',
            content: '微信支付 付款成功 ¥31.31',
          ),
          eventRole: roleOf(
            packageName: 'com.android.mms',
            content: bank.note!,
          ),
        ),
        isTrue,
      );
    });

    test('超过跨来源窗口（12 分钟）-> 不判重', () {
      final wechat = autoFrom(packageName: 'com.tencent.mm', content: '微信支付 付款成功 ¥31.31');
      expect(
        cross(
          wechat,
          amount: 31.31,
          at: base.add(const Duration(minutes: 12)),
          eventType: 'expense',
          existingRole: SourceRole.platform,
          eventRole: SourceRole.bank,
        ),
        isFalse,
      );
    });

    test('方向不一致（支出 vs 收入）-> 不判重', () {
      final wechat = autoFrom(packageName: 'com.tencent.mm', content: '微信支付 付款成功 ¥31.31');
      expect(
        cross(
          wechat,
          amount: 31.31,
          at: base,
          eventType: 'income',
          existingRole: SourceRole.platform,
          eventRole: SourceRole.bank,
        ),
        isFalse,
      );
    });

    test('金额不同 -> 不判重', () {
      final wechat = autoFrom(packageName: 'com.tencent.mm', content: '微信支付 付款成功 ¥31.31');
      expect(
        cross(
          wechat,
          amount: 99.99,
          at: base,
          eventType: 'expense',
          existingRole: SourceRole.platform,
          eventRole: SourceRole.bank,
        ),
        isFalse,
      );
    });

    test('两个陌生 App 之间 -> 不判重', () {
      final other = autoFrom(packageName: 'com.unknown.app', content: '扣款 31.31');
      expect(
        cross(
          other,
          amount: 31.31,
          at: base,
          eventType: 'expense',
          existingRole: SourceRole.other,
          eventRole: SourceRole.bank,
        ),
        isFalse,
      );
    });

    test('平台 ↔ 平台 -> 不判重（不是银行配对）', () {
      final wechat = autoFrom(packageName: 'com.tencent.mm', content: '微信支付 付款成功 ¥31.31');
      expect(
        cross(
          wechat,
          amount: 31.31,
          at: base,
          eventType: 'expense',
          existingRole: SourceRole.platform,
          eventRole: SourceRole.platform,
        ),
        isFalse,
      );
    });
  });

  group('来源角色识别', () {
    test('微信、支付宝 -> platform', () {
      expect(roleOf(packageName: 'com.tencent.mm', content: ''), SourceRole.platform);
      expect(
        roleOf(packageName: 'com.eg.android.AlipayGphone', content: ''),
        SourceRole.platform,
      );
    });
    test('银行 App -> bank', () {
      expect(roleOf(packageName: 'com.icbc', content: ''), SourceRole.bank);
      expect(roleOf(packageName: 'com.cmbchina', content: ''), SourceRole.bank);
    });

    test('短信 App + 银行特征 -> bank', () {
      expect(
        roleOf(
          packageName: 'com.android.mms',
          content: '您尾号8888的储蓄卡于10月20日消费支出人民币31.31元',
        ),
        SourceRole.bank,
      );
    });

    test('短信 App + 非银行内容 -> other', () {
      expect(
        roleOf(packageName: 'com.android.mms', content: '【验证码】您的验证码是123456'),
        SourceRole.other,
      );
    });

    test('微信支付通知里提到「信用卡」也不能被当成银行', () {
      // 这是必须靠包名判断的原因：微信通知正文可能写「使用招行信用卡支付」，
      // 靠关键词会把支付平台通知误判成银行通知。
      expect(
        roleOf(
          packageName: 'com.tencent.mm',
          content: '你于2026年10月20日,使用招商银行(1234)信用卡支付31.31元',
        ),
        SourceRole.platform,
      );
    });

    test('未知包名 -> other', () {
      expect(roleOf(packageName: 'com.unknown.app', content: '扣款'), SourceRole.other);
      expect(roleOf(packageName: null, content: '扣款'), SourceRole.other);
    });
  });

  group('findDuplicate 整条判重链路', () {
    final base = DateTime(2026, 10, 19, 12, 0);

    Transaction record({
      required String packageName,
      required String content,
      double amount = 31.31,
      String type = 'expense',
      DateTime? date,
    }) =>
        Transaction(
          amount: amount,
          type: type,
          category: '转账',
          date: date ?? base,
          isAuto: true,
          sourceApp: packageName,
          note: content,
        );

    PaymentEvent event({
      required String packageName,
      required String content,
      double amount = 31.31,
      String type = 'expense',
      DateTime? date,
    }) =>
        PaymentEvent(
          amount: amount,
          type: type,
          sourceApp: packageName,
          content: content,
          timestamp: date ?? base,
        );

    const wechatContent = '微信支付 付款成功 ¥31.31';
    const bankContent = '您尾号8888的储蓄卡于10月20日消费支出人民币31.31元';

    test('库里已有微信那条，来了银行短信 -> 判为重复', () {
      final dup = PaymentService.findDuplicate(
        candidates: [record(packageName: 'com.tencent.mm', content: wechatContent)],
        event: event(packageName: 'com.android.mms', content: bankContent),
        eventTime: base.add(const Duration(seconds: 40)),
      );
      expect(dup, isNotNull);
      expect(dup!.sourceApp, 'com.tencent.mm');
    });

    test('库里已有银行那条，来了微信通知 -> 判为重复（顺序反过来也一样）', () {
      final dup = PaymentService.findDuplicate(
        candidates: [record(packageName: 'com.android.mms', content: bankContent)],
        event: event(packageName: 'com.tencent.mm', content: wechatContent),
        eventTime: base.add(const Duration(seconds: 20)),
      );
      expect(dup, isNotNull);
    });

    test('同来源重复推送 -> 判为重复', () {
      final dup = PaymentService.findDuplicate(
        candidates: [record(packageName: 'com.tencent.mm', content: wechatContent)],
        event: event(packageName: 'com.tencent.mm', content: wechatContent),
        eventTime: base.add(const Duration(minutes: 2)),
      );
      expect(dup, isNotNull);
    });

    test('金额不同 -> 不是重复', () {
      final dup = PaymentService.findDuplicate(
        candidates: [record(packageName: 'com.tencent.mm', content: wechatContent)],
        event: event(
          packageName: 'com.android.mms',
          content: bankContent,
          amount: 88.88,
        ),
        eventTime: base,
      );
      expect(dup, isNull);
    });

    test('隔太久（超过 10 分钟）-> 不是重复', () {
      // 跨来源窗口从 5 分钟放宽到 10 分钟：
      // 银行 App 的推送经常延迟，用户反馈过「差个七八分钟还是记了两笔」。
      final dup = PaymentService.findDuplicate(
        candidates: [record(packageName: 'com.tencent.mm', content: wechatContent)],
        event: event(packageName: 'com.android.mms', content: bankContent),
        eventTime: base.add(const Duration(minutes: 12)),
      );
      expect(dup, isNull);
    });

    test('差 8 分钟 -> 算同一笔（窗口放宽到 10 分钟）', () {
      final dup = PaymentService.findDuplicate(
        candidates: [record(packageName: 'com.tencent.mm', content: wechatContent)],
        event: event(packageName: 'com.android.mms', content: bankContent),
        eventTime: base.add(const Duration(minutes: 8)),
      );
      expect(dup, isNotNull);
    });

    test('方向不一致 -> 不是重复', () {
      final dup = PaymentService.findDuplicate(
        candidates: [record(packageName: 'com.tencent.mm', content: wechatContent)],
        event: event(
          packageName: 'com.android.mms',
          content: '您尾号8888的储蓄卡于10月20日入账人民币31.31元',
          type: 'income',
        ),
        eventTime: base,
      );
      expect(dup, isNull);
    });

    test('两个陌生 App 之间 -> 不是重复', () {
      final dup = PaymentService.findDuplicate(
        candidates: [record(packageName: 'com.unknown.app', content: '扣款 31.31')],
        event: event(packageName: 'com.android.mms', content: bankContent),
        eventTime: base,
      );
      expect(dup, isNull);
    });

    test('关掉跨来源去重后 -> 平台与银行不再判重', () {
      PaymentService.crossSourceEnabled = false;
      addTearDown(() => PaymentService.crossSourceEnabled = true);

      final dup = PaymentService.findDuplicate(
        candidates: [record(packageName: 'com.tencent.mm', content: wechatContent)],
        event: event(packageName: 'com.android.mms', content: bankContent),
        eventTime: base.add(const Duration(seconds: 40)),
      );
      expect(dup, isNull);
    });

    test('同来源的判重不受跨来源开关影响', () {
      PaymentService.crossSourceEnabled = false;
      addTearDown(() => PaymentService.crossSourceEnabled = true);

      final dup = PaymentService.findDuplicate(
        candidates: [record(packageName: 'com.tencent.mm', content: wechatContent)],
        event: event(packageName: 'com.tencent.mm', content: wechatContent),
        eventTime: base.add(const Duration(minutes: 2)),
      );
      expect(dup, isNotNull);
    });

    test('银行 App 通知 + 微信通知 -> 也是同一笔', () {
      final dup = PaymentService.findDuplicate(
        candidates: [
          record(
            packageName: 'com.icbc',
            content: '您尾号8888的账户于10月20日消费支出人民币31.31元',
          ),
        ],
        event: event(packageName: 'com.tencent.mm', content: wechatContent),
        eventTime: base.add(const Duration(minutes: 1)),
      );
      expect(dup, isNotNull);
    });

    // ------------------------------------------- 用户反馈的「依旧重复」

    test('银行 App 不在包名表里，但正文写了银行名 -> 也能判为重复', () {
      // 这正是用户报的「微信一条、银行一条，金额一样、时间差几分钟，还是记了两笔」。
      // 根因：信用卡 App / 地方银行 / 数字银行的包名不在那 18 家里，
      // 它的通知被判成「其它」，于是「平台 ↔ 银行」配不上。
      final dup = PaymentService.findDuplicate(
        candidates: [
          record(
            packageName: 'com.cmb.creditcard',
            content: '招商银行 · 您尾号1234信用卡于10月20日消费支出人民币31.31元',
          ),
        ],
        event: event(
          packageName: 'com.tencent.mm',
          content: '微信支付 你于2026年10月20日使用招商银行(1234)信用卡支付31.31元',
        ),
        eventTime: base.add(const Duration(minutes: 2)),
      );
      expect(dup, isNotNull);
      expect(dup!.sourceApp, 'com.cmb.creditcard');
    });

    test('银行 App + 银行短信（同一家）-> 判为重复', () {
      // 两边角色都是 bank，原来的「平台 ↔ 银行」配对配不上。
      final dup = PaymentService.findDuplicate(
        candidates: [
          record(
            packageName: 'com.icbc',
            content: '工商银行 · 您尾号8888信用卡消费支出人民币31.31元',
          ),
        ],
        event: event(
          packageName: 'com.android.mms',
          content: '【工商银行】您尾号8888信用卡于10月20日消费支出人民币31.31元',
        ),
        eventTime: base.add(const Duration(seconds: 45)),
      );
      expect(dup, isNotNull);
    });

    test('微信通知带银行名 + 银行短信带银行名 -> 判为重复', () {
      final dup = PaymentService.findDuplicate(
        candidates: [
          record(
            packageName: 'com.tencent.mm',
            content: '微信支付 你于2026年10月20日使用招商银行(1234)信用卡支付31.31元',
          ),
        ],
        event: event(
          packageName: 'com.android.mms',
          content: '【招商银行】您尾号1234信用卡于10月20日消费支出人民币31.31元',
        ),
        eventTime: base.add(const Duration(minutes: 3)),
      );
      expect(dup, isNotNull);
    });

    test('两家不同的银行 -> 不是重复', () {
      // 同一家银行才合并，不同银行是两笔真交易。
      final dup = PaymentService.findDuplicate(
        candidates: [
          record(
            packageName: 'com.icbc',
            content: '工商银行 · 您尾号8888信用卡消费支出人民币31.31元',
          ),
        ],
        event: event(
          packageName: 'com.android.mms',
          content: '【招商银行】您尾号1234信用卡于10月20日消费支出人民币31.31元',
        ),
        eventTime: base.add(const Duration(seconds: 30)),
      );
      expect(dup, isNull);
    });

    test('同一家银行但隔太久 -> 不是重复', () {
      final dup = PaymentService.findDuplicate(
        candidates: [
          record(
            packageName: 'com.icbc',
            content: '工商银行 · 您尾号8888信用卡消费支出人民币31.31元',
          ),
        ],
        event: event(
          packageName: 'com.android.mms',
          content: '【工商银行】您尾号8888信用卡于10月20日消费支出人民币31.31元',
        ),
        eventTime: base.add(const Duration(minutes: 30)),
      );
      expect(dup, isNull);
    });
  });

  group('来源身份识别', () {
    test('从正文里认出银行名', () {
      expect(bankIdOfContent('【招商银行】您尾号8888信用卡消费31.31元'), 'cmbchina');
      expect(bankIdOfContent('您尾号8888的建设银行储蓄卡扣款'), 'ccb');
      expect(bankIdOfContent('中国工商银行信用卡账单'), 'icbc');
      // 长名优先：「广东发展银行」不能被「银行」之类的短片段截胡。
      expect(bankIdOfContent('广东发展银行通知'), 'cgb');
      // 认不出就是 null。
      expect(bankIdOfContent('微信支付 付款成功 ¥31.31'), isNull);
      expect(bankIdOfContent(''), isNull);
    });

    test('平台通知即使正文有银行名，角色仍然是 platform', () {
      final id = identityOf(
        packageName: 'com.tencent.mm',
        content: '你于2026年10月20日使用招商银行(1234)信用卡支付31.31元',
      );
      expect(id.role, SourceRole.platform);
      // 但银行名要记下来——跨来源判重要用。
      expect(id.bankId, 'cmbchina');
    });

    test('短信里认出银行名 -> role 是 bank', () {
      final id = identityOf(
        packageName: 'com.android.mms',
        content: '【招商银行】您尾号1234信用卡于10月20日消费支出人民币31.31元',
      );
      expect(id.role, SourceRole.bank);
      expect(id.bankId, 'cmbchina');
    });

    test('认不出来的包名 + 正文有银行名 -> 也算银行', () {
      final id = identityOf(
        packageName: 'com.unknown.creditcard.app',
        content: '招商银行 · 您尾号1234信用卡消费支出人民币31.31元',
      );
      expect(id.role, SourceRole.bank);
      expect(id.bankId, 'cmbchina');
    });

    test('同一家银行的两个身份能配成同一笔', () {
      final a = identityOf(packageName: 'com.cmb.creditcard', content: '招商银行扣款31.31');
      final b = identityOf(packageName: 'com.android.mms', content: '【招商银行】扣款31.31');
      expect(isSamePaymentPair(a, b), isTrue);
    });

    test('不同银行配不成同一笔', () {
      final a = identityOf(packageName: 'com.icbc', content: '工商银行扣款');
      final b = identityOf(packageName: 'com.android.mms', content: '【招商银行】扣款');
      expect(isSamePaymentPair(a, b), isFalse);
    });

    test('两个陌生 App 配不成同一笔', () {
      final a = identityOf(packageName: 'com.unknown.a', content: '扣款');
      final b = identityOf(packageName: 'com.unknown.b', content: '扣款');
      expect(isSamePaymentPair(a, b), isFalse);
    });
  });
}

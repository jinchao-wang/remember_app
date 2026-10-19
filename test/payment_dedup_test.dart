import 'package:flutter_test/flutter_test.dart';
import 'package:remember_app/models/transaction.dart';
import 'package:remember_app/services/payment_service.dart';

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
}

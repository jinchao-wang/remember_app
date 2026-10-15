import 'package:flutter_test/flutter_test.dart';
import 'package:remember_app/services/notification_listener.dart';

void main() {
  group('原生事件 -> PaymentEvent', () {
    // 字段名必须与 MainActivity.kt 里 mapOf("amount" to ..., ...) 一致。
    // 这条契约一旦单边改动，自动记账就会静默失效。
    test('完整字段映射正确', () {
      final event = parsePaymentEvent({
        'amount': 12.5,
        'sourceApp': 'com.tencent.mm',
        'content': '微信支付 餐饮 12.50元',
        'type': 'expense',
        'timestamp': 1757900000000,
      });

      expect(event.amount, 12.5);
      expect(event.sourceApp, 'com.tencent.mm');
      expect(event.content, '微信支付 餐饮 12.50元');
      expect(event.type, 'expense');
      expect(event.timestamp, isNotNull);
      expect(event.timestamp!.millisecondsSinceEpoch, 1757900000000);
    });

    test('缓存补发事件能还原原始发生时间', () {
      // App 关闭时产生、次日打开才补记的场景
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final event = parsePaymentEvent({
        'amount': 30.0,
        'sourceApp': 'com.eg.android.AlipayGphone',
        'content': '付款成功 30.00元',
        'type': 'expense',
        'timestamp': yesterday.millisecondsSinceEpoch,
      });

      expect(event.timestamp!.toDateString(),
          yesterday.year.toString() + '-' +
              yesterday.month.toString().padLeft(2, '0') + '-' +
              yesterday.day.toString().padLeft(2, '0'));
    });

    test('缺少可选字段时使用安全默认值', () {
      final event = parsePaymentEvent({'amount': 9.9});

      expect(event.amount, 9.9);
      expect(event.type, 'expense');
      expect(event.sourceApp, '');
      expect(event.content, '');
      expect(event.timestamp, isNull);
    });

    test('amount 传 int 也能正确转成 double', () {
      final event = parsePaymentEvent({'amount': 100});
      expect(event.amount, 100.0);
      expect(event.amount, isA<double>());
    });

    test('income 类型不会被误转成 expense', () {
      final event = parsePaymentEvent({'amount': 5000.0, 'type': 'income'});
      expect(event.type, 'income');
    });
  });
}

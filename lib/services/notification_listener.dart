import 'package:flutter/services.dart';

class PaymentEvent {
  final double amount;
  final String type; // expense / income
  final String sourceApp;
  final String content;

  PaymentEvent({
    required this.amount,
    required this.type,
    required this.sourceApp,
    required this.content,
  });
}

/// Android 支付通知监听桥接：MethodChannel 启动监听，EventChannel 接收解析结果。
class PaymentNotificationListener {
  static const MethodChannel _methodChannel =
      MethodChannel('remember/payment_listener');
  static const EventChannel _eventChannel =
      EventChannel('remember/payment_events');

  static Future<bool> startListening() async {
    try {
      final ok = await _methodChannel.invokeMethod<bool>('startListening');
      return ok ?? false;
    } catch (_) {
      return false; // iOS 或未启用时静默降级
    }
  }

  static Stream<PaymentEvent> get paymentStream {
    return _eventChannel.receiveBroadcastStream().map((raw) {
      final data = Map<dynamic, dynamic>.from(raw as Map);
      return PaymentEvent(
        amount: (data['amount'] as num).toDouble(),
        type: (data['type'] as String?) ?? 'expense',
        sourceApp: (data['sourceApp'] as String?) ?? '',
        content: (data['content'] as String?) ?? '',
      );
    });
  }
}
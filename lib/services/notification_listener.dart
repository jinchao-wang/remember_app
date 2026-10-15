import 'package:flutter/services.dart';

class PaymentEvent {
  final double amount;
  final String type; // expense / income
  final String sourceApp;
  final String content;

  /// 通知实际发生时间。App 未运行时事件会被原生层缓存，这里保留原始时间戳，
  /// 否则隔天补记就会把日期记成补记当天。
  final DateTime? timestamp;

  PaymentEvent({
    required this.amount,
    required this.type,
    required this.sourceApp,
    required this.content,
    this.timestamp,
  });
}

/// 把原生推送的 Map 转成 PaymentEvent。
/// 字段名必须与 MainActivity.kt 中的 mapOf(...) 保持一致。
PaymentEvent parsePaymentEvent(Map<dynamic, dynamic> data) {
  final ts = data['timestamp'];
  return PaymentEvent(
    amount: (data['amount'] as num).toDouble(),
    type: (data['type'] as String?) ?? 'expense',
    sourceApp: (data['sourceApp'] as String?) ?? '',
    content: (data['content'] as String?) ?? '',
    timestamp:
        ts is num ? DateTime.fromMillisecondsSinceEpoch(ts.toInt()) : null,
  );
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
      if (raw is! Map) {
        throw FormatException('支付通知事件格式异常: $raw');
      }
      return parsePaymentEvent(Map<dynamic, dynamic>.from(raw));
    });
  }
}
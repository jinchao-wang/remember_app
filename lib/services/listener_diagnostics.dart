import 'package:flutter/services.dart';

/// 一条通知的诊断记录。
///
/// [recognized] 为 false 时，[reason] 说明为什么这条通知没有被记成账单。
class NotificationRecord {
  /// 通知来源的包名，例如 com.tencent.mm。
  final String packageName;

  /// 通知标题。
  final String title;

  /// 通知正文。
  final String text;

  /// 是否被识别成支付通知。
  final bool recognized;

  /// 识别结果说明；未识别时是「为什么没记」。
  final String reason;

  /// 通知到达时间。
  final DateTime time;

  const NotificationRecord({
    required this.packageName,
    required this.title,
    required this.text,
    required this.recognized,
    required this.reason,
    required this.time,
  });

  factory NotificationRecord.fromMap(Map<dynamic, dynamic> map) => NotificationRecord(
        packageName: (map['packageName'] as String?) ?? '',
        title: (map['title'] as String?) ?? '',
        text: (map['text'] as String?) ?? '',
        recognized: (map['recognized'] as bool?) ?? false,
        reason: (map['reason'] as String?) ?? '',
        time: DateTime.fromMillisecondsSinceEpoch(
          (map['timestamp'] as num?)?.toInt() ?? 0,
        ),
      );

  /// 展示用的一行摘要。
  String get summary {
    final body = text.isNotEmpty ? text : title;
    return body.isEmpty ? '(空通知)' : body;
  }
}

/// 通知监听的诊断快照。
///
/// 「通知监听已开启」只说明系统设置里勾上了，不代表监听服务真的活着，
/// 也不代表通知文案被识别。这个快照把三件事分开报出来：
/// 授权状态、服务连接状态、最近收到的通知。
class ListenerDiagnostics {
  /// 系统设置里是否开启了本 App 的通知使用权。
  final bool listenerEnabled;

  /// 监听服务最后一次连上系统的时间；null 表示从来没连上过。
  final DateTime? serviceConnectedAt;

  /// 监听服务最后一次与系统断开的时间。
  final DateTime? serviceDisconnectedAt;

  /// 最后一次收到任何通知的时间。
  final DateTime? lastNotificationAt;

  /// 最近收到的疑似支付类通知，最新的在前。
  final List<NotificationRecord> recentNotifications;

  const ListenerDiagnostics({
    required this.listenerEnabled,
    this.serviceConnectedAt,
    this.serviceDisconnectedAt,
    this.lastNotificationAt,
    this.recentNotifications = const [],
  });

  /// 监听服务是否曾经被系统绑定过。
  bool get serviceEverConnected => serviceConnectedAt != null;

  /// 按记录判断，监听服务最后一次已知的状态是不是「已连接」。
  ///
  /// 服务被系统直接杀掉时不会回调 onListenerDisconnected，
  /// 所以这里只能看「最后一次事件是连接还是断开」。
  bool get serviceLooksConnected {
    final connected = serviceConnectedAt;
    if (connected == null) return false;
    final disconnected = serviceDisconnectedAt;
    if (disconnected == null) return true;
    return connected.isAfter(disconnected);
  }

  /// 解析原生返回的 Map。
  factory ListenerDiagnostics.fromMap(Map<dynamic, dynamic> map) {
    final raw = map['recentNotifications'];
    final list = <NotificationRecord>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) list.add(NotificationRecord.fromMap(item));
      }
    }

    DateTime? ts(Object? v) {
      final n = (v as num?)?.toInt() ?? 0;
      return n > 0 ? DateTime.fromMillisecondsSinceEpoch(n) : null;
    }

    return ListenerDiagnostics(
      listenerEnabled: (map['listenerEnabled'] as bool?) ?? false,
      serviceConnectedAt: ts(map['serviceConnectedAt']),
      serviceDisconnectedAt: ts(map['serviceDisconnectedAt']),
      lastNotificationAt: ts(map['lastNotificationAt']),
      recentNotifications: list,
    );
  }
}

/// 与原生层通信，拿诊断信息。
class ListenerDiagnosticsService {
  static const MethodChannel _channel =
      MethodChannel('remember/payment_listener');

  /// 取一份诊断快照。取不到时返回 null（iOS 或原生没实现）。
  static Future<ListenerDiagnostics?> fetch() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getDiagnostics',
      );
      if (raw == null) return null;
      return ListenerDiagnostics.fromMap(raw);
    } catch (_) {
      return null;
    }
  }

  /// 打开「通知使用权」系统设置。
  static Future<void> openNotificationSettings() =>
      _invoke('openNotificationSettings');

  /// 打开本 App 的系统详情页（国产 ROM 的自启动/电池策略入口在这里）。
  static Future<void> openAppSettings() => _invoke('openAppSettings');

  /// 打开系统「电池优化」白名单列表页。
  static Future<void> openBatteryOptimizationSettings() =>
      _invoke('openBatteryOptimizationSettings');

  /// 打开各厂商的「自启动管理」页面。
  static Future<void> openAutoStartSettings() => _invoke('openAutoStartSettings');

  static Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } catch (_) {
      // iOS / 桌面端没有这些页面，静默忽略。
    }
  }
}

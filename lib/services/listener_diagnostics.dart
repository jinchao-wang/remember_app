import 'dart:async';

import 'package:flutter/services.dart';

import 'notification_listener.dart';
import 'payment_service.dart';

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

  /// 正文里能读到的金额。
  ///
  /// 即使这条通知没有被记账，金额往往也是明确的（例如「微信支付 ¥31.31」）。
  /// 用户可以在诊断列表里一键补记，方向由自己选——
  /// 比 App 猜一个方向然后往账本里塞一条错误的收支要好。
  final double? amount;

  /// 用户是否已经手动补记过这条通知。
  final bool recorded;

  const NotificationRecord({
    required this.packageName,
    required this.title,
    required this.text,
    required this.recognized,
    required this.reason,
    required this.time,
    this.amount,
    this.recorded = false,
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
        amount: (map['amount'] as num?)?.toDouble(),
        recorded: (map['recorded'] as bool?) ?? false,
      );

  /// 展示用的一行摘要。
  String get summary {
    final body = text.isNotEmpty ? text : title;
    return body.isEmpty ? '(空通知)' : body;
  }

  /// 通知原文（标题 + 正文），用来做分类推断与账单备注。
  String get fullText {
    final t = title.trim();
    final b = text.trim();
    if (t.isEmpty) return b;
    if (b.isEmpty) return t;
    return '$t $b';
  }

  /// 这条通知能不能手动补记。
  ///
  /// 只有「读得出金额、但没自动记账、也没补记过」的才给补记入口：
  /// 没有金额就无从补记，已经记过的不该再给。
  bool get canManuallyRecord {
    if (recognized || recorded) return false;
    return amount != null && amount! > 0;
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

  /// 最后一次收到**疑似支付类**通知的时间。
  ///
  /// 注意这是「支付类」的，不是「任何」通知——用户几天不付款时它会一直是旧的。
  /// 判断服务死活请看 [lastEventAt]。
  final DateTime? lastNotificationAt;

  /// 最后一次收到**任何**通知的时间（聊天消息也算）。
  ///
  /// 这是判断监听服务还活不活着的关键：
  /// - 这个时间在往前走 -> 服务是活的，收不到支付通知是**文案识别**的问题；
  /// - 这个时间停住了 -> 绑定真的掉了，点「重新连接监听服务」能救回来。
  final DateTime? lastEventAt;

  /// 最近收到的疑似支付类通知，最新的在前。
  final List<NotificationRecord> recentNotifications;

  /// 最后一次请求系统重新绑定监听服务的时间。
  final DateTime? lastRebindAt;

  /// 一共请求过多少次重新绑定。
  final int rebindCount;

  /// 最近一次重新绑定请求是否成功发出。
  final bool lastRebindOk;

  /// 保活闹钟是否已经排上。
  final bool keepAliveArmed;

  /// 最后一次「手动重连监听服务」的时间。
  final DateTime? lastReconnectAt;

  /// 最后一次重连是否成功。
  final bool lastReconnectOk;

  /// 最后一次重连走到哪一步：rebind / force / notAuthorized。
  final String lastReconnectStage;

  /// 最后一次重连的结果说明（原生层给用户的文案）。
  final String lastReconnectMessage;

  const ListenerDiagnostics({
    required this.listenerEnabled,
    this.serviceConnectedAt,
    this.serviceDisconnectedAt,
    this.lastNotificationAt,
    this.lastEventAt,
    this.recentNotifications = const [],
    this.lastRebindAt,
    this.rebindCount = 0,
    this.lastRebindOk = false,
    this.keepAliveArmed = false,
    this.lastReconnectAt,
    this.lastReconnectOk = false,
    this.lastReconnectStage = '',
    this.lastReconnectMessage = '',
  });

  /// 监听服务是否曾经被系统绑定过。
  bool get serviceEverConnected => serviceConnectedAt != null;

  /// 「最近还收到过任意通知」的时间窗口：30 分钟。
  ///
  /// 与原生层 `ListenerHealth.ALIVE_WINDOW_MS` 保持一致。
  static const int aliveWindowMinutes = 30;

  /// 监听服务最近看起来还活着吗。
  ///
  /// 判据是 [lastEventAt]：最近半小时内收到过任何一条通知就算活着。
  ///
  /// 这一条专门用来识别用户报的那个故障：
  /// 系统那边显示「已连接」，但实际上一个通知都收不到——
  /// 这时 [serviceLooksConnected] 会是 true（骗人），只有这个能看出问题。
  bool get listenerLooksAlive {
    final at = lastEventAt;
    if (at == null) return false;
    final diff = DateTime.now().difference(at).inMinutes;
    return diff >= 0 && diff < aliveWindowMinutes;
  }

  /// 出现了「系统说连着、实际却收不到」这种僵死状态。
  bool get listenerLooksStuck =>
      serviceLooksConnected && serviceEverConnected && !listenerLooksAlive;

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
      lastEventAt: ts(map['lastEventAt']),
      recentNotifications: list,
      lastRebindAt: ts(map['lastRebindAt']),
      rebindCount: (map['rebindCount'] as num?)?.toInt() ?? 0,
      lastRebindOk: (map['lastRebindOk'] as bool?) ?? false,
      keepAliveArmed: (map['keepAliveArmed'] as bool?) ?? false,
      lastReconnectAt: ts(map['lastReconnectAt']),
      lastReconnectOk: (map['lastReconnectOk'] as bool?) ?? false,
      lastReconnectStage: (map['lastReconnectStage'] as String?) ?? '',
      lastReconnectMessage: (map['lastReconnectMessage'] as String?) ?? '',
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

  /// 标记某条通知已被用户手动补记。
  static Future<bool> markRecorded(int timestamp) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'markNotificationRecorded',
        {'timestamp': timestamp},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 手动重连监听服务。
  ///
  /// 原生侧会先用无副作用的 `requestRebind` 请求重绑并等几秒看效果，
  /// 确认没连上才去重置组件绑定（这一步有副作用，不该自动做）。
  ///
  /// 加了超时兜底：万一原生层卡住，界面不能一直停在「正在重新连接…」，
  /// 那比没重连还让人困惑。
  static Future<ReconnectResult> reconnect() async {
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>(
            'reconnectListener',
          )
          .timeout(const Duration(seconds: 20));
      if (raw == null) {
        return const ReconnectResult(
          ok: false,
          stage: 'unknown',
          message: '重连失败：原生层没有响应',
        );
      }
      return ReconnectResult(
        ok: (raw['ok'] as bool?) ?? false,
        stage: (raw['stage'] as String?) ?? 'unknown',
        message: (raw['message'] as String?) ?? '',
      );
    } on TimeoutException {
      return const ReconnectResult(
        ok: false,
        stage: 'timeout',
        message: '重连超时（20 秒没结果），请再点一次',
      );
    } catch (_) {
      return const ReconnectResult(
        ok: false,
        stage: 'unknown',
        message: '重连失败：无法调用原生层',
      );
    }
  }

  static Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } catch (_) {
      // iOS / 桌面端没有这些页面，静默忽略。
    }
  }
}

/// 「重新连接监听服务」的结果。
class ReconnectResult {
  /// 是否成功。
  final bool ok;

  /// 生效的阶段：rebind（只重绑）/ force（重置了组件）/ notAuthorized（没授权）。
  final String stage;

  /// 给用户看的说明。
  final String message;

  const ReconnectResult({
    required this.ok,
    required this.stage,
    required this.message,
  });
}

/// 手动把一条没被自动记账的通知补记成账单。
///
/// 存在的理由：有的支付通知只写「¥31.31」，没有方向词，App 判断不出是收还是付。
/// 与其猜一个方向往账本里塞一条错误的收支，不如把选择权交给用户——点一下就好。
///
/// 走 [PaymentService.handleEvent] 这条既有链路，是为了白捡判重、
/// 分类推断和「自动记账」标记：手动补记出来的账单，处理方式和自动记录的完全一致。
///
/// @return true 表示真的新增了一条；false 表示账本里已经有同一笔，没有重复记录。
Future<bool> recordNotificationManually(
  NotificationRecord record,
  String type,
) async {
  final amount = record.amount;
  if (amount == null || amount <= 0) return false;

  final inserted = await PaymentService.instance.handleEvent(
    PaymentEvent(
      amount: amount,
      type: type,
      sourceApp: record.packageName,
      content: record.fullText,
      timestamp: record.time,
    ),
  );
  // 无论有没有真的新增，都标记一下，避免用户连点补出两条。
  await ListenerDiagnosticsService.markRecorded(
    record.time.millisecondsSinceEpoch,
  );
  return inserted;
}

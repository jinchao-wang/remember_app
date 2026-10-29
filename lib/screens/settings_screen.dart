import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import '../models/transaction.dart';
import '../services/app_state.dart';
import '../services/bill_import_service.dart';
import '../services/database.dart';
import '../services/listener_diagnostics.dart';
import '../services/payment_service.dart';
import '../utils/bill_parser.dart';
import '../utils/csv_helper.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => SettingsScreenState();
}

/// 状态类对外公开，是为了让 [HomeScreen] 能在切到「设置」页签时
/// 主动调一次刷新——否则页面停在上一次打开时的快照，
/// 用户会看到「还没有收到疑似支付类的通知」而实际上通知已经到了。
class SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  bool _listening = false;
  bool _checking = true;
  ListenerDiagnostics? _diagnostics;

  /// 「后台常驻监听」的现状（开关、服务在不在跑、通知权限给了没）。
  BackgroundMonitoringStatus? _background;

  /// 「重新连接监听服务」是否正在进行。
  ///
  /// 重连要跑几秒（原生层最多等 6 秒），期间禁掉按钮，
  /// 既避免连点，也让用户看到「正在重新连接…」。
  bool _reconnecting = false;

  static const _platform = MethodChannel('remember/payment_listener');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkNotificationStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 用户跳到系统设置开启权限后返回，必须重新读取状态，
    // 否则界面会一直显示「未开启」。
    if (state == AppLifecycleState.resumed) {
      _checkNotificationStatus();
      refreshDiagnostics();
    }
  }

  /// 重新拉取诊断信息（授权状态 + 最近收到的通知）。
  ///
  /// 公开出来给 [HomeScreen] 调用：切到设置页签时拉一次，
  /// 用户不用记得点「刷新」才能看到刚到的通知。
  Future<void> refreshDiagnostics() async {
    await _checkNotificationStatus();
    await _loadDiagnostics();
  }

  Future<void> _checkNotificationStatus() async {
    try {
      final enabled = await _platform.invokeMethod<bool>('isListeningEnabled');
      if (mounted) {
        setState(() {
          _listening = enabled ?? false;
          _checking = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _checking = false);
    }
    await _loadDiagnostics();
  }

  /// 拉取诊断信息：服务有没有真的连上、最近收到了什么通知。
  Future<void> _loadDiagnostics() async {
    final diag = await ListenerDiagnosticsService.fetch();
    final bg = await ListenerDiagnosticsService.fetchBackgroundMonitoring();
    if (!mounted) return;
    setState(() {
      _diagnostics = diag;
      _background = bg;
    });
  }

  /// 开关「后台常驻监听」。
  ///
  /// 开着的时候 App 会在通知栏留一条常驻通知，进程被系统回收后
  /// 由系统重新拉起——这是「退到后台还能继续监听」的关键。
  Future<void> _toggleBackgroundMonitoring(bool enabled) async {
    final ok = await ListenerDiagnosticsService.setBackgroundMonitoring(enabled);
    if (enabled && ok) {
      // Android 13+ 常驻通知要 POST_NOTIFICATIONS 权限才显示得出来。
      // 不给也不影响服务运行，只是用户看不见那条提示，
      // 会以为「开了没反应」，所以这里主动要一次。
      await ListenerDiagnosticsService.requestNotificationPermission();
    }
    await _loadDiagnostics();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          enabled
              ? '后台常驻监听已开启，退到后台也会继续监听'
              : '后台常驻监听已关闭，退到后台后可能被系统清理',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 单独申请通知权限（Android 13+ 常驻通知需要它才显示得出来）。
  Future<void> _requestNotificationPermission() async {
    final granted = await ListenerDiagnosticsService.requestNotificationPermission();
    await _loadDiagnostics();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          granted
              ? '已允许显示常驻提示'
              : '没给通知权限，后台监听仍然正常，只是不显示常驻提示',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _openNotificationSettings() async {
    try {
      await _platform.invokeMethod('openNotificationSettings');
    } catch (e) {
      debugPrint('无法打开通知设置：$e');
    }
  }

  Future<void> _exportCsv() async {
    final ctx = context;
    try {
      final tx = await DatabaseHelper.instance.getTransactions();
      if (tx.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('暂无账单可导出'), duration: Duration(seconds: 2)),
        );
        return;
      }
      final csv = transactionsToCsv(tx);
      final dir = await getApplicationDocumentsDirectory();
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final file = File('${dir.path}/记账导出_$stamp.csv');
      await file.writeAsString(csv);
      if (!mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(content: Text('已导出 ${tx.length} 条记录\n${file.path}'), duration: const Duration(seconds: 3)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(content: Text('导出失败：$e'), duration: const Duration(seconds: 3)),
      );
    }
  }

  Future<void> _importCsv() async {
    final ctx = context;
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );
      if (res == null || res.files.single.path == null) return;
      final text = await File(res.files.single.path!).readAsString();
      final list = csvToTransactions(text);
      if (list.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('未解析到有效数据'), duration: Duration(seconds: 2)),
        );
        return;
      }
      final confirm = await showDialog<bool>(
        context: ctx,
        builder: (inner) => AlertDialog(
          title: const Text('确认导入'),
          content: Text('即将导入 ${list.length} 条账单，是否继续？\n（重复记录将被跳过）'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(inner, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(inner, true), child: const Text('导入')),
          ],
        ),
      );
      if (confirm != true) return;

      // 只查一次全表并建索引：旧实现对每一行都 getTransactions()，
      // 是 O(n^2) 的全表扫描，几百行 CSV 足以卡住界面。
      // dedupeKey 含 type，收入/支出同额不会被误判为重复。
      final existing = await DatabaseHelper.instance.getTransactions();
      final seen = existing.map((e) => e.dedupeKey).toSet();

      final toInsert = <Transaction>[];
      for (final tx in list) {
        if (seen.add(tx.dedupeKey)) toInsert.add(tx);
      }

      await DatabaseHelper.instance.insertAll(toInsert);
      final imported = toInsert.length;
      final skipped = list.length - imported;

      AppState.instance.bump();
      if (!mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text(
            skipped == 0
                ? '导入完成，成功导入 $imported 条记录'
                : '导入完成：新增 $imported 条，跳过重复 $skipped 条',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(content: Text('导入失败：$e'), duration: const Duration(seconds: 3)),
      );
    }
  }

  /// 导入微信 / 支付宝官方账单。
  ///
  /// 通知监听只覆盖「系统弹了通知」的场景；在微信、支付宝 App 内部发起的
  /// 转账平台并不发通知，那部分账只能从官方账单文件补。
  Future<void> _importBill() async {
    final ctx = context;
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv', 'xlsx', 'zip'],
      );
      if (res == null || res.files.single.path == null) return;

      final result = await BillImportService.importFile(res.files.single.path!);
      if (!mounted) return;

      if (!result.ok) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(
            content: Text(result.error ?? '导入失败'),
            duration: const Duration(seconds: 4),
          ),
        );
        return;
      }

      final message = StringBuffer('${result.source.label}账单导入完成：新增 ${result.imported} 条');
      if (result.duplicates > 0) message.write('，跳过重复 ${result.duplicates} 条');
      if (result.skipped > 0) message.write('，忽略无效 ${result.skipped} 行');
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(content: Text(message.toString()), duration: const Duration(seconds: 4)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(content: Text('导入失败：$e'), duration: const Duration(seconds: 3)),
      );
    }
  }

  Future<void> _showBillHelp() async {
    final ctx = context;
    await showDialog<void>(
      context: ctx,
      builder: (inner) => AlertDialog(
        title: const Text('怎么导出账单'),
        content: const Text(
          '微信：我的 → 服务 → 钱包 → 账单 → 右上角「…」→ 账单下载，\n'
          '选择时间范围后会收到邮件或下载压缩包（zip 里是 xlsx），\n'
          '也可以在电脑版微信导出 csv。\n\n'
          '支付宝：我的 → 账单 → 右上角「…」→ 账单导出 / 交易记录证明，\n'
          '下载得到的 csv 是 GBK 编码，本应用会自动识别。\n\n'
          '导入后可在账单列表里核对并修改分类。',
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(inner), child: const Text('知道了')),
        ],
      ),
    );
  }

  Future<void> _clearAll() async {
    final ctx = context;
    final confirm = await showDialog<bool>(
      context: ctx,
      builder: (inner) => AlertDialog(
        title: const Text('清空所有账单'),
        content: const Text('此操作将删除所有账单记录且不可恢复，是否继续？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(inner, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(inner, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await DatabaseHelper.instance.deleteAllTransactions();
    AppState.instance.bump();
    if (!mounted) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      const SnackBar(content: Text('所有账单已清空'), duration: Duration(seconds: 2)),
    );
  }

  /// 自动记账卡片。
  ///
  /// 默认只摆用户真正用得上的东西：现在是什么状态、不正常时该怎么办。
  /// 那些诊断细节（保活重连次数、上次连接时刻、国产 ROM 的三个开关……）
  /// 全部收进「诊断详情」折叠区——用户反馈过设置页又挤又杂，
  /// 那些信息平时根本用不上，摊开只是噪音。
  Widget _buildAutoRecordCard() {
    final diag = _diagnostics;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _listening ? Icons.check_circle : Icons.warning,
                  color: _listening ? context.appColors.income : context.scheme.error,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _checking
                            ? '检查中...'
                            : (_listening ? '通知监听已开启' : '通知监听未开启'),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _statusSubtitle(diag),
                        style: TextStyle(
                          color: context.scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (!_listening) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _openNotificationSettings,
                  icon: const Icon(Icons.settings),
                  label: const Text('前往设置开启'),
                ),
              ),
            ] else if (diag != null) ...[
              if (diag.listenerLooksStuck) ...[
                const SizedBox(height: 10),
                _stuckWarning(),
              ],
              if (diag.killNeedsUserAction) ...[
                const SizedBox(height: 10),
                _killNotRecoveredWarning(),
              ],
              if (diag.lastCrash.isNotEmpty) ...[
                const SizedBox(height: 10),
                _crashWarning(diag.lastCrash),
              ],
              const SizedBox(height: 12),
              _buildReconnectRow(),
              _buildBackgroundMonitoringRow(),
              _buildDiagnostics(diag),
            ],
          ],
        ),
      ),
    );
  }

  /// 状态标题下面那行说明。
  ///
  /// 一句话讲清「现在能不能记上账」：服务连没连、最近收没收到通知
  /// 都放在这一行，不用再往下翻一屏去找。
  String _statusSubtitle(ListenerDiagnostics? diag) {
    if (_checking) return '';
    if (!_listening) return '需在系统设置中开启通知权限，支付通知才能自动记录';
    if (diag == null) return '支付通知将自动记录为账单';
    if (!diag.serviceEverConnected) {
      return '已授权，但系统还没有拉起过监听服务，目前收不到任何通知';
    }
    if (!diag.serviceLooksConnected) return '监听服务已断开，点下面的按钮重连';
    final at = diag.lastEventAt;
    if (at == null) return '服务已连接，等系统推送通知';
    return '服务已连接 · 最近收到通知 ${_timeAgo(at)}';
  }

  /// 「诊断详情」折叠区。
  ///
  /// 里面的东西平时用不上，真出问题时又非常有用，
  /// 所以是收起来而不是删掉。
  Widget _buildDiagnostics(ListenerDiagnostics diag) {
    final connected = diag.serviceLooksConnected;
    final connectedAt = diag.serviceConnectedAt;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        dense: true,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 4),
        title: const Text('诊断详情', style: TextStyle(fontSize: 14)),
        children: [
          _diagRow(
            Icons.sensors,
            '监听服务',
            connected
                ? (connectedAt == null ? '已连接' : '已连接 · ${_timeAgo(connectedAt)}连接')
                : '未连接',
          ),
          _diagRow(
            Icons.notifications_active,
            '最近收到通知',
            _timeAgo(diag.lastEventAt),
          ),
          _diagRow(
            Icons.receipt_long,
            '最近支付类通知',
            _timeAgo(diag.lastNotificationAt),
          ),
          _diagRow(
            Icons.autorenew,
            '自动保活',
            diag.keepAliveArmed
                ? '已开启 · 已重连 ${diag.rebindCount} 次'
                : '未开启',
          ),
          _diagRow(
            Icons.phonelink_lock,
            '后台常驻服务',
            diag.foregroundServiceRunning ? '运行中' : '未运行',
          ),
          _diagRow(
            Icons.healing,
            '自动修复',
            _autoRepairHint(diag),
          ),
          _diagRow(
            Icons.power_settings_new,
            '上次进程结束',
            diag.lastKillAt == null
                ? '无记录'
                : '${_timeAgo(diag.lastKillAt)} · ${diag.lastKillReason}'
                    '${diag.killRecovered ? ' · 已自动恢复' : ''}',
          ),
          _diagRow(
            Icons.bug_report,
            '上次崩溃',
            diag.lastCrash.isEmpty ? '无记录' : diag.lastCrash,
          ),
          const SizedBox(height: 12),
          _buildRomHints(),
        ],
      ),
    );
  }

  /// 自动修复做过什么。
  ///
  /// 这一栏的意义是「App 不是在干等」：
  /// 用户反馈监听又没了时，能看到 App 自己试过没有、做到了哪一步。
  String _autoRepairHint(ListenerDiagnostics diag) {
    final at = diag.autoRepairAt;
    if (at == null) return '尚未触发';
    final message = diag.autoRepairMessage.isEmpty
        ? diag.autoRepairResult
        : diag.autoRepairMessage;
    return '${_timeAgo(at)} · $message';
  }

  /// 「系统说连着、实际收不到」的僵死告警。
  ///
  /// 原来是一个占掉半屏的大橙框 + 一长段解释，
  /// 而且阈值太紧，服务好好的时候也会跳出来吓人。
  /// 现在压成一行提示。
  Widget _stuckWarning() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 16, color: Colors.orange.shade700),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '超过 2 小时没收到任何通知。如果付了钱没记账，点下面重连一次。',
            style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
          ),
        ),
      ],
    );
  }

  /// 「上次进程结束后监听没连回来」的告警。
  ///
  /// 这是唯一一种**救不回来**的故障：进程被系统结束之后，
  /// 监听服务没能重新绑上（典型原因是被「强行停止」——
  /// Android 会把 App 标记为 stopped，此时**不跑任何组件**：
  /// 闹钟、后台服务、Job 全停，通知监听也不会被系统绑定）。
  ///
  /// 任何 App 都绕不过这条平台限制，唯一的办法是让用户重新打开一次。
  /// 所以必须明确告诉用户「现在不会自动恢复」，别让他干等。
  ///
  /// 判据不是死因（划掉还是强停，公开 API 分不清），
  /// 而是「监听到底连上了没有」——这个测得准。
  Widget _killNotRecoveredWarning() {
    final d = _diagnostics;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline, size: 16, color: context.scheme.error),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '上次进程在 ${_timeAgo(d?.lastKillAt)} 结束'
            '${d?.lastKillReason == null || d!.lastKillReason.isEmpty ? '' : '（${d.lastKillReason}）'}，'
            '之后监听没能重新连上。请重新打开一次 App 恢复。',
            style: TextStyle(fontSize: 12, color: context.scheme.error),
          ),
        ),
      ],
    );
  }

  /// 「上次崩过」的告警。
  ///
  /// 用户说「App 打不开」时，光看现象分不出是闪退还是白屏。
  /// 这里把崩溃时的异常原样摆出来，下次再出问题时能直接定位。
  Widget _crashWarning(String crash) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.bug_report, size: 16, color: context.scheme.error),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '上次崩溃：$crash',
            style: TextStyle(fontSize: 12, color: context.scheme.error),
          ),
        ),
      ],
    );
  }

  /// 「重新连接监听服务」按钮。
  ///
  /// 一直显示，不只是「未连接」时才显示——
  /// 最麻烦的故障是**绑定僵死**：系统以为还连着、界面也显示「已连接」，
  /// 但通知其实一个都收不到（这正是用户报的现象）。
  /// 这种情况下只有手动重置绑定才能救回来。
  ///
  /// 按钮上方原来那段「Android 偶尔会在后台把监听服务解绑……」的解释删掉了——
  /// 按钮叫什么就够用户看懂，真出问题时页面里的告警会告诉他该做什么。
  Widget _buildReconnectRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            // 重连要跑几秒，期间禁掉按钮，免得用户连点。
            onPressed: _reconnecting ? null : _reconnectListener,
            icon: _reconnecting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.link, size: 18),
            label: Text(_reconnecting ? '正在重新连接…' : '重新连接监听服务'),
          ),
        ),
        if (_lastReconnectHint != null) ...[
          const SizedBox(height: 6),
          Text(
            _lastReconnectHint!,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
            ),
          ),
        ],
      ],
    );
  }

  /// 「后台常驻监听」开关。
  ///
  /// 这是「退到后台也能继续监听」的那一环：常驻前台服务让进程优先级更高，
  /// 国产 ROM 的「一键清理」一般会跳过它，系统回收进程后也会重新拉起它。
  ///
  /// 代价是通知栏会多一条常驻通知，所以做成可关的。
  Widget _buildBackgroundMonitoringRow() {
    final bg = _background;
    final enabled = bg?.enabled ?? true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Row(
          children: [
            Icon(
              Icons.phonelink_lock,
              size: 20,
              color: context.scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '后台常驻监听',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _backgroundMonitoringHint,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.scheme.onSurfaceVariant,
                    ),
                  ),
                  // Android 13+ 没给通知权限的话，常驻通知不会出现在通知栏，
                  // 用户会以为「开了没反应」。给一个明确的授权入口。
                  if (bg != null && bg.enabled && !bg.notificationPermissionGranted)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _requestNotificationPermission,
                        icon: const Icon(Icons.notifications_active, size: 16),
                        label: const Text('允许显示常驻提示'),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          visualDensity: VisualDensity.compact,
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Switch(
              value: enabled,
              onChanged: _toggleBackgroundMonitoring,
            ),
          ],
        ),
      ],
    );
  }

  /// 常驻监听这一行下面的小字。
  ///
  /// 把「开关开着」和「服务真的在跑」分开说——
  /// 用户被清理之后开关还是开着的，但服务已经没了，
  /// 只看开关会以为一切正常。
  String get _backgroundMonitoringHint {
    final bg = _background;
    if (bg == null) return '退到后台后继续监听支付通知';
    if (!bg.enabled) return '已关闭 · 退到后台后可能被系统清理';
    if (!bg.running) return '未运行 · 进程被系统清掉了，重新打开一次 App 即可恢复';
    if (!bg.notificationPermissionGranted) {
      return '运行中 · 但没给通知权限，通知栏看不到常驻提示';
    }
    return '运行中 · 通知栏有一条常驻提示';
  }

  /// 上一次重连的结果。
  ///
  /// 从诊断数据里取，所以重启 App 之后也还在——
  /// 用户过几天回来看，能知道上次那次重连到底成功了没有。
  String? get _lastReconnectHint {
    final d = _diagnostics;
    if (d == null || d.lastReconnectMessage.isEmpty) return null;
    return '上次重连（${_timeAgo(d.lastReconnectAt)}）：${d.lastReconnectMessage}';
  }

  /// 手动重连监听服务。
  ///
  /// 「正在重连」直接体现在按钮上，不弹提示框——
  /// 提示框会排队，用户要等第一个提示框消失才看得到结果。
  Future<void> _reconnectListener() async {
    if (_reconnecting) return;
    setState(() => _reconnecting = true);
    final result = await ListenerDiagnosticsService.reconnect();
    await _loadDiagnostics();
    if (!mounted) return;
    setState(() => _reconnecting = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.message),
        backgroundColor: result.ok ? Colors.green.shade700 : Colors.orange.shade800,
      ),
    );
  }

  /// 一行「标签 : 值」。
  ///
  /// 旧版这里是 `Text(label) + Spacer() + Flexible(value) + Text(hint)` 四段挤在一行。
  /// `Spacer` 和 `Flexible` 各占一半弹性空间，而 `hint` 是不伸缩的长文本
  /// （「已重连 17 次 · 上次 刚刚」），值被压到只剩几像素宽——
  /// 「已连接」就被挤成竖着的「已连 / 接」。
  ///
  /// 现在只留两段：标签和值，中间用 [Expanded] 把值推到右边靠右对齐，
  /// 补充说明一律并进值里，不再单独占一列。
  Widget _diagRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: context.scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: context.scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// 国产 ROM 的自启动 / 电池优化提示与入口。
  Widget _buildRomHints() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '国产系统（小米 / 华为 / OPPO / vivo）会限制后台服务，'
          '如果一直没收到通知，请允许自启动并加入电池优化白名单。',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => ListenerDiagnosticsService.openAutoStartSettings(),
              icon: const Icon(Icons.rocket_launch, size: 18),
              label: const Text('允许自启动'),
            ),
            OutlinedButton.icon(
              onPressed: () => ListenerDiagnosticsService.openBatteryOptimizationSettings(),
              icon: const Icon(Icons.battery_saver, size: 18),
              label: const Text('电池优化白名单'),
            ),
            OutlinedButton.icon(
              onPressed: () => ListenerDiagnosticsService.openAppSettings(),
              icon: const Icon(Icons.settings, size: 18),
              label: const Text('应用设置'),
            ),
          ],
        ),
      ],
    );
  }

  /// 最近收到的通知（含没被记账的），用来回答「到底收到没有」。
  ///
  /// 最多能列 20 条，摊开来很长，所以默认收起来——
  /// 平时没人关心它，真出问题时点开看就行。
  Widget _buildRecentNotifications() {
    final list = _diagnostics?.recentNotifications ?? const <NotificationRecord>[];

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: const Text('最近收到的通知', style: TextStyle(fontSize: 14)),
        subtitle: Text(
          list.isEmpty ? '还没有收到疑似支付类的通知' : '${list.length} 条',
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              tooltip: '刷新',
              onPressed: _loadDiagnostics,
            ),
            const Icon(Icons.expand_more),
          ],
        ),
        children: [
          if (list.isEmpty)
            const Text(
              '付一笔钱之后回来刷新，就能看到系统到底送来了什么。'
              '如果已经付过钱、这里却还是空的，说明系统根本没把通知送过来——'
              '通常是国产 ROM 限制了后台服务，按「诊断详情」里的开关处理即可。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            )
          else
            ...list.take(20).map(_buildNotificationRow),
          const SizedBox(height: 8),
          const Text(
            '仅在本机保存最近 50 条通知原文用于排查，不联网、不上传。',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildNotificationRow(NotificationRecord r) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            r.recognized ? Icons.check_circle : Icons.error_outline,
            size: 18,
            color: r.recognized ? context.appColors.income : context.scheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${r.title.isEmpty ? r.packageName : r.title} · ${_timeAgo(r.time)}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  r.summary,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 2),
                Text(
                  r.recognized ? '已记账：${r.reason}' : '未记账：${r.reason}',
                  style: TextStyle(
                    fontSize: 11,
                    color: r.recognized ? context.appColors.income : context.scheme.error,
                  ),
                ),
                if (_canManuallyRecord(r)) ...[
                  const SizedBox(height: 6),
                  _buildManualRecordButtons(r),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 这条通知能不能手动补记。
  ///
  /// 只有「读得出金额、但没自动记账、也没补记过」的才给按钮：
  /// 没有金额就无从补记，已经记过的不该再给。
  bool _canManuallyRecord(NotificationRecord r) => r.canManuallyRecord;

  /// 「记为支出 / 记为收入」两个按钮。
  ///
  /// 方向让用户自己选，是因为 App 无法从「¥31.31」这种通知里判断是收还是付；
  /// 猜错方向往账本里塞一条错误的收支，比不记还糟。
  Widget _buildManualRecordButtons(NotificationRecord r) {
    final amount = r.amount ?? 0;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _manualRecord(r, 'expense'),
            icon: const Icon(Icons.arrow_downward, size: 16),
            label: Text('记为支出 ¥${amount.toStringAsFixed(2)}'),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _manualRecord(r, 'income'),
            icon: const Icon(Icons.arrow_upward, size: 16),
            label: Text('记为收入 ¥${amount.toStringAsFixed(2)}'),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }

  /// 手动补记一条通知。
  Future<void> _manualRecord(NotificationRecord r, String type) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ok = await recordNotificationManually(r, type);
      await _loadDiagnostics();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? '已记为${type == 'income' ? '收入' : '支出'} ¥${(r.amount ?? 0).toStringAsFixed(2)}'
                : '已存在相同金额的账单，没有重复记录',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('补记失败：$e')));
    }
  }

  /// 「x 分钟前」这样的相对时间。
  /// 扫描历史账单，删掉跨来源的重复记录。
  ///
  /// 用户反馈「总是有重复账单」时，光修新的不够——
  /// 已经记进去的那些也得能一键清掉。
  Future<void> _cleanupDuplicates() async {
    final messenger = ScaffoldMessenger.of(context);
    final ids = await PaymentService.findCrossSourceDuplicates();
    if (ids.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('没有发现重复账单'), duration: Duration(seconds: 2)),
      );
      return;
    }
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (inner) => AlertDialog(
        title: const Text('清理重复账单'),
        content: Text(
          '发现 ${ids.length} 条重复记录（同一笔扣费被记了两次）。\n'
          '每组重复只保留最早的那条，确定要删除多余的 ${ids.length} 条吗？',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(inner, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(inner, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final removed = await PaymentService.cleanupCrossSourceDuplicates();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(removed > 0 ? '已删除 $removed 条重复记录' : '清理失败，请重试'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _timeAgo(DateTime? time) {
    if (time == null) return '从未';
    final diff = DateTime.now().difference(time);
    if (diff.isNegative || diff.inSeconds < 60) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    return '${diff.inDays} 天前';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('数据管理', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.upload_file, color: Colors.blue),
                    title: const Text('导出 CSV'),
                    subtitle: const Text('把账单导出成文件'),
                    onTap: _exportCsv,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.download, color: Colors.green),
                    title: const Text('导入 CSV'),
                    subtitle: const Text('从文件导入账单'),
                    onTap: _importCsv,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.account_balance_wallet, color: Colors.purple),
                    title: const Text('导入微信/支付宝账单'),
                    subtitle: const Text('补记 App 内转账等没有通知的消费'),
                    onTap: _importBill,
                    trailing: IconButton(
                      icon: const Icon(Icons.help_outline),
                      tooltip: '怎么导出账单',
                      onPressed: _showBillHelp,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            const Text('账单去重', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              '同一笔扣费，微信和银行会各发一条通知。开启后只记一笔。',
              style: TextStyle(fontSize: 12, color: Colors.grey[600], height: 1.5),
            ),
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.merge_type, color: Colors.teal),
                    title: const Text('跨来源自动去重'),
                    subtitle: const Text('平台通知和银行通知金额相同、时间接近时，只记一笔'),
                    value: PaymentService.crossSourceEnabled,
                    onChanged: (v) async {
                      await PaymentService.setCrossSourceEnabled(v);
                      if (!mounted) return;
                      setState(() {});
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(v ? '已开启跨来源去重' : '已关闭跨来源去重'),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.cleaning_services_outlined, color: Colors.orange),
                    title: const Text('清理已有重复账单'),
                    subtitle: const Text('扫描历史记录，删掉重复的那几条'),
                    onTap: _cleanupDuplicates,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            const Text('自动记账（仅 Android）', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            _buildAutoRecordCard(),
            const SizedBox(height: 12),
            Card(child: _buildRecentNotifications()),
            const SizedBox(height: 32),
            const Text('危险操作', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.delete_forever_outlined, color: Colors.red),
                title: const Text('清空所有账单'),
                subtitle: const Text('删除所有记录，此操作不可撤销'),
                onTap: _clearAll,
              ),
            ),
            const SizedBox(height: 32),
            const Text('关于', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Remember 记账 v1.0', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      '本地优先，数据存在手机上，不联网、不上传。',
                      style: TextStyle(color: Colors.grey[600], fontSize: 14),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Android 支付通知自动记账，iOS 手动记账。',
                      style: TextStyle(color: Colors.grey[600], fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
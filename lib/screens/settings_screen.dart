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
import '../utils/bill_parser.dart';
import '../utils/csv_helper.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  bool _listening = false;
  bool _checking = true;
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
    }
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
                    subtitle: const Text('将账单导出为 CSV 文件保存到本地'),
                    onTap: _exportCsv,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.download, color: Colors.green),
                    title: const Text('导入 CSV'),
                    subtitle: const Text('从 CSV 文件导入账单（跳过重复记录）'),
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
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.delete_outline, color: Colors.red),
                    title: const Text('清空所有账单'),
                    subtitle: const Text('删除所有记录，此操作不可撤销'),
                    onTap: _clearAll,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            const Text('自动记账（仅 Android）', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _listening ? Icons.check_circle : Icons.warning,
                          color: _listening ? Colors.green : Colors.orange,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _checking ? '检查中...' : (_listening ? '通知监听已开启' : '通知监听未开启'),
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _checking ? '' : (_listening
                                    ? '支付通知将自动记录为账单'
                                    : '需在系统设置中开启通知权限，支付通知才能自动记录'),
                                style: TextStyle(color: Colors.grey[600], fontSize: 12),
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
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 32),
            const Text('关于', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Remember 记账 v1.0', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      '本地优先，数据存储在设备上，不联网，不上传服务器。',
                      style: TextStyle(color: Colors.grey[600], fontSize: 14),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '支持 Android 支付通知自动记账，iOS 支持手动记账。',
                      style: TextStyle(color: Colors.grey[600], fontSize: 14),
                    ),
                    Text(
                      '微信/支付宝 App 内转账不会发通知，可用「导入微信/支付宝账单」补记。',
                      style: TextStyle(color: Colors.grey[600], fontSize: 14),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '开发日期：2026年',
                      style: TextStyle(color: Colors.grey[500], fontSize: 12),
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
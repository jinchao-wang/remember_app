import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import '../services/app_state.dart';
import '../services/database.dart';
import '../utils/csv_helper.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _listening = false;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _checkNotificationStatus();
  }

  Future<void> _checkNotificationStatus() async {
    try {
      const platform = MethodChannel('remember/payment_listener');
      final ctx = context;
      final enabled = await platform.invokeMethod<bool>('isListeningEnabled');
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
    final ctx = context;
    try {
      const platform = MethodChannel('remember/payment_listener');
      await platform.invokeMethod('openNotificationSettings');
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

      int imported = 0;
      for (final tx in list) {
        try {
          final existing = await DatabaseHelper.instance.getTransactions();
          final duplicate = existing.any((e) =>
              e.category == tx.category &&
              (e.amount - tx.amount).abs() < 0.01 &&
              e.date.year == tx.date.year &&
              e.date.month == tx.date.month &&
              e.date.day == tx.date.day);
          if (!duplicate) {
            await DatabaseHelper.instance.insertTransaction(tx);
            imported++;
          }
        } catch (_) {
          // skip
        }
      }
      AppState.instance.bump();
      if (!mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(content: Text('导入完成，成功导入 $imported 条记录'), duration: const Duration(seconds: 2)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(content: Text('导入失败：$e'), duration: const Duration(seconds: 3)),
      );
    }
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
    final db = await DatabaseHelper.instance.database;
    await db.delete('transactions');
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
                    Text('记事本 v1.0', style: Theme.of(context).textTheme.titleMedium),
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
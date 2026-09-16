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
  Future<void> _export() async {
    final tx = await DatabaseHelper.instance.getTransactions();
    final csv = transactionsToCsv(tx);
    final dir = await getApplicationDocumentsDirectory();
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final file = File('${dir.path}/remember_export_$stamp.csv');
    await file.writeAsString(csv);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已导出 ${tx.length} 条\n${file.path}')));
  }

  Future<void> _import() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['csv']);
    if (res == null || res.files.single.path == null) return;
    final text = await File(res.files.single.path!).readAsString();
    final list = csvToTransactions(text);
    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('未解析到有效数据')));
      return;
    }
    await DatabaseHelper.instance.insertAll(list);
    AppState.instance.bump();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已导入 ${list.length} 条')));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('数据管理'),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              ListTile(leading: const Icon(Icons.download), title: const Text('导出 CSV'), onTap: _export),
              const Divider(height: 1),
              ListTile(leading: const Icon(Icons.upload), title: const Text('导入 CSV'), onTap: _import),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text('关于'),
        Card(child: Padding(padding: const EdgeInsets.all(16), child: const Text('Remember 记账 v1.0\n数据仅保存在本机，不上传服务器。Android 可开启支付通知自动记录功能。'))),
      ],
    );
  }
}
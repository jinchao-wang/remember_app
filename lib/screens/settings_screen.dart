import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import '../services/app_state.dart';
import '../models/transaction.dart';
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
    final csv = tx.isEmpty ? '' : transactionsToCsv(tx);
    final dir = await getApplicationDocumentsDirectory();
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final file = File('${dir.path}/remember_export_$stamp.csv');
    await file.writeAsString(csv);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Exported ${tx.length} records\n${file.path}')));
  }

  Future<void> _import() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['csv']);
    if (res == null || res.files.single.path == null) return;
    final text = await File(res.files.single.path!).readAsString();
    final list = csvToTransactions(text);
    if (list.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No valid data parsed')));
      return;
    }
    await DatabaseHelper.instance.insertAll(list);
    AppState.instance.bump();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Imported ${list.length} records')));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Data Management'),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              ListTile(leading: const Icon(Icons.download), title: const Text('Export CSV'), onTap: _export),
              const Divider(height: 1),
              ListTile(leading: const Icon(Icons.upload), title: const Text('Import CSV'), onTap: _import),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text('About'),
        const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('Remember v1.0\nData stored locally only, not uploaded to any server. Android supports auto-record from payment notifications.'))),
      ],
    );
  }
}

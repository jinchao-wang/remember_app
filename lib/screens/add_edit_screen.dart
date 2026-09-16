import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/transaction.dart';
import '../services/app_state.dart';
import '../services/database.dart';

class AddEditScreen extends StatefulWidget {
  final Transaction? transaction;
  const AddEditScreen({super.key, this.transaction});
  @override
  State<AddEditScreen> createState() => _AddEditScreenState();
}

class _AddEditScreenState extends State<AddEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _amountCtrl;
  late TextEditingController _categoryCtrl;
  late TextEditingController _noteCtrl;
  String _type = 'expense';
  DateTime _date = DateTime.now();

  @override
  void initState() {
    super.initState();
    _amountCtrl = TextEditingController(text: widget.transaction?.amount.toString() ?? '');
    _categoryCtrl = TextEditingController(text: widget.transaction?.category ?? '');
    _noteCtrl = TextEditingController(text: widget.transaction?.note ?? '');
    _type = widget.transaction?.type ?? 'expense';
    _date = widget.transaction?.date ?? DateTime.now();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.transaction != null;
    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? '编辑账单' : '新增账单')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'expense', label: Text('支出')),
                  ButtonSegment(value: 'income', label: Text('收入')),
                ],
                selected: {_type},
                onSelectionChanged: (s) => setState(() => _type = s.first),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '金额', prefixText: '¥ '),
                validator: (v) => v == null || double.tryParse(v) == null || double.parse(v) <= 0 ? '请输入有效金额' : null,
              ),
              TextFormField(
                controller: _categoryCtrl,
                decoration: const InputDecoration(labelText: '分类'),
                validator: (v) => v == null || v.trim().isEmpty ? '分类不能为空' : null,
              ),
              TextFormField(controller: _noteCtrl, decoration: const InputDecoration(labelText: '备注（可选）')),
              const SizedBox(height: 12),
              ListTile(
                title: const Text('日期'),
                subtitle: Text(DateFormat('yyyy-MM-dd HH:mm').format(_date)),
                trailing: const Icon(Icons.calendar_today),
                onTap: _pickDate,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _save,
                child: Text(isEdit ? '保存修改' : '添加账单'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (date != null) {
      final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_date));
      if (time != null) {
        setState(() => _date = DateTime(date.year, date.month, date.day, time.hour, time.minute));
      }
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final amount = double.parse(_amountCtrl.text);
    final newTx = Transaction(
      id: widget.transaction?.id,
      amount: amount,
      type: _type,
      category: _categoryCtrl.text.trim(),
      note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
      date: _date,
      isAuto: widget.transaction?.isAuto ?? false,
      isEdited: true,
      sourceApp: widget.transaction?.sourceApp,
    );
    if (widget.transaction != null) {
      await DatabaseHelper.instance.updateTransaction(newTx);
    } else {
      await DatabaseHelper.instance.insertTransaction(newTx);
    }
    AppState.instance.bump();
    if (mounted) Navigator.pop(context);
  }
}
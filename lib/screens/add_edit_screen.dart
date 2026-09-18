import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/transaction.dart';
import '../services/database.dart';
import '../services/app_state.dart';
import '../models/enums.dart';

class AddEditScreen extends StatefulWidget {
  final Transaction? transaction;

  const AddEditScreen({super.key, this.transaction});

  @override
  State<AddEditScreen> createState() => _AddEditScreenState();
}

class _AddEditScreenState extends State<AddEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();
  DateTime _selectedDate = DateTime.now();
  String _type = 'expense';
  String _category = '餐饮';

  @override
  void initState() {
    super.initState();
    if (widget.transaction != null) {
      _amountController.text = widget.transaction!.amount.toString();
      _noteController.text = widget.transaction!.note ?? '';
      _selectedDate = widget.transaction!.date;
      _type = widget.transaction!.type;
      _category = widget.transaction!.category;
    } else {
      _selectedDate = DateTime.now();
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final amount = double.tryParse(_amountController.text);
    if (amount == null || amount <= 0) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('请输入有效的金额（大于0）')),
      );
      return;
    }

    final newTransaction = Transaction(
      id: widget.transaction?.id,
      amount: amount,
      type: _type,
      category: _category,
      date: _selectedDate,
      note: _noteController.text.trim().isEmpty ? null : _noteController.text.trim(),
      isAuto: widget.transaction?.isAuto ?? false,
      isEdited: widget.transaction?.isEdited ?? false,
      sourceApp: widget.transaction?.sourceApp,
    );

    if (widget.transaction != null) {
      await DatabaseHelper.instance.updateTransaction(newTransaction);
    } else {
      await DatabaseHelper.instance.insertTransaction(newTransaction);
    }
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(widget.transaction != null ? '账单已更新' : '账单已记录'),
        duration: const Duration(seconds: 1),
      ),
    );
    AppState.instance.bump();
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.transaction == null ? '新增账单' : '编辑账单'),
        actions: [
          TextButton(
            onPressed: _save,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: const Text('保存'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '金额',
                  prefixText: '¥ ',
                  border: OutlineInputBorder(),
                  hintText: '请输入金额',
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) return '请输入金额';
                  final amount = double.tryParse(value);
                  if (amount == null || amount <= 0) return '请输入有效的金额（大于0）';
                  return null;
                },
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<String>(
                value: _type,
                items: TransactionType.values.map((t) {
                  return DropdownMenuItem(
                    value: t.value,
                    child: Row(children: [Icon(t.icon, size: 18), const SizedBox(width: 8), Text(t.label)]),
                  );
                }).toList(),
                onChanged: (v) => setState(() => _type = v ?? 'expense'),
                decoration: const InputDecoration(labelText: '类型', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<String>(
                value: _category,
                items: Categories.names().map((c) {
                  return DropdownMenuItem(
                    value: c,
                    child: Row(children: [Icon(Categories.iconOf(c), size: 18), const SizedBox(width: 8), Text(c)]),
                  );
                }).toList(),
                onChanged: (c) => setState(() => _category = c ?? '餐饮'),
                decoration: const InputDecoration(labelText: '分类', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 20),
              ListTile(
                title: const Text('日期'),
                subtitle: Text(DateFormat('yyyy-MM-dd').format(_selectedDate)),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _selectedDate,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2101),
                  );
                  if (picked != null) setState(() => _selectedDate = picked);
                },
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _noteController,
                decoration: const InputDecoration(
                  labelText: '备注',
                  border: OutlineInputBorder(),
                  hintText: '选填',
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
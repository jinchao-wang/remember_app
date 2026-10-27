import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../models/transaction.dart';
import '../services/database.dart';
import '../services/app_state.dart';
import '../models/enums.dart';
import '../theme/app_theme.dart';

class AddEditScreen extends StatefulWidget {
  final Transaction? transaction;

  const AddEditScreen({super.key, this.transaction});

  @override
  State<AddEditScreen> createState() => _AddEditScreenState();
}

class _AddEditScreenState extends State<AddEditScreen> {
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();
  DateTime _selectedDate = DateTime.now();
  String _type = 'expense';
  String _category = '餐饮';

  @override
  void initState() {
    super.initState();
    if (widget.transaction != null) {
      _amountController.text = widget.transaction!.amount.toStringAsFixed(2);
      _noteController.text = widget.transaction!.note ?? '';
      _selectedDate = widget.transaction!.date;
      // 归一化，防止旧脏数据让 DropdownButtonFormField 断言崩溃。
      _type = parseTransactionType(widget.transaction!.type).value;
      final rawCategory = widget.transaction!.category;
      _category = Categories.names().contains(rawCategory) ? rawCategory : '其他';
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

    // 容错解析：容忍 "¥12.50"、" 12.5 " 这类输入法带出的脏值。
    final amount = double.tryParse(
      _amountController.text.trim().replaceAll(RegExp(r'[^0-9.\-]'), ''),
    );
    if (amount == null || amount <= 0 || amount.isNaN || amount.isInfinite) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('请输入有效的金额（大于0）')),
      );
      return;
    }

    final isUpdate = widget.transaction != null;
    final newTransaction = Transaction(
      id: widget.transaction?.id,
      amount: amount,
      type: _type,
      category: _category,
      date: _selectedDate,
      note: _noteController.text.trim().isEmpty ? null : _noteController.text.trim(),
      isAuto: widget.transaction?.isAuto ?? false,
      // 与编辑弹窗保持一致：任何人工修改都标记为已编辑。
      isEdited: isUpdate ? true : false,
      sourceApp: widget.transaction?.sourceApp,
    );

    try {
      if (isUpdate) {
        await DatabaseHelper.instance.updateTransaction(newTransaction);
      } else {
        await DatabaseHelper.instance.insertTransaction(newTransaction);
      }
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('保存失败：$e')));
      return;
    }

    AppState.instance.bump();
    if (!mounted) return;
    HapticFeedback.lightImpact();
    messenger.showSnackBar(
      SnackBar(
        content: Text(isUpdate ? '账单已更新' : '账单已记录'),
        duration: const Duration(seconds: 1),
      ),
    );
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.appColors;
    final scheme = context.scheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.transaction == null ? '新增账单' : '编辑账单'),
        actions: [
          TextButton(
            onPressed: _save,
            style: TextButton.styleFrom(foregroundColor: scheme.primary),
            child: const Text('保存'),
          ),
        ],
      ),
      body: SafeArea(
        // 没有滚动视图时，键盘弹出会直接撑破 Column 导致 RenderFlex 溢出。
        // Scaffold 默认已按键盘高度收缩 body，这里不要再叠加 viewInsets。
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 金额是这一页的主角，给足视觉权重。
              TextField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                autofocus: false,
                style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
                decoration: const InputDecoration(
                  labelText: '金额',
                  prefixText: '¥ ',
                  hintText: '0.00',
                ),
              ),
              const SizedBox(height: 20),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'expense',
                    label: Text('支出'),
                    icon: Icon(Icons.arrow_downward, size: 18),
                  ),
                  ButtonSegment(
                    value: 'income',
                    label: Text('收入'),
                    icon: Icon(Icons.arrow_upward, size: 18),
                  ),
                ],
                selected: {_type},
                onSelectionChanged: (v) {
                  HapticFeedback.selectionClick();
                  setState(() => _type = v.first);
                },
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: WidgetStateProperty.resolveWith((states) {
                    if (!states.contains(WidgetState.selected)) {
                      return scheme.onSurfaceVariant;
                    }
                    return _type == 'income' ? app.income : app.expense;
                  }),
                ),
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<String>(
                value: _category,
                items: Categories.names().map((c) {
                  return DropdownMenuItem(
                    value: c,
                    child: Row(
                      children: [
                        Icon(
                          Categories.iconOf(c),
                          size: 18,
                          color: app.categoryColor(Categories.colorOf(c)),
                        ),
                        const SizedBox(width: 8),
                        Text(c),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (c) => setState(() => _category = c ?? '餐饮'),
                decoration: const InputDecoration(labelText: '分类'),
              ),
              const SizedBox(height: 20),
              InkWell(
                borderRadius: BorderRadius.circular(AppRadius.md),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _selectedDate,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2101),
                  );
                  // await 之后必须确认 State 仍存活，否则 setState 会抛异常。
                  if (!mounted) return;
                  if (picked != null) setState(() => _selectedDate = picked);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.event, size: 20),
                      const SizedBox(width: 12),
                      const Text('日期'),
                      const Spacer(),
                      Text(
                        DateFormat('yyyy年MM月dd日 HH:mm').format(_selectedDate),
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _noteController,
                decoration: const InputDecoration(
                  labelText: '备注',
                  hintText: '选填',
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _save,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: Text(
                    widget.transaction == null ? '记录账单' : '保存修改',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

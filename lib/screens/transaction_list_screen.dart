import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/transaction.dart';
import '../services/database.dart';
import '../services/app_state.dart';
import '../models/enums.dart';

class TransactionListScreen extends StatefulWidget {
  final DateTime? selectedDate;

  const TransactionListScreen({super.key, this.selectedDate});

  @override
  State<TransactionListScreen> createState() => _TransactionListScreenState();
}

class _TransactionListScreenState extends State<TransactionListScreen>
    with AutomaticKeepAliveClientMixin {
  List<Transaction> _list = [];
  bool _loading = true;
  String _filterType = 'all';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    AppState.instance.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final tx = await DatabaseHelper.instance.getTransactions();
    if (!mounted) return;
    setState(() {
      _list = widget.selectedDate != null
          ? tx.where((t) => t.date.year == widget.selectedDate!.year &&
                  t.date.month == widget.selectedDate!.month &&
                  t.date.day == widget.selectedDate!.day)
              .toList()
          : tx;
      _loading = false;
    });
  }

  Future<void> _delete(Transaction t) async {
    final ctx = context;
    final confirm = await showDialog<bool>(
      context: ctx,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除「${t.category} · ¥${t.amount.toStringAsFixed(2)}」这笔账单吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await DatabaseHelper.instance.deleteTransaction(t.id!);
      AppState.instance.bump();
      if (mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('已删除'), duration: Duration(seconds: 1)),
        );
      }
    }
  }

  List<Transaction> get _filteredList {
    if (_filterType == 'all') return _list;
    return _list.where((t) => t.type == _filterType).toList();
  }

  Color _categoryColor(String category) {
    return Colors.primaries[category.hashCode.abs() % Colors.primaries.length];
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _reload,
        child: Column(
          children: [
            _buildFilterBar(),
            if (_filteredList.isEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.receipt_long_outlined, size: 64, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text(
                        _list.isEmpty ? '还没有账单记录\n点右下角 + 记一笔' : '该分类暂无记录',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey[500], fontSize: 16),
                      ),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _filteredList.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final t = _filteredList[i];
                  return Dismissible(
                    key: Key('${t.id}-${t.date.millisecondsSinceEpoch}'),
                    direction: DismissDirection.endToStart,
                    confirmDismiss: (_) async {
                      await _delete(t);
                      return false;
                    },
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 24),
                      color: Colors.red,
                      child: const Icon(Icons.delete, color: Colors.white),
                    ),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: _categoryColor(t.category),
                        child: Icon(
                          parseTransactionType(t.type).icon,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      title: Text(
                        t.category,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        '${DateFormat('yyyy-MM-dd').format(t.date)} · ${t.note ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text(
                        '${t.type == 'income' ? '+' : '-'}¥${t.amount.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: t.type == 'income' ? Colors.green : Colors.red,
                        ),
                      ),
                      onTap: () => _showEditSheet(t),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          _filterChip('全部', 'all'),
          const SizedBox(width: 8),
          _filterChip('支出', 'expense'),
          const SizedBox(width: 8),
          _filterChip('收入', 'income'),
        ],
      ),
    );
  }

  Widget _filterChip(String label, String type) {
    final isSelected = _filterType == type;
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) {
        setState(() {
          _filterType = type;
        });
      },
      backgroundColor: Colors.grey[100],
      selectedColor: Theme.of(context).colorScheme.primaryContainer,
      labelStyle: TextStyle(
        color: isSelected
            ? Theme.of(context).colorScheme.onPrimaryContainer
            : Colors.black54,
      ),
    );
  }

  void _showEditSheet(Transaction t) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: _EditBottomSheet(transaction: t),
      ),
    );
  }
}

class _EditBottomSheet extends StatefulWidget {
  final Transaction transaction;

  const _EditBottomSheet({required this.transaction});

  @override
  State<_EditBottomSheet> createState() => _EditBottomSheetState();
}

class _EditBottomSheetState extends State<_EditBottomSheet> {
  late final TextEditingController _amountController;
  late final TextEditingController _noteController;
  DateTime _date = DateTime.now();
  String _type = 'expense';
  String _category = '餐饮';

  @override
  void initState() {
    super.initState();
    _amountController = TextEditingController(text: widget.transaction.amount.toString());
    _noteController = TextEditingController(text: widget.transaction.note ?? '');
    _date = widget.transaction.date;
    _type = widget.transaction.type;
    _category = widget.transaction.category;
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
        const SnackBar(content: Text('请输入有效的金额')),
      );
      return;
    }

    final updated = widget.transaction.copyWith(
      amount: amount,
      type: _type,
      category: _category,
      note: _noteController.text.trim().isEmpty ? null : _noteController.text.trim(),
      date: _date,
      isEdited: true,
    );

    await DatabaseHelper.instance.updateTransaction(updated);
    AppState.instance.bump();
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('账单已更新'), duration: Duration(seconds: 1)),
    );
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text('编辑账单', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 24),
          TextField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '金额',
              prefixText: '¥ ',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: _type,
            items: TransactionType.values.map((t) {
              return DropdownMenuItem(
                value: t.value,
                child: Row(
                  children: [
                    Icon(t.icon, size: 18),
                    const SizedBox(width: 8),
                    Text(t.label),
                  ],
                ),
              );
            }).toList(),
            onChanged: (v) => setState(() => _type = v ?? 'expense'),
            decoration: const InputDecoration(labelText: '类型', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: _category,
            items: Categories.names().map((c) {
              return DropdownMenuItem(
                value: c,
                child: Row(
                  children: [
                    Icon(Categories.iconOf(c), size: 18),
                    const SizedBox(width: 8),
                    Text(c),
                  ],
                ),
              );
            }).toList(),
            onChanged: (c) => setState(() => _category = c ?? '餐饮'),
            decoration: const InputDecoration(labelText: '分类', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          ListTile(
            title: const Text('日期'),
            trailing: Text(DateFormat('yyyy-MM-dd').format(_date)),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime(2000),
                lastDate: DateTime(2101),
              );
              if (picked != null) setState(() => _date = picked);
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _noteController,
            decoration: const InputDecoration(labelText: '备注', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _save,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: const Text('保存', style: TextStyle(fontSize: 16)),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

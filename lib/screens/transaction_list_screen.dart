import 'package:flutter/material.dart';
import '../models/transaction.dart';
import '../services/app_state.dart';
import '../services/database.dart';
import 'add_edit_screen.dart';

class TransactionListScreen extends StatefulWidget {
  const TransactionListScreen({super.key});
  @override
  State<TransactionListScreen> createState() => _TransactionListScreenState();
}

class _TransactionListScreenState extends State<TransactionListScreen> {
  List<Transaction> _items = [];
  bool _loading = true;

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
    final list = await DatabaseHelper.instance.getTransactions();
    if (!mounted) return;
    setState(() {
      _items = list;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return const Center(
          child: Text('还没有账单\n点击右下角 + 记一笔', textAlign: TextAlign.center));
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final t = _items[i];
          final color = t.type == 'expense' ? Colors.red : Colors.green;
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.12),
              child: Icon(
                t.type == 'expense' ? Icons.arrow_upward : Icons.arrow_downward,
                color: color,
              ),
            ),
            title: Text(t.category),
            subtitle: Text(
                '${t.date.year}-${t.date.month.toString().padLeft(2, '0')}-${t.date.day.toString().padLeft(2, '0')} ${t.date.hour.toString().padLeft(2, '0')}:${t.date.minute.toString().padLeft(2, '0')}  ${t.note ?? ''}'),
            trailing: Text(
              '${t.type == 'expense' ? '-' : '+'}${t.amount.toStringAsFixed(2)}',
              style: TextStyle(color: color, fontWeight: FontWeight.bold),
            ),
            onTap: () async {
              await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => AddEditScreen(transaction: t)));
              _reload();
            },
            onLongPress: () => _confirmDelete(t),
          );
        },
      ),
    );
  }

  void _confirmDelete(Transaction t) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除账单'),
        content:
            Text('确定删除 ${t.category} ${t.amount.toStringAsFixed(2)} 吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    ).then((ok) async {
      if (ok == true) {
        await DatabaseHelper.instance.deleteTransaction(t.id!);
        AppState.instance.bump();
      }
    });
  }
}

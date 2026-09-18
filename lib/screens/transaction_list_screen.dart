import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/transaction.dart';
import '../services/database.dart';
import '../services/app_state.dart';

class TransactionListScreen extends StatefulWidget {
  const TransactionListScreen({super.key});
  @override
  State<TransactionListScreen> createState() => _TransactionListScreenState();
}

class _TransactionListScreenState extends State<TransactionListScreen> {
  List<Transaction> _list = [];
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
    final tx = await DatabaseHelper.instance.getTransactions();
    if (!mounted) return;
    setState(() {
      _list = tx;
      _loading = false;
    });
  }

  Future<void> _delete(Transaction t) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Transaction'),
        content: Text('Delete ${t.category} ${t.amount.toStringAsFixed(2)}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirm == true) {
      await DatabaseHelper.instance.deleteTransaction(t.id!);
      AppState.instance.bump();
    }
  }

  Color _getColor(Transaction t) {
    final colors = Colors.primaries;
    final idx = t.category.hashCode.abs() % colors.length;
    return colors[idx].withOpacity(0.8);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _list.length,
      separatorBuilder: (_, __) => const Divider(),
      itemBuilder: (ctx, i) {
        final t = _list[i];
        final color = _getColor(t);
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: color,
            child: const Icon(Icons.money, color: Colors.white),
          ),
          title: Text('${t.category}'),
          subtitle: Text('${t.date.toString().split(' ').first} • ${t.note}'),
          trailing: Text(
            '${t.type == 'income' ? '+' : '-'}\$${t.amount.toStringAsFixed(2)}',
            style: TextStyle(
                fontWeight: FontWeight.bold, color: t.type == 'income' ? Colors.green : Colors.red),
          ),
          onLongPress: () => _delete(t),
        );
      },
    );
  }
}

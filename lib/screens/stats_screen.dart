import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/transaction.dart';
import '../services/app_state.dart';
import '../services/database.dart';

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});
  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  List<Transaction> _all = [];
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
      _all = list;
      _loading = false;
    });
  }

  double _sum(List<Transaction> list, String type) => list.where((t) => t.type == type).fold(0, (a, b) => a + b.amount);

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final now = DateTime.now();
    final monthTx = _all.where((t) => t.date.year == now.year && t.date.month == now.month).toList();
    final dayTx = _all.where((t) => t.date.year == now.year && t.date.month == now.month && t.date.day == now.day).toList();
    final monthExpense = _sum(monthTx, 'expense');
    final monthIncome = _sum(monthTx, 'income');
    final dayExpense = _sum(dayTx, 'expense');
    final dayIncome = _sum(dayTx, 'income');

    final catExpense = <String, double>{};
    for (final t in monthTx.where((t) => t.type == 'expense')) {
      catExpense[t.category] = (catExpense[t.category] ?? 0) + t.amount;
    }
    final pieSections = catExpense.entries.map((e) => PieChartSectionData(value: e.value, title: e.key, color: Colors.primaries[catExpense.keys.toList().indexOf(e.key) % Colors.primaries.length])).toList();

    final days = now.day;
    final lineSpots = List<FlSpot>.generate(days, (i) {
      final day = i + 1;
      final sum = _sum(monthTx.where((t) => t.date.day == day).toList(), 'expense');
      return FlSpot(i.toDouble(), sum);
    });
    final maxY = (lineSpots.map((s) => s.y).fold<double>(0, (a, b) => a > b ? a : b) * 1.2 + 1);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('本月概览'),
          const SizedBox(height: 8),
          Text('支出 ¥${monthExpense.toStringAsFixed(2)}  ·  收入 ¥${monthIncome.toStringAsFixed(2)}'),
          const SizedBox(height: 4),
          Text('今日支出 ¥${dayExpense.toStringAsFixed(2)}  ·  今日收入 ¥${dayIncome.toStringAsFixed(2)}', style: const TextStyle(color: Colors.grey)),
        ]))),
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('分类占比（本月支出）'),
          const SizedBox(height: 8),
          pieSections.isEmpty ? const Text('暂无数据') : SizedBox(height: 220, child: PieChart(PieChartData(sections: pieSections))),
        ]))),
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('支出趋势（近30天日度）'),
          const SizedBox(height: 8),
          lineSpots.isEmpty ? const Text('暂无数据') : SizedBox(height: 220, child: LineChart(LineChartData(
            minX: 0,
            maxX: (lineSpots.length - 1).toDouble(),
            minY: 0,
            maxY: maxY.isNaN ? 1 : maxY,
            lineBarsData: [
              LineChartBarData(
                spots: lineSpots,
                isCurved: true,
                color: Theme.of(context).colorScheme.primary,
                barWidth: 2,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(show: true, color: Theme.of(context).colorScheme.primary.withOpacity(0.1)),
              )
            ],
          ))),
        ]))),
      ],
    );
  }
}
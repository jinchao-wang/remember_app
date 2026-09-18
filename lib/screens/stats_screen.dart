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

class _StatsScreenState extends State<StatsScreen> with AutomaticKeepAliveClientMixin {
  List<Transaction> _all = [];
  bool _loading = true;
  DateTime _selectedMonth = DateTime.now();

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
    final list = await DatabaseHelper.instance.getTransactions();
    if (!mounted) return;
    setState(() {
      _all = list;
      _loading = false;
    });
  }

  double _sum(List<Transaction> list, String type) =>
      list.where((t) => t.type == type).fold(0.0, (a, b) => a + b.amount);

  String _fmt(double v) => '¥${v.toStringAsFixed(2)}';

  List<Transaction> _monthTx() {
    return _all
        .where((t) => t.date.year == _selectedMonth.year && t.date.month == _selectedMonth.month)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final monthTx = _monthTx();
    final monthExpense = _sum(monthTx, 'expense');
    final monthIncome = _sum(monthTx, 'income');

    final now = DateTime.now();
    final dayTx = _all.where((t) =>
        t.date.year == now.year &&
        t.date.month == now.month &&
        t.date.day == now.day).toList();
    final dayExpense = _sum(dayTx, 'expense');
    final dayIncome = _sum(dayTx, 'income');

    final catExpense = <String, double>{};
    for (final t in monthTx.where((t) => t.type == 'expense')) {
      catExpense[t.category] = (catExpense[t.category] ?? 0) + t.amount;
    }

    final daysInMonth = DateTime(_selectedMonth.year, _selectedMonth.month + 1, 0).day;
    final lineSpots = List<FlSpot>.generate(daysInMonth, (i) {
      final day = i + 1;
      final sum = _sum(
        monthTx.where((t) => t.date.day == day).toList(),
        'expense',
      );
      return FlSpot(i.toDouble(), sum);
    });
    final maxY = lineSpots.fold<double>(0.0, (a, b) => a > b.y ? a : b.y);
    final yMax = maxY == 0 ? 10.0 : maxY * 1.3 + 1.0;

    return Column(
      children: [
        _buildMonthHeader(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildOverviewCard(monthExpense, monthIncome, dayExpense, dayIncome),
              const SizedBox(height: 16),
              _buildCategoryPieCard(catExpense),
              const SizedBox(height: 16),
              _buildTrendCard(lineSpots, yMax, daysInMonth),
              const SizedBox(height: 80),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMonthHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () {
              setState(() {
                _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month - 1);
              });
              _reload();
            },
            icon: const Icon(Icons.chevron_left),
          ),
          Text(
            '${_selectedMonth.year}年${_selectedMonth.month}月',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
          IconButton(
            onPressed: () {
              setState(() {
                _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month + 1);
              });
              _reload();
            },
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }

  Widget _buildOverviewCard(double monthExpense, double monthIncome, double dayExpense, double dayIncome) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '月度概览',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _summaryTile(
                    label: '本月支出',
                    value: _fmt(monthExpense),
                    color: Colors.red,
                    icon: Icons.arrow_downward,
                  ),
                ),
                Container(width: 1, height: 40, color: Colors.grey[300]),
                Expanded(
                  child: _summaryTile(
                    label: '本月收入',
                    value: _fmt(monthIncome),
                    color: Colors.green,
                    icon: Icons.arrow_upward,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _summaryTile(
                    label: '今日支出',
                    value: _fmt(dayExpense),
                    color: Colors.red,
                    icon: Icons.arrow_downward,
                  ),
                ),
                Container(width: 1, height: 40, color: Colors.grey[300]),
                Expanded(
                  child: _summaryTile(
                    label: '今日收入',
                    value: _fmt(dayIncome),
                    color: Colors.green,
                    icon: Icons.arrow_upward,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryTile({required String label, required String value, required Color color, required IconData icon}) {
    return Column(
      children: [
        Row(children: [Icon(icon, size: 16, color: color), const SizedBox(width: 4), Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 12))]),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: color)),
      ],
    );
  }

  Widget _buildCategoryPieCard(Map<String, double> catExpense) {
    final total = catExpense.values.fold<double>(0, (a, b) => a + b);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '支出分类占比（本月）',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            if (total == 0)
              const Center(child: Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Text('暂无数据', style: TextStyle(color: Colors.grey)),
              ))
            else
              Column(
                children: [
                  SizedBox(
                    height: 220,
                    child: PieChart(_buildPieData(catExpense)),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    children: catExpense.entries.map((e) {
                      final pct = (e.value / total * 100).toStringAsFixed(1);
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: Colors.primaries[
                                  catExpense.keys.toList().indexOf(e.key) %
                                      Colors.primaries.length],
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('${e.key} ${_fmt(e.value)} ($pct%)',
                              style: const TextStyle(fontSize: 12)),
                        ],
                      );
                    }).toList(),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  PieChartData _buildPieData(Map<String, double> catExpense) {
    final categories = catExpense.keys.toList();
    final sections = catExpense.entries.map((e) {
      final idx = categories.indexOf(e.key);
      return PieChartSectionData(
        value: e.value,
        title: '${(e.value / catExpense.values.fold<double>(0, (a, b) => a + b) * 100).toStringAsFixed(0)}%',
        color: Colors.primaries[idx % Colors.primaries.length],
        radius: 70,
        titleStyle: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w500),
      );
    }).toList();
    return PieChartData(sections: sections, centerSpaceRadius: 0, borderData: FlBorderData(show: false));
  }

  Widget _buildTrendCard(List<FlSpot> lineSpots, double maxY, int daysInMonth) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '本月每日支出',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 220,
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: (lineSpots.length - 1).toDouble(),
                  minY: 0,
                  maxY: maxY,
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipColor: (touchedSpot) => Colors.blueGrey,
                      getTooltipItems: (spots) => spots.map((s) {
                        return LineTooltipItem(
                          '${s.x.toInt() + 1}日\n${_fmt(s.y)}',
                          const TextStyle(color: Colors.white, fontSize: 11),
                        );
                      }).toList(),
                    ),
                  ),
                  titlesData: FlTitlesData(
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: true, interval: 5),
                    ),
                    topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: maxY > 100 ? 50 : (maxY > 10 ? 10 : 2),
                        reservedSize: 50,
                      ),
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: lineSpots,
                      isCurved: true,
                      color: Theme.of(context).colorScheme.primary,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                      ),
                    )
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
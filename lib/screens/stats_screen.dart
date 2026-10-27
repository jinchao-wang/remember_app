import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/enums.dart';
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

  /// 选一个「好看」的刻度间隔：把目标格数压到 1/2/5 × 10^n，
  /// 避免旧实现 maxY>100 就固定 50 导致的刻度过密或过疏。
  static double _niceInterval(double maxY) {
    if (maxY <= 0) return 2;
    final target = maxY / 5;
    final pow = math.pow(10, (math.log(target) / math.ln10).floor()).toDouble();
    if (!pow.isFinite || pow <= 0) return 2;
    final norm = target / pow;
    final step = norm <= 1 ? 1.0 : (norm <= 2 ? 2.0 : (norm <= 5 ? 5.0 : 10.0));
    return step * pow;
  }

  List<Transaction> _monthTx() {
    final y = _selectedMonth.year;
    final m = _selectedMonth.month;
    return _all.where((t) => t.date.year == y && t.date.month == m).toList();
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
    for (final t in monthTx) {
      if (t.type == 'expense') {
        catExpense[t.category] = (catExpense[t.category] ?? 0) + t.amount;
      }
    }
    // 按金额降序，让饼图扇区顺序与图例顺序一致。
    final catKeys = catExpense.keys.toList()
      ..sort((a, b) => catExpense[b]!.compareTo(catExpense[a]!));
    // 分类配色和账单页用同一张表：
    // 用户在账单页认过的颜色，到统计页还是那个颜色。
    final catColors = catKeys.map(Categories.colorOf).toList();

    // 一次遍历按天汇总。旧实现为每一天重新过滤整月账单，
    // 复杂度是 O(天数 × 笔数) 且每次都会分配一个临时 List。
    final daysInMonth =
        DateTime(_selectedMonth.year, _selectedMonth.month + 1, 0).day;
    final dailyExpense = List<double>.filled(daysInMonth, 0);
    for (final t in monthTx) {
      if (t.type != 'expense') continue;
      final idx = t.date.day - 1;
      if (idx >= 0 && idx < daysInMonth) dailyExpense[idx] += t.amount;
    }
    final lineSpots = <FlSpot>[
      for (var i = 0; i < daysInMonth; i++) FlSpot(i.toDouble(), dailyExpense[i]),
    ];
    final maxY = dailyExpense.fold<double>(0.0, (a, b) => a > b ? a : b);
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
              _buildCategoryPieCard(catExpense, catKeys, catColors),
              const SizedBox(height: 16),
              _buildTrendCard(lineSpots, yMax),
              const SizedBox(height: 80),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMonthHeader() {
    // 以前用 primaryContainer 铺满整条，M3 的绿色容器色又亮又刺眼。
    // 改成白底 + 底部细线，月份切换只是辅助信息，不该抢视觉焦点。
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () {
              // _monthTx() 已经基于 _selectedMonth 过滤 _all，
              // 这里无需再全表查询一次。
              setState(() {
                _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month - 1);
              });
            },
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: Text(
              '${_selectedMonth.year}年${_selectedMonth.month}月',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
            ),
          ),
          IconButton(
            onPressed: () {
              setState(() {
                _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month + 1);
              });
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

  Widget _buildCategoryPieCard(
    Map<String, double> catExpense,
    List<String> catKeys,
    List<Color> catColors,
  ) {
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
            else ...[
              SizedBox(
                height: 200,
                child: PieChart(_buildPieData(catExpense, catKeys, catColors)),
              ),
              const SizedBox(height: 20),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Text(
                '分类排行',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                '按金额从多到少，一眼看出钱花在哪了',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              const SizedBox(height: 12),
              ...List.generate(catKeys.length, (i) {
                final key = catKeys[i];
                final value = catExpense[key]!;
                final pct = value / total;
                return _buildRankRow(key, value, pct, catColors[i]);
              }),
            ],
          ],
        ),
      ),
    );
  }

  /// 分类排行的一行：色点 + 分类名 + 金额 + 百分比 + 占比条。
  ///
  /// 以前图例是一堆挤在一起的文字，金额一多就排得乱七八糟，
  /// 也没法快速比较「哪个花得多」——排行条直接回答这个问题。
  Widget _buildRankRow(String category, double value, double pct, Color color) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                category,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Text(
                '${(pct * 100).toStringAsFixed(1)}%',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              const Spacer(),
              Text(
                _fmt(value),
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 5,
              backgroundColor: scheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      ),
    );
  }

  PieChartData _buildPieData(
    Map<String, double> catExpense,
    List<String> catKeys,
    List<Color> catColors,
  ) {
    // 总计只算一次：旧实现放在 map 内部，每个扇区都重新 fold 一遍。
    final total = catExpense.values.fold<double>(0, (a, b) => a + b);
    final sections = <PieChartSectionData>[
      for (var i = 0; i < catKeys.length; i++)
        PieChartSectionData(
          value: catExpense[catKeys[i]]!,
          title: total == 0
              ? ''
              : '${(catExpense[catKeys[i]]! / total * 100).toStringAsFixed(0)}%',
          color: catColors[i],
          radius: 70,
          titleStyle: const TextStyle(
              fontSize: 11, color: Colors.white, fontWeight: FontWeight.w500),
        ),
    ];
    return PieChartData(
        sections: sections, centerSpaceRadius: 0, borderData: FlBorderData(show: false));
  }

  Widget _buildTrendCard(List<FlSpot> lineSpots, double maxY) {
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
                        interval: _niceInterval(maxY),
                        reservedSize: 46,
                      ),
                    ),
                  ),
                  // 默认的网格线是一格一格的方格纸，视觉噪音很大。
                  // 只留淡淡的横线，纵向一律不画。
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: _niceInterval(maxY),
                    getDrawingHorizontalLine: (v) => FlLine(
                      color: Theme.of(context)
                          .colorScheme
                          .outlineVariant
                          .withOpacity(0.5),
                      strokeWidth: 1,
                    ),
                  ),
                  borderData: FlBorderData(show: false),
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
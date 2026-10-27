import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models/enums.dart';
import '../models/transaction.dart';
import '../services/app_state.dart';
import '../services/database.dart';
import '../theme/app_theme.dart';
import '../utils/source_role.dart';

/// 账单列表页。
///
/// 三个方向一起做的：
///
/// **排版**（好看）
/// - 按日期分组，组头直接写「今天 · 支出 ¥88.00」；
/// - 概览卡与列表口径一致——卡片上的数字就是下面这份数据的数字；
/// - 图标表示分类，金额的绿/红表示收支，语义不再自相矛盾；
/// - 副标题是「来源 · 摘要」，不是整句通知原文。
///
/// **手感**（顺手）
/// - 左滑删除（真的删，带撤销），右滑编辑；
/// - 筛选 chip 选中有轻微震动；
/// - 搜索输入做了防抖，边打字边出结果不会卡。
///
/// **流畅**（不卡）
/// - 旧实现把所有行一次性塞进 `ListView(children:)`，账单一多就开始掉帧；
///   现在展平成行列表 + `ListView.builder`，只构建看得见的那些。
/// - 筛选 / 分组 / 概览数字都在数据变化时算一次存起来，
///   不再每帧重算三四遍（每遍都做字符串拼接）。
class TransactionListScreen extends StatefulWidget {
  final DateTime? selectedDate;

  const TransactionListScreen({super.key, this.selectedDate});

  @override
  State<TransactionListScreen> createState() => _TransactionListScreenState();
}

class _TransactionListScreenState extends State<TransactionListScreen>
    with AutomaticKeepAliveClientMixin {
  /// 库里全部账单。
  List<Transaction> _list = [];

  /// 库里出现过的分类，按金额从大到小。
  List<String> _categories = [];

  /// 展平后的列表项：日期分组头 or 账单。
  List<_Row> _rows = [];

  /// 概览卡的数字（同样缓存）。
  double _scopeExpense = 0;
  double _scopeIncome = 0;
  double _monthAmount = 0;
  int _scopeCount = 0;

  bool _loading = true;
  String _filterType = 'all';
  String _categoryFilter = 'all';
  String _keyword = '';

  final TextEditingController _searchController = TextEditingController();

  /// 搜索防抖。
  ///
  /// 以前每敲一个字就 setState 一次 → 整个列表重建 → 打字明显发涩。
  /// 现在停下来 140ms 才真的去筛。
  Timer? _searchDebounce;

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
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final tx = await DatabaseHelper.instance.getTransactions();
    if (!mounted) return;
    setState(() {
      _list = widget.selectedDate != null
          ? tx.where((t) => _isSameDay(t, widget.selectedDate!)).toList()
          : tx;
      _loading = false;
      _recompute();
    });
  }

  bool _isSameDay(Transaction t, DateTime date) =>
      t.date.year == date.year &&
      t.date.month == date.month &&
      t.date.day == date.day;

  /// 一次遍历算出所有派生数据。
  ///
  /// 以前 `_filteredList` / `_categories` / `_grouped` 是三个 getter，
  /// 每帧被调用三四遍，每遍都是一次全表过滤 + 字符串拼接。
  /// 现在数据或筛选条件变了才算一次。
  void _recompute() {
    final kw = _keyword.trim().toLowerCase();
    final filtered = <Transaction>[];
    final catTotals = <String, double>{};

    for (final t in _list) {
      if (_filterType != 'all' && t.type != _filterType) continue;
      if (_categoryFilter != 'all' && t.category != _categoryFilter) continue;
      if (kw.isNotEmpty) {
        final haystack = '${t.category} ${t.note ?? ''} ${t.amount}'.toLowerCase();
        if (!haystack.contains(kw)) continue;
      }
      filtered.add(t);
      catTotals[t.category] = (catTotals[t.category] ?? 0) + t.amount;
    }

    _categories = catTotals.keys.toList()
      ..sort((a, b) => catTotals[b]!.compareTo(catTotals[a]!));

    // 按天分组，组内保持库里的日期倒序。
    final groups = <DateTime, List<Transaction>>{};
    for (final t in filtered) {
      final key = DateTime(t.date.year, t.date.month, t.date.day);
      groups.putIfAbsent(key, () => []).add(t);
    }
    final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));

    final rows = <_Row>[];
    for (final day in days) {
      final items = groups[day]!;
      rows.add(_Row.header(
        day,
        items.length,
        _sum(items, 'expense'),
        _sum(items, 'income'),
      ));
      for (final t in items) {
        rows.add(_Row.item(t));
      }
    }
    _rows = rows;

    // 概览卡的大数字：当前筛选 ∩ 选中日期范围。
    // 没选日期就只看今天。
    final now = DateTime.now();
    var expense = 0.0;
    var income = 0.0;
    var count = 0;
    for (final t in filtered) {
      if (widget.selectedDate == null && !_isSameDay(t, now)) continue;
      count++;
      if (t.type == 'income') {
        income += t.amount;
      } else {
        expense += t.amount;
      }
    }
    _scopeExpense = expense;
    _scopeIncome = income;
    _scopeCount = count;

    // 本月数字也跟着筛选走，卡片上几个数字口径才一致。
    // 选了具体某天时大数字本身就是那天，这个数没有意义，不显示。
    var month = 0.0;
    if (widget.selectedDate == null) {
      final monthType = _filterType == 'income' ? 'income' : 'expense';
      for (final t in _list) {
        if (t.type != monthType) continue;
        if (t.date.year != now.year || t.date.month != now.month) continue;
        if (_categoryFilter != 'all' && t.category != _categoryFilter) continue;
        if (kw.isNotEmpty) {
          final haystack = '${t.category} ${t.note ?? ''} ${t.amount}'.toLowerCase();
          if (!haystack.contains(kw)) continue;
        }
        month += t.amount;
      }
    }
    _monthAmount = month;
  }

  double _sum(List<Transaction> list, String type) =>
      list.where((t) => t.type == type).fold(0.0, (a, b) => a + b.amount);

  // ------------------------------------------------------------------ 筛选

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 140), () {
      if (!mounted) return;
      setState(() {
        _keyword = value;
        _recompute();
      });
    });
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() {
      _keyword = '';
      _recompute();
    });
  }

  void _setTypeFilter(String type) {
    if (_filterType == type) return;
    HapticFeedback.selectionClick();
    setState(() {
      _filterType = type;
      _recompute();
    });
  }

  void _setCategoryFilter(String category) {
    if (_categoryFilter == category) return;
    HapticFeedback.selectionClick();
    setState(() {
      _categoryFilter = category;
      _recompute();
    });
  }

  void _clearFilters() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() {
      _keyword = '';
      _filterType = 'all';
      _categoryFilter = 'all';
      _recompute();
    });
  }

  // ------------------------------------------------------------------ 删除

  /// 滑动删除：真的删掉，并且给一个「撤销」。
  Future<void> _deleteAndOfferUndo(Transaction t) async {
    final id = t.id;
    if (id == null) return;
    final messenger = ScaffoldMessenger.of(context);
    await DatabaseHelper.instance.deleteTransaction(id);
    AppState.instance.bump();
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('已删除「${t.category} · ¥${t.amount.toStringAsFixed(2)}」'),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () async {
              await DatabaseHelper.instance.restoreTransaction(t);
              AppState.instance.bump();
            },
          ),
        ),
      );
  }

  /// 长按 / 菜单里的删除，走确认框。
  Future<void> _deleteWithConfirm(Transaction t) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这笔账单？'),
        content: Text(
          '「${t.category} · ¥${t.amount.toStringAsFixed(2)}」删除后无法恢复，'
          '但可以立刻撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: context.appColors.expense,
              foregroundColor: Colors.white,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _deleteAndOfferUndo(t);
  }

  // ------------------------------------------------------------------ 概览

  /// 概览大数字的口径说明。
  ///
  /// 以前不管有没有筛选都写「今天支出」，用户按「餐饮」筛完看到
  /// 「今天支出 ¥58.80」会以为今天只花了 58.80，其实那只是餐饮那一部分。
  /// 现在把筛选条件写进标签里。
  String get _scopeLabel {
    final time = widget.selectedDate != null ? _dayLabel(_summaryDate) : '今天';
    final kind = _filterType == 'income' ? '收入' : '支出';
    final qualifier = _categoryFilter != 'all'
        ? _categoryFilter
        : (_keyword.isNotEmpty ? '「$_keyword」' : '');
    return qualifier.isEmpty ? '$time$kind' : '$time$qualifier$kind';
  }

  DateTime get _summaryDate => widget.selectedDate ?? DateTime.now();

  Widget _buildOverviewCard() {
    final scheme = context.scheme;
    final app = context.appColors;
    final big = _filterType == 'income' ? _scopeIncome : _scopeExpense;

    return RepaintBoundary(
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              scheme.primary,
              Color.lerp(scheme.primary, scheme.tertiary, 0.45)!,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(AppRadius.xl),
          boxShadow: [
            BoxShadow(
              color: scheme.primary.withOpacity(0.28),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Stack(
          children: [
            // 右上角一团柔光，给卡片一点纵深。
            // 用径向渐变而不是实心圆——实心圆的边缘会有一道硬边，
            // 看着像渲染瑕疵，不像装饰。
            Positioned(
              right: -60,
              top: -80,
              child: Container(
                width: 190,
                height: 190,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Colors.white.withOpacity(0.13),
                      Colors.white.withOpacity(0.0),
                    ],
                  ),
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _scopeLabel,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.85),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 金额可能很长（「本月支出 ¥123456.78」），窄屏上要能省略，
                    // 不能把左边挤出去。
                    if (widget.selectedDate == null)
                      Flexible(
                        child: Text(
                          '${_filterType == 'income' ? '本月收入' : '本月支出'} '
                          '¥${_monthAmount.toStringAsFixed(2)}',
                          textAlign: TextAlign.right,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.8),
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                // 金额用等宽数字，位数变化时不会左右跳。
                Text(
                  '¥${big.toStringAsFixed(2)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    height: 1.05,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (_scopeExpense > 0)
                      _moneyChip(Icons.south_rounded, _scopeExpense, app.expense),
                    if (_scopeExpense > 0 && _scopeIncome > 0)
                      const SizedBox(width: 8),
                    if (_scopeIncome > 0)
                      _moneyChip(Icons.north_rounded, _scopeIncome, app.income),
                    const Spacer(),
                    Text(
                      '$_scopeCount 笔',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.9),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _moneyChip(IconData icon, double amount, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.18),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 卡片本身是绿色渐变，chip 里再用红/绿会跟底色打架，
          // 统一用白色，靠箭头方向区分收支。
          Icon(icon, size: 14, color: Colors.white.withOpacity(0.92)),
          const SizedBox(width: 4),
          Text(
            '¥${amount.toStringAsFixed(2)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 筛选栏

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: TextField(
        controller: _searchController,
        onChanged: _onSearchChanged,
        onSubmitted: (v) {
          _searchDebounce?.cancel();
          setState(() {
            _keyword = v;
            _recompute();
          });
        },
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: '搜索分类、备注或金额',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _keyword.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: '清除',
                  onPressed: _clearSearch,
                ),
        ),
      ),
    );
  }

  Widget _buildFilterBar() {
    final cats = _categories;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Row(
            children: [
              _typeChip('全部', 'all'),
              const SizedBox(width: 8),
              _typeChip('支出', 'expense'),
              const SizedBox(width: 8),
              _typeChip('收入', 'income'),
              const Spacer(),
              if (_filterType != 'all' || _categoryFilter != 'all')
                TextButton.icon(
                  onPressed: _clearFilters,
                  icon: const Icon(Icons.filter_alt_off, size: 16),
                  label: const Text('重置'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        if (cats.length > 1) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 32,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: cats.length + 1,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _categoryChip('全部分类', 'all', null);
                }
                final c = cats[index - 1];
                return _categoryChip(c, c, Categories.colorOf(c));
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _typeChip(String label, String type) {
    final selected = _filterType == type;
    final scheme = context.scheme;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => _setTypeFilter(type),
      selectedColor: scheme.primaryContainer,
      backgroundColor: context.appColors.neutralContainer,
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
      ),
    );
  }

  Widget _categoryChip(String label, String value, Color? color) {
    final selected = _categoryFilter == value;
    final scheme = context.scheme;
    final dot = color == null ? null : context.appColors.categoryColor(color);
    return FilterChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Text(label),
        ],
      ),
      selected: selected,
      onSelected: (_) => _setCategoryFilter(value),
      selectedColor: scheme.primaryContainer,
      backgroundColor: context.appColors.neutralContainer,
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
      ),
    );
  }

  // ------------------------------------------------------------------ 列表

  /// 「今天 / 昨天 / 前天 / 周三 / 10月20日」。
  String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(day.year, day.month, day.day);
    final diff = today.difference(target).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    if (diff == 2) return '前天';
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final weekday = '周${weekdays[day.weekday - 1]}';
    if (diff < 7) return weekday;
    if (day.year == now.year) {
      return '${day.month}月${day.day}日 $weekday';
    }
    return '${day.year}年${day.month}月${day.day}日';
  }

  Widget _buildDayHeader(_Row row) {
    final app = context.appColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      child: Row(
        children: [
          Text(
            _dayLabel(row.day!),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 8),
          Text(
            '${row.count} 笔',
            style: TextStyle(fontSize: 12, color: context.scheme.onSurfaceVariant),
          ),
          const Spacer(),
          if (row.expense > 0)
            Text(
              '支出 ¥${row.expense.toStringAsFixed(2)}',
              style: TextStyle(
                fontSize: 12,
                color: app.expense,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          if (row.income > 0) ...[
            const SizedBox(width: 8),
            Text(
              '收入 ¥${row.income.toStringAsFixed(2)}',
              style: TextStyle(
                fontSize: 12,
                color: app.income,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTransactionItem(Transaction t) {
    final app = context.appColors;
    final base = Categories.colorOf(t.category);
    final color = app.categoryColor(base);
    final subtitle = _sourceLabel(t);
    final isIncome = t.type == 'income';

    return Dismissible(
      key: ValueKey('tx-${t.id}'),
      direction: DismissDirection.horizontal,
      // 左滑删除、右滑编辑。
      // 旧实现这里永远返回 false，划完弹回原位——看着像坏了。
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          HapticFeedback.lightImpact();
          _showEditSheet(t);
          return false;
        }
        return true;
      },
      onDismissed: (_) {
        // 先从本地列表摘掉，否则 Dismissible 下一帧还在树里会断言。
        setState(() {
          _list.removeWhere((x) => x.id == t.id);
          _recompute();
        });
        _deleteAndOfferUndo(t);
      },
      // 右滑时露出左边：编辑。
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 24),
        color: app.income,
        child: const Icon(Icons.edit, color: Colors.white),
      ),
      // 左滑时露出右边：删除。
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: app.expense,
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      child: Column(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            leading: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withOpacity(0.14),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(_categoryIcon(t.category), size: 21, color: color),
            ),
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    t.category,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  DateFormat('HH:mm').format(t.date),
                  style: TextStyle(
                    fontSize: 11,
                    color: context.scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            subtitle: subtitle.isEmpty
                ? null
                : Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.scheme.onSurfaceVariant,
                    ),
                  ),
            trailing: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: isIncome ? '+' : '-',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: isIncome ? app.income : app.expense,
                    ),
                  ),
                  TextSpan(
                    text: t.amount.toStringAsFixed(2),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: isIncome ? app.income : app.expense,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            onTap: () => _showEditSheet(t),
            onLongPress: () => _deleteWithConfirm(t),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 74, right: 16),
            child: Divider(
              height: 1,
              color: context.scheme.outlineVariant.withOpacity(0.45),
            ),
          ),
        ],
      ),
    );
  }

  /// 分类图标。分类没对上时退回「其他」的图标。
  IconData _categoryIcon(String category) =>
      Categories.all.any((e) => e.keys.first == category)
          ? Categories.iconOf(category)
          : Categories.iconOf('其他');

  /// 通知来源的可读名字。
  ///
  /// 包名对用户没意义，「微信」「招商银行」「短信」才认得出。
  /// 认不出来就返回空——总比显示 `com.some.app` 强。
  ///
  /// 另外：备注往往就是通知原文，本身已经带着来源名
  /// （「微信支付 付款成功 ¥18.80」），再拼一遍就成了
  /// 「微信 · 微信支付 付款成功 ¥18.80」，所以要去重。
  String _sourceLabel(Transaction t) {
    final source = displaySource(t.sourceApp) ?? '';
    final note = t.note ?? '';
    if (source.isEmpty) return note;
    if (note.contains(source)) return note;
    return note.isEmpty ? source : '$source · $note';
  }

  Widget _buildEmptyState() {
    final scheme = context.scheme;
    final noData = _list.isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
      child: Column(
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary.withOpacity(0.07),
            ),
            child: Icon(
              noData ? Icons.receipt_long_outlined : Icons.search_off,
              size: 44,
              color: scheme.primary.withOpacity(0.45),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            noData ? '还没有账单记录' : '没有匹配的记录',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            noData
                ? '付钱后只要在系统里开启本 App 的「通知使用权」，\n'
                    '支付通知就会自动记成账单；\n'
                    '也可以点右下角 + 手动记一笔。'
                : '换个关键词，或者把筛选条件放宽试试。',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 13,
              height: 1.6,
            ),
          ),
          if (!noData) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _clearFilters,
              icon: const Icon(Icons.filter_alt_off, size: 18),
              label: const Text('清除筛选条件'),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_rows.isEmpty) {
      return RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 8),
          children: [
            _buildOverviewCard(),
            _buildSearchBar(),
            _buildFilterBar(),
            _buildEmptyState(),
          ],
        ),
      );
    }

    // 展平成「行列表」后交给 ListView.builder：
    // 只有看得见的行才会被构建，账单再多也不掉帧。
    final headerCount = 3;
    final total = headerCount + _rows.length;

    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: total,
        itemBuilder: (context, index) {
          if (index == 0) return _buildOverviewCard();
          if (index == 1) return _buildSearchBar();
          if (index == 2) return _buildFilterBar();
          final row = _rows[index - headerCount];
          if (row.isHeader) return _buildDayHeader(row);
          return _buildTransactionItem(row.transaction!);
        },
      ),
    );
  }

  void _showEditSheet(Transaction t) {
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: _EditBottomSheet(
          transaction: t,
          onDelete: () => _deleteAndOfferUndo(t),
        ),
      ),
    );
  }
}

/// 展平后的列表项：要么是日期分组头，要么是一条账单。
class _Row {
  _Row.header(this.day, this.count, this.expense, this.income)
      : transaction = null;
  _Row.item(this.transaction)
      : day = null,
        count = 0,
        expense = 0,
        income = 0;

  final DateTime? day;
  final int count;
  final double expense;
  final double income;
  final Transaction? transaction;

  bool get isHeader => transaction == null;
}

class _EditBottomSheet extends StatefulWidget {
  final Transaction transaction;

  /// 删除这笔账单。传进来是为了复用父级的「删除 + 撤销」逻辑。
  final Future<void> Function() onDelete;

  const _EditBottomSheet({required this.transaction, required this.onDelete});

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
    _amountController =
        TextEditingController(text: widget.transaction.amount.toStringAsFixed(2));
    _noteController = TextEditingController(text: widget.transaction.note ?? '');
    _date = widget.transaction.date;
    // 归一化：DropdownButtonFormField 在当前值不在 items 中时会直接 assert 崩溃，
    // 旧版本导入的脏数据必须在此兜住。
    _type = parseTransactionType(widget.transaction.type).value;
    final rawCategory = widget.transaction.category;
    _category = Categories.names().contains(rawCategory) ? rawCategory : '其他';
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
    final amount = double.tryParse(_amountController.text.trim());
    if (amount == null || amount <= 0) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('请输入有效的金额')),
      );
      return;
    }

    final noteText = _noteController.text.trim();
    final updated = widget.transaction.copyWith(
      amount: amount,
      type: _type,
      category: _category,
      note: noteText,
      clearNote: noteText.isEmpty,
      date: _date,
      isEdited: true,
    );

    try {
      await DatabaseHelper.instance.updateTransaction(updated);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('保存失败：$e')));
      return;
    }
    AppState.instance.bump();
    if (!mounted) return;
    HapticFeedback.lightImpact();
    messenger.showSnackBar(
      const SnackBar(content: Text('账单已更新'), duration: Duration(seconds: 1)),
    );
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.appColors;
    return SingleChildScrollView(
      // 小屏 + 键盘弹出时固定高度会溢出，交给滚动容器处理。
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('编辑账单', style: context.theme.textTheme.titleLarge),
          const SizedBox(height: 20),
          TextField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            autofocus: true,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            decoration: const InputDecoration(
              labelText: '金额',
              prefixText: '¥ ',
            ),
          ),
          const SizedBox(height: 16),
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
            onSelectionChanged: (v) => setState(() => _type = v.first),
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              foregroundColor: WidgetStateProperty.resolveWith((states) {
                if (!states.contains(WidgetState.selected)) {
                  return context.scheme.onSurfaceVariant;
                }
                return _type == 'income' ? app.income : app.expense;
              }),
            ),
          ),
          const SizedBox(height: 16),
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
            onChanged: (v) => setState(() => _category = v ?? '其他'),
            decoration: const InputDecoration(labelText: '分类'),
          ),
          const SizedBox(height: 16),
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.md),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime(2000),
                lastDate: DateTime(2101),
              );
              if (!mounted || picked == null) return;
              setState(() => _date = picked);
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
                    DateFormat('yyyy年MM月dd日 HH:mm').format(_date),
                    style: TextStyle(color: context.scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _noteController,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: '备注',
              hintText: '选填',
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _save,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: const Text('保存修改', style: TextStyle(fontSize: 16)),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              onPressed: () async {
                Navigator.pop(context);
                await widget.onDelete();
              },
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('删除这笔'),
              style: TextButton.styleFrom(foregroundColor: app.expense),
            ),
          ),
        ],
      ),
    );
  }
}

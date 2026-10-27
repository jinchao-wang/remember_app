import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/enums.dart';
import '../models/transaction.dart';
import '../services/app_state.dart';
import '../services/database.dart';
import '../utils/source_role.dart';

/// 账单列表页。
///
/// 改版要点（都是「看不懂 / 不好用」的具体来源）：
/// - **按日期分组**：以前是一长条平铺的列表，看不出「今天花了多少」。
///   现在按天分组，组头直接写「今天 · 支出 ¥88.00」。
/// - **概览卡与列表口径一致**：以前卡片显示今天的数字、下面列的是全部记录，
///   两边对不上。现在卡片显示的就是下面这份数据的口径。
/// - **图标语义修正**：以前圆底用分类色、图标用收支箭头，
///   「绿色的向下箭头」这种组合自相矛盾。现在圆底图标表示分类，
///   金额的绿/红才表示收支。
/// - **副标题不再塞整句通知原文**：原文太长，挤掉了金额和时间。
///   现在副标题是「来源 · 摘要」，时间跟在分类名后面。
/// - **能搜、能按分类筛**：账单多了以后翻不动。
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
  String _categoryFilter = 'all';
  String _keyword = '';
  final TextEditingController _searchController = TextEditingController();

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
    });
  }

  bool _isSameDay(Transaction t, DateTime date) =>
      t.date.year == date.year &&
      t.date.month == date.month &&
      t.date.day == date.day;

  Future<void> _delete(Transaction t) async {
    final id = t.id;
    if (id == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除「${t.category} · ¥${t.amount.toStringAsFixed(2)}」这笔账单吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await DatabaseHelper.instance.deleteTransaction(id);
    AppState.instance.bump();
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('已删除'), duration: Duration(seconds: 1)),
    );
  }

  /// 应用「收支类型 + 分类 + 关键词」三重筛选后的结果。
  List<Transaction> get _filteredList {
    final kw = _keyword.trim().toLowerCase();
    return _list.where((t) {
      if (_filterType != 'all' && t.type != _filterType) return false;
      if (_categoryFilter != 'all' && t.category != _categoryFilter) return false;
      if (kw.isEmpty) return true;
      final haystack = '${t.category} ${t.note ?? ''} ${t.amount}'.toLowerCase();
      return haystack.contains(kw);
    }).toList();
  }

  /// 库里出现过的分类，按金额从大到小排。
  List<String> get _categories {
    final totals = <String, double>{};
    for (final t in _list) {
      totals[t.category] = (totals[t.category] ?? 0) + t.amount;
    }
    final keys = totals.keys.toList()
      ..sort((a, b) => totals[b]!.compareTo(totals[a]!));
    return keys;
  }

  double _sum(List<Transaction> list, String type) =>
      list.where((t) => t.type == type).fold(0.0, (a, b) => a + b.amount);

  DateTime get _summaryDate => widget.selectedDate ?? DateTime.now();

  /// 按天分组，保持库里「日期倒序」的顺序。
  List<MapEntry<DateTime, List<Transaction>>> get _grouped {
    final map = <DateTime, List<Transaction>>{};
    for (final t in _filteredList) {
      final key = DateTime(t.date.year, t.date.month, t.date.day);
      map.putIfAbsent(key, () => []).add(t);
    }
    final keys = map.keys.toList()..sort((a, b) => b.compareTo(a));
    return keys.map((k) => MapEntry(k, map[k]!)).toList();
  }

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

  Color _categoryColor(String category) => Categories.colorOf(category);

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

  // ------------------------------------------------------------------ 概览

  Widget _buildOverviewCard() {
    final scope = _filteredList;
    final scopeLabel = widget.selectedDate == null ? '今天' : _dayLabel(_summaryDate);
    final dayTx = widget.selectedDate == null
        ? scope.where((t) => _isSameDay(t, DateTime.now())).toList()
        : scope;
    final expense = _sum(dayTx, 'expense');
    final income = _sum(dayTx, 'income');

    // 本月支出：给一个长期视角，不然只看今天容易慌。
    final now = DateTime.now();
    final monthExpense = _sum(
      _list
          .where(
            (t) =>
                t.type == 'expense' &&
                t.date.year == now.year &&
                t.date.month == now.month,
          )
          .toList(),
      'expense',
    );

    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [scheme.primary, Color.lerp(scheme.primary, scheme.tertiary, 0.35)!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '$scopeLabel支出',
                style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 12),
              ),
              const Spacer(),
              Text(
                '本月支出 ¥${monthExpense.toStringAsFixed(2)}',
                style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '¥${expense.toStringAsFixed(2)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _overviewChip(Icons.south_rounded, '支出 ¥${expense.toStringAsFixed(2)}'),
              const SizedBox(width: 10),
              _overviewChip(Icons.north_rounded, '收入 ¥${income.toStringAsFixed(2)}'),
              const Spacer(),
              Text(
                '${dayTx.length} 笔',
                style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _overviewChip(IconData icon, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.18),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      );

  // ------------------------------------------------------------------ 筛选

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: TextField(
        controller: _searchController,
        onChanged: (v) => setState(() => _keyword = v),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: '搜索分类、备注或金额',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _keyword.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _keyword = '');
                  },
                ),
          isDense: true,
          filled: true,
          fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              _typeChip('全部', 'all'),
              const SizedBox(width: 8),
              _typeChip('支出', 'expense'),
              const SizedBox(width: 8),
              _typeChip('收入', 'income'),
            ],
          ),
        ),
        if (cats.length > 1) ...[
          const SizedBox(height: 6),
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _categoryChip('全部分类', 'all', _categoryColor('其他')),
                for (final c in cats) ...[
                  const SizedBox(width: 8),
                  _categoryChip(c, c, _categoryColor(c)),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _typeChip(String label, String type) {
    final selected = _filterType == type;
    final scheme = Theme.of(context).colorScheme;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _filterType = type),
      showCheckmark: false,
      labelStyle: TextStyle(
        fontSize: 13,
        color: selected ? scheme.onPrimaryContainer : Colors.black54,
      ),
      selectedColor: scheme.primaryContainer,
      backgroundColor: scheme.surfaceContainerHighest,
      side: BorderSide.none,
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _categoryChip(String label, String value, Color color) {
    final selected = _categoryFilter == value;
    return FilterChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
      selected: selected,
      onSelected: (_) => setState(() => _categoryFilter = value),
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  // ------------------------------------------------------------------ 列表

  Widget _buildDayHeader(DateTime day, List<Transaction> items) {
    final expense = _sum(items, 'expense');
    final income = _sum(items, 'income');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          Text(
            _dayLabel(day),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 8),
          Text(
            '${items.length} 笔',
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
          const Spacer(),
          if (expense > 0)
            Text(
              '支出 ¥${expense.toStringAsFixed(2)}',
              style: const TextStyle(
                fontSize: 12,
                color: Colors.red,
                fontWeight: FontWeight.w600,
              ),
            ),
          if (income > 0) ...[
            const SizedBox(width: 8),
            Text(
              '收入 ¥${income.toStringAsFixed(2)}',
              style: const TextStyle(
                fontSize: 12,
                color: Colors.green,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTransactionItem(Transaction t) {
    final color = _categoryColor(t.category);
    final subtitle = _sourceLabel(t);

    return Dismissible(
      key: Key('${t.id}-${t.date.millisecondsSinceEpoch}'),
      direction: DismissDirection.horizontal,
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          _showEditSheet(t);
          return false;
        }
        await _delete(t);
        return false;
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        decoration: BoxDecoration(color: Colors.red.shade400),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      secondaryBackground: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 24),
        decoration: BoxDecoration(color: Colors.green.shade400),
        child: const Icon(Icons.edit, color: Colors.white),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withOpacity(0.14),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(_categoryIcon(t.category), size: 20, color: color),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                t.category,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              DateFormat('HH:mm').format(t.date),
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
            ),
          ],
        ),
        subtitle: subtitle.isEmpty
            ? null
            : Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
        trailing: Text(
          '${t.type == 'income' ? '+' : '-'}${t.amount.toStringAsFixed(2)}',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
            color: t.type == 'income' ? Colors.green : Colors.red,
          ),
        ),
        onTap: () => _showEditSheet(t),
      ),
    );
  }

  Widget _buildEmptyState() {
    if (_list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(32, 48, 32, 32),
        child: Column(
          children: [
            Icon(Icons.receipt_long_outlined, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              '还没有账单记录',
              style: TextStyle(color: Colors.grey[600], fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              '付钱后只要在系统里开启本 App 的「通知使用权」，\n'
              '支付通知就会自动记成账单；\n'
              '也可以点右下角 + 手动记一笔。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[500], fontSize: 13, height: 1.6),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 32),
      child: Column(
        children: [
          Icon(Icons.search_off, size: 56, color: Colors.grey[300]),
          const SizedBox(height: 12),
          Text(
            '没有匹配的记录',
            style: TextStyle(color: Colors.grey[600], fontSize: 15),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () {
              _searchController.clear();
              setState(() {
                _keyword = '';
                _filterType = 'all';
                _categoryFilter = 'all';
              });
            },
            child: const Text('清除筛选条件'),
          ),
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

    final grouped = _grouped;
    final children = <Widget>[
      _buildOverviewCard(),
      _buildSearchBar(),
      _buildFilterBar(),
    ];

    if (grouped.isEmpty) {
      children.add(_buildEmptyState());
    } else {
      for (final entry in grouped) {
        children.add(_buildDayHeader(entry.key, entry.value));
        children.addAll(entry.value.map(_buildTransactionItem));
      }
      children.add(const SizedBox(height: 88));
    }

    // 不再套一层 Scaffold：
    // 外层 HomeScreen 已经有 Scaffold 和 FAB，
    // 嵌套 Scaffold 会让 FAB 的定位和 SnackBar 的层级变得别扭。
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 8),
        children: children,
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
    final amount = double.tryParse(_amountController.text);
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
      note: noteText.isEmpty ? null : noteText,
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
    messenger.showSnackBar(
      const SnackBar(content: Text('账单已更新'), duration: Duration(seconds: 1)),
    );
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      // 小屏 + 键盘弹出时固定高度会溢出，交给滚动容器处理。
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
              // await 之后必须确认 State 仍存活，否则 setState 会抛异常。
              if (!mounted) return;
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

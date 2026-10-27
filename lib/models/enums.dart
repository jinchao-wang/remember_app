import 'package:flutter/material.dart';

/// 记账类型（收入 / 支出）
enum TransactionType { income, expense }

extension TransactionTypeExtension on TransactionType {
  String get label => switch (this) {
        TransactionType.income => '收入',
        TransactionType.expense => '支出',
      };

  String get value => switch (this) {
        TransactionType.income => 'income',
        TransactionType.expense => 'expense',
      };

  IconData get icon => switch (this) {
        TransactionType.income => Icons.arrow_upward,
        TransactionType.expense => Icons.arrow_downward,
      };
}

/// 宽松解析：兼容 CSV 里可能出现的中英文、大小写与多余空白。
/// 任何无法识别的值都按「支出」处理，与历史行为保持一致。
TransactionType parseTransactionType(String? value) {
  final v = value?.trim().toLowerCase() ?? '';
  return switch (v) {
    'income' || '收入' || 'in' => TransactionType.income,
    _ => TransactionType.expense,
  };
}

/// 默认分类与图标
class Categories {
  static const List<Map<String, IconData>> all = [
    {'餐饮': Icons.food_bank},
    {'交通': Icons.directions_bus},
    {'购物': Icons.shopping_cart},
    {'日用': Icons.home},
    {'娱乐': Icons.movie},
    {'医疗': Icons.medical_services},
    {'教育': Icons.school},
    {'旅行': Icons.flight},
    {'转账': Icons.account_balance_wallet},
    {'其他': Icons.category},
  ];

  /// 分类的固定配色。
  ///
  /// 必须固定：以前用 `category.hashCode % Colors.primaries.length` 取色，
  /// 同一个分类在不同设备/不同版本上可能是不同颜色，
  /// 用户根本认不出「这个圆点是什么」。
  static const Map<String, Color> _colors = {
    '餐饮': Color(0xFFFF7043),
    '交通': Color(0xFF42A5F5),
    '购物': Color(0xFFAB47BC),
    '日用': Color(0xFF26A69A),
    '娱乐': Color(0xFFEC407A),
    '医疗': Color(0xFFEF5350),
    '教育': Color(0xFF5C6BC0),
    '旅行': Color(0xFF29B6F6),
    '转账': Color(0xFF8D6E63),
    '其他': Color(0xFF78909C),
  };

  static List<String> names() => all.map((e) => e.keys.first).toList();

  static IconData iconOf(String name) => all
      .firstWhere((e) => e.keys.first == name, orElse: () => {'其他': Icons.category})
      .values
      .first;

  /// 分类的主色；认不出来的分类一律用「其他」的灰。
  static Color colorOf(String name) => _colors[name] ?? _colors['其他']!;
}

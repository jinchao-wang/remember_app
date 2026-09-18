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

  static TransactionType fromValue(String? value) =>
      switch (value) {
        'income' => TransactionType.income,
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
    {'旅行': Icons.airplanemode_active},
    {'转账': Icons.account_balance_wallet},
    {'其他': Icons.category},
  ];

  static List<String> names() => all.map((e) => e.keys.first).toList();
  static IconData iconOf(String name) =>
      all.firstWhere((e) => e.keys.first == name, orElse: () => {'其他': Icons.category}).values.first;
}

/// 货币单位
class Currency {
  static const symbol = '¥';
  static const name = '人民币';
}

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

TransactionType parseTransactionType(String? value) =>
    switch (value) {
      'income' => TransactionType.income,
      _ => TransactionType.expense,
    };

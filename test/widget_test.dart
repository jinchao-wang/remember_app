import 'package:flutter_test/flutter_test.dart';
import 'package:remember_app/models/transaction.dart';

void main() {
  test('Transaction toMap/fromMap roundtrip', () {
    final t = Transaction(
      id: 1,
      amount: 12.34,
      type: 'expense',
      category: '餐饮',
      note: '午饭',
      date: DateTime(2026, 9, 16, 12, 30),
      isAuto: true,
      isEdited: false,
      sourceApp: 'com.example',
    );
    final map = t.toMap();
    final t2 = Transaction.fromMap(map);
    expect(t2.amount, 12.34);
    expect(t2.category, '餐饮');
    expect(t2.isAuto, isTrue);
  });
}
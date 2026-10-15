import 'package:flutter_test/flutter_test.dart';
import 'package:remember_app/models/enums.dart';
import 'package:remember_app/models/transaction.dart';

Transaction _tx({
  int? id = 1,
  double amount = 12.34,
  String type = 'expense',
  String category = '餐饮',
  String? note = '午饭',
  DateTime? date,
  bool isAuto = false,
  bool isEdited = false,
  String? sourceApp,
}) =>
    Transaction(
      id: id,
      amount: amount,
      type: type,
      category: category,
      note: note,
      date: date ?? DateTime(2026, 9, 16, 12, 30),
      isAuto: isAuto,
      isEdited: isEdited,
      sourceApp: sourceApp,
    );

void main() {
  group('Transaction 序列化', () {
    test('toMap / fromMap 往返一致', () {
      final t = _tx(isAuto: true, sourceApp: 'com.example');
      final t2 = Transaction.fromMap(t.toMap());

      expect(t2.id, t.id);
      expect(t2.amount, t.amount);
      expect(t2.type, t.type);
      expect(t2.category, t.category);
      expect(t2.note, t.note);
      expect(t2.date, t.date);
      expect(t2.isAuto, isTrue);
      expect(t2.isEdited, isFalse);
      expect(t2.sourceApp, 'com.example');
    });

    test('toMap 写入可被 SQLite 接受的原始类型', () {
      final map = _tx().toMap();
      expect(map['isAuto'], 0);
      expect(map['isEdited'], 0);
      expect(map['date'], isA<String>());
    });

    test('fromMap 容忍脏数据而不抛异常', () {
      // 历史遗留：SQLite 偶尔以字符串/布尔返回标志位。
      final t = Transaction.fromMap({
        'id': 3,
        'amount': '8.80',
        'type': 'income',
        'category': '转账',
        'note': null,
        'date': 'not-a-date',
        'isAuto': '1',
        'isEdited': true,
        'sourceApp': null,
      });

      expect(t.amount, 8.80);
      expect(t.isAuto, isTrue);
      expect(t.isEdited, isTrue);
      expect(t.note, isNull);
    });

    test('fromMap 对缺失字段使用安全默认值', () {
      final t = Transaction.fromMap({'id': 1});
      expect(t.amount, 0);
      expect(t.type, 'expense');
      expect(t.category, '其他');
      expect(t.isAuto, isFalse);
    });
  });

  group('copyWith', () {
    test('clearNote 可以把备注真正置空（这是修复前的 Bug）', () {
      final original = _tx(note: '午饭');

      // 仅传 null 无法区分「未修改」与「显式清空」，必须配合 clearNote。
      final stillOld = original.copyWith(note: null);
      expect(stillOld.note, '午饭', reason: 'copyWith 的 null 合并语义保持不变');

      final cleared = original.copyWith(clearNote: true);
      expect(cleared.note, isNull, reason: 'clearNote 应真正清空备注');
    });

    test('clearNote 为 false 时不影响其他字段', () {
      final original = _tx();
      final updated = original.copyWith(amount: 99, isEdited: true);

      expect(updated.amount, 99);
      expect(updated.isEdited, isTrue);
      expect(updated.note, '午饭');
      expect(updated.id, original.id);
    });

    test('clearSourceApp 清空来源', () {
      final original = _tx(sourceApp: 'com.alipay');
      expect(original.copyWith(clearSourceApp: true).sourceApp, isNull);
    });
  });

  group('dedupeKey', () {
    test('收支方向不同 -> 不同键（避免误判重复）', () {
      final expense = _tx(type: 'expense');
      final income = _tx(type: 'income');
      expect(expense.dedupeKey, isNot(income.dedupeKey));
    });

    test('金额 / 分类 / 日期相同则同键', () {
      expect(_tx().dedupeKey, _tx().dedupeKey);
    });

    test('金额不同则不同键', () {
      expect(_tx(amount: 10).dedupeKey, isNot(_tx(amount: 10.01).dedupeKey));
    });

    test('日期不同则不同键', () {
      final a = _tx(date: DateTime(2026, 9, 16, 1));
      final b = _tx(date: DateTime(2026, 9, 17, 1));
      expect(a.dedupeKey, isNot(b.dedupeKey));
    });
  });

  group('parseTransactionType', () {
    test('识别标准取值', () {
      expect(parseTransactionType('income'), TransactionType.income);
      expect(parseTransactionType('expense'), TransactionType.expense);
    });

    test('兼容大小写与空白', () {
      expect(parseTransactionType('  INCOME '), TransactionType.income);
    });

    test('兼容中文取值', () {
      expect(parseTransactionType('收入'), TransactionType.income);
      expect(parseTransactionType('支出'), TransactionType.expense);
    });

    test('未知值回退为支出', () {
      expect(parseTransactionType('whatever'), TransactionType.expense);
      expect(parseTransactionType(null), TransactionType.expense);
    });
  });

  group('Categories', () {
    test('names 返回全部内置分类', () {
      final names = Categories.names();
      expect(names, contains('餐饮'));
      expect(names, contains('其他'));
      expect(names.length, 10);
    });

    test('未知分类回退到其他图标', () {
      expect(Categories.iconOf('不存在的分类'), Categories.iconOf('其他'));
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:remember_app/models/enums.dart';
import 'package:remember_app/models/transaction.dart';
import 'package:remember_app/utils/csv_helper.dart';

const _header =
    'id,amount,type,category,note,date,isAuto,isEdited,sourceApp';

void main() {
  group('CSV 往返', () {
    test('导出再导入后字段保持一致', () {
      final original = [
        Transaction(
          id: 1,
          amount: 12.34,
          type: 'expense',
          category: '餐饮',
          note: '午饭',
          date: DateTime(2026, 9, 16, 12, 30),
          isAuto: false,
          isEdited: true,
          sourceApp: null,
        ),
        Transaction(
          id: 2,
          amount: 5000,
          type: 'income',
          category: '转账',
          note: null,
          date: DateTime(2026, 9, 17, 9),
          isAuto: true,
          isEdited: false,
          sourceApp: 'com.example.pay',
        ),
      ];

      final restored = csvToTransactions(transactionsToCsv(original));

      expect(restored.length, 2);
      expect(restored[0].amount, 12.34);
      expect(restored[0].type, 'expense');
      expect(restored[0].category, '餐饮');
      expect(restored[0].note, '午饭');
      expect(restored[0].date, original[0].date);
      expect(restored[0].isEdited, isTrue);

      expect(restored[1].type, 'income');
      expect(restored[1].note, isNull);
      expect(restored[1].isAuto, isTrue);
      expect(restored[1].sourceApp, 'com.example.pay');
    });

    test('导入不沿用 CSV 中的旧 id', () {
      final csv = '$_header\n7,10.0,expense,餐饮,咖啡,2026-09-16,0,0,';
      final parsed = csvToTransactions(csv);

      expect(parsed.length, 1);
      expect(parsed.single.id, isNull, reason: 'id 交给数据库自增');
    });

    test('CRLF 换行不会污染最后一列（回归修复）', () {
      // 导出用 ListToCsvConverter 的默认 CRLF，解析器按 LF 切行。
      final csv = '$_header\r\n1,10.0,expense,餐饮,咖啡,2026-09-16,0,0,com.example.pay\r\n';
      final parsed = csvToTransactions(csv);

      expect(parsed.length, 1);
      expect(parsed.single.sourceApp, 'com.example.pay');
      expect(parsed.single.sourceApp, isNot(contains('\r')));
    });
  });

  group('CSV 脏数据归一化', () {
    test('未知分类收敛到「其他」，不会让下拉框断言崩溃', () {
      final csv = '$_header\n1,10.0,expense,咖啡,,2026-09-16,0,0,';
      final parsed = csvToTransactions(csv);

      expect(parsed.single.category, '其他');
      expect(Categories.names(), contains(parsed.single.category));
    });

    test('未知类型收敛为 expense，合法取值原样保留', () {
      final csv = [
        _header,
        '1,10.0,expense,餐饮,,2026-09-16,0,0,',
        '2,10.0,income,转账,,2026-09-16,0,0,',
        '3,10.0,乱七八糟,餐饮,,2026-09-16,0,0,',
        '4,10.0,收入,转账,,2026-09-16,0,0,',
      ].join('\n');
      final parsed = csvToTransactions(csv);

      expect(parsed.map((t) => t.type).toList(), [
        'expense',
        'income',
        'expense',
        'income',
      ]);
    });

    test('解析后的 type 一定落在下拉框的可选集合内', () {
      final csv = '$_header\n1,10.0,??? ,coffee,?,2026-09-16,0,0,';
      final parsed = csvToTransactions(csv);

      expect(TransactionType.values.map((t) => t.value), contains(parsed.single.type));
      expect(Categories.names(), contains(parsed.single.category));
    });

    test('带货币符号的金额可以被解析', () {
      final csv = [
        _header,
        r'1,¥12.50,expense,餐饮,,2026-09-16,0,0,',
        r'2, RMB 88.00 ,income,转账,,2026-09-16,0,0,',
      ].join('\n');
      final parsed = csvToTransactions(csv);

      expect(parsed.length, 2);
      expect(parsed[0].amount, 12.50);
      expect(parsed[1].amount, 88.00);
    });

    test('空备注收敛为 null 而不是空字符串', () {
      final csv = '$_header\n1,10.0,expense,餐饮,,2026-09-16,0,0,';
      expect(csvToTransactions(csv).single.note, isNull);
    });

    test('备注含逗号时引号转义可正确还原', () {
      final original = Transaction(
        amount: 10,
        type: 'expense',
        category: '餐饮',
        note: '午饭, 加奶茶',
        date: DateTime(2026, 9, 16),
      );
      final restored = csvToTransactions(transactionsToCsv([original]));

      expect(restored.single.note, '午饭, 加奶茶');
    });

    test('日期非法时回退到当前时间而不是崩溃', () {
      final csv = '$_header\n1,10.0,expense,餐饮,,not-a-date,0,0,';
      final parsed = csvToTransactions(csv);

      expect(parsed.length, 1);
      expect(parsed.single.date, isA<DateTime>());
    });

    test('列数不足或金额非法的行被跳过', () {
      final csv = [
        _header,
        '1,10.0,expense', // 列数不足
        '2,abc,expense,餐饮,,2026-09-16,0,0,', // 金额非法
        '3,20.0,expense,餐饮,,2026-09-16,0,0,', // 合法
      ].join('\n');
      final parsed = csvToTransactions(csv);

      expect(parsed.length, 1);
      expect(parsed.single.amount, 20.0);
    });

    test('只有表头时返回空列表', () {
      expect(csvToTransactions(_header), isEmpty);
    });

    test('空字符串返回空列表', () {
      expect(csvToTransactions(''), isEmpty);
    });

    test('缺少可选列的行仍能解析', () {
      final csv = '$_header\n1,10.0,expense,餐饮,,2026-09-16';
      final parsed = csvToTransactions(csv);

      expect(parsed.length, 1);
      expect(parsed.single.sourceApp, isNull);
      expect(parsed.single.isAuto, isFalse);
    });
  });
}

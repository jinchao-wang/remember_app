import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:charset/charset.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remember_app/models/transaction.dart';
import 'package:remember_app/services/bill_import_service.dart';
import 'package:remember_app/utils/bill_parser.dart';

const _wechatHeader =
    '交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注';

/// 微信账单（UTF-8）。前几行是官方导出的说明文字，解析时要能跳过。
const _wechatBill = '''
微信支付账单明细列表
账单起始时间：[2024-10-01 00:00:00]    账单结束时间：[2024-10-31 23:59:59]
导出类型：[全部]
-----------------------微信支付账单明细列表--------------------
$_wechatHeader
2024-10-05 13:45:12,商户消费,肯德基,肯德基-快餐,支出,¥31.31,零钱,支付成功,4200000000000000000000000000000001,1001,
2024-10-06 09:00:00,转账,张三,,支出,¥200.00,零钱,支付成功,4200000000000000000000000000000002,,
2024-10-07 20:00:00,红包,李四,红包,收入,¥8.88,零钱,已存入零钱,4200000000000000000000000000000003,,
2024-10-08 10:00:00,零钱充值,,,不计收支,¥1000.00,招商银行,充值完成,4200000000000000000000000000000004,,
/2024-10-09 10:00:00,商户消费,已关闭商家,已关闭商品,支出,¥1.00,零钱,支付成功,4200000000000000000000000000000005,,
2024-10-10 12:00:00,退款,肯德基,退款,不计收支,¥31.31,零钱,已全额退款,4200000000000000000000000000000006,,
-----------------------微信支付账单明细列表--------------------
''';

const _alipayHeader =
    '交易号,商家订单号,交易创建时间,付款时间,最近修改时间,交易来源地,类型,交易对方,商品名称,金额（元）,收/支,交易状态,服务费（元）,成功退款（元）,备注,资金状态';

/// 支付宝账单（真实导出是 GBK 编码）。
const _alipayBill = '''
支付宝交易记录明细查询
账号：[zhangsan@example.com]
起始日期：[2024-10-01 00:00:00]    终止日期：[2024-10-31 23:59:59]
---------------------------------交易记录明细列表------------------------------------
$_alipayHeader
2024100522001498000,2088123456789,2024-10-05 22:01:49,2024-10-05 22:01:50,2024-10-05 22:01:50,支付宝网站,即时交易,肯德基,肯德基,31.31,支出,交易成功,0.00,0.00,,已支出
2024100622001498000,2088123456790,2024-10-06 12:00:00,2024-10-06 12:00:01,2024-10-06 12:00:01,转账,转账,张三,,200.00,支出,交易成功,0.00,0.00,,已支出
2024100722001498000,2088123456791,2024-10-07 08:00:00,2024-10-07 08:00:01,2024-10-07 08:00:01,余额宝,余额宝,余额宝,转入,50.00,不计收支,交易成功,0.00,0.00,,已支出
---------------------------------交易记录明细列表------------------------------------
''';

void main() {
  group('微信账单解析', () {
    test('识别为微信来源', () {
      final result = parseBillText(_wechatBill);
      expect(result.source, BillSource.wechat);
    });

    test('跳过说明文字与表头前的装饰行', () {
      final result = parseBillText(_wechatBill);
      // 有效行：消费、转账、红包、退款。充值与作废行不算。
      expect(result.entries.length, 4);
      // 表尾的分隔线是装饰行，不该被算成「无效行」。
      expect(result.skipped, 2, reason: '充值(不计收支) + 作废行');
    });

    test('金额解析正确（带货币符号）', () {
      final result = parseBillText(_wechatBill);
      expect(result.entries.first.amount, 31.31);
    });

    test('支出与收入方向正确', () {
      final result = parseBillText(_wechatBill);

      expect(result.entries[0].isIncome, isFalse, reason: '商户消费是支出');
      expect(result.entries[1].isIncome, isFalse, reason: '转账给别人是支出');
      expect(result.entries[2].isIncome, isTrue, reason: '收到红包是收入');
    });

    test('退款记为收入', () {
      final result = parseBillText(_wechatBill);
      final refund = result.entries.firstWhere((e) => e.note.contains('退款'));
      expect(refund.isIncome, isTrue);
      expect(refund.amount, 31.31);
    });

    test('零钱充值这类「不计收支」的行不记', () {
      final result = parseBillText(_wechatBill);
      expect(result.entries.any((e) => e.amount == 1000.00), isFalse);
    });

    test('作废行（前缀 /）不记', () {
      final result = parseBillText(_wechatBill);
      expect(result.entries.any((e) => e.amount == 1.00), isFalse);
    });

    test('分类推断：商家名命中规则，转账归到转账', () {
      final result = parseBillText(_wechatBill);
      expect(result.entries[0].category, '餐饮');
      expect(result.entries[1].category, '转账');
    });

    test('交易单号被解析出来，用于精确判重', () {
      final result = parseBillText(_wechatBill);
      expect(result.entries.first.externalId, '4200000000000000000000000000000001');
    });

    test('CRLF 换行的账单同样能解析', () {
      final result = parseBillText(_wechatBill.replaceAll('\n', '\r\n'));
      expect(result.entries.length, 4);
      expect(result.entries.first.amount, 31.31);
    });

    test('UTF-8 BOM 不会污染第一个字段', () {
      final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode(_wechatBill)];
      final result = parseBillText(decodeBillBytes(bytes));
      expect(result.entries.length, 4);
      expect(result.entries.first.date, DateTime(2024, 10, 5, 13, 45, 12));
    });
  });

  group('支付宝账单解析', () {
    test('识别为支付宝来源', () {
      final result = parseBillText(_alipayBill);
      expect(result.source, BillSource.alipay);
    });

    test('全角表头「金额（元）」能识别', () {
      final result = parseBillText(_alipayBill);
      expect(result.entries.length, 2);
      expect(result.entries.first.amount, 31.31);
    });

    test('转账类型归到转账分类', () {
      final result = parseBillText(_alipayBill);
      expect(result.entries[1].category, '转账');
      expect(result.entries[1].isIncome, isFalse);
    });

    test('GBK 编码的账单解码后不是乱码', () {
      final gbkBytes = gbk.encode(_alipayBill);
      final text = decodeBillBytes(gbkBytes);
      expect(text, contains('支付宝交易记录明细查询'));
      expect(text, isNot(contains('�')));

      final result = parseBillText(text);
      expect(result.source, BillSource.alipay);
      expect(result.entries.length, 2);
      expect(result.entries.first.amount, 31.31);
      expect(result.entries.first.category, '餐饮');
    });
  });

  group('容错', () {
    test('不是账单文件时返回空并给出提示', () {
      final result = parseBillText('随便一段文字\n还是文字\n');
      expect(result.entries, isEmpty);
      expect(result.warnings, isNotEmpty);
    });

    test('空文件不报错', () {
      expect(parseBillText('').entries, isEmpty);
    });

    test('金额缺失的行被跳过', () {
      const csv = '$_wechatHeader\n2024-10-05 13:45:12,商户消费,肯德基,快餐,支出,,零钱,支付成功,id1,,';
      final result = parseBillText(csv);
      expect(result.entries, isEmpty);
      expect(result.skipped, 1);
    });

    test('日期无法解析的行被跳过', () {
      const csv = '$_wechatHeader\n不是日期,商户消费,肯德基,快餐,支出,¥10.00,零钱,支付成功,id1,,';
      final result = parseBillText(csv);
      expect(result.entries, isEmpty);
    });

    test('金额为 0 的行被跳过', () {
      const csv = '$_wechatHeader\n2024-10-05 13:45:12,商户消费,肯德基,快餐,支出,¥0.00,零钱,支付成功,id1,,';
      expect(parseBillText(csv).entries, isEmpty);
    });

    test('金额里带千分位也能解析', () {
      const csv = '$_wechatHeader\n2024-10-05 13:45:12,商户消费,某店,商品,支出,"1,234.56",零钱,支付成功,id1,,';
      final result = parseBillText(csv);
      expect(result.entries.single.amount, 1234.56);
    });

    test('日期支持斜杠分隔与只到天的写法', () {
      const csv = '$_wechatHeader\n2024/10/05 13:45,商户消费,某店,商品,支出,¥10.00,零钱,支付成功,id1,,';
      final result = parseBillText(csv);
      expect(result.entries.single.date, DateTime(2024, 10, 5, 13, 45));
    });
  });

  group('仓库里的真实样本文件', () {
    // 这两个文件按官方导出的真实编码生成：微信是 UTF-8 BOM，支付宝是 GBK。
    // 生成脚本见 tool/make_sample_bills.py。
    test('微信样本（UTF-8 BOM）能解析', () {
      final bytes = File('tool/sample_bills/wechat_bill.csv').readAsBytesSync();
      final result = BillImportService.parseBillFile(bytes);

      expect(result.source, BillSource.wechat);
      // 消费、转账、红包、退款、滴滴；充值与作废行不算。
      expect(result.entries.length, 5);

      final transfer = result.entries.firstWhere((e) => e.note.contains('转账'));
      expect(transfer.amount, 288.88);
      expect(transfer.isIncome, isFalse);
      expect(transfer.category, '转账');
      expect(transfer.externalId, '4200000000000000000000000000000002');

      final taxi = result.entries.firstWhere((e) => e.note.contains('滴滴'));
      expect(taxi.category, '交通');
    });

    test('支付宝样本（GBK）能解析', () {
      final bytes = File('tool/sample_bills/alipay_bill.csv').readAsBytesSync();
      final result = BillImportService.parseBillFile(bytes);

      expect(result.source, BillSource.alipay);
      // 永辉超市、转账；余额宝那行是「不计收支」不算。
      expect(result.entries.length, 2);
      expect(result.entries.first.amount, 158.60);
      expect(result.entries.first.category, '日用');
      expect(result.entries.first.externalId, '2026100522001498000');
      expect(result.entries.last.category, '转账');
    });
  });

  group('xlsx 与压缩包', () {    test('xlsx 账单能解析', () {
      final result = BillImportService.parseBillFile(_buildWechatXlsx());
      expect(result.source, BillSource.wechat);
      expect(result.entries.length, 2);
      expect(result.entries.first.amount, 31.31);
      expect(result.entries.first.category, '餐饮');
    });

    test('微信那种 zip 套 xlsx 也能解析', () {
      final zip = _zipOf('微信支付账单明细列表.xlsx', _buildWechatXlsx());
      final result = BillImportService.parseBillFile(zip);
      expect(result.source, BillSource.wechat);
      expect(result.entries.length, 2);
    });

    test('本应用自己导出的 csv 会被识别并提示', () {
      const appCsv = 'id,amount,type,category,note,date,isAuto,isEdited,sourceApp\n'
          '1,10.0,expense,餐饮,午饭,2024-10-05,0,0,';
      expect(
        () => BillImportService.parseBillFile(appCsv.codeUnits),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('导入判重', () {
    test('同一个账单文件导入两次不会产生重复', () {
      final entries = parseBillText(_wechatBill).entries;
      final plan = BillImportService.planInsert(
        const [],
        entries,
        source: BillSource.wechat,
      );
      expect(plan.toInsert.length, 4);

      final second = BillImportService.planInsert(
        plan.toInsert,
        entries,
        source: BillSource.wechat,
      );
      expect(second.toInsert, isEmpty);
      expect(second.duplicates, 4);
    });

    test('通知已经记过的同一笔不会被重复导入', () {
      // 通知自动记账记下来的 sourceApp 是包名，账单导入记的是「微信」，
      // 两者必须能对上，否则同一笔会被记两次。
      final existing = [
        Transaction(
          amount: 31.31,
          type: 'expense',
          category: '餐饮',
          date: DateTime(2024, 10, 5, 13, 45, 30),
          isAuto: true,
          sourceApp: 'com.tencent.mm',
        ),
      ];

      final plan = BillImportService.planInsert(
        existing,
        parseBillText(_wechatBill).entries,
        source: BillSource.wechat,
      );
      expect(plan.duplicates, 1);
      expect(plan.toInsert.length, 3);
      // 退款那笔也是 31.31，所以要看方向：支出那笔不能重复进来。
      expect(
        plan.toInsert.any((t) => t.amount == 31.31 && t.type == 'expense'),
        isFalse,
      );
    });

    test('不同钱包的同金额消费互不影响', () {
      final existing = [
        Transaction(
          amount: 31.31,
          type: 'expense',
          category: '餐饮',
          date: DateTime(2024, 10, 5, 13, 45, 30),
          isAuto: true,
          sourceApp: 'com.eg.android.AlipayGphone',
        ),
      ];

      final plan = BillImportService.planInsert(
        existing,
        parseBillText(_wechatBill).entries,
        source: BillSource.wechat,
      );
      expect(plan.duplicates, 0);
      expect(plan.toInsert.length, 4);
    });

    test('两笔同额但不同单号的交易都保留', () {
      const csv = '$_wechatHeader\n'
          '2024-10-05 13:45:12,商户消费,某店,商品,支出,¥20.00,零钱,支付成功,id-A,\n'
          '2024-10-05 13:45:30,商户消费,某店,商品,支出,¥20.00,零钱,支付成功,id-B,\n';
      final entries = parseBillText(csv).entries;
      expect(entries.length, 2);

      final plan = BillImportService.planInsert(
        const [],
        entries,
        source: BillSource.wechat,
      );
      expect(plan.toInsert.length, 2, reason: '单号不同就是两笔交易');
    });

    test('导入的记录带上门店来源与交易单号', () {
      final plan = BillImportService.planInsert(
        const [],
        parseBillText(_wechatBill).entries,
        source: BillSource.wechat,
      );
      final first = plan.toInsert.first;
      expect(first.sourceApp, '微信');
      expect(first.externalId, '4200000000000000000000000000000001');
      expect(first.isAuto, isTrue);
      expect(first.type, 'expense');
    });
  });
}

/// 造一个微信账单 xlsx。
List<int> _buildWechatXlsx() {
  final excel = Excel.createExcel();
  final sheet = excel['Sheet1'];

  final rows = <List<String>>[
    ['微信支付账单明细列表'],
    [
      '交易时间', '交易类型', '交易对方', '商品', '收/支', '金额(元)',
      '支付方式', '当前状态', '交易单号', '商户单号', '备注',
    ],
    [
      '2024-10-05 13:45:12', '商户消费', '肯德基', '肯德基-快餐', '支出', '¥31.31',
      '零钱', '支付成功', '4200000000000000000000000000000001', '1001', '',
    ],
    [
      '2024-10-06 09:00:00', '转账', '张三', '', '支出', '¥200.00',
      '零钱', '支付成功', '4200000000000000000000000000000002', '', '',
    ],
  ];

  for (var r = 0; r < rows.length; r++) {
    for (var c = 0; c < rows[r].length; c++) {
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r))
          .value = TextCellValue(rows[r][c]);
    }
  }

  return excel.encode()!;
}

/// 把一个文件塞进 zip，模拟微信下载到的账单压缩包。
List<int> _zipOf(String name, List<int> content) {
  final archive = Archive();
  archive.addFile(ArchiveFile(name, content.length, content));
  return ZipEncoder().encode(archive)!;
}

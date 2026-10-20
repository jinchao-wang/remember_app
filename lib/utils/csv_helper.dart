import 'package:csv/csv.dart';

import '../models/enums.dart';
import '../models/transaction.dart';

String transactionsToCsv(List<Transaction> list) {
  final rows = <List<dynamic>>[
    ['id', 'amount', 'type', 'category', 'note', 'date', 'isAuto', 'isEdited', 'sourceApp', 'externalId'],
  ];
  for (final t in list) {
    rows.add([
      t.id ?? '',
      t.amount,
      t.type,
      t.category,
      t.note ?? '',
      t.date.toIso8601String(),
      t.isAuto ? 1 : 0,
      t.isEdited ? 1 : 0,
      t.sourceApp ?? '',
      t.externalId ?? '',
    ]);
  }
  return const ListToCsvConverter().convert(rows);
}

List<Transaction> csvToTransactions(String csv) {
  // 导出用的是 ListToCsvConverter 默认的 CRLF，而解析器按 LF 切行，
  // 不统一的话每行最后一列会残留一个 \r，导致 sourceApp 等字段被污染。
  final normalized = csv.replaceAll('\r\n', '\n');
  final rows = const CsvToListConverter(eol: '\n').convert(normalized);
  if (rows.length < 2) return [];

  bool truthy(List<dynamic> r, int i) =>
      r.length > i &&
      (r[i] == true ||
          r[i] == 1 ||
          r[i].toString().toLowerCase() == 'true' ||
          r[i].toString() == '1');

  String cell(List<dynamic> r, int i) {
    if (i >= r.length) return '';
    // csv 包对空字段可能给出 null 或 ''，统一折叠成空字符串。
    final v = r[i];
    if (v == null) return '';
    return v.toString();
  }

  final parsed = <Transaction>[];
  for (final r in rows.skip(1)) {
    if (r.length < 5) continue;
    final rawAmount = r[1];
    // CSV 文本默认解析成 num，但用户手改的文件可能是 "¥12.50" 这类脏值。
    final amount = rawAmount is num
        ? rawAmount.toDouble()
        : double.tryParse(cell(r, 1).replaceAll(RegExp(r'[^0-9.\-]'), ''));
    if (amount == null || amount.isNaN || amount.isInfinite) continue;

    final note = cell(r, 4).trim();

    // type / category 必须归一化到内置取值，否则编辑页的
    // DropdownButtonFormField 会因为找不到匹配项直接 assert 崩溃。
    final type = parseTransactionType(cell(r, 2)).value;
    final rawCategory = cell(r, 3).trim();
    final category = Categories.names().contains(rawCategory) ? rawCategory : '其他';

    final date = DateTime.tryParse(cell(r, 5).trim()) ?? DateTime.now();

    // externalId 是第 10 列，v1 导出的旧文件没有这一列，属于可选项。
    final externalId = cell(r, 9).trim();

    parsed.add(
      Transaction(
        // CSV 不携带 id，交给自增主键分配。
        amount: amount,
        type: type,
        category: category,
        note: note.isEmpty ? null : note,
        date: date,
        isAuto: truthy(r, 6),
        isEdited: truthy(r, 7),
        sourceApp: cell(r, 8).trim().isEmpty ? null : cell(r, 8).trim(),
        externalId: externalId.isEmpty ? null : externalId,
      ),
    );
  }
  return parsed;
}
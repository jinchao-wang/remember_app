import '../models/transaction.dart';
import 'package:csv/csv.dart';

String transactionsToCsv(List<Transaction> list) {
  final rows = <List<dynamic>>[
    ['id', 'amount', 'type', 'category', 'note', 'date', 'isAuto', 'isEdited', 'sourceApp'],
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
    ]);
  }
  return const ListToCsvConverter().convert(rows);
}

List<Transaction> csvToTransactions(String csv) {
  final rows = const CsvToListConverter(eol: '\n').convert(csv);
  if (rows.length < 2) return [];

  bool truthy(List<dynamic> r, int i) =>
      r.length > i &&
      (r[i] == true ||
          r[i] == 1 ||
          r[i].toString().toLowerCase() == 'true' ||
          r[i].toString() == '1');

  return rows.skip(1).where((r) => r.length >= 5 && r[1] is num).map((r) {
    final idRaw = r[0];
    return Transaction(
      id: idRaw is num ? idRaw.toInt() : null,
      amount: (r[1] as num).toDouble(),
      type: r[2].toString(),
      category: r[3].toString(),
      note: r.length > 4 ? (r[4]?.toString().isEmpty ?? true ? null : r[4].toString()) : null,
      date: DateTime.tryParse(r[5].toString()) ?? DateTime.now(),
      isAuto: truthy(r, 6),
      isEdited: truthy(r, 7),
      sourceApp: r.length > 8 ? r[8].toString() : null,
    );
  }).toList();
}
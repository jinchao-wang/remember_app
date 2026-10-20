import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';

import '../models/transaction.dart';
import '../utils/app_source.dart';
import '../utils/bill_parser.dart';
import 'app_state.dart';
import 'database.dart';

/// 一次账单导入的结果。
class BillImportResult {
  /// 识别出的账单来源（微信 / 支付宝）。
  final BillSource source;

  /// 实际写入数据库的条数。
  final int imported;

  /// 与已有记录重复、被跳过的条数。
  final int duplicates;

  /// 账单文件里被丢弃的行数（作废、金额缺失、不计收支等）。
  final int skipped;

  /// 失败原因。成功时为 null。
  final String? error;

  const BillImportResult({
    this.source = BillSource.unknown,
    this.imported = 0,
    this.duplicates = 0,
    this.skipped = 0,
    this.error,
  });

  bool get ok => error == null;
}

/// 导入前的落库计划。
class BillImportPlan {
  /// 真正要写入数据库的记录。
  final List<Transaction> toInsert;

  /// 被判定为重复的条数。
  final int duplicates;

  const BillImportPlan({this.toInsert = const [], this.duplicates = 0});
}

/// 把微信 / 支付宝的官方账单文件导入账本。
///
/// 通知监听只覆盖「系统弹了通知」的场景，而用户在微信/支付宝 App 内部
/// 发起转账时平台并不发通知，那部分账只能从官方账单文件里补。
class BillImportService {
  /// 弱匹配判重的时间窗。
  ///
  /// 通知自动记账记下的时间是通知投递时刻，账单里是交易时刻，
  /// 两者可能差几十秒，所以要给一个容差。
  static const Duration matchWindow = Duration(minutes: 2);

  /// 金额比较容差。
  static const double amountTolerance = 0.005;

  /// 从文件路径导入。
  static Future<BillImportResult> importFile(String path) async {
    final bytes = await File(path).readAsBytes();
    return importBytes(bytes);
  }

  /// 从字节流导入（file_picker 与测试都走这里）。
  static Future<BillImportResult> importBytes(List<int> bytes) async {
    BillParseResult parsed;
    try {
      parsed = parseBillFile(bytes);
    } catch (e) {
      return BillImportResult(error: '无法解析账单文件：$e');
    }

    if (parsed.entries.isEmpty) {
      return BillImportResult(
        source: parsed.source,
        skipped: parsed.skipped,
        error: parsed.warnings.isEmpty
            ? '没有解析到有效账单'
            : parsed.warnings.join('；'),
      );
    }

    final existing = await DatabaseHelper.instance.getTransactions();
    final plan = planInsert(existing, parsed.entries, source: parsed.source);

    await DatabaseHelper.instance.insertAll(plan.toInsert);
    if (plan.toInsert.isNotEmpty) AppState.instance.bump();

    return BillImportResult(
      source: parsed.source,
      imported: plan.toInsert.length,
      duplicates: plan.duplicates,
      skipped: parsed.skipped,
    );
  }

  /// 按文件内容判断类型并解析。
  ///
  /// 微信账单现在下载到的是 zip（里面套一个 xlsx），
  /// 支付宝既有 csv（GBK 编码）也有 xlsx，所以三种都要认。
  static BillParseResult parseBillFile(List<int> bytes) {
    if (bytes.isEmpty) {
      throw const FormatException('文件是空的');
    }

    if (_looksLikeZip(bytes)) {
      final archive = ZipDecoder().decodeBytes(bytes);

      // 直接就是一个 xlsx。
      if (archive.findFile('xl/workbook.xml') != null) {
        return _bestSheetResult(bytes);
      }

      // 微信账单的压缩包：里面套一个 xlsx。
      final inner = archive.files
          .where((f) => f.name.toLowerCase().endsWith('.xlsx'))
          .toList();
      if (inner.isEmpty) {
        throw const FormatException('压缩包里没有找到 xlsx 账单文件');
      }
      return _bestSheetResult(_toBytes(inner.first.content));
    }

    final text = decodeBillBytes(bytes);
    if (_looksLikeAppExport(text)) {
      throw const FormatException('这是本应用导出的文件，请用「导入 CSV」');
    }
    return parseBillText(text);
  }

  /// 算出要插入哪些记录、哪些是重复。
  ///
  /// 抽成纯函数是为了能脱离数据库做单元测试。
  static BillImportPlan planInsert(
    List<Transaction> existing,
    List<BillEntry> entries, {
    BillSource source = BillSource.unknown,
  }) {
    // 精确判重：平台交易单号。同一份账单导入两次不会产生重复记录。
    final knownIds = <String>{};
    for (final t in existing) {
      final id = t.externalId?.trim();
      if (id != null && id.isNotEmpty) knownIds.add(id);
    }

    // 弱匹配判重：通知自动记账已经记过的同一笔。
    final known = existing
        .map((t) => _Record(t.sourceApp, t.type, t.amount, t.date,
            externalId: t.externalId))
        .toList();

    final toInsert = <Transaction>[];
    var duplicates = 0;

    for (final e in entries) {
      final externalId = e.externalId?.trim();
      if (externalId != null &&
          externalId.isNotEmpty &&
          knownIds.contains(externalId)) {
        duplicates++;
        continue;
      }

      final candidate = _Record(source.label, e.type, e.amount, e.date,
          externalId: e.externalId);
      if (known.any((k) => k.matches(candidate))) {
        duplicates++;
        continue;
      }

      toInsert.add(
        Transaction(
          amount: e.amount,
          type: e.type,
          category: e.category,
          note: e.note.isEmpty ? null : e.note,
          date: e.date,
          isAuto: true,
          isEdited: false,
          sourceApp: source.label,
          externalId: externalId == null || externalId.isEmpty ? null : externalId,
        ),
      );

      if (externalId != null && externalId.isNotEmpty) knownIds.add(externalId);
      known.add(candidate);
    }

    return BillImportPlan(toInsert: toInsert, duplicates: duplicates);
  }

  /// 解析 xlsx。文件里可能有多个工作表，取能解析出最多记录的那一个。
  static BillParseResult _bestSheetResult(List<int> bytes) {
    final excel = Excel.decodeBytes(bytes);

    BillParseResult best = const BillParseResult(
      source: BillSource.unknown,
      entries: [],
    );
    for (final sheet in excel.tables.values) {
      final rows = sheet.rows.map((row) => row.map(_cellText).toList()).toList();
      final result = parseBillRows(rows);
      if (result.entries.length > best.entries.length) {
        best = result;
      }
    }
    return best;
  }

  /// 本应用自己导出的 CSV 有自己的表头，别和平台账单混淆。
  static bool _looksLikeAppExport(String text) {
    final head = text.split('\n').take(3).join(' ');
    return head.contains('isAuto') && head.contains('sourceApp');
  }

  static bool _looksLikeZip(List<int> bytes) {
    if (bytes.length < 4) return false;
    final b0 = bytes[0], b1 = bytes[1], b2 = bytes[2], b3 = bytes[3];
    if (b0 != 0x50 || b1 != 0x4B) return false; // "PK"
    return b2 == 0x03 ||
        b2 == 0x05 ||
        b2 == 0x07 ||
        (b2 == 0x06 && b3 == 0x06); // 分卷标记
  }

  static List<int> _toBytes(dynamic content) {
    if (content is Uint8List) return content;
    if (content is List<int>) return content;
    if (content is List) return content.map((e) => e as int).toList();
    throw const FormatException('无法读取压缩包内容');
  }

  /// 把 excel 单元格转成文本。
  static String _cellText(Data? cell) {
    if (cell == null) return '';
    final v = cell.value;
    if (v == null) return '';
    if (v is TextCellValue) return v.toString();
    if (v is DateCellValue) {
      final d = v.asDateTimeLocal();
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
    }
    if (v is DateTimeCellValue) {
      final d = v.asDateTimeLocal();
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')} '
          '${d.hour.toString().padLeft(2, '0')}:'
          '${d.minute.toString().padLeft(2, '0')}:'
          '${d.second.toString().padLeft(2, '0')}';
    }
    return v.toString();
  }
}

/// 判重用的记录摘要。
class _Record {
  final String? source;
  final String type;
  final double amount;
  final DateTime date;
  final String? externalId;

  _Record(String? source, this.type, this.amount, this.date, {this.externalId})
      : source = canonicalSource(source);

  /// 是否与另一条记录指向同一笔交易。
  bool matches(_Record other) {
    if (source == null || other.source == null) return false;
    if (source != other.source) return false;
    if (type != other.type) return false;

    // 两边都带交易单号时，单号不同就一定是两笔不同的交易。
    // 没有单号的（比如通知自动记账记下的）才走「同金额同时间」的弱匹配。
    if (externalId != null && other.externalId != null) return false;

    if ((amount - other.amount).abs() >= BillImportService.amountTolerance) {
      return false;
    }
    return date.difference(other.date).abs() <= BillImportService.matchWindow;
  }
}

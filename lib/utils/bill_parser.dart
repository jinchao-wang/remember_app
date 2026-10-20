import 'dart:convert';

import 'package:charset/charset.dart';
import 'package:csv/csv.dart';

import 'category_guesser.dart';

/// 账单来源。
enum BillSource { wechat, alipay, unknown }

extension BillSourceExtension on BillSource {
  /// 展示名，同时作为落库时的 sourceApp。
  String get label => switch (this) {
        BillSource.wechat => '微信',
        BillSource.alipay => '支付宝',
        BillSource.unknown => '账单',
      };
}

/// 一条账单明细。
class BillEntry {
  final BillSource source;
  final DateTime date;
  final double amount;

  /// true 表示收入，false 表示支出。
  final bool isIncome;
  final String category;
  final String note;

  /// 平台侧的交易单号（微信「交易单号」/ 支付宝「交易号」），用于精确判重。
  final String? externalId;

  const BillEntry({
    required this.source,
    required this.date,
    required this.amount,
    required this.isIncome,
    required this.category,
    required this.note,
    this.externalId,
  });

  /// 对应数据库里的 type 取值。
  String get type => isIncome ? 'income' : 'expense';
}

/// 一次账单解析的结果。
class BillParseResult {
  final BillSource source;

  /// 解析出的有效明细。
  final List<BillEntry> entries;

  /// 被跳过的行数（作废、金额缺失、不计收支等）。
  final int skipped;

  /// 解析过程中的提示，通常是「文件看起来不是账单」这类信息。
  final List<String> warnings;

  const BillParseResult({
    required this.source,
    required this.entries,
    this.skipped = 0,
    this.warnings = const [],
  });
}

/// 解析账单 CSV 文本。
BillParseResult parseBillText(String text) => parseBillRows(decodeBillRows(text));

/// 把 CSV 文本切成二维表。
///
/// 先用 csv 包解析（它能正确处理带引号、字段里含逗号的情况）；
/// 万一遇到引号不配对的脏数据导致整份文件被吞成一行，就退回自己按行切，
/// 宁可少认几个引号，也不能把整份账单解析失败。
List<List<String>> decodeBillRows(String text) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  List<List<String>> rows = const [];
  try {
    final parsed = const CsvToListConverter(
      eol: '\n',
      shouldParseNumbers: false,
      allowInvalid: true,
    ).convert(normalized);
    rows = parsed.map((r) => r.map((c) => c?.toString() ?? '').toList()).toList();
  } catch (_) {
    rows = const [];
  }

  final broken = rows.length < 2 || rows.any((r) => r.length > 60);
  if (broken) {
    rows = normalized.split('\n').map(_splitCsvLine).toList();
  }
  return rows;
}

/// 自己按行切 CSV：只处理账单里真实出现过的形态（普通字段、带引号字段、
/// 引号内的逗号与转义引号），不处理跨行字段。
List<String> _splitCsvLine(String line) {
  final out = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (inQuotes) {
      if (ch != '"') {
        buf.write(ch);
      } else if (i + 1 < line.length && line[i + 1] == '"') {
        buf.write('"');
        i++;
      } else {
        inQuotes = false;
      }
    } else if (ch == '"') {
      inQuotes = true;
    } else if (ch == ',') {
      out.add(buf.toString());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  out.add(buf.toString());
  return out;
}

/// 解析账单表格。
///
/// 微信与支付宝的导出文件都在正式表头前加了若干行说明文字，
/// 所以这里不假定第 0 行就是表头，而是先扫描出表头所在行。
BillParseResult parseBillRows(List<List<String>> rows) {
  final warnings = <String>[];

  var headerIndex = -1;
  var source = BillSource.unknown;

  for (var i = 0; i < rows.length; i++) {
    final cells = rows[i].map(_normalizeHeader).toList();
    if (!cells.contains('收/支') || !cells.contains('金额(元)')) continue;
    if (!cells.contains('交易时间') &&
        !cells.contains('交易创建时间') &&
        !cells.contains('付款时间') &&
        !cells.contains('交易号')) {
      continue;
    }
    headerIndex = i;
    source = _detectSource(cells, rows, i);
    break;
  }

  if (headerIndex < 0) {
    warnings.add('没有找到微信/支付宝账单的表头');
    return const BillParseResult(
      source: BillSource.unknown,
      entries: [],
      warnings: ['没有找到微信/支付宝账单的表头'],
    );
  }

  final header = rows[headerIndex].map(_normalizeHeader).toList();
  final col = <String, int>{};
  for (var i = 0; i < header.length; i++) {
    col.putIfAbsent(header[i], () => i);
  }

  final idxTime = col['交易时间'] ??
      col['交易创建时间'] ??
      col['付款时间'] ??
      col['日期时间'];
  final idxDir = col['收/支'];
  final idxAmount = col['金额(元)'];
  final idxType = col['交易类型'] ?? col['类型'];
  final idxParty = col['交易对方'];
  final idxGoods = col['商品'] ?? col['商品名称'];
  final idxStatus = col['当前状态'] ?? col['交易状态'];
  final idxOrderId = col['交易单号'] ?? col['交易号'];

  if (idxTime == null || idxDir == null || idxAmount == null) {
    warnings.add('账单表头缺少必要列');
    return BillParseResult(
      source: source,
      entries: const [],
      warnings: warnings,
    );
  }

  final entries = <BillEntry>[];
  var skipped = 0;

  for (var r = headerIndex + 1; r < rows.length; r++) {
    final row = rows[r];
    if (row.every((c) => c.trim().isEmpty)) continue;

    // 只有一两列的行是装饰行（表尾的分隔线之类），不是数据行，
    // 直接丢掉但不计入「忽略行数」，免得统计出来的数字对不上。
    if (row.length < 3) continue;

    // 微信把作废行整行前缀一个 "/"，是最可靠的作废标记。
    final firstCell = row.first.trim();
    if (firstCell.startsWith('/')) {
      skipped++;
      continue;
    }

    final status = _cell(row, idxStatus);
    if (_isVoidStatus(status)) {
      skipped++;
      continue;
    }

    final type = _cell(row, idxType);
    final party = _cell(row, idxParty);
    final goods = _cell(row, idxGoods);

    final amount = _parseAmount(_cell(row, idxAmount));
    if (amount == null || amount <= 0) {
      skipped++;
      continue;
    }

    final date = _parseBillDate(_cell(row, idxTime));
    if (date == null) {
      skipped++;
      continue;
    }

    final isRefund = _isRefund(type, goods);
    final isIncome = _resolveDirection(_cell(row, idxDir), isRefund);
    if (isIncome == null) {
      // 不计收支（零钱充值/提现这类自己账户之间的搬运）不记。
      skipped++;
      continue;
    }

    final orderId = _cell(row, idxOrderId);
    entries.add(
      BillEntry(
        source: source,
        date: date,
        amount: amount,
        isIncome: isIncome,
        category: guessBillCategory(type, party, goods),
        note: _buildNote(type, party, goods),
        externalId: orderId.isEmpty ? null : orderId,
      ),
    );
  }

  return BillParseResult(
    source: source,
    entries: entries,
    skipped: skipped,
    warnings: warnings,
  );
}

/// 归一化表头：去掉空白、统一全角括号与斜杠、忽略大小写。
///
/// 微信写「金额(元)」，支付宝写「金额（元）」，归一化后两者是同一个 key。
String _normalizeHeader(String cell) {
  var s = cell.replaceAll(RegExp(r'\s'), '');
  s = s.replaceAll('（', '(').replaceAll('）', ')');
  s = s.replaceAll('／', '/').replaceAll('，', ',');
  return s.toLowerCase();
}

/// 判断这份账单是微信的还是支付宝的。
BillSource _detectSource(List<String> header, List<List<String>> rows, int headerIndex) {
  if (header.contains('交易单号')) return BillSource.wechat;
  if (header.contains('交易号') || header.contains('商家订单号')) return BillSource.alipay;

  // 表头没认出，就去前面的说明文字里找平台名。
  final limit = headerIndex < 10 ? headerIndex : 10;
  for (var i = 0; i < limit; i++) {
    final line = rows[i].join(' ');
    if (line.contains('微信支付')) return BillSource.wechat;
    if (line.contains('支付宝')) return BillSource.alipay;
  }
  return BillSource.unknown;
}

String _cell(List<String> row, int? index) {
  if (index == null || index < 0 || index >= row.length) return '';
  return row[index].trim();
}

/// 作废/失败状态。命中的行一律不记。
const List<String> _voidStatusKeywords = [
  '作废',
  '已关闭',
  '交易关闭',
  '关闭',
  '支付失败',
  '交易失败',
  '已取消',
  '交易取消',
  '支付未成功',
  '已撤销',
  '已失效',
  '无效',
];

bool _isVoidStatus(String status) {
  if (status.isEmpty) return false;
  return _voidStatusKeywords.any(status.contains);
}

/// 退款相关关键词。退款一律按「钱回到自己账上」记收入。
const List<String> _refundKeywords = ['退款', '退回', '退货', '返还', '返现'];

bool _isRefund(String type, String goods) {
  return _refundKeywords.any(type.contains) || _refundKeywords.any(goods.contains);
}

/// 判定收支方向。返回 null 表示这一行不计入收支。
bool? _resolveDirection(String rawDirection, bool isRefund) {
  if (isRefund) return true;
  final d = rawDirection.trim();
  if (d == '收入') return true;
  if (d == '支出') return false;
  // 「不计收支」「/」以及认不出来的值都不记，避免把自己的账户搬运记成消费。
  return null;
}

/// 解析金额：容忍货币符号、千分位与「元」后缀。
double? _parseAmount(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  s = s.replaceAll(RegExp(r'[¥￥$,，\s]'), '').replaceAll('元', '');
  if (s.startsWith('+') || s.startsWith('-')) s = s.substring(1);
  final v = double.tryParse(s);
  if (v == null || v.isNaN || v.isInfinite) return null;
  return v;
}

final RegExp _datePattern = RegExp(
  r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?:[ T](\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?',
);

/// 解析账单时间。微信是「2024-10-05 13:45:12」，支付宝历史导出是
/// 「2024-10-05 13:45」或「2024-10-05」，这里都兼容。
DateTime? _parseBillDate(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  final m = _datePattern.firstMatch(s);
  if (m == null) return null;

  final year = int.parse(m.group(1)!);
  final month = int.parse(m.group(2)!);
  final day = int.parse(m.group(3)!);
  final hour = int.tryParse(m.group(4) ?? '') ?? 0;
  final minute = int.tryParse(m.group(5) ?? '') ?? 0;
  final second = int.tryParse(m.group(6) ?? '') ?? 0;

  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  if (hour > 23 || minute > 59 || second > 59) return null;
  return DateTime(year, month, day, hour, minute, second);
}

/// 账户之间搬运的交易类型，统一归到「转账」。
const List<String> _transferTypeKeywords = [
  '转账',
  '收款',
  '红包',
  '群收款',
  '还款',
  '充值',
  '提现',
  '余额宝',
  '亲属卡',
  'AA收款',
  'aa收款',
];

/// 账单分类推断。
///
/// 先看交易类型：转账、还款这类「钱只是换了个地方」的单据归到「转账」，
/// 不能再拿对方名字去猜餐饮购物，否则给张三转 50 块会被记成别的分类。
String guessBillCategory(String type, String party, String goods) {
  if (_transferTypeKeywords.any(type.contains)) return '转账';
  return guessCategory('$party $goods');
}

/// 拼备注：类型、对方、商品，去掉重复的片段。
String _buildNote(String type, String party, String goods) {
  final parts = <String>[];

  void add(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return;
    for (final p in parts) {
      if (p == t || p.contains(t) || t.contains(p)) return;
    }
    parts.add(t);
  }

  add(type);
  add(party);
  add(goods);
  return parts.join(' · ');
}

/// 按 BOM、UTF-8、GBK 的顺序尝试解码账单字节流。
///
/// 支付宝导出的 csv 是 GBK 编码，直接按 UTF-8 读会变成乱码；
/// 而 UTF-8 文件被当成 GBK 读同样会变成乱码（而且不报错，更难发现），
/// 所以这里先用严格的 UTF-8 解码，失败才退到 GBK。
String decodeBillBytes(List<int> bytes) {
  if (bytes.isEmpty) return '';

  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  // UTF-16 的 BOM 有大小端两种，charset 的解码器会自己认。
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
          (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
    return utf16.decode(bytes);
  }

  try {
    return utf8.decode(bytes);
  } on FormatException {
    // 支付宝账单是 GBK/GB18030。
    return gbk.decode(bytes, allowMalformed: true);
  }
}

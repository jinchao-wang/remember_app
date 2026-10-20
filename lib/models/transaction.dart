class Transaction {
  final int? id;
  final double amount;
  final String type;
  final String category;
  final String? note;
  final DateTime date;
  final bool isAuto;
  final bool isEdited;
  final String? sourceApp;

  /// 平台侧的交易单号（微信「交易单号」/ 支付宝「交易号」）。
  ///
  /// 账单导入靠它精确判重：同一个文件导入两次不会产生重复记录，
  /// 而「同金额同时间」的弱匹配会把一天内两笔同价消费误判成重复。
  final String? externalId;

  Transaction({
    this.id,
    required this.amount,
    required this.type,
    required this.category,
    this.note,
    required this.date,
    this.isAuto = false,
    this.isEdited = false,
    this.sourceApp,
    this.externalId,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'amount': amount,
        'type': type,
        'category': category,
        'note': note,
        'date': date.toIso8601String(),
        'isAuto': isAuto ? 1 : 0,
        'isEdited': isEdited ? 1 : 0,
        'sourceApp': sourceApp,
        'externalId': externalId,
      };

  factory Transaction.fromMap(Map<String, dynamic> map) => Transaction(
        id: map['id'] as int?,
        amount: _toDouble(map['amount']) ?? 0,
        type: (map['type'] as String?) ?? 'expense',
        category: (map['category'] as String?) ?? '其他',
        note: map['note'] as String?,
        date: DateTime.tryParse('${map['date']}') ?? DateTime.fromMillisecondsSinceEpoch(0),
        isAuto: _toInt(map['isAuto']) == 1,
        isEdited: _toInt(map['isEdited']) == 1,
        sourceApp: map['sourceApp'] as String?,
        externalId: map['externalId'] as String?,
      );

  static double? _toDouble(Object? v) =>
      v is num ? v.toDouble() : double.tryParse('$v');

  /// SQLite 可能以 int / bool / 字符串返回标志位，统一按 0/1 解析。
  static int? _toInt(Object? v) {
    if (v is num) return v.toInt();
    if (v is bool) return v ? 1 : 0;
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  /// [clearNote] / [clearSourceApp] 用于显式把可空字段置空。
  /// 因为 `note ?? this.note` 无法区分「没传」和「传了 null」，
  /// 直接传 null 会保留旧值，导致用户在编辑页清空备注后保存无效。
  Transaction copyWith({
    int? id,
    double? amount,
    String? type,
    String? category,
    String? note,
    DateTime? date,
    bool? isAuto,
    bool? isEdited,
    String? sourceApp,
    String? externalId,
    bool clearNote = false,
    bool clearSourceApp = false,
    bool clearExternalId = false,
  }) =>
      Transaction(
        id: id ?? this.id,
        amount: amount ?? this.amount,
        type: type ?? this.type,
        category: category ?? this.category,
        note: clearNote ? null : (note ?? this.note),
        date: date ?? this.date,
        isAuto: isAuto ?? this.isAuto,
        isEdited: isEdited ?? this.isEdited,
        sourceApp: clearSourceApp ? null : (sourceApp ?? this.sourceApp),
        externalId: clearExternalId ? null : (externalId ?? this.externalId),
      );

  /// 用于「金额 + 类型 + 分类 + 日期」完全相同且在同一时刻的判重键。
  String get dedupeKey =>
      '$type|$category|${amount.toStringAsFixed(2)}|${date.year}-${date.month}-${date.day}';
}
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
      };

  factory Transaction.fromMap(Map<String, dynamic> map) => Transaction(
        id: map['id'] as int?,
        amount: (map['amount'] as num).toDouble(),
        type: map['type'] as String,
        category: map['category'] as String,
        note: map['note'] as String?,
        date: DateTime.parse(map['date'] as String),
        isAuto: (map['isAuto'] as int) == 1,
        isEdited: (map['isEdited'] as int) == 1,
        sourceApp: map['sourceApp'] as String?,
      );

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
  }) =>
      Transaction(
        id: id ?? this.id,
        amount: amount ?? this.amount,
        type: type ?? this.type,
        category: category ?? this.category,
        note: note ?? this.note,
        date: date ?? this.date,
        isAuto: isAuto ?? this.isAuto,
        isEdited: isEdited ?? this.isEdited,
        sourceApp: sourceApp ?? this.sourceApp,
      );
}
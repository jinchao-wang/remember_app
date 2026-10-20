import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart' hide Transaction;

import '../models/transaction.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._();
  DatabaseHelper._();

  static Future<Database>? _dbFuture;

  Future<Database> get database {
    // 缓存 Future 而不是 Database：首页 IndexedStack 的三个 Tab 会在同一帧
    // 各自触发一次查询，若只缓存 _db 则三者都会看到 null 并并发 openDatabase。
    _dbFuture ??= _init();
    return _dbFuture!;
  }

  Future<Database> _init() async {
    final path = join(await getDatabasesPath(), 'remember_local.db');
    return openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
CREATE TABLE transactions(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  amount REAL NOT NULL,
  type TEXT NOT NULL,
  category TEXT NOT NULL,
  note TEXT,
  date TEXT NOT NULL,
  isAuto INTEGER NOT NULL DEFAULT 0,
  isEdited INTEGER NOT NULL DEFAULT 0,
  sourceApp TEXT,
  externalId TEXT
)
''');
        await db.execute('CREATE INDEX idx_transactions_date ON transactions(date)');
        await db.execute(
          'CREATE INDEX idx_transactions_external ON transactions(externalId)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // v2：账单导入需要用平台交易单号精确判重，加一列可空的 externalId。
        // 加列而不是重建表，是为了不丢用户已有的记录。
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE transactions ADD COLUMN externalId TEXT');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_transactions_external ON transactions(externalId)',
          );
        }
      },
    );
  }

  Future<List<Transaction>> getTransactions() async {
    final db = await database;
    final rows = await db.query('transactions', orderBy: 'date DESC');
    return rows.map((r) => Transaction.fromMap(r as Map<String, dynamic>)).toList();
  }

  Future<int> insertTransaction(Transaction t) async {
    final db = await database;
    return db.insert('transactions', t.toMap());
  }

  Future<void> insertAll(List<Transaction> list) async {
    if (list.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final t in list) {
      // 丢弃 CSV 里带来的旧 id，避免主键冲突导致整批插入失败。
      final values = t.toMap()..remove('id');
      batch.insert('transactions', values as Map<String, Object?>);
    }
    await batch.commit(noResult: true);
  }

  Future<int> updateTransaction(Transaction t) async {
    if (t.id == null) {
      throw ArgumentError('updateTransaction 需要非空 id');
    }
    final db = await database;
    // 不把主键写回 values，避免误改 id。
    final values = t.toMap()..remove('id');
    return db.update(
      'transactions',
      values as Map<String, Object?>,
      where: 'id = ?',
      whereArgs: [t.id],
    );
  }

  Future<int> deleteTransaction(int id) async {
    final db = await database;
    return db.delete('transactions', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteAllTransactions() async {
    final db = await database;
    return db.delete('transactions');
  }
}

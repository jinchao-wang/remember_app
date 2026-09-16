import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/transaction.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._();
  DatabaseHelper._();

  static Database? _db;

  Future<Database> get database async {
    _db ??= await _init();
    return _db!;
  }

  Future<Database> _init() async {
    final path = join(await getDatabasesPath(), 'remember_local.db');
    return openDatabase(
      path,
      version: 1,
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
  sourceApp TEXT
)
''');
        await db.execute('CREATE INDEX idx_transactions_date ON transactions(date)');
      },
    );
  }

  Future<List<Transaction>> getTransactions() async {
    final db = await database;
    final rows = await db.query('transactions', orderBy: 'date DESC');
    return rows.map(Transaction.fromMap).toList();
  }

  Future<int> insertTransaction(Transaction t) async {
    final db = await database;
    return db.insert('transactions', t.toMap());
  }

  Future<void> insertAll(List<Transaction> list) async {
    final db = await database;
    final batch = db.batch();
    for (final t in list) {
      batch.insert('transactions', t.toMap());
    }
    await batch.commit(noResult: true);
  }

  Future<int> updateTransaction(Transaction t) async {
    final db = await database;
    return db.update('transactions', t.toMap(), where: 'id = ?', whereArgs: [t.id]);
  }

  Future<int> deleteTransaction(int id) async {
    final db = await database;
    return db.delete('transactions', where: 'id = ?', whereArgs: [id]);
  }
}
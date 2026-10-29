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
    final pending = _dbFuture;
    if (pending != null) return pending;

    // **失败必须把缓存清掉**：缓存的是 Future，一旦 openDatabase 抛异常，
    // 这个「坏掉的 Future」会被永久缓存下去，进程内每一次查询都跟着抛同一个错。
    //
    // 这正是「App 直接打不开了」的成因之一：启动时读一次设置，
    // 数据库刚好失败（磁盘满、文件损坏、迁移出错），
    // 于是整个 App 每次打开都必然失败，用户怎么重开都没用。
    //
    // 失败后清缓存 + 抛出去，下一次调用会重新尝试打开，App 也就有了自救的可能。
    final future = _init().then<Database>(
      (db) => db,
      onError: (Object error, StackTrace stack) {
        _dbFuture = null;
        Error.throwWithStackTrace(error, stack);
      },
    );
    _dbFuture = future;
    return future;
  }

  /// 关掉当前连接并清掉缓存。
  ///
  /// 出错时给用户一个「重试」的机会：数据库恢复后能重新连上，
  /// 而不是让整个 App 卡在打不开的状态。
  Future<void> reset() async {
    final pending = _dbFuture;
    _dbFuture = null;
    if (pending == null) return;
    try {
      final db = await pending;
      await db.close();
    } catch (_) {
      // 本来就没连上，关不掉就算了。
    }
  }

  Future<Database> _init() async {
    final path = join(await getDatabasesPath(), 'remember_local.db');
    return openDatabase(
      path,
      version: 3,
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
        await db.execute('''
CREATE TABLE app_settings(
  key TEXT PRIMARY KEY,
  value TEXT
)
''');
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
        // v3：用户可配置项（目前只有「跨来源自动去重」）。
        // 之前开关只存在内存里，重启 App 就恢复默认值，
        // 用户明明关掉了却发现又开了。
        if (oldVersion < 3) {
          await db.execute('''
CREATE TABLE IF NOT EXISTS app_settings(
  key TEXT PRIMARY KEY,
  value TEXT
)
''');
        }
      },
    );
  }

  /// 读一个布尔型设置项。
  Future<bool> getBoolSetting(String key, {bool defaultValue = false}) async {
    final db = await database;
    final rows = await db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return defaultValue;
    return parseBoolSetting(rows.first['value'], defaultValue: defaultValue);
  }

  /// 把数据库里存的值解析成布尔。
  ///
  /// **这里以前认不出自己写进去的值**：存的是字符串 '1' / '0'，
  /// 读的时候却只认 'true' / 'false'，于是用户把开关打开（存 '1'），
  /// 重启 App 读回来是 false——开关自己变回关闭，
  /// 跨来源判重也等于被悄悄关掉了。
  ///
  /// 两种写法都得认：老数据里可能有 'true'/'false'，
  /// 新写进去的是 '1'/'0'。认不出来就退回默认值，
  /// 绝不猜——猜错会让用户的设置「自己乱变」。
  static bool parseBoolSetting(Object? v, {required bool defaultValue}) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = '${v ?? ''}'.trim().toLowerCase();
    if (s == 'true' || s == '1') return true;
    if (s == 'false' || s == '0') return false;
    // 空值和认不出来的值一样：退回默认值。
    // 绝不把「空」当成「关」——那会让一个从没设置过的项悄悄变成关闭。
    return defaultValue;
  }

  /// 写一个布尔型设置项。
  Future<void> setBoolSetting(String key, bool value) async {
    final db = await database;
    await db.insert(
      'app_settings',
      {'key': key, 'value': value ? '1' : '0'},
      conflictAlgorithm: ConflictAlgorithm.replace,
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

  /// 撤销删除：把记录原样插回去，**连原来的 id 一起**。
  ///
  /// 滑动删除后给用户一个「撤销」，误删了能救回来。
  /// 必须连 id 一起插回去，否则这条记录在库里的身份就变了
  /// （新 id 会让它排到列表末尾，用户会以为「撤销」没生效）。
  Future<int> restoreTransaction(Transaction t) async {
    final db = await database;
    final values = t.toMap();
    if (values['id'] == null) values.remove('id');
    return db.insert('transactions', values);
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

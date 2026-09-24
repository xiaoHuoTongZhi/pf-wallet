/// `PfDb` 的 sqlite3（FFI）适配器 —— 仓储层在桌面/命令行/CI 下的唯一入口。
///
/// ## 与 `PfTransaction` 的关系
///
/// `database.dart` 的 `PfDatabase` / `PfTransaction` 是给 M2 的移动端服务的
/// （打开/关闭/只读事务/写事务/rekey 一整条生命周期）。仓储层要的只有三件事：
/// 多行读、参数化写、事务边界 —— 那是 [PfDb]。本文件实现的是后者，
/// 因为命令行工具只有"打开→干活→关掉"一条路径，不需要生命周期对象。
///
/// ## 事务里那个不能不说清楚的取舍
///
/// 事务用 `BEGIN IMMEDIATE` 而不是裸 `BEGIN`：马上拿写锁，
/// 让并发冲突以「等」而不是「写了一半才发现拿不到锁」的形式出现
/// （SQLite 的错误码是 `SQLITE_BUSY`，在 WAL 下尤其容易出现）。
///
/// 代价是：**`BEGIN` 之后 `PRAGMA foreign_keys` 就变成空操作**
/// （SQLite 明文规定该 PRAGMA 在事务内无效）。`MigrationRunner` 现在是在
/// 事务内发 `PRAGMA foreign_keys = OFF` 的，也就是说那一句实际没生效。
/// 它不致命（外键约束在 DDL 期不检查，只在 DML 期检查），但"写了却不生效"
/// 必须留痕 —— 要让它生效，只能在 `BEGIN` **之前**发。
/// 这条已记在 docs/M1_RUNBOOK.md §3.5，属于迁移编排的改动，不随本文件一起做。
library;

import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../database.dart' show PfRow, PfSqlitePragma;
import '../db.dart';

/// 把一条已打开的 sqlite3 连接适配成仓储层要的 [PfDb]。
final class Sqlite3Db implements PfDb {
  Sqlite3Db(this._database);

  final sqlite.Database _database;

  /// 是否已在一个事务里。用于把嵌套调用**合并**进外层事务
  /// （与 sqflite 语义一致，见 [PfDb.transaction] 的注释）。
  bool _inTransaction = false;

  @override
  Future<List<PfRow>> query(String sql, {List<Object?> arguments = const <Object?>[]}) async {
    final result = _database.select(sql, arguments);
    return <PfRow>[
      for (final row in result) <String, Object?>{for (final key in row.keys) key: row[key]},
    ];
  }

  @override
  Future<void> run(String sql, {List<Object?> arguments = const <Object?>[]}) async {
    _database.execute(sql, arguments);
  }

  @override
  Future<T> transaction<T>(Future<T> Function(PfDb db) action) async {
    if (_inTransaction) {
      // 合并进外层：内层不单独 BEGIN，也不单独 COMMIT/ROLLBACK。
      // 内层抛错时由外层统一回滚 —— 这正是 sqflite 的行为。
      return action(this);
    }
    _database.execute('BEGIN IMMEDIATE');
    _inTransaction = true;
    try {
      final result = await action(this);
      _database.execute('COMMIT');
      return result;
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    } finally {
      _inTransaction = false;
    }
  }

  /// 执行收尾语句并关闭连接。
  ///
  /// 顺序即 `PfDatabase.close` 的契约：先 `PRAGMA optimize` 与
  /// `wal_checkpoint(TRUNCATE)`（把 WAL 并回主库，否则 `.db-wal` 会留着
  /// 最后一次事务的密文尾巴），再 `dispose`。
  ///
  /// 收尾语句失败**不阻止关闭** —— 一个关不掉的句柄会把失败放大成
  /// 「进程卡住」，而收尾本身是尽力而为。
  void close() {
    try {
      for (final statement in PfSqlitePragma.shutdown) {
        _database.execute(statement);
      }
    } catch (_) {
      // 尽力而为：见上。
    } finally {
      _database.dispose();
    }
  }
}

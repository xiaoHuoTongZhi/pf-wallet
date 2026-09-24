/// `RawSqliteSession` 的 sqlite3 适配器。
///
/// 打开流程（[SqlCipherOpenFlow]）对驱动的全部要求就是这一个方法：
/// 执行一条语句，返回**首行首列**。所以这个文件只有一件事要做对 ——
/// 把「没有行」与「行里的值是 null」区分开：
///
///   - 无行（如 `PRAGMA key = …`、`PRAGMA journal_mode = WAL` 之外的写型语句）
///     → 返回 `null`；
///   - 有行但值是 SQL NULL → 也返回 `null`。
///
/// 两者在打开流程里都只会走到「拿不到可解析的 user_version」那条路上，
/// 后果相同（拒绝打开），所以这里**不额外编码**去区分它们 ——
/// 少一个字段，就少一处能与向量对不上的地方。
library;

import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../open_flow.dart';

/// 把一个已打开的 sqlite3 连接适配成打开流程要求的最小会话。
final class Sqlite3Session implements RawSqliteSession {
  const Sqlite3Session(this._database);

  final sqlite.Database _database;

  /// 执行一条语句并返回首行首列。
  ///
  /// 用 `select` 而不是 `execute`：`execute` 在无参数时走 `sqlite3_exec`，
  /// 它**丢掉结果集** —— 而打开流程要读的正是 `PRAGMA user_version` 的值。
  /// `select` 对两类语句都成立（无结果集的语句返回空结果集）。
  ///
  /// 驱动异常原样抛出，由 [SqlCipherOpenFlow] 交给 `classifySqliteOpenError`
  /// 分类。本层不做任何错误判断 —— 分类逻辑只有那一份。
  @override
  Future<Object?> execute(String statement) async {
    final result = _database.select(statement);
    if (result.isEmpty) return null;
    final values = result.first.values;
    return values.isEmpty ? null : values.first;
  }
}

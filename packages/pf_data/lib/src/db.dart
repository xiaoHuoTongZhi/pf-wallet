/// 仓储层对驱动的抽象（M1）。
///
/// ## 为什么不直接扩展 [RawSqliteSession]
///
/// `RawSqliteSession` 是 §3.4 打开流程对驱动的**最小**要求：
/// 逐条执行语句、取回首行首列。这个契约被 7 条 `db.open.*` 向量锁死，
/// 它的假实现只需十几行 —— 契约每宽一分，假实现与向量就要重一分。
///
/// 仓储层需要的不是"执行一条语句"，而是：
///   - **多行多列**的读（`SELECT` 结果映射成实体）；
///   - **参数化**的写（金额是 int 可以拼接，但 name/note 是用户输入，
///     必须走 `?` 占位符，注入面从根上关掉）；
///   - **事务边界**（余额推演的"写 txn + 更新两个账户"必须是原子的）。
///
/// 把这三件事并成 [PfDb]，而不是塞进 `RawSqliteSession`：
/// 两个契约各自最小、各自可测。M2 的 sqflite_sqlcipher 适配器
/// 对这两个接口各写十几行即可；单测用记录型假实现。
///
/// ## SQL 书写纪律（review 检查项）
///
///   - 值一律参数化（`?` + `arguments`），**唯一例外**是来自编译期
///     常量的整数（如 `PRAGMA user_version = 1`）—— 它不可能是用户输入；
///   - 标识符（表名/列名）只允许出现在本仓源码的字面量里，
///     不允许由变量拼出；
///   - 所有仓储 SQL 集中在 `*_repository.dart` 与 `balance_recalc.dart`，
///     不允许散落在上层。
library;

/// 仓储层对 SQL 驱动的抽象：多行读、参数化写、事务边界。
abstract interface class PfDb {
  /// 执行 `SELECT`，把整个结果集按"行名 → 列值"映射返回。
  ///
  /// 列名与 SQL 方言下的原生类型由驱动透传（如 sqflite 返回
  /// `Map<String, Object?>`）。空结果集返回空列表。
  Future<List<Map<String, Object?>>> query(String sql, {List<Object?> arguments});

  /// 执行一条 DDL / DML / PRAGMA 语句，不取回结果。
  Future<void> run(String sql, {List<Object?> arguments});

  /// 在一个事务里执行 [action]。
  ///
  /// 语义与 SQLite 一致：[action] 正常完成 → COMMIT；
  /// 抛出任何异常 → ROLLBACK 并原样重抛。
  /// 嵌套调用由驱动决定（sqflite 语义：内层事务加入外层），
  /// 本仓的仓储实现**不依赖嵌套事务**。
  Future<T> transaction<T>(Future<T> Function(PfDb db) action);
}

/// 已打开的加密库 —— **`PfDb` 与 `PfDatabase` 的组合点**。
///
/// ## 为什么需要一个「组合点」，而不是让调用方各开一次
///
/// 本仓有两个数据库契约，它们不是同一个东西的两个名字：
///
/// | 契约 | 位置 | 它回答什么 | 谁在用 |
/// |---|---|---|---|
/// | [PfDb] | `src/db.dart` | 多行读 / 参数化写 / 事务边界 | 仓储、`MigrationRunner`、`ImportApplier`、余额重算 |
/// | `PfDatabase` | `src/database.dart` | 打开 / 关闭 / 只读事务 / 写事务 / rekey | M2 移动端的连接生命周期 |
///
/// 打开流程（§3.4）只认识第三个东西：`RawSqliteSession`（逐条执行 + 取首行首列）。
/// 也就是说，一次「打开加密库」的动作会把**三份**互不相认的契约凑到一起。
/// 若不指定一个组合点，五条读写命令就会各自 `open` 一次并各自持有句柄 ——
/// 于是「谁能把库关掉」没有答案，而 SQLite 的写锁在进程内是独占的：
/// 两处各开一次，第二处会以 `database is locked` 的形式失败，
/// 排查方向会被引向「并发写」而不是「重复打开」。
///
/// 因此本类是所有权的**唯一**载体：它持有连接，[db] 把「已打开的库」
/// 交给仓储层那一面，[close] 是唯一的关闭口。
///
/// ## 为什么不实现 `PfDatabase`
///
/// 这是一个**显式决定**，不是遗漏：
///
///   1. `PfDatabase.rekey({newDatabaseKey})` 需要把新密钥拼成
///      `PRAGMA rekey = "x'…'"` —— 那是**第二处让密钥进入 `String` 的地方**。
///      而 `PfSqlitePragma.key` 的文档把「全项目唯一允许让密钥进字符串的位置」
///      写成了硬约束，并由 `guards` 的 `log-secret-interpolation` 守着。
///      在本笔里开这个口子等于悄悄削弱一条安全纪律，而密钥轮换本身
///      属于 M2 的密钥管理（含「什么时候轮换、轮换失败怎么办」）。
///   2. `read` / `write` 交出的是 `PfTransaction`（另一套 query/execute/count 面），
///      而 M1 的五条命令全部只经仓储层，消费者是 [PfDb] —— 实现一个
///      没有消费者的适配面，只会多出一层「看起来接好了、其实是空壳」的代码。
///
/// 于是 M1 的答案是：**命令行侧一律面对 [Sqlite3Database]，它给出 [PfDb] 面**。
/// M2 落地 sqflite_sqlcipher 时，把开库那一行换成 `PfDatabase` 实现即可 ——
/// 五条命令只依赖「一个 PfDb」与「开/关」，那是一次替换，不是重写。
/// （同一判断在 `sqlite3/db.dart` 的文件头已有记录，这里是它的所有权一侧。）
library;

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../db.dart';
import 'db.dart';
import 'engine.dart';

/// 一个已打开、已按 §3.4 配置完毕的加密库。
final class Sqlite3Database {
  Sqlite3Database._(this._db);

  final Sqlite3Db _db;
  bool _closed = false;

  /// 打开（不存在的文件会被创建）一个加密库，并按 §3.4 的顺序跑完
  /// setup 与 post-open 脚本。
  ///
  /// [engine] 必须显式传入而不是在这里 [Sqlite3Engine.bind]：绑定是**进程级**
  /// 的一次性动作（见 `engine.dart` 的文件头），把它藏在本方法里会让
  /// 「这个进程用的是哪个引擎」变成一个隐式的、由调用顺序决定的事实。
  ///
  /// 引擎不可用或不是 SQLCipher 时抛 `PFD_E_ENGINE_*`（在 [engine] 的
  /// `requireUsable` 里就已经抛了，不会走到打开文件这一步）—— 因此
  /// **本方法不会写出一个明文库**：拒绝发生在写盘之前。
  static Future<Sqlite3Database> open({
    required Sqlite3Engine engine,
    required String path,
    required Uint8List databaseKey,
    int plaintextHeaderBytes = 0,
  }) async {
    final sqlite.Database handle = await engine.openEncrypted(
      path: path,
      databaseKey: databaseKey,
      plaintextHeaderBytes: plaintextHeaderBytes,
    );
    return Sqlite3Database._(Sqlite3Db(handle));
  }

  /// 仓储层那一面 —— 这就是「把已打开的库交给这一层用」的那个交接点。
  PfDb get db => _db;

  bool get isOpen => !_closed;

  /// 当前 `user_version`。未打开时抛 [StateError]（而不是返回 0）：
  /// 把「库没打开」和「库是空库」读成同一个 0，会让调用方拿 0 去走
  /// 「空库 → 执行全部迁移」的分支，从而在一个句柄已失效的库上发 DDL。
  Future<int> schemaVersion() async {
    _requireOpen();
    final rows = await _db.query('PRAGMA user_version');
    if (rows.isEmpty) {
      throw StateError('PRAGMA user_version 无结果');
    }
    final raw = rows.first.values.first;
    final parsed = raw is int ? raw : int.tryParse('$raw');
    if (parsed == null || parsed < 0) {
      throw StateError('user_version 不可解析：$raw');
    }
    return parsed;
  }

  /// 关闭连接：先跑收尾 PRAGMA（`optimize` / WAL checkpoint），再释放句柄。
  ///
  /// 幂等 —— 第二次调用什么都不做。这一点是必需的：五条命令的
  /// `finally` 分支都会关它，而「关两次」若抛错，会把一个已经成功的
  /// 命令变成失败。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _db.close();
  }

  void _requireOpen() {
    if (_closed) {
      throw StateError('库已关闭，不能再执行语句');
    }
  }
}

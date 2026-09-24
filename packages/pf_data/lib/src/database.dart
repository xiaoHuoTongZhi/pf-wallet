/// SQLCipher 数据库访问契约。
///
/// M0 只定义契约，不提供实现 —— 具体 DAO 与建表 SQL 属 M1。
/// 但 PRAGMA 配置属于**安全设置**，必须在动手写业务代码之前就定下来，
/// 因此提前钉在这里。
library;

import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';

/// 一行查询结果。
typedef PfRow = Map<String, Object?>;

/// 事务内的操作句柄。
///
/// 只暴露「执行语句」这一种能力，没有暴露连接、没有暴露 prepare 缓存 ——
/// 调用方无法绕过事务边界，也无法持有跨事务的语句句柄。
abstract interface class PfTransaction {
  /// 查询并返回全部行。
  Future<List<PfRow>> query(String sql, [List<Object?> parameters = const <Object?>[]]);

  /// 执行写语句，返回受影响行数。
  Future<int> execute(String sql, [List<Object?> parameters = const <Object?>[]]);

  /// 执行 COUNT 类查询并返回单个整数。
  Future<int> count(String sql, [List<Object?> parameters = const <Object?>[]]);
}

/// 数据库连接。
abstract interface class PfDatabase {
  /// 连接是否已打开。
  bool get isOpen;

  /// 当前 schema 版本。未打开时返回 0。
  int get schemaVersion;

  /// 打开数据库。
  ///
  /// [databaseKey] 是 32 字节 DEK，来自 `pf_crypto` 的密钥保险箱。
  /// 实现必须在打开后立即执行 [PfSqlitePragma.securityRequired] 中的全部语句。
  Future<void> open({required Uint8List databaseKey});

  /// 关闭连接。
  ///
  /// 实现必须在关闭前执行 `PRAGMA optimize` 与 WAL checkpoint，
  /// 并把 DEK 从内存中清零。
  Future<void> close();

  /// 只读事务。
  Future<T> read<T>(Future<T> Function(PfTransaction transaction) action);

  /// 读写事务。
  ///
  /// 实现必须保证：异常时回滚、嵌套调用合并进同一个事务（不做 savepoint 嵌套），
  /// 以及**同一时刻只允许一个写事务**（SQLite 的写锁本身也是这个语义，
  /// 显式串行化可以让冲突以"排队"而不是"database is locked"的形式出现）。
  Future<T> write<T>(Future<T> Function(PfTransaction transaction) action);

  /// 修改数据库密钥（`PRAGMA rekey`）。
  ///
  /// 只在「用户重置了全部密钥」时使用。日常改主密码**不需要**调用它 ——
  /// 因为 DEK 不变，只重新包裹即可。
  Future<void> rekey({required Uint8List newDatabaseKey});
}

/// 打开连接后必须立即执行的 PRAGMA。
///
/// ## 已收回的安全收紧：`trusted_schema = OFF`
///
/// M0 曾在 [securityRequired] 与 [postOpen] 里各加过一条
/// `PRAGMA trusted_schema = OFF`（§3.4 未列，属于自加的加固）。
/// **#5b 第二笔把它收回**。这里写清三件事 —— 否则后来的人只会看到
/// 一条离席的加固，读不出这是刻意收回还是漏掉了。
///
/// ### 为何收回
///
/// 它与定版的 schema 互斥。`schema_v1.dart` 的 `txn.tags` 与
/// `theme_profile.spec_json` 两列带 `CHECK (json_valid(…))`，而定版
/// SQLCipher 4.5.2 绑的是 **SQLite 3.39.2** —— 在 `trusted_schema = OFF`
/// 下 `json_valid()` 被判为 *unsafe use*，**建表与写入都会报
/// `unsafe use of json_valid(), SQL logic error`**。
/// 于是 `pf init` 连表都建不出来，五条读写命令全部不可达。
///
/// 实测（`sqlite3_exec` 直调两份定版件，同一段 SQL）：
/// `e_sqlcipher`（SQLite **3.39.2**）**FAIL**、`e_sqlite3`（SQLite **3.49.1**）**PASS**
/// —— 差别只在 SQLite 版本，上游后来把 JSON 函数标成了 `SQLITE_INNOCUOUS`。
/// 不是我们的 SQL 写错，是引擎太旧。
/// 又因为 **INSERT 同样被拒**，「建表时临时 ON、建完再 OFF」不是出路。
///
/// ### 什么条件下拿回
///
/// 当**所有目标平台**（含 M2 移动端）随库链接的 SQLCipher 都绑定
/// SQLite ≥ 标了 `SQLITE_INNOCUOUS` 的那个版本时。
///
/// 在那之前，这条加固防的是一个**空集**：它拦的是「schema 里的视图/触发器
/// 调用应用自定义函数」，而本应用**从不注册自定义 SQL 函数**
/// （全仓 `createFunction` 调用数为 0），这条路径根本不存在。
/// 它换掉的却是一条真实的完整性检查 —— `json_valid` 防的是
/// 「应用自己写进坏 JSON」，离 bug 更近。
///
/// ### 拿回时要做什么
///
/// 1. 把两条 `PRAGMA trusted_schema = OFF` 加回本文件（[securityRequired]
///    与 [postOpen]）；
/// 2. 同步 `tools/golden_vectors_gen/db_open.py` 的 [postOpen] 转录，并重新
///    `python tools/golden_vectors_gen/db_open.py --write` ——
///    `test_vectors/v1/db_open.json` 把脚本文本**逐字**钉死了，不同步必红；
/// 3. **重跑 `tools/pf_cli/test/roundtrip_test.dart`**（需定版 SQLCipher，
///    先 `melos run engine:fetch`）。
///
/// 第 3 步是关键判据：那份 DDL 在 `roundtrip_test` 之前**没有任何真实执行者**
/// （其余测试对「安全 PRAGMA 清单」与「建表 DDL」都只做文本断言），
/// 这正是这个冲突能一路潜伏到 `pf init` 真的存在才暴露的原因。
/// **只在 DDL 真实执行通过之后，才算拿回的时机到了。**
abstract final class PfSqlitePragma {
  /// 数据库密钥的字节长度。
  static const int databaseKeyLength = 32;

  /// 整库加密密钥。
  ///
  /// 使用**原始密钥模式**（`x'...'`）而不是口令模式：
  /// 我们的 DEK 已经是 32 字节高熵随机数，SQLCipher 的口令模式会再跑一遍
  /// 它自己的 KDF（默认 256000 轮 PBKDF2），白白增加数百毫秒解锁耗时，
  /// 且不增加任何安全性 —— 随机密钥的熵已经用满了。
  ///
  /// ## 这里为什么必须把密钥放进 String（以及代价是什么）
  ///
  /// 原始密钥模式的语法要求 `PRAGMA key = "x'<64 位十六进制>'"`，
  /// 而 SQLCipher 的 Dart 绑定（sqflite_sqlcipher）只接受 String 形式的 key。
  /// 也就是说：**密钥必然以密文以外的一种明文形式存在于 Dart 堆上一次**。
  ///
  /// 不能含糊过去，代价说清楚：
  ///   - Dart 的 `String` 不可变，无法清零；这份十六进制只会等 GC 回收。
  ///     见 `pf_core` 的 `zeroize`，那里对这件事的边界有完整说明。
  ///   - 缓解措施有三条，都是结构性的而非流程性的：
  ///     1. 这个函数是全项目**唯一**允许让密钥进入字符串的地方。
  ///        其它位置出现同类写法会被 `guards` 的 `log-secret-interpolation` 拦下。
  ///     2. 返回值只交给数据库驱动的 open 调用，不参与任何插值、日志、异常消息
  ///        （`PfLogger` 的字段白名单里根本没有可以承载它的字段）。
  ///     3. 明文库文件不存在：库文件本身由 SQLCipher 加密，
  ///        因此即使这份字符串被 dump，拿到的也只是「已经能解开库的密钥」——
  ///        攻击者要读到它，前提是已经能在进程内存里翻找，
  ///        那种情况下密钥本来就已经暴露。
  ///
  /// 之所以要写这么长：这条 suppression 是本项目唯一的密钥外露点，
  /// 后来的改动者必须能一眼看出「这是刻意的，以及为什么可以接受」，
  /// 而不是以为顺手漏了一条规则。
  ///
  /// 注意下面那条 suppression 的位置不能改动 —— 抑制指令只对
  /// 紧随其后的两个逻辑单元生效（见 `tools/guards/lib/scan.dart`）。
  // guards:ignore log-secret-interpolation
  static String key(Uint8List dek) {
    final actualLength = dek.length;
    if (actualLength != databaseKeyLength) {
      // 只插值长度，不插值密钥本身。
      throw DomainError.validation(detail: '数据库密钥必须为 $databaseKeyLength 字节，实际 $actualLength');
    }
    // guards:ignore log-secret-interpolation
    return "PRAGMA key = \"x'${toHex(dek)}'\"";
  }

  /// 安全必需的 PRAGMA。任何一项缺失都视为实现缺陷。
  ///
  /// 这是**审计集**（只查"有没有"，不查顺序）；有顺序要求的完整打开脚本
  /// 见 [openSetup] 与 [postOpen]。二者覆盖本清单的全部语句。
  ///
  /// 逐条理由：
  ///   - `temp_store = MEMORY`：SQLite 默认把排序 / 聚合的溢出数据写到磁盘临时文件，
  ///     而那个文件**是明文的**。一次 `ORDER BY amount DESC` 或 `GROUP BY category`
  ///     就会在设备临时目录留下明文片段。这是本清单里最重要的一条。
  ///   - `journal_mode = WAL`：WAL 文件由 SQLCipher 加密，保留它换取并发性能。
  ///   - `foreign_keys = ON`：SQLite 默认关闭外键约束，不打开会静默产生孤儿记录。
  ///   - `secure_delete = ON`：删除时覆写页内容，而不是只标记空闲。
  ///   - `cipher_memory_security = ON`：SQLCipher 释放内存页时清零，
  ///     防止密钥与明文残留在已 free 的堆块里。
  ///
  /// 这里**故意没有** `trusted_schema = OFF`：M0 加过、#5b 第二笔收回。
  /// 理由（与定版 SQLite 3.39.2 上的 `json_valid` 互斥）、恢复条件、
  /// 以及恢复时必须补做的事，全部写在 [PfSqlitePragma] 的类文档里 ——
  /// **不要**在没有重跑 `roundtrip_test.dart`（那份 DDL 唯一的真实执行者）
  /// 的情况下把它加回来。
  static const List<String> securityRequired = <String>[
    'PRAGMA temp_store = MEMORY',
    'PRAGMA journal_mode = WAL',
    'PRAGMA foreign_keys = ON',
    'PRAGMA secure_delete = ON',
    'PRAGMA cipher_memory_security = ON',
  ];

  /// 关闭连接前执行的收尾语句。
  static const List<String> shutdown = <String>[
    'PRAGMA optimize',
    'PRAGMA wal_checkpoint(TRUNCATE)',
  ];

  /// `cipher_compatibility` 锁定的 SQLCipher 大版本（§3.4 ②）。
  ///
  /// 显式锁版本：SQLCipher 5 若改默认参数，不锁定会导致"升级后老库打不开"。
  static const int cipherCompatibility = 4;

  /// 加密页大小（§3.4 ③）。建库与开库必须一致；4 KiB 是 SQLCipher 4.x 默认。
  static const int cipherPageSize = 4096;

  /// iOS 明文头的字节数（§3.4 iOS 特例，推荐 32）。
  static const int iosPlaintextHeaderBytes = 32;

  /// 打开连接**之前**必须执行的有序脚本（§3.4 ①–⑤，顺序不可换）。
  ///
  ///   1. （iOS）`cipher_plaintext_header_size` —— 必须在 key **之前**声明，
  ///      且与建库时的值一致；否则头 32 字节明文会被当作密文参与解密，
  ///      整库都解不开。该值在建库时定死，之后不可更改。
  ///   2. `key`（原始密钥模式，见 [key]）
  ///   3. `cipher_compatibility = 4` —— 在 key 之后立即锁版本，
  ///      避免后续任何按默认参数解读密文的余地。
  ///   4. `cipher_page_size = 4096`
  ///   5. `cipher_memory_security = ON`
  ///   6. `foreign_keys = ON`
  ///
  /// [plaintextHeaderBytes] 只允许 [iosPlaintextHeaderBytes]（iOS）或 0
  /// （Android/桌面，完全加密头）。§3.4 允许两端头策略不同 ——
  /// 库文件本来就不跨端传输（跨端走 `.pfb` 导出）。
  static List<String> openSetup(Uint8List dek, {int plaintextHeaderBytes = 0}) {
    if (plaintextHeaderBytes != 0 && plaintextHeaderBytes != iosPlaintextHeaderBytes) {
      throw DomainError.validation(
        detail: '明文头字节数只允许 0 或 $iosPlaintextHeaderBytes，实际 $plaintextHeaderBytes',
      );
    }
    return <String>[
      if (plaintextHeaderBytes > 0) 'PRAGMA cipher_plaintext_header_size = $plaintextHeaderBytes',
      key(dek),
      'PRAGMA cipher_compatibility = $cipherCompatibility',
      'PRAGMA cipher_page_size = $cipherPageSize',
      'PRAGMA cipher_memory_security = ON',
      'PRAGMA foreign_keys = ON',
    ];
  }

  /// 打开并验证密钥**之后**执行的有序脚本（§3.4 ⑦ + M0 增补）。
  ///
  /// 顺序即 [openSetup] 之后的执行顺序：
  ///   - `journal_mode = WAL` 先行（影响后续所有写路径的文件布局）；
  ///   - `synchronous = NORMAL`（WAL 下只可能丢最后一个事务，不损坏库）；
  ///   - `busy_timeout = 5000`；
  ///   - `temp_store = MEMORY`（安全要求，见 [securityRequired]）；
  ///   - `secure_delete = ON`。
  ///
  /// 审计不变式：[openSetup]（去 key 行）与本列表的**并集** ⊇
  /// [securityRequired]（由单元测试钉死 —— `foreign_keys` 在 setup 段，
  /// 其余在本列表）。
  ///
  /// `trusted_schema = OFF`（M0 增补）**已收回**，见类文档。
  static const List<String> postOpen = <String>[
    'PRAGMA journal_mode = WAL',
    'PRAGMA synchronous = NORMAL',
    'PRAGMA busy_timeout = 5000',
    'PRAGMA temp_store = MEMORY',
    'PRAGMA secure_delete = ON',
  ];
}

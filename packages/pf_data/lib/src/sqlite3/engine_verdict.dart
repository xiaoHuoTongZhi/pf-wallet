/// 引擎身份判据（§3.4 的前置条件）—— **纯函数，不含任何 FFI**。
///
/// ## 为什么判据必须与探测分开
///
/// 「打开一个原生库、读一条 PRAGMA」这件事本身没法在任意平台上跑
/// （CI 的 macOS 上没有 `winsqlite3.dll`，Windows 上没有 `libsqlite3.so`），
/// 但**判定规则**必须处处一致、处处可测。于是：
///
///   - 本文件只回答「给定这次观察到的事实，结论是什么」——输入是字符串，
///     输出是一个枚举，没有任何分支依赖运行环境；
///   - 真正的探测与加载在 `engine.dart`，它负责把事实采集出来。
///
/// 这样切分之后，「纯 SQLite 必须被拦下」这条最关键的规则有了
/// 不依赖任何原生库的单元测试；而 FFI 那一层只剩"搬运数据"。
///
/// ## 判据为什么只有一条
///
/// 判定「这个库是不是 SQLCipher」的**唯一**可靠信号是
/// `PRAGMA cipher_version` 的**行数**：
///
///   | 引擎 | `PRAGMA cipher_version` | 写出的库文件头 |
///   |---|---|---|
///   | SQLCipher 4.5.2 | 1 行 `4.5.2 community` | 密文 |
///   | 纯 SQLite 3.51（`winsqlite3.dll`） | **0 行** | `SQLite format 3\0` |
///
/// 不用「有没有报错」当判据，因为纯 SQLite 对全部 `cipher_*` PRAGMA
/// 都返回成功；不用 `sqlite3_libversion()` 当判据，因为 SQLCipher 的
/// 那个值报的是**它内嵌的 SQLite 版本**（`3.39.2`），与加密能力无关。
/// 这两个错误判据都试过，都在实测中被证伪（见 docs/M1_RUNBOOK.md §3.3）。
library;

import 'package:pf_core/pf_core.dart';

/// 一次引擎探测观察到的事实。
///
/// 全部字段都是「已经测出来的字符串」，没有任何需要再解析的结构 ——
/// 判据因此可以逐条写死。
final class EngineObservation {
  const EngineObservation({
    required this.libraryLabel,
    required this.libraryPath,
    this.loadError,
    this.sqliteVersion,
    this.cipherVersion,
  });

  /// 人读的候选名（如 `vendored` / `winsqlite3` / `platform-default`）。
  final String libraryLabel;

  /// 库文件路径。平台默认加载时它是空串（`package:sqlite3` 自己决定路径）。
  final String libraryPath;

  /// 加载或查询失败的原因。非空 ⇒ 这个候选根本没跑起来。
  final String? loadError;

  /// `sqlite3_libversion()`。**不用于判定**（见文件头说明），只用于报告。
  final String? sqliteVersion;

  /// `PRAGMA cipher_version` 的首行首列。空串或 null ⇒ 不是 SQLCipher。
  final String? cipherVersion;

  /// 库是否成功加载（含后面的身份查询）。
  bool get loaded => loadError == null;

  /// 是否探到了 SQLCipher 的身份串。
  bool get hasCipherVersion => cipherVersion != null && cipherVersion!.isNotEmpty;
}

/// 引擎的种类。只有三种，且互斥穷尽。
enum EngineKind {
  /// 真正的 SQLCipher：可以拿来做整库加密。
  sqlCipher,

  /// 能打开、能执行 SQL，但**没有加密层**。绝不允许拿它建库。
  plainSqlite,

  /// 库加载不出来（找不到 / 架构不对 / 缺符号）。
  unavailable,
}

/// 判定结论。
final class EngineVerdict {
  const EngineVerdict({required this.kind, required this.reason, required this.observation});

  /// 种类。
  final EngineKind kind;

  /// 判定依据（稳定措辞，直接进 CI 日志与命令行输出）。
  final String reason;

  /// 据以判定的事实。
  final EngineObservation observation;

  /// 是否可以直接用于建库/开库。
  bool get isSqlCipher => kind == EngineKind.sqlCipher;
}

/// 由观察到的事实得出结论。**这是判定规则的唯一定义处。**
///
/// 顺序即优先级：加载失败 → 不可用；加载成功但没有身份串 → 纯 SQLite；
/// 有身份串 → SQLCipher。三条互斥且穷尽。
EngineVerdict judgeEngine(EngineObservation observation) {
  if (!observation.loaded) {
    return EngineVerdict(
      kind: EngineKind.unavailable,
      reason: '原生库加载失败：${observation.loadError}',
      observation: observation,
    );
  }
  if (!observation.hasCipherVersion) {
    return EngineVerdict(
      kind: EngineKind.plainSqlite,
      reason:
          '库能加载（sqlite3_libversion=${observation.sqliteVersion ?? '?'}）'
          '但 PRAGMA cipher_version 返回 0 行 ⇒ 这是纯 SQLite，没有加密层。'
          '它会把全部 cipher_* PRAGMA 静默接受，然后写出一份明文库文件。',
      observation: observation,
    );
  }
  return EngineVerdict(
    kind: EngineKind.sqlCipher,
    reason: 'cipher_version=${observation.cipherVersion}',
    observation: observation,
  );
}

/// 判定 → 错误。要求引擎必须是 SQLCipher，否则抛 [PfError]。
///
/// 这个方法就是「不静默跳过」的落点：**调用方在拿到一个可用的
/// [PfDb] 之前必须先过这一关**，而不是先连上、等写盘时才发现写的是明文。
///
/// 两类失败分开编码，因为处置不同：
///   - [EngineKind.unavailable] → [PfErrorCode.storageEngineUnavailable]
///     （环境缺东西：装库、改路径、换架构）
///   - [EngineKind.plainSqlite] → [PfErrorCode.storageEngineNotCipher]
///     （拿错了库：换一个 SQLCipher 构建）
void requireSqlCipher(EngineVerdict verdict) {
  switch (verdict.kind) {
    case EngineKind.sqlCipher:
      return;
    case EngineKind.unavailable:
      throw StorageError.engineUnavailable(detail: verdict.reason);
    case EngineKind.plainSqlite:
      throw StorageError.engineNotCipher(detail: verdict.reason);
  }
}

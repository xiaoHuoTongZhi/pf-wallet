/// SQLCipher 打开流程编排（§3.4）—— 纯 Dart，可向量、可单测。
///
/// ## 为什么编排器不直接持有连接
///
/// §3.4 的打开流程 = 一段**有序的 PRAGMA 脚本 + 一次密钥验证读 + 一组错误分类**。
/// 把它与具体驱动（drift / sqflite_sqlcipher / sqlite3 FFI）解耦后：
///
///   - 脚本顺序、密钥格式、`user_version` 检查、`_isCipherKeyError` 的错误映射
///     全部能在 `dart test` 上验证 —— 不需要原生 SQLCipher；
///   - M2 的真实驱动只需实现 [RawSqliteSession]（十几行的适配器），
///     打开流程的正确性由本层一次性保证，驱动层不再各自为政。
///
/// ## 与 §3.4 的对应关系
///
///   - ①–⑤（key / cipher_compatibility / cipher_page_size / cipher_memory_security /
///     foreign_keys，及 iOS 明文头）→ [PfSqlitePragma.openSetup]；
///   - ⑥（`PRAGMA user_version` 作为第一个真实 IO + `_isCipherKeyError`）
///     → 本文件的 [classifySqliteOpenError] 与 [SqlCipherOpenFlow.open] 的版本检查；
///   - ⑦（journal_mode / synchronous / busy_timeout / temp_store / secure_delete）
///     → [PfSqlitePragma.postOpen]。
///
/// 注意：迁移编排（user_version < 支持版本时跑迁移计划）**不属于**
/// 本流程 —— 那是打开成功之后的事，由 M2 的数据库服务编排。
/// 本流程只负责"密钥对不对、库能不能读、版本会不会太高"。
library;

import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';

import 'database.dart';

/// 一个已建立、尚未配置的 SQLCipher 会话。
///
/// 这是打开流程对驱动的**全部**要求：能逐条执行语句并取回首行首列。
/// M2 的 drift / sqlite3 适配器各写十几行即可满足；
/// 单元测试与向量驱动用内存假实现。
abstract interface class RawSqliteSession {
  /// 执行一条语句，返回结果集首行首列（无行时返回 null）。
  ///
  /// 失败时抛驱动原生异常（如 drift 的 `SqliteException`）；
  /// [SqlCipherOpenFlow] 会把它们交给 [classifySqliteOpenError] 分类。
  Future<Object?> execute(String statement);
}

/// §3.4 的打开流程编排。
final class SqlCipherOpenFlow {
  const SqlCipherOpenFlow({this.maxSchemaVersion = PfSchema.current});

  /// 本实现支持的 schema 上限。超过即拒绝打开（R1 只进不退：旧版 App
  /// 打开新版库必须拒绝并提示升级，绝不能"试着读读看"）。
  final int maxSchemaVersion;

  /// 按 §3.4 的顺序打开一个加密库。
  ///
  /// [plaintextHeaderBytes] 默认 0（Android/桌面，完全加密头）；iOS 由
  /// 调用方显式传 [PfSqlitePragma.iosPlaintextHeaderBytes]。平台判断不
  /// 在本层 —— 该值建库时定死，决策权在建库/开库同层的调用方。
  ///
  /// 成功 = 全部 setup 与 post-open 语句执行完毕，且 `user_version` 可读、
  /// 不超过 [maxSchemaVersion]。失败一律抛 [PfError] 子类，错误码见
  /// [classifySqliteOpenError] 与 `PFD_E_SCHEMA_TOO_NEW`。
  Future<void> open({
    required RawSqliteSession session,
    required Uint8List databaseKey,
    int plaintextHeaderBytes = 0,
  }) async {
    // ①–⑤：key 前的声明 + key + cipher 参数（有序，见 openSetup 的文档）。
    for (final statement in PfSqlitePragma.openSetup(
      databaseKey,
      plaintextHeaderBytes: plaintextHeaderBytes,
    )) {
      await _execute(session, statement);
    }

    // ⑥：密钥验证。`PRAGMA user_version` 是开库后的第一个真实 IO ——
    // 密钥错误时 SQLCipher 在这里才会以"file is not a database"失败
    // （setup 阶段的 PRAGMA 都是本地配置，不触发解密）。
    final raw = await _execute(session, 'PRAGMA user_version');
    final userVersion = _parseUserVersion(raw);
    if (userVersion > maxSchemaVersion) {
      throw StorageError.schemaTooNew(found: userVersion, supported: maxSchemaVersion);
    }
    // user_version == 0 → 尚未初始化的新库，由建库/迁移流程接管；
    // 0 < user_version ≤ max → 正常老库；< max 的迁移由上层编排，不在本流程。

    // ⑦：常规 PRAGMA（WAL / synchronous / busy_timeout / temp_store / …）。
    for (final statement in PfSqlitePragma.postOpen) {
      await _execute(session, statement);
    }
  }

  Future<Object?> _execute(RawSqliteSession session, String statement) async {
    try {
      return await session.execute(statement);
    } on PfError {
      rethrow;
    } catch (error) {
      // 驱动原生异常（无类型依赖，只能拿 toString 的消息）。
      // M2 的真实适配器若想用精确的扩展错误码，可以自己先调
      // [classifySqliteOpenError] 再抛 —— 分类逻辑只有这一份。
      throw classifySqliteOpenError(message: error.toString());
    }
  }

  int _parseUserVersion(Object? raw) {
    final int value;
    if (raw is int) {
      value = raw;
    } else {
      final parsed = int.tryParse('$raw');
      if (parsed == null) {
        // user_version 读回来不是整数 → 页面解出来的不是合法 SQLite 头，
        // 与 NOTADB 同级：按库损坏/被换处理。
        throw StorageError.openFailed(cause: StateError('user_version 不可解析: $raw'));
      }
      value = parsed;
    }
    if (value < 0) {
      throw StorageError.openFailed(cause: StateError('user_version 为负数: $value'));
    }
    return value;
  }
}

/// SQLite 打开期错误的分类（§3.4 `_isCipherKeyError` 的对接点）。
///
/// 分类只依据两样东西：**消息文本**与**结果码** —— 都是纯数据，
/// 因此本函数可被向量锁死，也与任何驱动类型解耦。
///
/// 判定顺序（先具体后一般）：
///
///   1. `file is not a database`（SQLITE_NOTADB，主码 26）：
///      **加密层无法区分**「密钥错」与「库文件被换/坏」——两者都是认证失败
///      （与 keyCheck 的 AAD 篡改同理，见 KeyringCore.verifyKeyCheck 的注释）。
///      - [keyVerifiedViaKeyCheck] = false → [KeyringError.wrongPassword]
///        （§3.4 原文：直接映射密码错）。
///      - = true（调用前 keyCheck 已通过，密钥已证明正确）→
///        [StorageError.openFailed]：密钥对而库读不出，只能是库文件本身
///        损坏或被替换。App 层据此走"库损坏"而不是"密码错"提示。
///   2. `database disk image is malformed`（SQLITE_CORRUPT，主码 11）：
///      明确的损坏信号（含 WAL 损坏），→ [StorageError.openFailed]。
///   3. 其余 → [StorageError.openFailed]（打开期失败的一般兜底：
///      磁盘 IO、文件锁、权限等）。**不**往密码错上猜 ——
///      密码错只有 NOTADB 一种表现，放宽匹配只会制造误报。
///
/// 注意主码提取：SQLCipher/sqlite3 抛出的扩展码低 8 位即主码
/// （`extendedResultCode & 0xFF`），因此同时接受原始扩展码。
PfError classifySqliteOpenError({
  required String message,
  int? resultCode,
  bool keyVerifiedViaKeyCheck = false,
}) {
  final code = resultCode == null ? null : resultCode & 0xFF;
  final lower = message.toLowerCase();
  final isNotADb = lower.contains('file is not a database') || code == 26;
  if (isNotADb) {
    if (keyVerifiedViaKeyCheck) {
      return StorageError.openFailed(cause: StateError('密钥已验证但库打不开（NOTADB）：库文件损坏或被替换'));
    }
    return KeyringError.wrongPassword();
  }
  return StorageError.openFailed(cause: StateError(message));
}

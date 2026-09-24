/// SQLCipher 原生引擎的**加载与身份自检**。
///
/// ## 这个文件解决什么问题
///
/// `package:sqlite3` 在 Windows 上会依次尝试 `sqlite3.dll` 与
/// `winsqlite3.dll`，在 Linux/macOS 上加载系统自带的 `libsqlite3`。
/// **这些都不是 SQLCipher**，而它们对"我是不是 SQLCipher"这件事
/// 不报任何错：
///
/// ```
/// PRAGMA key = "x'…'";                 -- 纯 SQLite：静默成功
/// PRAGMA cipher_page_size = 4096;      -- 纯 SQLite：静默成功
/// CREATE TABLE t(a);                  -- 纯 SQLite：真的建了表
/// ```
///
/// 结果是：打开流程"全部成功"，库文件写出来了，而文件头是
/// `SQLite format 3\0` —— **明文**。这类事故不会让任何一条既有测试变红，
/// 因为它没有失败，它只是悄悄地什么都没加密。
///
/// 因此本层的职责是：在把任何 [PfDb] 交出去之前，先问引擎一句
/// `PRAGMA cipher_version`，拿不到身份串就拒绝继续（见 `engine_verdict.dart`）。
///
/// ## 为什么是「一个进程一个引擎」
///
/// `package:sqlite3` 把已加载的句柄缓存在模块级变量里（`_sqlite3 ??= …`），
/// 首次访问之后**无法更换**。本类把这件事实显式化：
/// 第二次用不同路径调用 [bind] 会抛 [StateError]，而不是静默复用旧引擎 ——
/// 「我到底在测哪个引擎」这个问题必须永远有确定答案。
///
/// 需要对比多个候选库时，**换进程**（`pf engine --engine-lib …` 各跑一次），
/// 不要试图在一个进程里换库。
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../open_flow.dart';
import 'engine_verdict.dart';
import 'session.dart';

/// 环境变量：指定 SQLCipher 动态库路径。
///
/// 名字里带 `SQLCIPHER` 而不是 `SQLITE3` 是刻意的 ——
/// 它必须是一个**带加密层**的构建，而 `sqlite3.dll` 这个名字
/// 恰好对应最容易被误用的那个东西。
const String kSqlCipherLibraryEnvVar = 'PF_SQLCIPHER_LIB';

/// 已绑定的 SQLCipher 引擎。
final class Sqlite3Engine {
  Sqlite3Engine._(this._handle, this.verdict);

  final sqlite.Sqlite3 _handle;

  /// 身份判定结果。**调用方必须先看它**（或直接调 [requireUsable]）。
  final EngineVerdict verdict;

  // ---------------------------------------------------------------------------
  // 进程级绑定
  // ---------------------------------------------------------------------------

  static Sqlite3Engine? _instance;
  static String? _instancePath;

  /// 等待加载的库路径。做成静态字段而不是闭包捕获，
  /// 是因为 `package:sqlite3` 要求这个回调在跨 isolate 时也能用
  /// （闭包捕获的是某个 isolate 的堆，静态方法不是）。
  static String? _pendingPath;

  /// 加载 [libraryPath] 指向的动态库并完成身份自检。
  ///
  /// [libraryPath] 为 null 时**不覆盖** `package:sqlite3` 的平台默认选择
  /// （Windows：`sqlite3.dll` → `winsqlite3.dll`；Linux/macOS：系统库）。
  /// 这条路径存在的意义就是：没有显式给出 SQLCipher 库时，
  /// 自检会以 `PFD_E_ENGINE_NOT_CIPHER` 失败，而不是悄悄降级成明文。
  ///
  /// [libraryLabel] 只影响报告里的人读名字。
  static Sqlite3Engine bind({String? libraryPath, String libraryLabel = 'platform-default'}) {
    final bound = _instance;
    if (bound != null) {
      _guardRebind(libraryPath);
      return bound;
    }

    final observation = observeLibrary(libraryPath: libraryPath, libraryLabel: libraryLabel);
    final verdict = judgeEngine(observation);
    // 加载失败时不留绑定：下一次调用可以用另一个路径重试
    // （这也是单测里「先试错的、再试对的」能跑通的原因）。
    if (!observation.loaded) {
      throw StorageError.engineUnavailable(detail: verdict.reason, cause: observation.loadError);
    }
    final engine = Sqlite3Engine._(sqlite.sqlite3, verdict);
    _instance = engine;
    _instancePath = libraryPath;
    return engine;
  }

  /// 采集一次观察到的事实。**不抛业务异常** —— 加载失败也是一种事实。
  ///
  /// 这个函数是 `pf engine` 的全部依赖：它回答「这个库能不能打开、
  /// 打开了是什么引擎」，而**不做任何裁决**。裁决在 [judgeEngine]
  /// 与 [requireSqlCipher]（`engine_verdict.dart`）—— 那两处不碰 FFI，
  /// 因此可以在任何平台上被逐条锁死。
  ///
  /// [libraryPath] 为 null 时**不覆盖** `package:sqlite3` 的平台默认选择
  /// （Windows：`sqlite3.dll` → `winsqlite3.dll`；Linux/macOS：系统库）。
  /// 这条路径存在的意义就是：没有显式给出 SQLCipher 库时，
  /// 自检会以 `PFD_E_ENGINE_NOT_CIPHER` 失败，而不是悄悄降级成明文。
  ///
  /// 唯一会抛的是 [StateError]：同进程内**用另一个路径**再次调用
  /// （句柄已固定，见文件头）。
  static EngineObservation observeLibrary({
    String? libraryPath,
    String libraryLabel = 'platform-default',
  }) {
    _guardRebind(libraryPath);
    try {
      if (libraryPath != null) {
        final os = sqlite_open.open.os;
        if (os == null) {
          return EngineObservation(
            libraryLabel: libraryLabel,
            libraryPath: libraryPath,
            loadError: '无法识别当前操作系统，不能覆盖原生库加载路径',
          );
        }
        _pendingPath = libraryPath;
        // 唯一一处允许打开动态库的地方（见 banned_api.yaml 的
        // no-raw-dylib-open-outside-data：数据层是它的豁免范围）。
        sqlite_open.open.overrideFor(os, _openPending);
      }

      // 到这里才真正 dlopen。库不存在 / 架构不符 / 缺符号都在这一句爆。
      final handle = sqlite.sqlite3;
      final sqliteVersion = handle.version.libVersion;

      // 身份查询要一个**活的连接**：PRAGMA 是连接级语句，不能脱离连接执行。
      // 用内存库，不碰磁盘 —— 自检不允许有副作用。
      final String cipherVersion;
      final probe = handle.openInMemory();
      try {
        cipherVersion = _firstValue(probe.select('PRAGMA cipher_version'));
      } catch (error) {
        return EngineObservation(
          libraryLabel: libraryLabel,
          libraryPath: libraryPath ?? '',
          sqliteVersion: sqliteVersion,
          loadError: '身份查询失败（PRAGMA cipher_version）：$error',
        );
      } finally {
        probe.dispose();
      }

      return EngineObservation(
        libraryLabel: libraryLabel,
        libraryPath: libraryPath ?? '',
        sqliteVersion: sqliteVersion,
        cipherVersion: cipherVersion,
      );
    } catch (error) {
      // 不写 `on ArgumentError`：DynamicLibrary.open 失败时抛的正是它，
      // 而 avoid_catching_errors 禁止按 Error 类型捕获。
      // 这里确实需要一把兜住所有加载期异常的伞。
      return EngineObservation(
        libraryLabel: libraryLabel,
        libraryPath: libraryPath ?? '',
        loadError: '$error',
      );
    }
  }

  /// 静态方法（`package:sqlite3` 的加载回调用）。
  static DynamicLibrary _openPending() {
    final path = _pendingPath;
    if (path == null) {
      throw StateError('未设置待加载的原生库路径');
    }
    return DynamicLibrary.open(path);
  }

  /// 一个进程只能有一个引擎。已经绑定过之后再换路径 = 拿到的身份是假的。
  static void _guardRebind(String? libraryPath) {
    if (_instance == null) return;
    if (_instancePath == libraryPath) return;
    throw StateError(
      '一个进程只能绑定一个原生库：已绑定 ${_instancePath ?? '（平台默认）'}，'
      '不能再绑定 ${libraryPath ?? '（平台默认）'}。'
      'package:sqlite3 在首次访问后会把句柄固定在模块级变量上，换库必须换进程。',
    );
  }

  static String _firstValue(sqlite.ResultSet result) {
    if (result.isEmpty) return '';
    final values = result.first.values;
    if (values.isEmpty) return '';
    final value = values.first;
    return value == null ? '' : '$value';
  }

  // ---------------------------------------------------------------------------
  // 用
  // ---------------------------------------------------------------------------

  /// 引擎不可用/不是 SQLCipher 就抛 [PfError]。这是「不静默跳过」的入口。
  void requireUsable() => requireSqlCipher(verdict);

  /// `sqlite3_libversion()`。**只用于报告，不用于判定**。
  String get sqliteVersion => _handle.version.libVersion;

  /// `PRAGMA cipher_version` 读到的身份串（已确认非空）。
  String get cipherVersion => verdict.observation.cipherVersion ?? '';

  /// 打开一个内存库。用于自检与单测，不落盘。
  sqlite.Database openInMemory() => _handle.openInMemory();

  /// 打开一个**加密**库，并按 §3.4 的顺序跑完 setup 与 post-open 脚本。
  ///
  /// 参数与 [SqlCipherOpenFlow.open] 一致（本方法只是把
  /// [Sqlite3Session] 这个适配器装上去）。失败时关闭连接再抛 ——
  /// 不留下一个"半开着"的句柄。
  Future<sqlite.Database> openEncrypted({
    required String path,
    required Uint8List databaseKey,
    int plaintextHeaderBytes = 0,
    SqlCipherOpenFlow flow = const SqlCipherOpenFlow(),
  }) async {
    requireUsable();
    final db = _handle.open(path);
    try {
      await flow.open(
        session: Sqlite3Session(db),
        databaseKey: databaseKey,
        plaintextHeaderBytes: plaintextHeaderBytes,
      );
      return db;
    } catch (error) {
      db.dispose();
      rethrow;
    }
  }
}

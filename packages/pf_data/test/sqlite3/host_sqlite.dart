/// 打开**宿主机自带的那个 SQLite**（测试夹具，不是产品代码）。
///
/// ## 为什么适配器用例用宿主库，而不是定版的 SQLCipher
///
/// [Sqlite3Session] / [Sqlite3Db] 只做「把 FFI 调用翻译成会话/仓储契约」——
/// 它们**不碰加密层**。给它们配 SQLCipher 不会让断言更强，只会让这一组用例
/// 依赖一次联网取件（`fetch_engine`），于是全新 clone 上跑不了测试。
///
/// 引擎身份是另一件事，由 `engine_verdict_test.dart`（纯规则）与
/// `pf_cli` 下的引擎用例（真库）回答。
///
/// ## 唯一需要动手的地方：Linux 的库名
///
/// `package:sqlite3` 的平台默认加载器在 Linux 上只试 `libsqlite3.so`
/// （不带版本号的开发符号链接），而发行版通常只装 `libsqlite3.so.0`。
/// 这里补一串候选名，**全部打不开就抛** —— 不静默跳过：
/// 「一条都没跑」与「全部通过」在报告里长得一模一样，那是本项目最怕的形态。
library;

import 'dart:ffi';

import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart' as sqlite;

bool _overrideInstalled = false;

/// Linux 上按顺序尝试的库名（默认加载器只试第一个）。
const List<String> _linuxCandidates = <String>[
  'libsqlite3.so',
  'libsqlite3.so.0',
  'libsqlite3.so.1',
];

/// 宿主 SQLite 的句柄。首次调用会先装好加载覆盖。
sqlite.Sqlite3 openHostSqlite() {
  if (!_overrideInstalled) {
    _overrideInstalled = true;
    // 只在目标平台匹配时注册覆盖：`overrideFor` 的 os 参数不可空，
    // 而 `open.os` 可空（未知平台），所以判断写在条件里而不是先取值。
    if (sqlite_open.open.os == sqlite_open.OperatingSystem.linux) {
      sqlite_open.open.overrideFor(sqlite_open.OperatingSystem.linux, _openLinux);
    }
  }
  return sqlite.sqlite3;
}

/// Linux 的加载函数：逐个试候选名。
///
/// 用 `catch` + `is!` 而不是 `on ArgumentError`：仓库的 lint 里
/// `avoid_catching_errors` 是开着的（`DynamicLibrary.open` 失败抛的正是
/// Error 的子类，按类型捕获会被判死）。
DynamicLibrary _openLinux() {
  for (final name in _linuxCandidates) {
    try {
      return DynamicLibrary.open(name);
    } catch (error) {
      if (error is! ArgumentError) rethrow;
    }
  }
  throw StateError(
    '这台机器上没有可加载的系统 SQLite（试过 ${_linuxCandidates.join(' / ')}）。\n'
    '  适配器用例只需要一个能执行 SQL 的库，不需要 SQLCipher，但确实需要一个库。\n'
    '  Debian/Ubuntu：apt-get install -y libsqlite3-0（或 libsqlite3-dev）',
  );
}

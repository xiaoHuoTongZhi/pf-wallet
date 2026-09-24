/// `pf engine` 的**正例**：定版 SQLCipher 库必须被认下来。
///
/// 需要先取件（见 `support/engine_support.dart` 与 docs/M1_RUNBOOK.md §3.1）：
///
/// ```
/// dart run tools/pf_cli/bin/fetch_engine.dart
/// ```
///
/// ## 为什么这个文件单独存在
///
/// `package:sqlite3` 把已加载的句柄缓存在模块级变量上，**一个 isolate 只能有
/// 一个引擎**（见 `pf_data` 的 `engine.dart` 文件头）。因此「用哪个库测」这件事
/// 只能按 isolate 分文件：本文件只碰 sqlcipher 那个库，纯 SQLite 的反例在
/// `engine_plain_test.dart` 与 `engine_platform_default_test.dart`。
/// 这既是约束，也是保证 —— 报告里每一条结论都能回答"它测的是哪个库"。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:pf_cli/pf_cli.dart';
import 'package:pf_data/pf_data.dart';
import 'package:test/test.dart';

import 'support/engine_support.dart';
import 'support/harness.dart';

/// 32 字节的假密钥。**只是密钥**，不参与任何真实加密。
final Uint8List _dek = Uint8List.fromList(List<int>.generate(32, (i) => 0x40 + i));

void main() {
  late String libraryPath;

  setUpAll(() {
    final paths = loadVendoredEnginePaths();
    final entry = paths.require('sqlcipher');
    libraryPath = entry.path;

    // 先绑定一次：绑定成一次之后，"第二次换成别的路径"这条不变量才有对象可测。
    final engine = Sqlite3Engine.bind(libraryPath: libraryPath, libraryLabel: 'vendored');
    expect(
      engine.verdict.kind,
      EngineKind.sqlCipher,
      reason: '清单里的 sqlcipher 条目必须是 SQLCipher。落盘清单：${paths.source}',
    );
  });

  test('① 命令行那一层：exit 0，status=ok，kind=sqlCipher，身份串非空', () async {
    final result = await runCli(<String>['--json', 'engine', '--engine-lib', libraryPath]);

    expect(result.code, ExitCodes.ok);
    expect(result.err.text, isEmpty);
    expect(result.result['status'], 'ok');
    expect(result.result['kind'], 'sqlCipher');
    expect(result.result['cipherVersion'], isNotEmpty);
    // 自报的 sqlite 版本也要在结果里 —— 它是排查"库是不是我要的那份"的锚点。
    expect(result.result['sqliteVersion'], isNotEmpty);
  });

  test('② 过程记录里保留了标签与路径（判据之外的事实也要可追溯）', () async {
    final result = await runCli(<String>['--json', 'engine', '--engine-lib', libraryPath]);

    final engineRecord = result.jsonLines.firstWhere((line) => line['type'] == 'engine');
    expect(engineRecord['label'], 'explicit');
    expect(engineRecord['path'], libraryPath);
    expect(engineRecord['loaded'], isTrue);

    final verdictRecord = result.jsonLines.firstWhere((line) => line['type'] == 'verdict');
    expect(verdictRecord['kind'], 'sqlCipher');
  });

  test('③ 引擎那一层：requireUsable 放行，openEncrypted 写出的文件头是密文', () async {
    final engine = Sqlite3Engine.bind(libraryPath: libraryPath, libraryLabel: 'vendored');
    engine.requireUsable();

    final tmp = Directory.systemTemp.createTempSync('pf_cli_engine_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final dbPath = '${tmp.path}${Platform.pathSeparator}wallet.db';

    final db = await engine.openEncrypted(path: dbPath, databaseKey: _dek);
    db.execute('CREATE TABLE t (a)');
    db.execute('INSERT INTO t VALUES (1)');
    db.dispose();

    // 判定的落脚点不是"命令返回 0"，而是**盘上那份字节到底是不是密文**。
    // 明文库的头 16 字节固定是 `SQLite format 3\0`。
    final header = File(dbPath).readAsBytesSync().sublist(0, 16);
    expect(
      String.fromCharCodes(header),
      isNot(startsWith('SQLite format 3')),
      reason: '库文件是明文 —— 说明加密参数根本没生效',
    );
  });

  test('④ 不变量：一个进程绑定过之后，换路径必须抛 StateError', () {
    // 换库必须换进程（package:sqlite3 把句柄固定在模块级变量上）。
    // 这里必须"响"而不是静默复用旧引擎 —— 静默复用会让报告里的身份是假的。
    expect(() => Sqlite3Engine.bind(libraryPath: '$libraryPath.other'), throwsStateError);
    // 显式给过路径之后，再退回"平台默认"同样算换库。
    expect(Sqlite3Engine.bind, throwsStateError);
  });
}

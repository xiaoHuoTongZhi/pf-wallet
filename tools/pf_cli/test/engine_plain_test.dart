/// `pf engine` 的**反例 A**：定版的**纯 SQLite** 必须被拦下。
///
/// 需要先取件（同 `engine_sqlcipher_test.dart`）。
///
/// ## 为什么拿两份"纯 SQLite"分别测
///
///   - 本文件用**我们钉死的那一份**（`SQLitePCLRaw.lib.e_sqlite3`，3.49.1）：
///     版本确定，报错里那句话因此是稳定的，可以断言；
///   - `engine_platform_default_test.dart` 用**这台机器自带的**那一份
///     （Windows 上是 `winsqlite3.dll`）：它证明的是一件更硬的事 ——
///     「`package:sqlite3` 的默认选择**永远不是** SQLCipher」，
///     因而"没配库就不该能建库"这条底线不依赖我们的取件流程。
///
/// 两条腿缺一不可：只测其中一份，都会漏掉另一份所代表的事故。
library;

import 'package:pf_cli/pf_cli.dart';
import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';
import 'package:test/test.dart';

import 'support/engine_support.dart';
import 'support/harness.dart';

void main() {
  late String libraryPath;

  setUpAll(() {
    final paths = loadVendoredEnginePaths();
    libraryPath = paths.require('plain').path;

    // 绑定本身**必须成功** —— 这个库是好的，只是没有加密层。
    // 若这里就失败了，那说明问题出在取件，而不在判据，两者要能分开看。
    Sqlite3Engine.bind(libraryPath: libraryPath, libraryLabel: 'vendored-plain');
  });

  test('① 命令行那一层：exit 2（工具故障），不是 0、也不是 1', () async {
    final result = await runCli(<String>['--json', 'engine', '--engine-lib', libraryPath]);

    // 2 而不是 1：「引擎不对」不是关于某份数据的业务结论，而是环境不可用。
    // 归到 1 会让 CI 把环境故障读成"这份备份有问题"。
    expect(result.code, ExitCodes.toolError);
    expect(result.result['status'], 'engine-not-sqlcipher');
    expect(result.result['kind'], 'plainSqlite');
    expect(result.result['code'], PfErrorCode.storageEngineNotCipher);
    expect(result.err.text, contains(PfErrorCode.storageEngineNotCipher));
  });

  test('② 判定依据必须点出 cipher_version 是 0 行（否则日志里看不出为什么拦）', () async {
    final result = await runCli(<String>['--json', 'engine', '--engine-lib', libraryPath]);

    final verdict = result.jsonLines.firstWhere((line) => line['type'] == 'verdict');
    expect('${verdict['reason']}', contains('0 行'));

    // 记录里 cipherVersion 是空的 —— 它是"没有"，不是"没测"。
    final engineRecord = result.jsonLines.firstWhere((line) => line['type'] == 'engine');
    expect(engineRecord['loaded'], isTrue, reason: '这个库能加载，能跑 SQL —— 这正是危险所在');
    expect(engineRecord['cipherVersion'], isEmpty);
    expect(engineRecord['sqliteVersion'], isNotEmpty);
  });

  test('③ 引擎那一层：requireUsable 抛 PFD_E_ENGINE_NOT_CIPHER，且不算"环境缺东西"', () {
    final engine = Sqlite3Engine.bind(libraryPath: libraryPath, libraryLabel: 'vendored-plain');

    expect(
      engine.requireUsable,
      throwsA(
        isA<StorageError>().having((e) => e.code, 'code', PfErrorCode.storageEngineNotCipher),
      ),
    );
  });
}

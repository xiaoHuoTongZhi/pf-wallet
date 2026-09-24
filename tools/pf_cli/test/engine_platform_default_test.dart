/// `pf engine` 的**反例 B**：**这台机器自带的** SQLite 也必须被拦下。
///
/// 这个文件回答的是另一类问题：反例 A（`engine_plain_test.dart`）证明
/// "我们钉死的那份纯 SQLite 会被拦"，本文件证明**"什么都不配"也拦得住** ——
/// 也就是 `pf engine` **缺省不给库**时的行为。
///
/// 缺省这条路是最容易漏的一条：它没有显式参数，写起来像是"没给就跳过检查"。
/// 而真实后果是：命令会拿 `package:sqlite3` 的平台默认选择去开库 ——
/// Windows 上是 `winsqlite3.dll`，Linux/macOS 上是系统 libsqlite3，
/// **三者都不是 SQLCipher**，都会静默接受全部 `cipher_*` PRAGMA
/// 然后写出明文库。所以缺省必须失败，而不是降级。
///
/// 反过来看：如果有一天 CI 上这条用例失败了，唯一可能是"这台机器上的默认
/// SQLite 变成了 SQLCipher"——那本身就是需要立刻知道的事。
///
/// ## 这个文件里为什么没有"环境变量"的用例
///
/// 「`PF_SQLCIPHER_LIB` 指向一个不存在的路径 ⇒ 引擎不可用」这条用例在
/// `engine_unavailable_test.dart`：一旦 `package:sqlite3` 的加载覆盖被装成
/// 某个路径，它在本 isolate 里就**不会**再退回平台默认了，
/// 因此那条用例与这里的用例必须分处两个文件，否则顺序会决定结论。
/// 本文件里的三条全部走"不给路径"，彼此之间因此没有顺序依赖。
library;

import 'package:pf_cli/pf_cli.dart';
import 'package:pf_data/pf_data.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  test('① 不给 --engine-lib ⇒ 平台默认（纯 SQLite）⇒ exit 2', () async {
    final result = await runCli(<String>['--json', 'engine']);

    expect(result.code, ExitCodes.toolError);
    expect(result.result['status'], 'engine-not-sqlcipher');
    expect(result.result['kind'], 'plainSqlite');
  });

  test('② 环境变量是空串时按"没给"处理，同样落到平台默认', () async {
    // `PF_SQLCIPHER_LIB=`（例如 CI 里某个变量展开成了空）如果被当成有效路径，
    // `DynamicLibrary.open('')` 会给出一个与"没配"完全不同的报错，
    // 把排查引向错误方向。这里断言两者行为一致。
    final result = await runCli(
      <String>['--json', 'engine'],
      environment: <String, String>{kSqlCipherLibraryEnvVar: ''},
    );

    expect(result.code, ExitCodes.toolError);
    expect(result.result['status'], 'engine-not-sqlcipher');
  });

  test('③ 平台默认路径**看不到**，就报 null，不猜一个', () async {
    // 路径由 package:sqlite3 决定，我们确实不知道它选了哪一个文件。
    // 打 null 而不是拼一个"大概是 winsqlite3.dll"—— 报告里的值只能是事实。
    final result = await runCli(<String>['--json', 'engine']);

    final engineRecord = result.jsonLines.firstWhere((line) => line['type'] == 'engine');
    expect(engineRecord['label'], 'platform-default');
    expect(engineRecord['path'], isNull);
    expect(engineRecord['loaded'], isTrue);
    expect(engineRecord['sqliteVersion'], isNotEmpty);
  });
}

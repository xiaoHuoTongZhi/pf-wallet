/// `pf engine` 的**反例 C**：库加载不出来时必须报「环境不可用」。
///
/// 这一类失败与"库不对"要分开编码，因为处置方向相反：
///
///   | 情况 | 错误码 | 该做什么 |
///   |---|---|---|
///   | 库找不到 / 架构不符 / 缺符号 | `PFD_E_ENGINE_UNAVAILABLE` | 装库、修路径、换架构 |
///   | 库能加载但不是 SQLCipher | `PFD_E_ENGINE_NOT_CIPHER` | 换一个构建 |
///
/// 合并成一个码，调用方就只能靠字符串猜 —— 而这两条路的动作没有交集。
///
/// 本文件里的用例都走"显式给一个打不开的路径"，因此彼此之间没有顺序依赖
/// （理由见 `engine_platform_default_test.dart` 的文件头）。
library;

import 'dart:io';

import 'package:pf_cli/pf_cli.dart';
import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// 一个确定不存在的路径。放在系统临时目录下，避免"恰好撞上某个真文件"。
String missingLibraryPath(String name) =>
    '${Directory.systemTemp.path}${Platform.pathSeparator}pf-cli-no-such-engine-$name';

void main() {
  test('① 路径不存在 ⇒ exit 2 + engine-unavailable + 把 dlopen 的原话带上', () async {
    final missing = missingLibraryPath('a.dll');
    final result = await runCli(<String>['--json', 'engine', '--engine-lib', missing]);

    expect(result.code, ExitCodes.toolError);
    expect(result.result['status'], 'engine-unavailable');
    expect(result.result['kind'], 'unavailable');
    expect(result.result['code'], PfErrorCode.storageEngineUnavailable);
    // stderr 里要有人能看懂的那一行 —— CI 日志里只有一次机会。
    expect(result.err.text, contains(PfErrorCode.storageEngineUnavailable));
  });

  test('② 显式路径优先于环境变量（两者都给了时用命令行那个）', () async {
    final missing = missingLibraryPath('b.dll');
    final result = await runCli(
      <String>['--json', 'engine', '--engine-lib', missing],
      // 环境变量给一个**同样打不开**的路径：结论仍是 unavailable，
      // 但记录里的 path 必须是命令行给的那个，否则"优先级"就无从验证。
      environment: <String, String>{kSqlCipherLibraryEnvVar: missingLibraryPath('env.dll')},
    );

    expect(result.code, ExitCodes.toolError);
    final engineRecord = result.jsonLines.firstWhere((line) => line['type'] == 'engine');
    expect(engineRecord['path'], missing);
  });

  test('③ 环境变量里给一个打不开的路径 ⇒ 同样 unavailable（说明它被采纳了）', () async {
    // 这条与②的区别：② 证明"命令行赢"，这条证明"环境变量确实被读到了"。
    // 少了这条，把环境变量那一档整个删掉的改动不会让任何用例变红。
    final result = await runCli(
      <String>['--json', 'engine'],
      environment: <String, String>{kSqlCipherLibraryEnvVar: missingLibraryPath('c.dll')},
    );

    expect(result.code, ExitCodes.toolError);
    expect(result.result['status'], 'engine-unavailable');
  });

  test('④ 加载失败**不留绑定**：下一次换路径仍能照常尝试', () async {
    // `bind` 在加载失败时会把那次尝试丢掉（不留下一个"半绑定的引擎"），
    // 否则第二次调用会以 StateError 报"已绑定过"—— 一个纯属误导的结论。
    final first = await runCli(<String>[
      '--json',
      'engine',
      '--engine-lib',
      missingLibraryPath('d.dll'),
    ]);
    final second = await runCli(<String>[
      '--json',
      'engine',
      '--engine-lib',
      missingLibraryPath('e.dll'),
    ]);

    expect(first.result['status'], 'engine-unavailable');
    expect(second.result['status'], 'engine-unavailable');
    expect(second.result['status'], isNot('engine-rebind-refused'));
  });
}

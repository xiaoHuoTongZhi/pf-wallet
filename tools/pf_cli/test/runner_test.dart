/// `runPf` 的契约测试：退出码、全局选项、用法错误、NDJSON 协议。
///
/// 这里只守「命令面」——每条命令**做事**的行为在 info_test / verify_test 里。
/// 分开的理由是这两类失败的含义不同：命令面的错会让脚本判断错「该不该重试」，
/// 而命令内部的错只会让某次诊断给错结论。
library;

import 'package:pf_cli/pf_cli.dart';
import 'package:pf_core/pf_core.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  group('退出码契约', () {
    test('三个码互不相同，且是 0 / 1 / 2', () {
      expect(ExitCodes.ok, 0);
      expect(ExitCodes.negative, 1);
      expect(ExitCodes.toolError, 2);
      expect(
        <int>{ExitCodes.ok, ExitCodes.negative, ExitCodes.toolError}.length,
        3,
        reason: '合并任意两个码都会让「业务结论」与「工具故障」无法区分',
      );
    });
  });

  group('全局选项', () {
    test('--help 列出全部命令与退出码表，返回 0', () async {
      final r = await runCli(<String>['--help']);
      expect(r.code, ExitCodes.ok);
      // 十条命令一条都不能漏：帮助里少一条，等于那条命令在用户那里不存在
      // （而它其实存在，只是没人知道）。
      for (final name in <String>[
        'engine',
        'info',
        'verify',
        'init',
        'seed',
        'export',
        'import',
        'dump',
      ]) {
        expect(r.out.text, contains(name), reason: '帮助里缺少 $name');
      }
      expect(r.out.text, contains('退出码'));
      expect(r.out.text, contains(kPasswordEnvVar), reason: '两条密码来源必须写在帮助里');
      expect(r.out.text, contains(kDatabaseKeyEnvVar), reason: '数据库密钥的两条来源也必须写在帮助里');
      expect(r.err.text, isEmpty);
    });

    test('--version 打出应用版本与三个格式版本，返回 0', () async {
      final r = await runCli(<String>['--version']);
      expect(r.code, ExitCodes.ok);
      expect(r.out.text, contains(PfBuildInfo.appVersion));
      expect(r.out.text, contains('container v1.0'));
      expect(r.out.text, contains('payload v1'));
    });
  });

  group('用法错误一律返回 2（工具故障，不是结论为否）', () {
    test('无参数', () async {
      final r = await runCli(<String>[]);
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('缺少子命令'));
      expect(r.out.text, isEmpty, reason: '用法错误只走 stderr，不污染 stdout');
    });

    test('未知子命令', () async {
      final r = await runCli(<String>['bogus']);
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('用法错误'));
    });

    test('已知子命令 + 未知选项', () async {
      final r = await runCli(<String>['info', '--nope']);
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('用法错误'));
    });

    test('verify 的 --password-file 缺参数', () async {
      final r = await runCli(<String>['verify', 'a.pfb', '--password-file']);
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('用法错误'));
    });

    test('子命令自身的 --help 返回 0，且打到 stdout', () async {
      // 全部子命令都过一遍：漏掉的那条一旦在 `--help` 上抛异常，
      // 用户看到的是「用法错误」而不是帮助 —— 而帮助正是他此刻在找的东西。
      for (final name in <String>[
        'engine',
        'info',
        'verify',
        'init',
        'seed',
        'export',
        'import',
        'dump',
      ]) {
        final r = await runCli(<String>[name, '--help']);
        expect(r.code, ExitCodes.ok, reason: name);
        expect(r.out.text, contains('$name 用法'), reason: name);
        expect(r.err.text, isEmpty, reason: name);
      }
    });
  });

  group('NDJSON 契约（--json）', () {
    test('末行是结果行，含 type/status/exitCode 与命令名', () async {
      final r = await runCli(<String>['--json', 'info', 'x.pfb']);
      final last = r.result;
      expect(last['type'], 'result');
      expect(last['status'], 'io-error');
      expect(last['exitCode'], ExitCodes.toolError);
      expect(last['command'], 'info');
      expect(last['file'], 'x.pfb');
    });

    test('--json 放在子命令之后同样生效', () async {
      final r = await runCli(<String>['verify', '--json', 'x.pfb']);
      expect(r.result['command'], 'verify');
      expect(r.result['file'], 'x.pfb');
    });

    test('结果行是合法 JSON 对象，且单行（无内嵌换行）', () async {
      final r = await runCli(<String>['--json', 'verify', 'x.pfb']);
      final raw = r.out.lines.last;
      expect(raw.startsWith('{'), isTrue);
      expect(raw.endsWith('}'), isTrue);
      expect(raw.contains('\\n'), isFalse);
    });

    test('缺文件参数时 result 里不带 file 键', () async {
      final r = await runCli(<String>['--json', 'info']);
      expect(r.result.containsKey('file'), isFalse);
      expect(r.result['command'], 'info');
      expect(r.result['status'], 'usage-error');
    });
  });
}

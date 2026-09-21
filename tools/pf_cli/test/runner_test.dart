import 'dart:convert';

import 'package:pf_cli/pf_cli.dart';
import 'package:pf_core/pf_core.dart';
import 'package:test/test.dart';

/// 把 CLI 的输出收进内存 —— 这样测试不必起子进程，分支也进得了覆盖率。
final class _Capture implements StringSink {
  final StringBuffer _buffer = StringBuffer();

  String get text => _buffer.toString();

  List<String> get lines =>
      text.isEmpty ? <String>[] : text.substring(0, text.length - 1).split('\n');

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _buffer.writeln(object);
}

({int code, _Capture out, _Capture err}) _run(List<String> args) {
  final out = _Capture();
  final err = _Capture();
  final code = runPf(args, out: out, err: err);
  return (code: code, out: out, err: err);
}

Map<String, Object?> _lastJson(_Capture out) {
  final raw = out.lines.last;
  final decoded = jsonDecode(raw);
  return (decoded as Map).cast<String, Object?>();
}

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
    test('--help 列出全部命令与退出码表，返回 0', () {
      final r = _run(<String>['--help']);
      expect(r.code, ExitCodes.ok);
      expect(r.out.text, contains('info'));
      expect(r.out.text, contains('verify'));
      expect(r.out.text, contains('init | seed | export | import | dump'));
      expect(r.out.text, contains('退出码'));
      expect(r.err.text, isEmpty);
    });

    test('--version 打出应用版本与三个格式版本，返回 0', () {
      final r = _run(<String>['--version']);
      expect(r.code, ExitCodes.ok);
      expect(r.out.text, contains(PfBuildInfo.appVersion));
      expect(r.out.text, contains('container v1.0'));
      expect(r.out.text, contains('payload v1'));
    });
  });

  group('用法错误一律返回 2（工具故障，不是结论为否）', () {
    test('无参数', () {
      final r = _run(<String>[]);
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('缺少子命令'));
      expect(r.out.text, isEmpty, reason: '用法错误只走 stderr，不污染 stdout');
    });

    test('未知子命令', () {
      final r = _run(<String>['bogus']);
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('用法错误'));
    });

    test('已知子命令 + 未知选项', () {
      final r = _run(<String>['info', '--nope']);
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('用法错误'));
    });

    test('verify 的 --password-file 缺参数', () {
      final r = _run(<String>['verify', 'a.pfb', '--password-file']);
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('用法错误'));
    });

    test('子命令自身的 --help 返回 0，且打到 stdout', () {
      for (final name in <String>['info', 'verify']) {
        final r = _run(<String>[name, '--help']);
        expect(r.code, ExitCodes.ok, reason: name);
        expect(r.out.text, contains('$name 用法'));
        expect(r.err.text, isEmpty, reason: name);
      }
    });
  });

  group('骨架阶段的落点：命令已定，实现未落地', () {
    test('info 在 stderr 明说未实现，并给出 not-implemented 结果行', () {
      final r = _run(<String>['info', 'x.pfb']);
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('尚未实现'));
      expect(r.out.text, contains('not-implemented'));
    });

    test('verify 同上（含 --password-file）', () {
      final r = _run(<String>['verify', 'x.pfb', '-p', 'pw.txt']);
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('尚未实现'));
    });

    test('绝不能返回 1 —— 「没实现」不是「结论为否」', () {
      for (final args in <List<String>>[
        <String>['info', 'x.pfb'],
        <String>['verify', 'x.pfb'],
      ]) {
        expect(_run(args).code, isNot(ExitCodes.negative), reason: args.toString());
      }
    });
  });

  group('NDJSON 契约（--json）', () {
    test('末行是结果行，含 type/status/exitCode 与命令名', () {
      final r = _run(<String>['--json', 'info', 'x.pfb']);
      final last = _lastJson(r.out);
      expect(r.out.lines.length, 1, reason: '骨架阶段只有结果行');
      expect(last['type'], 'result');
      expect(last['status'], 'not-implemented');
      expect(last['exitCode'], ExitCodes.toolError);
      expect(last['command'], 'info');
      expect(last['file'], 'x.pfb');
    });

    test('--json 放在子命令之后同样生效', () {
      final r = _run(<String>['verify', '--json', 'x.pfb']);
      expect(_lastJson(r.out)['command'], 'verify');
      expect(_lastJson(r.out)['file'], 'x.pfb');
    });

    test('结果行是合法 JSON 对象，且单行（无内嵌换行）', () {
      final r = _run(<String>['--json', 'verify', 'x.pfb']);
      final raw = r.out.lines.last;
      expect(raw.startsWith('{'), isTrue);
      expect(raw.endsWith('}'), isTrue);
      expect(raw.contains('\\n'), isFalse);
    });

    test('缺文件参数时 result 里不带 file 键', () {
      final r = _run(<String>['--json', 'info']);
      final last = _lastJson(r.out);
      expect(last.containsKey('file'), isFalse);
      expect(last['command'], 'info');
    });
  });
}

import 'dart:convert';

import 'package:pf_cli/pf_cli.dart';
import 'package:test/test.dart';

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

void main() {
  group('NDJSON 模式', () {
    test('record 的键序是 type 在最前', () {
      final out = _Capture();
      CliReporter(out: out, json: true).record('integrity', <String, Object?>{'ok': true});
      expect(out.lines.single, '{"type":"integrity","ok":true}');
    });

    test('record 无字段时只有 type，不出现空对象', () {
      final out = _Capture();
      CliReporter(out: out, json: true).record('header');
      expect(out.lines.single, '{"type":"header"}');
    });

    test('result 的键序固定为 type/status/exitCode，附加字段排在其后', () {
      final out = _Capture();
      CliReporter(
        out: out,
        json: true,
      ).result(exitCode: 0, status: 'ok', fields: <String, Object?>{'records': 12});
      expect(out.lines.single, '{"type":"result","status":"ok","exitCode":0,"records":12}');
    });

    test('每行都是独立可解析的 JSON 对象（NDJSON 的全部要求）', () {
      final out = _Capture();
      final reporter = CliReporter(out: out, json: true);
      reporter.record('header', <String, Object?>{'formatVersion': 1});
      reporter.record('integrity', <String, Object?>{'intact': true});
      reporter.result(exitCode: 0, status: 'ok');

      expect(out.lines, hasLength(3));
      for (final line in out.lines) {
        expect(jsonDecode(line), isA<Map<String, Object?>>());
      }
      // 只有末行是结果行 —— 调用方因此可以只读最后一行。
      expect((jsonDecode(out.lines.first) as Map)['type'], 'header');
      expect((jsonDecode(out.lines.last) as Map)['type'], 'result');
    });

    test('值里的换行被转义，不会把一行拆成两行', () {
      final out = _Capture();
      CliReporter(out: out, json: true).record('note', <String, Object?>{'detail': 'a\nb'});
      expect(out.lines, hasLength(1));
      expect(out.lines.single.contains('\\n'), isTrue);
    });
  });

  group('人类可读模式', () {
    test('record 打 k=v，无字段时只打 type', () {
      final out = _Capture();
      final reporter = CliReporter(out: out, json: false);
      reporter.record('header', <String, Object?>{'formatVersion': 1, 'chunks': 3});
      reporter.record('integrity');
      expect(out.lines[0], 'header  formatVersion=1 chunks=3');
      expect(out.lines[1], 'integrity');
    });

    test('result 无字段时带上退出码', () {
      final out = _Capture();
      CliReporter(out: out, json: false).result(exitCode: 1, status: 'corrupted');
      expect(out.lines.single, 'corrupted (exit 1)');
    });

    test('result 有字段时打 k=v', () {
      final out = _Capture();
      CliReporter(
        out: out,
        json: false,
      ).result(exitCode: 0, status: 'ok', fields: <String, Object?>{'records': 5});
      expect(out.lines.single, 'ok  records=5');
    });
  });
}

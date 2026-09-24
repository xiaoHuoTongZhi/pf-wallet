/// 走**生产路径**的测试：真文件系统、真环境变量、不注入任何东西。
///
/// 其余测试都注入了 `readBytes` 与 `environment` —— 那是为了让反例可测
/// （见 `support/harness.dart`）。但注入有一个代价：`runPf` 里
/// `readBytes ?? readFileBytes` 与 `environment ?? Platform.environment`
/// 这两条的**右侧**，以及 `readFileBytes` 的函数体，就永远不会被执行。
///
/// 那意味着「CLI 真的能从磁盘读一个文件」这件事**没有被测过** ——
/// 所有测试绿，而真实入口从没跑起来过。这个文件补的就是它。
///
/// 临时文件写在系统临时目录，跑完删掉；不碰仓库里的任何路径
/// （`.pfb` 与 `*.db` 都在 `tracked_paths` 的 deny 名单上，落盘只能进 `build/`，
/// 而这里连 `build/` 都不需要）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:pf_cli/pf_cli.dart';
import 'package:test/test.dart';

import 'support/harness.dart';
import 'support/sample.dart';

void main() {
  late VectorFixture fixture;
  late VectorSample sample;
  late Directory tmp;

  setUpAll(() {
    fixture = loadVectorFixture();
    sample = fixture.full;
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pf_cli_real_');
  });

  tearDown(() {
    if (tmp.existsSync()) {
      tmp.deleteSync(recursive: true);
    }
  });

  /// 把样本落到磁盘上，返回路径。
  String writeSample() {
    final file = File('${tmp.path}${Platform.pathSeparator}${sample.fileName}');
    file.writeAsBytesSync(sample.fileBytes);
    return file.path;
  }

  String writePassword() {
    final file = File('${tmp.path}${Platform.pathSeparator}pw.txt');
    // 用平台默认换行写 —— 真实用户就是这么存密码文件的（Windows 上会是 CRLF）。
    file.writeAsStringSync('${fixture.password}\n');
    return file.path;
  }

  group('缺省参数下走真的 dart:io', () {
    test('info：从磁盘读一个真实的 .pfb（不注入 readBytes）', () async {
      final path = writeSample();
      final out = Capture();
      final err = Capture();

      // 刻意只传两个输出流 —— 其余参数走缺省，这才验证了生产路径本身。
      final code = await runPf(<String>['--json', 'info', path], out: out, err: err);

      expect(code, ExitCodes.ok);
      expect(err.text, isEmpty);
      final result = CliResult(code: code, out: out, err: err);
      expect(result.result['status'], 'ok');
      expect(result.jsonLines[1]['fileSha256'], sample.fileSha256);
    });

    test('verify：从磁盘读真文件与真密码文件（不注入 environment）', () async {
      final pfbPath = writeSample();
      final pwPath = writePassword();
      final out = Capture();
      final err = Capture();

      final code = await runPf(
        <String>['--json', 'verify', pfbPath, '--password-file', pwPath],
        out: out,
        err: err,
      );

      expect(code, ExitCodes.ok);
      expect(err.text, isEmpty);
      final result = CliResult(code: code, out: out, err: err);
      expect(result.result['status'], 'ok');
      expect(result.result['passwordSource'], 'password-file');
      expect(result.result['counts'], sample.counts);
    });

    test('info：路径不存在时由真实现抛出的异常也要被认出来 → 2', () async {
      final missing = '${tmp.path}${Platform.pathSeparator}not-here.pfb';
      final out = Capture();
      final err = Capture();

      final code = await runPf(<String>['--json', 'info', missing], out: out, err: err);

      expect(code, ExitCodes.toolError);
      final result = CliResult(code: code, out: out, err: err);
      expect(result.result['status'], 'io-error');
      expect(err.text, contains('读不到文件'));
    });

    test('verify：密码文件不存在 → 2（真实现的 FileSystemException 被接住）', () async {
      final pfbPath = writeSample();
      final out = Capture();
      final err = Capture();

      final code = await runPf(
        <String>[
          '--json',
          'verify',
          pfbPath,
          '--password-file',
          '${tmp.path}${Platform.pathSeparator}no-pw.txt',
        ],
        out: out,
        err: err,
      );

      expect(code, ExitCodes.toolError);
      final result = CliResult(code: code, out: out, err: err);
      expect(result.result['status'], 'io-error');
      expect(err.text, contains('读不到密码文件'));
    });

    test('带目录的真实路径：file 原样回显，且没有被 baseNameOf 影响', () async {
      final path = writeSample();
      final out = Capture();
      final err = Capture();

      final code = await runPf(<String>['--json', 'info', path], out: out, err: err);

      expect(code, ExitCodes.ok);
      final result = CliResult(code: code, out: out, err: err);
      expect(result.result['file'], path);
      expect(baseNameOf(path), sample.fileName);
    });

    test('info --records --out：从磁盘读、往磁盘写（不注入 writeText）', () async {
      // 为什么必须有不注入 writeText 的这一条：`writeText ?? writeTextFile`
      // 的右侧与 `writeTextFile` 的函数体，在注入的实现里永远不会被执行 ——
      // 于是「报告真的能落到磁盘上」这件事从没被验证过，而 CI 完全依赖它
      // （跨实现校验比对的就是这两个文件）。
      final pfbPath = writeSample();
      final pwPath = writePassword();
      final outPath = '${tmp.path}${Platform.pathSeparator}report.dart.txt';
      final out = Capture();
      final err = Capture();

      final code = await runPf(
        <String>['info', pfbPath, '--records', '--password-file', pwPath, '--out', outPath],
        out: out,
        err: err,
      );

      expect(code, ExitCodes.ok);
      expect(out.text, isEmpty, reason: '--out 模式不该再往 stdout 写报告');
      final written = File(outPath);
      expect(written.existsSync(), isTrue);
      final text = written.readAsStringSync(encoding: utf8);
      expect(text, startsWith(kCrossCheckReportHeader));
      expect(text, contains('layer1.file.sha256=${sample.fileSha256}'));
      // 无 BOM、LF 结尾：报告要拿去与另一套实现逐字节 diff。
      expect(written.readAsBytesSync().take(3), isNot(<int>[0xEF, 0xBB, 0xBF]));
      expect(written.readAsBytesSync().last, 0x0A);
    });
  });
}

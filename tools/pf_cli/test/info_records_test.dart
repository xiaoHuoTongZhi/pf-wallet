/// `pf info <file> --records` 的行为测试。
///
/// 这个命令有三处与其它命令**不一样**的地方，测试的重点就在这三处：
///
///   1. **它需要密码**，而 `pf info` 的默认行为不需要。因此密码来源的三条
///      分支（文件、环境变量、两条都没有）必须与 `verify` 得到**同一套**说法 ——
///      同一份密码文件在两条命令下得到相反的指引，是最难查的一类不一致。
///   2. **它不按人读格式输出，也不按 NDJSON 输出**：报告本体是给 diff 用的
///      规范文本。于是它不能有结果行，诊断必须全走 stderr。
///   3. **`--out` 与 stdout 二选一**：CI 用 `--out`（Windows 上 stdout 的默认
///      编码不是 UTF-8，靠重定向取字节会得到随机器而变的报告）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pf_cli/pf_cli.dart';
import 'package:test/test.dart';

import 'support/harness.dart';
import 'support/sample.dart';

void main() {
  late VectorFixture fixture;
  late VectorSample sample;

  setUpAll(() {
    fixture = loadVectorFixture();
    sample = fixture.full;
  });

  MemoryFiles filesWithSample({Map<String, Uint8List>? extra}) =>
      MemoryFiles(<String, Uint8List>{sample.fileName: sample.fileBytes, ...?extra});

  /// 标准调用：`pf info <sample> --records --password-file pw.txt`。
  Future<CliResult> records({
    MemoryFiles? files,
    MemoryFiles? written,
    String? passwordText,
    Map<String, String> environment = const <String, String>{},
    List<String> extraArgs = const <String>[],
  }) {
    final fs = files ?? filesWithSample();
    fs.putText('pw.txt', passwordText ?? fixture.password);
    return runCli(
      <String>['info', sample.fileName, '--records', '--password-file', 'pw.txt', ...extraArgs],
      files: fs,
      written: written,
      environment: environment,
    );
  }

  group('正例：正确密码 → 0，规范报告走 stdout', () {
    test('stdout 就是报告本体，且不含结果行（结果行会让 diff 永不为空）', () async {
      final r = await records();
      expect(r.code, ExitCodes.ok);
      expect(r.out.text, startsWith(kCrossCheckReportHeader));
      expect(r.out.text.endsWith('\n'), isTrue);
      // 结果行不存在：末行是 counts，不是 `ok (exit 0)`，也不是 JSON。
      expect(r.out.lines.last, startsWith('layer4.counts.'));
      expect(() => jsonDecode(r.out.lines.last), throwsFormatException);
    });

    test('四层都在，且与 fixture 的期望值一致', () async {
      final r = await records();
      expect(r.out.text, contains('layer1.file.sha256=${sample.fileSha256}'));
      expect(r.out.text, contains('layer3.ndjson.sha256=${sample.payloadNdjsonSha256}'));
      expect(r.out.text, contains('layer4.contentHash=sha256:${sample.contentHashHex}'));
      expect(r.out.text, contains('layer4.recordCount.observed=${sample.recordCount}'));
    });

    test('报告里不含文件名与路径（换个路径跑不该变成假失败）', () async {
      final r = await records();
      expect(r.out.text.contains(sample.fileName), isFalse);
      expect(r.out.text.contains('.pfb'), isFalse);
    });

    test('诊断走 stderr，不污染 stdout', () async {
      final r = await records();
      expect(r.err.text, isEmpty);
    });
  });

  group('--out：报告写文件，stdout 留空', () {
    test('写出的内容与 stdout 模式逐字节相同', () async {
      final written = MemoryFiles();
      final r = await records(written: written, extraArgs: <String>['--out', 'report.dart.txt']);
      expect(r.code, ExitCodes.ok);
      expect(r.out.text, isEmpty, reason: '--out 模式不该再往 stdout 写报告');
      expect(written.textAt('report.dart.txt'), (await records()).out.text);
      expect(r.err.text, contains('report.dart.txt'));
    });

    test('同一份文件、两个不同的文件路径 → 写出的报告一模一样', () async {
      final first = MemoryFiles();
      final second = MemoryFiles();
      await runCli(
        <String>['info', 'a/one.pfb', '--records', '--password-file', 'pw.txt', '--out', 'x.txt'],
        files: MemoryFiles(<String, Uint8List>{'a/one.pfb': sample.fileBytes})
          ..putText('pw.txt', fixture.password),
        written: first,
      );
      await runCli(
        <String>[
          'info',
          'D:/dbg/two.pfb',
          '--records',
          '--password-file',
          'pw.txt',
          '--out',
          'y.txt',
        ],
        files: MemoryFiles(<String, Uint8List>{'D:/dbg/two.pfb': sample.fileBytes})
          ..putText('pw.txt', fixture.password),
        written: second,
      );
      expect(first.textAt('x.txt'), second.textAt('y.txt'));
    });
  });

  group('密码来源：与 verify 同一套说法', () {
    test('环境变量 PF_PASSWORD 单独可用', () async {
      final fs = filesWithSample();
      final r = await runCli(
        <String>['info', sample.fileName, '--records'],
        files: fs,
        environment: <String, String>{kPasswordEnvVar: fixture.password},
      );
      expect(r.code, ExitCodes.ok);
      expect(r.out.text, startsWith(kCrossCheckReportHeader));
    });

    test('--password-file 优先：环境变量里放错密码也不影响', () async {
      final r = await records(environment: <String, String>{kPasswordEnvVar: 'wrong'});
      expect(r.code, ExitCodes.ok);
    });

    test('两条来源都没有 → 2，且指出两条来源', () async {
      final fs = filesWithSample();
      final r = await runCli(<String>['info', sample.fileName, '--records'], files: fs);
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('缺少密码。二选一：'));
      expect(r.err.text, contains('--password-file'));
      expect(r.err.text, contains(kPasswordEnvVar));
      expect(r.out.text, isEmpty);
    });

    test('环境变量是空串 → 等同没给（2）', () async {
      final fs = filesWithSample();
      final r = await runCli(
        <String>['info', sample.fileName, '--records'],
        files: fs,
        environment: <String, String>{kPasswordEnvVar: ''},
      );
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('缺少密码'));
    });

    test('密码文件不存在 → 2（io-error，不是「密码错」）', () async {
      final r = await runCli(<String>[
        'info',
        sample.fileName,
        '--records',
        '--password-file',
        'nope.txt',
      ], files: filesWithSample());
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('读不到密码文件'));
      expect(r.err.text, isNot(contains('密码错')));
      expect(r.out.text, isEmpty);
    });

    test('密码文件是空文件 → 2，且明说这不是「密码错」', () async {
      final r = await records(passwordText: '');
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('密码为空'));
    });

    test('密码文件只有换行 → 同样是 2', () async {
      final r = await records(passwordText: '\n');
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('密码为空'));
    });

    test('末尾一个换行 / BOM 都会被剥掉（剥不掉就报「密码错」，把人带偏）', () async {
      expect((await records(passwordText: '${fixture.password}\n')).code, ExitCodes.ok);
      expect((await records(passwordText: '\uFEFF${fixture.password}')).code, ExitCodes.ok);
      expect((await records(passwordText: '\uFEFF${fixture.password}\r\n')).code, ExitCodes.ok);
    });
  });

  group('用法错误 → 2（与业务结论 1 分得开）', () {
    test('缺文件参数', () async {
      final r = await runCli(<String>['info', '--records', '--password-file', 'pw.txt']);
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('用法错误'));
    });

    test('--records 与 --json 互斥', () async {
      final r = await records(extraArgs: <String>['--json']);
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('互斥'));
      expect(r.out.text, isEmpty);
    });

    test('数据文件不存在 → 2', () async {
      final r = await runCli(<String>[
        'info',
        'not-here.pfb',
        '--records',
        '--password-file',
        'pw.txt',
      ], files: MemoryFiles()..putText('pw.txt', fixture.password));
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('读不到文件'));
    });
  });

  group('反例：结论为否 → 1', () {
    test('密码错 → PFI_E_WRONG_PASSWORD（文件完好，只有密钥不对）', () async {
      final r = await records(passwordText: fixture.wrongPassword);
      expect(r.code, ExitCodes.negative);
      expect(r.err.text, contains('PFI_E_WRONG_PASSWORD'));
      expect(r.out.text, isEmpty, reason: '结论为否时不该产出半份报告');
    });

    test('文件被改一字节 → PFI_E_CORRUPT，且在解密之前中止', () async {
      final tampered = sample.withTamperedCiphertext();
      final r = await records(
        files: MemoryFiles(<String, Uint8List>{sample.fileName: tampered.fileBytes}),
      );
      expect(r.code, ExitCodes.negative);
      expect(r.err.text, contains('PFI_E_CORRUPT'));
      expect(r.out.text, isEmpty);
    });

    test('这不是本应用的文件 → 1', () async {
      final broken = sample.withBrokenMagic();
      final r = await records(
        files: MemoryFiles(<String, Uint8List>{sample.fileName: broken.fileBytes}),
      );
      expect(r.code, ExitCodes.negative);
      expect(r.err.text, contains('PFI_E_CORRUPT'));
    });
  });

  group('入口细节', () {
    test('三个样本都能跑通，且各自的 fileSha256 出现在报告里', () async {
      for (final id in <String>['sample-full', 'sample-incremental', 'sample-apply-minimal']) {
        final one = fixture.sample(id);
        final r = await runCli(
          <String>['info', one.fileName, '--records', '--password-file', 'pw.txt'],
          files: MemoryFiles(<String, Uint8List>{one.fileName: one.fileBytes})
            ..putText('pw.txt', fixture.password),
        );
        expect(r.code, ExitCodes.ok, reason: id);
        expect(r.out.text, contains('layer1.file.sha256=${one.fileSha256}'), reason: id);
        expect(r.out.text, contains('layer3.ndjson.sha256=${one.payloadNdjsonSha256}'), reason: id);
      }
    });

    test('--out 的路径原样使用（不做任何拼接或规范化）', () async {
      final written = MemoryFiles();
      final r = await records(written: written, extraArgs: <String>['--out', 'nested/dir/out.txt']);
      expect(r.code, ExitCodes.ok);
      expect(written.contains('nested/dir/out.txt'), isTrue);
    });
  });
}

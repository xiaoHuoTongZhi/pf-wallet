/// `pf verify` 的行为测试。
///
/// 输入是 `test_vectors/fixtures/import_samples.json` 里**被向量锁死**的
/// `.pfb`（见 `support/sample.dart` 的解释）。与 info 的分工决定了这里的重点：
/// info 关心「字节对不对」，verify 关心「能不能读出一份完整的载荷」。
/// 所以这组测试要同时证明两件事 ——
///
///   1. **正例真的走到了载荷层**：预期的记录数与逐表条数来自 fixture
///      （Python 生成器写下的值），不是被测代码算出来的；
///   2. **三种否定处境分得开**：密码错 / 文件坏 / 版本不兼容 ——
///      它们的用户动作完全不同，合并任意两个都会把人引向错的方向。
///
/// 密码来源的几种写法（文件、末尾换行、BOM、环境变量）也在这里锁死：
/// 它们都以「密码明明是对的，却报密码错」的形式出错，而那是最难排查的失败。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pf_cli/pf_cli.dart';
import 'package:pf_core/pf_core.dart';
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

  /// 标准调用：`verify <sample> --password-file pw.txt`。
  Future<CliResult> verify({
    MemoryFiles? files,
    String? passwordText,
    Map<String, String> environment = const <String, String>{},
  }) {
    final fs = files ?? filesWithSample();
    fs.putText('pw.txt', passwordText ?? fixture.password);
    return runCli(
      <String>['--json', 'verify', sample.fileName, '--password-file', 'pw.txt'],
      files: fs,
      environment: environment,
    );
  }

  group('正例：正确密码走通完整路径 → 0', () {
    test('四条输出：header、integrity、payload、result', () async {
      final r = await verify();
      expect(r.code, ExitCodes.ok);
      expect(r.err.text, isEmpty);
      expect(r.jsonLines.length, 4);
      expect(r.jsonLines[0]['type'], 'header');
      expect(r.jsonLines[1]['type'], 'integrity');
      expect(r.jsonLines[2]['type'], 'payload');
      expect(r.result['type'], 'result');
      expect(r.result['status'], 'ok');
    });

    test('报出 manifest 计数与记录条数 —— 预期值来自 fixture，不是被测代码', () async {
      final r = await verify();
      expect(r.result['counts'], sample.counts);
      expect(r.result['recordCount'], sample.recordCount);
      expect(r.jsonLines[2]['observedRecordCount'], sample.recordCount);
      expect(r.jsonLines[2]['declaredRecordCount'], sample.recordCount);
      expect(r.jsonLines[2]['exportKind'], sample.exportKind);
      expect(r.jsonLines[2]['payloadVersion'], 1);
      expect(r.jsonLines[2]['skippedUnknownRecordCount'], 0);
      expect(sample.counts.length, 8, reason: 'full 样本覆盖全部八种记录类型');
    });

    test('contentHash 与 fixture 记下的载荷摘要一致（独立来源，非自证）', () async {
      final r = await verify();
      final hash = r.result['contentHash']! as String;
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(hash), isTrue);
      expect(hash, sample.contentHashHex);
      expect(r.jsonLines[2]['contentHash'], sample.contentHashHex);
    });

    test('passwordSource 标明密码来自哪条路（排查时第一个要看的东西）', () async {
      final r = await verify();
      expect(r.result['passwordSource'], 'password-file');
    });

    test('integrity 记录证明「先免密、后解密」的顺序', () async {
      final r = await verify();
      expect(r.jsonLines[1]['intact'], isTrue);
      expect(r.jsonLines[1]['declaredDigest'], r.jsonLines[1]['computedDigest']);
    });

    test('非 JSON 模式的末行同样是结果行', () async {
      final fs = filesWithSample()..putText('pw.txt', fixture.password);
      final r = await runCli(<String>[
        'verify',
        sample.fileName,
        '--password-file',
        'pw.txt',
      ], files: fs);
      expect(r.code, ExitCodes.ok);
      expect(r.lastLine, startsWith('ok'));
    });

    test('增量样本也能读通（它只含 1 条交易，但载荷契约相同）', () async {
      final inc = fixture.incremental;
      final fs = MemoryFiles(<String, Uint8List>{inc.fileName: inc.fileBytes})
        ..putText('pw.txt', fixture.password);
      final r = await runCli(<String>[
        '--json',
        'verify',
        inc.fileName,
        '--password-file',
        'pw.txt',
      ], files: fs);
      expect(r.code, ExitCodes.ok);
      expect(r.result['counts'], inc.counts);
      expect(r.result['recordCount'], inc.recordCount);
      expect(r.jsonLines[2]['exportKind'], 'incremental');
    });
  });

  group('密码文件的写法：都要能打开（否则报的是「密码错」，把人带偏）', () {
    test('末尾一个 \\n → 剥掉后解开', () async {
      final r = await verify(passwordText: '${fixture.password}\n');
      expect(r.code, ExitCodes.ok);
    });

    test('末尾 \\r\\n（Windows 编辑器）→ 剥掉后解开', () async {
      final r = await verify(passwordText: '${fixture.password}\r\n');
      expect(r.code, ExitCodes.ok);
    });

    test('UTF-8 BOM（记事本另存为 UTF-8）→ 剥掉后解开', () async {
      final r = await verify(passwordText: '\uFEFF${fixture.password}');
      expect(r.code, ExitCodes.ok);
    });

    test('BOM + \\r\\n 同时存在 → 两者都剥掉', () async {
      final r = await verify(passwordText: '\uFEFF${fixture.password}\r\n');
      expect(r.code, ExitCodes.ok);
    });

    test('只剥一个换行：末尾两个 \\n 仍剩一个，于是打不开（密码真的不同）', () async {
      final r = await verify(passwordText: '${fixture.password}\n\n');
      expect(r.code, ExitCodes.negative);
      expect(r.result['code'], PfErrorCode.ioWrongPassword);
    });
  });

  group('密码来源：文件优先于环境变量', () {
    test('环境变量 PF_PASSWORD 单独可用', () async {
      final r = await runCli(
        <String>['--json', 'verify', sample.fileName],
        files: filesWithSample(),
        environment: <String, String>{kPasswordEnvVar: fixture.password},
      );
      expect(r.code, ExitCodes.ok);
      expect(r.result['passwordSource'], 'env');
    });

    test('--password-file 优先：环境变量里放错密码也不影响', () async {
      final r = await verify(environment: <String, String>{kPasswordEnvVar: fixture.wrongPassword});
      expect(r.code, ExitCodes.ok);
      expect(r.result['passwordSource'], 'password-file');
    });
  });

  group('反例：结论为否 → 1，且三种处境分得开', () {
    test('密码错 → PFI_E_WRONG_PASSWORD（文件完好，只有密钥不对）', () async {
      final r = await verify(passwordText: fixture.wrongPassword);
      expect(r.code, ExitCodes.negative);
      expect(r.result['code'], PfErrorCode.ioWrongPassword);
      expect(r.result['status'], 'wrong-password');
      expect(r.err.text, contains(PfErrorCode.ioWrongPassword));
      // 免密完整性已经通过 —— 这正是「判定为密码错」的依据。
      expect(r.jsonLines[1]['intact'], isTrue);
    });

    test('文件被改 → PFI_E_CORRUPT，且在解密**之前**就中止', () async {
      final tampered = sample.withTamperedCiphertext();
      final fs = MemoryFiles(<String, Uint8List>{sample.fileName: tampered.fileBytes})
        ..putText('pw.txt', fixture.password);
      final r = await runCli(<String>[
        '--json',
        'verify',
        sample.fileName,
        '--password-file',
        'pw.txt',
      ], files: fs);

      expect(r.code, ExitCodes.negative);
      expect(r.result['status'], 'corrupted');
      expect(r.result['code'], PfErrorCode.ioCorrupt);
      // 中止得够早：没有 payload 行，也没有误判成「密码错」。
      expect(r.jsonLines.length, 3, reason: 'header、integrity、result —— 没有 payload 行');
      expect(r.jsonLines[1]['intact'], isFalse);
      expect(r.err.text, contains('摘要不符'));
    });

    test('这不是本应用的文件 → PFI_E_CORRUPT（先于任何解密）', () async {
      final fs = MemoryFiles(<String, Uint8List>{
        sample.fileName: sample.withBrokenMagic().fileBytes,
      })..putText('pw.txt', fixture.password);
      final r = await runCli(<String>[
        '--json',
        'verify',
        sample.fileName,
        '--password-file',
        'pw.txt',
      ], files: fs);
      expect(r.code, ExitCodes.negative);
      expect(r.result['status'], 'corrupted');
    });

    test('未知特性位 → PFI_E_VERSION（用户该升级应用，不是换文件）', () async {
      final fs = MemoryFiles(<String, Uint8List>{
        sample.fileName: sample.withUnknownFeatureFlag().fileBytes,
      })..putText('pw.txt', fixture.password);
      final r = await runCli(<String>[
        '--json',
        'verify',
        sample.fileName,
        '--password-file',
        'pw.txt',
      ], files: fs);
      expect(r.code, ExitCodes.negative);
      expect(r.result['code'], PfErrorCode.ioVersionIncompatible);
      expect(r.result['status'], 'version-incompatible');
    });

    test('截断的文件 → PFI_E_CORRUPT', () async {
      final fs = MemoryFiles(<String, Uint8List>{
        sample.fileName: sample.truncatedTo(200).fileBytes,
      })..putText('pw.txt', fixture.password);
      final r = await runCli(<String>[
        '--json',
        'verify',
        sample.fileName,
        '--password-file',
        'pw.txt',
      ], files: fs);
      expect(r.code, ExitCodes.negative);
      expect(r.result['status'], 'corrupted');
    });
  });

  group('反例：工具故障 → 2（绝不能与上面的 1 混为一谈）', () {
    test('既没有 --password-file 也没有环境变量 → usage-error，并指出两条来源', () async {
      final r = await runCli(<String>[
        '--json',
        'verify',
        sample.fileName,
      ], files: filesWithSample());
      expect(r.code, ExitCodes.toolError);
      expect(r.result['status'], 'usage-error');
      expect(r.err.text, contains('--password-file'));
      expect(r.err.text, contains(kPasswordEnvVar));
    });

    test('环境变量是空串 → 等同没给', () async {
      final r = await runCli(
        <String>['--json', 'verify', sample.fileName],
        files: filesWithSample(),
        environment: const <String, String>{kPasswordEnvVar: ''},
      );
      expect(r.code, ExitCodes.toolError);
      expect(r.result['status'], 'usage-error');
    });

    test('密码文件不存在 → io-error', () async {
      final r = await runCli(<String>[
        '--json',
        'verify',
        sample.fileName,
        '--password-file',
        'nowhere.txt',
      ], files: filesWithSample());
      expect(r.code, ExitCodes.toolError);
      expect(r.result['status'], 'io-error');
      expect(r.err.text, contains('读不到密码文件'));
    });

    test('密码文件是空文件 → usage-error，且明说这不是「密码错」', () async {
      final r = await verify(passwordText: '');
      expect(r.code, ExitCodes.toolError);
      expect(r.result['status'], 'usage-error');
      expect(r.err.text, contains('密码为空'));
    });

    test('密码文件只有换行 → 同样是 usage-error', () async {
      final r = await verify(passwordText: '\n');
      expect(r.code, ExitCodes.toolError);
      expect(r.result['status'], 'usage-error');
    });

    test('数据文件不存在 → io-error', () async {
      final fs = MemoryFiles()..putText('pw.txt', fixture.password);
      final r = await runCli(<String>[
        '--json',
        'verify',
        sample.fileName,
        '--password-file',
        'pw.txt',
      ], files: fs);
      expect(r.code, ExitCodes.toolError);
      expect(r.result['status'], 'io-error');
      expect(r.err.text, contains('读不到文件'));
    });

    test('缺文件参数 → usage-error', () async {
      final r = await runCli(<String>['--json', 'verify'], files: filesWithSample());
      expect(r.code, ExitCodes.toolError);
      expect(r.result['status'], 'usage-error');
    });
  });

  group('入口的两条路径细节', () {
    test('带目录的路径原样回显在 file 里（脚本要能直接比对）', () async {
      const deep = '/home/someone/backups/sample-full.pfb';
      final fs = MemoryFiles(<String, Uint8List>{deep: sample.fileBytes})
        ..putText('pw.txt', fixture.password);
      final r = await runCli(<String>[
        '--json',
        'verify',
        deep,
        '--password-file',
        'pw.txt',
      ], files: fs);
      expect(r.code, ExitCodes.ok);
      expect(r.result['file'], deep);
    });
  });

  group('密码解码：只剥 BOM 与末尾一个换行', () {
    Uint8List of(String s) => Uint8List.fromList(utf8.encode(s));

    test('原样、末尾换行、BOM、空', () {
      expect(decodePasswordBytes(of('secret')), of('secret'));
      expect(decodePasswordBytes(of('secret\n')), of('secret'));
      expect(decodePasswordBytes(of('secret\r\n')), of('secret'));
      expect(decodePasswordBytes(of('secret\n\n')), of('secret\n'));
      expect(decodePasswordBytes(of('\uFEFFsecret')), of('secret'));
      expect(decodePasswordBytes(of('\uFEFFsecret\r\n')), of('secret'));
      expect(decodePasswordBytes(of('')), isEmpty);
      expect(decodePasswordBytes(of('\n')), isEmpty);
      expect(decodePasswordBytes(of('\uFEFF')), isEmpty);
    });

    test('前后空格是密码的一部分，不被 trim 掉', () {
      expect(decodePasswordBytes(of('  secret  ')), of('  secret  '));
      expect(decodePasswordBytes(of('  secret  \n')), of('  secret  '));
    });
  });

  group('baseNameOf：两种分隔符都认', () {
    test('取最后一段', () {
      expect(baseNameOf('a.pfb'), 'a.pfb');
      expect(baseNameOf('/tmp/a.pfb'), 'a.pfb');
      expect(baseNameOf(r'C:\backups\a.pfb'), 'a.pfb');
      expect(baseNameOf('/tmp/dir/'), '');
      expect(baseNameOf(''), '');
    });
  });
}

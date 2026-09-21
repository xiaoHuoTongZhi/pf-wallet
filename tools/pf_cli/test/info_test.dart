/// `pf info` 的行为测试。
///
/// 输入是 `test_vectors/fixtures/import_samples.json` 里**被向量锁死**的
/// `.pfb`（见 `support/sample.dart` 的解释），预期值来自两处独立来源：
///   1. 用 `PfbLayout.slice` 从字节里**独立解出**的头部 —— 证明 CLI
///      打的是头部里的值，不是它自己猜的；
///   2. fixture 记录的 `fileSha256` —— 证明整文件摘要没算错。
///
/// 两态分界也在这里锁死：结构问题与内容问题**都**返回 1（结论为否），
/// 但 `status` 不同；而「读不到文件」必须返回 2 —— 脚本据此决定
/// 是去查路径，还是去换一份备份。
library;

import 'dart:typed_data';

import 'package:pf_cli/pf_cli.dart';
import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';
import 'package:test/test.dart';

import 'support/harness.dart';
import 'support/sample.dart';

void main() {
  late VectorFixture fixture;
  late VectorSample sample;
  late MemoryFiles files;

  setUpAll(() {
    fixture = loadVectorFixture();
    sample = fixture.full;
  });

  setUp(() {
    files = MemoryFiles(<String, Uint8List>{sample.fileName: sample.fileBytes});
  });

  Future<CliResult> info(String path, {MemoryFiles? withFiles}) =>
      runCli(<String>['--json', 'info', path], files: withFiles ?? files);

  group('正例：完整合法文件 → 0', () {
    test('三条输出：header、integrity、result', () async {
      final r = await info(sample.fileName);
      expect(r.code, ExitCodes.ok);
      expect(r.err.text, isEmpty, reason: '成功时 stdout 只有信息，stderr 干净');
      expect(r.jsonLines.length, 3);
      expect(r.jsonLines[0]['type'], 'header');
      expect(r.jsonLines[1]['type'], 'integrity');
      expect(r.result['type'], 'result');
      expect(r.result['status'], 'ok');
    });

    test('头部字段与独立解出的头部逐项相同（不解释、不篡改）', () async {
      final r = await info(sample.fileName);
      final header = PfbLayout.slice(sample.fileBytes).header;
      final printed = r.jsonLines[0];

      expect(printed['formatVersion'], header.formatVersion);
      expect(printed['minReaderVersion'], header.minReaderVersion);
      expect(printed['chunkPlainSizeKiB'], header.chunkPlainSizeKiB);
      expect(printed['chunkCount'], header.chunkCount);
      expect(printed['plaintextLength'], header.plaintextLength);
      expect(printed['volumeIndex'], header.volumeIndex);
      expect(printed['volumeTotal'], header.volumeTotal);
      expect(printed['featureFlags'], '0x${header.featureFlags.toRadixString(16).padLeft(4, '0')}');
    });

    test('KDF 参数按头部原样打出（值来自不可信输入，必须看得见）', () async {
      final r = await info(sample.fileName);
      final printed = r.jsonLines[0];
      final kdf = PfbLayout.slice(sample.fileBytes).header.kdf;
      expect(printed['kdf'], kdf.describe());
      expect(printed['kdfMemoryKiB'], kdf.memoryKiB);
      expect(printed['kdfIterations'], kdf.iterations);
      expect(printed['kdfParallelism'], kdf.parallelism);
      expect(printed['kdf'], 'm=19MiB t=2 p=1');
    });

    test('gzip / chunked 明确给出（这两个是载荷能否解出来的前提）', () async {
      final r = await info(sample.fileName);
      expect(r.jsonLines[0]['gzip'], isTrue);
      expect(r.jsonLines[0]['chunked'], isTrue);
      expect(r.jsonLines[0]['multiVolume'], isFalse);
      expect(r.jsonLines[0]['volumeTotal'], 1);
    });

    test('摘要两态：intact=true，且声明值与计算值相同', () async {
      final r = await info(sample.fileName);
      final integrity = r.jsonLines[1];
      expect(integrity['intact'], isTrue);
      expect(integrity['declaredDigest'], integrity['computedDigest']);
      expect(r.result['intact'], isTrue);
    });

    test('fileSha256 与 fixture 记下的值相同（独立来源，非自证）', () async {
      final r = await info(sample.fileName);
      final digest = r.jsonLines[1]['fileSha256']! as String;
      expect(digest, sample.fileSha256);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(digest), isTrue);
    });

    test('结果行带上格式版本、块数与明文长度 —— 脚本看这三项就够判断', () async {
      final r = await info(sample.fileName);
      expect(r.result['formatVersion'], 1);
      expect(r.result['chunkCount'], 1);
      expect(r.result['plaintextLength'], greaterThan(0));
      expect(r.result['file'], sample.fileName);
    });

    test('非 JSON 模式的末行同样是结果行，且信息顺序一致', () async {
      final r = await runCli(<String>['info', sample.fileName], files: files);
      expect(r.code, ExitCodes.ok);
      expect(r.out.lines[0], startsWith('header'));
      expect(r.out.lines[1], startsWith('integrity'));
      expect(r.lastLine, startsWith('ok'));
    });
  });

  group('标志位由头部决定，不由工具猜', () {
    test('含附件的样本 → hasAttachments=true', () async {
      expect(sample.hasAttachments, isTrue, reason: '样本本身要含附件，否则这条测试没有意义');
      final r = await info(sample.fileName);
      expect(r.jsonLines[0]['hasAttachments'], isTrue);
      expect(r.jsonLines[0]['incremental'], isFalse);
    });

    test('增量导出的样本 → incremental=true，且没有附件', () async {
      final inc = fixture.incremental;
      final r = await info(
        inc.fileName,
        withFiles: MemoryFiles(<String, Uint8List>{inc.fileName: inc.fileBytes}),
      );
      expect(r.jsonLines[0]['incremental'], isTrue);
      expect(r.jsonLines[0]['hasAttachments'], isFalse);
      expect(r.jsonLines[0]['gzip'], isTrue);
    });

    test('标志位与独立解出的头部一致（三份样本各验一次）', () async {
      for (final s in <VectorSample>[fixture.full, fixture.incremental, fixture.minimal]) {
        final r = await info(
          s.fileName,
          withFiles: MemoryFiles(<String, Uint8List>{s.fileName: s.fileBytes}),
        );
        final flags = PfbLayout.slice(s.fileBytes).header.featureFlags;
        expect(
          r.jsonLines[0]['hasAttachments'],
          (flags & PfbFlags.bitHasAttachments) != 0,
          reason: s.id,
        );
        expect(r.jsonLines[0]['incremental'], (flags & PfbFlags.bitIncremental) != 0, reason: s.id);
      }
    });
  });

  group('反例：结构问题 → 1（结论为否，不是工具故障）', () {
    Future<void> expectsNegative(VectorSample broken, String code, String status) async {
      final r = await info(
        'bad.pfb',
        withFiles: MemoryFiles(<String, Uint8List>{'bad.pfb': broken.fileBytes}),
      );
      expect(r.code, ExitCodes.negative);
      expect(r.result['code'], code);
      expect(r.result['status'], status);
      expect(r.err.text, contains(code), reason: 'stderr 要带上错误码 —— 它是检索锚点');
      expect(r.result['userMessage'], isNotEmpty, reason: '结果行要给可执行的用户提示');
      expect(r.result['exitCode'], ExitCodes.negative);
    }

    test('魔数不符 → PFI_E_CORRUPT（这不是本应用的文件）', () async {
      await expectsNegative(sample.withBrokenMagic(), PfErrorCode.ioCorrupt, 'corrupted');
    });

    test('文件短于魔数长度 → PFI_E_CORRUPT', () async {
      await expectsNegative(sample.truncatedTo(4), PfErrorCode.ioCorrupt, 'corrupted');
    });

    test('文件短于头部长度 → PFI_E_CORRUPT', () async {
      await expectsNegative(sample.truncatedTo(100), PfErrorCode.ioCorrupt, 'corrupted');
    });

    test('头部 CRC 不符 → PFI_E_CORRUPT', () async {
      await expectsNegative(sample.withBrokenHeaderCrc(), PfErrorCode.ioCorrupt, 'corrupted');
    });

    test('未知特性位 → PFI_E_VERSION（换文件不够，要升级应用）', () async {
      await expectsNegative(
        sample.withUnknownFeatureFlag(),
        PfErrorCode.ioVersionIncompatible,
        'version-incompatible',
      );
    });
  });

  group('反例：内容被改过 → 1，但头部仍读得出来', () {
    test('密文被改 → intact=false，声明值与计算值不同', () async {
      final tampered = sample.withTamperedCiphertext();
      final r = await info(
        't.pfb',
        withFiles: MemoryFiles(<String, Uint8List>{'t.pfb': tampered.fileBytes}),
      );

      expect(r.code, ExitCodes.negative);
      expect(r.result['status'], 'corrupted');
      expect(r.result['intact'], isFalse);

      // 关键分界：头部**没有**坏（仍然打出了三条输出），坏的只是内容。
      expect(r.jsonLines.length, 3);
      expect(r.jsonLines[0]['type'], 'header');
      expect(r.jsonLines[1]['intact'], isFalse);
      expect(r.jsonLines[1]['declaredDigest'], isNot(r.jsonLines[1]['computedDigest']));
      expect(r.jsonLines[1]['declaredDigest'], isNotEmpty);
      expect(r.jsonLines[1]['computedDigest'], isNotEmpty);
    });

    test('被改过的文件仍报出可用的头部信息（诊断价值就在这里）', () async {
      final tampered = sample.withTamperedCiphertext();
      final r = await info(
        't.pfb',
        withFiles: MemoryFiles(<String, Uint8List>{'t.pfb': tampered.fileBytes}),
      );
      final header = PfbLayout.slice(sample.fileBytes).header;
      expect(r.jsonLines[0]['formatVersion'], header.formatVersion);
      expect(r.jsonLines[0]['kdf'], header.kdf.describe());
    });
  });

  group('反例：工具故障 → 2（脚本该修路径，不是换文件）', () {
    test('文件不存在 → io-error', () async {
      final r = await runCli(<String>['--json', 'info', 'missing.pfb']);
      expect(r.code, ExitCodes.toolError);
      expect(r.result['status'], 'io-error');
      expect(r.err.text, contains('读不到文件'));
    });

    test('缺文件参数 → usage-error', () async {
      final r = await runCli(<String>['--json', 'info']);
      expect(r.code, ExitCodes.toolError);
      expect(r.result['status'], 'usage-error');
      expect(r.err.text, contains('需要一个文件参数'));
    });

    test('「读不到文件」绝不能是 1 —— 那会把路径写错读成备份损坏', () async {
      final r = await runCli(<String>['info', 'missing.pfb']);
      expect(r.code, isNot(ExitCodes.negative));
    });
  });
}

/// `PfbExportAssembler` 的行为测试。
///
/// 容器字节与 KDF 由 container / export_payload 向量锁死；这里守装配层的
/// 行为边界：固定随机源下的确定性、GZIP 位置（先压缩后加密）、读回自校验、
/// 以及 flags 的正确映射。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pf_crypto/pf_crypto.dart';
import 'package:pf_io/pf_io.dart';
import 'package:test/test.dart';

final _salt = Uint8List.fromList(List.generate(16, (i) => 0x10 + i));
final _prefix = Uint8List.fromList(List.generate(8, (i) => 0xA0 + i));
final _volumeSetId = Uint8List.fromList(List.generate(8, (i) => i));
final _password = Uint8List.fromList(utf8.encode('export-test-pass'));

PayloadBuildResult _payload({int records = 3}) {
  final stages = <String, List<Map<String, Object?>>>{};
  for (var i = 0; i < records; i++) {
    stages
        .putIfAbsent(
          kPayloadStageOrder[i % kPayloadStageOrder.length],
          () => <Map<String, Object?>>[],
        )
        .add(<String, Object?>{'id': 'id-$i'});
  }
  return PfbPayloadEncoder.encode(
    manifest: <String, Object?>{
      'type': 'manifest',
      'appVersion': '1.0.0',
      'deviceId': '01J8Z9K2M4P6Q8R0T2V4X6Z8B1',
      'exportedAt': 1757922436789,
      'exportKind': 'full',
      'includesAttachments': false,
    },
    stages: stages,
    generatedAtMilliseconds: 1757922437000,
  );
}

void main() {
  group('PfbExportAssembler.assemble · 固定随机源', () {
    test('两次装配输出逐字节相同（确定性）', () async {
      final assembler = PfbExportAssembler();
      final a = await assembler.assemble(
        payload: _payload(),
        password: _password,
        kdf: Argon2Params.presetMin,
        salt: _salt,
        noncePrefix: _prefix,
        volumeSetId: _volumeSetId,
      );
      final b = await assembler.assemble(
        payload: _payload(),
        password: _password,
        kdf: Argon2Params.presetMin,
        salt: _salt,
        noncePrefix: _prefix,
        volumeSetId: _volumeSetId,
      );
      expect(a.fileSha256Hex, b.fileSha256Hex);
      expect(a.fileBytes, b.fileBytes);
    });

    test('头部 flags：gzip + chunked 置位；plaintextLength = GZIP 长度', () async {
      final assembler = PfbExportAssembler();
      final result = await assembler.assemble(
        payload: _payload(),
        password: _password,
        kdf: Argon2Params.presetMin,
        includeAttachments: true,
        incremental: true,
        salt: _salt,
        noncePrefix: _prefix,
        volumeSetId: _volumeSetId,
      );
      final header = PfbLayout.slice(result.fileBytes).header;
      expect(header.flagGzip, isTrue);
      expect(header.flagChunked, isTrue);
      expect((header.featureFlags & PfbFlags.bitHasAttachments) != 0, isTrue);
      expect(header.flagIncremental, isTrue);
      expect(header.plaintextLength, result.gzipBytes.length);
      expect(result.verifiedByReadBack, isTrue);
    });
  });

  group('PfbExportAssembler.assemble · GZIP 位置与读回', () {
    test('容器解出的明文是 GZIP 流，解压后与载荷字节一致（先压缩后加密）', () async {
      final assembler = PfbExportAssembler();
      final payload = _payload();
      final result = await assembler.assemble(
        payload: payload,
        password: _password,
        kdf: Argon2Params.presetMin,
        salt: _salt,
        noncePrefix: _prefix,
        volumeSetId: _volumeSetId,
      );
      // GZIP 魔数 1f 8b 在加密前的明文里 —— 解密回来的就是它。
      expect(result.gzipBytes[0], 0x1F);
      expect(result.gzipBytes[1], 0x8B);
      final decompressed = Uint8List.fromList(GZipCodec().decode(result.gzipBytes));
      expect(decompressed, payload.ndjsonBytes);
    });

    test('recordCount 与 contentHash 原样透传', () async {
      final assembler = PfbExportAssembler();
      final payload = _payload(records: 5);
      final result = await assembler.assemble(
        payload: payload,
        password: _password,
        kdf: Argon2Params.presetMin,
        salt: _salt,
        noncePrefix: _prefix,
        volumeSetId: _volumeSetId,
      );
      expect(result.recordCount, payload.recordCount);
      expect(result.contentHashHex, payload.contentHashHex);
    });

    test('未传固定随机源时盐/nonce 前缀由安全随机生成且自校验仍通过', () async {
      final result = await PfbExportAssembler().assemble(
        payload: _payload(),
        password: _password,
        kdf: Argon2Params.presetMin,
      );
      expect(result.salt.length, PfbFormat.saltLength);
      expect(result.noncePrefix.length, PfbFormat.noncePrefixLength);
      expect(PfbContainer.verifyContentDigest(result.fileBytes).matches, isTrue);
    });
  });
}

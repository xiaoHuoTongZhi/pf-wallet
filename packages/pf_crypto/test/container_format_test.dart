import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';
import 'package:test/test.dart';

const int _exportedAt = 1735689600000; // 2025-01-01T00:00:00Z

Uint8List zeroDeviceId() => Uint8List(PfbFormat.deviceIdLength);

PfbHeader buildHeader({
  int plaintextLength = 1024,
  Argon2Params params = Argon2Params.mobileDefault,
  int? majorVersion,
  int? minorVersion,
}) => PfbHeader.create(
  params: params,
  plaintextLength: plaintextLength,
  exportedAtMilliseconds: _exportedAt,
  deviceId: zeroDeviceId(),
  majorVersion: majorVersion,
  minorVersion: minorVersion,
);

/// 构造一个结构合法但内容未加密的容器，用于纯布局测试。
Uint8List buildSyntheticContainer({
  int plaintextLength = 1024,
  Argon2Params params = Argon2Params.mobileDefault,
  int? majorVersion,
  int? minorVersion,
  int trailerDigestAlgorithm = PfbAlgorithm.digestSha256,
}) {
  final header = buildHeader(
    plaintextLength: plaintextLength,
    params: params,
    majorVersion: majorVersion,
    minorVersion: minorVersion,
  );
  final trailer = PfbTrailer(
    digestAlgorithm: trailerDigestAlgorithm,
    digest: Uint8List(PfbFormat.trailerDigestLength),
  );
  final total = PfbFormat.exactFileLength(header);
  final file =
      Uint8List(total)
        ..setRange(0, PfbFormat.headerSize, header.encode())
        ..setRange(total - PfbFormat.trailerSize, total, trailer.encode());
  return file;
}

void main() {
  group('格式常量（改动即破坏已发布的备份文件）', () {
    test('魔数与大小时刻字面值', () {
      expect(pfbMagic, <int>[0x50, 0x46, 0x42, 0x31]); // "PFB1"
      expect(pfbTrailerMagic, <int>[0x50, 0x46, 0x42, 0x46]); // "PFBF"
      expect(PfbFormat.headerSize, 76);
      expect(PfbFormat.trailerSize, 40);
      expect(PfbFormat.deviceIdLength, 16);
    });

    test('头部字段偏移不重叠且不越界', () {
      final spans = <(int, int)>[
        (PfbFormat.offsetMagic, 4),
        (PfbFormat.offsetMajorVersion, 2),
        (PfbFormat.offsetMinorVersion, 2),
        (PfbFormat.offsetKdfAlgorithm, 2),
        (PfbFormat.offsetAeadAlgorithm, 2),
        (PfbFormat.offsetKdfMemoryKiB, 4),
        (PfbFormat.offsetKdfIterations, 4),
        (PfbFormat.offsetKdfParallelism, 2),
        (PfbFormat.offsetSaltLength, 2),
        (PfbFormat.offsetNonceLength, 2),
        (PfbFormat.offsetTagLength, 2),
        (PfbFormat.offsetPlaintextLength, 8),
        (PfbFormat.offsetExportedAt, 8),
        (PfbFormat.offsetDeviceId, 16),
        (PfbFormat.offsetReserved, 16),
      ];
      final covered = <int>{};
      for (final (start, length) in spans) {
        for (var i = start; i < start + length; i++) {
          expect(covered.add(i), isTrue, reason: '字节 $i 被多个字段占用');
        }
      }
      expect(covered.length, PfbFormat.headerSize, reason: '头部必须被字段完整覆盖，不留空洞');
    });

    test('算法 ID 与版本号是契约', () {
      expect(PfbAlgorithm.kdfArgon2id, 1);
      expect(PfbAlgorithm.aeadAes256Gcm, 1);
      expect(PfbAlgorithm.digestSha256, 1);
      expect(PfbFormat.majorVersion, PfBuildInfo.containerFormatVersion);
    });
  });

  group('PfbHeader 编码', () {
    test('编码结果恰好 76 字节，且前 4 字节为魔数', () {
      final bytes = buildHeader().encode();
      expect(bytes.length, PfbFormat.headerSize);
      expect(bytes.sublist(0, 4), pfbMagic);
    });

    test('大端序写入（高字节在前）', () {
      final bytes = buildHeader(majorVersion: 0x0102).encode();
      expect(bytes[4], 0x01);
      expect(bytes[5], 0x02);
    });

    test('保留位全 0', () {
      final bytes = buildHeader().encode();
      for (var i = 0; i < PfbFormat.reservedLength; i++) {
        expect(bytes[PfbFormat.offsetReserved + i], 0);
      }
    });

    test('导出时刻与明文长度按 u64 写入', () {
      final bytes = buildHeader(plaintextLength: 0x0102030405).encode();
      expect(TestBigEndian.read(bytes, PfbFormat.offsetPlaintextLength, 8), 0x0102030405);
      expect(TestBigEndian.read(bytes, PfbFormat.offsetExportedAt, 8), _exportedAt);
    });
  });

  group('PfbHeader 解码与错误分类', () {
    test('往返一致', () {
      final original = buildHeader(plaintextLength: 4096);
      final decoded = PfbHeader.decode(original.encode());
      expect(decoded.majorVersion, original.majorVersion);
      expect(decoded.minorVersion, original.minorVersion);
      expect(decoded.plaintextLength, 4096);
      expect(decoded.kdfParams, original.kdfParams);
      expect(decoded.exportedAtMilliseconds, _exportedAt);
      expect(decoded.deviceId, original.deviceId);
    });

    test('魔数不对 → PFB_E_MAGIC', () {
      final bytes = buildHeader().encode()..[0] = 0x00;
      expect(
        () => PfbHeader.decode(bytes),
        throwsA(isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerMagic)),
      );
    });

    test('文件过短 → PFB_E_TRUNCATED', () {
      expect(
        () => PfbHeader.decode(Uint8List(20)),
        throwsA(
          isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerTruncated),
        ),
      );
    });

    test('主版本过高 → PFB_E_VERSION_UNSUPPORTED（而不是报一堆字段错误）', () {
      final bytes = buildHeader(majorVersion: PfbFormat.majorVersion + 1).encode();
      expect(
        () => PfbHeader.decode(bytes),
        throwsA(
          isA<ContainerError>().having(
            (e) => e.code,
            'code',
            PfErrorCode.containerVersionUnsupported,
          ),
        ),
      );
    });

    test('显式指定上限时，恰好等于上限可通过', () {
      final bytes = buildHeader(majorVersion: 3).encode();
      expect(PfbHeader.decode(bytes, maxSupportedMajorVersion: 3).majorVersion, 3);
    });

    test('次版本更高时接受（次版本只允许新增算法 ID）', () {
      final bytes = buildHeader(minorVersion: 99).encode();
      expect(PfbHeader.decode(bytes).minorVersion, 99);
    });

    test('保留位非 0 → PFB_E_HEADER_INVALID（拒绝猜测未来语义）', () {
      final bytes = buildHeader().encode()..[PfbFormat.offsetReserved] = 1;
      expect(
        () => PfbHeader.decode(bytes),
        throwsA(
          isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerHeaderInvalid),
        ),
      );
    });

    test('未知 KDF 算法 ID → 明确报错而非猜测', () {
      final bytes = buildHeader().encode();
      TestBigEndian.write(bytes, PfbFormat.offsetKdfAlgorithm, 2, 99);
      expect(
        () => PfbHeader.decode(bytes),
        throwsA(
          isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerHeaderInvalid),
        ),
      );
    });

    test('未知 AEAD 算法 ID → 报错', () {
      final bytes = buildHeader().encode();
      TestBigEndian.write(bytes, PfbFormat.offsetAeadAlgorithm, 2, 7);
      expect(() => PfbHeader.decode(bytes), throwsA(isA<ContainerError>()));
    });

    test('nonce 长度不是 12 → 报错', () {
      final bytes = buildHeader().encode();
      TestBigEndian.write(bytes, PfbFormat.offsetNonceLength, 2, 16);
      expect(() => PfbHeader.decode(bytes), throwsA(isA<ContainerError>()));
    });

    test('标签长度不是 16 → 报错', () {
      final bytes = buildHeader().encode();
      TestBigEndian.write(bytes, PfbFormat.offsetTagLength, 2, 8);
      expect(() => PfbHeader.decode(bytes), throwsA(isA<ContainerError>()));
    });

    test('明文长度上限被强制执行（防御头部驱动的巨额分配）', () {
      final bytes = buildHeader().encode();
      TestBigEndian.write(
        bytes,
        PfbFormat.offsetPlaintextLength,
        8,
        PfbFormat.maxPlaintextLength + 1,
      );
      expect(
        () => PfbHeader.decode(bytes),
        throwsA(
          isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerHeaderInvalid),
        ),
      );
    });

    test('恶意 KDF 参数（16 GiB 内存）在解析文件头阶段就被拦下', () {
      final bytes = buildHeader().encode();
      TestBigEndian.write(bytes, PfbFormat.offsetKdfMemoryKiB, 4, 16777216);
      expect(
        () => PfbHeader.decode(bytes),
        throwsA(isA<CryptoError>().having((e) => e.code, 'code', PfErrorCode.kdfParamsOutOfRange)),
      );
    });

    test('导出时刻为 0 → 报错', () {
      final bytes = buildHeader().encode();
      TestBigEndian.write(bytes, PfbFormat.offsetExportedAt, 8, 0);
      expect(() => PfbHeader.decode(bytes), throwsA(isA<ContainerError>()));
    });
  });

  group('PfbTrailer', () {
    test('编码恰好 40 字节，尾部魔数在偏移 36', () {
      final trailer = PfbTrailer(
        digestAlgorithm: PfbAlgorithm.digestSha256,
        digest: Uint8List(PfbFormat.trailerDigestLength),
      );
      final bytes = trailer.encode();
      expect(bytes.length, PfbFormat.trailerSize);
      expect(bytes.sublist(36, 40), pfbTrailerMagic);
    });

    test('往返一致', () {
      final digest = Uint8List.fromList(List<int>.generate(32, (i) => i * 7 % 256));
      final trailer = PfbTrailer(digestAlgorithm: PfbAlgorithm.digestSha256, digest: digest);
      final decoded = PfbTrailer.decode(trailer.encode());
      expect(decoded.digest, digest);
      expect(decoded.digestAlgorithm, PfbAlgorithm.digestSha256);
    });

    test('摘要长度不对直接拒绝', () {
      expect(
        () => PfbTrailer(digestAlgorithm: PfbAlgorithm.digestSha256, digest: Uint8List(16)),
        throwsA(isA<ContainerError>()),
      );
    });

    test('未知摘要算法拒绝', () {
      expect(
        () => PfbTrailer(digestAlgorithm: 42, digest: Uint8List(32)),
        throwsA(isA<ContainerError>()),
      );
    });

    test('尾部魔数不符 → 明确提示"可能被追加了数据"', () {
      final bytes =
          PfbTrailer(digestAlgorithm: PfbAlgorithm.digestSha256, digest: Uint8List(32)).encode();
      bytes[36] = 0x00;
      expect(
        () => PfbTrailer.decode(bytes),
        throwsA(
          isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerDigestMismatch),
        ),
      );
    });

    test('长度不对 → PFB_E_TRUNCATED', () {
      expect(
        () => PfbTrailer.decode(Uint8List(39)),
        throwsA(
          isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerTruncated),
        ),
      );
    });
  });

  group('PfbLayout 切分', () {
    test('各段偏移与长度正确', () {
      const plaintextLength = 300;
      final file = buildSyntheticContainer(plaintextLength: plaintextLength);

      expect(file.length, PfbFormat.headerSize + 16 + 12 + 300 + 16 + PfbFormat.trailerSize);

      final slices = PfbLayout.slice(file);
      expect(slices.salt.length, 16);
      expect(slices.nonce.length, 12);
      expect(slices.ciphertext.length, plaintextLength);
      expect(slices.tag.length, 16);
      expect(slices.header.plaintextLength, plaintextLength);
    });

    test('明文长度为 0 时仍然自洽（空账本也能导出）', () {
      final file = buildSyntheticContainer(plaintextLength: 0);
      final slices = PfbLayout.slice(file);
      expect(slices.ciphertext, isEmpty);
      expect(file.length, PfbFormat.headerSize + 16 + 12 + 16 + PfbFormat.trailerSize);
    });

    test('文件被截断 → PFB_E_TRUNCATED', () {
      final file = buildSyntheticContainer();
      final truncated = Uint8List.sublistView(file, 0, file.length - 5);
      expect(
        () => PfbLayout.slice(truncated),
        throwsA(
          isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerTruncated),
        ),
      );
    });

    test('尾部被追加数据 → 拒绝（多余字节不受摘要保护）', () {
      final file = buildSyntheticContainer();
      final extended = Uint8List(file.length + 8)..setRange(0, file.length, file);
      expect(
        () => PfbLayout.slice(extended),
        throwsA(
          isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerHeaderInvalid),
        ),
      );
    });

    test('切分结果是原缓冲区的视图，不做额外拷贝', () {
      final file = buildSyntheticContainer(plaintextLength: 16);
      final slices = PfbLayout.slice(file);
      final firstCiphertextOffset =
          PfbFormat.headerSize + slices.header.saltLength + slices.header.nonceLength;
      slices.ciphertext[0] = 0xAB;
      expect(file[firstCiphertextOffset], 0xAB);
    });

    test('不同 Argon2 参数下的文件长度随之变化', () {
      final mobile = buildSyntheticContainer(params: Argon2Params.mobileDefault);
      final desktop = buildSyntheticContainer(params: Argon2Params.desktopDefault);
      expect(mobile.length, desktop.length, reason: '长度只由盐/nonce/tag/明文决定，与 m/t/p 无关');
      expect(PfbLayout.slice(desktop).header.kdfParams, Argon2Params.desktopDefault);
    });
  });

  group('exactFileLength', () {
    test('与构造出的实际文件长度一致', () {
      for (final length in <int>[0, 1, 255, 4096, 100000]) {
        final header = buildHeader(plaintextLength: length);
        final file = buildSyntheticContainer(plaintextLength: length);
        expect(file.length, PfbFormat.exactFileLength(header));
      }
    });
  });
}

/// 测试内的最小大端读写（避免测试与实现共用同一份易错代码）。
abstract final class TestBigEndian {
  static int read(Uint8List bytes, int offset, int length) {
    var value = 0;
    for (var i = 0; i < length; i++) {
      value = (value << 8) | bytes[offset + i];
    }
    return value;
  }

  static void write(Uint8List bytes, int offset, int length, int value) {
    for (var i = length - 1; i >= 0; i--) {
      bytes[offset + i] = (value >> ((length - 1 - i) * 8)) & 0xFF;
    }
  }
}

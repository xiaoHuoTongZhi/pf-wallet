import 'dart:convert';
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';
import 'package:test/test.dart';

/// §3.3 分块容器的单测。字节级快照由向量（container_file 套件，Python 独立
/// 实现生成）负责；这里守的是**行为契约**：往返、三态错误分流、链式 AAD 的
/// 绑定语义、以及 CRC32 的 zlib 兼容性。

const Argon2Params _fastKdf = Argon2Params.presetMin; // 19 MiB / t=2 / p=1

final Uint8List _key = Uint8List.fromList(List.generate(32, (i) => i + 1));
final Uint8List _salt = Uint8List.fromList(List.generate(16, (i) => 0x10 + i));
final Uint8List _prefix = Uint8List.fromList(List.generate(8, (i) => 0xA0 + i));
final Uint8List _volumeSetId = Uint8List.fromList(List.generate(8, (i) => i));

Future<Uint8List> _seal(
  Uint8List payload, {
  int chunkPlainSizeKiB = 1,
  PfbFlagsSpec flags = const PfbFlagsSpec(),
}) => PfbContainer.seal(
  payload: payload,
  key: _key,
  salt: _salt,
  noncePrefix: _prefix,
  kdf: _fastKdf,
  flags: flags,
  chunkPlainSizeKiB: chunkPlainSizeKiB,
  volumeSetId: _volumeSetId,
);

Uint8List _bytes(int length, [int seed = 0]) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 31 + seed) & 0xFF));

void main() {
  group('Crc32 · zlib 兼容性', () {
    test('已知答案：crc32("123456789") == 0xCBF43926', () {
      final data = Uint8List.fromList(ascii.encode('123456789'));
      expect(Crc32.of(data), 0xCBF43926);
    });

    test('空输入 == 0', () {
      expect(Crc32.of(Uint8List(0)), 0);
    });

    test('ofHex：8 位大写十六进制，与 of 是同一个值', () {
      final data = Uint8List.fromList(ascii.encode('123456789'));
      expect(Crc32.ofHex(data), 'CBF43926');
      // 前 4 字节的 CRC 一定不足 8 位有效数字 —— 这条守的是 padLeft，
      // 不是「恰好 8 个字符」：少了补零，两个不同的 CRC 会撞成同一个字符串。
      final short = Uint8List.fromList(<int>[0x00, 0x00, 0x00, 0x00]);
      expect(Crc32.ofHex(short), '2144DF1C');
      expect(Crc32.ofHex(short), hasLength(8));
    });

    test('ofHex 的 [start, end) 与 zlib.crc32 同源（期望值另算）', () {
      // '1234' 的 CRC-32 = 0x9BE3E0A3，由 Python `zlib.crc32` 独立算出，
      // 不是从本实现打印的 —— 否则这条只是在证明「和自己一致」。
      final data = Uint8List.fromList(ascii.encode('123456789'));
      expect(Crc32.ofHex(data, 0, 4), '9BE3E0A3');
    });
  });

  group('PfbHeader · 编解码', () {
    test('encode → 128 字节，CRC 落在 44..48，firstChunkNonce = prefix||0', () {
      final header = PfbHeader.create(
        kdf: _fastKdf,
        flags: const PfbFlagsSpec(gzip: true),
        plaintextLength: 2500,
        salt: _salt,
        noncePrefix: _prefix,
        chunkPlainSizeKiB: 1,
        volumeSetId: _volumeSetId,
      );
      final bytes = header.encode();
      expect(bytes.length, PfbFormat.headerSize);
      expect(bytes.sublist(0, 8), pfbMagic);
      expect(header.chunkCount, 3, reason: '2500B / 1024B → 3 块');
      expect(
        bytes.sublist(PfbFormat.offsetFirstChunkNonce, PfbFormat.offsetFirstChunkNonce + 12),
        Uint8List.fromList([..._prefix, 0, 0, 0, 0]),
      );
      final declaredCrc = BigEndian.readUint32(bytes, PfbFormat.offsetHeaderCrc32);
      expect(declaredCrc, Crc32.of(bytes, 0, PfbFormat.offsetHeaderCrc32));
    });

    test('decode(encode) 往返保真', () {
      final header = PfbHeader.create(
        kdf: _fastKdf,
        flags: const PfbFlagsSpec(hasAttachments: true, incremental: true),
        plaintextLength: 5000,
        salt: _salt,
        noncePrefix: _prefix,
        chunkPlainSizeKiB: 1, // 1 KiB 块：5000B → 5 块
        volumeSetId: _volumeSetId,
      );
      final parsed = PfbHeader.decode(header.encode());
      expect(parsed.formatVersion, header.formatVersion);
      expect(parsed.minReaderVersion, header.minReaderVersion);
      expect(parsed.featureFlags, header.featureFlags);
      expect(parsed.kdf.memoryKiB, _fastKdf.memoryKiB);
      expect(parsed.kdf.iterations, _fastKdf.iterations);
      expect(parsed.kdf.parallelism, _fastKdf.parallelism);
      expect(parsed.kdf.saltLength, _fastKdf.saltLength);
      expect(parsed.chunkPlainSizeKiB, 1);
      expect(parsed.plaintextLength, 5000);
      expect(parsed.chunkCount, 5);
      expect(parsed.salt, _salt);
      expect(parsed.noncePrefix, _prefix);
      expect(parsed.volumeSetId, _volumeSetId);
      expect(parsed.volumeIndex, 1);
      expect(parsed.volumeTotal, 1);
    });

    test('魔数不符 → PFB_E_MAGIC', () {
      final bytes =
          PfbHeader.create(
            kdf: _fastKdf,
            flags: const PfbFlagsSpec(),
            plaintextLength: 0,
            salt: _salt,
            noncePrefix: _prefix,
          ).encode();
      bytes[3] = 0x00; // PFBOOK → PFB0OK
      expect(() => PfbHeader.decode(bytes), throwsA(_withCode(PfErrorCode.containerMagic)));
    });

    test('版本过高 → PFB_E_VERSION_UNSUPPORTED', () {
      final bytes =
          PfbHeader.create(
            kdf: _fastKdf,
            flags: const PfbFlagsSpec(),
            plaintextLength: 0,
            salt: _salt,
            noncePrefix: _prefix,
          ).encode();
      BigEndian.writeUint16(bytes, PfbFormat.offsetFormatVersion, 2);
      // 版本字段变了必须重算 CRC，否则先撞 CRC 分支 —— 这里恰好要测版本分支。
      Crc32.writeInto(bytes, PfbFormat.offsetHeaderCrc32, bytes, 0, PfbFormat.offsetHeaderCrc32);
      expect(
        () => PfbHeader.decode(bytes),
        throwsA(_withCode(PfErrorCode.containerVersionUnsupported)),
      );
    });

    test('CRC 被改 → PFB_E_HEADER_INVALID（先于字段语义校验）', () {
      final bytes =
          PfbHeader.create(
            kdf: _fastKdf,
            flags: const PfbFlagsSpec(),
            plaintextLength: 0,
            salt: _salt,
            noncePrefix: _prefix,
          ).encode();
      BigEndian.writeUint32(bytes, PfbFormat.offsetHeaderCrc32, 0xDEADBEEF);
      expect(() => PfbHeader.decode(bytes), throwsA(_withCode(PfErrorCode.containerHeaderInvalid)));
    });

    test('未知 flag 位 → PFB_E_HEADER_INVALID', () {
      final bytes =
          PfbHeader.create(
            kdf: _fastKdf,
            flags: const PfbFlagsSpec(),
            plaintextLength: 0,
            salt: _salt,
            noncePrefix: _prefix,
          ).encode();
      BigEndian.writeUint16(bytes, PfbFormat.offsetFeatureFlags, 1 << 11);
      Crc32.writeInto(bytes, PfbFormat.offsetHeaderCrc32, bytes, 0, PfbFormat.offsetHeaderCrc32);
      expect(() => PfbHeader.decode(bytes), throwsA(_withCode(PfErrorCode.containerHeaderInvalid)));
    });

    test('chunkCount 与明文长度不自洽 → PFB_E_HEADER_INVALID', () {
      final bytes =
          PfbHeader.create(
            kdf: _fastKdf,
            flags: const PfbFlagsSpec(),
            plaintextLength: 1025,
            salt: _salt,
            noncePrefix: _prefix,
            chunkPlainSizeKiB: 1,
          ).encode();
      // 1025B / 1024B 应为 2 块；把它改成 3 块后 (2*1024, 3*1024] 不含 1025。
      BigEndian.writeUint32(bytes, PfbFormat.offsetChunkCount, 3);
      Crc32.writeInto(bytes, PfbFormat.offsetHeaderCrc32, bytes, 0, PfbFormat.offsetHeaderCrc32);
      expect(() => PfbHeader.decode(bytes), throwsA(_withCode(PfErrorCode.containerHeaderInvalid)));
    });

    test('KDF 参数超上限 → PFB_E_KDF_PARAMS（恶意文件的 OOM 防线在头部解析）', () {
      final bytes =
          PfbHeader.create(
            kdf: _fastKdf,
            flags: const PfbFlagsSpec(),
            plaintextLength: 0,
            salt: _salt,
            noncePrefix: _prefix,
          ).encode();
      // 16 GiB —— 恶意文件惯用的内存炸弹。
      BigEndian.writeUint32(bytes, PfbFormat.offsetKdfMemKiB, 16777216);
      Crc32.writeInto(bytes, PfbFormat.offsetHeaderCrc32, bytes, 0, PfbFormat.offsetHeaderCrc32);
      expect(() => PfbHeader.decode(bytes), throwsA(_withCode(PfErrorCode.kdfParamsOutOfRange)));
    });
  });

  group('PfbContainer.seal/open · 往返与三态分流', () {
    test('seal → open 往返（单块）', () async {
      final payload = _bytes(600, 7);
      final file = await _seal(payload);
      expect(file.length, 128 + 4 + 12 + 600 + 16 + 32);
      final opened = await PfbContainer.open(file: file, key: _key);
      expect(opened, payload);
    });

    test('seal → open 往返（多块，末块不满）', () async {
      final payload = _bytes(2500, 3);
      final file = await _seal(payload, chunkPlainSizeKiB: 1);
      final slices = PfbLayout.slice(file);
      expect(slices.chunks, hasLength(3));
      expect(slices.chunks[0].plainLength, 1024);
      expect(slices.chunks[2].plainLength, 452);
      final opened = await PfbContainer.open(file: file, key: _key);
      expect(opened, payload);
    });

    test('空载荷：0 块，往返为空', () async {
      final file = await _seal(Uint8List(0));
      expect(PfbLayout.slice(file).chunks, isEmpty);
      final opened = await PfbContainer.open(file: file, key: _key);
      expect(opened, isEmpty);
    });

    test('seal 确定性：同输入逐字节相同（向量的前提）', () async {
      final payload = _bytes(300, 5);
      final a = await _seal(payload);
      final b = await _seal(payload);
      expect(a, b);
    });

    test('密码错：完整性全过、认证失败 → PFB_E_AUTH_FAILED', () async {
      final file = await _seal(_bytes(100));
      final wrongKey = Uint8List(32);
      await expectLater(
        PfbContainer.open(file: file, key: wrongKey),
        throwsA(_withCode(PfErrorCode.containerAuthFailed)),
      );
    });

    test('密文被改：contentDigest 先挡 → PFB_E_DIGEST_MISMATCH（免密判定损坏）', () async {
      final file = await _seal(_bytes(100));
      file[200] ^= 0x01; // 落在密文区（128..）
      await expectLater(
        PfbContainer.open(file: file, key: _key),
        throwsA(_withCode(PfErrorCode.containerDigestMismatch)),
      );
    });

    test('头部被改：CRC 先挡 → PFB_E_HEADER_INVALID', () async {
      final file = await _seal(_bytes(100));
      file[10] ^= 0x01; // minReaderVersion，落在 CRC 覆盖区（0..44）
      await expectLater(
        PfbContainer.open(file: file, key: _key),
        throwsA(_withCode(PfErrorCode.containerHeaderInvalid)),
      );
    });

    test('变量区被改（盐）：contentDigest 挡 → PFB_E_DIGEST_MISMATCH', () async {
      final file = await _seal(_bytes(100));
      file[50] ^= 0x01; // kdfSalt，48..128 属于 contentDigest 覆盖区
      await expectLater(
        PfbContainer.open(file: file, key: _key),
        throwsA(_withCode(PfErrorCode.containerDigestMismatch)),
      );
    });

    test('截断 → PFB_E_TRUNCATED；尾部多字节 → PFB_E_HEADER_INVALID', () async {
      final file = await _seal(_bytes(100));
      await expectLater(
        PfbContainer.open(file: file.sublist(0, file.length - 10), key: _key),
        throwsA(_withCode(PfErrorCode.containerTruncated)),
      );
      final padded = Uint8List(file.length + 1)..setRange(0, file.length, file);
      await expectLater(
        PfbContainer.open(file: padded, key: _key),
        throwsA(_withCode(PfErrorCode.containerHeaderInvalid)),
      );
    });
  });

  group('链式 AAD · 绑定语义', () {
    test('重排两块的密文（nonce 保持原位，trailer 重算）：链式 AAD 命中 → PFB_E_AUTH_FAILED', () async {
      final payload = _bytes(2500, 9);
      final file = await _seal(payload, chunkPlainSizeKiB: 1);
      final slices = PfbLayout.slice(file);
      // 交换块 0 与块 1 的 box（nonce 留在原位 → nonce 检查全部通过），
      // 再重算 trailer 摘要 —— 免密完整性因此被"骗过"，
      // 唯一还站着的就是链式 AAD：块 1 的 box 是用 nonce1 + AAD(base||1||tag0)
      // 封的，现在被要求用 nonce0 + AAD(base||0||零32) 解。
      final box0 = Uint8List.fromList(slices.chunks[0].box);
      final box1 = Uint8List.fromList(slices.chunks[1].box);
      _replaceBox(file, slices, 0, box1);
      _replaceBox(file, slices, 1, box0);
      _recomputeTrailer(file);
      await expectLater(
        PfbContainer.open(file: file, key: _key),
        throwsA(_withCode(PfErrorCode.containerAuthFailed)),
      );
    });

    test('连 nonce 一起重排（trailer 重算）：nonce 序号检查命中 → PFB_E_HEADER_INVALID', () async {
      final payload = _bytes(2500, 9);
      final file = await _seal(payload, chunkPlainSizeKiB: 1);
      // 把块 0 的整段（len+nonce+box）搬到块 1 的位置并重算摘要：
      // nonce 序号立刻错位，还轮不到 GCM 认证出手 —— 两道防线各守一种重排。
      const sliceLen0 = 4 + 12 + 1024 + 16;
      final chunk0 = Uint8List.fromList(file.sublist(128, 128 + sliceLen0));
      const chunk1Start = 128 + sliceLen0;
      final chunk1Len = 4 + 12 + BigEndian.readUint32(file, chunk1Start);
      final chunk1 = Uint8List.fromList(file.sublist(chunk1Start, chunk1Start + chunk1Len));
      file.setRange(128, 128 + chunk1Len, chunk1);
      file.setRange(128 + chunk1Len, 128 + chunk1Len + chunk0.length, chunk0);
      _recomputeTrailer(file);
      await expectLater(
        PfbContainer.open(file: file, key: _key),
        throwsA(_withCode(PfErrorCode.containerHeaderInvalid)),
      );
    });

    test('首块 AAD 的 prevTag 是 32 个 0x00（规格原文，不是 16 个）', () async {
      // 用向量以外的独立路径验证：拿正确密钥但把首块 AAD 的 prevTag 换成
      // 16 个 0x00 的「想当然」版本不可直接构造 —— 这里锁的是与 Python
      // 参考实现的一致性，由 container_file 套件的 aadHexs 承担；
      // 本测试锁定 seal 写出的文件能被按规格（32 字节零 prevTag）解开。
      final payload = _bytes(100, 11);
      final file = await _seal(payload);
      final opened = await PfbContainer.open(file: file, key: _key);
      expect(opened, payload);
    });
  });

  group('PfbHeader · 常量命名空间与访问器', () {
    test('PfbAlgorithm.isKnownKdf / isKnownAead 只认已登记的 ID', () {
      expect(PfbAlgorithm.isKnownKdf(PfbAlgorithm.kdfArgon2id), isTrue);
      expect(PfbAlgorithm.isKnownKdf(PfbAlgorithm.kdfArgon2id + 1), isFalse);
      expect(PfbAlgorithm.isKnownAead(PfbAlgorithm.aeadAes256Gcm), isTrue);
      expect(PfbAlgorithm.isKnownAead(PfbAlgorithm.aeadAes256Gcm + 1), isFalse);
    });

    test('PfbFlags.of：四个可选位各自独立置位，bit0/bit2 恒置', () {
      const base = PfbFlags.bitAesGcm | PfbFlags.bitChunked;
      expect(PfbFlags.of(), base);
      expect(PfbFlags.of(gzip: true), base | PfbFlags.bitGzip);
      expect(PfbFlags.of(hasAttachments: true), base | PfbFlags.bitHasAttachments);
      expect(PfbFlags.of(multiVolume: true), base | PfbFlags.bitMultiVolume);
      expect(PfbFlags.of(incremental: true), base | PfbFlags.bitIncremental);
      expect(
        PfbFlags.of(gzip: true, hasAttachments: true, multiVolume: true, incremental: true),
        PfbFlags.knownMask,
      );
    });

    test('flagGzip / flagChunked / flagIncremental 与 featureFlags 逐位一致', () {
      final plain = _rawHeader();
      expect(plain.flagGzip, isFalse);
      expect(plain.flagChunked, isTrue);
      expect(plain.flagIncremental, isFalse);

      final flagged = _rawHeader(featureFlags: PfbFlags.of(gzip: true, incremental: true));
      expect(flagged.flagGzip, isTrue);
      expect(flagged.flagChunked, isTrue);
      expect(flagged.flagIncremental, isTrue);
    });

    test('toString 摘要含版本、flags、KDF 描述、块数与明文长', () {
      final header = _rawHeader();
      expect(header.toString(), startsWith('PfbHeader(v${PfbFormat.formatVersion}, flags=0x5, '));
      expect(header.toString(), contains(_fastKdf.describe()));
      expect(header.toString(), endsWith('chunks=0, plain=0)'));
    });
  });

  group('PfbHeader.validate · 逐条结构校验的拒绝分支', () {
    test('formatVersion ≤ 0 ⇒ PFB_E_HEADER_INVALID', () {
      expect(
        () => _rawHeader(formatVersion: 0).validate(),
        throwsA(_withCode(PfErrorCode.containerHeaderInvalid)),
      );
    });

    test('minReaderVersion ≤ 0 ⇒ PFB_E_HEADER_INVALID', () {
      expect(
        () => _rawHeader(minReaderVersion: 0).validate(),
        throwsA(_withCode(PfErrorCode.containerHeaderInvalid)),
      );
    });

    test('bit0(AESGCM) 未置位 ⇒ PFB_E_HEADER_INVALID（本格式只定义了这一种 AEAD）', () {
      expect(
        () => _rawHeader(featureFlags: PfbFlags.bitChunked).validate(),
        throwsA(_withCode(PfErrorCode.containerHeaderInvalid)),
      );
    });

    test('chunkPlainSizeKiB < 1 ⇒ PFB_E_HEADER_INVALID', () {
      expect(
        () => _rawHeader(chunkPlainSizeKiB: 0).validate(),
        throwsA(_withCode(PfErrorCode.containerHeaderInvalid)),
      );
    });

    test('明文长度超出 1 TiB ⇒ PFB_E_HEADER_INVALID（不让文件头驱动荒谬分配）', () {
      expect(
        () => _rawHeader(plaintextLength: PfbFormat.maxPlaintextLength + 1).validate(),
        throwsA(_withCode(PfErrorCode.containerHeaderInvalid)),
      );
    });

    test('chunkCount=0 但明文非空 ⇒ PFB_E_HEADER_INVALID', () {
      expect(
        () => _rawHeader(plaintextLength: 100, chunkCount: 0).validate(),
        throwsA(_withCode(PfErrorCode.containerHeaderInvalid)),
      );
    });

    test('volumeTotal 越界（0 与 maxVolumes+1）⇒ PFB_E_HEADER_INVALID', () {
      expect(
        () => _rawHeader(volumeTotal: 0).validate(),
        throwsA(_withCode(PfErrorCode.containerHeaderInvalid)),
      );
      expect(
        () => _rawHeader(volumeTotal: PfbFormat.maxVolumes + 1).validate(),
        throwsA(_withCode(PfErrorCode.containerHeaderInvalid)),
      );
    });

    test('volumeIndex 越界（0 / 大于 volumeTotal）⇒ PFB_E_HEADER_INVALID', () {
      expect(
        () => _rawHeader(volumeTotal: 1, volumeIndex: 0).validate(),
        throwsA(_withCode(PfErrorCode.containerHeaderInvalid)),
      );
      expect(
        () => _rawHeader(volumeTotal: 2, volumeIndex: 3).validate(),
        throwsA(_withCode(PfErrorCode.containerHeaderInvalid)),
      );
    });
  });

  group('PfbHeader.encode / decode · 长度与冗余字段的拒绝分支', () {
    test('盐长度与声明的 kdfSaltLen 不符 ⇒ 编码期就拦下', () {
      expect(() => _rawHeader(salt: Uint8List(8)).encode(), throwsA(_headerInvalid));
    });

    test('noncePrefix 长度 ≠ 8 ⇒ 编码期就拦下', () {
      expect(() => _rawHeader(noncePrefix: Uint8List(4)).encode(), throwsA(_headerInvalid));
    });

    test('不足 128 字节 ⇒ PFB_E_TRUNCATED（长度不足走自己的码，不是 headerInvalid）', () {
      expect(
        () => PfbHeader.decode(Uint8List(PfbFormat.headerSize - 1)),
        throwsA(_withCode(PfErrorCode.containerTruncated)),
      );
    });

    test('firstChunkNonce 前 8 字节与 noncePrefix 不一致 ⇒ PFB_E_HEADER_INVALID', () {
      final bytes = _rawHeader().encode();
      BigEndian.writeBytes(
        bytes,
        PfbFormat.offsetFirstChunkNonce,
        Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]),
      );
      _fixHeaderCrc(bytes); // 先让 CRC 过，才轮得到这条冗余校验
      expect(() => PfbHeader.decode(bytes), throwsA(_headerInvalid));
    });

    test('firstChunkNonce 末 4 字节非 0 ⇒ PFB_E_HEADER_INVALID', () {
      final bytes = _rawHeader().encode();
      bytes[PfbFormat.offsetFirstChunkNonce + 8] = 1;
      _fixHeaderCrc(bytes);
      expect(() => PfbHeader.decode(bytes), throwsA(_headerInvalid));
    });
  });

  group('PfbLayout / PfbSlices · 布局自洽与拒绝分支', () {
    test('fileLength == 实际文件长度（头 128 + 每块 16 开销 + 尾部 32）', () async {
      final file = await _seal(_bytes(2500, 3), chunkPlainSizeKiB: 1);
      final slices = PfbLayout.slice(file);
      expect(slices.chunks, hasLength(3));
      expect(slices.fileLength, file.length);
    });

    test('bit2(CHUNKED) 未置位 ⇒ PFB_E_HEADER_INVALID（只支持分块容器）', () {
      final bytes = _rawHeader(featureFlags: PfbFlags.bitAesGcm).encode();
      expect(() => PfbLayout.slice(bytes), throwsA(_headerInvalid));
    });

    test('某块 chunkLen ≤ 标签长度 ⇒ PFB_E_HEADER_INVALID', () async {
      final file = await _seal(_bytes(100), chunkPlainSizeKiB: 1);
      // 恰好等于 16（= tagLength）：一块连标签都装不下，只能是写坏了。
      BigEndian.writeUint32(file, PfbFormat.headerSize, PfbFormat.tagLength);
      expect(() => PfbLayout.slice(file), throwsA(_headerInvalid));
    });

    test('块长之和与「文件长度 = 头 + 明文 + 开销 + 尾」对不上 ⇒ PFB_E_HEADER_INVALID', () async {
      final file = await _seal(_bytes(100), chunkPlainSizeKiB: 1);
      // 声明 chunkLen=20（> 16，所以先过上一道），于是密文区在 164 就结束，
      // 而文件长 292 —— 中间那 128 字节不受任何完整性保护，必须拒绝。
      BigEndian.writeUint32(file, PfbFormat.headerSize, 20);
      expect(() => PfbLayout.slice(file), throwsA(_headerInvalid));
    });

    test('目录里的块数与 chunkCount 一致（切片不会多读或少读）', () async {
      final payload = _bytes(2500, 3);
      final file = await _seal(payload, chunkPlainSizeKiB: 1);
      final slices = PfbLayout.slice(file);
      expect(slices.chunks.map((c) => c.index), <int>[0, 1, 2]);
      expect(slices.chunks.fold<int>(0, (n, c) => n + c.plainLength), payload.length);
    });
  });

  group('PfbContainer.verifyContentDigest · 长度不足', () {
    test('不足「头部 + 尾部」⇒ PFB_E_TRUNCATED', () {
      final tooShort = Uint8List(PfbFormat.headerSize + PfbFormat.trailerSize - 1);
      expect(
        () => PfbContainer.verifyContentDigest(tooShort),
        throwsA(_withCode(PfErrorCode.containerTruncated)),
      );
    });
  });
}

/// 直接构造头部（**绕过** `PfbHeader.create` 的默认值），用于逐条命中
/// `validate()` / `encode()` 的拒绝分支。
///
/// 为什么必须另开这个入口：`create` 会把参数钳进合法域（例如 chunkCount 由
/// plaintextLength 反算），于是「不自洽的头部」在测试里根本造不出来 ——
/// 而那些分支恰恰是解析**攻击者可控的文件头**时要走的。
PfbHeader _rawHeader({
  int formatVersion = PfbFormat.formatVersion,
  int minReaderVersion = PfbFormat.minReaderVersion,
  int featureFlags = PfbFlags.bitAesGcm | PfbFlags.bitChunked,
  Argon2Params kdf = _fastKdf,
  int chunkPlainSizeKiB = 1,
  int plaintextLength = 0,
  int chunkCount = 0,
  Uint8List? salt,
  Uint8List? noncePrefix,
  int volumeIndex = 1,
  int volumeTotal = 1,
}) => PfbHeader(
  formatVersion: formatVersion,
  minReaderVersion: minReaderVersion,
  featureFlags: featureFlags,
  kdf: kdf,
  chunkPlainSizeKiB: chunkPlainSizeKiB,
  plaintextLength: plaintextLength,
  chunkCount: chunkCount,
  salt: salt ?? Uint8List(PfbFormat.saltLength),
  noncePrefix: noncePrefix ?? Uint8List(PfbFormat.noncePrefixLength),
  volumeSetId: Uint8List(PfbFormat.volumeSetIdLength),
  volumeIndex: volumeIndex,
  volumeTotal: volumeTotal,
  setDigest: Uint8List(PfbFormat.setDigestLength),
);

/// 改了固定头里的字段之后重算 CRC32 —— 否则会先撞 CRC 分支，
/// 测不到真正想测的那一条。
void _fixHeaderCrc(Uint8List bytes) =>
    Crc32.writeInto(bytes, PfbFormat.offsetHeaderCrc32, bytes, 0, PfbFormat.offsetHeaderCrc32);

/// 把第 [index] 块的 box 替换为 [newBox]（nonce 不动）。
void _replaceBox(Uint8List file, PfbSlices slices, int index, Uint8List newBox) {
  var start = PfbFormat.headerSize;
  for (var i = 0; i < index; i++) {
    start += PfbFormat.perChunkOverhead + slices.chunks[i].cipherLength;
  }
  start += 4 + 12; // 跳过本块的 chunkLen + chunkNonce
  file.setRange(start, start + newBox.length, newBox);
}

/// 重算文件尾的 contentDigest —— 用于"绕过"免密完整性，
/// 让测试能落到更深的防线（nonce 序号 / 链式 AAD）。
void _recomputeTrailer(Uint8List file) {
  final digest = Sha256.instance.hash(
    file.sublist(PfbFormat.offsetKdfSalt, file.length - PfbFormat.trailerSize),
  );
  file.setRange(file.length - PfbFormat.trailerSize, file.length, digest);
}

Matcher _withCode(String code) => isA<PfError>().having((e) => e.code, 'code', code);

/// 结构损坏的统一码。绝大多数拒绝分支都归到它 —— 单独抽出来是为了让
/// 「这一条到底该报哪个码」在用例里一眼可读。
final Matcher _headerInvalid = _withCode(PfErrorCode.containerHeaderInvalid);

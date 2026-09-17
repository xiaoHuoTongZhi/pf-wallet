/// M1 驱动：PFB 分块容器（规格 §3.3，2026-09-17 裁决的唯一 v1 格式）。
///
/// 这一组向量把**发布格式**钉死：魔数 / 头部 128 字节布局 / CRC / 分块结构 /
/// 链式 AAD / contentDigest。格式一旦发布就改不动了 —— 用户已经导出的备份
/// 必须能被将来任何版本打开。期望值全部由 `tools/golden_vectors_gen/container_pfb.py`
/// （Python `cryptography` + `argon2-cffi` + 手工打包）独立生成，
/// 本文件只是把输入喂给 Dart 实现并逐字段比对。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';

import '../driver.dart';
import '../json_util.dart';
import '../outcome.dart';

Map<String, Object?> _kdfFrom(Map<String, Object?> input, String kind) =>
    requireMap(input, 'kdf', kind);

Argon2Params _kdf(Map<String, Object?> input, String kind) {
  final row = _kdfFrom(input, kind);
  return Argon2Params(
    memoryKiB: requireInt(row, 'm', '$kind.kdf.m'),
    iterations: requireInt(row, 't', '$kind.kdf.t'),
    parallelism: requireInt(row, 'p', '$kind.kdf.p'),
    saltLength: requireInt(row, 'saltLength', '$kind.kdf.saltLength'),
    outputLength: requireInt(row, 'outputLength', '$kind.kdf.outputLength'),
  );
}

PfbFlagsSpec _flags(Map<String, Object?> input, String kind) => PfbFlagsSpec(
  gzip: optionalBool(input, 'flagGzip', false),
  hasAttachments: optionalBool(input, 'flagHasAttachments', false),
  multiVolume: optionalBool(input, 'flagMultiVolume', false),
  incremental: optionalBool(input, 'flagIncremental', false),
);

/// 序列化 128 字节头部（固定头 + 变量区 + CRC32）。
final class ContainerHeaderEncodeDriver extends VectorDriver {
  const ContainerHeaderEncodeDriver();

  @override
  String get kind => 'container.header.encode';

  @override
  String get description => '按 §3.3 序列化 128 字节文件头（含 CRC32 与变量区）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'kdf': '{m, t, p, saltLength, outputLength}',
    'featureFlags': 'int，位定义见 §3.3',
    'minReaderVersion': 'int',
    'chunkPlainSizeKiB': 'int，块明文大小（KiB）',
    'plaintextLength': 'int',
    'chunkCount': 'int',
    'saltHex': '32 个十六进制字符',
    'noncePrefixHex': '16 个十六进制字符',
    'volumeSetIdHex': '16 个十六进制字符',
    'volumeIndex': 'int',
    'volumeTotal': 'int',
    'setDigestHex': '64 个十六进制字符',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final header = PfbHeader(
      formatVersion: PfbFormat.formatVersion,
      minReaderVersion: requireInt(input, 'minReaderVersion', kind),
      featureFlags: requireInt(input, 'featureFlags', kind),
      kdf: _kdf(input, kind),
      chunkPlainSizeKiB: requireInt(input, 'chunkPlainSizeKiB', kind),
      plaintextLength: requireInt(input, 'plaintextLength', kind),
      chunkCount: requireInt(input, 'chunkCount', kind),
      salt: requireHexBytes(input, 'saltHex', kind),
      noncePrefix: requireHexBytes(input, 'noncePrefixHex', kind),
      volumeSetId: requireHexBytes(input, 'volumeSetIdHex', kind),
      volumeIndex: requireInt(input, 'volumeIndex', kind),
      volumeTotal: requireInt(input, 'volumeTotal', kind),
      setDigest: requireHexBytes(input, 'setDigestHex', kind),
    );
    final bytes = header.encode();
    return VectorOutcome.value(<String, Object?>{
      'hex': toHex(bytes),
      'lengthBytes': bytes.length,
      'crc32Hex': Crc32.ofHex(bytes, 0, PfbFormat.offsetHeaderCrc32),
      'headerSha256Hex': Sha256.instance.hashHex(bytes),
      'formatVersion': header.formatVersion,
      'kdfDescription': header.kdf.describe(),
    });
  }
}

/// 解析 128 字节头部。
final class ContainerHeaderDecodeDriver extends VectorDriver {
  const ContainerHeaderDecodeDriver();

  @override
  String get kind => 'container.header.decode';

  @override
  String get description => '解析 128 字节文件头：CRC → 版本 → flags → 字段语义';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'hex': '文件头十六进制（恰好 256 个字符 = 128 字节）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final bytes = requireHexBytes(input, 'hex', kind);
    final header = PfbHeader.decode(bytes);
    return VectorOutcome.value(<String, Object?>{
      'formatVersion': header.formatVersion,
      'minReaderVersion': header.minReaderVersion,
      'featureFlags': header.featureFlags,
      'kdfId': PfbAlgorithm.kdfArgon2id,
      'kdfMemoryKiB': header.kdf.memoryKiB,
      'kdfIterations': header.kdf.iterations,
      'kdfParallelism': header.kdf.parallelism,
      'kdfSaltLen': header.kdf.saltLength,
      'noncePrefixLen': header.noncePrefix.length,
      'chunkPlainSizeKiB': header.chunkPlainSizeKiB,
      'plaintextLength': header.plaintextLength,
      'chunkCount': header.chunkCount,
      'saltHex': toHex(header.salt),
      'noncePrefixHex': toHex(header.noncePrefix),
      'volumeSetIdHex': toHex(header.volumeSetId),
      'volumeIndex': header.volumeIndex,
      'volumeTotal': header.volumeTotal,
      'setDigestHex': toHex(header.setDigest),
    });
  }
}

/// 切分完整容器文件。
final class ContainerLayoutSliceDriver extends VectorDriver {
  const ContainerLayoutSliceDriver();

  @override
  String get kind => 'container.layout.slice';

  @override
  String get description => '按 §3.3 切分文件并核对长度/nonce 序号/块结构';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{'hex': '完整 .pfb 文件十六进制'};

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final file = requireHexBytes(input, 'hex', kind);
    final slices = PfbLayout.slice(file);
    return VectorOutcome.value(<String, Object?>{
      'fileLength': file.length,
      'chunkCount': slices.chunks.length,
      'saltHex': toHex(slices.header.salt),
      'noncePrefixHex': toHex(slices.header.noncePrefix),
      'firstChunkNonceHex': toHex(slices.chunks.isEmpty ? Uint8List(0) : slices.chunks.first.nonce),
      'volumeSetIdHex': toHex(slices.header.volumeSetId),
      'volumeIndex': slices.header.volumeIndex,
      'volumeTotal': slices.header.volumeTotal,
      'setDigestHex': toHex(slices.header.setDigest),
      'contentDigestHex': toHex(slices.contentDigest),
      'chunkPlainLengths': <Object?>[for (final c in slices.chunks) c.plainLength],
      'chunkNonceHexs': <Object?>[for (final c in slices.chunks) toHex(c.nonce)],
      // 逐段指纹：证明「正确的字节落进了正确的区段」—— 区段整体错位时
      // 长度依然正确，只有内容指纹能抓到。
      'saltSha256': Sha256.instance.hashHex(slices.header.salt),
      'chunkBoxesSha256': <Object?>[for (final c in slices.chunks) Sha256.instance.hashHex(c.box)],
    });
  }
}

/// 内容摘要（文件尾 32 字节）核对。
final class ContainerDigestVerifyDriver extends VectorDriver {
  const ContainerDigestVerifyDriver();

  @override
  String get kind => 'container.digest.verify';

  @override
  String get description => '用文件尾 contentDigest 免密核对完整性（覆盖 [48..长度-32]）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{'hex': '完整 .pfb 文件十六进制'};

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final file = requireHexBytes(input, 'hex', kind);
    // 走 pf_crypto 的实现，而不是在本文件里再算一次摘要。
    // 这是 README 第三条红线（**加密只有一份实现**）的落地。
    final verdict = PfbContainer.verifyContentDigest(file);
    return VectorOutcome.value(<String, Object?>{
      'matches': verdict.matches,
      'computedDigestHex': verdict.computedHex,
      'declaredDigestHex': verdict.declaredHex,
    });
  }
}

/// 完整文件的封包（KDF + 分块 + 链式 AAD + 摘要，全部链路）。
final class ContainerFileSealDriver extends VectorDriver {
  const ContainerFileSealDriver();

  @override
  String get kind => 'container.file.seal';

  @override
  String get description => '固定随机源下封出完整 .pfb：期望值由 Python 独立实现计算';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'password': '导出密码（UTF-8）',
    'kdf': '{m, t, p, saltLength, outputLength}',
    'saltHex': 'KDF 盐',
    'noncePrefixHex': '分块 nonce 前缀',
    'payloadHex': '压缩后明文',
    'featureFlags': 'int',
    'chunkPlainSizeKiB': 'int',
    'volumeSetIdHex': '16 个十六进制字符',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final kdf = _kdf(input, kind);
    final salt = requireHexBytes(input, 'saltHex', kind);
    final noncePrefix = requireHexBytes(input, 'noncePrefixHex', kind);
    final payload = requireHexBytes(input, 'payloadHex', kind);
    final password = Uint8List.fromList(utf8.encode(requireString(input, 'password', kind)));
    final key = await Argon2idDeriver.instance.derive(password: password, salt: salt, params: kdf);

    final file = await PfbContainer.seal(
      payload: payload,
      key: key,
      salt: salt,
      noncePrefix: noncePrefix,
      kdf: kdf,
      flags: _flags(input, kind),
      chunkPlainSizeKiB: requireInt(input, 'chunkPlainSizeKiB', kind),
      volumeSetId: requireHexBytes(input, 'volumeSetIdHex', kind),
    );
    final slices = PfbLayout.slice(file);
    final aadBase = Sha256.instance.hash(Uint8List.sublistView(file, 0, PfbFormat.headerSize));
    // 逐块 AAD 快照：把链式 AAD 的「SHA256(头) || u32BE(idx) || prevTag」
    // 逐字节锁死 —— 首块 prevTag 是 32 个 0x00（规格原文），其后是上一块 tag。
    final aadHexs = <Object?>[];
    var prevTag = Uint8List(32);
    for (final chunk in slices.chunks) {
      final aad =
          BytesBuilder()
            ..add(aadBase)
            ..add(Uint8List(4)..buffer.asByteData().setUint32(0, chunk.index, Endian.big))
            ..add(prevTag);
      aadHexs.add(toHex(aad.toBytes()));
      prevTag = Uint8List.sublistView(chunk.box, chunk.plainLength);
    }
    return VectorOutcome.value(<String, Object?>{
      'fileHex': toHex(file),
      'fileSha256': Sha256.instance.hashHex(file),
      'contentDigestHex': toHex(slices.contentDigest),
      'chunkCount': slices.chunks.length,
      'plaintextLength': slices.header.plaintextLength,
      'aadHexs': aadHexs,
    });
  }
}

/// 完整文件的解包与三态错误分流。
final class ContainerFileOpenDriver extends VectorDriver {
  const ContainerFileOpenDriver();

  @override
  String get kind => 'container.file.open';

  @override
  String get description => '按分流顺序解包：CRC → contentDigest（免密）→ GCM 认证';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'fileHex': '完整 .pfb 文件十六进制',
    'password': '导出密码（UTF-8）',
    'kdf': '{m, t, p, saltLength, outputLength}',
    'saltHex': 'KDF 盐',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final file = requireHexBytes(input, 'fileHex', kind);
    final kdf = _kdf(input, kind);
    final salt = requireHexBytes(input, 'saltHex', kind);
    final password = Uint8List.fromList(utf8.encode(requireString(input, 'password', kind)));
    final key = await Argon2idDeriver.instance.derive(password: password, salt: salt, params: kdf);
    final payload = await PfbContainer.open(file: file, key: key);
    return VectorOutcome.value(<String, Object?>{
      'payloadHex': toHex(payload),
      'payloadLength': payload.length,
    });
  }
}

/// 格式常量：这些数字一旦发布就不可更改。
final class ContainerFormatConstantsDriver extends VectorDriver {
  const ContainerFormatConstantsDriver();

  @override
  String get kind => 'container.format.constants';

  @override
  String get description => '锁定 §3.3 容器格式的魔数、偏移、长度与上限等全部常量';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{};

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async =>
      VectorOutcome.value(<String, Object?>{
        'magicHex': toHex(pfbMagic),
        'headerSize': PfbFormat.headerSize,
        'fixedHeaderSize': PfbFormat.fixedHeaderSize,
        'trailerSize': PfbFormat.trailerSize,
        'payloadOffset': PfbFormat.headerSize,
        'formatVersion': PfbFormat.formatVersion,
        'minReaderVersion': PfbFormat.minReaderVersion,
        'saltLength': PfbFormat.saltLength,
        'noncePrefixLength': PfbFormat.noncePrefixLength,
        'nonceLength': PfbFormat.nonceLength,
        'tagLength': PfbFormat.tagLength,
        'volumeSetIdLength': PfbFormat.volumeSetIdLength,
        'setDigestLength': PfbFormat.setDigestLength,
        'trailerDigestLength': PfbFormat.trailerDigestLength,
        'defaultChunkPlainSizeKiB': PfbFormat.defaultChunkPlainSizeKiB,
        'maxVolumes': PfbFormat.maxVolumes,
        'maxPlaintextLength': PfbFormat.maxPlaintextLength,
        'bitAesGcm': PfbFlags.bitAesGcm,
        'bitGzip': PfbFlags.bitGzip,
        'bitChunked': PfbFlags.bitChunked,
        'bitHasAttachments': PfbFlags.bitHasAttachments,
        'bitMultiVolume': PfbFlags.bitMultiVolume,
        'bitIncremental': PfbFlags.bitIncremental,
        'knownFlagsMask': PfbFlags.knownMask,
        'kdfArgon2id': PfbAlgorithm.kdfArgon2id,
        'aeadAes256Gcm': PfbAlgorithm.aeadAes256Gcm,
      });
}

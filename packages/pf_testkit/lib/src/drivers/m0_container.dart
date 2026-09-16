/// M0 驱动：PFB 容器的字节级格式。
///
/// 这一组向量的价值在于**把格式钉死**。
/// 格式一旦发布就改不动了 —— 用户已经导出的备份文件必须能被将来任何版本打开。
/// 因此这些向量是「不可逆决策」的书面记录：任何改动都会让门禁变红，
/// 迫使改动者先想清楚「旧文件怎么办」。
library;

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';

import '../driver.dart';
import '../json_util.dart';
import '../outcome.dart';

/// 序列化文件头。
final class ContainerHeaderEncodeDriver extends VectorDriver {
  const ContainerHeaderEncodeDriver();

  @override
  String get kind => 'container.header.encode';

  @override
  String get description => '按给定 KDF 参数与元数据序列化为固定 76 字节文件头';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'params': 'KDF 参数对象 {m, t, p, saltLength, outputLength}',
    'plaintextLength': 'int，明文载荷长度（密文长度与之相等）',
    'exportedAtMilliseconds': 'int，UTC 毫秒导出时刻',
    'deviceIdHex': '32 个十六进制字符（16 字节设备 ID）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final params = Argon2Params.fromJson(requireMap(input, 'params', kind));
    final header = PfbHeader.create(
      params: params,
      plaintextLength: requireInt(input, 'plaintextLength', kind),
      exportedAtMilliseconds: requireInt(input, 'exportedAtMilliseconds', kind),
      deviceId: requireHexBytes(input, 'deviceIdHex', kind),
    );
    final bytes = header.encode();
    return VectorOutcome.value(<String, Object?>{
      'hex': toHex(bytes),
      'lengthBytes': bytes.length,
      'majorVersion': header.majorVersion,
      'minorVersion': header.minorVersion,
      'kdfDescription': header.kdfParams.describe(),
    });
  }
}

/// 解析文件头。
final class ContainerHeaderDecodeDriver extends VectorDriver {
  const ContainerHeaderDecodeDriver();

  @override
  String get kind => 'container.header.decode';

  @override
  String get description => '解析 76 字节文件头并做结构自洽校验';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'hex': '文件头十六进制（恰好 152 个字符 = 76 字节）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final bytes = requireHexBytes(input, 'hex', kind);
    final header = PfbHeader.decode(bytes);
    return VectorOutcome.value(<String, Object?>{
      'majorVersion': header.majorVersion,
      'minorVersion': header.minorVersion,
      'kdfAlgorithm': header.kdfAlgorithm,
      'aeadAlgorithm': header.aeadAlgorithm,
      'kdfMemoryKiB': header.kdfMemoryKiB,
      'kdfIterations': header.kdfIterations,
      'kdfParallelism': header.kdfParallelism,
      'saltLength': header.saltLength,
      'nonceLength': header.nonceLength,
      'tagLength': header.tagLength,
      'plaintextLength': header.plaintextLength,
      'exportedAtMilliseconds': header.exportedAtMilliseconds,
      'deviceIdHex': toHex(header.deviceId),
      'kdfDescription': header.kdfParams.describe(),
    });
  }
}

/// 解析文件尾。
final class ContainerTrailerDecodeDriver extends VectorDriver {
  const ContainerTrailerDecodeDriver();

  @override
  String get kind => 'container.trailer.decode';

  @override
  String get description => '解析固定 40 字节文件尾（摘要算法 + 密文 SHA-256 + 尾部魔数）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'hex': '文件尾十六进制（恰好 80 个字符 = 40 字节）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final bytes = requireHexBytes(input, 'hex', kind);
    final trailer = PfbTrailer.decode(bytes);
    return VectorOutcome.value(<String, Object?>{
      'digestAlgorithm': trailer.digestAlgorithm,
      'digestHex': toHex(trailer.digest),
      'lengthBytes': PfbFormat.trailerSize,
    });
  }
}

/// 校验文件尾摘要是否与密文相符。
///
/// 这是「密码错」与「文件损坏」能被区分的全部依据，
/// 因此必须有一条向量专门锁住它 —— 否则某天有人把摘要改成对明文计算，
/// 加密层不会有任何测试报错，而泄漏已经发生。
final class ContainerDigestVerifyDriver extends VectorDriver {
  const ContainerDigestVerifyDriver();

  @override
  String get kind => 'container.digest.verify';

  @override
  String get description => '用文件尾的 SHA-256 校验密文段完整性（免密码判断是否损坏）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'trailerHex': '文件尾十六进制（40 字节）',
    'ciphertextHex': '密文段十六进制',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final trailer = PfbTrailer.decode(
      parseHex(requireString(input, 'trailerHex', kind), '$kind.trailerHex'),
    );
    final ciphertext = requireHexBytes(input, 'ciphertextHex', kind);
    // 走 pf_crypto 的实现，而不是在本文件里再算一次摘要。
    // 这是 README 第三条红线（**加密只有一份实现**）的落地：
    // 驱动里若各有一份 sha256，那么「换摘要算法」就会有一处漏改，
    // 而漏改的后果是所有备份被静默判成损坏。
    final verdict = PfbDigest.verify(trailer: trailer, ciphertext: ciphertext);
    return VectorOutcome.value(<String, Object?>{
      'matches': verdict.matches,
      'computedDigestHex': verdict.computedHex,
      'declaredDigestHex': verdict.declaredHex,
    });
  }
}

/// 切分完整容器文件。
final class ContainerLayoutSliceDriver extends VectorDriver {
  const ContainerLayoutSliceDriver();

  @override
  String get kind => 'container.layout.slice';

  @override
  String get description => '按文件头声明切分文件，并校验文件长度恰好等于声明长度';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{'hex': '完整 .pfb 文件十六进制'};

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final file = requireHexBytes(input, 'hex', kind);
    final slices = PfbLayout.slice(file);
    return VectorOutcome.value(<String, Object?>{
      'fileLength': file.length,
      'declaredTotalLength': PfbFormat.exactFileLength(slices.header),
      'headerSize': PfbFormat.headerSize,
      'saltLength': slices.salt.length,
      'nonceLength': slices.nonce.length,
      'ciphertextLength': slices.ciphertext.length,
      'tagLength': slices.tag.length,
      'trailerSize': PfbFormat.trailerSize,
      'declaredPlaintextLength': slices.header.plaintextLength,
      // 逐段指纹：证明「正确的字节落进了正确的区段」。
      // 只比对长度是不够的 —— 区段整体错位一位时长度依然正确。
      'saltSha256': _sha256Hex(slices.salt),
      'nonceSha256': _sha256Hex(slices.nonce),
      'ciphertextSha256': _sha256Hex(slices.ciphertext),
      'tagSha256': _sha256Hex(slices.tag),
      'trailerDigestHex': toHex(slices.trailer.digest),
    });
  }
}

/// 格式常量：这些数字一旦发布就不可更改。
final class ContainerFormatConstantsDriver extends VectorDriver {
  const ContainerFormatConstantsDriver();

  @override
  String get kind => 'container.format.constants';

  @override
  String get description => '锁定容器格式的魔数、偏移、长度与上限等全部常量';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{};

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async =>
      VectorOutcome.value(<String, Object?>{
        'magicHex': toHex(pfbMagic),
        'trailerMagicHex': toHex(pfbTrailerMagic),
        'headerSize': PfbFormat.headerSize,
        'trailerSize': PfbFormat.trailerSize,
        'deviceIdLength': PfbFormat.deviceIdLength,
        'reservedLength': PfbFormat.reservedLength,
        'expectedNonceLength': PfbFormat.expectedNonceLength,
        'expectedTagLength': PfbFormat.expectedTagLength,
        'majorVersion': PfbFormat.majorVersion,
        'minorVersion': PfbFormat.minorVersion,
        'maxPlaintextLength': PfbFormat.maxPlaintextLength,
        'kdfArgon2id': PfbAlgorithm.kdfArgon2id,
        'aeadAes256Gcm': PfbAlgorithm.aeadAes256Gcm,
        'digestSha256': PfbAlgorithm.digestSha256,
        'offsetMagic': PfbFormat.offsetMagic,
        'offsetMajorVersion': PfbFormat.offsetMajorVersion,
        'offsetMinorVersion': PfbFormat.offsetMinorVersion,
        'offsetKdfAlgorithm': PfbFormat.offsetKdfAlgorithm,
        'offsetAeadAlgorithm': PfbFormat.offsetAeadAlgorithm,
        'offsetKdfMemoryKiB': PfbFormat.offsetKdfMemoryKiB,
        'offsetKdfIterations': PfbFormat.offsetKdfIterations,
        'offsetKdfParallelism': PfbFormat.offsetKdfParallelism,
        'offsetSaltLength': PfbFormat.offsetSaltLength,
        'offsetNonceLength': PfbFormat.offsetNonceLength,
        'offsetTagLength': PfbFormat.offsetTagLength,
        'offsetPlaintextLength': PfbFormat.offsetPlaintextLength,
        'offsetExportedAt': PfbFormat.offsetExportedAt,
        'offsetDeviceId': PfbFormat.offsetDeviceId,
        'offsetReserved': PfbFormat.offsetReserved,
        'offsetTrailerDigestAlgorithm': PfbFormat.offsetTrailerDigestAlgorithm,
        'offsetTrailerReserved': PfbFormat.offsetTrailerReserved,
        'offsetTrailerDigest': PfbFormat.offsetTrailerDigest,
        'offsetTrailerMagic': PfbFormat.offsetTrailerMagic,
        'trailerDigestLength': PfbFormat.trailerDigestLength,
      });
}

String _sha256Hex(List<int> bytes) => Sha256.instance.hashHex(bytes);

/// PFB 加密容器的二进制格式。
///
/// ## 完整字节布局
///
/// ```
/// ┌──────────────────────────────── 文件头 76 字节（固定，明文）─────────────────────────────┐
/// │ 偏移  长度  字段                         说明                                          │
/// │  0     4   魔数 "PFB1"                    0x50 0x46 0x42 0x31                          │
/// │  4     2   格式主版本 u16 BE              不兼容变更时 +1；读方遇到更高主版本必须拒绝     │
/// │  6     2   格式次版本 u16 BE              只允许新增算法 ID / 启用保留位，不得新增区段    │
/// │  8     2   KDF 算法 ID u16 BE             1 = Argon2id                                   │
/// │ 10     2   AEAD 算法 ID u16 BE            1 = AES-256-GCM                                │
/// │ 12     4   KDF 内存 m (KiB) u32 BE        写入实际使用值，不写"默认值"                    │
/// │ 16     4   KDF 迭代 t u32 BE                                                            │
/// │ 20     2   KDF 并行 p u16 BE                                                            │
/// │ 22     2   盐长度 u16 BE                                                                │
/// │ 24     2   nonce 长度 u16 BE              固定 12                                       │
/// │ 26     2   认证标签长度 u16 BE            固定 16                                       │
/// │ 28     8   明文载荷长度 u64 BE            密文长度与之相等（GCM 不改变长度）              │
/// │ 36     8   导出时刻 u64 BE（UTC 毫秒）                                                  │
/// │ 44    16   设备 ID（UUID v4 原始字节）    用于冲突提示"来自哪台设备"                      │
/// │ 60    16   保留位                         必须全 0；非 0 即视为格式错误                  │
/// └────────────────────────────────────────────────────────────────────────────────────────┘
/// ┌──────────────────────────────── 变长区段 ─────────────────────────────────────────────┐
/// │ 紧随文件头：盐 → nonce → 密文 → 认证标签（顺序固定，长度由文件头声明）                    │
/// └────────────────────────────────────────────────────────────────────────────────────────┘
/// ┌──────────────────────────────── 文件尾 40 字节（固定，明文）────────────────────────────┐
/// │ 偏移  长度  字段                         说明                                          │
/// │  0     2   摘要算法 ID u16 BE             1 = SHA-256                                   │
/// │  2     2   保留                           必须为 0                                      │
/// │  4    32   对**密文段**计算的 SHA-256      用于免密判断文件是否损坏                       │
/// │ 36     4   尾部魔数 "PFBF"                0x50 0x46 0x42 0x46                           │
/// └────────────────────────────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## 为什么文件头是明文
///
/// KDF 参数与盐必须能被读取方拿到 —— 否则「用文件自己的参数派生密钥」这件事
/// 根本无法开始。所以它们不可能是密文。
///
/// 代价是：任何拿到文件的人都知道「这是 PF Wallet 的备份、用 Argon2id、
/// 参数是 m=64MiB t=3 p=1」。这不是泄漏，这是解密所必需的公开参数。
/// **真正保护数据的是密码熵与 KDF 的代价**，不是参数保密。
/// 如果这里含糊其辞，反而会让人误以为「参数隐藏」提供了额外安全。
///
/// 文件头另外还暴露了导出时刻与设备 ID —— 这两个字段是明文的，
/// 用户应当知道这一点（产品上需要在导出页明确提示）。
/// 若将来需要隐藏它们，做法是把它们移入密文载荷，而不是在这里加密。
///
/// ## 「密码错」与「文件损坏」为什么能区分
///
/// 文件尾的 SHA-256 是**对密文段**计算的，对象是密文而不是明文，
/// 因此它不泄漏任何明文信息（密文本来就是公开的）。
/// 但它让读取方能在**没有密码的情况下**先做一次完整性判断：
///
///   摘要不符            → 文件损坏（PFB_E_DIGEST_MISMATCH）
///   摘要相符 + 认证失败 → 密码错   （PFB_E_AUTH_FAILED）
///   主版本过高          → 版本不兼容（PFB_E_VERSION_UNSUPPORTED）
///
/// 没有这一层，AES-GCM 的认证失败在密码学上就无法区分这两种原因。
///
/// ## 原子写
///
/// M2 实现写文件时必须先写 `xxx.pfb.tmp`、fsync、再 rename。
/// 直接写目标文件会让「导出过程中断电」留下一个半截文件，
/// 而用户会以为那是一份有效备份。
library;

import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';

import 'argon2_params.dart';
import 'byte_order.dart';

/// 文件头魔数：ASCII `PFB1`。
const List<int> pfbMagic = <int>[0x50, 0x46, 0x42, 0x31];

/// 文件尾魔数：ASCII `PFBF`。
const List<int> pfbTrailerMagic = <int>[0x50, 0x46, 0x42, 0x46];

/// 算法数值 ID。
///
/// 这些数字一旦发布即为契约：新增算法只能追加新 ID，不得复用旧 ID。
abstract final class PfbAlgorithm {
  /// KDF：Argon2id。
  static const int kdfArgon2id = 1;

  /// AEAD：AES-256-GCM。
  static const int aeadAes256Gcm = 1;

  /// 摘要：SHA-256。
  static const int digestSha256 = 1;

  static bool isKnownKdf(int id) => id == kdfArgon2id;

  static bool isKnownAead(int id) => id == aeadAes256Gcm;

  static bool isKnownDigest(int id) => id == digestSha256;
}

/// 格式常量：偏移与长度。
abstract final class PfbFormat {
  /// 本实现支持的格式主版本。
  static const int majorVersion = PfBuildInfo.containerFormatVersion;

  /// 本实现写出的格式次版本。
  static const int minorVersion = PfBuildInfo.containerFormatMinorVersion;

  // ---- 文件头 ----
  static const int offsetMagic = 0;
  static const int offsetMajorVersion = 4;
  static const int offsetMinorVersion = 6;
  static const int offsetKdfAlgorithm = 8;
  static const int offsetAeadAlgorithm = 10;
  static const int offsetKdfMemoryKiB = 12;
  static const int offsetKdfIterations = 16;
  static const int offsetKdfParallelism = 20;
  static const int offsetSaltLength = 22;
  static const int offsetNonceLength = 24;
  static const int offsetTagLength = 26;
  static const int offsetPlaintextLength = 28;
  static const int offsetExportedAt = 36;
  static const int offsetDeviceId = 44;
  static const int offsetReserved = 60;
  static const int reservedLength = 16;
  static const int headerSize = 76;
  static const int deviceIdLength = 16;

  // ---- 文件尾 ----
  static const int trailerSize = 40;
  static const int offsetTrailerDigestAlgorithm = 0;
  static const int offsetTrailerReserved = 2;
  static const int offsetTrailerDigest = 4;
  static const int trailerDigestLength = 32;
  static const int offsetTrailerMagic = 36;

  // ---- 取值约束 ----
  static const int expectedNonceLength = 12;
  static const int expectedTagLength = 16;

  /// 明文载荷长度上限：1 TiB。
  ///
  /// 目的不是限制功能，而是让「头部声明的长度」不能用来驱动一次荒谬的分配。
  /// 一个 8 字节的 u64 字段可以声明 16 EiB，读取方若照做就是一次 DoS。
  static const int maxPlaintextLength = 1099511627776;

  /// 给定文件头时，合法文件的最小（也是唯一可能）长度。
  static int exactFileLength(PfbHeader header) =>
      headerSize +
      header.saltLength +
      header.nonceLength +
      header.plaintextLength +
      header.tagLength +
      trailerSize;
}

/// 容器文件头。
final class PfbHeader {
  PfbHeader({
    required this.majorVersion,
    required this.minorVersion,
    required this.kdfAlgorithm,
    required this.aeadAlgorithm,
    required this.kdfMemoryKiB,
    required this.kdfIterations,
    required this.kdfParallelism,
    required this.saltLength,
    required this.nonceLength,
    required this.tagLength,
    required this.plaintextLength,
    required this.exportedAtMilliseconds,
    required Uint8List deviceId,
  }) : deviceId = Uint8List.fromList(deviceId);

  /// 按当前实现版本构造一个头部。
  PfbHeader.create({
    required Argon2Params params,
    required int plaintextLength,
    required int exportedAtMilliseconds,
    required Uint8List deviceId,
    int? majorVersion,
    int? minorVersion,
  }) : this(
         majorVersion: majorVersion ?? PfbFormat.majorVersion,
         minorVersion: minorVersion ?? PfbFormat.minorVersion,
         kdfAlgorithm: PfbAlgorithm.kdfArgon2id,
         aeadAlgorithm: PfbAlgorithm.aeadAes256Gcm,
         kdfMemoryKiB: params.memoryKiB,
         kdfIterations: params.iterations,
         kdfParallelism: params.parallelism,
         saltLength: params.saltLength,
         nonceLength: PfbFormat.expectedNonceLength,
         tagLength: PfbFormat.expectedTagLength,
         plaintextLength: plaintextLength,
         exportedAtMilliseconds: exportedAtMilliseconds,
         deviceId: deviceId,
       );

  static const int currentMajorVersion = PfbFormat.majorVersion;
  static const int currentMinorVersion = PfbFormat.minorVersion;
  static const int deviceIdLength = PfbFormat.deviceIdLength;

  final int majorVersion;
  final int minorVersion;
  final int kdfAlgorithm;
  final int aeadAlgorithm;
  final int kdfMemoryKiB;
  final int kdfIterations;
  final int kdfParallelism;
  final int saltLength;
  final int nonceLength;
  final int tagLength;
  final int plaintextLength;
  final int exportedAtMilliseconds;

  /// 设备 ID（16 字节 UUID v4 原始形式，非字符串）。
  final Uint8List deviceId;

  /// 头部声明的 KDF 参数（盐本身在变长区，不在这里）。
  Argon2Params get kdfParams => Argon2Params(
    memoryKiB: kdfMemoryKiB,
    iterations: kdfIterations,
    parallelism: kdfParallelism,
    saltLength: saltLength,
  );

  /// 导出时刻（UTC）。
  DateTime get exportedAt =>
      DateTime.fromMillisecondsSinceEpoch(exportedAtMilliseconds, isUtc: true);

  /// 结构自洽性校验。
  void validate() {
    if (majorVersion <= 0) {
      throw ContainerError.headerInvalid(detail: '主版本必须为正，实际 $majorVersion');
    }
    if (minorVersion < 0) {
      throw ContainerError.headerInvalid(detail: '次版本不得为负，实际 $minorVersion');
    }
    if (!PfbAlgorithm.isKnownKdf(kdfAlgorithm)) {
      throw ContainerError.headerInvalid(detail: '未知的 KDF 算法 ID $kdfAlgorithm（本版本只认识 Argon2id=1）');
    }
    if (!PfbAlgorithm.isKnownAead(aeadAlgorithm)) {
      throw ContainerError.headerInvalid(
        detail: '未知的 AEAD 算法 ID $aeadAlgorithm（本版本只认识 AES-256-GCM=1）',
      );
    }
    if (nonceLength != PfbFormat.expectedNonceLength) {
      throw ContainerError.headerInvalid(
        detail: 'nonce 长度必须为 ${PfbFormat.expectedNonceLength}，实际 $nonceLength',
      );
    }
    if (tagLength != PfbFormat.expectedTagLength) {
      throw ContainerError.headerInvalid(
        detail: '认证标签长度必须为 ${PfbFormat.expectedTagLength}，实际 $tagLength',
      );
    }
    if (plaintextLength < 0 || plaintextLength > PfbFormat.maxPlaintextLength) {
      throw ContainerError.headerInvalid(
        detail: '明文长度 $plaintextLength 超出 0..${PfbFormat.maxPlaintextLength}',
      );
    }
    if (exportedAtMilliseconds <= 0) {
      throw ContainerError.headerInvalid(detail: '导出时刻必须为正数');
    }
    if (deviceId.length != PfbFormat.deviceIdLength) {
      throw ContainerError.headerInvalid(
        detail: '设备 ID 必须为 ${PfbFormat.deviceIdLength} 字节，实际 ${deviceId.length}',
      );
    }
    // KDF 参数通常是破坏性输入的着陆点（恶意文件可以把 m 写成 16 GiB）
    kdfParams.validate();
  }

  /// 序列化为 76 字节。
  Uint8List encode() {
    validate();
    final bytes = Uint8List(PfbFormat.headerSize);
    BigEndian.writeBytes(bytes, PfbFormat.offsetMagic, pfbMagic);
    BigEndian.writeUint16(bytes, PfbFormat.offsetMajorVersion, majorVersion);
    BigEndian.writeUint16(bytes, PfbFormat.offsetMinorVersion, minorVersion);
    BigEndian.writeUint16(bytes, PfbFormat.offsetKdfAlgorithm, kdfAlgorithm);
    BigEndian.writeUint16(bytes, PfbFormat.offsetAeadAlgorithm, aeadAlgorithm);
    BigEndian.writeUint32(bytes, PfbFormat.offsetKdfMemoryKiB, kdfMemoryKiB);
    BigEndian.writeUint32(bytes, PfbFormat.offsetKdfIterations, kdfIterations);
    BigEndian.writeUint16(bytes, PfbFormat.offsetKdfParallelism, kdfParallelism);
    BigEndian.writeUint16(bytes, PfbFormat.offsetSaltLength, saltLength);
    BigEndian.writeUint16(bytes, PfbFormat.offsetNonceLength, nonceLength);
    BigEndian.writeUint16(bytes, PfbFormat.offsetTagLength, tagLength);
    BigEndian.writeUint64(bytes, PfbFormat.offsetPlaintextLength, plaintextLength);
    BigEndian.writeUint64(bytes, PfbFormat.offsetExportedAt, exportedAtMilliseconds);
    BigEndian.writeBytes(bytes, PfbFormat.offsetDeviceId, deviceId);
    // 保留位保持全 0（Uint8List 初始化为 0，此处不写）
    return bytes;
  }

  /// 从字节解析。
  ///
  /// [maxSupportedMajorVersion] 缺省为本实现支持的版本；
  /// 高于它的文件会得到 `PFB_E_VERSION_UNSUPPORTED`，而不是解析出一堆垃圾字段。
  ///
  /// 次版本高于本实现时**接受**：次版本只允许新增算法 ID 或启用保留位，
  /// 不允许新增区段，因此旧读方能安全地按长度字段正确切分。
  /// 若遇到不认识的算法 ID，会在 [validate] 处明确报错，而不是猜。
  static PfbHeader decode(Uint8List bytes, {int? maxSupportedMajorVersion}) {
    if (bytes.length < PfbFormat.headerSize) {
      throw ContainerError.truncated(expected: PfbFormat.headerSize, actual: bytes.length);
    }
    for (var i = 0; i < pfbMagic.length; i++) {
      if (bytes[i] != pfbMagic[i]) {
        throw ContainerError.magicMismatch();
      }
    }

    final supportedMajor = maxSupportedMajorVersion ?? PfbFormat.majorVersion;
    final major = BigEndian.readUint16(bytes, PfbFormat.offsetMajorVersion);
    if (major > supportedMajor) {
      throw ContainerError.versionUnsupported(found: major, supported: supportedMajor);
    }

    for (var i = 0; i < PfbFormat.reservedLength; i++) {
      final value = bytes[PfbFormat.offsetReserved + i];
      if (value != 0) {
        throw ContainerError.headerInvalid(
          detail: '保留位第 $i 字节为 $value，必须为 0（可能来自更新的次版本，本实现无法安全解析）',
        );
      }
    }

    final header = PfbHeader(
      majorVersion: major,
      minorVersion: BigEndian.readUint16(bytes, PfbFormat.offsetMinorVersion),
      kdfAlgorithm: BigEndian.readUint16(bytes, PfbFormat.offsetKdfAlgorithm),
      aeadAlgorithm: BigEndian.readUint16(bytes, PfbFormat.offsetAeadAlgorithm),
      kdfMemoryKiB: BigEndian.readUint32(bytes, PfbFormat.offsetKdfMemoryKiB),
      kdfIterations: BigEndian.readUint32(bytes, PfbFormat.offsetKdfIterations),
      kdfParallelism: BigEndian.readUint16(bytes, PfbFormat.offsetKdfParallelism),
      saltLength: BigEndian.readUint16(bytes, PfbFormat.offsetSaltLength),
      nonceLength: BigEndian.readUint16(bytes, PfbFormat.offsetNonceLength),
      tagLength: BigEndian.readUint16(bytes, PfbFormat.offsetTagLength),
      plaintextLength: BigEndian.readUint64(bytes, PfbFormat.offsetPlaintextLength),
      exportedAtMilliseconds: BigEndian.readUint64(bytes, PfbFormat.offsetExportedAt),
      deviceId: BigEndian.readBytes(bytes, PfbFormat.offsetDeviceId, PfbFormat.deviceIdLength),
    );
    header.validate();
    return header;
  }

  @override
  String toString() =>
      'PfbHeader(v$majorVersion.$minorVersion, ${kdfParams.describe()}, '
      'plaintext=$plaintextLength, exportedAt=${exportedAt.toIso8601String()})';
}

/// 文件尾：密文摘要，用于在不需要密码的情况下判断文件是否损坏。
final class PfbTrailer {
  PfbTrailer({required this.digestAlgorithm, required Uint8List digest})
    : digest = Uint8List.fromList(digest) {
    if (digest.length != PfbFormat.trailerDigestLength) {
      throw ContainerError.headerInvalid(
        detail: '摘要长度必须为 ${PfbFormat.trailerDigestLength}，实际 ${digest.length}',
      );
    }
    if (!PfbAlgorithm.isKnownDigest(digestAlgorithm)) {
      throw ContainerError.headerInvalid(detail: '未知的摘要算法 ID $digestAlgorithm');
    }
  }

  /// SHA-256 的字节长度。
  static const int digestLength = PfbFormat.trailerDigestLength;

  final int digestAlgorithm;

  /// 对密文段计算的摘要。
  final Uint8List digest;

  Uint8List encode() {
    final bytes = Uint8List(PfbFormat.trailerSize);
    BigEndian.writeUint16(bytes, PfbFormat.offsetTrailerDigestAlgorithm, digestAlgorithm);
    // 保留字段保持 0
    BigEndian.writeBytes(bytes, PfbFormat.offsetTrailerDigest, digest);
    BigEndian.writeBytes(bytes, PfbFormat.offsetTrailerMagic, pfbTrailerMagic);
    return bytes;
  }

  static PfbTrailer decode(Uint8List bytes) {
    if (bytes.length != PfbFormat.trailerSize) {
      throw ContainerError.truncated(expected: PfbFormat.trailerSize, actual: bytes.length);
    }
    for (var i = 0; i < pfbTrailerMagic.length; i++) {
      if (bytes[PfbFormat.offsetTrailerMagic + i] != pfbTrailerMagic[i]) {
        throw ContainerError.digestMismatch(detail: '文件尾魔数不是 PFBF，文件可能被追加了数据');
      }
    }
    if (BigEndian.readUint16(bytes, PfbFormat.offsetTrailerReserved) != 0) {
      throw ContainerError.headerInvalid(detail: '文件尾保留字段不为 0');
    }
    return PfbTrailer(
      digestAlgorithm: BigEndian.readUint16(bytes, PfbFormat.offsetTrailerDigestAlgorithm),
      digest: BigEndian.readBytes(
        bytes,
        PfbFormat.offsetTrailerDigest,
        PfbFormat.trailerDigestLength,
      ),
    );
  }

  @override
  String toString() => 'PfbTrailer(digest=${toHex(digest).substring(0, 16)}…)';
}

/// 已切分好的容器区段。**全部是原缓冲区的视图**，不复制数据。
final class PfbSlices {
  const PfbSlices({
    required this.header,
    required this.salt,
    required this.nonce,
    required this.ciphertext,
    required this.tag,
    required this.trailer,
  });

  final PfbHeader header;
  final Uint8List salt;
  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List tag;
  final PfbTrailer trailer;

  @override
  String toString() =>
      'PfbSlices(salt=${salt.length}B nonce=${nonce.length}B '
      'ciphertext=${ciphertext.length}B tag=${tag.length}B)';
}

/// 容器布局解析。
abstract final class PfbLayout {
  /// 解析并校验文件长度与各段偏移。
  ///
  /// 严格性：文件长度必须**恰好等于**头部声明的长度。
  /// 多出来的字节会被拒绝，而不是静默忽略 ——
  /// 因为摘要只覆盖密文段，多出来的数据不受任何完整性保护，
  /// 放行它等于给"在文件末尾夹带私货"留了口子。
  static PfbSlices slice(Uint8List file) {
    final header = PfbHeader.decode(file);
    final expected = PfbFormat.exactFileLength(header);
    if (file.length < expected) {
      throw ContainerError.truncated(expected: expected, actual: file.length);
    }
    if (file.length > expected) {
      throw ContainerError.headerInvalid(
        detail: '文件长度 ${file.length} 超出头部声明长度 $expected（尾部存在未受保护的多余数据）',
      );
    }

    const saltOffset = PfbFormat.headerSize;
    final nonceOffset = saltOffset + header.saltLength;
    final ciphertextOffset = nonceOffset + header.nonceLength;
    final tagOffset = ciphertextOffset + header.plaintextLength;
    final trailerOffset = tagOffset + header.tagLength;

    return PfbSlices(
      header: header,
      salt: Uint8List.sublistView(file, saltOffset, nonceOffset),
      nonce: Uint8List.sublistView(file, nonceOffset, ciphertextOffset),
      ciphertext: Uint8List.sublistView(file, ciphertextOffset, tagOffset),
      tag: Uint8List.sublistView(file, tagOffset, trailerOffset),
      trailer: PfbTrailer.decode(
        Uint8List.sublistView(file, trailerOffset, trailerOffset + PfbFormat.trailerSize),
      ),
    );
  }
}

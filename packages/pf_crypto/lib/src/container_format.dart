/// PFB 加密容器格式（规格 §3.3 的**分块**容器，2026-09-17 裁决为唯一 v1）。
///
/// ## 完整字节布局（全部整数大端）
///
/// ```
/// ┌─ HEADER（128 字节 = 48 固定 + 80 变量区，明文）──────────────────────────┐
/// │  0     8  magic             ASCII  "PFBOOK\x01\x00"                      │
/// │  8     2  formatVersion u16   1     主版本，不兼容才升                     │
/// │ 10     2  minReaderVersion u16 1     低于此值的读方拒绝                    │
/// │ 12     2  featureFlags u16   bit0=AESGCM bit1=GZIP bit2=CHUNKED         │
/// │                             bit3=HAS_ATTACH bit4=MULTI_VOLUME            │
/// │                             bit5=INCREMENTAL                             │
/// │ 14     1  kdfId u8          1=Argon2id                                   │
/// │ 15     1  aeadId u8         1=AES-256-GCM                                │
/// │ 16     4  kdfMemKiB u32                                                  │
/// │ 20     4  kdfIterations u32                                              │
/// │ 24     1  kdfParallelism u8                                              │
/// │ 25     1  kdfOutLen u8      32                                           │
/// │ 26     2  kdfSaltLen u16     16                                          │
/// │ 28     2  noncePrefixLen u16 8                                           │
/// │ 30     2  chunkPlainSize u16 块明文大小，单位 KiB（1024 = 1 MiB）         │
/// │ 32     8  plaintextLength u64  压缩后明文总长                              │
/// │ 40     4  chunkCount u32     分块数（0 仅当明文为空）                     │
/// │ 44     4  headerCrc32 u32    CRC32(偏移 0..44)，覆盖固定头                 │
/// │ 48    16  kdfSalt         随机，每次导出必须新生成                          │
/// │ 64     8  noncePrefix     随机（分块 nonce 前缀）                           │
/// │ 72    12  firstChunkNonce = noncePrefix || 00000000                      │
/// │ 84     8  volumeSetId     分卷集合标识（非分卷也填）                       │
/// │ 92     2  volumeIndex u16 1-based                                        │
/// │ 94     2  volumeTotal u16                                                │
/// │ 96    32  setDigest         预留（多卷集合摘要；单卷写全 0）               │
/// ├─ 密文区（128 起，每块）─────────────────────────────────────────────────┤
/// │ +0     4  chunkLen u32     = 该块明文长 + 16（tag 一并计入）              │
/// │ +4    12  chunkNonce       = noncePrefix || u32BE(chunkIndex)            │
/// │ +16    N  box              = AES-256-GCM 密文 || 16 字节 tag              │
/// │                                                                            │
/// │ 单块 AAD = SHA256(header[0..128]) || u32BE(chunkIndex) || prevTag          │
/// │   chunkIndex=0 时 prevTag = 32 个 0x00；其后为上一块 box 的末 16 字节       │
/// │   → 绑定头部（参数不可篡改）、绑定顺序（不可重排）、绑定前序（不可截断）    │
/// ├─ TRAILER（32 字节，明文）───────────────────────────────────────────────┤
/// │ contentDigest = SHA256(文件[48 .. 长度-32])                               │
/// │   = SHA256(kdfSalt || noncePrefix || 全部 chunkLen || 全部 box)           │
/// │   → 免密判断文件是否损坏；「损坏」与「密码错」的分流依据                    │
/// └──────────────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## 2026-09-17 的容器格式裁决（ADR）
///
/// M0 期间曾落地过一版 **76 字节 "PFB1" 单块容器**（无分块、无链式 AAD），
/// 并被当时的 container_header / container_layout / container_trailer 向量锁死。
/// 落实导出器（M1 ⑤）时确认它与规格 §3.3 冲突：规格要求分块 + noncePrefix +
/// 链式 AAD（内存峰值 ≈ 2×1 MiB、可检测重排/截断、参数被 AAD 绑定）。
/// **裁决：§3.3 为唯一 v1**，76 字节版废除，三套向量按 §3.3 重写。
/// 该格式从未发布过任何文件（v0.1.0 尚未出包），无迁移问题；
/// 裁决记录见 `docs/M0_ACCEPTANCE.md` 与当日运行手册。
///
/// ## 「密码错」与「文件损坏」为什么能区分
///
/// 校验顺序即分流顺序（[PfbReader.open]）：
///
///   魔数不符                     → 选错文件（PFB_E_MAGIC）
///   版本过高                     → 版本不兼容（PFB_E_VERSION_UNSUPPORTED）
///   头部 CRC 不符 / 字段非法      → 结构损坏（PFB_E_HEADER_INVALID）
///   contentDigest 不符（免密）   → 文件损坏（PFB_E_DIGEST_MISMATCH）
///   上述全过 + GCM 认证失败      → 密码错（PFB_E_AUTH_FAILED）
///
/// 没有这一层，AES-GCM 的认证失败在密码学上无法区分「损坏」与「密码错」。
///
/// ## 随机源
///
/// 写入方不生成任何随机数：salt / noncePrefix / volumeSetId 全部由调用方注入
/// （附录 B 的「固定随机源」原则 —— 没有它就无法对完整文件做字节级断言）。
/// 生产侧的 CSPRNG 封装在导出管线（pf_io），不在本层。
library;

import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';

import 'aesgcm.dart';
import 'argon2_params.dart';
import 'byte_order.dart';
import 'crc32.dart';
import 'digest.dart';

/// 头部魔数：ASCII `PFBOOK` + 版本 1.0。
const List<int> pfbMagic = <int>[0x50, 0x46, 0x42, 0x4F, 0x4F, 0x4B, 0x01, 0x00];

/// 算法数值 ID。一旦发布即为契约：新增算法只能追加新 ID，不得复用。
abstract final class PfbAlgorithm {
  /// KDF：Argon2id。
  static const int kdfArgon2id = 1;

  /// AEAD：AES-256-GCM。
  static const int aeadAes256Gcm = 1;

  static bool isKnownKdf(int id) => id == kdfArgon2id;

  static bool isKnownAead(int id) => id == aeadAes256Gcm;
}

/// featureFlags 的位定义（§3.3）。
abstract final class PfbFlags {
  /// AES-256-GCM（本版本必置）。
  static const int bitAesGcm = 1 << 0;

  /// 载荷先 GZIP 压缩再加密（压缩是载荷管线的职责，容器层只记录事实）。
  static const int bitGzip = 1 << 1;

  /// 分块加密（本实现必置；未分块格式不存在 —— 附录 C 脚本按分块读）。
  static const int bitChunked = 1 << 2;

  /// 载荷含附件记录。
  static const int bitHasAttachments = 1 << 3;

  /// 多分卷文件。
  static const int bitMultiVolume = 1 << 4;

  /// 增量导出（载荷含墓碑与 change_log 游标）。
  static const int bitIncremental = 1 << 5;

  /// 本实现认识的全部位。
  static const int knownMask =
      bitAesGcm | bitGzip | bitChunked | bitHasAttachments | bitMultiVolume | bitIncremental;

  /// 组合多个位的便捷写法。
  static int of({
    bool gzip = false,
    bool hasAttachments = false,
    bool multiVolume = false,
    bool incremental = false,
  }) {
    var v = bitAesGcm | bitChunked;
    if (gzip) {
      v |= bitGzip;
    }
    if (hasAttachments) {
      v |= bitHasAttachments;
    }
    if (multiVolume) {
      v |= bitMultiVolume;
    }
    if (incremental) {
      v |= bitIncremental;
    }
    return v;
  }
}

/// 格式常量：偏移与长度。
abstract final class PfbFormat {
  /// 本实现写出的容器主版本。
  static const int formatVersion = PfBuildInfo.containerFormatVersion;

  /// 低于此版本的读方必须拒绝。
  static const int minReaderVersion = 1;

  // ---- 固定头（48 字节） ----
  static const int offsetMagic = 0;
  static const int magicLength = 8;
  static const int offsetFormatVersion = 8;
  static const int offsetMinReaderVersion = 10;
  static const int offsetFeatureFlags = 12;
  static const int offsetKdfId = 14;
  static const int offsetAeadId = 15;
  static const int offsetKdfMemKiB = 16;
  static const int offsetKdfIterations = 20;
  static const int offsetKdfParallelism = 24;
  static const int offsetKdfOutLen = 25;
  static const int offsetKdfSaltLen = 26;
  static const int offsetNoncePrefixLen = 28;
  static const int offsetChunkPlainSizeKiB = 30;
  static const int offsetPlaintextLength = 32;
  static const int offsetChunkCount = 40;
  static const int offsetHeaderCrc32 = 44;
  static const int fixedHeaderSize = 48;

  // ---- 变量区（48..128） ----
  static const int offsetKdfSalt = 48;
  static const int offsetNoncePrefix = 64;
  static const int offsetFirstChunkNonce = 72;
  static const int offsetVolumeSetId = 84;
  static const int offsetVolumeIndex = 92;
  static const int offsetVolumeTotal = 94;
  static const int offsetSetDigest = 96;

  /// 头部总长（固定头 + 变量区）。AAD 基础 = SHA256(前 128 字节)。
  static const int headerSize = 128;

  /// 密文区每块的固定开销：chunkLen(4) + chunkNonce(12)。
  static const int perChunkOverhead = 16;

  // ---- 文件尾 ----
  static const int trailerSize = 32;
  static const int trailerDigestLength = 32;

  // ---- 取值约束 ----
  static const int nonceLength = 12;
  static const int tagLength = 16;
  static const int noncePrefixLength = 8;
  static const int saltLength = 16;
  static const int volumeSetIdLength = 8;
  static const int setDigestLength = 32;
  static const int defaultChunkPlainSizeKiB = 1024;
  static const int maxVolumes = 64;

  /// 明文载荷长度上限：1 TiB。
  ///
  /// 目的不是限制功能，而是让「头部声明的长度」不能驱动一次荒谬的分配。
  static const int maxPlaintextLength = 1099511627776;

  /// 明文（压缩后）非空时的最小分块数。
  static int chunkCountFor({required int plaintextLength, required int chunkPlainSizeKiB}) {
    final chunkBytes = chunkPlainSizeKiB * 1024;
    if (plaintextLength == 0) {
      return 0;
    }
    return (plaintextLength + chunkBytes - 1) ~/ chunkBytes;
  }
}

/// PFB 容器文件头（128 字节，含变量区）。
final class PfbHeader {
  PfbHeader({
    required this.formatVersion,
    required this.minReaderVersion,
    required this.featureFlags,
    required this.kdf,
    required this.chunkPlainSizeKiB,
    required this.plaintextLength,
    required this.chunkCount,
    required Uint8List salt,
    required Uint8List noncePrefix,
    required Uint8List volumeSetId,
    required this.volumeIndex,
    required this.volumeTotal,
    required Uint8List setDigest,
  }) : salt = Uint8List.fromList(salt),
       noncePrefix = Uint8List.fromList(noncePrefix),
       volumeSetId = Uint8List.fromList(volumeSetId),
       setDigest = Uint8List.fromList(setDigest);

  /// 按当前实现版本与默认值构造。
  PfbHeader.create({
    required Argon2Params kdf,
    required PfbFlagsSpec flags,
    required int plaintextLength,
    required Uint8List salt,
    required Uint8List noncePrefix,
    int chunkPlainSizeKiB = PfbFormat.defaultChunkPlainSizeKiB,
    int volumeIndex = 1,
    int volumeTotal = 1,
    Uint8List? volumeSetId,
    Uint8List? setDigest,
    int? formatVersion,
    int? minReaderVersion,
  }) : this(
         formatVersion: formatVersion ?? PfbFormat.formatVersion,
         minReaderVersion: minReaderVersion ?? PfbFormat.minReaderVersion,
         featureFlags: flags.value,
         kdf: kdf,
         chunkPlainSizeKiB: chunkPlainSizeKiB,
         plaintextLength: plaintextLength,
         chunkCount: PfbFormat.chunkCountFor(
           plaintextLength: plaintextLength,
           chunkPlainSizeKiB: chunkPlainSizeKiB,
         ),
         salt: salt,
         noncePrefix: noncePrefix,
         volumeSetId: volumeSetId ?? Uint8List(PfbFormat.volumeSetIdLength),
         volumeIndex: volumeIndex,
         volumeTotal: volumeTotal,
         setDigest: setDigest ?? Uint8List(PfbFormat.setDigestLength),
       );

  final int formatVersion;
  final int minReaderVersion;
  final int featureFlags;
  final Argon2Params kdf;
  final int chunkPlainSizeKiB;
  final int plaintextLength;
  final int chunkCount;
  final Uint8List salt;
  final Uint8List noncePrefix;
  final Uint8List volumeSetId;
  final int volumeIndex;
  final int volumeTotal;
  final Uint8List setDigest;

  bool get flagGzip => (featureFlags & PfbFlags.bitGzip) != 0;
  bool get flagChunked => (featureFlags & PfbFlags.bitChunked) != 0;
  bool get flagIncremental => (featureFlags & PfbFlags.bitIncremental) != 0;

  /// 块明文大小（字节）。
  int get chunkPlainSizeBytes => chunkPlainSizeKiB * 1024;

  /// 结构自洽性校验。全部失败都是 [ContainerError.headerInvalid]，
  /// 只有「长度不足」「魔数」「版本」走各自的码。
  void validate() {
    if (formatVersion <= 0) {
      throw ContainerError.headerInvalid(detail: '格式主版本必须为正，实际 $formatVersion');
    }
    if (minReaderVersion <= 0) {
      throw ContainerError.headerInvalid(detail: 'minReaderVersion 必须为正，实际 $minReaderVersion');
    }
    final unknown = featureFlags & ~PfbFlags.knownMask;
    if (unknown != 0) {
      throw ContainerError.headerInvalid(
        detail:
            'featureFlags 含未知位 0x${unknown.toRadixString(16)}'
            '（来自更新的次版本，本实现无法安全解析）',
      );
    }
    if ((featureFlags & PfbFlags.bitAesGcm) == 0) {
      throw ContainerError.headerInvalid(detail: 'bit0(AESGCM) 未置位 —— 本格式只定义了这一种 AEAD');
    }
    if (chunkPlainSizeKiB < 1) {
      throw ContainerError.headerInvalid(detail: 'chunkPlainSize 必须 ≥ 1 KiB，实际 $chunkPlainSizeKiB');
    }
    if (plaintextLength < 0 || plaintextLength > PfbFormat.maxPlaintextLength) {
      throw ContainerError.headerInvalid(
        detail: '明文长度 $plaintextLength 超出 0..${PfbFormat.maxPlaintextLength}',
      );
    }
    // 分块数与明文长度必须自洽：除末块外每块都应装满。
    if (chunkCount == 0) {
      if (plaintextLength != 0) {
        throw ContainerError.headerInvalid(detail: 'chunkCount=0 但明文长度 $plaintextLength ≠ 0');
      }
    } else {
      final chunkBytes = chunkPlainSizeBytes;
      final lower = (chunkCount - 1) * chunkBytes;
      final upper = chunkCount * chunkBytes;
      if (plaintextLength <= lower || plaintextLength > upper) {
        throw ContainerError.headerInvalid(
          detail:
              'chunkCount=$chunkCount 与明文长度 $plaintextLength、'
              '块大小 ${chunkBytes}B 不自洽（应为 ($lower, $upper]）',
        );
      }
    }
    if (volumeTotal < 1 || volumeTotal > PfbFormat.maxVolumes) {
      throw ContainerError.headerInvalid(
        detail: 'volumeTotal=$volumeTotal 超出 1..${PfbFormat.maxVolumes}',
      );
    }
    if (volumeIndex < 1 || volumeIndex > volumeTotal) {
      throw ContainerError.headerInvalid(detail: 'volumeIndex=$volumeIndex 超出 1..$volumeTotal');
    }
    kdf.validate();
  }

  /// 序列化为 128 字节（含 CRC32 与变量区）。
  Uint8List encode() {
    if (salt.length != kdf.saltLength) {
      throw ContainerError.headerInvalid(
        detail: '盐实际 ${salt.length} 字节，与声明的 kdfSaltLen=${kdf.saltLength} 不符',
      );
    }
    if (noncePrefix.length != PfbFormat.noncePrefixLength) {
      throw ContainerError.headerInvalid(
        detail: 'noncePrefix 必须 ${PfbFormat.noncePrefixLength} 字节，实际 ${noncePrefix.length}',
      );
    }
    validate();
    final bytes = Uint8List(PfbFormat.headerSize);
    BigEndian.writeBytes(bytes, PfbFormat.offsetMagic, pfbMagic);
    BigEndian.writeUint16(bytes, PfbFormat.offsetFormatVersion, formatVersion);
    BigEndian.writeUint16(bytes, PfbFormat.offsetMinReaderVersion, minReaderVersion);
    BigEndian.writeUint16(bytes, PfbFormat.offsetFeatureFlags, featureFlags);
    bytes[PfbFormat.offsetKdfId] = PfbAlgorithm.kdfArgon2id;
    bytes[PfbFormat.offsetAeadId] = PfbAlgorithm.aeadAes256Gcm;
    BigEndian.writeUint32(bytes, PfbFormat.offsetKdfMemKiB, kdf.memoryKiB);
    BigEndian.writeUint32(bytes, PfbFormat.offsetKdfIterations, kdf.iterations);
    bytes[PfbFormat.offsetKdfParallelism] = kdf.parallelism;
    bytes[PfbFormat.offsetKdfOutLen] = kdf.outputLength;
    BigEndian.writeUint16(bytes, PfbFormat.offsetKdfSaltLen, kdf.saltLength);
    BigEndian.writeUint16(bytes, PfbFormat.offsetNoncePrefixLen, noncePrefix.length);
    BigEndian.writeUint16(bytes, PfbFormat.offsetChunkPlainSizeKiB, chunkPlainSizeKiB);
    BigEndian.writeUint64(bytes, PfbFormat.offsetPlaintextLength, plaintextLength);
    BigEndian.writeUint32(bytes, PfbFormat.offsetChunkCount, chunkCount);
    BigEndian.writeBytes(bytes, PfbFormat.offsetKdfSalt, salt);
    BigEndian.writeBytes(bytes, PfbFormat.offsetNoncePrefix, noncePrefix);
    // firstChunkNonce = noncePrefix || u32(0)
    BigEndian.writeBytes(bytes, PfbFormat.offsetFirstChunkNonce, noncePrefix);
    BigEndian.writeBytes(bytes, PfbFormat.offsetVolumeSetId, volumeSetId);
    BigEndian.writeUint16(bytes, PfbFormat.offsetVolumeIndex, volumeIndex);
    BigEndian.writeUint16(bytes, PfbFormat.offsetVolumeTotal, volumeTotal);
    BigEndian.writeBytes(bytes, PfbFormat.offsetSetDigest, setDigest);
    Crc32.writeInto(bytes, PfbFormat.offsetHeaderCrc32, bytes, 0, PfbFormat.offsetHeaderCrc32);
    return bytes;
  }

  /// 从字节解析（128 字节头部）。
  ///
  /// [maxSupportedFormatVersion] 缺省为本实现支持的版本；高于它的文件报
  /// [ContainerError.versionUnsupported]，而不是解析出一堆垃圾字段。
  static PfbHeader decode(Uint8List bytes, {int? maxSupportedFormatVersion}) {
    if (bytes.length < PfbFormat.headerSize) {
      throw ContainerError.truncated(expected: PfbFormat.headerSize, actual: bytes.length);
    }
    for (var i = 0; i < pfbMagic.length; i++) {
      if (bytes[i] != pfbMagic[i]) {
        throw ContainerError.magicMismatch();
      }
    }
    final supported = maxSupportedFormatVersion ?? PfbFormat.formatVersion;
    final major = BigEndian.readUint16(bytes, PfbFormat.offsetFormatVersion);
    if (major > supported) {
      throw ContainerError.versionUnsupported(found: major, supported: supported);
    }

    // CRC 先于字段语义校验：先确认头部没被改过，再去解释它。
    final declaredCrc = BigEndian.readUint32(bytes, PfbFormat.offsetHeaderCrc32);
    final computedCrc = Crc32.of(bytes, 0, PfbFormat.offsetHeaderCrc32);
    if (declaredCrc != computedCrc) {
      throw ContainerError.headerInvalid(
        detail:
            '头部 CRC32 不匹配（声明 0x${declaredCrc.toRadixString(16)}，'
            '实际 0x${computedCrc.toRadixString(16)}）—— 头部被篡改或不是本格式',
      );
    }

    final header = PfbHeader(
      formatVersion: major,
      minReaderVersion: BigEndian.readUint16(bytes, PfbFormat.offsetMinReaderVersion),
      featureFlags: BigEndian.readUint16(bytes, PfbFormat.offsetFeatureFlags),
      kdf: Argon2Params(
        memoryKiB: BigEndian.readUint32(bytes, PfbFormat.offsetKdfMemKiB),
        iterations: BigEndian.readUint32(bytes, PfbFormat.offsetKdfIterations),
        parallelism: bytes[PfbFormat.offsetKdfParallelism],
        saltLength: BigEndian.readUint16(bytes, PfbFormat.offsetKdfSaltLen),
        outputLength: bytes[PfbFormat.offsetKdfOutLen],
      ),
      chunkPlainSizeKiB: BigEndian.readUint16(bytes, PfbFormat.offsetChunkPlainSizeKiB),
      plaintextLength: BigEndian.readUint64(bytes, PfbFormat.offsetPlaintextLength),
      chunkCount: BigEndian.readUint32(bytes, PfbFormat.offsetChunkCount),
      salt: BigEndian.readBytes(
        bytes,
        PfbFormat.offsetKdfSalt,
        BigEndian.readUint16(bytes, PfbFormat.offsetKdfSaltLen),
      ),
      noncePrefix: BigEndian.readBytes(
        bytes,
        PfbFormat.offsetNoncePrefix,
        BigEndian.readUint16(bytes, PfbFormat.offsetNoncePrefixLen),
      ),
      volumeSetId: BigEndian.readBytes(
        bytes,
        PfbFormat.offsetVolumeSetId,
        PfbFormat.volumeSetIdLength,
      ),
      volumeIndex: BigEndian.readUint16(bytes, PfbFormat.offsetVolumeIndex),
      volumeTotal: BigEndian.readUint16(bytes, PfbFormat.offsetVolumeTotal),
      setDigest: BigEndian.readBytes(bytes, PfbFormat.offsetSetDigest, PfbFormat.setDigestLength),
    );
    // firstChunkNonce 必须等于 prefix || 00000000（可校验的冗余，防手拼头写错）。
    for (var i = 0; i < 8; i++) {
      if (bytes[PfbFormat.offsetFirstChunkNonce + i] != header.noncePrefix[i]) {
        throw ContainerError.headerInvalid(detail: 'firstChunkNonce 前 8 字节与 noncePrefix 不一致');
      }
    }
    for (var i = 8; i < 12; i++) {
      if (bytes[PfbFormat.offsetFirstChunkNonce + i] != 0) {
        throw ContainerError.headerInvalid(detail: 'firstChunkNonce 末 4 字节必须为 0');
      }
    }
    header.validate();
    return header;
  }

  @override
  String toString() =>
      'PfbHeader(v$formatVersion, flags=0x${featureFlags.toRadixString(16)}, '
      '${kdf.describe()}, chunks=$chunkCount, plain=$plaintextLength)';
}

/// 容器里的一块密文。
final class PfbChunk {
  const PfbChunk({required this.index, required this.nonce, required this.box});

  /// 块序号（0 起）。
  final int index;

  /// 12 字节 nonce = noncePrefix || u32BE(index)。
  final Uint8List nonce;

  /// 密文 + 16 字节标签（即文件里 chunkLen 字节的那一段）。
  final Uint8List box;

  int get cipherLength => box.length;

  int get plainLength => box.length - PfbFormat.tagLength;
}

/// 已切分好的容器区段。除 [chunks] 外，字节均为原缓冲区视图或拷贝。
final class PfbSlices {
  const PfbSlices({required this.header, required this.chunks, required this.contentDigest});

  final PfbHeader header;
  final List<PfbChunk> chunks;

  /// 文件尾声明的 32 字节内容摘要。
  final Uint8List contentDigest;

  int get fileLength =>
      PfbFormat.headerSize +
      chunks.fold<int>(0, (sum, c) => sum + PfbFormat.perChunkOverhead + c.cipherLength) +
      PfbFormat.trailerSize;
}

/// 容器布局解析。
abstract final class PfbLayout {
  /// 解析头部并按块切分密文区，校验文件长度与 nonce 序号。
  ///
  /// 严格性：文件长度必须**恰好**等于头部声明推出的长度 ——
  /// 多出来的字节不受任何完整性保护，放行它等于给"末尾夹带私货"留口子。
  static PfbSlices slice(Uint8List file) {
    final header = PfbHeader.decode(file);
    if (!header.flagChunked) {
      throw ContainerError.headerInvalid(detail: 'bit2(CHUNKED) 未置位 —— 本实现只支持分块容器');
    }
    final expectedTotal = _expectedFileLength(header);
    if (file.length < expectedTotal) {
      throw ContainerError.truncated(expected: expectedTotal, actual: file.length);
    }
    if (file.length > expectedTotal) {
      throw ContainerError.headerInvalid(
        detail: '文件长度 ${file.length} 超出结构推出长度 $expectedTotal（尾部存在未受保护的多余数据）',
      );
    }

    final chunks = <PfbChunk>[];
    var off = PfbFormat.headerSize;
    for (var idx = 0; idx < header.chunkCount; idx++) {
      final len = BigEndian.readUint32(file, off);
      if (len <= PfbFormat.tagLength) {
        throw ContainerError.headerInvalid(detail: '第 $idx 块 chunkLen=$len，小于标签长度');
      }
      final nonce = BigEndian.readBytes(file, off + 4, PfbFormat.nonceLength);
      final box = BigEndian.readBytes(file, off + 4 + PfbFormat.nonceLength, len);
      chunks.add(PfbChunk(index: idx, nonce: nonce, box: box));
      off += PfbFormat.perChunkOverhead + len;
    }
    if (off + PfbFormat.trailerSize != file.length) {
      throw ContainerError.headerInvalid(
        detail: '密文区结束位置 $off 与文件长度 ${file.length} 不符（尾部应为 32 字节摘要）',
      );
    }
    return PfbSlices(
      header: header,
      chunks: chunks,
      contentDigest: BigEndian.readBytes(file, off, PfbFormat.trailerDigestLength),
    );
  }

  static int _expectedFileLength(PfbHeader header) {
    // 恰好长度：sum(chunkLen) = 明文长 + 每块 16 字节 tag，逐块开销 4+12。
    return PfbFormat.headerSize +
        header.plaintextLength +
        header.chunkCount * PfbFormat.tagLength +
        header.chunkCount * PfbFormat.perChunkOverhead +
        PfbFormat.trailerSize;
  }
}

/// 内容摘要（文件尾 32 字节）的核对。
///
/// 覆盖范围是文件 [48 .. 长度-32]（= salt 起、trailer 前），**不含固定头** ——
/// 固定头的完整性由 headerCrc32 负责，两者的分工被向量锁死。
final class PfbContentDigestVerdict {
  const PfbContentDigestVerdict({required this.computed, required this.declared});

  final Uint8List computed;
  final Uint8List declared;

  bool get matches => constantTimeEquals(computed, declared);

  String get computedHex => toHex(computed);

  String get declaredHex => toHex(declared);
}

/// 容器写入与读取。
///
/// ## 为什么这里没有密码
///
/// 容器层只认**已经派生好的 32 字节密钥**。导出密码 → ExportKey 的 Argon2id
/// 派生在密钥层完成（§3.1：参数写进头部，任何设备都能复现），容器层不重复
/// 承担 KDF 职责 —— 这样向量可以单独锁容器，KDF 的向量继续由 argon2id 套件守。
abstract final class PfbContainer {
  /// 把 [payload]（压缩后的明文）按 [kdf]/[salt]/[noncePrefix] 分块加密成完整 .pfb 文件。
  ///
  /// 全程确定性：给定相同输入（含密钥）产出逐字节相同的文件 —— 这是向量
  /// 字节级断言的前提（附录 B「固定随机源」）。
  static Future<Uint8List> seal({
    required Uint8List payload,
    required Uint8List key,
    required Uint8List salt,
    required Uint8List noncePrefix,
    required Argon2Params kdf,
    PfbFlagsSpec flags = const PfbFlagsSpec(),
    int chunkPlainSizeKiB = PfbFormat.defaultChunkPlainSizeKiB,
    int volumeIndex = 1,
    int volumeTotal = 1,
    Uint8List? volumeSetId,
    Aes256Gcm aead = Aes256Gcm.instance,
    Digest digest = Sha256.instance,
    int? formatVersion,
    int? minReaderVersion,
  }) async {
    final header = PfbHeader.create(
      kdf: kdf,
      flags: flags,
      plaintextLength: payload.length,
      salt: salt,
      noncePrefix: noncePrefix,
      chunkPlainSizeKiB: chunkPlainSizeKiB,
      volumeIndex: volumeIndex,
      volumeTotal: volumeTotal,
      volumeSetId: volumeSetId,
      formatVersion: formatVersion,
      minReaderVersion: minReaderVersion,
    );
    final headerBytes = header.encode();
    final aadBase = digest.hash(headerBytes);

    // 明文缓冲 + 密文输出的内存峰值 ≈ 2×块大小（§3.3 选 1 MiB 的理由）。
    final out = BytesBuilder(copy: false);
    out.add(headerBytes);
    var prevTag = Uint8List(32); // 首块 AAD 的 prevTag = 32 个 0x00（规格原文）
    final chunkBytes = header.chunkPlainSizeBytes;
    for (var idx = 0; idx < header.chunkCount; idx++) {
      final start = idx * chunkBytes;
      var end = start + chunkBytes;
      if (end > payload.length) {
        end = payload.length;
      }
      final plain = Uint8List.sublistView(payload, start, end);
      final nonce = _deriveNonce(noncePrefix, idx);
      final aad =
          BytesBuilder()
            ..add(aadBase)
            ..add(Uint8List(4)..buffer.asByteData().setUint32(0, idx, Endian.big))
            ..add(prevTag);
      final detached = await aead.sealDetached(
        key: key,
        nonce: nonce,
        plaintext: plain,
        aad: aad.toBytes(),
      );
      final box =
          BytesBuilder()
            ..add(detached.ciphertext)
            ..add(detached.tag);
      final boxBytes = box.toBytes();
      final lenPrefix = Uint8List(4)..buffer.asByteData().setUint32(0, boxBytes.length, Endian.big);
      out.add(lenPrefix);
      out.add(nonce);
      out.add(boxBytes);
      prevTag = detached.tag;
    }
    final bodyWithoutTrailer = out.toBytes();
    final contentDigest = digest.hash(
      Uint8List.sublistView(bodyWithoutTrailer, PfbFormat.offsetKdfSalt, bodyWithoutTrailer.length),
    );
    final trailer = Uint8List(PfbFormat.trailerSize);
    trailer.setRange(0, PfbFormat.trailerDigestLength, contentDigest);
    final file =
        BytesBuilder()
          ..add(bodyWithoutTrailer)
          ..add(trailer);
    return file.toBytes();
  }

  /// 解开并校验整个文件。见类注释的分流顺序；成功返回明文（压缩后的载荷）。
  static Future<Uint8List> open({
    required Uint8List file,
    required Uint8List key,
    Aes256Gcm aead = Aes256Gcm.instance,
    Digest digest = Sha256.instance,
    int? maxSupportedFormatVersion,
  }) async {
    final slices = PfbLayout.slice(file);

    // 免密完整性：contentDigest 先于任何密钥使用。
    final computed = digest.hash(
      Uint8List.sublistView(file, PfbFormat.offsetKdfSalt, file.length - PfbFormat.trailerSize),
    );
    if (!constantTimeEquals(computed, slices.contentDigest)) {
      throw ContainerError.digestMismatch(
        detail:
            '内容摘要与文件尾声明不符（声明 ${toHex(slices.contentDigest).substring(0, 16)}…，'
            '计算 ${toHex(computed).substring(0, 16)}…）',
      );
    }

    final aadBase = digest.hash(Uint8List.sublistView(file, 0, PfbFormat.headerSize));
    final payload = BytesBuilder(copy: false);
    var prevTag = Uint8List(32);
    for (final chunk in slices.chunks) {
      final expectedNonce = _deriveNonce(slices.header.noncePrefix, chunk.index);
      for (var i = 0; i < PfbFormat.nonceLength; i++) {
        if (chunk.nonce[i] != expectedNonce[i]) {
          throw ContainerError.headerInvalid(
            detail: '第 ${chunk.index} 块 nonce 与 noncePrefix||u32BE(${chunk.index}) 不符（可能被重排）',
          );
        }
      }
      final aad =
          BytesBuilder()
            ..add(aadBase)
            ..add(Uint8List(4)..buffer.asByteData().setUint32(0, chunk.index, Endian.big))
            ..add(prevTag);
      final plain = await aead.open(
        key: key,
        nonce: chunk.nonce,
        ciphertext: Uint8List.sublistView(chunk.box, 0, chunk.plainLength),
        tag: Uint8List.sublistView(chunk.box, chunk.plainLength),
        aad: aad.toBytes(),
      );
      payload.add(plain);
      prevTag = Uint8List.sublistView(chunk.box, chunk.plainLength);
    }
    final result = payload.toBytes();
    if (result.length != slices.header.plaintextLength) {
      throw ContainerError.headerInvalid(
        detail: '解出明文 ${result.length} 字节，与头部声明的 ${slices.header.plaintextLength} 不符',
      );
    }
    return result;
  }

  /// 只核对内容摘要（免密完整性），不解密。向量 kind `container.digest.verify`
  /// 与单测共用这一个入口 —— 「算什么」只允许有一份实现。
  static PfbContentDigestVerdict verifyContentDigest(
    Uint8List file, {
    Digest digest = Sha256.instance,
  }) {
    if (file.length < PfbFormat.headerSize + PfbFormat.trailerSize) {
      throw ContainerError.truncated(
        expected: PfbFormat.headerSize + PfbFormat.trailerSize,
        actual: file.length,
      );
    }
    return PfbContentDigestVerdict(
      computed: digest.hash(
        Uint8List.sublistView(file, PfbFormat.offsetKdfSalt, file.length - PfbFormat.trailerSize),
      ),
      declared: Uint8List.sublistView(
        file,
        file.length - PfbFormat.trailerDigestLength,
        file.length,
      ),
    );
  }

  /// chunkNonce = noncePrefix || u32BE(chunkIndex)（§3.3：确定性计数器 nonce）。
  static Uint8List _deriveNonce(Uint8List noncePrefix, int index) {
    final nonce = Uint8List(PfbFormat.nonceLength);
    nonce.setRange(0, noncePrefix.length, noncePrefix);
    ByteData.sublistView(nonce).setUint32(noncePrefix.length, index, Endian.big);
    return nonce;
  }
}

/// featureFlags 的构造描述（语义位 → 整数）。
///
/// 与 [PfbFlags] 的静态位常量配合使用；单独成类是为了让调用方写
/// `PfbFlagsSpec(gzip: true)` 而不是手算位或。
final class PfbFlagsSpec {
  const PfbFlagsSpec({
    this.gzip = false,
    this.hasAttachments = false,
    this.multiVolume = false,
    this.incremental = false,
  });

  final bool gzip;
  final bool hasAttachments;
  final bool multiVolume;
  final bool incremental;

  int get value => PfbFlags.of(
    gzip: gzip,
    hasAttachments: hasAttachments,
    multiVolume: multiVolume,
    incremental: incremental,
  );
}

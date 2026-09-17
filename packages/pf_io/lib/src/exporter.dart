/// 导出装配器：载荷 → GZIP → PFB 容器 → 读回自校验（§4.2）。
///
/// 规格 §4.2 伪代码中**不依赖文件系统与数据库**的部分全部在这里：
/// 载荷编码（[PfbPayloadEncoder]）、压缩（先压缩后加密，§3.3）、容器封包
/// （`PfbContainer.seal`，链式 AAD 与分块由容器层负责）、以及第 5 步的
/// **读回自校验**。文件落盘（临时文件 / fsync / rename / 分卷切分）是
/// M3 平台网关的事 —— 本类的产出是完整的 `.pfb` 字节，落盘方拿到即可写。
///
/// 自校验不是装饰。规格 T-清单里「导出文件损坏未被察觉」的代价是用户在
/// 数月后才发现备份打不开；所以 [PfbExportAssembler.assemble] 在返回前
/// 用与导入端**同一条解包路径**把文件读回来，任何一步失败都抛
/// `PFI_E_SELF_CHECK` —— 宁可当场失败重试，不留一个看似成功的坏文件。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';

import 'export_payload.dart';
import 'transfer.dart';

/// 装配结果。
final class ExportAssemblyResult {
  const ExportAssemblyResult({
    required this.fileBytes,
    required this.gzipBytes,
    required this.recordCount,
    required this.contentHashHex,
    required this.fileSha256Hex,
    required this.salt,
    required this.noncePrefix,
    required this.header,
    required this.verifiedByReadBack,
  });

  /// 完整 `.pfb` 文件字节（含头部 / 密文区 / 文件尾）。
  final Uint8List fileBytes;

  /// 压缩后、加密前的载荷（写入容器的明文）。
  final Uint8List gzipBytes;

  final int recordCount;
  final String contentHashHex;
  final String fileSha256Hex;

  /// 本次导出生成的 KDF 盐与 nonce 前缀（每次导出必须新生成，§4.2 第 2 步）。
  final Uint8List salt;
  final Uint8List noncePrefix;
  final PfbHeader header;

  /// 是否已通过读回自校验。**false 时调用方不得报告导出成功**（契约原文）。
  final bool verifiedByReadBack;
}

/// 导出装配器。
final class PfbExportAssembler {
  PfbExportAssembler({math.Random? random}) : _random = random ?? math.Random.secure();

  final math.Random _random;

  /// 载荷 → GZIP → 封包 → 读回自校验。
  ///
  /// [password] 为导出密码的 UTF-8 字节（与主密码无关，§3.1）；派生用
  /// [kdf]（默认 [exportKdfParams]）与本次新生成的盐。传入测试用
  /// [salt] / [noncePrefix] / [volumeSetId] 可获得字节级确定的输出
  /// （向量的「固定随机源」锚点）；缺省时用 [math.Random.secure] 生成。
  Future<ExportAssemblyResult> assemble({
    required PayloadBuildResult payload,
    required Uint8List password,
    Argon2Params kdf = exportKdfParams,
    bool includeAttachments = false,
    bool incremental = false,
    int chunkPlainSizeKiB = PfbFormat.defaultChunkPlainSizeKiB,
    Uint8List? salt,
    Uint8List? noncePrefix,
    Uint8List? volumeSetId,
  }) async {
    final actualSalt = salt ?? _randomBytes(PfbFormat.saltLength);
    final actualPrefix = noncePrefix ?? _randomBytes(PfbFormat.noncePrefixLength);
    final actualVolumeSetId = volumeSetId ?? _randomBytes(PfbFormat.volumeSetIdLength);

    // 1. 先压缩后加密（§3.3 GZIP 位置）。明文长度 = 压缩后长度。
    final gzipBytes = Uint8List.fromList(GZipCodec(level: 6).encode(payload.ndjsonBytes));

    // 2. 派生导出密钥 + 封包（分块 / 链式 AAD / contentDigest 都在容器层）。
    final key = await Argon2idDeriver.instance.derive(
      password: password,
      salt: actualSalt,
      params: kdf,
    );
    final fileBytes = await PfbContainer.seal(
      payload: gzipBytes,
      key: key,
      salt: actualSalt,
      noncePrefix: actualPrefix,
      kdf: kdf,
      flags: PfbFlagsSpec(
        gzip: true,
        hasAttachments: includeAttachments,
        multiVolume: false,
        incremental: incremental,
      ),
      chunkPlainSizeKiB: chunkPlainSizeKiB,
      volumeSetId: actualVolumeSetId,
    );

    // 3. 读回自校验（§4.2 第 5 步）：与导入端同一条解包路径。
    await _selfCheck(
      fileBytes: fileBytes,
      password: password,
      salt: actualSalt,
      kdf: kdf,
      expectedGzip: gzipBytes,
    );

    return ExportAssemblyResult(
      fileBytes: fileBytes,
      gzipBytes: gzipBytes,
      recordCount: payload.recordCount,
      contentHashHex: payload.contentHashHex,
      fileSha256Hex: Sha256.instance.hashHex(fileBytes),
      salt: actualSalt,
      noncePrefix: actualPrefix,
      header: PfbLayout.slice(fileBytes).header,
      verifiedByReadBack: true,
    );
  }

  Future<void> _selfCheck({
    required Uint8List fileBytes,
    required Uint8List password,
    required Uint8List salt,
    required Argon2Params kdf,
    required Uint8List expectedGzip,
  }) async {
    // 3.1 免密层：头部 CRC + contentDigest。
    final digestVerdict = PfbContainer.verifyContentDigest(fileBytes);
    if (!digestVerdict.matches) {
      throw ImportExportError.selfCheckFailed(reason: 'contentDigest 不符', cause: null);
    }
    // 3.2 解密层：完整解出并与压缩载荷逐字节比对。
    try {
      final key = await Argon2idDeriver.instance.derive(
        password: password,
        salt: salt,
        params: kdf,
      );
      final reopened = await PfbContainer.open(file: fileBytes, key: key);
      if (!_bytesEqual(reopened, expectedGzip)) {
        throw ImportExportError.selfCheckFailed(reason: '解密载荷与压缩载荷不一致');
      }
    } on PfError catch (e) {
      throw ImportExportError.selfCheckFailed(reason: '读回解密失败（${e.code}）', cause: e);
    }
  }

  Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}

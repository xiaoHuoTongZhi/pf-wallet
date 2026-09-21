/// 导入侧的文件读取与**三态错误分流**（§4.3 阶段 A–D）。
///
/// ## 为什么要有「三态」这一层
///
/// 底层能报的错很多（魔数不对 / 头部 CRC 不符 / KDF 参数越界 / 内容摘要不符 /
/// 分块认证失败 / 版本过高 …），但**用户能做的动作只有三种**：
/// 重新输一次密码、换一份文件、升级应用。因此导入层必须把这堆细节
/// 收敛成互斥且穷尽的三态（[ImportFailureKind.wrongPassword] /
/// `.corrupted` / `.versionIncompatible`），否则 UI 只能把原始错误码
/// 直接甩给用户 —— 而「分块认证失败」这句话对用户毫无意义。
///
/// ## 区分「损坏」与「密码错」的关键：先免密、后解密
///
/// 顺序不能反（§4.3 阶段 B 在阶段 C/D 之前）：
///
///   1. [PfbContainer.verifyContentDigest] **不需要密钥**，它覆盖全部块密文
///      （§3.3 的 `contentDigest = SHA256(kdfSalt‖noncePrefix‖全部块密文)`）。
///      摘要不符 ⇒ 密文字节已经不是当初封包时的字节 ⇒ **文件坏了**。
///   2. 摘要通过之后才派生密钥、解密首块。此时若是认证失败，只能是密码错 ——
///      因为「文件完好」已经被上一步证明过了（密文一个字节都没变）。
///
/// 这条推理有一个前提：**内容摘要必须覆盖会被重排/篡改的每一个字节**。
/// 块被交换或重排会改变密文的拼接顺序 ⇒ 摘要先变 ⇒ 落到「损坏」，
/// 不会伪装成「密码错」。因此三态互斥不是靠「尽量猜」，而是有结构保证的。
///
/// ## 与 §4.3 的一处口径冲突（已在实现中裁决）
///
/// 规格 §4.3 硬约束表写「GZIP 解压上限 = `head.plaintextLength`」。
/// 但按 §3.3 的容器格式，`plaintextLength` 是**容器明文长度**，
/// 在导出侧它等于 GZIP 流本身的长度（导出伪码第 3.2 步：`plainLen += n`
/// 累计的是压缩后写入的字节），并不是解压后的长度。两者互斥，
/// 因此本实现按 §3.3 解释，并把 zip bomb 防线换成**两道独立上限**：
/// 绝对上限 [kMaxDecompressedPayloadBytes] + 压缩比上限 [kMaxGzipRatio]。
/// 比值上限比「声明值」更可靠：声明值本身就是攻击者可控的输入。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';

import 'export_payload.dart';
import 'import_payload.dart';

/// 解压后载荷的绝对上限（512 MiB）。
///
/// 与 §4.3「单次导入记录数上限」同一精神：先给资源消耗一个天花板，
/// 再谈其它防线。
const int kMaxDecompressedPayloadBytes = 512 * 1024 * 1024;

/// 解压膨胀比上限。
///
/// 正常 NDJSON 的压缩比在 5–20 倍之间（附件是 Base64 文本，压缩比更低）。
/// 200 倍留了充分余量，同时让「几 KB 压成几十 GB」的构造立刻撞墙。
const int kMaxGzipRatio = 200;

/// 导入流程所处的阶段。**同一个低层错误码在不同阶段的含义不同**，
/// 所以三态分流必须知道阶段（例：`PFB_E_AUTH_FAILED` 在解密阶段是密码错；
/// 若出现在免密阶段，那只能是文件被改过）。
enum ImportStage {
  /// 阶段 A：只读头部，不解密。
  header,

  /// 阶段 B：无需密码的整文件完整性校验。
  integrity,

  /// 阶段 C/D：派生密钥并解密。
  decrypt,

  /// 载荷解析（阶段 D 之后）。
  payload,
}

/// 失败的种类（比三态细，比错误码粗）。
///
/// 保留细粒度不是为了给用户看，而是为了**排查方向**：
/// `notPfbFile` 要用户找回正确的文件，`corruptedHeader` 要看是不是被截断，
/// `suspiciousKdfParams` 是安全信号（可能被篡改）。三态只决定 UI 动作。
enum ImportFailureKind {
  /// 魔数不匹配 —— 这不是本应用导出的文件。
  notPfbFile('PFI_E_CORRUPT'),

  /// 头部结构/CRC 不自洽，或被截断。
  corruptedHeader('PFI_E_CORRUPT'),

  /// 免密内容摘要不符（或分块链认证失败）—— 文件确实坏了。
  corrupted('PFI_E_CORRUPT'),

  /// 头部声明了本实现不认识的特性位。
  unsupportedFeature('PFI_E_VERSION'),

  /// 头部 KDF 参数超出安全上限（可能被篡改）。
  suspiciousKdfParams('PFI_E_VERSION'),

  /// 容器格式或载荷版本高于本实现。
  versionIncompatible('PFI_E_VERSION'),

  /// 文件完好，但解不开 —— 只能是密码错。
  wrongPassword('PFI_E_WRONG_PASSWORD'),

  /// 载荷内容违反格式契约（schema / scope / contentHash）。
  payloadInvalid('PFC_E_VALIDATION'),

  /// 载荷内部/与本地库之间的引用悬空（txn 指向不存在的 account 等）。
  ///
  /// 用 `PFI_E_INCOMPATIBLE` 而不是 `PFC_E_VALIDATION`：这是**文件与这份库
  /// 合不到一起**，不是「文件格式不合法」。两者的用户动作相同（换一份文件），
  /// 但排查方向完全不同 —— 前者要去看库里缺了什么，后者要去看文件怎么写的。
  referenceMissing('PFI_E_INCOMPATIBLE'),

  /// 存在需要用户裁决的记录（同 id 但内容不同）—— 提交 B 的裁决表未落地前，
  /// 执行器不猜、不覆盖，整批中止。
  recordConflict('PFI_E_CONFLICT'),

  /// 导入前自动备份失败。
  backupFailed('PFI_E_BACKUP');

  const ImportFailureKind(this.code);

  /// 该种类对外呈现的错误码。
  final String code;

  /// 是否属于三态之一（UI 的三个动作）。
  bool get isTriaged => this == wrongPassword || this == corrupted || this == versionIncompatible;
}

/// 一次失败的分流结果。
final class ImportFailure {
  const ImportFailure({required this.kind, required this.detail, this.cause});

  final ImportFailureKind kind;

  /// 面向排查的细节（写进日志与错误对象）。
  final String detail;

  final Object? cause;

  String get code => kind.code;

  /// 转成领域错误 —— 三态各自的用户提示在 [ImportExportError] 里，不在这里。
  PfError toError() {
    switch (kind) {
      case ImportFailureKind.wrongPassword:
        return ImportExportError.wrongPassword(detail: detail);
      case ImportFailureKind.corrupted:
      case ImportFailureKind.corruptedHeader:
      case ImportFailureKind.notPfbFile:
        return ImportExportError.corrupted(detail: detail);
      case ImportFailureKind.versionIncompatible:
      case ImportFailureKind.unsupportedFeature:
      case ImportFailureKind.suspiciousKdfParams:
        return ImportExportError.versionIncompatible(detail: detail);
      case ImportFailureKind.backupFailed:
        return ImportExportError.backupFailed(detail: detail, cause: cause);
      case ImportFailureKind.referenceMissing:
        return ImportExportError.incompatible(detail: detail);
      case ImportFailureKind.recordConflict:
        // 不用具名工厂：`conflict({count})` 的文案带条数，而走到这里时
        // 条数已经丢在分流之前了。宁可用一句不带数字的真话。
        return const ImportExportError(
          code: PfErrorCode.ioConflict,
          message: '存在需要用户裁决的记录（同 id 但内容不同）',
          userMessage: '这份备份里有记录与你本地已有的记录内容不同，需要你确认保留哪一份。',
        );
      case ImportFailureKind.payloadInvalid:
        return DomainError.validation(
          detail: detail,
          userMessage: '这份导入文件的内容不合法（已停止处理，你的数据没有被修改）。',
        );
    }
  }

  @override
  String toString() => 'ImportFailure(${kind.name}: $detail)';
}

/// 三态分流：把「阶段 + 低层错误码」映射成 [ImportFailure]。
///
/// 刻意做成**纯函数**（与 `classifySqliteOpenError` 同一手法）：
/// 分流表是整个导入体验的分水岭 —— 判错一次，用户就会在「密码错」
/// 与「文件坏了」之间得到完全相反的指引。纯表函数可以被逐条锁死。
ImportFailure triageImportFailure({
  required ImportStage stage,
  required String code,
  required String detail,
  Object? cause,
}) {
  // 幂等前哨：若错误已经是三态之一，直接返回对应种类。
  // 这让本函数可以被反复调用（读文件时我们已经按阶段构造过三态错误，
  // 再分流一次不得把它改成别的态）。
  switch (code) {
    case PfErrorCode.ioWrongPassword:
      return ImportFailure(kind: ImportFailureKind.wrongPassword, detail: detail, cause: cause);
    case PfErrorCode.ioCorrupt:
      return ImportFailure(kind: ImportFailureKind.corrupted, detail: detail, cause: cause);
    case PfErrorCode.ioVersionIncompatible:
      return ImportFailure(
        kind: ImportFailureKind.versionIncompatible,
        detail: detail,
        cause: cause,
      );
  }
  switch (stage) {
    case ImportStage.header:
      switch (code) {
        case PfErrorCode.containerMagic:
          return ImportFailure(kind: ImportFailureKind.notPfbFile, detail: detail, cause: cause);
        case PfErrorCode.containerVersionUnsupported:
          return ImportFailure(
            kind: ImportFailureKind.versionIncompatible,
            detail: detail,
            cause: cause,
          );
        case PfErrorCode.containerTruncated:
        case PfErrorCode.containerHeaderInvalid:
          return ImportFailure(
            kind: ImportFailureKind.corruptedHeader,
            detail: detail,
            cause: cause,
          );
        case PfErrorCode.kdfParamsOutOfRange:
          return ImportFailure(
            kind: ImportFailureKind.suspiciousKdfParams,
            detail: detail,
            cause: cause,
          );
      }
    case ImportStage.integrity:
      // 免密阶段只可能得出一个结论：字节不对。这里没有密钥，
      // 「密码错」在这个阶段是不可观测的 —— 也就不会误报。
      return ImportFailure(kind: ImportFailureKind.corrupted, detail: detail, cause: cause);
    case ImportStage.decrypt:
      if (code == PfErrorCode.containerAuthFailed) {
        // 免密摘要已通过 ⇒ 密文与封包时逐字节相同 ⇒ 解不开只能是密钥不对。
        return ImportFailure(
          kind: ImportFailureKind.wrongPassword,
          detail: '$detail（文件完整性已通过，判定为密码错）',
          cause: cause,
        );
      }
      if (code == PfErrorCode.containerDigestMismatch ||
          code == PfErrorCode.containerTruncated ||
          code == PfErrorCode.containerHeaderInvalid) {
        return ImportFailure(kind: ImportFailureKind.corrupted, detail: detail, cause: cause);
      }
      if (code == PfErrorCode.containerVersionUnsupported) {
        return ImportFailure(
          kind: ImportFailureKind.versionIncompatible,
          detail: detail,
          cause: cause,
        );
      }
      if (code == PfErrorCode.ioVersionIncompatible) {
        return ImportFailure(
          kind: ImportFailureKind.versionIncompatible,
          detail: detail,
          cause: cause,
        );
      }
    case ImportStage.payload:
      if (code == PfErrorCode.ioVersionIncompatible) {
        return ImportFailure(
          kind: ImportFailureKind.versionIncompatible,
          detail: detail,
          cause: cause,
        );
      }
      if (code == PfErrorCode.validation) {
        return ImportFailure(kind: ImportFailureKind.payloadInvalid, detail: detail, cause: cause);
      }
  }
  // 未列入表的组合按「最保守的一态」兜底：报损坏。
  // 不往密码错上猜 —— 错误地让用户反复试密码，比让他换一份文件更糟。
  return ImportFailure(
    kind: ImportFailureKind.corrupted,
    detail: '[未分类 $code] $detail',
    cause: cause,
  );
}

/// 一次成功读取的结果。
final class ImportedFile {
  const ImportedFile({
    required this.fileBytes,
    required this.header,
    required this.fileSha256Hex,
    required this.payload,
    required this.payloadVersion,
    required this.fileName,
  });

  final Uint8List fileBytes;
  final PfbHeader header;

  /// 整文件字节的 SHA-256（幂等短路的键，§4.3 阶段 E）。
  final String fileSha256Hex;

  final DecodedPayload payload;
  final int payloadVersion;

  /// 用户看到的文件名（只用于记录，**不参与任何路径构造**）。
  final String fileName;

  /// manifest 里的计数（`counts`），供报告比对。
  Map<String, Object?> get manifestCounts {
    final raw = payload.manifest['counts'];
    return raw is Map<String, Object?> ? raw : const <String, Object?>{};
  }

  bool get isMultiVolume => header.volumeTotal > 1;
  bool get hasAttachments => (header.featureFlags & PfbFlags.bitHasAttachments) != 0;
  bool get isIncremental => (header.featureFlags & PfbFlags.bitIncremental) != 0;
}

/// 导入侧的文件读取器：容器 → 明文载荷（§4.3 阶段 A–D）。
///
/// 分卷（阶段 F）与预览/裁决（阶段 G）不在本类 —— 分卷是 M3 的文件网关，
/// 裁决是提交 B（§4.4）。本类只回答一个问题：
/// **这份文件是什么、里面的记录长什么样、或者它为什么读不出来。**
final class PfbImportReader {
  const PfbImportReader({this.maxFormatVersion, this.maxPayloadVersion = kPayloadVersion});

  /// 容器格式上限（缺省为本实现支持的版本）。
  final int? maxFormatVersion;

  final int maxPayloadVersion;

  Future<ImportedFile> read({
    required Uint8List fileBytes,
    required Uint8List password,
    required String fileName,
  }) async {
    // ── 阶段 A：头部（128 字节，不解密）──────────────────────────────────
    //
    // 先做两件**不解析**的廉价检查：魔数与特性位。理由不是性能，而是
    // 语义 —— 「这不像是本应用的文件」与「这文件用了本版本不认识的特性」
    // 是两种完全不同的处境，而它们都发生在 CRC 之前（§4.3 阶段 A 的顺序）。
    // 只靠捕获 PfbHeader.decode 的异常会在「魔数不对但第 12 字节恰好
    // 看起来像未知位」时给出错误指引。
    _requireMagic(fileBytes);
    _requireKnownFeatureFlags(fileBytes);

    final PfbHeader header;
    try {
      header = PfbHeader.decode(fileBytes, maxSupportedFormatVersion: maxFormatVersion);
    } on PfError catch (error) {
      throw _triage(ImportStage.header, error);
    }

    // ── 阶段 B：免密完整性（区分「损坏」与「密码错」的全部依据）──────────
    //
    // 这一步**必须**被包住：`verifyContentDigest` 对「文件短于 头+尾部」的情况
    // 抛的是低层码 `PFB_E_TRUNCATED`。让它直接冒泡出去，用户会收到一个
    // 低层错误码而不是三态之一 —— 那正是本文件存在的理由（把细节收敛成
    // 三种可执行的动作）。包住之后，所有「字节不对」都在这里归为「损坏」。
    final PfbContentDigestVerdict verdict;
    try {
      verdict = PfbContainer.verifyContentDigest(fileBytes);
    } on PfError catch (error) {
      throw _triage(ImportStage.integrity, error);
    }
    if (!verdict.matches) {
      throw _triage(
        ImportStage.integrity,
        ImportExportError.corrupted(
          detail: '免密内容摘要不符（声明 ${verdict.declaredHex}，实际 ${verdict.computedHex}）',
        ),
      );
    }

    // ── 阶段 C/D：派生密钥 → 解密 → 解压 → 解载荷 ────────────────────────
    final Uint8List plain;
    try {
      final key = await Argon2idDeriver.instance.derive(
        password: password,
        salt: header.salt,
        params: header.kdf,
      );
      plain = await PfbContainer.open(file: fileBytes, key: key);
    } on PfError catch (error) {
      throw _triage(ImportStage.decrypt, error);
    }

    final DecodedPayload payload;
    try {
      final ndjson = _gunzip(plain, header);
      payload = PfbPayloadDecoder.decode(ndjson);
    } on PfError catch (error) {
      throw _triage(ImportStage.payload, error);
    }

    final version = payload.manifest['payloadVersion'];
    if (version is! int) {
      throw _triage(
        ImportStage.payload,
        DomainError.validation(detail: 'manifest 缺少 payloadVersion'),
      );
    }
    if (version > maxPayloadVersion) {
      throw _triage(
        ImportStage.payload,
        ImportExportError.versionIncompatible(
          detail: '载荷版本 v$version 高于本实现支持的 v$maxPayloadVersion',
        ),
      );
    }

    return ImportedFile(
      fileBytes: fileBytes,
      header: header,
      fileSha256Hex: Sha256.instance.hashHex(fileBytes),
      payload: payload,
      payloadVersion: version,
      fileName: fileName,
    );
  }

  /// GZIP 解压（仅在头部声明了 gzip 时）。
  ///
  /// zip bomb 的两道上限见文件头说明。压缩比检查在解压**之后**做 ——
  /// 没有更早的观测点（GZIP 流不声明解压后长度），所以绝对上限同时兼任
  /// 「内存天花板」，必要时由 M3 换成流式解压。
  Uint8List _gunzip(Uint8List plain, PfbHeader header) {
    if (!header.flagGzip) {
      throw _triage(
        ImportStage.payload,
        DomainError.validation(detail: '本实现只支持 gzip 载荷（flagGzip 未置位）'),
      );
    }
    final List<int> inflated;
    try {
      inflated = GZipCodec().decode(plain);
    } on FormatException catch (error) {
      throw _triage(
        ImportStage.payload,
        ImportExportError.corrupted(detail: 'GZIP 解压失败：${error.message}'),
      );
    }
    if (inflated.length > kMaxDecompressedPayloadBytes) {
      throw _triage(
        ImportStage.payload,
        DomainError.validation(
          detail: '解压后 ${inflated.length} 字节，超过绝对上限 $kMaxDecompressedPayloadBytes',
        ),
      );
    }
    if (plain.isNotEmpty && inflated.length > plain.length * kMaxGzipRatio) {
      throw _triage(
        ImportStage.payload,
        DomainError.validation(
          detail:
              '解压膨胀比 ${inflated.length ~/ plain.length}× 超过上限 $kMaxGzipRatio×，'
              '疑似压缩炸弹',
        ),
      );
    }
    return inflated is Uint8List ? inflated : Uint8List.fromList(inflated);
  }

  PfError _triage(ImportStage stage, PfError error) {
    final failure = triageImportFailure(
      stage: stage,
      code: error.code,
      detail: error.message,
      cause: error,
    );
    return failure.toError();
  }

  /// 魔数检查（不解析头部）。
  void _requireMagic(Uint8List bytes) {
    if (bytes.length < pfbMagic.length) {
      throw _triage(
        ImportStage.header,
        ContainerError.truncated(expected: pfbMagic.length, actual: bytes.length),
      );
    }
    for (var i = 0; i < pfbMagic.length; i++) {
      if (bytes[i] != pfbMagic[i]) {
        throw _triage(ImportStage.header, ContainerError.magicMismatch());
      }
    }
  }

  /// 特性位检查（§4.3 阶段 A 的第三步）。
  ///
  /// 未知位意味着「导出方用了本版本没有的能力」，而**能力是安全的边界**：
  /// 顶层不能用「先忽略、看着办」的策略（那正是 C1/C2 对字段与记录类型
  /// 放宽的地方，与特性位不同：字段是数据，特性位是格式语义）。
  void _requireKnownFeatureFlags(Uint8List bytes) {
    if (bytes.length < PfbFormat.headerSize) {
      throw _triage(
        ImportStage.header,
        ContainerError.truncated(expected: PfbFormat.headerSize, actual: bytes.length),
      );
    }
    final flags =
        (bytes[PfbFormat.offsetFeatureFlags] << 8) | bytes[PfbFormat.offsetFeatureFlags + 1];
    final unknown = flags & ~PfbFlags.knownMask;
    if (unknown != 0) {
      throw _triage(
        ImportStage.header,
        ImportExportError.versionIncompatible(
          detail:
              '文件声明了本版本不支持的格式特性（位 0x${unknown.toRadixString(16)}）。'
              '拒绝按「忽略未知特性」处理 —— 那会把格式语义的差异当成数据差异。',
        ),
      );
    }
  }
}

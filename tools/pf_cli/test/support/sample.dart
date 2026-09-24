/// 仓库里**被向量锁死**的固定 `.pfb` 样本。
///
/// 这里刻意**不自造样本**，尽管那更容易写。理由是一条隐蔽的分叉：
/// `test_vectors/fixtures/import_samples.json` 里的 5 份 `.pfb` 由独立的
/// Python 生成器产出（以 hex 存放 —— `.pfb` 本体在 `tracked_paths` 的 deny
/// 名单上，落不了盘），并且**导入器 A/B 的向量用的就是它们**。
///
/// 拿它们当 CLI 的输入，等于让 CLI 的端到端验证与导入器验证**共用同一个
/// 事实源**：若 CLI 读得通而导入器读不通（或反过来），差异一定出在 CLI 这一层。
/// 反过来，若测试自己造样本，就有了一条「CLI 的样本恰好绕开了导入器的某个
/// 约束」的分叉 —— 而那种分叉只会在真实用户文件上暴露。
///
/// 这份文件同时记录了一个曾经的误判：自造样本用 `{'id': 'id-0'}` 当记录，
/// 在 `assemble` 的自校验里能过（那只做容器层读回），却过不了载荷解码
/// （`ledger` 行必须有 `name` 列）。CLI 的 verify 走的是**深**路径，
/// 所以它需要的样本比「能被封包」严格得多。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';

/// fixture 相对仓库根的位置。
const String kFixtureRelPath = 'test_vectors/fixtures/import_samples.json';

/// 一份固定样本。
final class VectorSample {
  const VectorSample({
    required this.id,
    required this.fileName,
    required this.fileBytes,
    required this.fileSha256,
    required this.payloadNdjson,
    required this.payloadNdjsonSha256,
    required this.recordCount,
    required this.counts,
    required this.exportKind,
    required this.contentHashHex,
    required this.hasAttachments,
  });

  final String id;
  final String fileName;
  final Uint8List fileBytes;

  /// 整文件 SHA-256 —— fixture 记的值，用来独立校验 CLI 打出的那个。
  final String fileSha256;

  /// **解压后**的 NDJSON 载荷字节 —— fixture 记的值。
  ///
  /// 注意 fixture 里那个键叫 `payloadNdjsonHex` / `payloadSha256`，
  /// 而容器明文（§3.3 里那颗 gzip 流）**没有**记在 fixture 里：
  /// 那是容器层的中间产物，fixture 只记入参（文件字节）与最终产物（载荷）。
  /// 于是跨实现校验的第 2 层没有第三方锚点，只由「两套实现的 diff 为空」绑定 ——
  /// 这正是第 2 层与第 1、3 层的分工差别。
  final Uint8List payloadNdjson;

  /// NDJSON 载荷的 SHA-256 —— fixture 记的值（跨实现校验第 3 层的独立锚点）。
  final String payloadNdjsonSha256;

  /// 载荷里的记录条数（fixture 记录的值，不是被测代码算出来的）。
  final int recordCount;

  /// manifest 声明的逐表条数 —— verify 的预期值来自这里。
  final Map<String, Object?> counts;

  final String exportKind;

  /// 载荷的 contentHash（十六进制，**不含** `sha256:` 前缀）—— fixture 记的值。
  final String contentHashHex;

  /// manifest 是否声明含附件（用于与头部标志位对照）。
  final bool hasAttachments;

  /// 改一个字节：仍是合法头部，但内容摘要会不符。
  ///
  /// 偏移取 130 —— 在 128 字节头部**之后**（头部与它的 CRC 都不受影响），
  /// 又在第一个块的密文里（内容摘要必然变）。于是 `inspect()` 成功、
  /// `isIntact` 为 false，正是「传输中断 / 被改了一字节」的样子。
  VectorSample withTamperedCiphertext() => _copyWith((bytes) => bytes[130] ^= 0x01);

  /// 把魔数改坏 —— 「这不是本应用的文件」。
  VectorSample withBrokenMagic() => _copyWith((bytes) => bytes[0] ^= 0xFF);

  /// 把头部 CRC 字段改坏 —— 头部自相矛盾。
  VectorSample withBrokenHeaderCrc() =>
      _copyWith((bytes) => bytes[PfbFormat.offsetHeaderCrc32] ^= 0xFF);

  /// 置一个本实现不认识的特性位 —— 理由应是「版本/特性不兼容」，
  /// 而不是「文件坏了」。两者的用户动作不同，必须分得开。
  VectorSample withUnknownFeatureFlag() =>
      _copyWith((bytes) => bytes[PfbFormat.offsetFeatureFlags + 1] |= 0x80);

  /// 只留前 [length] 字节。
  VectorSample truncatedTo(int length) => _copyWith((_) {}, keep: length);

  VectorSample _copyWith(void Function(Uint8List bytes) mutate, {int? keep}) {
    final copy = Uint8List.fromList(fileBytes);
    mutate(copy);
    return VectorSample(
      id: id,
      fileName: fileName,
      fileBytes: keep == null ? copy : Uint8List.fromList(copy.sublist(0, keep)),
      // 变体改了字节 ⇒ 原来的 SHA 不再适用，标记成空串表明「这份没有预期值」。
      fileSha256: '',
      // 载荷没动（变体只改容器层的字节）⇒ 载荷侧的预期值照旧有效。
      payloadNdjson: payloadNdjson,
      payloadNdjsonSha256: payloadNdjsonSha256,
      recordCount: recordCount,
      counts: counts,
      exportKind: exportKind,
      contentHashHex: contentHashHex,
      hasAttachments: hasAttachments,
    );
  }
}

/// 整个 fixture。
final class VectorFixture {
  const VectorFixture({required this.password, required this.wrongPassword, required this.samples});

  /// 正确的密码。
  final String password;

  /// 一份内容不同的密码 —— 用来证明「密码错」与「文件坏」分得开。
  final String wrongPassword;

  final Map<String, VectorSample> samples;

  /// `full` 导出：11 条记录、含内联附件、含一个软删账户。
  VectorSample get full => sample('sample-full');

  /// `incremental` 导出：只含 1 条交易。
  VectorSample get incremental => sample('sample-incremental');

  /// 写入编排的最小样本：1 账本 + 2 账户 + 1 转账。
  VectorSample get minimal => sample('sample-apply-minimal');

  VectorSample sample(String id) {
    final found = samples[id];
    if (found == null) {
      throw StateError('fixture 里没有样本 $id（有的是 ${samples.keys.join(', ')}）');
    }
    return found;
  }
}

/// 从仓库里加载 fixture。
///
/// **向上搜索**而不是写死相对路径：测试进程的工作目录取决于从哪里调用
/// `dart test`（包目录或仓库根），写死任一种都会在另一种下失效。
VectorFixture loadVectorFixture() {
  final file = locateFixture();
  final decoded = (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
  final rawSamples = (decoded['samples']! as List).cast<Map<String, Object?>>();
  final password = decoded['password']! as String;

  return VectorFixture(
    password: password,
    wrongPassword: decoded['wrongPassword']! as String,
    samples: <String, VectorSample>{
      for (final raw in rawSamples) raw['id']! as String: _buildSample(raw),
    },
  );
}

VectorSample _buildSample(Map<String, Object?> raw) {
  final manifest = (raw['manifest'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
  return VectorSample(
    id: raw['id']! as String,
    fileName: raw['fileName']! as String,
    fileBytes: fromHex(raw['fileHex']! as String),
    fileSha256: raw['fileSha256']! as String,
    payloadNdjson: fromHex(raw['payloadNdjsonHex']! as String),
    payloadNdjsonSha256: raw['payloadSha256']! as String,
    recordCount: raw['recordCount']! as int,
    counts: (manifest['counts'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{},
    exportKind: raw['exportKind']! as String,
    // fixture 把它写成 `sha256:<hex>`，而 CLI 打出的是裸 hex —— 在装载时
    // 就统一成裸 hex，免得每条断言都去剥前缀（剥漏一次就是一条假的失败）。
    contentHashHex: (raw['contentHash']! as String).replaceFirst('sha256:', ''),
    hasAttachments: manifest['includesAttachments'] == true,
  );
}

/// 向上找 [kFixtureRelPath]，最多 6 层。
File locateFixture() {
  var dir = Directory.current;
  for (var depth = 0; depth < 6; depth++) {
    final candidate = File('${dir.path}${Platform.pathSeparator}$kFixtureRelPath');
    if (candidate.existsSync()) {
      return candidate;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      break;
    }
    dir = parent;
  }
  throw StateError(
    '找不到 $kFixtureRelPath（从 ${Directory.current.path} 向上找了 6 层）。'
    '这份 fixture 是 CLI 端到端测试的输入，必须在仓库里。',
  );
}

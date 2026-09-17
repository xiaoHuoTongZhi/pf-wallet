/// 导出载荷（NDJSON）编码器 —— 规格 §3.2 / §4.2 3.3–3.5。
///
/// 职责单一：把「调用方给出的各阶段记录」编成**字节确定**的 NDJSON 载荷。
/// 字节确定不是审美问题 —— manifest 的 `contentHash` 覆盖全部非 manifest 行，
/// 行序或序列化的任何漂移都会让它失配；导入端拿它做载荷完整性裁决。
///
/// 三条硬规则（全部被 `export_payload` 向量锁死，期望值由
/// `tools/golden_vectors_gen/export_payload.py` 独立实现生成）：
///
///   1. **行序 = manifest → 按 [kPayloadStageOrder] 的记录行 → end**。
///      父实体先行（ledger → account → category → tag → theme → txn →
///      budget → attachment），保证导入时引用已存在。
///   2. **contentHash = SHA256(全部记录行的 UTF-8 字节，按出现顺序)**。
///      规格原文写「覆盖所有非 manifest 行」，但 end 行自身携带同一哈希 ——
///      若把 end 也算进覆盖，就是自指。因此口径固定为「记录行」
///      （2026-09-17 裁决）：manifest 与 end 均不在覆盖内；
///      end 行携带同一哈希与 recordCount，供导入端流式解析到最后一行时
///      与实际累计值比对。
///   3. **manifest 的 contentHash 由本编码器注入**。调用方给的 manifest 若已
///      含该键一律拒绝 —— 允许传入等于允许伪造。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';

/// 记录行的输出阶段与顺序（§4.2 3.4 的 `kExportStageOrder`）。
///
/// 行序是**载荷格式契约**的一部分：导入端按行流式解析、逐条 upsert，
/// 乱序载荷会让「txn 引用尚未导入的 account」这类引用悬空。
/// 行内 JSON 对象的键序不在契约内（C1 规则：未知字段/键序差异必须容忍），
/// 但编码器输出是确定的（Map 插入序），这只是为了字节级可比，不是承诺。
const List<String> kPayloadStageOrder = <String>[
  'ledger',
  'account',
  'category',
  'tag',
  'theme',
  'txn',
  'budget',
  'attachment',
];

/// manifest.exportKind 的合法取值（§3.2）。
const Set<String> kPayloadExportKinds = <String>{'full', 'range', 'ledger', 'incremental'};

/// 载荷格式版本（与容器 formatVersion 独立演进，§3.2）。
const int kPayloadVersion = 1;

/// 编码结果。
final class PayloadBuildResult {
  const PayloadBuildResult({
    required this.ndjsonBytes,
    required this.recordCount,
    required this.contentHashHex,
  });

  /// 完整载荷：manifest 行 → 记录行 → end 行，每行 `\n` 结尾的 UTF-8。
  final Uint8List ndjsonBytes;

  /// 记录行条数（不含 manifest 与 end）。
  final int recordCount;

  /// contentHash 的十六进制（小写，不带 `sha256:` 前缀）。
  final String contentHashHex;
}

/// NDJSON 载荷编码器。
abstract final class PfbPayloadEncoder {
  /// 把 [stages]（键为 [kPayloadStageOrder] 中的阶段名）编成载荷。
  ///
  /// [manifest] 必须含 `type: "manifest"`，且**不得**已含 `contentHash`；
  /// 缺 `exportKind` 或取值非法、或 scope 专属字段缺失 → `PFC_E_VALIDATION`。
  /// [generatedAtMilliseconds] 是 end 行的 `generatedAt`（显式传入，编码器
  /// 不读时钟 —— 载荷必须可复现）。
  static PayloadBuildResult encode({
    required Map<String, Object?> manifest,
    required Map<String, List<Map<String, Object?>>> stages,
    required int generatedAtMilliseconds,
  }) {
    _validateManifest(manifest);
    for (final stage in stages.keys) {
      if (!kPayloadStageOrder.contains(stage)) {
        throw DomainError.validation(detail: '未知的载荷阶段：$stage');
      }
    }

    // 1. 先编记录行并累计 contentHash（manifest 要携带它，只能后置）。
    //    记录行整体缓冲后一次求摘要 —— M1 载荷本就整体在内存中；
    //    流式分块化（大文件恒定内存）是 M3 接文件网关时的事，届时换
    //    Digest 的分块接口，规则不变。
    final records = BytesBuilder();
    var recordCount = 0;
    for (final stage in kPayloadStageOrder) {
      final rows = stages[stage] ?? const <Map<String, Object?>>[];
      for (final fields in rows) {
        records.add(_encodeLine(<String, Object?>{'type': stage, ...fields}));
        recordCount++;
      }
    }
    final recordBytes = records.toBytes();
    final contentHashHex = Sha256.instance.hashHex(recordBytes);

    // 2. manifest 行（补 payloadVersion / contentHash）。
    final manifestLine = _encodeLine(<String, Object?>{
      ...manifest,
      'payloadVersion': kPayloadVersion,
      'contentHash': 'sha256:$contentHashHex',
    });

    // 3. end 行。
    final endLine = _encodeLine(<String, Object?>{
      'type': 'end',
      'recordCount': recordCount,
      'contentHash': 'sha256:$contentHashHex',
      'generatedAt': generatedAtMilliseconds,
    });

    final out =
        BytesBuilder()
          ..add(manifestLine)
          ..add(recordBytes)
          ..add(endLine);
    return PayloadBuildResult(
      ndjsonBytes: out.toBytes(),
      recordCount: recordCount,
      contentHashHex: contentHashHex,
    );
  }

  static void _validateManifest(Map<String, Object?> manifest) {
    if (manifest['type'] != 'manifest') {
      throw DomainError.validation(detail: 'manifest 行的 type 必须是 manifest');
    }
    if (manifest.containsKey('contentHash')) {
      throw DomainError.validation(
        detail: 'manifest 不得自带 contentHash（由编码器注入，防止伪造）',
        userMessage: '导出数据内部不一致，已中止。',
      );
    }
    final kind = manifest['exportKind'];
    if (kind is! String || !kPayloadExportKinds.contains(kind)) {
      throw DomainError.validation(detail: 'manifest.exportKind 非法：$kind');
    }
    // scope 专属字段的存在性在编码期就拦（§4.2 第 0 步「前置校验」的载荷侧）。
    switch (kind) {
      case 'range':
        if (manifest['range'] is! Map<String, Object?>) {
          throw DomainError.validation(detail: 'exportKind=range 必须携带 range');
        }
      case 'ledger':
        final ids = manifest['ledgerIds'];
        if (ids is! List<Object?> || ids.isEmpty) {
          throw DomainError.validation(detail: 'exportKind=ledger 必须携带非空 ledgerIds');
        }
      case 'incremental':
        if (manifest['changeLogRange'] is! Map<String, Object?>) {
          throw DomainError.validation(detail: 'exportKind=incremental 必须携带 changeLogRange');
        }
        if (manifest['sinceExportAt'] is! int) {
          throw DomainError.validation(detail: 'exportKind=incremental 必须携带 sinceExportAt');
        }
    }
  }

  static Uint8List _encodeLine(Map<String, Object?> line) {
    // 先白名单校验再序列化：jsonEncode 对不可序列化值抛的是
    // JsonUnsupportedObjectError（Error 子类，禁止捕获）—— 与其压制 lint，
    // 不如把「能不能编码」变成显式的前置校验，报 PFC_E_VALIDATION。
    _ensureJsonable(line, 0);
    return Uint8List.fromList(utf8.encode('${jsonEncode(line)}\n'));
  }

  static void _ensureJsonable(Object? value, int depth) {
    if (value == null || value is String || value is bool || value is num) {
      return;
    }
    if (depth >= 32) {
      throw DomainError.validation(detail: '载荷嵌套深度超过 32', userMessage: '导出数据内部不一致，已中止。');
    }
    if (value is Map<Object?, Object?>) {
      for (final child in value.values) {
        _ensureJsonable(child, depth + 1);
      }
      return;
    }
    if (value is List<Object?>) {
      for (final child in value) {
        _ensureJsonable(child, depth + 1);
      }
      return;
    }
    throw DomainError.validation(
      detail: '载荷含不可 JSON 序列化的值：${value.runtimeType}',
      userMessage: '导出数据内部不一致，已中止。',
    );
  }
}

/// M1 驱动：导出载荷 NDJSON（规格 §3.2 / §4.2 3.3–3.5）。
///
/// 期望值由 `tools/golden_vectors_gen/export_payload.py`（Python 标准库
/// json / hashlib）独立生成。本驱动把向量输入喂给 `PfbPayloadEncoder`，
/// 逐字节比对载荷十六进制、recordCount 与 contentHash —— 行序、manifest
/// 注入位置、end 行字段任何一处漂移都会在这里现形。
library;

import 'package:pf_core/pf_core.dart';
import 'package:pf_io/pf_io.dart';

import '../driver.dart';
import '../json_util.dart';
import '../outcome.dart';

final class ExportPayloadNdjsonDriver extends VectorDriver {
  const ExportPayloadNdjsonDriver();

  @override
  String get kind => 'export.payload.ndjson';

  @override
  String get description => '按 §3.2 编码 NDJSON 载荷：行序 / contentHash 注入 / end 行';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'manifest': 'manifest 行字段（不得自带 contentHash / payloadVersion）',
    'stages': '{阶段名: [记录字段]}，阶段名 ∈ kPayloadStageOrder',
    'generatedAt': 'end 行的 generatedAt（epoch 毫秒）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final manifest = requireMap(input, 'manifest', kind);
    final stagesRaw = requireMap(input, 'stages', kind);
    final stages = <String, List<Map<String, Object?>>>{};
    for (final entry in stagesRaw.entries) {
      final rows = requireList(stagesRaw, entry.key, '$kind.stages');
      final list = <Map<String, Object?>>[];
      for (var i = 0; i < rows.length; i++) {
        final row = rows[i];
        if (row is! Map<String, Object?>) {
          throwVectorInput('$kind.stages.${entry.key}[$i]', '记录必须是 JSON 对象');
        }
        list.add(row);
      }
      stages[entry.key] = list;
    }
    final result = PfbPayloadEncoder.encode(
      manifest: manifest,
      stages: stages,
      generatedAtMilliseconds: requireInt(input, 'generatedAt', kind),
    );
    return VectorOutcome.value(<String, Object?>{
      'ndjsonHex': toHex(result.ndjsonBytes),
      'recordCount': result.recordCount,
      'contentHashHex': result.contentHashHex,
    });
  }
}

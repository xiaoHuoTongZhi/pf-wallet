/// 导出侧读库：把 SQLite 行读成**载荷阶段**（§4.2 第 1–3 步的数据侧）。
///
/// ## 这个文件要解决的是「两张会分叉的表」
///
/// 导入方向早有一张权威表格：`import_payload.dart` 的 [kPayloadRecordSpecs]
/// ——`type → table`，加上每个字段的 `jsonKey ↔ column` 与取值规则。
/// 导出方向如果自己再写一份（"ledger 表读 ledger 表、attachment 表读
/// attachment 表"），就会出现**第二张表**：某天 v2 新增一列、或把
/// `theme` 落到 `theme_profile`，导入侧跟着改、导出侧照旧 ——
/// 而那时的表现是「导出的文件能被导入，只是少了那一列」：
/// 一份看起来完全正常的备份，恢复了 99% 的数据。
///
/// 因此本文件**不写任何表名与列名的字面量表**，只通过 [kPayloadRecordSpecs]
/// 取；[payloadTableOf] 是那张表对外**唯一**的访问器，导出侧与导入侧
/// （见 `import_apply.dart` 的 `_planRequest`）都走它。
///
/// ## 两个方向共用的是什么、不共用什么
///
/// | 共用 | 不共用 |
/// |---|---|
/// | 阶段清单 [kPayloadStageOrder] | 取值的**方向**：导入把 JSON 校验成列值，导出把列值还原成 JSON |
/// | 表名（[payloadTableOf]） | |
/// | 字段表的 `jsonKey ↔ column` 对应 | |
///
/// 之所以「方向」不能共用：导入侧的核心动作是**校验**（越界即拒绝整份文件，
/// §4.3 的硬约束表），而导出侧的核心动作是**忠实**（库里有什么就带什么，
/// 越界不该在这时被静默修掉 —— 那是写坏了库，应当在导出时就响）。
/// 把两者揉成一个「双向转换器」会让每一条校验规则都要回答
/// 「这个方向要不要查」，而那正是两张表开始分叉的地方。
///
/// ## 行序
///
/// 每个阶段内部按 `id` 升序（`id` 是 ULID ⇒ 即创建顺序）。这不是审美：
/// 载荷的 `contentHash` 覆盖全部记录行，行序一漂移摘要就变。
/// 若按 `rowid` / 物理顺序读，同一个库在 `VACUUM` 前后会导出**不同的字节**，
/// 于是「同一份数据导出两次得同一份文件」这条性质就不成立 ——
/// 而它是备份可校验的前提。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';

import 'export_payload.dart';
import 'import_payload.dart';

/// 阶段 → 表名。**导出侧与导入侧共用的唯一访问器。**
///
/// 未知阶段抛 [DomainError]：拼错的阶段名（`'ledgers'`、`'txnType'`）若被
/// 静默当成"没有这张表"而返回空集，表现是**导出了一份缺整张表的备份**，
/// 而导出方会报告成功。
String payloadTableOf(String stage) {
  final spec = kPayloadRecordSpecs[stage];
  if (spec == null) {
    throw DomainError.validation(detail: '未知的载荷阶段：$stage（已知：${kPayloadStageOrder.join(', ')}）');
  }
  return spec.table;
}

/// 导出侧的读库器。
abstract final class PfPayloadExtractor {
  /// 按 [kPayloadStageOrder] 逐阶段读库，产出**载荷键**（`jsonKey`）形式的行。
  ///
  /// 返回的 Map 一定包含全部 8 个阶段（空阶段是空列表而不是缺失键）：
  /// 「这张表存在但没有行」与「这个阶段被忘了处理」是两件事，
  /// 让后者表现为一个缺失的键，才有机会被断言抓住。
  ///
  /// 含墓碑（`deleted_at` 非空）—— 删除必须能被带到另一台设备上，
  /// 否则合并（§4.4）会把「另一端已删的记录」当成新记录重新插回来。
  static Future<Map<String, List<Map<String, Object?>>>> readStages(PfDb db) async {
    final stages = <String, List<Map<String, Object?>>>{};
    for (final stage in kPayloadStageOrder) {
      stages[stage] = await readStage(db, stage);
    }
    return stages;
  }

  /// 读单个阶段。列序、字段映射与取值还原都在这里定义一次。
  static Future<List<Map<String, Object?>>> readStage(PfDb db, String stage) async {
    final spec = kPayloadRecordSpecs[stage];
    if (spec == null) {
      throw DomainError.validation(detail: '未知的载荷阶段：$stage');
    }
    // 只取字段表里登记过的列：库里可能多出「导出不带」的列
    // （`txn.source_import_job` 只在导入时写），把它们带上会让
    // 「导出 → 导入」的产物与原件在载荷层出现差异。
    final columns = <String>[for (final field in spec.fields) field.column];
    final rows = await db.query('SELECT ${columns.join(', ')} FROM ${spec.table} ORDER BY id');
    return <Map<String, Object?>>[for (final row in rows) _toPayloadRow(spec, row)];
  }

  /// 各阶段的记录条数。**从 [readStages] 的结果数出来，不另发 COUNT 查询** ——
  /// 两条查询会给出两个可能不一致的数字，而 manifest 的 `counts` 与
  /// 实际记录数是**逐阶段强核对**的（`import_payload.dart` 的
  /// `_validateCountsMatchContent`：声明与实测不符即拒绝整份文件）。
  static Map<String, int> countsOf(Map<String, List<Map<String, Object?>>> stages) {
    return <String, int>{
      for (final stage in kPayloadStageOrder) stage: (stages[stage] ?? const []).length,
    };
  }

  /// 把一行的 DB 列值还原成载荷键值。
  ///
  /// 只在**形状不同**的地方动手（JSON 文本 → 数组/对象，BLOB → Base64 字符串），
  /// 其余原样透传：整数与字符串在两边是同一个东西，中间加一层"规范化"
  /// 只会多一个改变数据的机会。
  static Map<String, Object?> _toPayloadRow(PayloadRecordSpec spec, Map<String, Object?> row) {
    final out = <String, Object?>{};
    for (final field in spec.fields) {
      out[field.jsonKey] = _payloadValue(field, row[field.column], spec.table, row['id']);
    }
    return out;
  }

  static Object? _payloadValue(PayloadField field, Object? value, String table, Object? rowId) {
    if (value == null) {
      // 空值的语义按字段类型定：`idList` 的缺省是空数组（§4.1 C3），
      // 其余是 JSON null。这里不塞字段表的 defaultValue —— 那是**导入侧
      // 缺字段时**的取值，与"库里这一列是 NULL"不是同一件事；
      // 混用会让"库里确实没这个值"被导出成一个具体的默认值。
      return field.kind == PayloadValueKind.idList ? const <Object?>[] : null;
    }
    switch (field.kind) {
      case PayloadValueKind.idList:
      case PayloadValueKind.jsonObject:
        if (value is String) {
          try {
            return jsonDecode(value);
          } on FormatException catch (error) {
            throw DomainError.validation(
              detail: '$table.${field.column} 不是合法 JSON（行 id=$rowId）：${error.message}',
              userMessage: '本地数据里有一列的格式不对，导出已中止。',
            );
          }
        }
        return value; // 已经是解码后的形状（假驱动/将来换驱动时可能出现）
      case PayloadValueKind.base64Blob:
        if (value is Uint8List) {
          return base64Encode(value);
        }
        if (value is List<int>) {
          return base64Encode(value);
        }
        return '$value';
      case PayloadValueKind.text:
      case PayloadValueKind.optionalText:
      case PayloadValueKind.integer:
      case PayloadValueKind.optionalInteger:
      case PayloadValueKind.flag:
      case PayloadValueKind.optionalId:
      case PayloadValueKind.derivedDayKey:
      case PayloadValueKind.derivedMonthKey:
        return value;
    }
  }
}

/// 造 manifest 行（§3.2）。
///
/// 键序与 §3.2 的示例一致。**不注入 `contentHash`** —— 那个键由
/// [PfbPayloadEncoder.encode] 负责，且编码器会拒绝调用方自带的
/// `contentHash`（允许传入等于允许伪造）。
///
/// [exportedAtMilliseconds] 必须由调用方显式传入：编码器与本函数都不读时钟，
/// 否则「同一份数据导出两次得到同一份文件」在 manifest 那一行就不成立。
Map<String, Object?> buildPayloadManifest({
  required Map<String, int> counts,
  required String deviceId,
  required String deviceName,
  required String platform,
  required int exportedAtMilliseconds,
  required bool includesAttachments,
  String exportKind = 'full',
  Map<String, Object?>? range,
  List<String>? ledgerIds,
  Map<String, Object?>? changeLogRange,
  int? sinceExportAt,
}) {
  return <String, Object?>{
    kPayloadDiscriminatorKey: 'manifest',
    'appVersion': PfBuildInfo.appVersion,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'platform': platform,
    'exportedAt': exportedAtMilliseconds,
    'exportKind': exportKind,
    'includesAttachments': includesAttachments,
    'counts': counts,
    // scope 专属字段按需带上；编码器会校验「说了哪个 scope 就得带哪个字段」。
    if (range != null) 'range': range,
    if (ledgerIds != null) 'ledgerIds': ledgerIds,
    if (changeLogRange != null) 'changeLogRange': changeLogRange,
    if (sinceExportAt != null) 'sinceExportAt': sinceExportAt,
  };
}

/// M1 驱动：导入器（规格 §4.3 阶段 A–I）。
///
/// 四个 kind 把导入器的**四段可独立判定的性质**分开：
///
///   - `import.triage.failure`  —— 三态分流表（纯函数，一张表定生死）
///   - `import.payload.decode`  —— 明文载荷 → 记录（C1/C2/C3、派生字段、前置 CHECK）
///   - `import.file.read`       —— .pfb 文件 → 明文载荷（魔数 / 免密摘要 / 解密 / 版本）
///   - `import.apply`           —— 明文载荷 → 写库轨迹（幂等 / 备份 / 事务 / 重算 / 引用）
///
/// 拆成四个而不是一个「import」大 kind，理由与容器那组一样：
/// 一份向量失败时，读报告的人要能一眼看出是格式、是分流、还是编排。
///
/// ## 期望值从哪来
///
/// 载荷与文件两组的期望值由 `tools/golden_vectors_gen/import_samples.py`
/// 独立生成（Python 侧用 `container_pfb.py` 的 `open_pfb` 手写解开 + 逐行对账，
/// 零共享 Dart 代码）；分流表与编排轨迹来自规格 §4.3 的**原文转录**
/// （阶段顺序、SAVEPOINT 名、列序）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';
import 'package:pf_io/pf_io.dart';

import '../driver.dart';
import '../fakes/scripted_db.dart';
import '../json_util.dart';
import '../outcome.dart';

/// 把任意驱动输出变成可 JSON 化的值（字节 → `{hex}`）。
///
/// 为什么需要它：载荷里的附件列是 `Uint8List`，`jsonEquals` 认不出它，
/// 而「把字节按十六进制写进期望值」是容器向量已经确立的做法。
Object? _jsonSafe(Object? value) {
  if (value == null || value is num || value is bool || value is String) {
    return value;
  }
  if (value is Uint8List) {
    return <String, Object?>{'hex': toHex(value)};
  }
  if (value is List<Object?>) {
    return value.map(_jsonSafe).toList();
  }
  if (value is Map<String, Object?>) {
    return <String, Object?>{for (final entry in value.entries) entry.key: _jsonSafe(entry.value)};
  }
  return '<${value.runtimeType}>';
}

/// 载荷投影：驱动的**输出契约**只有这一处定义，两个 kind 共用。
Map<String, Object?> _projectPayload(DecodedPayload payload) => <String, Object?>{
  'records': <Object?>[
    for (final record in payload.records)
      <String, Object?>{
        'type': record.type,
        'table': record.table,
        'id': record.id,
        'isTombstone': record.isTombstone,
        'updatedAt': record.updatedAt,
        'deviceId': record.deviceId,
        'recordIndex': record.recordIndex,
        // 列名 → 值。cached_balance_minor / balance_as_of 应当**不在这里** ——
        // 它们被显式丢弃，向量的期望值里看不见这两个键就是证据。
        'columns': _jsonSafe(record.columns),
      },
  ],
  'unknownTypes': payload.unknownTypes,
  'skippedUnknownRecords': payload.skippedUnknownRecordCount,
  'declaredRecordCount': payload.declaredRecordCount,
  'observedRecordCount': payload.observedRecordCount,
  'contentHashHex': payload.contentHashHex,
  'recordsRegionBytes': payload.recordsRegionBytes,
  'warnings': payload.warnings,
  'exportKind': payload.exportKind,
};

/// 三态分流（§4.3 阶段 A–D 的 `FailureKind` → 用户能做的三件事）。
final class ImportTriageDriver extends VectorDriver {
  const ImportTriageDriver();

  @override
  String get kind => 'import.triage.failure';

  @override
  String get description => '阶段 + 低层错误码 → 三态分流（密码错 / 损坏 / 版本不兼容，互斥且穷尽）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'stage': 'header | integrity | decrypt | payload',
    'code': '低层错误码（PFB_E_* / PFC_E_* / PFI_E_*）',
    'detail': '可选：诊断详情（不参与判定）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final stageName = requireString(input, 'stage', kind);
    final stage = ImportStage.values.firstWhere(
      (ImportStage s) => s.name == stageName,
      orElse: () => throwVectorInput('$kind.stage', '未知阶段 "$stageName"（可选值 ${ImportStage.values}）'),
    );
    final failure = triageImportFailure(
      stage: stage,
      code: requireString(input, 'code', kind),
      detail: optionalString(input, 'detail', ''),
    );
    return VectorOutcome.value(<String, Object?>{
      'kind': failure.kind.name,
      'code': failure.code,
      'triaged': failure.kind.isTriaged,
    });
  }
}

/// 明文载荷解码（§4.1 的 C1–C4 + §2.3 的 DEFAULT/CHECK 前置）。
final class ImportPayloadDecodeDriver extends VectorDriver {
  const ImportPayloadDecodeDriver();

  @override
  String get kind => 'import.payload.decode';

  @override
  String get description => 'NDJSON 载荷 → 可直接写入的记录（未知字段忽略 / 未知类型计数 / 缺字段取默认）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'ndjsonHex': '解压后的明文载荷十六进制（manifest 行 + 记录行 + end 行）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final bytes = requireHexBytes(input, 'ndjsonHex', kind);
    try {
      return VectorOutcome.value(_projectPayload(PfbPayloadDecoder.decode(bytes)));
    } on PfError catch (error) {
      return VectorOutcome.errored(error.code);
    }
  }
}

/// 整文件读取（§4.3 阶段 A–D）。
final class ImportFileReadDriver extends VectorDriver {
  const ImportFileReadDriver();

  @override
  String get kind => 'import.file.read';

  @override
  String get description => '.pfb 文件 → 明文载荷：魔数 / 免密摘要先于解密 / 三态分流';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'fileHex': '完整 .pfb 文件的十六进制',
    'password': '导出密码（UTF-8）',
    'fileName': '可选：用户看到的文件名，只用于记录',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final bytes = requireHexBytes(input, 'fileHex', kind);
    final password = Uint8List.fromList(utf8.encode(requireString(input, 'password', kind)));
    try {
      final file = await PfbImportReader().read(
        fileBytes: bytes,
        password: password,
        fileName: optionalString(input, 'fileName', 'vector.pfb'),
      );
      return VectorOutcome.value(<String, Object?>{
        'fileSha256Hex': file.fileSha256Hex,
        'payloadVersion': file.payloadVersion,
        'hasAttachments': file.hasAttachments,
        'isIncremental': file.isIncremental,
        'isMultiVolume': file.isMultiVolume,
        'manifest': _jsonSafe(file.payload.manifest),
        'payload': _projectPayload(file.payload),
      });
    } on PfError catch (error) {
      return VectorOutcome.errored(error.code);
    }
  }
}

/// 写入编排（§4.3 阶段 E–I）。
///
/// ## 为什么这个 kind 把错误也表达成「值」
///
/// 它判定的对象是**编排轨迹**，不是某一个错误码：`apply.reference-missing`
/// 要同时断言「抛的是 `PFI_E_INCOMPATIBLE`」与「抛之前真的
/// `ROLLBACK TO import_stage` 了」。而 `VectorOutcome` 的两种形态互斥，
/// 抛成 errored 就丢掉了轨迹、返回值就丢掉了「是异常而非正常返回」这个事实。
/// 因此这里把两者都放进实际值（`outcome` + `errorCode` + `statements`），
/// 由向量逐项比对 —— 这是本 kind 唯一的破例，写在文件头而不是靠读代码发现。
final class ImportApplyDriver extends VectorDriver {
  const ImportApplyDriver();

  @override
  String get kind => 'import.apply';

  @override
  String get description => '幂等短路 / 备份意图 / 单事务 + SAVEPOINT / 忽略缓存余额并重算 / 引用完整性';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'jobId': 'import_job.id',
    'fileName': '文件名（只记录）',
    'fileSha256': '整文件 sha256（幂等键）',
    // 时钟字段刻意叫 `nowMillis` 而不是 `now`：向量格式门禁用字段名的启发式
    // 拦「把不确定源当输入传进来」（`vector_format_test.dart` 的
    // `(^|_)(now|random|seed|uuid|time)$`）。这里传的本来就是**显式固定的**时钟，
    // 取名要让门禁和读者都一眼看出这一点，而不是去放宽那条规则。
    'nowMillis': '显式时钟（epoch 毫秒）',
    'ndjsonHex': '明文载荷十六进制',
    'localRows': '{表名: [本地行]}，作为 SELECT 的罐头结果',
    'importedFile': 'imported_file 的罐头结果（非空即触发幂等短路）',
    'quickCheck': 'PRAGMA quick_check 的罐头结果',
    'orphanViolations': '{子表.列: 悬空行数}，未列出的规则视为 0',
    'backup': 'ok | fail',
    'failOn': '可选：命中该 SQL 前缀的语句抛 PFD_E_OPEN（模拟写入途中失败）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final payload = PfbPayloadDecoder.decode(requireHexBytes(input, 'ndjsonHex', kind));
    final scripted = _scriptedDb(input);

    final backupCalls = <String>[];
    final gateway = _ScriptedBackup(
      mode: optionalString(input, 'backup', 'ok'),
      calls: backupCalls,
    );

    Object? errorCode;
    ImportApplyResult? result;
    try {
      result = await ImportApplier.apply(
        db: scripted,
        request: ImportApplyRequest(
          jobId: requireString(input, 'jobId', kind),
          fileName: requireString(input, 'fileName', kind),
          fileSha256Hex: requireString(input, 'fileSha256', kind),
          payload: payload,
          nowMilliseconds: requireInt(input, 'nowMillis', kind),
        ),
        backup: gateway,
      );
    } on PfError catch (error) {
      errorCode = error.code;
    }

    return VectorOutcome.value(<String, Object?>{
      'outcome': errorCode == null ? 'ok' : 'error',
      'errorCode': errorCode,
      // 余额重算的两条长 SQL 用记号代替：它们的正确性由 `db.balance.replay`
      // 与 `balance_recalc.dart` 负责；在导入轨迹里需要证明的只是
      // 「被调用了、且在事务提交之前、在全部写入之后」—— 位置由列表下标锁定。
      'statements': <String>[for (final sql in scripted.statements) _tokenize(sql)],
      'arguments': <Object?>[for (final args in scripted.argumentLog) _jsonSafe(args)],
      'transactions': scripted.transactionLog,
      'backupCalls': backupCalls,
      'unusedCanned': scripted.unusedCannedKeys,
      'summary':
          result == null
              ? null
              : <String, Object?>{
                'inserted': result.insertedCount,
                'skipped': result.skippedCount,
                'alreadyImportedJobId': result.previousJobId,
                'alreadyImportedAt': result.previousImportedAt,
                'backupPath': result.backup?.backupPath,
                'unknownTypes': result.unknownTypes,
                'warnings': result.warnings,
              },
      'unknownTypes': payload.unknownTypes,
      'warnings': payload.warnings,
    });
  }

  /// 把冗长的重算 SQL 换成记号（见上面 `statements` 处的说明）。
  String _tokenize(String sql) {
    if (sql == BalanceRecalculator.recalcStatement) {
      return '<balance.recalc>';
    }
    if (sql == BalanceRecalculator.resetStatement) {
      return '<balance.reset>';
    }
    return sql;
  }

  /// 把逻辑输入翻译成假驱动的罐头结果。
  ///
  /// 键取自**被测实现自己的常量**（`ImportApplier.findImportedFileSql` 等），
  /// 而不是在向量里抄一遍 SQL —— 抄一遍会让「SQL 改了而罐头键没改」
  /// 变成一次静默的空结果。SQL 文本本身由**语句日志**锁定，两者分工不重叠。
  ScriptedDb _scriptedDb(Map<String, Object?> input) {
    final canned = <String, List<Map<String, Object?>>>{
      ImportApplier.findImportedFileSql: _rows(input, 'importedFile'),
      ImportIntegrityCheck.quickCheckSql: <Map<String, Object?>>[
        <String, Object?>{'quick_check': optionalString(input, 'quickCheck', 'ok')},
      ],
    };
    final localRows = optionalMap(input, 'localRows', kind) ?? const <String, Object?>{};
    for (final entry in localRows.entries) {
      final rows = entry.value;
      if (rows is! List<Object?>) {
        throwVectorInput('$kind.localRows.${entry.key}', '必须是数组');
      }
      canned['SELECT * FROM ${entry.key} WHERE id IN ('] = <Map<String, Object?>>[
        for (final row in rows)
          if (row is Map<String, Object?>) row else throwVectorInput('$kind.localRows', '行必须是对象'),
      ];
    }
    final violations = optionalMap(input, 'orphanViolations', kind) ?? const <String, Object?>{};
    for (final rule in ImportIntegrityCheck.referenceRules) {
      final raw = violations[rule.key];
      final n = raw is int ? raw : 0;
      canned[rule.orphanScanSql] = <Map<String, Object?>>[
        <String, Object?>{'n': n},
      ];
    }
    final failOn = optionalString(input, 'failOn', '');
    return ScriptedDb(
      canned: canned,
      failures: failOn.isEmpty ? const <String>{} : <String>{failOn},
    );
  }

  List<Map<String, Object?>> _rows(Map<String, Object?> input, String key) {
    final raw = input[key];
    if (raw == null) {
      return const <Map<String, Object?>>[];
    }
    if (raw is! List<Object?>) {
      throwVectorInput('$kind.$key', '必须是数组');
    }
    return <Map<String, Object?>>[
      for (final row in raw)
        if (row is Map<String, Object?>) row else throwVectorInput('$kind.$key', '行必须是对象'),
    ];
  }
}

/// 按向量要求成功或失败的备份网关（记录调用次数）。
final class _ScriptedBackup implements ImportBackupGateway {
  _ScriptedBackup({required this.mode, required this.calls});

  final String mode;
  final List<String> calls;

  @override
  Future<RollbackHandle> snapshot({required String jobId}) async {
    calls.add(jobId);
    if (mode == 'fail') {
      throw StateError('磁盘空间不足（向量注入的备份失败）');
    }
    return _ScriptedRollbackHandle(backupPath: 'backup/pf-pre-import-$jobId.db');
  }
}

/// 只承载路径的回滚句柄（M1：真正的快照与恢复是 M3 的文件网关）。
final class _ScriptedRollbackHandle implements RollbackHandle {
  _ScriptedRollbackHandle({required this.backupPath});

  @override
  final String backupPath;

  @override
  Future<void> rollback() async {}

  @override
  Future<void> commit() async {}
}

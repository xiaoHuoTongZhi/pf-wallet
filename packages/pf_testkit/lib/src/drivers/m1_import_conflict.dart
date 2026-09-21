/// M1 驱动：导入期裁决、计划与引用修复（§4.4）—— 提交 B。
///
/// ## 四个 kind 的分界
///
///   - `import.merge.record` —— **单条**裁决：给定 `(文件行, 本地行, 模式, 策略,
///     删除/编辑策略)`，七态里落在哪一态、依据是哪条规则、要不要写、写什么。
///     §4.4 的裁决表逐格可穷举，因此这一层是「一组输入一组输出」的形状。
///   - `import.merge.plan` —— **一批**的计划：语句序列（含顺序）、七态计数、
///     覆盖模式的待软删清单、冲突登记的语句与参数。锁的是「写什么、按什么顺序写」。
///   - `import.merge.converge` —— **收敛性**：行序打乱、重复导入、分批导入三种
///     扰动下结果是否一致。这三条性质（可交换 / 幂等 / 可结合）是无后端同步的
///     全部依据，也是最容易在重构中被悄悄破坏的东西。
///   - `import.merge.reference` —— **引用修复**（§4.4 S11–S14）：造占位实体、
///     升级一级、同名并列。
///
/// ## 为什么 converge 需要一台模拟器
///
/// 「导入两次结果不变」这条性质**无法从一次调用的输出里看出来** —— 它要求
/// 把第一次的结果喂回去再跑一次。而本项目在 CI 上没有真实的 SQLCipher，
/// 所以驱动里带一台**极小的假库**：它只认识 [MergeWrite] 的两种形态
/// （INSERT / UPDATE），把语句折叠成行。它不是被测对象，而是让被测对象的
/// 输出**可被再次消费**的那一步。它的正确性由 `finalState` 字段反锁：
/// 那串规范化行文本由 Python 生成器独立推演过。
///
/// ## 输入里的时间与设备身份
///
/// `nowMillis` 与 `localDeviceId` 一律显式传入（缺省值写在契约里）。
/// 它们参与的地方（软删时间戳、占位实体、冲突主键）都是**可复现**的：
/// 同样的输入必然得到同样的字节，因此它们可以进黄金向量。
library;

import 'dart:convert';

import 'package:pf_io/pf_io.dart';

import '../driver.dart';
import '../json_util.dart';
import '../outcome.dart';

/// `import.merge.*` 的缺省本机身份（与 `import.apply` 驱动取同一个值）。
const String _defaultLocalDeviceId = '01J8Z9K2M4P6Q8R0T2V4X6Z8B1';

/// `import.merge.*` 的缺省显式时钟。
const int _defaultNowMillis = 1789550000000;

// ────────────────────────── 四个驱动 ──────────────────────────

/// 单条记录的裁决（§4.4 的裁决表）。
final class MergeRecordDriver extends VectorDriver {
  const MergeRecordDriver();

  @override
  String get kind => 'import.merge.record';

  @override
  String get description => '单条记录的七态裁决：取值层（复用 M0）+ 复核层（记待复核）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'remote': '{type, id, updatedAt, deviceId, columns}（墓碑即 columns.deleted_at 非空）',
    'local': '本地行（DB 列，含 updated_at / device_id / deleted_at），本地没有则省略',
    'mode': 'merge | replace | supplement_only',
    'strategy': 'converge | abort（缺省 abort）',
    'deleteEdit': 'delete_wins | edit_wins_by_lww（缺省 delete_wins）',
    'skewWindowMs': '时钟偏移宽限窗口（缺省 60000）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final decision = mergeRecord(
      remote: _record(requireMap(input, 'remote', kind), '$kind.remote'),
      local: optionalMap(input, 'local', kind),
      mode: _mode(optionalString(input, 'mode', ImportMode.merge.wireName), kind),
      strategy: _strategy(optionalString(input, 'strategy', ConflictStrategy.abort.wireName), kind),
      deleteEdit: _deleteEdit(
        optionalString(input, 'deleteEdit', DeleteEditPolicy.deleteWinsBySkew.wireName),
        kind,
      ),
      skewWindowMs: optionalInt(input, 'skewWindowMs', kSkewConflictWindowMs),
    );
    return VectorOutcome.value(<String, Object?>{
      'entityKind': decision.entityKind,
      'outcome': decision.outcome.wireName,
      'rule': decision.rule.wireName,
      'side': decision.side.wireName,
      'conflictKind': decision.conflictKind?.value,
      'needsUserReview': decision.needsUserReview,
      'write': _writeJson(decision.write),
      'localVersionStamp': decision.localVersion?.versionStamp,
      'remoteVersionStamp': decision.remoteVersion?.versionStamp,
    });
  }
}

/// 一批记录的计划（§4.4 的 plan 阶段）。
final class MergePlanDriver extends VectorDriver {
  const MergePlanDriver();

  @override
  String get kind => 'import.merge.plan';

  @override
  String get description => '一批记录的写入计划：语句序列与顺序、七态计数、待软删清单、冲突登记';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'records': '数组，元素为 {type, id, updatedAt, deviceId, columns}（行序即 recordIndex）',
    'localRows': '{表名: [本地行]}',
    'mode': 'merge | replace | supplement_only',
    'strategy': 'converge | abort',
    'deleteEdit': 'delete_wins | edit_wins_by_lww',
    'skewWindowMs': '时钟偏移宽限窗口',
    'jobId': 'import_job.id（冲突行的外键与主键派生输入）',
    'nowMillis': '显式时钟（软删时间戳与冲突主键都要它）',
    'localDeviceId': '本机 deviceId（占位实体与覆盖软删要写它）',
    'ledgerRemap': '可选：{源账本 id: 目标账本 id}（§4.4 S29）',
    'targetLedgerId': '可选：覆盖模式的软删范围；缺省表示不软删',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final plan = ImportMergePlanner.plan(_planRequest(input, kind));
    return VectorOutcome.value(<String, Object?>{
      'mode': plan.mode.wireName,
      'writes': <Object?>[for (final write in plan.writes) _writeJson(write)],
      'counts': <String, Object?>{
        for (final outcome in MergeOutcome.values) outcome.wireName: plan.countOf(outcome),
      },
      'insertedCount': plan.insertedCount,
      'updatedCount': plan.updatedCount,
      'removedCount': plan.removedCount,
      'skippedCount': plan.skippedCount,
      'conflictCount': plan.conflictCount,
      'removedCandidates': plan.removedCandidates,
      'requiresCountConfirmation': plan.requiresCountConfirmation,
      'touchedTables': plan.touchedTables.toList()..sort(),
      'conflicts': <Object?>[for (final conflict in plan.conflicts) _conflictJson(conflict)],
      'referenceFixes': <Object?>[for (final fix in plan.referenceFixes) _fixJson(fix)],
    });
  }
}

/// 收敛性：可交换 / 幂等 / 可结合。
final class MergeConvergeDriver extends VectorDriver {
  const MergeConvergeDriver();

  @override
  String get kind => 'import.merge.converge';

  @override
  String get description => '行序打乱、重复导入、分批导入三种扰动下，写入集合与最终状态是否一致';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'records': '数组，元素为 {type, id, updatedAt, deviceId, columns}',
    'localRows': '{表名: [本地行]}',
    'mode': 'merge | replace | supplement_only',
    'strategy': 'converge | abort',
    'deleteEdit': 'delete_wins | edit_wins_by_lww',
    'skewWindowMs': '时钟偏移宽限窗口',
    'jobId': 'import_job.id',
    'nowMillis': '显式时钟',
    'localDeviceId': '本机 deviceId',
    'shuffleSeed': '打乱行序用的 LCG 种子（显式传入，因此结果可复现）',
    'splitAfterStage': '分批导入的批界：该阶段（含）之前的记录为第一批',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final records = _records(input, kind);
    final localRows = _localRows(input, kind);
    final seed = optionalInt(input, 'shuffleSeed', 20260921);

    final baseline = ImportMergePlanner.plan(_planRequest(input, kind));
    final baselineWrites = _writeSetOf(baseline);
    // 每次模拟都从**同一份初始行**出发：`_SimState.apply` 是就地修改的，
    // 复用同一个实例会让「分批」从「一次导入之后」的状态开始 ——
    // 那样测出来的「一致」毫无意义。
    final baselineFinal = _SimState.of(localRows).apply(baseline.writes);

    // ── 扰动 1：行序打乱（连同 recordIndex 一起重排 —— 模拟「文件里的行是
    //    另一个顺序」）。裁决是逐条独立的，因此写入**集合**必须完全一致。
    final shuffled = _shuffle(records, seed);
    final shuffledPlan = ImportMergePlanner.plan(
      _planRequest(
        input,
        kind,
        overrideRecords: <ImportRecord>[
          for (var i = 0; i < shuffled.length; i++) _withRecordIndex(shuffled[i], i),
        ],
      ),
    );

    // ── 扰动 2：幂等 —— 把第一批计划的写入折进本地，再跑一次同样的文件。
    //    第二次必须一条正文都不写（skip 是唯一正确的落点）。
    final secondPass = ImportMergePlanner.plan(
      _planRequest(input, kind, overrideLocalRows: baselineFinal.toLocalRows()),
    );

    // ── 扰动 3：可结合 —— 按阶段边界把文件切成两批依次导入，
    //    最终状态必须与一次导入完全相同。
    final splitAfter = optionalString(input, 'splitAfterStage', '');
    final splitIndex = splitAfter.isEmpty ? -1 : kPayloadStageOrder.indexOf(splitAfter);
    final splitFinal =
        splitIndex < 0 ? null : _applySplit(input, records, splitIndex, _SimState.of(localRows));

    return VectorOutcome.value(<String, Object?>{
      'baselineWrites': <Object?>[for (final write in baseline.writes) _writeJson(write)],
      'baselineCounts': _countsJson(baseline),
      'shuffledCountsEqual': _countsEqual(shuffledPlan, baseline),
      'shuffledWritesMultisetEqual':
          _canonicalSet(_writeSetOf(shuffledPlan)) == _canonicalSet(baselineWrites),
      // 乱序**不**保证语句顺序相同（同表内按 recordIndex 排），只保证集合相同。
      // 因此这里另外锁一条：阶段序在任何扰动下都不变。
      // 两个阶段序都写进输出：只留布尔值时，失败信息只能告诉你「不一样」，
      // 而这两条字符串本身才是「父实体先于子实体」这条性质的载体。
      'shuffledStageOrderPreserved': _stageOrderOf(shuffledPlan) == _stageOrderOf(baseline),
      'baselineStageOrder': _stageOrderOf(baseline),
      'shuffledStageOrder': _stageOrderOf(shuffledPlan),
      'secondPassWrites': secondPass.writes.length,
      'secondPassCounts': _countsJson(secondPass),
      'finalState': baselineFinal.tokens(),
      if (splitFinal != null) ...<String, Object?>{
        'splitFinalStateEqual': splitFinal.tokens().toString() == baselineFinal.tokens().toString(),
        'splitFinalState': splitFinal.tokens(),
      },
    });
  }
}

/// 引用修复（§4.4 S11–S14）。
final class MergeReferenceDriver extends VectorDriver {
  const MergeReferenceDriver();

  @override
  String get kind => 'import.merge.reference';

  @override
  String get description => '引用修复：缺失父实体造占位、分类升级为一级、同名并列只报告不合并';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'records': '数组，元素为 {type, id, updatedAt, deviceId, columns}',
    'localRows': '{表名: [本地行]}',
    'nowMillis': '占位实体的时间戳（显式）',
    'localDeviceId': '占位实体的 device_id（显式）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final result = ImportReferenceFixer.apply(
      records: _records(input, kind),
      localRows: _localRows(input, kind),
      placeholderDeviceId: optionalString(input, 'localDeviceId', _defaultLocalDeviceId),
      placeholderAtMilliseconds: optionalInt(input, 'nowMillis', _defaultNowMillis),
    );
    return VectorOutcome.value(<String, Object?>{
      'placeholders': <Object?>[
        for (final row in result.placeholders)
          <String, Object?>{'table': row.table, 'id': row.id, 'columns': row.columns},
      ],
      'fixes': <Object?>[for (final fix in result.fixes) _fixJson(fix)],
      'normalized': <Object?>[
        for (final record in result.records)
          <String, Object?>{
            'table': record.table,
            'id': record.id,
            'parentId': record.columns['parent_id'],
          },
      ],
    });
  }
}

// ────────────────────────── 模拟器（假库） ──────────────────────────

/// 一台只认识 [MergeWrite] 两种形态的假库。
///
/// 它**不是**被测对象：它的存在只是为了让「把计划的结果喂回去」这一步可以做。
/// 因此它刻意做得很笨 —— 不校验主键冲突、不解析 SQL，只按 `replace` 标志
/// 折叠列。笨到出错时会立刻被 `finalState` 的期望值抓住。
final class _SimState {
  _SimState();

  /// `表|id` → 行。行的列集合即写入给出的列集合（本地独有列保留）。
  final Map<String, Map<String, Object?>> _rows = <String, Map<String, Object?>>{};

  static _SimState of(Map<String, List<Map<String, Object?>>> localRows) {
    final state = _SimState();
    for (final entry in localRows.entries) {
      for (final row in entry.value) {
        state._rows['${entry.key}|${row['id']}'] = Map<String, Object?>.of(row);
      }
    }
    return state;
  }

  _SimState apply(List<MergeWrite> writes) {
    for (final write in writes) {
      final key = '${write.table}|${write.id}';
      if (write.replace) {
        final row = _rows[key];
        if (row == null) {
          // 空库上出现 UPDATE：说明计划假定了一条不存在的本地行。
          // 静默造一行会把「计划与本地状态脱节」掩盖成一次正常写入。
          throw StateError('模拟器收到对不存在行 $key 的 UPDATE（计划与本地状态不一致）');
        }
        row.addAll(write.columns);
      } else {
        _rows[key] = Map<String, Object?>.of(write.columns);
      }
    }
    return this;
  }

  /// 回写成 `{表: [行]}`（行的 id 就是键的右半）。
  Map<String, List<Map<String, Object?>>> toLocalRows() {
    final out = <String, List<Map<String, Object?>>>{};
    for (final entry in _rows.entries) {
      final table = entry.key.substring(0, entry.key.indexOf('|'));
      (out[table] ??= <Map<String, Object?>>[]).add(entry.value);
    }
    for (final rows in out.values) {
      rows.sort(
        (Map<String, Object?> a, Map<String, Object?> b) => '${a['id']}'.compareTo('${b['id']}'),
      );
    }
    return out;
  }

  /// 规范化行文本（排序，可复现）。列名排序后拼成 `k=v`。
  List<String> tokens() {
    final tokens = <String>[
      for (final entry in _rows.entries) '${entry.key}|${_columnsToken(entry.value)}',
    ];
    tokens.sort();
    return tokens;
  }
}

/// 分批导入：第一段（阶段序 <= 批界）先跑，把结果折进本地，再跑第二段。
///
/// 批界只能落在**阶段边界**上，不能落在一张表中间：表内的随机切分会让
/// 第二批的行引用到第一批还没导入的父实体，从而造出占位实体 —— 那是一次
/// **真实存在**的行为差异（见 README「已知残留」），不是本驱动要检验的收敛性。
_SimState _applySplit(
  Map<String, Object?> input,
  List<ImportRecord> records,
  int boundaryIndex,
  _SimState start,
) {
  final first = <ImportRecord>[];
  final second = <ImportRecord>[];
  for (final record in records) {
    final stage = _stageOfTable(record.table);
    (stage <= boundaryIndex ? first : second).add(record);
  }

  final state = start;
  var batch = 0;
  for (final part in <List<ImportRecord>>[first, second]) {
    if (part.isEmpty) {
      continue;
    }
    batch++;
    final plan = ImportMergePlanner.plan(
      _planRequest(
        input,
        'import.merge.converge.split#$batch',
        overrideRecords: <ImportRecord>[
          for (var i = 0; i < part.length; i++) _withRecordIndex(part[i], i),
        ],
        overrideLocalRows: state.toLocalRows(),
      ),
    );
    state.apply(plan.writes);
  }
  return state;
}

// ────────────────────────── 输入解码 ──────────────────────────

MergePlanRequest _planRequest(
  Map<String, Object?> input,
  String path, {
  List<ImportRecord>? overrideRecords,
  Map<String, List<Map<String, Object?>>>? overrideLocalRows,
}) => MergePlanRequest(
  records: overrideRecords ?? _records(input, path),
  localRows: overrideLocalRows ?? _localRows(input, path),
  mode: _mode(optionalString(input, 'mode', ImportMode.merge.wireName), path),
  strategy: _strategy(optionalString(input, 'strategy', ConflictStrategy.abort.wireName), path),
  deleteEdit: _deleteEdit(
    optionalString(input, 'deleteEdit', DeleteEditPolicy.deleteWinsBySkew.wireName),
    path,
  ),
  skewWindowMs: optionalInt(input, 'skewWindowMs', kSkewConflictWindowMs),
  jobId: optionalString(input, 'jobId', '01J8TESTJOB000000000000001'),
  nowMilliseconds: optionalInt(input, 'nowMillis', _defaultNowMillis),
  localDeviceId: optionalString(input, 'localDeviceId', _defaultLocalDeviceId),
  ledgerRemap: _stringMap(input, 'ledgerRemap'),
  targetLedgerId:
      optionalString(input, 'targetLedgerId', '').isEmpty
          ? null
          : optionalString(input, 'targetLedgerId', ''),
);

List<ImportRecord> _records(Map<String, Object?> input, String path) {
  final raw = requireList(input, 'records', path);
  final out = <ImportRecord>[];
  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    if (item is! Map<String, Object?>) {
      throwVectorInput('$path.records[$i]', '必须是对象');
    }
    // 缺省的行序就是**它在文件里的位置**。不这样兜底，`recordIndex` 会全部取 0，
    // 而计划里的同表次序就交给 `List.sort` 的稳定性决定了 —— Dart 明确不保证
    // 排序稳定，于是「同一份文件两次导入得到不同的语句序列」。
    out.add(_record(item, '$path.records[$i]', defaultIndex: i));
  }
  return out;
}

/// 一条记录行。
///
/// 三个自洽性检查是刻意的，它们都是**真实记录行**的不变量：
///   - `columns.id` 必须与 `id` 一致（id 就是列之一，SQL 的列集合来自 `columns`）；
///   - `columns.updated_at` / `columns.device_id` 必须与 `updatedAt` / `deviceId`
///     一致（解码器正是从这两列取的值，见 `PfbPayloadDecoder`），
///     不一致的向量会让「版本戳来自哪个时间」变得无从判断；
///   - 墓碑必须表现为 `columns.deleted_at` 非空（墓碑不是另一个字段）。
///
/// 少了这三条，一条写错的向量会被当成一条合法的边界用例跑过去 ——
/// 而它锁定的行为其实从未发生过。
ImportRecord _record(Map<String, Object?> json, String path, {int defaultIndex = 0}) {
  final type = requireString(json, 'type', path);
  final spec = kPayloadRecordSpecs[type];
  if (spec == null) {
    throwVectorInput('$path.type', '未注册的记录类型 "$type"');
  }
  final id = requireString(json, 'id', path);
  final columns = requireMap(json, 'columns', path);
  final updatedAt = requireInt(json, 'updatedAt', path);
  final deviceId = requireString(json, 'deviceId', path);
  if (columns['id'] != id) {
    throwVectorInput('$path.columns.id', '必须与 id 一致（实际 ${columns['id']} vs $id）');
  }
  if (columns['updated_at'] != updatedAt) {
    throwVectorInput(
      '$path.columns.updated_at',
      '必须与 updatedAt 一致（实际 ${columns['updated_at']} vs $updatedAt）',
    );
  }
  if (columns['device_id'] != deviceId) {
    throwVectorInput(
      '$path.columns.device_id',
      '必须与 deviceId 一致（实际 ${columns['device_id']} vs $deviceId）',
    );
  }
  return ImportRecord(
    type: type,
    table: spec.table,
    id: id,
    columns: columns,
    updatedAt: updatedAt,
    deviceId: deviceId,
    isTombstone: columns['deleted_at'] != null,
    recordIndex: optionalInt(json, 'recordIndex', defaultIndex),
  );
}

ImportRecord _withRecordIndex(ImportRecord record, int index) => ImportRecord(
  type: record.type,
  table: record.table,
  id: record.id,
  columns: record.columns,
  updatedAt: record.updatedAt,
  deviceId: record.deviceId,
  isTombstone: record.isTombstone,
  recordIndex: index,
);

Map<String, List<Map<String, Object?>>> _localRows(Map<String, Object?> input, String path) {
  final raw = optionalMap(input, 'localRows', path) ?? const <String, Object?>{};
  final out = <String, List<Map<String, Object?>>>{};
  for (final entry in raw.entries) {
    final rows = entry.value;
    if (rows is! List<Object?>) {
      throwVectorInput('$path.localRows.${entry.key}', '必须是数组');
    }
    out[entry.key] = <Map<String, Object?>>[
      for (final row in rows)
        if (row is Map<String, Object?>) row else throwVectorInput('$path.localRows', '行必须是对象'),
    ];
  }
  return out;
}

Map<String, String> _stringMap(Map<String, Object?> input, String key) {
  final raw = optionalMap(input, key, '');
  if (raw == null) {
    return const <String, String>{};
  }
  return <String, String>{
    for (final entry in raw.entries)
      if (entry.value is String) entry.key: entry.value! as String,
  };
}

ImportMode _mode(String wire, String path) {
  for (final mode in ImportMode.values) {
    if (mode.wireName == wire) {
      return mode;
    }
  }
  throwVectorInput('$path.mode', '未知模式 "$wire"');
}

ConflictStrategy _strategy(String wire, String path) {
  for (final strategy in ConflictStrategy.values) {
    if (strategy.wireName == wire) {
      return strategy;
    }
  }
  throwVectorInput('$path.strategy', '未知策略 "$wire"');
}

DeleteEditPolicy _deleteEdit(String wire, String path) {
  for (final policy in DeleteEditPolicy.values) {
    if (policy.wireName == wire) {
      return policy;
    }
  }
  throwVectorInput('$path.deleteEdit', '未知删除/编辑策略 "$wire"');
}

// ────────────────────────── 输出规整 ──────────────────────────

Map<String, Object?>? _writeJson(MergeWrite? write) =>
    write == null
        ? null
        : <String, Object?>{
          'sql': write.sql,
          'arguments': write.arguments,
          'replace': write.replace,
        };

Map<String, Object?> _countsJson(MergePlan plan) => <String, Object?>{
  for (final outcome in MergeOutcome.values) outcome.wireName: plan.countOf(outcome),
};

/// 两个计划的七态计数是否逐项相同。
///
/// 不用 `Map.toString()` 比较：那依赖两个 Map 的插入顺序恰好一致，
/// 而这里要断言的是**值**相同；顺序一致是另一件事（由 `_stageOrderOf` 管）。
bool _countsEqual(MergePlan a, MergePlan b) {
  for (final outcome in MergeOutcome.values) {
    if (a.countOf(outcome) != b.countOf(outcome)) {
      return false;
    }
  }
  return true;
}

Map<String, Object?> _conflictJson(ImportConflict conflict) => <String, Object?>{
  'entity': conflict.entityKind,
  'entityId': conflict.recordId,
  'kind': conflict.kind.value,
  'side': conflict.autoResolvedSide.wireName,
  'reason': conflict.decision.reason.wireName,
  'localVersionStamp': conflict.local?.versionStamp,
  'remoteVersionStamp': conflict.remote.versionStamp,
};

Map<String, Object?> _fixJson(ReferenceFix fix) => <String, Object?>{
  'key': fix.key,
  'kind': fix.kind.wireName,
  'reason': fix.reason,
  'entity': fix.entity,
  'recordId': fix.recordId,
  'column': fix.column,
  'referencedId': fix.referencedId,
  'placeholderName': fix.placeholderName,
};

/// 一条写入的可比较形态（`sql` + 规范化参数）。
List<String> _writeSetOf(MergePlan plan) => <String>[
  for (final write in plan.writes) '${write.sql}|${jsonEncode(write.arguments)}',
];

String _canonicalSet(List<String> rows) => (List<String>.of(rows)..sort()).join('\n');

/// 语句序列里的**阶段序**：把每条语句映射成它所属的阶段，压缩掉连续重复。
///
/// 用途是「乱序不改变阶段序」这条断言：同一批数据的写入必须始终
/// 「父实体先于子实体」，否则 `foreign_keys = ON` 之下会整批失败 ——
/// 而失败的表现是「导入报错」，看起来像数据问题。
///
/// 返回的是 **String 而不是 List**：Dart 的 `List` 用 `==` 比的是同一性，
/// `_stageOrderOf(a) == _stageOrderOf(b)` 永远为 false —— 那样写出来的断言
/// 既不可能通过、也不可能报出真问题。把它压成文本，比较才是内容比较。
String _stageOrderOf(MergePlan plan) {
  final stages = <String>[];
  for (final write in plan.writes) {
    final stage = write.table == 'conflict' ? 'conflict' : _tableStage(write.table);
    if (stages.isEmpty || stages.last != stage) {
      stages.add(stage);
    }
  }
  return stages.join(' > ');
}

String _tableStage(String table) {
  for (final type in kPayloadStageOrder) {
    if (kPayloadRecordSpecs[type]!.table == table) {
      return type;
    }
  }
  return table;
}

int _stageOfTable(String table) {
  for (var i = 0; i < kPayloadStageOrder.length; i++) {
    if (kPayloadRecordSpecs[kPayloadStageOrder[i]]!.table == table) {
      return i;
    }
  }
  throw StateError('表 $table 不在阶段序里');
}

/// 确定性打乱（LCG + Fisher–Yates）。
///
/// 用固定种子的伪随机而不是真随机：向量必须可复现，且**种子的作用要能被
/// 读者复核** —— `shuffleSeed` 是输入字段，改它就换一种行序。
List<T> _shuffle<T>(List<T> items, int seed) {
  final out = List<T>.of(items);
  var state = seed & 0x7FFFFFFF;
  for (var i = out.length - 1; i > 0; i--) {
    state = (1103515245 * state + 12345) & 0x7FFFFFFF;
    final j = state % (i + 1);
    final tmp = out[i];
    out[i] = out[j];
    out[j] = tmp;
  }
  return out;
}

String _columnsToken(Map<String, Object?> row) {
  final keys = row.keys.toList()..sort();
  return keys.map((String key) => '$key=${row[key]}').join(',');
}

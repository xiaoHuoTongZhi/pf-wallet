/// 导入执行器：幂等 → 预演分类 → 备份意图 → 单事务写入（§4.3 阶段 E–I）。
///
/// ## 本文件负责什么，不负责什么
///
/// 读取与三态分流在 `import_file.dart` 与 `import_payload.dart`（阶段 A–D），
/// 本文件从**已经解码好的载荷**开始（阶段 E–I）。这条分界线不是随意划的：
/// 它让「写入编排」可以被一台**记录型假驱动**逐条锁死 ——
/// 语句内容、参数、事务边界、调用顺序全部进向量，
/// 而不需要在 CI 上装一个真实的 SQLCipher。
///
/// ## 四项硬要求（全部被 `import_payload` 向量反向钉死）
///
///   1. **幂等**：整文件 sha256 命中 `imported_file` → 直接返回上次结果，
///      一条写语句都不发；同 id 同内容 → 跳过（不是 update）。
///   2. **100% 参数化**：所有用户数据走 `?` + `arguments`。
///      字段表（[kPayloadRecordSpecs]）给出的表名与列名是本仓源码的字面量，
///      因此拼进 SQL 是合规的；**值永远不拼**。
///   3. **单事务 + SAVEPOINT**：任一步失败（含引用完整性、余额重算）
///      → `ROLLBACK TO import_stage`，整体回滚，库里不留半成品。
///   4. **cached_balance 是派生态**：写入 account 时**不带**
///      `cached_balance_minor` / `balance_as_of`（解码期已丢弃），
///      写完一律走 [BalanceRecalculator] 全量重算 —— 缓存余额只有一个权威来源。
///
/// ## 与 §4.4（冲突裁决，提交 B）的接缝
///
/// 本提交**不实现** LWW 与三十组裁决表，因此遇到「同 id 但内容不同」时
/// **不猜、不覆盖**：整批中止并抛 `PFI_E_CONFLICT`（§4.3 阶段 G 的
/// `needDecision` 语义）。接缝就是 [classifyImportRecord] 这一个纯函数 ——
/// 提交 B 只需要把 `conflict` 这一支再细分（`updated` / `tombstone` /
/// `conflict` 三态），执行器一行不用改。
library;

import 'dart:convert';

import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';

import 'export_payload.dart';
import 'import_payload.dart';
import 'transfer.dart';

/// 一条导入记录相对本地状态的去向。
enum ImportVerdict {
  /// 本地没有这条 id → 插入。
  insert,

  /// 本地已有同 id 且同内容 → 跳过（**这就是幂等**：重复导入不会产生 update）。
  skip,

  /// 本地已有同 id 但内容不同 → 需要裁决。**提交 A 不裁决，整批中止**。
  conflict,
}

/// 单条记录的预演分类（**纯函数**，提交 B 扩展它的就是这一支）。
///
/// 判「同内容」用的是 [ImportRecord.contentFingerprint] 的口径（§4.4 的
/// `contentEquals`）：排除 `rev` / `updated_at` / `created_at` / `device_id`。
/// 这几列在两台设备上天然不同 —— 把它们算进去，会导致「两台设备改成了
/// 同样的值」被判成冲突，从而把一个纯幂等的重复导入变成一次用户弹窗。
ImportVerdict classifyImportRecord({
  required ImportRecord incoming,
  required Map<String, Object?>? local,
}) {
  if (local == null) {
    return ImportVerdict.insert;
  }
  return incoming.matchesLocal(local) ? ImportVerdict.skip : ImportVerdict.conflict;
}

/// 导入模式在 `import_job.mode` 里的稳定数值（§2.3 `CHECK (mode IN (1,2,3))`）。
///
/// 规格只给了取值域、没给命名，因此这张映射是**本实现的裁决**，
/// 由 `import.apply` 向量锁死。写成显式函数而不是 `mode.index + 1`：
/// 枚举的声明顺序是给读代码的人看的，不该同时承担数据库契约。
int importJobModeValue(ImportMode mode) => switch (mode) {
  ImportMode.merge => 1,
  ImportMode.replace => 2,
  ImportMode.supplementOnly => 3,
};

/// `import_job.status` 的取值。
///
/// §2.3 只给了 `CHECK (status IN (0,1,2,3))`，没有命名；这里的命名是本实现的
/// 裁决（会在 `import.apply` 向量里锁死），四个值分别对应
/// 「开始但未结束 / 成功且可撤销 / 已撤销 / 失败」。
enum ImportJobStatus {
  /// 已开始、尚未收尾（进程在事务中被杀会留下这个状态，是排查线索）。
  running(0),

  /// 成功。§4.5 的 24 小时撤销窗口内它同时是「可撤销」。
  ok(1),

  /// 用户执行了「撤销本次导入」。
  undone(2),

  /// 失败（事务已回滚，数据未变）。
  failed(3);

  const ImportJobStatus(this.value);

  final int value;
}

/// 备份网关：导入前整库快照（§4.5）。
///
/// 为什么做成接口而不是直接调 `CipherBackup.snapshot`：备份需要 DBKey 与文件系统，
/// 而执行器要能在纯 Dart 环境（CI 上没有原生 sqlite3）被逐条测。
/// 返回的 [RollbackHandle] 就是 `transfer.dart` 里那个契约对象 ——
/// 导入流程必须持有它直到确认成功，「撤销本次导入」才有依据。
///
/// **失败就是不导入**：没有备份就没有退路（§4.5），这条不允许被跳过。
abstract interface class ImportBackupGateway {
  /// 生成一份快照。实现抛出的任何异常都会被执行器转成 `PFI_E_BACKUP`。
  ///
  /// M1 只承载**意图**（调用时机、失败语义、路径落库）；真正的
  /// `ATTACH` + `sqlcipher_export` 拷贝是 M3 的文件网关。
  Future<RollbackHandle> snapshot({required String jobId});
}

/// 一次导入执行请求。
final class ImportApplyRequest {
  const ImportApplyRequest({
    required this.jobId,
    required this.fileName,
    required this.fileSha256Hex,
    required this.payload,
    required this.nowMilliseconds,
  });

  /// `import_job.id`（由调用方生成，执行器不读时钟也不生成 id）。
  final String jobId;

  /// 用户看到的文件名（只用于记录，**不参与任何路径构造**）。
  final String fileName;

  /// 整文件字节的 SHA-256 —— 幂等短路的键。
  final String fileSha256Hex;

  final DecodedPayload payload;

  /// 显式时钟（可复现：向量必须能在任何时间点得到同一结果）。
  final int nowMilliseconds;
}

/// 一次导入执行的结果（§4.3 阶段 I 的**执行事实**）。
///
/// 与 `transfer.dart` 的 [ImportReport] 不是替代关系：那个是面向 UI 的汇总
/// （带模式、软删计数与冲突明细，属 M3/提交 B），本类是「这一次写入到底做了什么」
/// 的原始计数 —— report 由它加上裁决结果汇成。
final class ImportApplyResult {
  const ImportApplyResult({
    required this.insertedCount,
    required this.skippedCount,
    required this.conflictCount,
    required this.unknownTypes,
    required this.warnings,
    this.backup,
    this.previousJobId,
    this.previousImportedAt,
  });

  /// 幂等短路：这个文件之前已经成功导入过，本次什么都没做。
  const ImportApplyResult.alreadyImported({
    required String jobId,
    required int importedAt,
    required Map<String, int> unknownTypes,
    required List<String> warnings,
  }) : this(
         insertedCount: 0,
         skippedCount: 0,
         conflictCount: 0,
         unknownTypes: unknownTypes,
         warnings: warnings,
         previousJobId: jobId,
         previousImportedAt: importedAt,
       );

  final int insertedCount;
  final int skippedCount;
  final int conflictCount;

  /// C2：被跳过的未知类型计数（进导入报告）。
  final Map<String, int> unknownTypes;

  final List<String> warnings;

  /// 导入前备份的句柄（撤销依据）。幂等短路时为 null —— 没写任何东西，无需退路。
  final RollbackHandle? backup;

  /// 非空表示本次是「已导入过」的幂等返回。
  final String? previousJobId;

  final int? previousImportedAt;

  bool get alreadyImported => previousJobId != null;
}

/// 引用完整性规则：子表某列必须指向父表的既有行。
final class ImportReferenceRule {
  const ImportReferenceRule({required this.child, required this.column, required this.parent});

  final String child;
  final String column;
  final String parent;

  /// 面向排查的名字：`txn.account_id→account`。
  String get name => '$child.$column→$parent';

  /// 面向向量输入的键（纯 ASCII）：`txn.account_id`。
  ///
  /// 单独给一个键而不是复用 [name]：向量文件是给人看也会被别的实现读的，
  /// 让它的键里出现 `→` 只会平添编码争议（`name` 用于日志与错误详情）。
  String get key => '$child.$column';

  /// 孤儿扫描。**常量 SQL**（表名/列名都是本仓字面量），不带参数。
  ///
  /// `NOT IN` 遇 NULL 得 NULL、行被过滤 —— 这正是想要的：
  /// 可空引用列取 NULL 表示「没有引用」，不是「引用了不存在的行」。
  String get orphanScanSql =>
      'SELECT COUNT(*) AS n FROM $child WHERE $column NOT IN (SELECT id FROM $parent)';
}

/// 导入后的完整性校验（§4.3 I.4 的落点）。
///
/// M1 只做两件与「导入是否成功」直接相关的事：
///
///   1. `PRAGMA quick_check` —— 页级自检，确认没有把库写坏；
///   2. 孤儿扫描 —— 引用完整性缺失（§4.3 I.2 的 `ReferenceFixer` **不在这里**：
///      「缺父实体就自动造一个占位」是提交 B 的裁决，M1 的态度是**宁可整体回滚**）。
///
/// 这里刻意**不**做「Σ账户余额 == opening + Σ交易影响」的抽样校验：
/// 那条式子的正确性已经由 `db.balance.replay` 向量与全量重算 SQL 两处独立锁定，
/// 在导入路径上再算一遍只会多一个失败点，而不会多一份证据。
abstract final class ImportIntegrityCheck {
  /// §4.3 I.4 的页级自检。**性能备注**：这是一次全库扫描；
  /// 百万行库上它可能需要数秒。M3 接入真实库后应复核是否移到事务之外，
  /// 那时再改（现在改会让「异常路径也过了 quick_check」无法被向量覆盖）。
  static const String quickCheckSql = 'PRAGMA quick_check';

  /// 全部引用规则。顺序即扫描顺序（可复现）。
  static const List<ImportReferenceRule> referenceRules = <ImportReferenceRule>[
    ImportReferenceRule(child: 'account', column: 'ledger_id', parent: 'ledger'),
    ImportReferenceRule(child: 'account', column: 'repay_account_id', parent: 'account'),
    ImportReferenceRule(child: 'category', column: 'ledger_id', parent: 'ledger'),
    ImportReferenceRule(child: 'category', column: 'parent_id', parent: 'category'),
    ImportReferenceRule(child: 'tag', column: 'ledger_id', parent: 'ledger'),
    ImportReferenceRule(child: 'txn', column: 'ledger_id', parent: 'ledger'),
    ImportReferenceRule(child: 'txn', column: 'account_id', parent: 'account'),
    ImportReferenceRule(child: 'txn', column: 'to_account_id', parent: 'account'),
    ImportReferenceRule(child: 'txn', column: 'category_id', parent: 'category'),
    ImportReferenceRule(child: 'budget', column: 'ledger_id', parent: 'ledger'),
    ImportReferenceRule(child: 'budget', column: 'category_id', parent: 'category'),
    ImportReferenceRule(child: 'attachment', column: 'ledger_id', parent: 'ledger'),
    ImportReferenceRule(child: 'attachment', column: 'txn_id', parent: 'txn'),
  ];

  /// 校验。任何一项失败都抛错 —— 调用方（执行器）在事务内调用，
  /// 抛错即触发 `ROLLBACK TO import_stage`。
  ///
  /// [touchedTables] 是文件里出现过的表：只有**可能被本次导入影响的**
  /// 引用才需要重扫。这不是性能优化，而是让「扫了哪些规则」成为向量里
  /// 看得见的事实 —— 引用扫描漏掉一条规则，比多扫几条危险得多。
  static Future<void> assertAll(PfDb db, {required Set<String> touchedTables}) async {
    final quickCheck = await db.query(quickCheckSql);
    final verdict = quickCheck.isEmpty ? null : quickCheck.first['quick_check'];
    if (verdict != 'ok') {
      throw StorageError.openFailed(cause: 'PRAGMA quick_check 返回 $verdict（导入写入后本地库未通过页级自检）');
    }

    final failures = <String>[];
    for (final rule in referenceRules) {
      if (!touchedTables.contains(rule.child)) {
        continue;
      }
      final rows = await db.query(rule.orphanScanSql);
      final count = rows.isEmpty ? 0 : rows.first['n'];
      final n = count is int ? count : 0;
      if (n > 0) {
        failures.add('${rule.name} 有 $n 行悬空');
      }
    }
    if (failures.isNotEmpty) {
      throw ImportExportError.incompatible(
        detail:
            '引用完整性校验未通过：${failures.join('；')}。'
            '本提交不自动补建父实体（§4.4 S11/S12 属提交 B），因此整体回滚。',
      );
    }
  }
}

/// 导入执行器（§4.3 阶段 E–I）。
abstract final class ImportApplier {
  /// 本提交实现的导入模式。**唯一取值**，直到提交 B 把模式放开成参数。
  ///
  /// 「覆盖」与「仅补充」的语义（文件里没有的本地记录要不要软删、
  /// 已有记录要不要改）与 §4.4 的三十组裁决表是同一张表上的决定，
  /// 因此一并留给提交 B；现在放一个参数进来只会多一个必然抛错的入口。
  static const ImportMode implementedMode = ImportMode.merge;

  /// 阶段 E：整文件幂等短路的查询。
  static const String findImportedFileSql =
      'SELECT job_id, imported_at FROM imported_file WHERE file_sha256 = ?';

  /// 阶段 I：登记「这个文件的字节已经导入过」。
  static const String markImportedFileSql =
      'INSERT INTO imported_file (file_sha256, file_name, job_id, imported_at) VALUES (?, ?, ?, ?)';

  static const String createJobSql =
      'INSERT INTO import_job '
      '(id, file_name, file_sha256, mode, status, started_at, backup_file, manifest_json) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)';

  static const String finishJobSql =
      'UPDATE import_job SET status = ?, finished_at = ?, inserted_cnt = ?, updated_cnt = ?, '
      'skipped_cnt = ?, conflict_cnt = ?, removed_cnt = ?, error_code = ? WHERE id = ?';

  /// 事务内的回滚点（§4.3 I）。
  static const String savepointSql = 'SAVEPOINT import_stage';
  static const String rollbackToSavepointSql = 'ROLLBACK TO import_stage';
  static const String releaseSavepointSql = 'RELEASE import_stage';

  /// 执行一次导入。
  ///
  /// 抛出的一定是 `PfError`：三态（密码/损坏/版本）、`PFI_E_BACKUP`、
  /// `PFI_E_CONFLICT`、`PFI_E_INCOMPATIBLE`；写入途中底层抛出的 `PfError`
  /// **原样上抛**（不包装）—— 包装会抹掉低层的真实码，
  /// 而那正是排查导入失败时唯一有用的东西。
  static Future<ImportApplyResult> apply({
    required PfDb db,
    required ImportApplyRequest request,
    required ImportBackupGateway backup,
  }) async {
    final payload = request.payload;

    // ── 阶段 E：幂等短路（不备份、不写任何行）───────────────────────────
    final previous = await db.query(
      findImportedFileSql,
      arguments: <Object?>[request.fileSha256Hex],
    );
    if (previous.isNotEmpty) {
      final row = previous.first;
      return ImportApplyResult.alreadyImported(
        jobId: '${row['job_id']}',
        importedAt: row['imported_at'] is int ? row['imported_at']! as int : 0,
        unknownTypes: payload.unknownTypes,
        warnings: payload.warnings,
      );
    }

    // ── 阶段 G（精简）：预演分类。冲突不裁决 → 整批中止 ──────────────────
    final plan = await _plan(db, payload);

    // ── 阶段 H：备份意图。失败就不导入（备份在事务之前，因此失败时一条写语句都没发）──
    final RollbackHandle handle;
    try {
      handle = await backup.snapshot(jobId: request.jobId);
    } catch (error) {
      throw ImportExportError.backupFailed(detail: '$error', cause: error);
    }

    await _createJob(db, request, handle);

    // ── 阶段 I：单事务 + SAVEPOINT ─────────────────────────────────────
    try {
      await db.transaction((PfDb txn) async {
        await txn.run(savepointSql);
        try {
          for (final record in plan.inserts) {
            await txn.run(_insertSql(record), arguments: _insertArguments(record));
          }
          await ImportIntegrityCheck.assertAll(txn, touchedTables: plan.touchedTables);
          await BalanceRecalculator.run(txn);
        } catch (_) {
          await txn.run(rollbackToSavepointSql);
          await txn.run(releaseSavepointSql);
          rethrow;
        }
        await txn.run(releaseSavepointSql);
      });
    } catch (error) {
      // 失败时计数一律写 0：事务已整体回滚，本次导入对库的影响就是「没有影响」。
      // 把被回滚掉的 insert 数记进 `inserted_cnt`，会让「导入报告说写了 12 条」
      // 与「库里一条都没有」同时成立 —— 一份自相矛盾的报告比没有报告更坏。
      await _finishJob(
        db,
        request,
        status: ImportJobStatus.failed,
        inserted: 0,
        skipped: 0,
        errorCode: _errorCodeOf(error),
      );
      rethrow;
    }

    await _finishJob(
      db,
      request,
      status: ImportJobStatus.ok,
      inserted: plan.inserts.length,
      skipped: plan.skipped,
      errorCode: null,
    );
    await db.run(
      markImportedFileSql,
      arguments: <Object?>[
        request.fileSha256Hex,
        request.fileName,
        request.jobId,
        request.nowMilliseconds,
      ],
    );

    return ImportApplyResult(
      insertedCount: plan.inserts.length,
      skippedCount: plan.skipped,
      conflictCount: 0,
      unknownTypes: payload.unknownTypes,
      warnings: payload.warnings,
      backup: handle,
    );
  }

  /// 预演：读本地行 → 逐条分类。
  ///
  /// 自建 `ImportRequest` 到 `plan` 之间没有任何写入动作 —— 这条性质保证
  /// 「冲突 → 中止」时库里是干净的（阶段 G 在阶段 H/I 之前）。
  static Future<_ImportPlan> _plan(PfDb db, DecodedPayload payload) async {
    final byTable = <String, List<ImportRecord>>{};
    final touched = <String>{};
    for (final record in payload.records) {
      // 行序在这里被**按阶段归一**：文件里的行序是导出方的承诺，
      // 而导入正确性依赖「父实体先写」。归一让「行序错误的文件」也能被正确处理，
      // 与 C1/C2 的容忍精神一致（C1 容忍多余字段、C2 容忍未知类型，都属于
      // 「格式的冗余不该变成数据的损失」）。
      byTable.putIfAbsent(record.table, () => <ImportRecord>[]).add(record);
      touched.add(record.table);
    }

    final plan = _ImportPlan(touchedTables: touched);
    // 表按阶段顺序处理 → 语句序列可复现。
    for (final type in kPayloadStageOrder) {
      final spec = kPayloadRecordSpecs[type]!;
      final records = byTable[spec.table];
      if (records == null) {
        continue;
      }
      records.sort((ImportRecord a, ImportRecord b) => a.recordIndex.compareTo(b.recordIndex));
      final localRows = await _loadLocalRows(db, spec.table, records);
      for (final record in records) {
        switch (classifyImportRecord(incoming: record, local: localRows[record.id])) {
          case ImportVerdict.insert:
            plan.inserts.add(record);
          case ImportVerdict.skip:
            plan.skipped++;
          case ImportVerdict.conflict:
            plan.conflictIds.add(record.id);
        }
      }
    }
    if (plan.conflictIds.isNotEmpty) {
      // §4.3 阶段 G 的 needDecision；提交 B 会把它细分成 updated / tombstone / conflict。
      throw ImportExportError.conflict(count: plan.conflictIds.length);
    }
    return plan;
  }

  /// 读本地同 id 行。一次一条 `IN (?, ?, …)` 查询 —— 占位符个数由数据长度
  /// 决定（不是由数据内容），因此仍是纯参数化。
  static Future<Map<String, Map<String, Object?>>> _loadLocalRows(
    PfDb db,
    String table,
    List<ImportRecord> records,
  ) async {
    final ids = <String>[];
    final seen = <String>{};
    for (final record in records) {
      if (seen.add(record.id)) {
        ids.add(record.id);
      }
    }
    if (ids.isEmpty) {
      return const <String, Map<String, Object?>>{};
    }
    final placeholders = List<String>.filled(ids.length, '?').join(', ');
    final rows = await db.query('SELECT * FROM $table WHERE id IN ($placeholders)', arguments: ids);
    final byId = <String, Map<String, Object?>>{};
    for (final row in rows) {
      final id = row['id'];
      if (id is String) {
        byId[id] = row;
      }
    }
    return byId;
  }

  /// 写入语句。列名来自字段表（本仓字面量），值一律 `?`。
  static String _insertSql(ImportRecord record) {
    final columns = record.columns.keys.join(', ');
    final placeholders = List<String>.filled(record.columns.length, '?').join(', ');
    return 'INSERT INTO ${record.table} ($columns) VALUES ($placeholders)';
  }

  /// 参数顺序必须与 [ImportRecord.columns] 的键序一致 —— 两者都来自字段表的列序，
  /// 因此这里是「同一个顺序的两次取值」，不是两条独立规则。
  static List<Object?> _insertArguments(ImportRecord record) =>
      record.columns.values.toList(growable: false);

  static Future<void> _createJob(PfDb db, ImportApplyRequest request, RollbackHandle handle) async {
    await db.run(
      createJobSql,
      arguments: <Object?>[
        request.jobId,
        request.fileName,
        request.fileSha256Hex,
        importJobModeValue(implementedMode),
        ImportJobStatus.running.value,
        request.nowMilliseconds,
        handle.backupPath,
        jsonEncode(request.payload.manifest),
      ],
    );
  }

  static Future<void> _finishJob(
    PfDb db,
    ImportApplyRequest request, {
    required ImportJobStatus status,
    required int inserted,
    required int skipped,
    required String? errorCode,
  }) async {
    await db.run(
      finishJobSql,
      arguments: <Object?>[
        status.value,
        request.nowMilliseconds,
        inserted,
        0, // updated_cnt：本提交只插不更新（更新属提交 B）
        skipped,
        0, // conflict_cnt：有冲突就不会走到这里
        0, // removed_cnt：覆盖模式的软删计数，属提交 B
        errorCode,
        request.jobId,
      ],
    );
  }

  static String? _errorCodeOf(Object error) => error is PfError ? error.code : null;
}

/// 预演结果。
final class _ImportPlan {
  _ImportPlan({required this.touchedTables});

  final List<ImportRecord> inserts = <ImportRecord>[];
  final List<String> conflictIds = <String>[];
  final Set<String> touchedTables;
  int skipped = 0;
}

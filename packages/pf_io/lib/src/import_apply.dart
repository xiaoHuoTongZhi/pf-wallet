/// 导入执行器：读本地行 → 交计划器 → 逐条执行 → 记账（§4.3 阶段 E–I）。
///
/// ## 本文件负责什么，不负责什么
///
/// 读取与三态分流在 `import_file.dart` 与 `import_payload.dart`（阶段 A–D），
/// **裁决**在 `import_merge.dart`（§4.4），**引用修复**在
/// `import_reference_fix.dart`（§4.4 S11–S14），本文件从**计划**开始：
/// 它只做「读本地行 → 交给计划器 → 把计划逐条执行 → 记账」。
/// 这条分界线不是随意划的：它让「写入编排」可以被一台**记录型假驱动**逐条锁死
/// —— 语句内容、参数、事务边界、调用顺序全部进向量，
/// 而不需要在 CI 上装一个真实的 SQLCipher。
///
/// 更要紧的是：**执行器里没有一条业务判断**。哪些记录该写、写哪些列、要不要
/// 记一条冲突，全部是 [MergePlan] 里的既成事实。执行器只负责顺序与事务边界 ——
/// 它一旦开始「顺便判断一下」，计划器上那些锁死裁决表的向量就锁不住它了。
/// 唯一被允许留在执行器里的判断是**护栏**（见下文「两条护栏」），
/// 因为护栏的判据是「调用方有没有先问过用户」，而不是数据长什么样。
///
/// ## 四项硬要求（全部被 `import_payload` / `import_merge` 向量反向钉死）
///
///   1. **幂等**：整文件 sha256 命中 `imported_file` → 直接返回上次结果，
///      一条写语句都不发；同 id 同内容 → 跳过（不是 update）。
///   2. **100% 参数化**：所有用户数据走 `?` + `arguments`。
///      字段表（[kPayloadRecordSpecs]）给出的表名与列名是本仓源码的字面量，
///      因此拼进 SQL 是合规的；**值永远不拼**。
///   3. **单事务 + SAVEPOINT**：任一步失败（含引用完整性、余额重算）
///      都触发 `ROLLBACK TO import_stage`，整体回滚，库里不留半成品。
///   4. **cached_balance 是派生态**：写入 account 时**不带**
///      `cached_balance_minor` / `balance_as_of`（解码期已丢弃），
///      写完一律走 [BalanceRecalculator] 全量重算 —— 缓存余额只有一个权威来源。
///
/// ## 两条护栏（唯一允许留在执行器里的判断）
///
///   1. **覆盖模式的条数确认**（§4.4 护栏第 2 条）：计划里出现了「文件没提到、
///      将被软删」的本地记录，而调用方没有传 `allowOverwriteRemoval: true`
///      → **在写任何东西之前**抛错。护栏不能靠「调用方记得传」生效，
///      一条默认放行的护栏等于没有护栏。
///   2. **`abort` 策略下的整批中止**：只要有任何一条记录需要动本地已有行，
///      就在**备份之前**抛 `PFI_E_CONFLICT`（阶段 G 在阶段 H 之前）。
///
/// 两条护栏都发生在 `backup.snapshot` 之前，因此失败时库里与备份目录都没有
/// 任何变化 —— 这是「中止」该有的代价。
///
/// ## 冲突策略：为什么缺省是「中止」而不是「收敛」
///
/// `ImportApplyRequest.strategy` 缺省 [`ConflictStrategy.abort`]，于是
/// 「同 id 但内容不同 → 整批中止并抛 `PFI_E_CONFLICT`」仍然是本执行器的
/// **缺省行为**（提交 A 的行为，A 的九条 `import.apply` 向量因此一字不改）。
///
/// 这不是保守，而是顺序：**没人显式要求裁决之前，引擎不擅自改用户已有的数据。**
/// `abort` 恰好就是规格 §4.3 阶段 G 的 `askUser` 在没有 UI 时的退化形态 ——
/// 停下、不猜、不动。M3 的导入向导带上了冲突面板，届时它**必须显式传**
/// `converge`，收敛与复核才有意义。
library;

import 'dart:convert';

import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';

import 'export_payload.dart';
import 'import_merge.dart';
import 'import_payload.dart';
import 'import_reference_fix.dart';
import 'transfer.dart';

/// 一条导入记录相对本地状态的去向（提交 A 的分流口径）。
///
/// 提交 B 之后，这三态由 [mergeRecord] 在 `ConflictStrategy.abort` 下产出
/// （`insert` / `skip` / `conflict` 一一对应），本枚举因此退化为**读代码时的
/// 速记**：想知道七态怎么收敛，去 `import_merge.dart`；想知道 A 当初为什么
/// 只有三态，看这里。
enum ImportVerdict {
  /// 本地没有这条 id → 插入。
  insert,

  /// 本地已有同 id 且同内容 → 跳过（**这就是幂等**：重复导入不会产生 update）。
  skip,

  /// 本地已有同 id 但内容不同 → 需要裁决。`abort` 策略下整批中止。
  conflict,
}

/// 单条记录的预演分类（**纯函数**）。
///
/// 与 [mergeRecord] 在 `abort` 策略下的判断逐条等价，且**刻意不做版本比较** ——
/// 一旦开始比较，就等于承认「谁更新」是可判的，而那正是「中止」拒绝替用户
/// 做的判断。保留它而不是删掉的唯一理由：`import.apply.conflict-deferred`
/// 那条向量的 `notes` 指着这个函数名，而**已发布的向量注释不重写**。
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
    required this.localDeviceId,
    this.mode = ImportMode.merge,
    this.strategy = ConflictStrategy.abort,
    this.deleteEdit = DeleteEditPolicy.deleteWinsBySkew,
    this.skewWindowMs = kSkewConflictWindowMs,
    this.ledgerRemap = const <String, String>{},
    this.targetLedgerId,
    this.allowOverwriteRemoval = false,
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

  /// 本机 deviceId。占位实体与覆盖模式的软删都要写它 ——
  /// 由调用方传入而不是从某处读：执行器**不猜**自己是谁。
  final String localDeviceId;

  /// 导入模式（§4.4 模式表）。
  final ImportMode mode;

  /// 冲突策略。缺省 [`ConflictStrategy.abort`]（见文件头）。
  final ConflictStrategy strategy;

  /// 删除/编辑分歧的取值策略（§4.4 策略表两行）。
  final DeleteEditPolicy deleteEdit;

  /// 时钟偏移宽限窗口（§2.5 第 3 条）。
  final int skewWindowMs;

  /// 账本映射（§4.4 S29）：源账本 id → 目标账本 id。
  final Map<String, String> ledgerRemap;

  /// 覆盖模式的软删范围（目标账本）。
  ///
  /// `null` ⇒ **不产生任何软删**：覆盖退化为「逐条以文件为准」，
  /// 本地独有的记录一条都不动。这是刻意的失败方向 ——
  /// 范围不确定时，「少删」的代价是用户发现旧数据还在，
  /// 「多删」的代价是他再也找不回来。
  final String? targetLedgerId;

  /// 用户是否已经用**条数**确认过「将有 M 条被软删」（§4.4 护栏第 2 条）。
  ///
  /// 缺省 false：覆盖模式一旦会产生软删，而没有人明确确认过，执行器
  /// **在写任何东西之前**就抛错。
  final bool allowOverwriteRemoval;
}

/// 一次导入执行的结果（§4.3 阶段 I 的**执行事实**）。
///
/// 与 `transfer.dart` 的 [ImportReport] 不是替代关系：那个是面向 UI 的汇总
/// （带模式、软删清单与冲突明细），本类是「这一次写入到底做了什么」的原始计数。
///
/// 五个计数与 §2.3 `import_job` 的五个 `*_cnt` 列**一一对应** ——
/// 这不是巧合，而是同一次事实的两种呈现：报告与台账对不上时，
/// 用户看到的数字与库里的数字会互相矛盾。
final class ImportApplyResult {
  const ImportApplyResult({
    required this.insertedCount,
    required this.skippedCount,
    required this.conflictCount,
    required this.unknownTypes,
    required this.warnings,
    this.updatedCount = 0,
    this.removedCount = 0,
    this.removedCandidates = const <String>[],
    this.conflicts = const <ImportConflict>[],
    this.referenceFixes = const <ReferenceFix>[],
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

  /// 插入的行数（含引用修复造出的占位实体）。
  ///
  /// 占位实体算进 `inserted`：它们**确实**是新增的行，而「报告说插了 4 条、
  /// 库里多了 5 行」比多报一条更糟。它们是占位这件事由 [referenceFixes]
  /// 单独说清。
  final int insertedCount;

  /// 改动已有行的数量（含墓碑写入与复活）。
  final int updatedCount;

  /// 覆盖模式软删的行数。
  final int removedCount;

  final int skippedCount;

  /// 待复核条目数（写入 `conflict` 表的那部分）。
  final int conflictCount;

  /// C2：被跳过的未知类型计数（进导入报告）。
  final Map<String, int> unknownTypes;

  final List<String> warnings;

  /// 覆盖模式下「文件里没有、已被软删」的本地 id（§4.4 护栏要展示的就是它）。
  final List<String> removedCandidates;

  /// 待复核明细（`conflict` 表里的那些）。
  final List<ImportConflict> conflicts;

  /// 引用修复动作（§4.4 S11–S14），进导入报告。
  final List<ReferenceFix> referenceFixes;

  /// 导入前备份的句柄（撤销依据）。幂等短路时为 null —— 没写任何东西，无需退路。
  final RollbackHandle? backup;

  /// 非空表示本次是「已导入过」的幂等返回。
  final String? previousJobId;

  final int? previousImportedAt;

  bool get alreadyImported => previousJobId != null;
}

/// 导入后的完整性校验（§4.3 I.4 的落点）。
///
/// 只做两件与「导入是否成功」直接相关的事：
///
///   1. `PRAGMA quick_check` —— 页级自检，确认没有把库写坏；
///   2. 孤儿扫描 —— 引用完整性。**修复在前、校验在后**：`converge` 策略下
///      `ImportReferenceFixer`（`import_reference_fix.dart`）已经先把
///      「文件引用了一个本地没有的父实体」修掉了（造占位 / 升级一级），
///      走到这里还剩下的悬空就是**修不了的**（悬空 `ledger_id`）——
///      那种文件不是「只讲了一半的故事」，而是故事本身不成立，宁可整体回滚。
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
  ///
  /// **这是 [kPayloadReferenceRules] 的别名，不是第二张表。** 保留这个入口是
  /// 为了让「扫描规则」与「修复规则」在源码里是**同一个对象**
  /// （`import.apply.reference-rules-full` 的跨实现对证取的就是它）。
  /// 两张表一旦并存，就会出现「扫描认得这条引用、修复不认得」的组合 ——
  /// 而那时的表现是**导入整体回滚**：看起来像数据坏了，实际是两张表不一致。
  static const List<PayloadReferenceRule> referenceRules = kPayloadReferenceRules;

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
            '`converge` 策略下的修复（§4.4 S11–S14）只覆盖 account / category 两类'
            '父实体；悬空的 ledger_id 没有可凭空编造的 ledger.code，因此整体回滚。',
      );
    }
  }
}

/// 导入执行器（§4.3 阶段 E–I）。
abstract final class ImportApplier {
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
  ///
  /// **唯一的例外是护栏 1**（覆盖模式未确认条数）：那是调用方的契约破坏，
  /// 不是数据状况，因此抛 `StateError` —— 它**刻意不进错误码体系**，
  /// 否则迟早会有人 catch 住它、给用户弹一句「导入失败」，
  /// 把一个编程错误伪装成一次数据故障。
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

    // ── 阶段 G：预演。读本地行 → 生成计划。**一条写语句都不发** ──────────
    final plan = ImportMergePlanner.plan(await _planRequest(db, request));

    // 护栏 1：覆盖模式会产生软删，而没有人确认过条数 → 不写、不猜、不动。
    if (plan.requiresCountConfirmation && !request.allowOverwriteRemoval) {
      throw StateError(
        '覆盖模式将软删 ${plan.removedCandidates.length} 条本地记录，'
        '但 request.allowOverwriteRemoval 为 false：'
        '调用方必须先把这份清单摊给用户、拿到条数确认再调用（§4.4 护栏第 2 条）。',
      );
    }

    // 护栏 2：`abort` 策略下只要有一条记录需要动本地已有行，就整批停下。
    // 位置很关键：**在备份之前**，因此中止的代价是「什么都没发生」。
    if (request.strategy == ConflictStrategy.abort) {
      final conflicts = plan.countOf(MergeOutcome.conflict);
      if (conflicts > 0) {
        throw ImportExportError.conflict(count: conflicts);
      }
    }

    // ── 阶段 H：备份意图。失败就不导入（备份在事务之前，失败时一条写语句都没发）──
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
          for (final write in plan.writes) {
            await txn.run(write.sql, arguments: write.arguments);
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
      // 失败时五个计数一律写 0：事务已整体回滚，本次导入对库的影响就是「没有影响」。
      // 把被回滚掉的 insert 数记进 `inserted_cnt`，会让「导入报告说写了 12 条」
      // 与「库里一条都没有」同时成立 —— 一份自相矛盾的报告比没有报告更坏。
      await _finishJob(
        db,
        request,
        status: ImportJobStatus.failed,
        inserted: 0,
        updated: 0,
        skipped: 0,
        conflicts: 0,
        removed: 0,
        errorCode: _errorCodeOf(error),
      );
      rethrow;
    }

    await _finishJob(
      db,
      request,
      status: ImportJobStatus.ok,
      inserted: plan.insertedCount,
      updated: plan.updatedCount,
      skipped: plan.skippedCount,
      conflicts: plan.conflictCount,
      removed: plan.removedCount,
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
      insertedCount: plan.insertedCount,
      updatedCount: plan.updatedCount,
      removedCount: plan.removedCount,
      skippedCount: plan.skippedCount,
      conflictCount: plan.conflictCount,
      unknownTypes: payload.unknownTypes,
      warnings: payload.warnings,
      removedCandidates: plan.removedCandidates,
      conflicts: plan.conflicts,
      referenceFixes: plan.referenceFixes,
      backup: handle,
    );
  }

  /// 把请求翻译成计划器要的输入：**读本地行**。
  ///
  /// 自建 `ImportApplyRequest` 到 `plan` 之间没有任何写入动作 —— 这条性质保证
  /// 「冲突 → 中止」时库里是干净的（阶段 G 在阶段 H/I 之前）。
  ///
  /// 查询按 [kPayloadStageOrder] 的顺序发（因此语句序列可复现），
  /// 且**只查文件里出现过的表**：多查一张表只是多一条没人看的语句。
  static Future<MergePlanRequest> _planRequest(PfDb db, ImportApplyRequest request) async {
    final byTable = <String, List<ImportRecord>>{};
    for (final record in request.payload.records) {
      byTable.putIfAbsent(record.table, () => <ImportRecord>[]).add(record);
    }

    final localRows = <String, List<Map<String, Object?>>>{};
    for (final type in kPayloadStageOrder) {
      final table = kPayloadRecordSpecs[type]!.table;
      if (byTable.containsKey(table)) {
        localRows[table] = await _loadByIds(db, table, byTable[table]!);
      }
    }

    // 覆盖模式还要回答一个额外问题：「目标账本下本地有哪些行」——
    // 判定「文件没提到它」要用全量，而不是本批 id 的交集。
    // 这些行**不改写任何裁决**（裁决仍然按 id 查表），只用来产出待软删清单。
    if (request.mode == ImportMode.replace) {
      for (final type in kPayloadStageOrder) {
        final table = kPayloadRecordSpecs[type]!.table;
        if (!_isLedgerScoped(table)) {
          continue;
        }
        final scope = await _loadLedgerScope(db, table, request.targetLedgerId);
        localRows[table] = _mergeById(localRows[table] ?? const <Map<String, Object?>>[], scope);
      }
    }

    return MergePlanRequest(
      records: request.payload.records,
      localRows: localRows,
      mode: request.mode,
      strategy: request.strategy,
      jobId: request.jobId,
      nowMilliseconds: request.nowMilliseconds,
      localDeviceId: request.localDeviceId,
      deleteEdit: request.deleteEdit,
      skewWindowMs: request.skewWindowMs,
      ledgerRemap: request.ledgerRemap,
      targetLedgerId: request.targetLedgerId,
    );
  }

  /// 读本地同 id 行。一次一条 `IN (?, ?, …)` 查询 —— 占位符个数由数据长度
  /// 决定（不是由数据内容），因此仍是纯参数化。
  static Future<List<Map<String, Object?>>> _loadByIds(
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
      return const <Map<String, Object?>>[];
    }
    final placeholders = List<String>.filled(ids.length, '?').join(', ');
    return db.query('SELECT * FROM $table WHERE id IN ($placeholders)', arguments: ids);
  }

  /// 读目标账本下的本地行（覆盖模式的软删范围）。
  ///
  /// `targetLedgerId` 为 null ⇒ 空结果 ⇒ 不软删任何东西（见该字段的注释）。
  static Future<List<Map<String, Object?>>> _loadLedgerScope(
    PfDb db,
    String table,
    String? targetLedgerId,
  ) async {
    if (targetLedgerId == null) {
      return const <Map<String, Object?>>[];
    }
    return db.query(
      'SELECT * FROM $table WHERE ledger_id = ?',
      arguments: <Object?>[targetLedgerId],
    );
  }

  /// 表是否有 `ledger_id` 列。判据取自引用规则表（单一来源），不是手写清单：
  /// 将来 v2 新增一张带账本维度的表，这里会自动跟上。
  static bool _isLedgerScoped(String table) => kPayloadReferenceRules.any(
    (PayloadReferenceRule rule) => rule.child == table && rule.column == 'ledger_id',
  );

  /// 按 id 合并两批行（先到的赢）。覆盖模式下同一张表可能被查两次：
  /// 一次按本批 id、一次按账本范围，去重是必需的 —— 同一条行出现两次会让
  /// 「本地已有该 id」的判定与「待软删」的清单互相矛盾。
  static List<Map<String, Object?>> _mergeById(
    List<Map<String, Object?>> first,
    List<Map<String, Object?>> second,
  ) {
    final seen = <String>{};
    final merged = <Map<String, Object?>>[];
    for (final row in <Map<String, Object?>>[...first, ...second]) {
      final id = row['id'];
      if (id is String && seen.add(id)) {
        merged.add(row);
      }
    }
    return merged;
  }

  static Future<void> _createJob(PfDb db, ImportApplyRequest request, RollbackHandle handle) async {
    await db.run(
      createJobSql,
      arguments: <Object?>[
        request.jobId,
        request.fileName,
        request.fileSha256Hex,
        importJobModeValue(request.mode),
        ImportJobStatus.running.value,
        request.nowMilliseconds,
        handle.backupPath,
        jsonEncode(request.payload.manifest),
      ],
    );
  }

  /// 收尾记账。五个 `*_cnt` 全部显式传入 —— 缺省成 0 的那种写法会让
  /// 「忘了记 updated」表现成「确实没更新过」，而两者完全不同。
  static Future<void> _finishJob(
    PfDb db,
    ImportApplyRequest request, {
    required ImportJobStatus status,
    required int inserted,
    required int updated,
    required int skipped,
    required int conflicts,
    required int removed,
    required String? errorCode,
  }) async {
    await db.run(
      finishJobSql,
      arguments: <Object?>[
        status.value,
        request.nowMilliseconds,
        inserted,
        updated,
        skipped,
        conflicts,
        removed,
        errorCode,
        request.jobId,
      ],
    );
  }

  static String? _errorCodeOf(Object error) => error is PfError ? error.code : null;
}

/// 导入期记录裁决（§4.4）—— 提交 B。
///
/// ## 两层，职责不许串
///
/// ```
///   取值层：把「本地那份」与「文件里那份」裁决成一个确定取值  ← 收敛性全靠它
///   复核层：把这次分歧记下来，交给用户看一眼               ← 只影响「打不打扰用户」
/// ```
///
/// 这个切分不是审美。多设备离线场景下**任何**「停下来等用户选」的设计都无法
/// 收敛：同一处分歧在 A 上选了「保本地」、在 B 上选了「保远端」，下次同步又冲突。
/// 因此规则是：**先确定性地得出一个取值，再把可疑的分歧呈现给用户复核**。
/// 用户改不改都不影响收敛性 —— 改了就产生一个更新的版本戳。
///
/// 顺着这条线推出一个反直觉但必须的结论：**「冲突」不影响收敛性**。
/// 一次 `conflict` 只是「取值 + 一条待复核记录」，取值本身仍然按版本戳确定性地
/// 选出来。若把冲突实现成「这次先不写、等用户」，同一批记录以不同顺序导入就会
/// 得到不同结果 —— §4.4 S27 会当场变红（见 `import.merge.converge` 向量）。
///
/// ## 版本戳从哪来：合成，而不是新增一列
///
/// §4.1 的记录行只带 `updated_at` 与 `device_id`（`change_log` 表同样只有这两列），
/// **没有版本戳列**。于是导入期的版本戳必须由这两个字段按 §4.4 的实现口径注记
/// 合成（[synthesizeVersionStamp]）：
///
///     48 位毫秒 + 80 位设备派生决胜位 → 26 字符 Crockford Base32 ULID
///
/// 为什么复用 M0 冻结的 ULID 戳，而不是「先比 updatedAt、再比 deviceId」：
/// 后者会让 `device_id` 同时承担「身份」与「排序键」两个角色，任何一端改了 ID
/// 的格式或生成方式都会**静默改写历史裁决结果**。派生位把这层耦合切断。
///
/// ## 60 秒宽限窗口（§2.5 第 3 条）
///
/// 「差异 < 60s 且内容不同 → 不静默 LWW，直接进冲突列表让用户决定」。
/// 这条规则把「时钟偏移导致的静默丢数据」变成「用户可见的冲突」——
/// 两台设备的时钟差几秒是完全正常的，此时说「谁更新的」没有语义上的强弱之分。
///
/// 它与 M0 的 `needsUserReview`（同毫秒）是**包含**关系而不是两条独立规则：
/// 同毫秒必然落在 60s 窗口内。B 把窗口放成 60s 之后，M0 那条判据不再单独使用，
/// 但 `resolveRecordVersion` 定出的**胜者**仍然是唯一权威。
///
/// ## 与 `record_version.dart` 的分工
///
/// 取值层不重写比较逻辑，而是复用 M0 的 [resolveRecordVersion] ——
/// 它已经被 `merge.resolve` / `merge.reduce` 向量锁死，满足可交换 / 幂等 /
/// 可结合三条性质。B 只在其上加两样东西：**删除状态**与**宽限窗口**。
///
///   - 删除状态不是「内容」的一部分，因此不能塞进内容指纹；
///   - 宽限窗口是「要不要打扰用户」的判据，不是「谁胜」的判据。
///
/// 一句话：**胜者由 M0 定，要不要复核由 B 定。**
library;

import 'dart:convert';

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';

import 'export_payload.dart';
import 'import_payload.dart';
import 'import_reference_fix.dart';
import 'record_version.dart';
import 'transfer.dart';

/// 时钟偏移宽限窗口（§2.5 的 `SKEW_CONFLICT_WINDOW_MS`）。
///
/// 差 60 秒以内且内容不同 ⇒ 不敢断言谁更新，转人工。
const int kSkewConflictWindowMs = 60000;

/// §4.4 的七态。
///
/// 七个状态互斥且穷尽：给定 (本地, 远端, 模式, 策略) 有且只有一个落点。
/// 之所以要这么细，是因为它们的**写库动作不同** —— `insert` 是 INSERT、
/// `update` 是 UPDATE、`skip` 一条语句都不发、`insertTombstone` 只写墓碑不写正文。
/// 合成成「变更 / 不变更」两态，语句轨迹就锁不住了。
enum MergeOutcome {
  /// 本地没有这条 id → 插入正文。
  insert('insert'),

  /// 本地已有、远端胜出且内容不同 → 更新。
  update('update'),

  /// 什么都不做（本地胜出、双方同内容、双方都删、仅补充模式遇到已存在）。
  skip('skip'),

  /// 墓碑胜出 → 把删除写进本地（远端的墓碑、本地是活着的编辑）。
  markDeleted('mark_deleted'),

  /// 编辑胜出且本地是墓碑 → 记录复活。**只在 [DeleteEditPolicy.editWinsByLww] 下出现。**
  resurrect('resurrect'),

  /// 有分歧但已确定性取值 → 取值照写（或不写），另外记一条待复核。
  conflict('conflict'),

  /// 本地没有、且文件带来的只是一个墓碑 → 只记墓碑，防止它以后复活。
  insertTombstone('insert_tombstone');

  const MergeOutcome(this.wireName);

  final String wireName;
}

/// 冲突策略。
///
/// ## 为什么只有两个值，而规格里出现了三个名字
///
/// §4.4 的伪码里 `ConflictStrategy` 同时被用来表达两件**无关**的事：
/// 「发现分歧要不要停下来问用户」（§4.3 阶段 G 的 `askUser`）与
/// 「删除/编辑谁赢」（§4.4 的 `editWinsByLww`）。塞进同一个枚举，就会产生
/// 「`deleteWins` 与 `askUser` 谁优先」这种没有答案的问题。
///
/// 本实现把它拆成两个正交的轴：
///
///   - [ConflictStrategy]：**要不要裁决**。`abort` 就是规格 `askUser` 在**没有
///     UI 时的退化形态** —— 停下、不猜、不动数据。
///   - [DeleteEditPolicy]：**删除/编辑谁赢**，见该枚举。
///
/// 拆开之后每个取值都有唯一含义，也就都能被一条向量钉死。
enum ConflictStrategy {
  /// 逐条裁决并收敛：确定性取值 + 记待复核（§4.4 的默认路径）。
  converge('converge'),

  /// 发现任何「需要动本地已有行」的分歧就整批中止，抛 `PFI_E_CONFLICT`。
  ///
  /// 这是提交 A 的唯一行为，也是本引擎的缺省策略：**没人显式要求裁决之前，
  /// 引擎不擅自改用户已有的数据**。M3 的导入向导必须显式传 `converge`。
  abort('abort');

  const ConflictStrategy(this.wireName);

  final String wireName;
}

/// 删除 / 编辑分歧的取值策略（§4.4 策略表的两行）。
enum DeleteEditPolicy {
  /// 删除优先 + 宽限转人工（**默认**）。
  ///
  /// 编辑不晚于墓碑 ⇒ 墓碑胜（**迟到的编辑不得复活已删记录**）；
  /// 编辑晚于墓碑 ⇒ 转人工，但取值仍确定性取编辑那一份。
  ///
  /// 本策略下「复活」**一定伴随一条待复核记录** —— 这正是规格策略表里那句
  /// 「绝不静默复活」的落点：复活可以发生，但不能悄无声息。
  deleteWinsBySkew('delete_wins'),

  /// 编辑优先（纯 LWW）—— §4.4 策略 B。
  ///
  /// 编辑更晚 ⇒ [MergeOutcome.resurrect]（复活，且**不**记待复核）。
  /// 这是七态里 `resurrect` 唯一的出口：默认策略下它不可达。
  editWinsByLww('edit_wins_by_lww');

  const DeleteEditPolicy(this.wireName);

  final String wireName;
}

/// 裁决依据。进向量、也进冲突面板的解释文案 —— 取值一旦发布不得改名。
enum MergeRule {
  /// 仅补充模式：本地已存在，一律不动（含墓碑）。
  fillOnlyExisting('fill_only_existing'),

  /// 仅补充模式：本地不存在。
  fillOnlyNew('fill_only_new'),

  /// 覆盖模式：以文件为准。
  overwriteByFile('overwrite_by_file'),

  /// 覆盖模式：文件里是墓碑。
  overwriteTombstone('overwrite_tombstone'),

  /// 本地不存在，文件带来正文。
  localMissing('local_missing'),

  /// 本地不存在，文件带来墓碑（防复活）。
  localMissingTombstone('local_missing_tombstone'),

  /// 中止策略：本地已存在且内容不同 → 不猜、不覆盖。
  abortOnDivergence('abort_on_divergence'),

  /// 内容与删除状态都相同 → 什么都不用做（**幂等就落在这里**）。
  identicalContent('identical_content'),

  /// 双方都是墓碑 → 无事。
  bothDeleted('both_deleted'),

  /// 删除/编辑分歧：墓碑不早于编辑 → 墓碑胜。
  tombstoneWins('tombstone_wins'),

  /// 删除/编辑分歧：编辑晚于墓碑，默认策略下转人工。
  deleteVsEdit('delete_vs_edit'),

  /// 删除/编辑分歧：编辑晚于墓碑，`editWinsByLww` 策略下复活。
  deleteVsEditLww('delete_vs_edit_lww'),

  /// 双方未删、远端严格更新 → 取远端。
  remoteNewer('remote_newer'),

  /// 双方未删、本地严格更新 → 保本地。
  localNewer('local_newer'),

  /// 双方未删、内容不同、时间差落在宽限窗口内 → 转人工（取值仍确定）。
  ambiguousWindow('ambiguous_window'),

  /// 双方未删、版本戳相同但内容不同 → 转人工。
  ///
  /// 正常流程不可能产生（同设备同戳 = 同一次写入）。出现即说明版本戳生成被
  /// 破坏、或数据被外部改过，因此必须留下证据而不是悄悄选一个。
  stampCollision('stamp_collision');

  const MergeRule(this.wireName);

  final String wireName;
}

/// 一条要发给数据库的写入。
///
/// 为什么把 SQL 的拼装放在这里而不是执行器里：**它是被向量锁定的对象**。
/// `import.merge.plan` 的期望值里能看见每条语句的文本与参数，于是「悄悄改一条
/// 写入语句」必须同时改向量文件（diff 里看得见）。表名与列名全部是本仓字段表
/// 的字面量（§4.3 的「100% 参数化」），**值永远走 `?`**。
final class MergeWrite {
  const MergeWrite({
    required this.table,
    required this.id,
    required this.columns,
    required this.replace,
  });

  final String table;

  /// 目标行主键（UPDATE 的 `WHERE id = ?`）。
  final String id;

  /// 列名 → 值。列序即参数序。
  final Map<String, Object?> columns;

  /// `true` → UPDATE（本地已有该行）；`false` → INSERT（本地没有）。
  final bool replace;

  /// 写入语句。列名是本仓字面量，值一律占位符。
  String get sql =>
      replace
          ? 'UPDATE $table SET ${columns.keys.map((String c) => '$c = ?').join(', ')} WHERE id = ?'
          : 'INSERT INTO $table (${columns.keys.join(', ')}) '
              'VALUES (${List<String>.filled(columns.length, '?').join(', ')})';

  /// 参数。UPDATE 的主键放在最后 —— 与 [sql] 里 `WHERE id = ?` 的位置一致。
  List<Object?> get arguments =>
      replace ? <Object?>[...columns.values, id] : columns.values.toList(growable: false);

  @override
  String toString() => 'MergeWrite(${replace ? 'update' : 'insert'} $table/$id)';
}

/// 一条记录的裁决结果。
final class MergeRecordDecision {
  const MergeRecordDecision({
    required this.entityKind,
    required this.recordId,
    required this.outcome,
    required this.rule,
    required this.side,
    required this.write,
    this.conflictKind,
    this.localVersion,
    this.remoteVersion,
    this.needsUserReview = false,
  });

  /// 目标表名（`conflict.entity` 用的也是它）。
  final String entityKind;

  final String recordId;

  final MergeOutcome outcome;

  final MergeRule rule;

  /// 确定性取值落在哪一侧。
  final MergeSide side;

  /// 要执行的写入；`null` 表示这一条不需要写任何东西。
  final MergeWrite? write;

  /// 冲突种类（`conflict.kind`）。非 null 等价于 [needsUserReview]。
  final ConflictKind? conflictKind;

  /// 参与裁决的两个版本（诊断、冲突面板与待复核登记都要它）。
  final RecordVersion? localVersion;
  final RecordVersion? remoteVersion;

  /// 是否记一条待复核。
  final bool needsUserReview;

  /// 是否真的会改动库里的那一行。
  bool get writes => write != null;

  @override
  String toString() =>
      'MergeRecordDecision($entityKind/$recordId, ${outcome.wireName}, '
      '${rule.wireName}${needsUserReview ? ', review' : ''})';
}

/// **单条记录**的裁决（§4.4 的记录级合并）。
///
/// 这是本文件唯一做决定的地方，[ImportMergePlanner] 只是把它套上「按阶段序遍历
/// + 收集 + 汇总」。拆开的理由很实际：三十组裁决场景全部是这一层的输入输出，
/// 逐条喂给它就能穷举，不需要为每组场景造一份完整载荷。
///
/// [local] 是**库里的那一行**（可以是墓碑），`null` 表示本地没有这条 id。
/// 判定「同内容」用的是 [ImportRecord.matchesLocal] 的口径。
MergeRecordDecision mergeRecord({
  required ImportRecord remote,
  required Map<String, Object?>? local,
  required ImportMode mode,
  required ConflictStrategy strategy,
  DeleteEditPolicy deleteEdit = DeleteEditPolicy.deleteWinsBySkew,
  int skewWindowMs = kSkewConflictWindowMs,
}) {
  final table = remote.table;

  MergeRecordDecision plain(
    MergeOutcome outcome,
    MergeRule rule, {
    MergeSide side = MergeSide.none,
    MergeWrite? write,
    ConflictKind? conflictKind,
    RecordVersion? localVersion,
    RecordVersion? remoteVersion,
  }) => MergeRecordDecision(
    entityKind: table,
    recordId: remote.id,
    outcome: outcome,
    rule: rule,
    side: side,
    write: write,
    conflictKind: conflictKind,
    localVersion: localVersion,
    remoteVersion: remoteVersion,
    needsUserReview: conflictKind != null,
  );

  // ── 模式 1/2：仅补充与覆盖都**不做版本比较**，先于一切裁决 ──────────────
  switch (mode) {
    case ImportMode.supplementOnly:
      if (local == null) {
        return plain(
          remote.isTombstone ? MergeOutcome.insertTombstone : MergeOutcome.insert,
          MergeRule.fillOnlyNew,
          side: MergeSide.remote,
          write: _insert(remote),
        );
      }
      // 「绝不修改、绝不删除任何已有记录」—— 含墓碑（§4.4 模式表）。
      return plain(MergeOutcome.skip, MergeRule.fillOnlyExisting, side: MergeSide.local);
    case ImportMode.replace:
      if (local == null) {
        return plain(
          remote.isTombstone ? MergeOutcome.insertTombstone : MergeOutcome.insert,
          remote.isTombstone ? MergeRule.overwriteTombstone : MergeRule.overwriteByFile,
          side: MergeSide.remote,
          write: _insert(remote),
        );
      }
      return plain(
        remote.isTombstone ? MergeOutcome.markDeleted : MergeOutcome.update,
        remote.isTombstone ? MergeRule.overwriteTombstone : MergeRule.overwriteByFile,
        side: MergeSide.remote,
        write: _update(remote),
      );
    case ImportMode.merge:
      break;
  }

  // ── 本地不存在 ────────────────────────────────────────────────────────
  if (local == null) {
    return plain(
      remote.isTombstone ? MergeOutcome.insertTombstone : MergeOutcome.insert,
      remote.isTombstone ? MergeRule.localMissingTombstone : MergeRule.localMissing,
      side: MergeSide.remote,
      write: _insert(remote),
    );
  }

  // ── 中止策略：只看「要不要动本地已有行」，动就整批停下 ─────────────────
  //
  // 刻意**不做**版本比较：一旦开始比较，就等于承认「谁更新」是可判的，
  // 而那正是本策略拒绝替用户做的判断。这也是提交 A 的行为 ——
  // A 的向量因此一字不改地继续成立。
  if (strategy == ConflictStrategy.abort) {
    if (remote.matchesLocal(local)) {
      return plain(MergeOutcome.skip, MergeRule.identicalContent);
    }
    final localDeleted = local['deleted_at'] != null;
    // 即使**不裁决**也要把两侧版本算出来：冲突登记（`conflict.local_json` /
    // `remote_json`）要写它们。这一步不参与任何判定 —— 判定在上一行就做完了
    // （同内容即跳过），本分支的结论只有「有分歧，停下」。
    //
    // 本地那侧允许为 null：`_localVersionOrNull` 在 `device_id` 不可用时返回 null，
    // 而「停下一批」不需要比大小，因此一条缺版本元数据的坏行不该把
    // `PFI_E_CONFLICT` 换成 `PFI_E_INCOMPATIBLE`（那会指错排查方向）。
    return plain(
      MergeOutcome.conflict,
      MergeRule.abortOnDivergence,
      conflictKind:
          localDeleted != remote.isTombstone ? ConflictKind.deleteVsEdit : ConflictKind.content,
      localVersion: _localVersionOrNull(local, remote),
      remoteVersion: _remoteVersion(remote),
    );
  }

  // ── 双方同内容 → 什么都不做（**幂等就落在这里**，且必须先于版本比较）──
  //
  // 「先判同内容」不是优化：两台设备各自把同一个字段改成同样的值，版本戳必然
  // 不同，但业务上没有任何分歧。若先比版本戳，远端较大就会产生一次 update ——
  // 「同一份备份导入两次结果不变」这条性质会当场失效（§4.4 S28）。
  // 内容相同意味着**写与不写，库里是同一行**。
  final sameContent = remote.matchesLocal(local);
  final localDeleted = local['deleted_at'] != null;
  if (sameContent && localDeleted == remote.isTombstone) {
    return plain(MergeOutcome.skip, MergeRule.identicalContent);
  }

  final localVersion = _localVersion(local, remote);
  final remoteVersion = _remoteVersion(remote);

  // 胜者由 M0 定（可交换 / 幂等 / 可结合三条性质已在那里被锁死）。
  final decision = resolveRecordVersion(local: localVersion, remote: remoteVersion);
  final remoteWins = decision.side == MergeSide.remote;
  final side = remoteWins ? MergeSide.remote : MergeSide.local;

  // ── 双方都是墓碑 → 无事 ────────────────────────────────────────────────
  if (localDeleted && remote.isTombstone) {
    return plain(
      MergeOutcome.skip,
      MergeRule.bothDeleted,
      side: side,
      localVersion: localVersion,
      remoteVersion: remoteVersion,
    );
  }

  // ── 一边删除、一边编辑 ────────────────────────────────────────────────
  if (localDeleted != remote.isTombstone) {
    final deletedIsLocal = localDeleted;
    // 「编辑不晚于墓碑」—— 迟到的编辑不得复活已删记录。判据是版本戳的全序，
    // 因此与哪一侧是本机无关（可交换性由此成立）。
    final editedIsNewer = deletedIsLocal ? remoteWins : !remoteWins;
    if (!editedIsNewer) {
      if (deletedIsLocal) {
        // 本地已经是墓碑，取值本来就是它 → 不需要写任何东西。
        return plain(
          MergeOutcome.skip,
          MergeRule.tombstoneWins,
          side: MergeSide.local,
          localVersion: localVersion,
          remoteVersion: remoteVersion,
        );
      }
      return plain(
        MergeOutcome.markDeleted,
        MergeRule.tombstoneWins,
        side: MergeSide.remote,
        write: _update(remote),
        localVersion: localVersion,
        remoteVersion: remoteVersion,
      );
    }
    if (deleteEdit == DeleteEditPolicy.editWinsByLww) {
      return plain(
        MergeOutcome.resurrect,
        MergeRule.deleteVsEditLww,
        side: MergeSide.remote,
        write: _update(remote),
        localVersion: localVersion,
        remoteVersion: remoteVersion,
      );
    }
    return plain(
      MergeOutcome.conflict,
      MergeRule.deleteVsEdit,
      side: side,
      // 取值仍按版本戳确定（编辑晚于墓碑 ⇒ 取编辑），但**一定**记一条待复核 ——
      // 规格策略表那句「绝不静默复活」落在这里。
      write: remoteWins ? _update(remote) : null,
      conflictKind: ConflictKind.deleteVsEdit,
      localVersion: localVersion,
      remoteVersion: remoteVersion,
    );
  }

  // ── 双方都未删 ────────────────────────────────────────────────────────
  if (sameContent) {
    // 删除状态相同、内容也相同 → 只是元数据不同，不该用它打扰用户。
    return plain(
      MergeOutcome.skip,
      MergeRule.identicalContent,
      side: side,
      localVersion: localVersion,
      remoteVersion: remoteVersion,
    );
  }

  final localUpdatedAt = local['updated_at'];
  final deltaMs = (remote.updatedAt - (localUpdatedAt is int ? localUpdatedAt : 0)).abs();
  final collided = localVersion.versionStamp == remoteVersion.versionStamp;

  if (collided || deltaMs < skewWindowMs) {
    return plain(
      MergeOutcome.conflict,
      collided ? MergeRule.stampCollision : MergeRule.ambiguousWindow,
      side: side,
      // 确定性取值仍然照写（本地胜就不写）—— 见文件头「『冲突』不影响收敛性」。
      write: remoteWins ? _update(remote) : null,
      conflictKind: ConflictKind.content,
      localVersion: localVersion,
      remoteVersion: remoteVersion,
    );
  }

  if (remoteWins) {
    return plain(
      MergeOutcome.update,
      MergeRule.remoteNewer,
      side: MergeSide.remote,
      write: _update(remote),
      localVersion: localVersion,
      remoteVersion: remoteVersion,
    );
  }
  return plain(
    MergeOutcome.skip,
    MergeRule.localNewer,
    side: MergeSide.local,
    localVersion: localVersion,
    remoteVersion: remoteVersion,
  );
}

MergeWrite _insert(ImportRecord remote) =>
    MergeWrite(table: remote.table, id: remote.id, columns: remote.columns, replace: false);

MergeWrite _update(ImportRecord remote) =>
    MergeWrite(table: remote.table, id: remote.id, columns: remote.columns, replace: true);

/// 文件中那一行的版本。恒可构造 —— 载荷解码已经保证 `deviceId` 非空。
RecordVersion _remoteVersion(ImportRecord remote) => RecordVersion(
  id: remote.id,
  versionStamp: remote.versionStamp,
  deviceId: remote.deviceId,
  contentHash: remote.contentFingerprint,
  deleted: remote.isTombstone,
);

/// 库中那一行的版本。
///
/// 库行的时间戳同样可能不合法（时钟从未校准的设备写下的 0），因此先走
/// [normalizeUpdatedAtMilliseconds] 归一 —— 不能让一条坏时间戳炸掉整次导入。
/// `device_id` 不可用时**抛错**：这个函数只在「必须比大小」的分支里被调用，
/// 而无法定序时得出的任何结论都是编的。
RecordVersion _localVersion(Map<String, Object?> local, ImportRecord remote) {
  final version = _localVersionOrNull(local, remote);
  if (version == null) {
    throw ImportExportError.incompatible(detail: '库中记录 ${remote.id} 缺少 device_id，无法参与版本裁决');
  }
  return version;
}

/// 同 [_localVersion]，但 `device_id` 不可用时返回 `null` 而不是抛错。
///
/// 存在的理由是「转人工」这一类分支：它们**只记录现状、不比较大小**，
/// 因此缺版本元数据不该把它们变成另一个错误码 —— 那会让用户看到
/// 「记录缺少 device_id」，而真正该看到的是「有 1 处冲突要确认」。
RecordVersion? _localVersionOrNull(Map<String, Object?> local, ImportRecord remote) {
  final deviceId = local['device_id'];
  if (deviceId is! String || deviceId.isEmpty) {
    return null;
  }
  final updatedAt = local['updated_at'];
  return RecordVersion(
    id: remote.id,
    versionStamp: synthesizeVersionStamp(
      updatedAt is int ? normalizeUpdatedAtMilliseconds(updatedAt) : 0,
      deviceId,
    ),
    deviceId: deviceId,
    // 内容指纹的口径必须与 [ImportRecord.matchesLocal] 完全一致：**只比文件那一行
    // 携带的列**，并排除版本元数据列。
    //
    // 「只比文件携带的列」这半条不能省：本地行多出 `cached_balance_minor` /
    // `balance_as_of` / `source_import_job` 这些「导出不带、本地才有」的列，
    // 按列名求并集会让任何一条 account 或 txn 行永远判成「内容不同」，
    // 于是重复导入变成一次冲突弹窗。而 [ImportRecord.matchesLocal] 用的正是
    // 同一个键集（`remote.columns` 减去排除项），两处必须逐字一致 ——
    // 一旦分叉，就会出现「判成同内容（skip）却带着两个不同的 contentHash」，
    // 而 contentHash 正是版本戳相同时的决胜依据。
    contentHash: ImportRecord.contentFingerprintOf(<String, Object?>{
      for (final key in remote.columns.keys)
        if (!ImportRecord.fingerprintExcluded.contains(key)) key: local[key],
    }),
    deleted: local['deleted_at'] != null,
  );
}

/// 一次 `plan` 的输入。
final class MergePlanRequest {
  const MergePlanRequest({
    required this.records,
    required this.localRows,
    required this.mode,
    required this.strategy,
    required this.jobId,
    required this.nowMilliseconds,
    required this.localDeviceId,
    this.deleteEdit = DeleteEditPolicy.deleteWinsBySkew,
    this.skewWindowMs = kSkewConflictWindowMs,
    this.ledgerRemap = const <String, String>{},
    this.targetLedgerId,
  });

  /// 已解码的记录（行序不重要：planner 内部按阶段序归一）。
  final List<ImportRecord> records;

  /// 库中已有行，按表分组。合并/仅补充只需要**与本批 id 相交的**那些；
  /// 覆盖模式还需要目标账本下的全部行（判定「文件没提到」）。
  final Map<String, List<Map<String, Object?>>> localRows;

  final ImportMode mode;
  final ConflictStrategy strategy;
  final DeleteEditPolicy deleteEdit;
  final int skewWindowMs;

  /// `import_job.id`：冲突行的外键，也是冲突主键的派生输入。
  final String jobId;

  /// 显式时钟（软删时间戳与冲突主键都要它 —— 引擎不读时钟）。
  final int nowMilliseconds;

  /// 本机 deviceId（占位实体与覆盖软删都要写 `device_id`）。
  final String localDeviceId;

  /// 账本映射（§4.4 S29）：源账本 id → 目标账本 id。
  final Map<String, String> ledgerRemap;

  /// 覆盖模式的软删范围（目标账本）。`null` 表示不软删。
  final String? targetLedgerId;
}

/// `plan` 的结果（§4.3 阶段 G）。
///
/// 四类写入分开存不是为了好看：它们的**计数口径不同**
/// （`import_job` 的 `inserted_cnt` / `updated_cnt` / `removed_cnt` / `conflict_cnt`），
/// 混在一个列表里计数迟早会把占位实体算成用户的数据。
final class MergePlan {
  MergePlan({
    required this.mode,
    required this.recordWrites,
    required this.placeholderWrites,
    required this.removalWrites,
    required this.conflictWrites,
    required this.conflicts,
    required this.removedCandidates,
    required this.counts,
    required this.touchedTables,
    required this.referenceFixes,
  });

  final ImportMode mode;

  /// 裁决产生的写入（按阶段序）。
  final List<MergeWrite> recordWrites;

  /// 引用修复产生的占位实体（按表内顺序排在引用它们的记录之前）。
  final List<MergeWrite> placeholderWrites;

  /// 覆盖模式的软删写入。
  final List<MergeWrite> removalWrites;

  /// 冲突登记（`conflict` 表）。
  final List<MergeWrite> conflictWrites;

  /// 待复核条目（与 [conflictWrites] 一一对应）。
  final List<ImportConflict> conflicts;

  /// 覆盖模式下「文件里没有、将被软删」的本地 id（排序，可复现）。
  final List<String> removedCandidates;

  /// 七态计数。
  final Map<MergeOutcome, int> counts;

  /// 文件里出现过的表（引用完整性只扫这些表）。
  final Set<String> touchedTables;

  /// 引用修复动作（§4.4 S11–S14），进导入报告。
  final List<ReferenceFix> referenceFixes;

  /// **执行顺序**：按阶段序逐表「先占位实体、后裁决写入」，再软删、最后登记冲突。
  ///
  /// 这个顺序不是风格：`foreign_keys = ON` 之下，占位实体必须早于引用它的记录、
  /// 父实体必须早于子实体（§4.3 I.1 的「引用闭包」）。
  List<MergeWrite> get writes {
    final ordered = <MergeWrite>[];
    for (final type in kPayloadStageOrder) {
      final table = kPayloadRecordSpecs[type]!.table;
      ordered.addAll(placeholderWrites.where((MergeWrite w) => w.table == table));
      ordered.addAll(recordWrites.where((MergeWrite w) => w.table == table));
    }
    ordered
      ..addAll(removalWrites)
      ..addAll(conflictWrites);
    return ordered;
  }

  int countOf(MergeOutcome outcome) => counts[outcome] ?? 0;

  /// `insert_job.inserted_cnt`：真正插进去的行（含占位实体）。
  int get insertedCount =>
      recordWrites.where((MergeWrite w) => !w.replace).length + placeholderWrites.length;

  /// `import_job.updated_cnt`：改动了已有行的那部分（含墓碑写入与复活）。
  int get updatedCount => recordWrites.where((MergeWrite w) => w.replace).length;

  /// `import_job.removed_cnt`：覆盖模式的软删数。
  int get removedCount => removalWrites.length;

  /// `import_job.conflict_cnt`。
  int get conflictCount => conflicts.length;

  /// `import_job.skipped_cnt`。
  int get skippedCount => countOf(MergeOutcome.skip);

  /// 是否必须先让用户用条数确认才能软删（§4.4 覆盖模式护栏 1–2）。
  bool get requiresCountConfirmation => mode == ImportMode.replace && removedCandidates.isNotEmpty;
}

/// 计划器（§4.4）—— 纯函数式：同样的输入得到**逐字节相同**的计划。
///
/// 它不碰数据库、不读时钟、不生成随机数，所以「同一批记录以不同顺序导入结果是否
/// 一致」这个问题可以直接问它（见 `import.merge.converge`）。
abstract final class ImportMergePlanner {
  /// 生成计划。**不写任何东西** —— 阶段 G 在阶段 H（备份）之前，
  /// 这条顺序让「中止时库里是干净的」成为结构事实而不是承诺。
  static MergePlan plan(MergePlanRequest request) {
    final counts = <MergeOutcome, int>{for (final outcome in MergeOutcome.values) outcome: 0};
    final touched = <String>{};
    final decisions = <MergeRecordDecision>[];

    // ── 阶段 0：账本映射（§4.4 S29）──────────────────────────────────────
    //
    // 排在裁决**之前**：映射会改写 `ledger_id`，而 `ledger_id` 是内容的一部分
    // （它参与 contentEquals）。放在裁决之后，就会出现「按旧账本判定了要不要写，
    // 却按新账本写进去」—— 一行记录的字面值与它的版本判决来自两个不同的世界。
    var records = _applyLedgerRemap(request.records, request.ledgerRemap);

    // ── 阶段 0.5：引用修复的**归一化**部分（S14 / 环 / 超深）──────────────
    //
    // 与上文同理：升级为一级会改写 `parent_id`，必须发生在裁决之前。
    // `abort` 策略下整段跳过 —— 修复也是猜测，它必须由「逐条裁决」一并授权。
    var placeholders = const <ImportRecord>[];
    var fixes = const <ReferenceFix>[];
    if (request.strategy == ConflictStrategy.converge) {
      final fixed = ImportReferenceFixer.apply(
        records: records,
        localRows: request.localRows,
        placeholderDeviceId: request.localDeviceId,
        placeholderAtMilliseconds: normalizeUpdatedAtMilliseconds(request.nowMilliseconds),
      );
      records = fixed.records;
      placeholders = fixed.placeholders;
      fixes = fixed.fixes;
    }

    final byTable = <String, List<ImportRecord>>{};
    for (final record in records) {
      byTable.putIfAbsent(record.table, () => <ImportRecord>[]).add(record);
      touched.add(record.table);
    }

    // ── 阶段 G：逐表逐条裁决（阶段序 + 原行序，语句序列因此可复现）──────
    for (final type in kPayloadStageOrder) {
      final spec = kPayloadRecordSpecs[type]!;
      final tableRecords = byTable[spec.table];
      if (tableRecords == null) {
        continue;
      }
      tableRecords.sort((ImportRecord a, ImportRecord b) => a.recordIndex.compareTo(b.recordIndex));
      final localById = <String, Map<String, Object?>>{
        for (final row in request.localRows[spec.table] ?? const <Map<String, Object?>>[])
          if (row['id'] is String) row['id']! as String: row,
      };
      for (final record in tableRecords) {
        final decision = mergeRecord(
          remote: record,
          local: localById[record.id],
          mode: request.mode,
          strategy: request.strategy,
          deleteEdit: request.deleteEdit,
          skewWindowMs: request.skewWindowMs,
        );
        decisions.add(decision);
        counts.update(decision.outcome, (int n) => n + 1);
      }
    }

    final recordWrites = <MergeWrite>[
      for (final decision in decisions)
        if (decision.write != null) decision.write!,
    ];
    final placeholderWrites = <MergeWrite>[
      for (final placeholder in placeholders)
        MergeWrite(
          table: placeholder.table,
          id: placeholder.id,
          columns: placeholder.columns,
          replace: false,
        ),
    ];

    // ── 覆盖模式：文件没提到的本地记录 → 待软删（§4.4 plan 阶段第 3 条）──
    final candidates =
        request.mode == ImportMode.replace
            ? _removalCandidates(request, decisions)
            : const <_RemovalCandidate>[];
    final removalWrites = <MergeWrite>[];
    for (final candidate in candidates) {
      final row = _rowById(request.localRows, candidate);
      if (row == null) {
        continue;
      }
      removalWrites.add(
        MergeWrite(
          table: candidate.table,
          id: candidate.id,
          columns: <String, Object?>{
            'deleted_at': request.nowMilliseconds,
            'updated_at': request.nowMilliseconds,
            'rev': (row['rev'] is int ? row['rev']! as int : 1) + 1,
            'device_id': request.localDeviceId,
          },
          replace: true,
        ),
      );
    }

    // ── 冲突登记 ─────────────────────────────────────────────────────────
    //
    // `abort` 策略下**不登记**冲突行：那条 `conflict.job_id` 会指向一个
    // `status=failed` 的 job，用户在冲突面板里永远处理不掉它 ——
    // 一批没有发生的导入不该留下待办。
    // 冲突**个数**仍然进 [MergePlan.counts]（执行器靠它算出 `PFI_E_CONFLICT`
    // 的条数），只是不落库。
    final reviewable =
        request.strategy == ConflictStrategy.abort
            ? const <MergeRecordDecision>[]
            : <MergeRecordDecision>[
              for (final decision in decisions)
                if (decision.conflictKind != null) decision,
            ];
    final conflicts = <ImportConflict>[
      for (final decision in reviewable)
        ImportConflict(
          entityKind: decision.entityKind,
          recordId: decision.recordId,
          local: decision.localVersion,
          remote: decision.remoteVersion!,
          decision: MergeDecision(
            side: decision.side,
            winner:
                decision.side == MergeSide.remote
                    ? decision.remoteVersion!
                    : (decision.localVersion ?? decision.remoteVersion!),
            reason: _reasonOf(decision),
            needsUserReview: true,
          ),
          kind: decision.conflictKind!,
          autoResolvedSide: decision.side,
        ),
    ];

    return MergePlan(
      mode: request.mode,
      recordWrites: recordWrites,
      placeholderWrites: placeholderWrites,
      removalWrites: removalWrites,
      conflictWrites: <MergeWrite>[
        for (final conflict in conflicts) conflictWriteOf(conflict, request),
      ],
      conflicts: conflicts,
      removedCandidates: <String>[for (final candidate in candidates) candidate.id],
      counts: counts,
      touchedTables: touched,
      referenceFixes: fixes,
    );
  }

  /// 冲突登记语句（§2.3 `conflict`）。
  ///
  /// 主键由 `(job, 实体, id, 冲突种类)` 派生而不是随机生成：同一次导入里同一处
  /// 冲突**不可能**产生两行。随机 id 会让「同一条分歧被记了两次」变成一件靠概率
  /// 保证的事，而那恰恰是用户最不想要的结果 —— 他会以为自己有两条要处理。
  static MergeWrite conflictWriteOf(ImportConflict conflict, MergePlanRequest request) {
    final id = conflictIdOf(
      jobId: request.jobId,
      entity: conflict.entityKind,
      entityId: conflict.recordId,
      kind: conflict.kind,
      nowMilliseconds: request.nowMilliseconds,
    );
    return MergeWrite(
      table: 'conflict',
      id: id,
      columns: <String, Object?>{
        'id': id,
        'job_id': request.jobId,
        'entity': conflict.entityKind,
        'entity_id': conflict.recordId,
        'kind': conflict.kind.value,
        'local_json': jsonEncode(<String, Object?>{
          'versionStamp': conflict.local?.versionStamp,
          'contentHash': conflict.local?.contentHash,
          'deleted': conflict.local?.deleted,
        }),
        'remote_json': jsonEncode(<String, Object?>{
          'versionStamp': conflict.remote.versionStamp,
          'contentHash': conflict.remote.contentHash,
          'deleted': conflict.remote.deleted,
        }),
        // NULL = 待决（§2.3）。导入期的冲突**一律**待决：
        // 自动收敛只是为了收敛性，不代表已经替用户做了决定。
        'resolution': null,
        'resolved_at': null,
      },
      replace: false,
    );
  }

  /// 冲突行主键（确定性派生，见 [conflictWriteOf] 的说明）。
  static String conflictIdOf({
    required String jobId,
    required String entity,
    required String entityId,
    required ConflictKind kind,
    required int nowMilliseconds,
  }) => UlidGenerator.encode(
    normalizeUpdatedAtMilliseconds(nowMilliseconds),
    Sha256.instance.hash(utf8.encode('$jobId|$entity|$entityId|${kind.value}')).sublist(0, 10),
  );

  static MergeReason _reasonOf(MergeRecordDecision decision) => switch (decision.rule) {
    MergeRule.stampCollision => MergeReason.stampCollision,
    MergeRule.ambiguousWindow => MergeReason.metadataOnly,
    _ => MergeReason.newerStamp,
  };

  /// 阶段 0：账本映射（§4.4 S29「保留原 id，只把账本重映射」）。
  ///
  /// 只有**映射表里出现过的**账本才被改写：没被点名的记录原样通过。
  /// `ledger` 行自身的 id 就是账本 id，因此它改的是 `id`；其余行改 `ledger_id`。
  static List<ImportRecord> _applyLedgerRemap(
    List<ImportRecord> records,
    Map<String, String> ledgerRemap,
  ) {
    if (ledgerRemap.isEmpty) {
      return records;
    }
    final remapped = <ImportRecord>[];
    for (final record in records) {
      final isLedger = record.type == 'ledger';
      final key = isLedger ? record.id : record.columns['ledger_id'];
      final target = key is String ? ledgerRemap[key] : null;
      if (target == null) {
        remapped.add(record);
        continue;
      }
      remapped.add(
        _withColumns(
          record,
          isLedger ? <String, Object?>{'id': target} : <String, Object?>{'ledger_id': target},
        ),
      );
    }
    return remapped;
  }

  /// 覆盖模式的待软删清单。
  ///
  /// 「文件没提到」只在**同一个目标账本内**成立：别的账本的行本来就不该被这份
  /// 文件提起，把它们算进来就是一次跨账本误删。
  /// 只对**带 `ledger_id` 列**的表判定 —— `ledger` 表自身没有这一列，
  /// 它的取舍由文件里有没有那个账本决定，不属于「本地独有记录」。
  ///
  /// 没有目标账本 ⇒ **一条也不软删**（失败方向指向「少删」）。执行器那一侧
  /// 同口径（`ImportApplier._loadLedgerScope` 在 `targetLedgerId` 为空时返回空集）：
  /// 两层若不同口径，「计划说删 N 条」与「实际一条没删」就会同时成立，
  /// 而那正是护栏上要展示给用户的那个数字。
  static List<_RemovalCandidate> _removalCandidates(
    MergePlanRequest request,
    List<MergeRecordDecision> decisions,
  ) {
    final target = request.targetLedgerId;
    if (target == null) {
      return const <_RemovalCandidate>[];
    }
    final seen = <String>{for (final decision in decisions) decision.recordId};
    final candidates = <_RemovalCandidate>[];
    for (final rule in kPayloadReferenceRules) {
      if (rule.column != 'ledger_id') {
        continue;
      }
      final table = rule.child;
      for (final row in request.localRows[table] ?? const <Map<String, Object?>>[]) {
        final id = row['id'];
        if (id is! String || seen.contains(id) || row['deleted_at'] != null) {
          continue;
        }
        if (row['ledger_id'] != target) {
          // 目标账本之外的本地记录不属于这次覆盖的范围。
          continue;
        }
        candidates.add(_RemovalCandidate(table: table, id: id));
      }
    }
    candidates.sort(
      (_RemovalCandidate a, _RemovalCandidate b) =>
          a.table == b.table ? a.id.compareTo(b.id) : a.table.compareTo(b.table),
    );
    return candidates;
  }

  static Map<String, Object?>? _rowById(
    Map<String, List<Map<String, Object?>>> localRows,
    _RemovalCandidate candidate,
  ) {
    for (final row in localRows[candidate.table] ?? const <Map<String, Object?>>[]) {
      if (row['id'] == candidate.id) {
        return row;
      }
    }
    return null;
  }

  static ImportRecord _withColumns(ImportRecord record, Map<String, Object?> patch) => ImportRecord(
    type: record.type,
    table: record.table,
    id: patch['id'] is String ? patch['id']! as String : record.id,
    columns: <String, Object?>{...record.columns, ...patch},
    updatedAt: record.updatedAt,
    deviceId: record.deviceId,
    isTombstone: record.isTombstone,
    recordIndex: record.recordIndex,
  );
}

/// 待软删的本地行（表 + id）。
final class _RemovalCandidate {
  const _RemovalCandidate({required this.table, required this.id});

  final String table;
  final String id;
}

/// 记录级版本模型与合并裁决规则。
///
/// ## 这是全项目最容易写错的一处逻辑
///
/// 「无后端同步」的全部正确性都压在这个函数上。它必须同时满足三条性质，
/// 否则多设备场景会出现无法解释的现象（记录凭空复活、A 看到的结果和 B 不同、
/// 反复导入导致数据漂移）：
///
///   1. **可交换**：`resolve(a, b)` 与 `resolve(b, a)` 必须得到同一个胜者。
///      否则两台设备的同步顺序不同 → 最终状态不同 → 用户永远对不上账。
///   2. **幂等**：`resolve(a, a)` 必须是 no-op。
///      否则「把同一份备份导入两次」会改变数据 —— 这在用户重试时会真的发生。
///   3. **可结合**：对任意集合反复两两合并，结果与顺序无关（收敛性）。
///      数学上就是「把这个集合按全序取最大值」，但用错字段就退化成不可交换比较
///      （经典错误：`a.updatedAt >= b.updatedAt ? a : b`，在相等时会偏向左边）。
///
/// ## 为什么版本戳用 ULID 而不是毫秒时间戳
///
/// 时间戳的粒度是毫秒。同一台设备在同一毫秒内对同一条记录写两次，
/// 会产生两个「updatedAt 相同」却内容不同的版本 —— 此时任何比较函数都
/// 无法区分它们，只能抛错或随机选一个，收敛性当场失效。
///
/// ULID 由本项目的 [UlidGenerator] 生成，保证**同一进程内严格单调递增**
/// （同毫秒内递增随机部分，时钟回拨时沿用上一时间戳）。
/// 于是「版本戳的字典序」就是一个真实的全序，而其中还编码了写入时刻，
/// 可以直接还原用于展示。一个字段同时解决排序与展示两个需求。
///
/// ## 与「软删除防复活」的关系
///
/// 删除操作本身也产生一个新的版本戳（就是删除发生的时刻），
/// 因此墓碑（tombstone）天然地大于被删除内容的版本戳，自动胜出。
/// 不需要为「删除」单独设计优先级规则 —— 那是把同一个问题解两遍。
library;

import 'package:pf_core/pf_core.dart';

/// 一条记录的版本元数据。
///
/// 刻意不含业务字段：合并算法只应该看到「谁改的、什么时候改的、内容指纹是什么」。
/// 一旦让合并逻辑接触到金额、分类这些字段，它就会开始长出业务特例，
/// 而那正是收敛性被破坏的开始。
final class RecordVersion {
  const RecordVersion({
    required this.id,
    required this.versionStamp,
    required this.deviceId,
    required this.contentHash,
    this.deleted = false,
  });

  /// 记录主键（ULID）。
  final String id;

  /// 版本戳（ULID）。字典序即全序。
  final String versionStamp;

  /// 写入设备的 ID（ULID）。仅用于展示「这条来自哪台设备」，不参与排序。
  final String deviceId;

  /// 规范化序列化后内容的 SHA-256（小写十六进制）。
  ///
  /// 用途是区分「同一内容的新版本」与「真正的内容改动」：
  /// 前者不必打扰用户，后者需要。没有这个字段，任何元数据差异都会被当成冲突。
  final String contentHash;

  /// 是否为墓碑（已软删除）。
  final bool deleted;

  /// 写入时刻（UTC）。从 [versionStamp] 解出，用于展示与调试。
  ///
  /// 刻意不单独存储：两个可以互相推导的时间字段迟早会不一致。
  ///
  /// **前置条件：`versionStamp` 必须是合法 ULID**，否则会抛 [FormatException]。
  /// 处理来路不明的元数据（导入的备份、损坏的文件）时改用 [stampMilliseconds]。
  DateTime get updatedAt => Ulid.timestampOf(versionStamp);

  /// [versionStamp] 中编码的毫秒时间戳；版本戳不合法时返回 `null`。
  ///
  /// 与 [updatedAt] 的区别是「判定」而非「解读」：
  /// 对账路径上会遇到不可信的版本戳，那里需要的是「这条记录的时间可不可信」，
  /// 而不是让一次解析失败炸掉整个合并过程。
  int? get stampMilliseconds => Ulid.tryMillisecondsOf(versionStamp);

  /// 是否为结构合法的版本元数据。
  bool get isValid =>
      Ulid.isValid(id) &&
      Ulid.isValid(versionStamp) &&
      Ulid.isValid(deviceId) &&
      contentHash.length == 64;

  /// 版本戳相同（同一时刻、同一设备的同一次写入）。
  bool hasSameStamp(RecordVersion other) => versionStamp == other.versionStamp;

  /// 内容与删除状态是否一致（忽略版本戳与设备）。
  bool hasSameContent(RecordVersion other) =>
      contentHash == other.contentHash && deleted == other.deleted;

  /// 完全一致（含版本戳）。仅用于判断 no-op。
  bool isIdenticalTo(RecordVersion other) =>
      id == other.id &&
      versionStamp == other.versionStamp &&
      deviceId == other.deviceId &&
      contentHash == other.contentHash &&
      deleted == other.deleted;

  @override
  String toString() =>
      'RecordVersion($id, stamp=$versionStamp, device=$deviceId, '
      'hash=${contentHash.substring(0, 8)}…, deleted=$deleted)';
}

/// 合并结果的来源侧。
enum MergeSide {
  /// 两侧一致，无需改动。
  none('none'),

  /// 本地版本胜出。
  local('local'),

  /// 导入 / 远端版本胜出。
  remote('remote');

  const MergeSide(this.wireName);

  final String wireName;
}

/// 裁决原因。用于日志与冲突 UI 的解释文案。
enum MergeReason {
  /// 两侧完全一致。
  identical('identical'),

  /// 时间戳更晚的一方胜出。
  newerStamp('newer_stamp'),

  /// 版本戳相同但内容不同（正常流程不会产生；说明有实现缺陷或被篡改）。
  stampCollision('stamp_collision'),

  /// 内容相同、只有元数据不同 → 按版本戳取较大者，不打扰用户。
  metadataOnly('metadata_only');

  const MergeReason(this.wireName);

  final String wireName;
}

/// 一条记录的合并裁决。
final class MergeDecision {
  const MergeDecision({
    required this.side,
    required this.winner,
    required this.reason,
    required this.needsUserReview,
  });

  /// 胜出来源侧。
  final MergeSide side;

  /// 胜出的版本。
  final RecordVersion winner;

  /// 裁决原因。
  final MergeReason reason;

  /// 是否需要让用户裁决。
  ///
  /// 本项目采用「确定性 LWW」而不是「暂停并要求用户选择」，原因是后者在
  /// 多设备离线场景下无法收敛：用户在一台设备上选了 A，另一台上选了 B，
  /// 下一次同步又会冲突。
  ///
  /// 因此策略是：**先确定性地收敛，再把可疑的分歧呈现给用户复核**。
  /// 用户改不改都不影响收敛性，改了就产生一个更新的版本戳。
  final bool needsUserReview;

  /// 是否什么都不用做。
  bool get isNoop => side == MergeSide.none;

  @override
  String toString() =>
      'MergeDecision(${side.wireName}, ${reason.wireName}'
      '${needsUserReview ? ', needsReview' : ''})';
}

/// 裁决两个版本。[local] 是本地库中的版本，[remote] 是导入文件中的版本。
///
/// ## 规则（顺序即优先级）
///
/// 1. **ID 必须相同**，否则抛 `PFI_E_INCOMPATIBLE`。
///    把不同记录放在一起比较，说明上游的分组逻辑坏了，必须立刻暴露。
/// 2. **完全一致 → no-op**。这是幂等性的保证：同一份备份导入两次结果不变。
/// 3. **内容与删除状态一致 → 取版本戳较大者**，`needsUserReview = false`。
///    这覆盖「另一台设备只是重写了同样的内容」这种情况，
///    不该用它来打扰用户。
/// 4. **版本戳相同但内容不同 → 确定性选一方并标记需复核**。
///    正常流程不可能产生（同设备同戳 = 同一次写入）。出现即说明
///    版本戳生成被破坏，或数据被外部修改过。
/// 5. **其余情况 → 版本戳较大者胜出**。
///    若两个戳落在同一毫秒内（跨设备并发写），标记 `needsUserReview = true`，
///    因为此时「谁更新」没有语义上的强弱之分，只是被全序安排了一个结果。
///
/// 注意规则 5 的比较用 `compareTo` 而不是 `>=`：
/// `>=` 在相等时偏向左侧，会直接破坏可交换性。
MergeDecision resolveRecordVersion({required RecordVersion local, required RecordVersion remote}) {
  if (local.id != remote.id) {
    throw ImportExportError.incompatible(detail: '记录 ID 不同（${local.id} vs ${remote.id}），不能比较版本');
  }
  if (!local.isValid || !remote.isValid) {
    throw ImportExportError.incompatible(
      detail: '版本元数据不合法（ID / 版本戳 / 设备 ID 必须是 ULID，内容指纹必须是 64 位十六进制）',
    );
  }

  // 规则 2：完全一致
  if (local.isIdenticalTo(remote)) {
    return MergeDecision(
      side: MergeSide.none,
      winner: local,
      reason: MergeReason.identical,
      needsUserReview: false,
    );
  }

  final comparison = local.versionStamp.compareTo(remote.versionStamp);

  // 规则 3：内容一致，只是元数据不同 —— 不打扰用户
  if (local.hasSameContent(remote)) {
    return MergeDecision(
      side: comparison > 0 ? MergeSide.local : MergeSide.remote,
      winner: comparison > 0 ? local : remote,
      reason: MergeReason.metadataOnly,
      needsUserReview: false,
    );
  }

  // 规则 4：同戳不同内容 —— 不可能由正常流程产生
  if (comparison == 0) {
    final localWins = local.contentHash.compareTo(remote.contentHash) > 0;
    return MergeDecision(
      side: localWins ? MergeSide.local : MergeSide.remote,
      winner: localWins ? local : remote,
      reason: MergeReason.stampCollision,
      needsUserReview: true,
    );
  }

  // 规则 5：版本戳较大者胜出
  final localWins = comparison > 0;
  return MergeDecision(
    side: localWins ? MergeSide.local : MergeSide.remote,
    winner: localWins ? local : remote,
    reason: MergeReason.newerStamp,
    needsUserReview: _isSameMillisecond(local, remote),
  );
}

/// 两个版本戳是否落在同一毫秒内（跨设备并发写的判定）。
bool _isSameMillisecond(RecordVersion a, RecordVersion b) =>
    a.updatedAt.millisecondsSinceEpoch == b.updatedAt.millisecondsSinceEpoch;

/// 一组版本的收敛结果。
final class VersionReduceResult {
  const VersionReduceResult({
    required this.winner,
    required this.needsUserReview,
    required this.mergedCount,
  });

  /// 收敛后的胜者。
  final RecordVersion winner;

  /// 过程中是否出现过需要用户复核的分歧。
  final bool needsUserReview;

  /// 参与合并的版本个数。
  final int mergedCount;

  @override
  String toString() =>
      'VersionReduceResult(${winner.versionStamp}, merged=$mergedCount'
      '${needsUserReview ? ', needsReview' : ''})';
}

/// 对一组版本求收敛结果（反复两两合并）。
///
/// 该函数的存在是为了让「可结合性」这条性质可以被直接测试：
/// 打乱输入顺序后结果必须完全一致。
///
/// 空集合返回 null。集合中混入不同 ID 的版本会抛 `PFI_E_INCOMPATIBLE`
/// （由 [resolveRecordVersion] 抛出）。
VersionReduceResult? reduceRecordVersions(Iterable<RecordVersion> versions) {
  final iterator = versions.iterator;
  if (!iterator.moveNext()) return null;

  var winner = iterator.current;
  var needsReview = false;
  var count = 1;

  while (iterator.moveNext()) {
    final decision = resolveRecordVersion(local: winner, remote: iterator.current);
    winner = decision.winner;
    needsReview = needsReview || decision.needsUserReview;
    count += 1;
  }

  return VersionReduceResult(winner: winner, needsUserReview: needsReview, mergedCount: count);
}

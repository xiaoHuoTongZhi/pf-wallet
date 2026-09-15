/// M0 驱动：记录版本与合并裁决。
///
/// ## 这是全项目最容易写错的一处逻辑
///
/// 「无后端同步」的全部正确性都压在
/// [resolveRecordVersion] 这一个函数上。它必须同时满足：
///
///   1. **可交换** —— `resolve(a,b)` 与 `resolve(b,a)` 得到同一个胜者
///   2. **幂等** —— 同一份备份导入两次结果不变
///   3. **可结合** —— 集合反复两两合并的结果与顺序无关
///
/// 单测能证明这三条性质在随机采样下成立，但**证不了未来某次改动不会破坏它**。
/// 因此这里额外用固定向量把几个关键裁决钉死：同戳不同内容、同毫秒跨设备写、
/// 墓碑胜出。这三条是「感觉上无关紧要、破坏后极难察觉」的典型位置。
library;

import 'package:pf_io/pf_io.dart';

import '../driver.dart';
import '../json_util.dart';
import '../outcome.dart';

/// 裁决两个版本。
final class MergeResolveDriver extends VectorDriver {
  const MergeResolveDriver();

  @override
  String get kind => 'merge.resolve';

  @override
  String get description => '对两个版本做确定性裁决（LWW + 同毫秒标记待复核）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'local': '{id, versionStamp, deviceId, contentHash, deleted?}',
    'remote': '{id, versionStamp, deviceId, contentHash, deleted?}',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final decision = resolveRecordVersion(
      local: _version(requireMap(input, 'local', kind), '$kind.local'),
      remote: _version(requireMap(input, 'remote', kind), '$kind.remote'),
    );
    return VectorOutcome.value(<String, Object?>{
      'side': decision.side.wireName,
      'reason': decision.reason.wireName,
      'needsUserReview': decision.needsUserReview,
      'isNoop': decision.isNoop,
      'winnerVersionStamp': decision.winner.versionStamp,
      'winnerContentHash': decision.winner.contentHash,
      'winnerDeleted': decision.winner.deleted,
      'winnerDeviceId': decision.winner.deviceId,
    });
  }
}

/// 一组版本的收敛。
///
/// 输入顺序会被刻意打乱后重跑，用来验证「可交换 / 可结合」——
/// 因此这里的期望值是**顺序无关**的：只写胜者与计数，不写「第几次比较谁赢」。
final class MergeReduceDriver extends VectorDriver {
  const MergeReduceDriver();

  @override
  String get kind => 'merge.reduce';

  @override
  String get description => '对一组版本求收敛结果，并在打乱顺序后复核结果不变';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'versions': '数组，元素为 {id, versionStamp, deviceId, contentHash, deleted?}',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final rawVersions = requireList(input, 'versions', kind);
    final versions = <RecordVersion>[];
    for (var i = 0; i < rawVersions.length; i++) {
      final Object? raw = rawVersions[i];
      if (raw is! Map<String, Object?>) {
        throwVectorInput(kind, 'versions[$i] 必须是对象');
      }
      versions.add(_version(raw, '$kind.versions[$i]'));
    }

    final forward = reduceRecordVersions(versions);
    if (forward == null) {
      return VectorOutcome.value(<String, Object?>{
        'winnerVersionStamp': null,
        'mergedCount': 0,
        'needsUserReview': false,
        'orderIndependent': true,
      });
    }

    // 逆序与「按随机但确定的方式重排」各跑一次。
    // 用固定顺序而不是真随机：向量必须可复现。
    final reversed = reduceRecordVersions(versions.reversed);
    final rotated = reduceRecordVersions(<RecordVersion>[
      ...versions.skip(versions.length ~/ 2),
      ...versions.take(versions.length ~/ 2),
    ]);

    return VectorOutcome.value(<String, Object?>{
      'winnerVersionStamp': forward.winner.versionStamp,
      'winnerContentHash': forward.winner.contentHash,
      'winnerDeleted': forward.winner.deleted,
      'mergedCount': forward.mergedCount,
      'needsUserReview': forward.needsUserReview,
      'orderIndependent':
          reversed?.winner.versionStamp == forward.winner.versionStamp &&
          rotated?.winner.versionStamp == forward.winner.versionStamp,
      'reviewFlagOrderIndependent':
          reversed?.needsUserReview == forward.needsUserReview &&
          rotated?.needsUserReview == forward.needsUserReview,
    });
  }
}

/// 版本元数据自洽性。
final class MergeVersionValidityDriver extends VectorDriver {
  const MergeVersionValidityDriver();

  @override
  String get kind => 'merge.version.validity';

  @override
  String get description => '版本元数据自洽性（ID / 版本戳 / 设备 ID 必为 ULID，指纹必为 64 位十六进制）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'version': '{id, versionStamp, deviceId, contentHash, deleted?}',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final version = _version(requireMap(input, 'version', kind), '$kind.version');
    return VectorOutcome.value(<String, Object?>{
      'valid': version.isValid,
      'isTombstone': version.deleted,
      // 时间的**唯一来源是版本戳**，因此这里只按版本戳能否解出来决定给不给值，
      // 不按整体的 `valid` 决定：内容指纹长度不对并不妨碍读出「这条记录何时写的」，
      // 而对账诊断恰恰需要这个时间。
      // 反过来，版本戳解不出来时**不给兜底值**（不是 0、不是当前时间）——
      // 不合法数据不该被「尽量解释」，否则一次元数据损坏会被悄悄当成一条正常记录。
      'updatedAtMilliseconds': version.stampMilliseconds,
      'contentHashLength': version.contentHash.length,
    });
  }
}

RecordVersion _version(Map<String, Object?> json, String path) => RecordVersion(
  id: requireString(json, 'id', path),
  versionStamp: requireString(json, 'versionStamp', path),
  deviceId: requireString(json, 'deviceId', path),
  contentHash: requireString(json, 'contentHash', path),
  deleted: optionalBool(json, 'deleted', false),
);

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_io/pf_io.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// 测试夹具：可控时钟的 ULID 生成器，保证版本戳单调且可精确构造时间关系
// ---------------------------------------------------------------------------

int _nowMilliseconds = 1735689600000; // 2025-01-01T00:00:00Z

final UlidGenerator _generator = UlidGenerator(
  random: math.Random(20260915),
  nowMilliseconds: () => _nowMilliseconds,
);

/// 生成一个单调递增的 ULID（可同时用作 ID / 版本戳 / 设备 ID）。
String nextUlid() => _generator.next();

/// 推进时钟。
void tick(int milliseconds) => _nowMilliseconds += milliseconds;

/// 由种子派生一个 64 位十六进制内容指纹（确定性，便于断言）。
String contentHashFor(String seed) {
  var accumulator = 7;
  for (final unit in seed.codeUnits) {
    accumulator = (accumulator * 31 + unit) & 0xFF;
  }
  final bytes = Uint8List(32);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = (accumulator + i * 17) % 256;
  }
  return toHex(bytes);
}

void main() {
  group('夹具自检（避免测试本身失效）', () {
    test('生成的 ULID 合法且单调', () {
      final ids = <String>[for (var i = 0; i < 50; i++) nextUlid()];
      for (final id in ids) {
        expect(Ulid.isValid(id), isTrue);
      }
      final sorted = List<String>.of(ids)..sort();
      expect(ids, equals(sorted));
    });

    test('内容指纹为 64 位十六进制', () {
      final hash = contentHashFor('x');
      expect(hash.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(hash), isTrue);
    });
  });

  group('基本规则', () {
    test('完全一致 → no-op', () {
      final id = nextUlid();
      final version = RecordVersion(
        id: id,
        versionStamp: nextUlid(),
        deviceId: nextUlid(),
        contentHash: contentHashFor('a'),
      );

      final forward = resolveRecordVersion(local: version, remote: version);
      expect(forward.isNoop, isTrue);
      expect(forward.reason, MergeReason.identical);
      expect(forward.needsUserReview, isFalse);
    });

    test('更新的版本戳胜出（本地更新）', () {
      final id = nextUlid();
      final older = nextUlid();
      tick(1000);
      final newer = nextUlid();

      final decision = resolveRecordVersion(
        local: RecordVersion(
          id: id,
          versionStamp: newer,
          deviceId: nextUlid(),
          contentHash: contentHashFor('local'),
        ),
        remote: RecordVersion(
          id: id,
          versionStamp: older,
          deviceId: nextUlid(),
          contentHash: contentHashFor('remote'),
        ),
      );

      expect(decision.side, MergeSide.local);
      expect(decision.reason, MergeReason.newerStamp);
      expect(decision.needsUserReview, isFalse);
    });

    test('更新的版本戳胜出（远端更新）', () {
      final id = nextUlid();
      final older = nextUlid();
      tick(1000);
      final newer = nextUlid();

      final decision = resolveRecordVersion(
        local: RecordVersion(
          id: id,
          versionStamp: older,
          deviceId: nextUlid(),
          contentHash: contentHashFor('local'),
        ),
        remote: RecordVersion(
          id: id,
          versionStamp: newer,
          deviceId: nextUlid(),
          contentHash: contentHashFor('remote'),
        ),
      );

      expect(decision.side, MergeSide.remote);
      expect(decision.needsUserReview, isFalse);
    });

    test('内容相同、只有元数据不同 → 取较大戳且不打扰用户', () {
      final id = nextUlid();
      final older = nextUlid();
      tick(10);
      final newer = nextUlid();
      final sharedHash = contentHashFor('same');

      final decision = resolveRecordVersion(
        local: RecordVersion(
          id: id,
          versionStamp: older,
          deviceId: nextUlid(),
          contentHash: sharedHash,
        ),
        remote: RecordVersion(
          id: id,
          versionStamp: newer,
          deviceId: nextUlid(),
          contentHash: sharedHash,
        ),
      );

      expect(decision.reason, MergeReason.metadataOnly);
      expect(decision.side, MergeSide.remote);
      expect(decision.needsUserReview, isFalse);
    });

    test('版本戳相同但内容不同 → 确定性选择 + 标记复核', () {
      final id = nextUlid();
      final sharedStamp = nextUlid();
      final local = RecordVersion(
        id: id,
        versionStamp: sharedStamp,
        deviceId: nextUlid(),
        contentHash: contentHashFor('A'),
      );
      final remote = RecordVersion(
        id: id,
        versionStamp: sharedStamp,
        deviceId: nextUlid(),
        contentHash: contentHashFor('B'),
      );

      final forward = resolveRecordVersion(local: local, remote: remote);
      final backward = resolveRecordVersion(local: remote, remote: local);

      expect(forward.reason, MergeReason.stampCollision);
      expect(forward.needsUserReview, isTrue);
      expect(forward.winner.contentHash, backward.winner.contentHash, reason: '同戳冲突的裁决必须可交换');
    });

    test('跨设备同毫秒并发写 → 仍确定性收敛，但标记复核', () {
      final id = nextUlid();
      final stampA = nextUlid();
      final stampB = nextUlid(); // 不推进时钟 → 同一毫秒
      expect(
        Ulid.timestampOf(stampA).millisecondsSinceEpoch,
        Ulid.timestampOf(stampB).millisecondsSinceEpoch,
      );

      final local = RecordVersion(
        id: id,
        versionStamp: stampA,
        deviceId: nextUlid(),
        contentHash: contentHashFor('A'),
      );
      final remote = RecordVersion(
        id: id,
        versionStamp: stampB,
        deviceId: nextUlid(),
        contentHash: contentHashFor('B'),
      );

      final forward = resolveRecordVersion(local: local, remote: remote);
      final backward = resolveRecordVersion(local: remote, remote: local);

      expect(forward.needsUserReview, isTrue);
      expect(forward.reason, MergeReason.newerStamp);
      expect(forward.winner.versionStamp, backward.winner.versionStamp);
    });
  });

  group('软删除防复活', () {
    test('墓碑胜出，无论比较顺序', () {
      final id = nextUlid();
      final liveStamp = nextUlid();
      tick(5000);
      final deleteStamp = nextUlid();

      final live = RecordVersion(
        id: id,
        versionStamp: liveStamp,
        deviceId: nextUlid(),
        contentHash: contentHashFor('live'),
      );
      final tombstone = RecordVersion(
        id: id,
        versionStamp: deleteStamp,
        deviceId: nextUlid(),
        contentHash: contentHashFor('tombstone'),
        deleted: true,
      );

      final a = resolveRecordVersion(local: tombstone, remote: live);
      final b = resolveRecordVersion(local: live, remote: tombstone);

      expect(a.winner.deleted, isTrue);
      expect(b.winner.deleted, isTrue, reason: '顺序不能影响墓碑胜出');
      expect(a.winner.versionStamp, b.winner.versionStamp);
    });

    test('三设备场景：删除后再被旧数据导入，墓碑仍胜出', () {
      final id = nextUlid();
      final v1 = nextUlid();
      tick(1000);
      final v2 = nextUlid();
      tick(1000);
      final tombstoneStamp = nextUlid();

      final versions = <RecordVersion>[
        RecordVersion(
          id: id,
          versionStamp: v1,
          deviceId: nextUlid(),
          contentHash: contentHashFor('v1'),
        ),
        RecordVersion(
          id: id,
          versionStamp: v2,
          deviceId: nextUlid(),
          contentHash: contentHashFor('v2'),
        ),
        RecordVersion(
          id: id,
          versionStamp: tombstoneStamp,
          deviceId: nextUlid(),
          contentHash: contentHashFor('tomb'),
          deleted: true,
        ),
      ];

      final result = reduceRecordVersions(versions);
      expect(result, isNotNull);
      expect(result!.winner.deleted, isTrue);
      expect(result.winner.versionStamp, tombstoneStamp);
    });
  });

  group('收敛性（这是无后端同步全部正确性的来源）', () {
    test('可交换：正反两序得到同一胜者', () {
      final id = nextUlid();
      final first = RecordVersion(
        id: id,
        versionStamp: nextUlid(),
        deviceId: nextUlid(),
        contentHash: contentHashFor('first'),
      );
      final second = RecordVersion(
        id: id,
        versionStamp: nextUlid(),
        deviceId: nextUlid(),
        contentHash: contentHashFor('second'),
      );

      expect(
        resolveRecordVersion(local: first, remote: second).winner.versionStamp,
        resolveRecordVersion(local: second, remote: first).winner.versionStamp,
      );
    });

    test('可交换：1000 组随机版本对（含同毫秒、同内容、墓碑）', () {
      final random = math.Random(20260915);

      for (var trial = 0; trial < 1000; trial++) {
        final id = nextUlid();
        final sameMillisecond = random.nextBool();
        final stampA = nextUlid();
        if (!sameMillisecond) tick(1 + random.nextInt(1000));
        final stampB = nextUlid();

        final sameContent = random.nextInt(5) == 0;
        final local = RecordVersion(
          id: id,
          versionStamp: stampA,
          deviceId: nextUlid(),
          contentHash: sameContent ? contentHashFor('shared') : contentHashFor('a$trial'),
          deleted: random.nextInt(10) == 0,
        );
        final remote = RecordVersion(
          id: id,
          versionStamp: stampB,
          deviceId: nextUlid(),
          contentHash: sameContent ? contentHashFor('shared') : contentHashFor('b$trial'),
          deleted: random.nextInt(10) == 0,
        );

        final forward = resolveRecordVersion(local: local, remote: remote);
        final backward = resolveRecordVersion(local: remote, remote: local);

        expect(
          forward.winner.versionStamp,
          backward.winner.versionStamp,
          reason: '第 $trial 组不满足可交换性',
        );
        expect(forward.winner.contentHash, backward.winner.contentHash);
        expect(forward.winner.deleted, backward.winner.deleted);
      }
    });

    test('幂等：与自身合并不改变任何东西', () {
      for (var trial = 0; trial < 50; trial++) {
        final version = RecordVersion(
          id: nextUlid(),
          versionStamp: nextUlid(),
          deviceId: nextUlid(),
          contentHash: contentHashFor('idempotent$trial'),
          deleted: trial.isOdd,
        );
        final decision = resolveRecordVersion(local: version, remote: version);
        expect(decision.isNoop, isTrue);
        expect(decision.winner.versionStamp, version.versionStamp);
      }
    });

    test('可结合：200 次随机打乱后收敛结果完全一致', () {
      final id = nextUlid();
      final versions = <RecordVersion>[
        for (var i = 0; i < 8; i++)
          RecordVersion(
            id: id,
            versionStamp: nextUlid(),
            deviceId: nextUlid(),
            contentHash: contentHashFor('v$i'),
            deleted: i == 3,
          ),
      ];

      final reference = reduceRecordVersions(versions);
      expect(reference, isNotNull);

      final random = math.Random(7);
      for (var trial = 0; trial < 200; trial++) {
        final shuffled = List<RecordVersion>.of(versions)..shuffle(random);
        final result = reduceRecordVersions(shuffled);
        expect(result!.winner.versionStamp, reference!.winner.versionStamp);
        expect(result.winner.contentHash, reference.winner.contentHash);
      }
    });

    test('可结合：同一份数据重复合并两次结果不变（导入重试安全）', () {
      final id = nextUlid();
      final versions = <RecordVersion>[
        for (var i = 0; i < 4; i++)
          RecordVersion(
            id: id,
            versionStamp: nextUlid(),
            deviceId: nextUlid(),
            contentHash: contentHashFor('dup$i'),
          ),
      ];

      final first = reduceRecordVersions(versions)!.winner;
      final second = reduceRecordVersions(<RecordVersion>[first, ...versions])!.winner;
      expect(second.versionStamp, first.versionStamp);
    });

    test('reduceRecordVersions 对空集合返回 null', () {
      expect(reduceRecordVersions(const <RecordVersion>[]), isNull);
    });
  });

  group('非法输入必须硬失败', () {
    test('ID 不同 → PFI_E_INCOMPATIBLE', () {
      final a = RecordVersion(
        id: nextUlid(),
        versionStamp: nextUlid(),
        deviceId: nextUlid(),
        contentHash: contentHashFor('a'),
      );
      final b = RecordVersion(
        id: nextUlid(),
        versionStamp: nextUlid(),
        deviceId: nextUlid(),
        contentHash: contentHashFor('b'),
      );

      expect(
        () => resolveRecordVersion(local: a, remote: b),
        throwsA(isA<ImportExportError>().having((e) => e.code, 'code', PfErrorCode.ioIncompatible)),
      );
    });

    test('版本戳不是合法 ULID → PFI_E_INCOMPATIBLE', () {
      final id = nextUlid();
      final broken = RecordVersion(
        id: id,
        versionStamp: 'not-a-ulid',
        deviceId: id,
        contentHash: contentHashFor('x'),
      );
      final valid = RecordVersion(
        id: id,
        versionStamp: nextUlid(),
        deviceId: id,
        contentHash: contentHashFor('y'),
      );

      expect(
        () => resolveRecordVersion(local: valid, remote: broken),
        throwsA(isA<ImportExportError>()),
      );
    });

    test('内容指纹长度不对 → PFI_E_INCOMPATIBLE', () {
      final id = nextUlid();
      final broken = RecordVersion(
        id: id,
        versionStamp: nextUlid(),
        deviceId: id,
        contentHash: 'deadbeef',
      );
      expect(broken.isValid, isFalse);
      expect(
        () => resolveRecordVersion(
          local: broken,
          remote: RecordVersion(
            id: id,
            versionStamp: nextUlid(),
            deviceId: id,
            contentHash: contentHashFor('y'),
          ),
        ),
        throwsA(isA<ImportExportError>()),
      );
    });

    test('reduce 过程中混入不同 ID 也会失败（不静默吞掉）', () {
      final id = nextUlid();
      expect(
        () => reduceRecordVersions(<RecordVersion>[
          RecordVersion(
            id: id,
            versionStamp: nextUlid(),
            deviceId: id,
            contentHash: contentHashFor('a'),
          ),
          RecordVersion(
            id: nextUlid(),
            versionStamp: nextUlid(),
            deviceId: id,
            contentHash: contentHashFor('b'),
          ),
        ]),
        throwsA(isA<ImportExportError>()),
      );
    });
  });

  group('RecordVersion 派生属性', () {
    test('updatedAt 由版本戳解出（不单独存储，避免两个字段不一致）', () {
      tick(12345);
      final stamp = nextUlid();
      final version = RecordVersion(
        id: nextUlid(),
        versionStamp: stamp,
        deviceId: nextUlid(),
        contentHash: contentHashFor('t'),
      );
      expect(version.updatedAt.isUtc, isTrue);
      expect(
        version.updatedAt.millisecondsSinceEpoch,
        Ulid.timestampOf(stamp).millisecondsSinceEpoch,
      );
    });

    test('hasSameStamp / hasSameContent 语义清晰', () {
      final id = nextUlid();
      final stamp = nextUlid();
      final hash = contentHashFor('h');
      final a = RecordVersion(id: id, versionStamp: stamp, deviceId: id, contentHash: hash);
      final b = RecordVersion(id: id, versionStamp: stamp, deviceId: nextUlid(), contentHash: hash);

      expect(a.hasSameStamp(b), isTrue);
      expect(a.hasSameContent(b), isTrue);
      expect(a.isIdenticalTo(b), isFalse, reason: '设备不同则不是同一次写入');
    });

    test('删除状态参与内容比较（墓碑与活记录不算同内容）', () {
      final id = nextUlid();
      final stamp = nextUlid();
      final hash = contentHashFor('h');
      final live = RecordVersion(id: id, versionStamp: stamp, deviceId: id, contentHash: hash);
      final tombstone = RecordVersion(
        id: id,
        versionStamp: stamp,
        deviceId: id,
        contentHash: hash,
        deleted: true,
      );
      expect(live.hasSameContent(tombstone), isFalse);
    });
  });
}

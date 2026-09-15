import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';
import 'package:test/test.dart';

Migration migration(int version) => Migration(
  version: version,
  description: 'v$version',
  statements: <String>['CREATE TABLE IF NOT EXISTS t$version (id TEXT PRIMARY KEY);'],
);

List<Migration> chain(int highest) => List<Migration>.generate(highest, (i) => migration(i + 1));

/// 计划构建的测试包装：**显式抬高** `maxSupportedVersion`。
///
/// M0 时实现只支持 schema v1，而迁移链的正确性（多步排序、断裂检测）
/// 需要至少 4~5 个版本才谈得上。若沿用默认值，`PFD_E_SCHEMA_TOO_NEW`
/// 会先一步拦下所有 `to > 1` 的用例，于是这些用例测的其实是同一件事。
///
/// 「默认值就是当前实现支持的版本」这条**生产安全性质**由
/// 《目标版本高于实现支持》《默认上限就是当前实现版本》两个用例单独守着。
const int _testMaxSupported = 9;

MigrationPlan buildPlan({
  required int from,
  required int to,
  required List<Migration> registered,
}) => MigrationPlan.build(
  from: from,
  to: to,
  registered: registered,
  maxSupportedVersion: _testMaxSupported,
);

void main() {
  group('MigrationPlan.build · 正常路径', () {
    test('起始与目标相同 → 空计划', () {
      final plan = MigrationPlan.build(from: 3, to: 3, registered: chain(3));
      expect(plan.isEmpty, isTrue);
      expect(plan.stepCount, 0);
    });

    test('单步', () {
      final plan = buildPlan(from: 1, to: 2, registered: chain(2));
      expect(plan.stepCount, 1);
      expect(plan.steps.single.version, 2);
    });

    test('多步按版本升序排列', () {
      final shuffled = <Migration>[migration(4), migration(2), migration(5), migration(3)];
      final plan = buildPlan(from: 1, to: 5, registered: shuffled);
      expect(plan.steps.map((m) => m.version), <int>[2, 3, 4, 5]);
    });

    test('只取区间内的迁移，不执行多余步骤', () {
      final plan = buildPlan(from: 2, to: 4, registered: chain(6));
      expect(plan.steps.map((m) => m.version), <int>[3, 4]);
    });

    test('计划不可变（防止上层误改）', () {
      final plan = buildPlan(from: 1, to: 2, registered: chain(2));
      expect(() => plan.steps.add(migration(9)), throwsUnsupportedError);
    });
  });

  group('MigrationPlan.build · 必须硬失败的情形', () {
    test('迁移链断裂（缺 v3）绝不跳过', () {
      final registered = <Migration>[migration(2), migration(4)];
      expect(() => buildPlan(from: 1, to: 4, registered: registered), throwsA(isA<DomainError>()));
    });

    test('缺少起始后的第一步', () {
      expect(
        () => buildPlan(from: 1, to: 2, registered: <Migration>[migration(3)]),
        throwsA(isA<DomainError>()),
      );
    });

    test('同一版本号被两个迁移占用', () {
      final duplicated = <Migration>[migration(2), migration(2)];
      expect(() => buildPlan(from: 1, to: 2, registered: duplicated), throwsA(isA<DomainError>()));
    });

    test('目标版本高于实现支持 → PFD_E_SCHEMA_TOO_NEW', () {
      expect(
        () => MigrationPlan.build(from: 1, to: 9, registered: chain(9), maxSupportedVersion: 5),
        throwsA(isA<StorageError>().having((e) => e.code, 'code', PfErrorCode.storageSchemaTooNew)),
      );
    });

    test('默认上限就是当前实现版本：不显式抬高时，目标超版一律拒绝', () {
      // 这条是**生产路径**的护栏：用户手机上装的是旧版本 App，
      // 却打开了新版本写过的库，必须在动任何数据之前停下。
      expect(
        () => MigrationPlan.build(from: 1, to: PfSchema.current + 1, registered: chain(9)),
        throwsA(isA<StorageError>().having((e) => e.code, 'code', PfErrorCode.storageSchemaTooNew)),
      );
    });

    test('起始版本高于目标版本（降级）被拒绝', () {
      expect(() => buildPlan(from: 5, to: 3, registered: chain(5)), throwsA(isA<StorageError>()));
    });

    test('起始版本低于初始版本被拒绝', () {
      expect(() => buildPlan(from: 0, to: 2, registered: chain(2)), throwsA(isA<DomainError>()));
    });

    test('缺少目标版本的迁移定义', () {
      expect(
        () => buildPlan(from: 1, to: 3, registered: <Migration>[migration(2)]),
        throwsA(isA<DomainError>()),
      );
    });
  });

  group('Migration.validate', () {
    test('无语句被拒绝', () {
      expect(
        () => const Migration(version: 2, description: 'empty', statements: <String>[]).validate(),
        throwsA(isA<DomainError>()),
      );
    });

    test('含空白语句被拒绝', () {
      expect(
        () =>
            const Migration(
              version: 2,
              description: 'blank',
              statements: <String>['  '],
            ).validate(),
        throwsA(isA<DomainError>()),
      );
    });

    test('版本号低于初始值被拒绝', () {
      expect(
        () =>
            const Migration(
              version: 0,
              description: 'bad',
              statements: <String>['SELECT 1'],
            ).validate(),
        throwsA(isA<DomainError>()),
      );
    });

    test('合法迁移通过校验', () {
      expect(() => migration(2).validate(), returnsNormally);
    });

    test('计划构建时会顺带校验每个迁移', () {
      final broken = <Migration>[
        migration(2),
        const Migration(version: 3, description: 'bad', statements: <String>[]),
      ];
      expect(() => buildPlan(from: 1, to: 3, registered: broken), throwsA(isA<DomainError>()));
    });
  });

  group('PfSchema 常量', () {
    test('当前 schema 版本与构建常量一致', () {
      expect(PfSchema.current, PfBuildInfo.schemaVersion);
      expect(PfSchema.initial, 1);
      expect(PfSchema.current, greaterThanOrEqualTo(PfSchema.initial));
    });
  });
}

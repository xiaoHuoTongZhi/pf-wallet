/// [CoverageReport] 的自防测试。
///
/// 这份报告存在的理由是「覆盖检查的结论必须留下一份可点开、可机读的证据」。
/// 一旦它自己写错了 —— 例如 `ok` 判据被写成「uncoveredKinds 非空也算通过」，
/// 或者 `drivers` 里混进了未注册的 kind —— CI 会拿着这份报告说「一切正常」，
/// 而实际发生的事恰恰相反。所以每个字段的语义都要在这里钉住。
library;

import 'dart:convert';

import 'package:pf_testkit/pf_testkit.dart';
import 'package:test/test.dart';

CoverageReport _report({
  Map<String, int>? vectorCounts,
  List<String> uncoveredKinds = const <String>[],
  Map<String, int> orphanCounts = const <String, int>{},
  int passed = 155,
  int failed = 0,
  int pending = 0,
}) => CoverageReport(
  generatedAt: DateTime.utc(2026, 9, 21, 1, 2, 3),
  dartVersion: '3.7.0 (stable)',
  operatingSystem: 'linux',
  vectorCounts: vectorCounts ?? <String, int>{'container.file.seal': 3, 'export.payload.ndjson': 3},
  passed: passed,
  failed: failed,
  pending: pending,
  uncoveredKinds: uncoveredKinds,
  orphanCounts: orphanCounts,
);

void main() {
  group('覆盖判定', () {
    test('两个方向都为空即通过', () {
      expect(_report().ok, isTrue);
    });

    test('有一个驱动没被引用就是失败', () {
      final report = _report(
        vectorCounts: <String, int>{'container.file.seal': 3, 'export.payload.ndjson': 0},
        uncoveredKinds: <String>['export.payload.ndjson'],
      );
      expect(report.ok, isFalse);
    });

    test('向量引用了未注册的 kind 也是失败（否则报告会与门禁结论相反）', () {
      // 这类 kind 在运行器里已经是 fail，run 是红的。若这里仍判 ok，
      // artifact 就会说「一切正常」而 CI 亮红 —— 一份与门禁相反的
      // 证据比没有证据更坏。
      final report = _report(
        vectorCounts: <String, int>{'container.file.seal': 3},
        orphanCounts: <String, int>{'export.payload.ndjson': 3},
      );
      expect(report.ok, isFalse);
      expect(report.orphanKinds, <String>['export.payload.ndjson']);
      expect(report.orphanVectorCount, 3);
    });

    test('未实现的驱动有向量不算孤儿（向量写在前是正确的顺序）', () {
      // 「未实现」与「未注册」是两件事：
      //   - 未实现的驱动在注册表里，它的向量是 pending —— 正常，不算失败；
      //   - 未注册的 kind 在注册表外，它的向量是 fail —— 接线断了。
      // 混淆这两者会让 M2 那些「先写好向量等实现」的用例全被误报成孤儿。
      final report = _report(vectorCounts: <String, int>{'a.b.c': 3}, pending: 3);
      expect(report.ok, isTrue);
      expect(report.orphanKinds, isEmpty);
      expect(report.toJson()['totals']! as Map<String, Object?>, containsPair('pending', 3));
    });

    test('向量失败不进 ok（那是 report.json 的结论）', () {
      // 守一条边界：这份文件只回答「覆盖面完整吗」。
      // 把 failed 并进 ok 会让同一个判定在两处各写一遍。
      final report = _report(failed: 2);
      expect(report.ok, isTrue);
      expect(report.toJson()['totals']! as Map<String, Object?>, containsPair('failed', 2));
    });

    test('摘要行说清「几个驱动、缺几个」', () {
      // 通过时给出驱动总数，失败时给出缺的个数 ——
      // 这两句话是要贴进验收记录的，含糊的措辞会在半年后变成歧义。
      expect(_report().summaryLine, '✓ 覆盖检查：2 个驱动全部有向量引用');

      final failing = _report(
        vectorCounts: <String, int>{'a.b.c': 1, 'd.e.f': 0, 'g.h.i': 0},
        uncoveredKinds: <String>['d.e.f', 'g.h.i'],
      );
      expect(failing.summaryLine, '✗ 覆盖检查：3 个驱动，2 个已实现驱动没有任何向量引用');
      expect(failing.describeUncovered(), '    - d.e.f\n    - g.h.i');
    });

    test('摘要行同时报出两个方向，并带上孤儿条数', () {
      final report = _report(
        vectorCounts: <String, int>{'a.b.c': 0},
        uncoveredKinds: <String>['a.b.c'],
        orphanCounts: <String, int>{'x.y.z': 2},
      );
      expect(report.summaryLine, '✗ 覆盖检查：1 个驱动，1 个已实现驱动没有任何向量引用；1 个 kind 被向量引用但未注册');
      expect(report.describeOrphans(), '    - x.y.z（被 2 条向量引用）');
    });
  });

  group('计数字段', () {
    test('coveredDrivers = 驱动数 - 未覆盖数', () {
      final report = _report(
        vectorCounts: <String, int>{'a.b.c': 1, 'd.e.f': 2, 'g.h.i': 0},
        uncoveredKinds: <String>['g.h.i'],
      );
      final totals = report.toJson()['totals']! as Map<String, Object?>;
      expect(totals['drivers'], 3);
      expect(totals['coveredDrivers'], 2);
      expect(totals['uncoveredDrivers'], 1);
    });

    test('vectors 是各驱动向量引用数之和（与判定计数无关）', () {
      // 这里的 155 是「通过数」，vectors 是「被引用条数」。
      // 两者混为一谈时，失败或 pending 的用例会被悄悄抹掉。
      final report = _report(
        vectorCounts: <String, int>{'a.b.c': 4, 'd.e.f': 6},
        passed: 9,
        failed: 1,
        pending: 0,
      );
      final totals = report.toJson()['totals']! as Map<String, Object?>;
      expect(totals['vectors'], 10);
      expect(totals['passed'], 9);
      expect(totals['failed'], 1);
    });

    test('孤儿 kind 单独计数，不混进 drivers / vectors', () {
      final report = _report(
        vectorCounts: <String, int>{'a.b.c': 4},
        orphanCounts: <String, int>{'x.y.z': 2, 'w.v.u': 1},
      );
      final totals = report.toJson()['totals']! as Map<String, Object?>;
      expect(totals['drivers'], 1);
      expect(totals['vectors'], 4);
      expect(totals['orphanKinds'], 2);
      expect(totals['orphanVectors'], 3);
    });
  });

  group('输出形状', () {
    test('drivers 按 kind 排序，保证同一仓库两次运行产物逐字节相同', () {
      final report = _report(vectorCounts: <String, int>{'z.last': 1, 'a.first': 2, 'm.mid': 3});
      final drivers = (report.toJson()['drivers']! as List<Object?>).cast<Map<String, Object?>>();
      expect(drivers.map((Map<String, Object?> d) => d['kind']).toList(), <String>[
        'a.first',
        'm.mid',
        'z.last',
      ]);
      expect(drivers.first['vectors'], 2);
    });

    test('uncoveredKinds 与 orphans 都排序', () {
      final report = _report(
        vectorCounts: <String, int>{'z.last': 0, 'a.first': 0},
        uncoveredKinds: <String>['z.last', 'a.first'],
        orphanCounts: <String, int>{'z.orphan': 1, 'a.orphan': 2},
      );
      final json = report.toJson();
      expect(json['uncoveredKinds'], <String>['a.first', 'z.last']);
      expect(json['orphanKinds'], <String>['a.orphan', 'z.orphan']);
      final orphans = (json['orphans']! as List<Object?>).cast<Map<String, Object?>>();
      expect(orphans.first['kind'], 'a.orphan');
      expect(orphans.first['vectors'], 2);
    });

    test('generatedAt 一律按 UTC 写出，避免三平台混入本地时区', () {
      final json = _report().toJson();
      expect(json['generatedAt'], '2026-09-21T01:02:03.000Z');
      expect(json['schemaVersion'], CoverageReport.schemaVersion);
      expect(json['ok'], isTrue);
    });

    test('toPrettyJson 可被重新解析回等价对象', () {
      final report = _report(
        uncoveredKinds: <String>['x.y.z'],
        orphanCounts: <String, int>{'p.q.r': 1},
      );
      final decoded = jsonDecode(report.toPrettyJson());
      expect(decoded, report.toJson());
    });
  });
}

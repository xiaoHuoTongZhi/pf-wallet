/// 运行器判定规则测试。
///
/// 判定规则是整个框架的心脏：如果它错了，向量会「通过」但什么都没锁住 ——
/// 而这是所有测试基建失效模式里最难发现的一种，因为一切看起来都是绿的。
/// 因此每一个分支都必须有测试。
library;

import 'package:pf_core/pf_core.dart';
import 'package:pf_testkit/pf_testkit.dart';
import 'package:test/test.dart';

/// 脚本化驱动：用闭包决定行为，避免为每个分支写一个类。
final class _ScriptedDriver extends VectorDriver {
  _ScriptedDriver(this.kind, this._handler, {this.implemented = true, this.milestone = 'M0'});

  @override
  final String kind;

  final Future<VectorOutcome> Function(Map<String, Object?> input) _handler;

  /// 字段名与基类方法名不同（基类是 isImplemented），
  /// 因此**不能**标 @override —— 标了会得到 override_on_non_overriding_member。
  final bool implemented;

  final String milestone;

  @override
  String get description => '测试用脚本化驱动';

  @override
  bool get isImplemented => implemented;

  @override
  String get plannedMilestone => milestone;

  @override
  Map<String, String> get inputContract => const <String, String>{};

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) => _handler(input);
}

PfVectorCase _case({
  String id = 'demo.thing.run',
  String kind = 'demo.kind',
  VectorExpectation? expect,
  String milestone = 'M0',
  List<String> tags = const <String>[],
}) => PfVectorCase(
  id: id,
  kind: kind,
  title: '用例 $id',
  milestone: MilestoneTag.parse(milestone, 'inline'),
  input: const <String, Object?>{'x': 1},
  expect: expect ?? const VectorExpectation.success(<String, Object?>{'v': 1}),
  tags: tags,
);

PfVectorSuite _suite(List<PfVectorCase> cases) =>
    PfVectorSuite(suite: 'demo', title: 'demo', cases: cases);

Future<VectorReport> _runWith(
  Iterable<PfVectorSuite> suites,
  VectorDriver driver, {
  VectorFilter filter = const VectorFilter(),
}) async {
  final run = await VectorRunner(
    registry: VectorRegistry(<VectorDriver>[driver]),
    filter: filter,
  ).run(suites);
  return run.report;
}

void main() {
  group('成功形态', () {
    test('期望键全部一致 → pass', () async {
      final report = await _runWith(
        <PfVectorSuite>[
          _suite(<PfVectorCase>[
            _case(expect: const VectorExpectation.success(<String, Object?>{'v': 1})),
          ]),
        ],
        _ScriptedDriver(
          'demo.kind',
          (Map<String, Object?> input) async =>
              const VectorOutcome.value(<String, Object?>{'v': 1}),
        ),
      );

      expect(report.passed, 1);
      expect(report.results.single.status, VectorStatus.pass);
    });

    test('实际值多出的键被忽略（允许驱动输出诊断信息）', () async {
      final report = await _runWith(
        <PfVectorSuite>[
          _suite(<PfVectorCase>[
            _case(expect: const VectorExpectation.success(<String, Object?>{'v': 1})),
          ]),
        ],
        _ScriptedDriver(
          'demo.kind',
          (Map<String, Object?> input) async =>
              const VectorOutcome.value(<String, Object?>{'v': 1, 'diagnostic': '仅供参考'}),
        ),
      );

      expect(report.passed, 1);
    });

    test('期望与实际不一致 → fail，且说明差异', () async {
      final report = await _runWith(
        <PfVectorSuite>[
          _suite(<PfVectorCase>[
            _case(expect: const VectorExpectation.success(<String, Object?>{'v': 1})),
          ]),
        ],
        _ScriptedDriver(
          'demo.kind',
          (Map<String, Object?> input) async =>
              const VectorOutcome.value(<String, Object?>{'v': 2}),
        ),
      );

      expect(report.failed, 1);
      expect(report.failures.single.message, contains('不符'));
    });

    test('缺少期望键 → fail，并列出实际有的键', () async {
      final report = await _runWith(
        <PfVectorSuite>[
          _suite(<PfVectorCase>[
            _case(expect: const VectorExpectation.success(<String, Object?>{'v': 1, 'w': 2})),
          ]),
        ],
        _ScriptedDriver(
          'demo.kind',
          (Map<String, Object?> input) async =>
              const VectorOutcome.value(<String, Object?>{'v': 1}),
        ),
      );

      expect(report.failed, 1);
      expect(report.failures.single.message, contains('缺少期望字段 "w"'));
    });

    test('期望成功但抛出错误 → fail', () async {
      final report = await _runWith(
        <PfVectorSuite>[
          _suite(<PfVectorCase>[_case()]),
        ],
        _ScriptedDriver(
          'demo.kind',
          (Map<String, Object?> input) async =>
              VectorOutcome.errored(ContainerError.magicMismatch().code),
        ),
      );

      expect(report.failed, 1);
      expect(report.failures.single.message, contains('期望正常返回'));
    });
  });

  group('错误形态', () {
    test('错误码一致 → pass', () async {
      final report = await _runWith(
        <PfVectorSuite>[
          _suite(<PfVectorCase>[
            _case(expect: VectorExpectation.failure(ContainerError.magicMismatch().code)),
          ]),
        ],
        _ScriptedDriver(
          'demo.kind',
          (Map<String, Object?> input) async => throw ContainerError.magicMismatch(),
        ),
      );

      expect(report.passed, 1);
    });

    test('错误码不一致 → fail', () async {
      final report = await _runWith(
        <PfVectorSuite>[
          _suite(<PfVectorCase>[_case(expect: VectorExpectation.failure('PFB_E_MAGIC'))]),
        ],
        _ScriptedDriver(
          'demo.kind',
          (Map<String, Object?> input) async =>
              throw ContainerError.truncated(expected: 76, actual: 10),
        ),
      );

      expect(report.failed, 1);
      expect(report.failures.single.message, contains('错误码不符'));
    });

    test('errorCode "*" 接受任意错误码', () async {
      final report = await _runWith(
        <PfVectorSuite>[
          _suite(<PfVectorCase>[_case(expect: const VectorExpectation.failure('*'))]),
        ],
        _ScriptedDriver(
          'demo.kind',
          (Map<String, Object?> input) async =>
              VectorOutcome.errored(DomainError.validation(detail: 'x').code),
        ),
      );

      expect(report.passed, 1);
    });

    test('期望报错但正常返回 → fail', () async {
      final report = await _runWith(
        <PfVectorSuite>[
          _suite(<PfVectorCase>[_case(expect: VectorExpectation.failure('PFB_E_MAGIC'))]),
        ],
        _ScriptedDriver(
          'demo.kind',
          (Map<String, Object?> input) async =>
              const VectorOutcome.value(<String, Object?>{'v': 1}),
        ),
      );

      expect(report.failed, 1);
      expect(report.failures.single.message, contains('期望抛出 PFB_E_MAGIC'));
    });
  });

  group('接线与就绪状态', () {
    test('kind 未注册 → fail（而不是静默跳过）', () async {
      final report = await _runWith(
        <PfVectorSuite>[
          _suite(<PfVectorCase>[_case(kind: 'not.registered')]),
        ],
        _ScriptedDriver(
          'demo.kind',
          (Map<String, Object?> input) async =>
              const VectorOutcome.value(<String, Object?>{'v': 1}),
        ),
      );

      expect(report.failed, 1);
      expect(report.failures.single.message, contains('未注册的 kind'));
    });

    test('驱动未实现 → pending（不是 fail）', () async {
      final report = await _runWith(
        <PfVectorSuite>[
          _suite(<PfVectorCase>[_case(id: 'demo.a.b')]),
        ],
        _ScriptedDriver(
          'demo.kind',
          (Map<String, Object?> input) async =>
              const VectorOutcome.value(<String, Object?>{'v': 1}),
          implemented: false,
          milestone: 'M2',
        ),
      );

      expect(report.pending, 1);
      expect(report.isClean, isTrue, reason: 'pending 不应导致失败');
      expect(report.results.single.message, contains('M2'));
    });

    test('驱动抛非 PfError 异常 → fail，并截取栈顶', () async {
      final report = await _runWith(
        <PfVectorSuite>[
          _suite(<PfVectorCase>[_case()]),
        ],
        _ScriptedDriver(
          'demo.kind',
          (Map<String, Object?> input) async => throw ArgumentError('向量写错了'),
        ),
      );

      expect(report.failed, 1);
      expect(report.failures.single.message, contains('非 PfError 异常'));
      expect(report.failures.single.message, contains('ArgumentError'));
    });

    test('已实现的驱动没有向量引用 → 产生 warning', () async {
      final run = await VectorRunner(
        registry: VectorRegistry(<VectorDriver>[
          _ScriptedDriver(
            'unused.kind',
            (Map<String, Object?> input) async =>
                const VectorOutcome.value(<String, Object?>{'v': 1}),
          ),
        ]),
      ).run(<PfVectorSuite>[
        _suite(<PfVectorCase>[_case()]),
      ]);

      // kind 未注册 → 失败；同时 unused.kind 未被引用 → warning
      expect(run.report.failed, 1);
      expect(run.warnings.join('\n'), contains('unused.kind'));
    });

    test('未实现的驱动没有向量引用 → 不产生 warning', () async {
      final run = await VectorRunner(
        registry: VectorRegistry(<VectorDriver>[
          _ScriptedDriver(
            'demo.kind',
            (Map<String, Object?> input) async =>
                const VectorOutcome.value(<String, Object?>{'v': 1}),
            implemented: false,
          ),
          _ScriptedDriver(
            'm2.kind',
            (Map<String, Object?> input) async =>
                const VectorOutcome.value(<String, Object?>{'v': 1}),
            implemented: false,
          ),
        ]),
      ).run(<PfVectorSuite>[
        _suite(<PfVectorCase>[_case()]),
      ]);

      expect(run.warnings.join('\n'), isNot(contains('m2.kind')));
    });

    // uncoveredKinds 是 `vector_report.dart --require-coverage` 的判定依据，
    // 也就是「向量先于实现」这条顺序原则的机器执行者。
    // 它必须比 warning 严格：warning 只打印，本字段会让门禁变红。
    test('已实现但没向量引用的 kind 进入 uncoveredKinds（并排序）', () async {
      final run = await VectorRunner(
        registry: VectorRegistry(<VectorDriver>[
          _ScriptedDriver(
            'demo.kind',
            (Map<String, Object?> input) async =>
                const VectorOutcome.value(<String, Object?>{'v': 1}),
          ),
          _ScriptedDriver(
            'zzz.unused',
            (Map<String, Object?> input) async =>
                const VectorOutcome.value(<String, Object?>{'v': 1}),
          ),
          _ScriptedDriver(
            'aaa.unused',
            (Map<String, Object?> input) async =>
                const VectorOutcome.value(<String, Object?>{'v': 1}),
          ),
          _ScriptedDriver(
            'm2.pending',
            (Map<String, Object?> input) async =>
                const VectorOutcome.value(<String, Object?>{'v': 1}),
            implemented: false,
          ),
        ]),
      ).run(<PfVectorSuite>[
        _suite(<PfVectorCase>[_case()]),
      ]);

      // 未实现的 m2.pending 不算「缺向量」—— 它的向量本来就还没到。
      // 若把它也算进去，覆盖检查会从第一天起就常红，然后被所有人忽略。
      expect(run.uncoveredKinds, <String>['aaa.unused', 'zzz.unused']);
    });

    test('全部驱动都被引用 → uncoveredKinds 为空', () async {
      final run = await VectorRunner(
        registry: VectorRegistry(<VectorDriver>[
          _ScriptedDriver(
            'demo.kind',
            (Map<String, Object?> input) async =>
                const VectorOutcome.value(<String, Object?>{'v': 1}),
          ),
        ]),
      ).run(<PfVectorSuite>[
        _suite(<PfVectorCase>[_case()]),
      ]);

      expect(run.uncoveredKinds, isEmpty);
      expect(run.warnings, isEmpty);
    });
  });

  group('筛选与报告', () {
    test('筛选条件排除的用例被跳过并产生提示', () async {
      final run = await VectorRunner(
        registry: VectorRegistry(<VectorDriver>[
          _ScriptedDriver(
            'demo.kind',
            (Map<String, Object?> input) async =>
                const VectorOutcome.value(<String, Object?>{'v': 1}),
          ),
        ]),
        filter: const VectorFilter(milestones: <String>{'M3'}),
      ).run(<PfVectorSuite>[
        _suite(<PfVectorCase>[_case(id: 'demo.a.one'), _case(id: 'demo.a.two', milestone: 'M3')]),
      ]);

      expect(run.report.total, 1);
      expect(run.report.results.single.caseId, 'demo.a.two');
      expect(run.warnings.join('\n'), contains('排除了 1 条'));
    });

    test('判定摘要与用例顺序无关', () {
      final a = VectorReport(
        results: <VectorCaseResult>[
          _result('demo.a.one', VectorStatus.pass),
          _result('demo.a.two', VectorStatus.fail),
        ],
        generatedAt: DateTime.utc(2026),
        dartVersion: 'x',
        operatingSystem: 'y',
      );
      final b = VectorReport(
        results: <VectorCaseResult>[
          _result('demo.a.two', VectorStatus.fail),
          _result('demo.a.one', VectorStatus.pass),
        ],
        generatedAt: DateTime.utc(2027),
        dartVersion: 'z',
        operatingSystem: 'w',
      );
      final c = VectorReport(
        results: <VectorCaseResult>[
          _result('demo.a.one', VectorStatus.pass),
          _result('demo.a.two', VectorStatus.pass),
        ],
        generatedAt: DateTime.utc(2026),
        dartVersion: 'x',
        operatingSystem: 'y',
      );

      expect(a.verdictDigest, b.verdictDigest);
      expect(a.verdictDigest, isNot(c.verdictDigest));
    });
  });

  group('pending 基线', () {
    test('一致 → 干净', () {
      const baseline = PendingBaseline(entries: <String>{'a', 'b'});
      expect(baseline.diff(<String>['b', 'a']).isClean, isTrue);
    });

    test('新增 pending → added（实现倒退）', () {
      const baseline = PendingBaseline(entries: <String>{'a'});
      final delta = baseline.diff(<String>['a', 'b']);
      expect(delta.added, <String>['b']);
      expect(delta.resolved, isEmpty);
      expect(delta.isClean, isFalse);
      expect(delta.describe(), contains('新增 pending'));
    });

    test('消除 pending → resolved（基线过期）', () {
      const baseline = PendingBaseline(entries: <String>{'a', 'b'});
      final delta = baseline.diff(<String>['a']);
      expect(delta.resolved, <String>['b']);
      expect(delta.isClean, isFalse);
      expect(delta.describe(), contains('基线过期'));
    });

    test('JSON 往返保持内容与顺序确定性', () {
      const baseline = PendingBaseline(entries: <String>{'c', 'a', 'b'});
      final decoded = PendingBaseline.fromJson(baseline.toJson(), 'inline');
      expect(decoded.entries, baseline.entries);
      expect(baseline.toJson()['pending']! as List<Object?>, <Object?>['a', 'b', 'c']);
    });
  });
}

VectorCaseResult _result(String id, VectorStatus status) => VectorCaseResult(
  caseId: id,
  suite: 'demo',
  kind: 'demo.kind',
  title: id,
  milestone: 'M0',
  status: status,
  durationMicros: 0,
);

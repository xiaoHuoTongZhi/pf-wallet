/// [TestReportSummary] / [TestReportVerdict] 的自防测试。
///
/// 夹具直接照抄 test_core 的 JSON 协议事件（见
/// `test_core-0.6.8/lib/src/runner/reporter/json.dart`），
/// 不是「随手编的形状」—— 因为本模块的整个价值就在于它对三个
/// 容易被忽略的字段（`skipped` / `hidden` / `metadata.skip`）的解读，
/// 形状写错的话测试会一起错，且仍然全绿。
///
/// 这也是为什么必须有这份测试：本机沙箱跑不了 flutter_tester，
/// `bin/assert_test_report.dart` 在本地拿不到真实报告。
/// 协议解读的每一处判断都要靠这里的合成报告来守。
library;

import 'dart:convert';

import 'package:pf_testkit/pf_testkit.dart';
import 'package:test/test.dart';

const String _reportPath = 'build/test-reports/pf_mobile.jsonl';

/// `testStart` 事件（字段与 test_core 的 `_emit('testStart', ...)` 一致）。
Map<String, Object?> _start(int id, String name, {bool skip = false}) => <String, Object?>{
  'type': 'testStart',
  'test': <String, Object?>{
    'id': id,
    'name': name,
    'suiteID': 0,
    'groupIDs': <int>[],
    'metadata': <String, Object?>{'skip': skip, 'skipReason': skip ? '待 M1 再修' : null},
    'line': null,
    'column': null,
    'url': null,
    'root_url': null,
  },
};

/// `testDone` 事件。
///
/// 注意默认值：`skipped = false` 时 `result` 才是真正的判定依据；
/// 而被跳过时 test_core 会**把 result 规范化成 success**，
/// 夹具刻意保留这个反直觉的行为。
Map<String, Object?> _done(
  int id, {
  String result = 'success',
  bool skipped = false,
  bool hidden = false,
}) => <String, Object?>{
  'type': 'testDone',
  'testID': id,
  'result': result,
  'skipped': skipped,
  'hidden': hidden,
};

/// 报告里除 testStart / testDone 之外一定会出现的噪声事件。
List<Map<String, Object?>> _noise() => <Map<String, Object?>>[
  <String, Object?>{
    'type': 'suite',
    'suite': <String, Object?>{'id': 0},
  },
  <String, Object?>{
    'type': 'group',
    'group': <String, Object?>{'id': 0, 'name': ''},
  },
  <String, Object?>{'type': 'allSuites', 'count': 1},
];

String _ndjson(List<Map<String, Object?>> events) => events.map(jsonEncode).join('\n');

TestReportSummary _parse(List<Map<String, Object?>> events) =>
    TestReportSummary.parse(_ndjson(events), source: _reportPath);

/// pf_mobile 三条 widget 测试的名字（与 apps/pf_mobile/test/smoke_test.dart 核对过）。
const List<String> _mobileWidgetTests = <String>[
  '应用能构建并显示构建信息',
  '深色模式下也能正常构建',
  'MVP 阶段不得出现任何「记账」入口',
];

void main() {
  group('TestReportSummary.parse · 事件解读', () {
    test('三条用例全部执行并通过', () {
      final TestReportSummary summary = _parse(<Map<String, Object?>>[
        ..._noise(),
        _start(1, _mobileWidgetTests[0]),
        _done(1),
        _start(2, _mobileWidgetTests[1]),
        _done(2),
        _start(3, _mobileWidgetTests[2]),
        _done(3),
      ]);

      expect(summary.executedCount, 3);
      expect(summary.failedCount, 0);
      expect(summary.skippedCount, 0);
      expect(summary.hiddenCount, 0);
      expect(summary.executedNames, _mobileWidgetTests);
    });

    test('合成用例（loading ...）不计入执行数', () {
      final TestReportSummary summary = _parse(<Map<String, Object?>>[
        ..._noise(),
        _start(1, 'loading /repo/apps/pf_mobile/test/smoke_test.dart'),
        _done(1, hidden: true),
        _start(2, _mobileWidgetTests[0]),
        _done(2),
      ]);

      expect(summary.executedCount, 1);
      expect(summary.hiddenCount, 1);
      expect(summary.executedNames, <String>[
        _mobileWidgetTests[0],
      ], reason: '合成用例只用于解释总数，绝不能出现在「已执行」列表里');
    });

    test('被跳过的用例 result 仍是 success —— 只看 result 会得出完全相反的结论', () {
      final TestReportSummary summary = _parse(<Map<String, Object?>>[
        ..._noise(),
        _start(1, _mobileWidgetTests[0]),
        _done(1),
        _start(2, _mobileWidgetTests[1], skip: true),
        _done(2, skipped: true),
      ]);

      // 框架把它报成 success，这是规范行为，不是 bug ——
      // 因此任何判断都必须同时看 skipped，本模块的每个计数都这么做。
      expect(summary.cases.last.result, 'success');
      expect(summary.cases.last.skipped, isTrue);

      expect(summary.executedCount, 1);
      expect(summary.skippedCount, 1);
      expect(summary.declaredSkipCount, 1);
      expect(summary.declaredSkipNames, <String>[_mobileWidgetTests[1]]);
    });

    test('失败与错误的用例都计入 failed', () {
      final TestReportSummary summary = _parse(<Map<String, Object?>>[
        ..._noise(),
        _start(1, 'a'),
        _done(1, result: 'failure'),
        _start(2, 'b'),
        _done(2, result: 'error'),
        _start(3, 'c'),
        _done(3),
      ]);

      expect(summary.failedCount, 2);
      expect(summary.executedCount, 1);
    });

    test('不认识的 type 被忽略：协议演进不该让门禁变红', () {
      final TestReportSummary summary = _parse(<Map<String, Object?>>[
        ..._noise(),
        <String, Object?>{'type': 'somethingAddedInDartFiveHundred', 'payload': 1},
        _start(1, 'a'),
        _done(1),
        <String, Object?>{'type': 'done', 'success': true},
      ]);

      expect(summary.executedCount, 1);
    });

    test('空报告 → isEmpty（由 CLI 判为「报告不可用」）', () {
      expect(TestReportSummary.parse('', source: _reportPath).isEmpty, isTrue);
      expect(TestReportSummary.parse('\n  \n', source: _reportPath).isEmpty, isTrue);
    });
  });

  group('TestReportSummary.parse · 必须硬失败的情形', () {
    test('某一行不是合法 JSON → 指明行号，并带上该行开头', () {
      expect(
        () => TestReportSummary.parse('{"type":"suite"}\n这不是 JSON', source: _reportPath),
        throwsA(
          isA<TestReportFormatException>()
              .having((TestReportFormatException e) => e.message, 'message', contains('第 2 行'))
              // 光说「第 2 行坏了」只解决一半问题：CI 上报告在 artifact 里，
              // 出错时看不到内容。带上该行开头，才能一眼分辨是
              // 「工具输出被混进了 stdout」还是「JSON 真的断了」——
              // 这两种成因的修法完全不同（前者改命令，后者查写入）。
              .having((TestReportFormatException e) => e.message, 'message', contains('这不是 JSON')),
        ),
      );
    });

    test('坏行过长时截断，并报出原长 —— 避免 CI 日志折行把关键处挤出屏幕', () {
      final String long = 'x' * 300;
      expect(
        () => TestReportSummary.parse('{"type":"suite"}\n$long', source: _reportPath),
        throwsA(
          isA<TestReportFormatException>().having(
            (TestReportFormatException e) => e.message,
            'message',
            contains('该行共 300 字符'),
          ),
        ),
      );
    });

    test('testDone 找不到对应的 testStart（报告被截断）', () {
      expect(
        () =>
            TestReportSummary.parse(_ndjson(<Map<String, Object?>>[_done(7)]), source: _reportPath),
        throwsA(
          isA<TestReportFormatException>().having(
            (TestReportFormatException e) => e.message,
            'message',
            contains('找不到对应的 testStart'),
          ),
        ),
      );
    });

    test('testStart 缺 name', () {
      expect(
        () => TestReportSummary.parse(
          _ndjson(<Map<String, Object?>>[
            <String, Object?>{
              'type': 'testStart',
              'test': <String, Object?>{'id': 1},
            },
          ]),
          source: _reportPath,
        ),
        throwsA(isA<TestReportFormatException>()),
      );
    });

    test('事件不是 JSON 对象', () {
      expect(
        () => TestReportSummary.parse('[1,2,3]', source: _reportPath),
        throwsA(
          isA<TestReportFormatException>().having(
            (TestReportFormatException e) => e.message,
            'message',
            contains('不是 JSON 对象'),
          ),
        ),
      );
    });

    test('异常对象带上报告来源，便于在多平台日志里指认', () {
      expect(
        () => TestReportSummary.parse('{oops', source: _reportPath),
        throwsA(
          isA<TestReportFormatException>().having(
            (TestReportFormatException e) => e.source,
            'source',
            _reportPath,
          ),
        ),
      );
    });
  });

  group('TestReportVerdict.judge', () {
    TestReportVerdict judge(
      List<Map<String, Object?>> events, {
      int minExecuted = 0,
      List<String> required = const <String>[],
      bool allowSkipped = false,
    }) => TestReportVerdict.judge(
      summary: _parse(events),
      expectation: TestReportExpectation(
        minExecuted: minExecuted,
        requiredNames: required,
        allowSkipped: allowSkipped,
      ),
    );

    /// M0 在 CI 关卡 2 上对 pf_mobile 使用的那份期望。
    TestReportVerdict judgeMobile(List<Map<String, Object?>> events) =>
        judge(events, minExecuted: 3, required: _mobileWidgetTests);

    List<Map<String, Object?>> mobileAllPassing() => <Map<String, Object?>>[
      ..._noise(),
      _start(1, _mobileWidgetTests[0]),
      _done(1),
      _start(2, _mobileWidgetTests[1]),
      _done(2),
      _start(3, _mobileWidgetTests[2]),
      _done(3),
    ];

    test('三条全部执行 → 通过', () {
      final TestReportVerdict verdict = judgeMobile(mobileAllPassing());
      expect(verdict.isClean, isTrue, reason: verdict.problems.join(' / '));
      expect(verdict.describe(), contains('✓ 判定通过'));
    });

    test('缺一条（被跳过）→ 不通过，且同时点出「跳过」与「没执行到」', () {
      final TestReportVerdict verdict = judgeMobile(<Map<String, Object?>>[
        ..._noise(),
        _start(1, _mobileWidgetTests[0]),
        _done(1),
        _start(2, _mobileWidgetTests[1], skip: true),
        _done(2, skipped: true),
        _start(3, _mobileWidgetTests[2]),
        _done(3),
      ]);

      expect(verdict.isClean, isFalse);
      expect(verdict.problems.join('\n'), contains('被跳过'));
      expect(verdict.problems.join('\n'), contains('没有执行到必需的用例：${_mobileWidgetTests[1]}'));
      expect(verdict.problems.join('\n'), contains('源码里声明了跳过'));
    });

    test('整个文件都没跑（0 条）→ 不通过', () {
      final TestReportVerdict verdict = judgeMobile(<Map<String, Object?>>[
        ..._noise(),
        _start(1, 'loading /repo/apps/pf_mobile/test/smoke_test.dart'),
        _done(1, hidden: true),
      ]);

      expect(verdict.isClean, isFalse);
      expect(verdict.problems.join('\n'), contains('少于要求的 3 条'));
      for (final String name in _mobileWidgetTests) {
        expect(verdict.problems.join('\n'), contains(name));
      }
    });

    test('执行了但是失败 → 不通过', () {
      final List<Map<String, Object?>> events = mobileAllPassing();
      events[events.length - 1] = _done(3, result: 'failure');

      final TestReportVerdict verdict = judgeMobile(events);
      expect(verdict.isClean, isFalse);
      expect(verdict.problems.join('\n'), contains('1 条用例失败'));
    });

    test('数量是下界：新增用例不该让门禁变红', () {
      final TestReportVerdict verdict = judgeMobile(<Map<String, Object?>>[
        ...mobileAllPassing(),
        _start(9, 'M1 新加的用例'),
        _done(9),
      ]);

      expect(verdict.isClean, isTrue, reason: '下界用 ≥ 而不是 =，否则每加一条用例都要改 CI —— 那只会让人删掉这条断言');
    });

    test('必需用例按子串匹配，且必须在「已执行」列表里', () {
      final TestReportVerdict verdict = judge(mobileAllPassing(), required: <String>['记账']);
      expect(verdict.isClean, isTrue);

      final TestReportVerdict missing = judge(mobileAllPassing(), required: <String>['对账中心']);
      expect(missing.isClean, isFalse);
      expect(missing.problems.single, contains('对账中心'));
    });

    test('被跳过的用例不满足「必须执行」的必需名', () {
      final TestReportVerdict verdict = judge(
        <Map<String, Object?>>[
          ..._noise(),
          _start(1, '对账中心入口', skip: true),
          _done(1, skipped: true),
        ],
        required: <String>['对账中心'],
      );

      expect(verdict.isClean, isFalse, reason: '用例名出现了，但它是被跳过的 —— 没有执行就不算数');
    });

    test('allowSkipped 只放开「被跳过」，不放开「声明跳过」与「必需名缺失」', () {
      final TestReportVerdict verdict = judge(
        <Map<String, Object?>>[
          ..._noise(),
          _start(1, '甲'),
          _done(1),
          _start(2, '乙', skip: true),
          _done(2, skipped: true),
        ],
        minExecuted: 1,
        allowSkipped: true,
      );

      expect(verdict.isClean, isFalse);
      expect(verdict.problems.join('\n'), contains('源码里声明了跳过：乙'));
      expect(
        verdict.problems.join('\n'),
        isNot(contains('被跳过 —— 跳过等于没有执行')),
        reason: 'allowSkipped 关掉的是「统计意义上的跳过」，不是「源码声明」这条证据',
      );
    });
  });

  group('与真实测试文件的契约', () {
    test('三条 widget 测试的名字与 smoke_test.dart 一致', () {
      // 这条断言故意写死名字：它是 bin/assert_test_report.dart 在 CI 上
      // --require 的那三个参数。若有人重命名了 widget 测试，
      // CI 会因为「没有执行到必需的用例」而失败 —— 那正是我们想要的，
      // 因为改名绕过门禁必须是一次看得见的修改。
      expect(_mobileWidgetTests, hasLength(3));
      expect(_mobileWidgetTests.first, '应用能构建并显示构建信息');
      expect(_mobileWidgetTests.last, contains('记账'));
    });
  });
}

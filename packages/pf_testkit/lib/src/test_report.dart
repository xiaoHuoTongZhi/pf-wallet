/// 解析 `flutter test --reporter json` 的输出，回答一个 CI 上很容易被糊弄过去的问题：
/// **这些用例究竟执行了，还是被跳过了。**
///
/// ## 为什么不能只看退出码
///
/// `flutter test` 在下面三种情况下都返回 0：
///
///   1. 用例全部执行并通过；
///   2. **一条用例都没有**（测试文件被删了、匹配不到文件、包配错了）；
///   3. **用例全部被跳过**（有人加了 `@Skip(...)` 或 `skip: true`）。
///
/// 后两种是同一类事故：**覆盖率静默归零而 CI 依然全绿**。
/// 本项目把跨平台一致性做成门禁（关卡 3）、把 pending 做成只减不增的棘轮
/// （见 docs/M0_ACCEPTANCE.md 第 4 节），如果「用例到底跑没跑」这条底线
/// 反而靠人肉看日志，那前面那些棘轮都失去了地基 —— 一座建在沙上的塔。
///
/// 因此这里不「跑测试」，只**审报告**：报告由测试进程自己产出，
/// 里面的每个事件都带 `skipped` / `hidden` / `metadata.skip` 三个信号。
///
/// ## 报告格式
///
/// 取自 test_core 的 JSON 协议（https://dart.dev/go/test-docs/json_reporter.md），
/// 本项目实际依赖的只有两类事件：
///
/// ```jsonl
/// {"type":"testStart","test":{"id":2,"name":"应用能构建","metadata":{"skip":false,"skipReason":null}}}
/// {"type":"testDone","testID":2,"result":"success","skipped":false,"hidden":false}
/// ```
///
/// 三个字段的语义差异是本模块存在的全部理由：
///
///   - `skipped == true` —— 用例**没有执行**。但注意 `result` 仍被规范化为
///     `success`（为兼容旧版消费方），所以只看 `result` 会得出完全相反的结论。
///   - `hidden == true` —— 测试框架自己产生的合成用例（如 `loading /path/x_test.dart`）。
///     它们必须排除，否则「执行了几条」永远比实际多。
///   - `metadata.skip` —— **源码里**声明了跳过。它和 `skipped` 通常同时为真，
///     但分开报是刻意的：前者指向「有人写下了 @Skip」，后者指向「这次没跑」，
///     排查方向不同。
library;

import 'dart:convert';

/// 报告文件本身有问题：不存在、为空、某一行不是合法 JSON、事件字段缺失。
///
/// 与「用例失败」严格区分 —— 前者要修 CI 接线（退出码 2），
/// 后者要修实现（退出码 1）。这与 [VectorFormatException] 的分工一致。
final class TestReportFormatException implements Exception {
  TestReportFormatException(this.message, {this.source});

  final String message;

  /// 报告来源（通常是文件路径），用于在日志里指认是哪一份报告坏了。
  final String? source;

  @override
  String toString() =>
      source == null
          ? 'TestReportFormatException: $message'
          : 'TestReportFormatException @ $source: $message';
}

/// `testDone.result` 中代表「通过」的取值。
///
/// 单列成常量是因为它有一个反直觉之处：**被跳过的用例也是这个值**
/// （test_core 为兼容旧消费方刻意做的规范化）。任何判断都必须同时看 `skipped`。
const String _resultSuccess = 'success';

/// 单条用例的执行结果。
final class TestCaseOutcome {
  const TestCaseOutcome({
    required this.id,
    required this.name,
    required this.result,
    required this.skipped,
    required this.hidden,
    required this.declaresSkip,
  });

  /// 报告内的用例编号（仅在同一份报告内唯一）。
  final int id;

  /// 用例名，与源码里 `testWidgets('...')` 的字面量一致（不含 group 前缀）。
  final String name;

  /// `success` / `failure` / `error`。
  final String result;

  /// 被跳过 —— **没有执行**。此时 [result] 仍是 `success`。
  final bool skipped;

  /// 测试框架内部的合成用例（`loading ...`），不计入任何统计。
  final bool hidden;

  /// 源码里显式声明了跳过（`@Skip` 或 `skip:` 参数）。
  final bool declaresSkip;

  /// 真正执行了且通过 —— 这是唯一可以计入「覆盖」的状态。
  bool get executedAndPassed => !hidden && !skipped && result == _resultSuccess;

  /// 执行了但失败（含 error）。
  bool get failed => !hidden && result != _resultSuccess;
}

/// 一份报告的整体摘要。
final class TestReportSummary {
  const TestReportSummary({required this.cases, required this.source});

  final List<TestCaseOutcome> cases;

  /// 报告来源，用于输出。
  final String source;

  /// 真正执行并通过的条数。
  int get executedCount => _visible.where((c) => c.executedAndPassed).length;

  /// 执行了但失败的条数。
  int get failedCount => _visible.where((c) => c.failed).length;

  /// 被跳过的条数（**没有执行**）。
  int get skippedCount => _visible.where((c) => c.skipped).length;

  /// 框架合成用例的条数，仅用于解释「总数为什么对不上」。
  int get hiddenCount => cases.where((c) => c.hidden).length;

  /// 源码里声明了跳过的条数。
  int get declaredSkipCount => _visible.where((c) => c.declaresSkip).length;

  /// 执行并通过的用例名。断言「该跑的那几条确实在列表里」靠它。
  List<String> get executedNames =>
      _visible.where((c) => c.executedAndPassed).map((c) => c.name).toList(growable: false);

  /// 在源码里声明了跳过的用例名。
  List<String> get declaredSkipNames =>
      _visible.where((c) => c.declaresSkip).map((c) => c.name).toSet().toList(growable: false);

  /// 报告里没有任何用例记录（CLI 会把它当作「报告不可用」，退出码 2）。
  bool get isEmpty => cases.isEmpty;

  Iterable<TestCaseOutcome> get _visible => cases.where((c) => !c.hidden);

  /// 解析 JSON Lines 报告。
  ///
  /// 不认识的 `type` 直接忽略：报告协议会随 Dart 版本增加事件种类，
  /// 因为多了个 `debug` 事件就让门禁失败，是把「协议演进」误判成「报告坏了」。
  static TestReportSummary parse(String ndjson, {required String source}) {
    final Map<int, _TestStart> starts = <int, _TestStart>{};
    final List<TestCaseOutcome> cases = <TestCaseOutcome>[];

    var lineNumber = 0;
    for (final String line in const LineSplitter().convert(ndjson)) {
      lineNumber++;
      if (line.trim().isEmpty) {
        continue;
      }
      final String where = '第 $lineNumber 行';

      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException catch (error) {
        throw TestReportFormatException('$where 不是合法 JSON：${error.message}', source: source);
      }
      if (decoded is! Map<String, Object?>) {
        throw TestReportFormatException('$where 不是 JSON 对象', source: source);
      }

      final String type = _requireString(decoded, 'type', where, source);

      switch (type) {
        case 'testStart':
          final Map<String, Object?> test = _requireMap(decoded, 'test', where, source);
          final int id = _requireInt(test, 'id', '$where · test', source);
          // metadata.skip 是「源码里写了跳过」，与「这次没跑」分开记录。
          final Map<String, Object?>? metadata = _optionalMap(test, 'metadata');
          starts[id] = _TestStart(
            name: _requireString(test, 'name', '$where · test', source),
            declaresSkip: metadata?['skip'] == true,
          );

        case 'testDone':
          final int id = _requireInt(decoded, 'testID', where, source);
          final _TestStart? start = starts[id];
          if (start == null) {
            throw TestReportFormatException(
              '$where 的 testDone 找不到对应的 testStart —— 报告不是完整的一次运行',
              source: source,
            );
          }
          cases.add(
            TestCaseOutcome(
              id: id,
              name: start.name,
              result: _requireString(decoded, 'result', where, source),
              skipped: _flag(decoded, 'skipped', where, source),
              hidden: _flag(decoded, 'hidden', where, source),
              declaresSkip: start.declaresSkip,
            ),
          );

        default:
          // suite / group / print / allSuites / done ... 一律忽略。
          break;
      }
    }

    return TestReportSummary(cases: List<TestCaseOutcome>.unmodifiable(cases), source: source);
  }
}

/// 对一份报告的期望。默认值刻意保守：**什么都不允许发生**。
final class TestReportExpectation {
  const TestReportExpectation({
    this.minExecuted = 0,
    this.requiredNames = const <String>[],
    this.allowSkipped = false,
  });

  /// 执行并通过的**下界**。
  ///
  /// 用下界而不是等号：新增用例不该让门禁变红（那只会让人删掉这条断言），
  /// 但**减少**必须变红 —— 与 pending 基线的「只减不增」是同一个思路。
  final int minExecuted;

  /// 必须出现在「已执行」列表里的用例名（子串匹配）。
  ///
  /// 它是这份期望里最有力的一条：数量对得上不代表跑的是**那几条**。
  /// M0 用它钉住 pf_mobile 的三条 widget 测试 —— 本机沙箱跑不了 flutter_tester，
  /// 这三条在本地始终「未验证」，只有在 CI 上核对过名字才算真的执行过。
  final List<String> requiredNames;

  /// 是否容忍被跳过的用例。默认**不容忍**。
  final bool allowSkipped;
}

/// 判定结果。
final class TestReportVerdict {
  const TestReportVerdict({
    required this.summary,
    required this.expectation,
    required this.problems,
  });

  final TestReportSummary summary;
  final TestReportExpectation expectation;

  /// 全部问题，逐条可读。为空即通过。
  final List<String> problems;

  bool get isClean => problems.isEmpty;

  static TestReportVerdict judge({
    required TestReportSummary summary,
    required TestReportExpectation expectation,
  }) {
    final List<String> problems = <String>[];

    if (summary.failedCount > 0) {
      problems.add('有 ${summary.failedCount} 条用例失败');
    }
    if (!expectation.allowSkipped && summary.skippedCount > 0) {
      problems.add('有 ${summary.skippedCount} 条用例被跳过 —— 跳过等于没有执行');
    }
    for (final String name in summary.declaredSkipNames) {
      problems.add('源码里声明了跳过：$name');
    }
    if (summary.executedCount < expectation.minExecuted) {
      problems.add('实际执行并通过 ${summary.executedCount} 条，少于要求的 ${expectation.minExecuted} 条');
    }
    for (final String required in expectation.requiredNames) {
      if (!summary.executedNames.any((String name) => name.contains(required))) {
        problems.add('没有执行到必需的用例：$required');
      }
    }

    return TestReportVerdict(
      summary: summary,
      expectation: expectation,
      problems: List<String>.unmodifiable(problems),
    );
  }

  /// 人读的多行摘要。CI 日志里这一块就是「有没有真的跑」的凭据。
  String describe() {
    final StringBuffer buffer =
        StringBuffer()..writeln(
          '报告：${summary.source}'
          '（执行并通过 ${summary.executedCount} / 失败 ${summary.failedCount} / '
          '跳过 ${summary.skippedCount} / 合成 ${summary.hiddenCount}）',
        );

    if (expectation.requiredNames.isNotEmpty) {
      buffer.writeln('必需用例：');
      for (final String required in expectation.requiredNames) {
        final bool ran = summary.executedNames.any((String name) => name.contains(required));
        buffer.writeln('  ${ran ? '✓' : '✗'} $required');
      }
    }

    if (summary.executedNames.isNotEmpty) {
      buffer.writeln('实际执行的用例：');
      for (final String name in summary.executedNames) {
        buffer.writeln('  · $name');
      }
    }

    if (isClean) {
      buffer.writeln('✓ 判定通过');
    } else {
      buffer.writeln('✗ 判定不通过：');
      for (final String problem in problems) {
        buffer.writeln('  - $problem');
      }
    }

    return buffer.toString().trimRight();
  }
}

/// `testStart` 里被后续 `testDone` 需要的两个字段。
final class _TestStart {
  const _TestStart({required this.name, required this.declaresSkip});

  final String name;
  final bool declaresSkip;
}

Map<String, Object?> _requireMap(
  Map<String, Object?> parent,
  String key,
  String where,
  String source,
) {
  final Object? value = parent[key];
  if (value is! Map<String, Object?>) {
    throw TestReportFormatException(
      '$where 的字段 "$key" 缺失或不是对象（实际 ${value.runtimeType}）',
      source: source,
    );
  }
  return value;
}

Map<String, Object?>? _optionalMap(Map<String, Object?> parent, String key) {
  final Object? value = parent[key];
  return value is Map<String, Object?> ? value : null;
}

String _requireString(Map<String, Object?> parent, String key, String where, String source) {
  final Object? value = parent[key];
  if (value is! String) {
    throw TestReportFormatException(
      '$where 的字段 "$key" 缺失或不是字符串（实际 ${value.runtimeType}）',
      source: source,
    );
  }
  return value;
}

int _requireInt(Map<String, Object?> parent, String key, String where, String source) {
  final Object? value = parent[key];
  if (value is! int) {
    throw TestReportFormatException(
      '$where 的字段 "$key" 缺失或不是整数（实际 ${value.runtimeType}）',
      source: source,
    );
  }
  return value;
}

/// 读布尔字段，缺失按 `false`。
///
/// 默认值取 `false` 而不是「缺失即报错」：这两个字段在协议里是可选新增的，
/// 而它们缺失时最保守的解释就是「没有跳过、不是合成用例」——
/// 一旦某天协议改了默认语义，用例数量下界与必需用例名两条断言仍会兜住。
bool _flag(Map<String, Object?> parent, String key, String where, String source) {
  final Object? value = parent[key];
  if (value == null) {
    return false;
  }
  if (value is! bool) {
    throw TestReportFormatException(
      '$where 的字段 "$key" 不是布尔值（实际 ${value.runtimeType}）',
      source: source,
    );
  }
  return value;
}

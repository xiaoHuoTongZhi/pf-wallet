/// 向量运行器。
///
/// 职责边界很清楚：**它只做判定，不做事**。
///   - 不做 I/O（文件读取在 [loadVectorSuites] 里）
///   - 不做输出（CLI 在 bin/ 里）
///   - 不做实现（各 [VectorDriver]）
///
/// 这样 runner 可以被单测直接调用，塞进内存构造的套件即可验证
/// 「判定规则本身是否正确」—— 包括「期望抛错却正常返回」、
/// 「kind 未注册」、「缺少期望键」这些容易写错的分支。
library;

import 'package:pf_core/pf_core.dart';

import 'compare.dart';
import 'driver.dart';
import 'outcome.dart';
import 'registry.dart';
import 'report.dart';
import 'vector.dart';

/// 运行筛选条件。
final class VectorFilter {
  const VectorFilter({
    this.kinds = const <String>{},
    this.milestones = const <String>{},
    this.tags = const <String>{},
    this.caseIds = const <String>{},
  });

  /// 只跑这些 kind（空集表示不筛）。
  final Set<String> kinds;

  /// 只跑这些里程碑（空集表示不筛）。
  final Set<String> milestones;

  /// 只跑带这些标签之一的用例（空集表示不筛）。
  final Set<String> tags;

  /// 只跑这些用例 ID（空集表示不筛）。
  final Set<String> caseIds;

  bool get isEmpty => kinds.isEmpty && milestones.isEmpty && tags.isEmpty && caseIds.isEmpty;

  bool accepts(PfVectorCase c) {
    if (kinds.isNotEmpty && !kinds.contains(c.kind)) return false;
    if (milestones.isNotEmpty && !milestones.contains(c.milestone.value)) {
      return false;
    }
    if (tags.isNotEmpty && !c.tags.any(tags.contains)) return false;
    if (caseIds.isNotEmpty && !caseIds.contains(c.id)) return false;
    return true;
  }
}

/// 一次运行的完整产物。
final class VectorRun {
  const VectorRun({
    required this.report,
    required this.warnings,
    this.uncoveredKinds = const <String>[],
  });

  final VectorReport report;

  /// 非致命提醒。不会导致退出码非 0，但会被打印出来。
  ///
  /// 目前两类：
  ///   - 注册了驱动却没有任何向量引用它（驱动白写了 or 向量漏了）
  ///   - 被筛选条件排除掉的用例数（提醒「本次不是全量跑」）
  final List<String> warnings;

  /// **已实现**但没有任何向量引用它的 kind（排序）。
  ///
  /// 与 [warnings] 的区别是「该怎么处理」：提醒只打印，本字段供
  /// `vector_report.dart --require-coverage` 直接判失败。
  ///
  /// 它守的是方案 §7.6 的第一条顺序原则 —— **向量先于实现**。
  /// 只靠提醒守不住：提醒在 CI 日志里活不过一周，而「实现写了但没人拿它
  /// 和任何期望值比对」这件事本身不会让任何一条用例变红，因此表现为全绿。
  final List<String> uncoveredKinds;

  /// 未注册 kind 的用例数。这些已经是 fail，这里单列便于 CI 报错定位。
  int get unregisteredKindFailures =>
      report.results
          .where(
            (VectorCaseResult r) =>
                r.status == VectorStatus.fail && (r.message?.startsWith('未注册的 kind') ?? false),
          )
          .length;
}

/// 运行器。
final class VectorRunner {
  const VectorRunner({required this.registry, this.filter = const VectorFilter()});

  final VectorRegistry registry;
  final VectorFilter filter;

  /// 跑完所有套件。
  Future<VectorRun> run(Iterable<PfVectorSuite> suites) async {
    final results = <VectorCaseResult>[];
    final warnings = <String>[];
    final usedKinds = <String>{};
    var skipped = 0;

    final ordered =
        suites.toList()..sort((PfVectorSuite a, PfVectorSuite b) => a.suite.compareTo(b.suite));

    for (final suite in ordered) {
      suite.validateUniqueIds();
      for (final c in suite.cases) {
        if (!filter.accepts(c)) {
          skipped += 1;
          continue;
        }
        usedKinds.add(c.kind);
        results.add(await _runCase(suite, c));
      }
    }

    // 注册了却没人用的驱动：几乎总是「向量还没写」或「kind 拼错了」。
    //
    // 未就绪的驱动不报警：M0 阶段 M2 的那些 kind 本来就还没有向量 ——
    // 它们的期望值必须由独立的参考实现（argon2 CLI / OpenSSL）生成，
    // 属于 M2 的工作范围。对它们报警只会制造长期存在的噪音，
    // 而噪音会让真正的警报被忽略。
    final uncovered = <String>[];
    for (final driver in registry.drivers) {
      if (driver.isImplemented && !usedKinds.contains(driver.kind)) {
        uncovered.add(driver.kind);
        warnings.add(
          '驱动 "${driver.kind}" 已实现但没有任何向量引用它 —— '
          '要么向量漏了，要么 kind 拼错了',
        );
      }
    }
    uncovered.sort();
    if (skipped > 0) {
      warnings.add('筛选条件排除了 $skipped 条用例，本次不是全量运行');
    }

    final env = captureEnvironment();
    return VectorRun(
      report: VectorReport(
        results: results,
        generatedAt: DateTime.now().toUtc(),
        dartVersion: env.dartVersion,
        operatingSystem: env.operatingSystem,
      ),
      warnings: warnings,
      uncoveredKinds: uncovered,
    );
  }

  Future<VectorCaseResult> _runCase(PfVectorSuite suite, PfVectorCase c) async {
    final stopwatch = Stopwatch()..start();
    final driver = registry.lookup(c.kind);

    if (driver == null) {
      stopwatch.stop();
      return _build(
        suite,
        c,
        VectorStatus.fail,
        stopwatch.elapsedMicroseconds,
        '未注册的 kind "${c.kind}" —— '
        '向量与驱动之间失去了对应关系，必须立刻修好而不是跳过。'
        '已注册：${registry.kinds.join(", ")}',
      );
    }

    if (!driver.isImplemented) {
      stopwatch.stop();
      return _build(
        suite,
        c,
        VectorStatus.pending,
        stopwatch.elapsedMicroseconds,
        '实现未就绪（计划于 ${driver.plannedMilestone}）：${driver.description}',
      );
    }

    VectorOutcome outcome;
    try {
      outcome = await driver.run(c.input);
    } on PfError catch (error) {
      outcome = VectorOutcome.errored(error.code, message: error.message);
    } catch (error, stack) {
      stopwatch.stop();
      return _build(
        suite,
        c,
        VectorStatus.fail,
        stopwatch.elapsedMicroseconds,
        '驱动抛出非 PfError 异常：${error.runtimeType}: $error\n'
        '${stack.toString().split("\n").take(4).join("\n")}',
      );
    }
    stopwatch.stop();

    final micros = stopwatch.elapsedMicroseconds;

    if (outcome.pending) {
      return _build(suite, c, VectorStatus.pending, micros, outcome.message ?? '驱动声明该用例尚未实现');
    }

    return _judge(suite, c, outcome, micros);
  }

  /// 判定规则。**这是整个框架的心脏**，改动必须配单测。
  VectorCaseResult _judge(PfVectorSuite suite, PfVectorCase c, VectorOutcome outcome, int micros) {
    final expected = c.expect;

    if (expected.expectsError) {
      if (!outcome.isError) {
        return _build(
          suite,
          c,
          VectorStatus.fail,
          micros,
          '期望抛出 ${expected.errorCode}，实际正常返回 '
          '${describeMismatch(expected.errorCode, outcome.actual)}',
          actual: outcome.actual,
        );
      }
      if (expected.acceptsAnyError) {
        return _build(suite, c, VectorStatus.pass, micros, null);
      }
      if (outcome.errorCode != expected.errorCode) {
        return _build(
          suite,
          c,
          VectorStatus.fail,
          micros,
          '错误码不符：${describeMismatch(expected.errorCode, outcome.errorCode)}'
          '${outcome.message == null ? "" : "（${outcome.message}）"}',
        );
      }
      return _build(suite, c, VectorStatus.pass, micros, null);
    }

    if (outcome.isError) {
      return _build(
        suite,
        c,
        VectorStatus.fail,
        micros,
        '期望正常返回，实际抛出 ${outcome.errorCode}'
        '${outcome.message == null ? "" : "：${outcome.message}"}',
      );
    }

    final want = expected.value ?? const <String, Object?>{};
    final got = outcome.actual ?? const <String, Object?>{};

    for (final key in want.keys) {
      if (!got.containsKey(key)) {
        return _build(
          suite,
          c,
          VectorStatus.fail,
          micros,
          '驱动输出缺少期望字段 "$key"。实际输出字段：'
          '${got.keys.isEmpty ? "(空)" : got.keys.join(", ")}',
          expected: want,
          actual: got,
        );
      }
      if (!jsonEquals(want[key], got[key])) {
        return _build(
          suite,
          c,
          VectorStatus.fail,
          micros,
          '字段 "$key" 不符：${describeMismatch(want[key], got[key])}',
          expected: want,
          actual: got,
        );
      }
    }

    return _build(suite, c, VectorStatus.pass, micros, null);
  }

  VectorCaseResult _build(
    PfVectorSuite suite,
    PfVectorCase c,
    VectorStatus status,
    int micros,
    String? message, {
    Map<String, Object?>? expected,
    Map<String, Object?>? actual,
  }) => VectorCaseResult(
    caseId: c.id,
    suite: suite.suite,
    kind: c.kind,
    title: c.title,
    milestone: c.milestone.value,
    status: status,
    durationMicros: micros,
    // pass 的用例不写 message，避免报告里塞满无用的噪音
    message: status == VectorStatus.pass ? null : message,
    expected: expected,
    actual: actual,
  );
}

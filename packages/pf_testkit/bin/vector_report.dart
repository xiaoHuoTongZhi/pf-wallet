/// 黄金向量运行入口。
///
/// 用法：
///   dart run packages/pf_testkit/bin/vector_report.dart
///   dart run packages/pf_testkit/bin/vector_report.dart --list-pending
///   dart run packages/pf_testkit/bin/vector_report.dart --update-baseline
///   dart run packages/pf_testkit/bin/vector_report.dart --require-coverage
///   dart run packages/pf_testkit/bin/vector_report.dart --kind container.header.encode
///
/// `--require-coverage` 除了判定，还会把覆盖结论写成
/// `build/vectors/coverage.json`（CI 当 artifact 传，见 [CoverageReport]）。
///
/// 退出码：
///   0  全部通过，且 pending 集合与基线一致
///   1  有向量失败，或 pending 集合与基线不符
///   2  向量文件 / 参数 / 环境本身有问题（**与实现无关**）
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:pf_testkit/pf_testkit.dart';

const String _usage = '''
运行黄金测试向量。

用法：dart run packages/pf_testkit/bin/vector_report.dart [选项]

选项：
''';

Future<void> main(List<String> argv) async {
  exitCode = await _run(argv);
}

Future<int> _run(List<String> argv) async {
  final parser =
      ArgParser()
        ..addOption('vectors', abbr: 'v', help: '向量目录（缺省 test_vectors/v1）')
        ..addOption('out', abbr: 'o', help: '报告输出路径（缺省 build/vectors/report.json）')
        ..addOption('coverage-out', help: '覆盖检查报告输出路径（缺省 build/vectors/coverage.json）')
        ..addFlag('list-pending', negatable: false, help: '只列出尚未实现的用例，然后退出')
        ..addFlag(
          'update-baseline',
          negatable: false,
          help: '把当前 pending 集合写回 test_vectors/pending_baseline.json',
        )
        ..addFlag('require-coverage', negatable: false, help: '已实现的驱动必须至少被一条向量引用，否则判失败（守住「向量先于实现」）')
        ..addMultiOption('kind', help: '只跑指定 kind（可重复）')
        ..addMultiOption('milestone', help: '只跑指定里程碑，如 M0（可重复）')
        ..addMultiOption('tag', help: '只跑带指定标签的用例（可重复）')
        ..addMultiOption('case', help: '只跑指定用例 ID（可重复）')
        ..addFlag('quiet', abbr: 'q', negatable: false, help: '只输出结论行')
        ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助');

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (error) {
    stderr
      ..writeln('参数错误：${error.message}')
      ..writeln(_usage)
      ..writeln(parser.usage);
    return 2;
  }

  if (args.flag('help')) {
    stdout
      ..writeln(_usage)
      ..writeln(parser.usage);
    return 0;
  }

  final Directory repoRoot;
  final List<PfVectorSuite> suites;
  try {
    repoRoot = findRepoRoot();
    suites = loadVectorSuites(_resolveVectorsDirectory(repoRoot, args));
  } on VectorFormatException catch (error) {
    stderr.writeln('✗ 向量加载失败：$error');
    return 2;
  }

  final filter = VectorFilter(
    kinds: args.multiOption('kind').toSet(),
    milestones: args.multiOption('milestone').toSet(),
    tags: args.multiOption('tag').toSet(),
    caseIds: args.multiOption('case').toSet(),
  );

  final VectorRun run;
  final VectorRegistry registry = buildDefaultRegistry();
  try {
    run = await VectorRunner(registry: registry, filter: filter).run(suites);
  } on VectorFormatException catch (error) {
    stderr.writeln('✗ 向量自检失败：$error');
    return 2;
  }

  final report = run.report;

  if (args.flag('list-pending')) {
    return _listPending(report, repoRoot);
  }

  if (args.flag('update-baseline')) {
    return _updateBaseline(repoRoot, report);
  }

  _printReport(report, run, quiet: args.flag('quiet'), repoRoot: repoRoot);

  try {
    final outPath = _resolveReportPath(repoRoot, args);
    File(outPath).parent.createSync(recursive: true);
    File(outPath).writeAsStringSync('${report.toPrettyJson()}\n', encoding: utf8);
    if (!args.flag('quiet')) {
      stdout.writeln('报告已写入 ${p.relative(outPath, from: repoRoot.path)}');
    }
  } on FileSystemException catch (error) {
    stderr.writeln('✗ 报告写入失败：${error.message}');
    return 2;
  }

  var code = 0;
  if (!report.isClean) code = 1;

  // 基线校验只在「全量跑」时进行。
  // 带筛选条件时 pending 集合天然是子集，拿它比基线只会产生一堆假警报。
  if (filter.isEmpty) {
    final load = loadPendingBaseline(repoRoot);
    final delta = load.baseline.diff(report.pendingCaseIds);
    if (!delta.isClean) {
      stdout
        ..writeln()
        ..writeln('✗ pending 基线与实际不符：')
        ..writeln(delta.describe())
        ..writeln()
        ..writeln(
          load.existed
              ? '若确认新的 pending 是有意为之，运行 --update-baseline 更新基线；'
                  '否则说明有实现从「已就绪」退回了「未实现」。'
              : '基线文件尚不存在。首次引入时请先运行 --update-baseline 建立基线。',
        );
      code = 1;
    }
  } else if (!args.flag('quiet')) {
    stdout.writeln('（带筛选条件运行，跳过 pending 基线校验）');
  }

  // 覆盖检查：已实现的驱动必须至少被一条向量引用。
  //
  // 它守的是方案 §7.6 的第一条顺序原则 —— 向量先于实现。反过来的话，
  // 实现算出什么、测试就接受什么，而报告是全绿的，没有任何迹象表明
  // 「这个原语从未与任何独立期望值比对过」。
  //
  // 只在全量跑时判定：带筛选条件时 usedKinds 天然是子集，
  // 拿它判覆盖会把每一个没被筛中的 kind 都报成未覆盖。
  if (args.flag('require-coverage')) {
    if (!filter.isEmpty) {
      stdout.writeln('（带筛选条件运行，跳过覆盖检查）');
    } else {
      final coverage = _buildCoverageReport(registry: registry, suites: suites, run: run);

      if (coverage.ok) {
        stdout.writeln(coverage.summaryLine);
      } else {
        stdout
          ..writeln()
          ..writeln(coverage.summaryLine);
        if (coverage.uncoveredKinds.isNotEmpty) {
          stdout
            ..writeln('没有任何向量引用的已实现驱动：')
            ..writeln(coverage.describeUncovered())
            ..writeln()
            ..writeln(
              '这说明有实现先于向量落地了 —— 也就是「实现算出什么、测试就接受什么」。'
              '请为它先补上独立生成的期望值（见 test_vectors/README.md），再保留实现。',
            );
        }
        if (coverage.orphanKinds.isNotEmpty) {
          stdout
            ..writeln('被向量引用、但注册表里没人认领的 kind：')
            ..writeln(coverage.describeOrphans())
            ..writeln()
            ..writeln(
              '这不是缺向量，而是**接线断了**：要么向量的 kind 拼错了，'
              '要么驱动的注册名改了。这些用例在运行器里已经是 fail（不是跳过），'
              '所以别只看「覆盖」两个字 —— 先按上面的 kind 名去 '
              'packages/pf_testkit/lib/src/drivers/ 找同名驱动。',
            );
        }
        code = 1;
      }

      // 报告先落盘、再返回退出码：红的时候恰恰最需要这份证据，
      // 所以「没通过就不写文件」是错的（artifact 会空着）。
      try {
        final coveragePath = _resolveCoverageReportPath(repoRoot, args);
        File(coveragePath).parent.createSync(recursive: true);
        File(coveragePath).writeAsStringSync('${coverage.toPrettyJson()}\n', encoding: utf8);
        if (!args.flag('quiet')) {
          stdout.writeln('覆盖检查报告已写入 ${p.relative(coveragePath, from: repoRoot.path)}');
        }
      } on FileSystemException catch (error) {
        stderr.writeln('✗ 覆盖检查报告写入失败：${error.message}');
        return 2;
      }
    }
  }

  return code;
}

/// 汇总一次覆盖检查的结果。
///
/// [CoverageReport.vectorCounts] 只投影到**已注册**的 kind 上：
/// 向量写了但没人认领的 kind 属于接线问题，混进来会把驱动数撑大 ——
/// 那样 `drivers` 计数就与 `registry.kinds.length` 对不上了。
/// 但它们**不是**被丢掉：同一个循环顺手收进 [CoverageReport.orphanCounts]，
/// 让报告两个方向都能判（漏写向量 / 写错 kind）。
CoverageReport _buildCoverageReport({
  required VectorRegistry registry,
  required List<PfVectorSuite> suites,
  required VectorRun run,
}) {
  final rawCounts = <String, int>{};
  for (final suite in suites) {
    for (final testCase in suite.cases) {
      rawCounts.update(testCase.kind, (int n) => n + 1, ifAbsent: () => 1);
    }
  }

  final registered = registry.kinds.toSet();
  final report = run.report;
  return CoverageReport(
    generatedAt: report.generatedAt,
    dartVersion: report.dartVersion,
    operatingSystem: report.operatingSystem,
    vectorCounts: <String, int>{for (final kind in registry.kinds) kind: rawCounts[kind] ?? 0},
    orphanCounts: <String, int>{
      for (final entry in rawCounts.entries)
        if (!registered.contains(entry.key)) entry.key: entry.value,
    },
    passed: report.passed,
    failed: report.failed,
    pending: report.pending,
    uncoveredKinds: run.uncoveredKinds,
  );
}

Directory _resolveVectorsDirectory(Directory repoRoot, ArgResults args) {
  final raw = args.option('vectors');
  if (raw == null) {
    return Directory(p.join(repoRoot.path, VectorSchema.vectorsDirectory));
  }
  return Directory(p.isAbsolute(raw) ? raw : p.join(repoRoot.path, raw));
}

String _resolveReportPath(Directory repoRoot, ArgResults args) {
  final raw = args.option('out');
  if (raw == null) {
    return p.join(repoRoot.path, VectorSchema.reportFile);
  }
  return p.isAbsolute(raw) ? raw : p.join(repoRoot.path, raw);
}

String _resolveCoverageReportPath(Directory repoRoot, ArgResults args) {
  final raw = args.option('coverage-out');
  if (raw == null) {
    return p.join(repoRoot.path, VectorSchema.coverageReportFile);
  }
  return p.isAbsolute(raw) ? raw : p.join(repoRoot.path, raw);
}

int _listPending(VectorReport report, Directory repoRoot) {
  final pending =
      report.results.where((VectorCaseResult r) => r.status == VectorStatus.pending).toList();

  if (pending.isEmpty) {
    stdout.writeln('没有处于 pending 的用例 —— 全部实现已就绪。');
    return 0;
  }

  stdout.writeln('尚未实现（${pending.length} 条）：');
  var currentMilestone = '';
  for (final result in pending) {
    if (result.milestone != currentMilestone) {
      currentMilestone = result.milestone;
      stdout.writeln('  [$currentMilestone]');
    }
    stdout.writeln('    ${result.caseId}');
    stdout.writeln('      kind: ${result.kind}');
    stdout.writeln('      ${result.message ?? ""}');
  }
  stdout.writeln();
  stdout.writeln('其余 ${report.passed} 条已通过。');
  return 0;
}

int _updateBaseline(Directory repoRoot, VectorReport report) {
  final baseline = PendingBaseline(entries: report.pendingCaseIds);
  final file = File(
    p.join(repoRoot.path, VectorSchema.pendingBaselineFile.replaceAll('/', Platform.pathSeparator)),
  );
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('${baseline.toPrettyJson()}\n', encoding: utf8);
  stdout.writeln(
    '基线已更新：${p.relative(file.path, from: repoRoot.path)} '
    '（${baseline.entries.length} 条 pending）',
  );
  if (report.failed > 0) {
    stdout.writeln('注意：本次仍有 ${report.failed} 条失败，先修失败再提交基线。');
    return 1;
  }
  return 0;
}

void _printReport(
  VectorReport report,
  VectorRun run, {
  required bool quiet,
  required Directory repoRoot,
}) {
  if (!quiet) {
    for (final result in report.results.where(
      (VectorCaseResult r) => r.status != VectorStatus.pass,
    )) {
      final mark = result.status == VectorStatus.fail ? '✗' : '·';
      stdout.writeln(
        '$mark [${result.status.wireName}] ${result.caseId} '
        '(${result.kind}, ${result.milestone})',
      );
      stdout.writeln('    ${result.title}');
      if (result.message != null) {
        for (final line in result.message!.split('\n')) {
          stdout.writeln('    $line');
        }
      }
    }
    if (report.results.any((VectorCaseResult r) => r.status != VectorStatus.pass)) {
      stdout.writeln();
    }

    for (final warning in run.warnings) {
      stdout.writeln('! $warning');
    }
    if (run.warnings.isNotEmpty) stdout.writeln();

    stdout.writeln('环境：${report.operatingSystem}');
    stdout.writeln('Dart：${report.dartVersion}');
  }

  stdout.writeln(report.summaryLine);
  if (run.unregisteredKindFailures > 0) {
    stdout.writeln(
      '其中 ${run.unregisteredKindFailures} 条失败的原因是 kind 未注册 —— '
      '这属于向量或驱动接线问题，不是实现问题。',
    );
  }
  stdout.writeln(report.isClean ? '✓ 全部已实现向量通过' : '✗ ${report.failed} 条向量失败');
}

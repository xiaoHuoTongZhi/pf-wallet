/// 审阅 `flutter test --reporter json` 产出的报告，断言「用例确实执行了」。
///
/// 用法：
///   dart run packages/pf_testkit/bin/assert_test_report.dart \
///     --report build/test-reports/pf_mobile.jsonl \
///     --min-executed 3 \
///     --require '应用能构建并显示构建信息'
///
/// 退出码：
///   0  报告可读，且全部期望成立
///   1  报告可读，但期望不成立（有用例失败 / 被跳过 / 该跑的没跑）
///   2  报告本身不可用（文件不存在、为空、不是合法 JSON Lines）
///
/// 退出码 2 与 1 分开的理由和 `vector_report.dart` 一样：
/// 「报告没拿到」和「测试有失败」的修复方向完全不同，
/// 混成一个退出码会让人对着正确的实现找半天。
///
/// 为什么需要它 —— 见 `lib/src/test_report.dart` 的库注释：
/// `flutter test` 在「0 条用例」与「全部被跳过」两种情况下同样返回 0，
/// 而本机开发沙箱跑不了 flutter_tester，pf_mobile 的三条 widget 测试
/// 只有在 CI 上核对过名字，才算真的执行过。
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:pf_testkit/pf_testkit.dart';

const String _usage = '''
审阅测试报告，断言用例确实被执行（而不是被跳过）。

用法：dart run packages/pf_testkit/bin/assert_test_report.dart [选项]

典型场景（CI 关卡 2，证明 pf_mobile 的 widget 测试真的跑了）：
  flutter test --reporter json > build/test-reports/pf_mobile.jsonl
  dart run packages/pf_testkit/bin/assert_test_report.dart \\
    --report build/test-reports/pf_mobile.jsonl \\
    --min-executed 3 \\
    --require '应用能构建并显示构建信息'

选项：
''';

Future<void> main(List<String> argv) async {
  exitCode = _run(argv);
}

int _run(List<String> argv) {
  final ArgParser parser =
      ArgParser()
        ..addOption('report', abbr: 'r', help: 'flutter test --reporter json 的输出文件（相对仓库根或绝对路径）')
        ..addOption('min-executed', help: '执行并通过的条数下界（默认 0）', defaultsTo: '0')
        ..addMultiOption('require', help: '必须执行到的用例名（子串匹配，可重复）')
        ..addFlag('allow-skipped', negatable: false, help: '容忍被跳过的用例（默认不容忍：跳过等于没有执行）')
        ..addOption('label', help: '输出前缀，用于在多平台日志里指认来源')
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

  final String? rawReport = args.option('report');
  if (rawReport == null) {
    stderr
      ..writeln('缺少必填参数 --report')
      ..writeln(_usage)
      ..writeln(parser.usage);
    return 2;
  }

  final int minExecuted;
  try {
    minExecuted = int.parse(args.option('min-executed') ?? '0');
  } on FormatException {
    stderr.writeln('参数错误：--min-executed 必须是整数');
    return 2;
  }

  final Directory repoRoot;
  try {
    repoRoot = findRepoRoot();
  } on VectorFormatException catch (error) {
    stderr.writeln('✗ 找不到仓库根：${error.message}');
    return 2;
  }

  // 相对路径按**仓库根**解析，而不是当前目录 ——
  // 与 vector_report.dart 一致，这样从任何子目录调用都得到同一个结果。
  final String reportPath = p.isAbsolute(rawReport) ? rawReport : p.join(repoRoot.path, rawReport);

  final File reportFile = File(reportPath);
  if (!reportFile.existsSync()) {
    stderr.writeln('✗ 报告不存在：${p.relative(reportPath, from: repoRoot.path)}');
    stderr.writeln('  测试步骤可能没有执行，或输出被重定向到了别处。');
    return 2;
  }

  final String content = reportFile.readAsStringSync();
  if (content.trim().isEmpty) {
    stderr.writeln('✗ 报告是空的：${p.relative(reportPath, from: repoRoot.path)}');
    stderr.writeln('  空报告意味着测试进程没有产出任何事件（编译失败？reporter 传错？）。');
    return 2;
  }

  final String label = args.option('label') ?? '';

  final TestReportSummary summary;
  try {
    summary = TestReportSummary.parse(content, source: p.relative(reportPath, from: repoRoot.path));
  } on TestReportFormatException catch (error) {
    stderr
      ..writeln('✗ 报告不可解析：$error')
      // 这条提示是踩过坑之后补的：报告「不可解析」最常见的成因不是报告本身坏，
      // 而是产出报告的**命令**把别的输出混进了 stdout。
      // 报告文件由 `> ../../build/test-reports/pf_mobile.jsonl` 重定向而来，
      // 所以任何一行写进 stdout 的东西都会进入报告。
      ..writeln('  常见成因（按出现频率）：')
      ..writeln('   1. `flutter test` 没加 `--no-pub` —— 它会先把 pub 的解析进度')
      ..writeln('      （Resolving dependencies in ... / Downloading packages... /')
      ..writeln('      Got dependencies! ...）写进 stdout，使报告前几十行不是 JSON。')
      ..writeln('      修法：`flutter test --no-pub --reporter json > <报告>`。')
      ..writeln('   2. 报告被 append（>>）到了上一次运行的残留文件上，或两次运行混写。')
      ..writeln('   3. reporter 参数写错（传了 compact / expanded 之类）。');
    return 2;
  }

  if (summary.isEmpty) {
    stderr.writeln('✗ 报告里没有任何用例事件：${summary.source}');
    stderr.writeln('  「跑完了但一条都没有」不是通过 —— 常见原因是测试文件被删、');
    stderr.writeln('  文件名不匹配 *_test.dart、或 reporter 输出被其他内容污染。');
    return 2;
  }

  final TestReportVerdict verdict = TestReportVerdict.judge(
    summary: summary,
    expectation: TestReportExpectation(
      minExecuted: minExecuted,
      requiredNames: args.multiOption('require'),
      allowSkipped: args.flag('allow-skipped'),
    ),
  );

  stdout.writeln(label.isEmpty ? '── 测试报告审阅 ──' : '── 测试报告审阅 · $label ──');
  stdout.writeln(verdict.describe());

  return verdict.isClean ? 0 : 1;
}

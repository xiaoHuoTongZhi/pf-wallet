/// PF Wallet 自定义 CI 门禁。
///
/// 用法：
///   dart run tools/guards/bin/guards.dart `<check>` [选项]
///
/// check 取值：
///   deps        依赖黑名单（含传递依赖）与来源审计
///   banned-api  禁用 API 扫描
///   logging     日志敏感信息扫描
///   manifest    平台隐私清单校验
///   version     版本号一致性（version.dart ↔ 各 pubspec）
///   all         依次执行以上全部
///
/// 退出码：
///   0 通过
///   1 检查不通过（代码有问题）
///   2 工具或配置错误（规则文件写错、pubspec.lock 缺失等）
///
/// 刻意区分 1 与 2：CI 必须把 2 当成基础设施故障。
/// 否则最坏的情况是有人为了让流水线变绿而去删规则。
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:pf_guards/checks/deps.dart';
import 'package:pf_guards/checks/manifest.dart';
import 'package:pf_guards/checks/source_checks.dart';
import 'package:pf_guards/checks/version.dart';
import 'package:pf_guards/model.dart';
import 'package:pf_guards/repo.dart';
import 'package:pf_guards/rules.dart';

/// 退出码常量。
const int exitPass = 0;
const int exitFail = 1;
const int exitToolError = 2;

/// 报告输出目录（相对仓库根，已被 .gitignore 忽略）。
const String reportDirectory = 'build/guards';

const List<String> availableChecks = <String>[
  'deps',
  'banned-api',
  'logging',
  'manifest',
  'version',
];

void main(List<String> arguments) {
  final parser =
      ArgParser()
        ..addOption('repo', abbr: 'r', help: '仓库根目录；缺省时从当前目录向上查找 melos.yaml')
        ..addOption('rules', help: '规则目录（相对仓库根）', defaultsTo: defaultRuleDirectory)
        ..addFlag('quiet', abbr: 'q', negatable: false, help: '只输出 error 与 warning')
        ..addFlag('no-report', negatable: false, help: '不写 build/guards/*.json 报告')
        ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助');

  ArgResults options;
  try {
    options = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln('参数错误: ${error.message}');
    stderr.writeln();
    _printUsage(parser);
    exit(exitToolError);
  }

  if (options['help'] as bool) {
    _printUsage(parser);
    exit(exitPass);
  }
  if (options.rest.isEmpty) {
    _printUsage(parser);
    exit(exitToolError);
  }

  final targets = options.rest.first == 'all' ? availableChecks : <String>[options.rest.first];
  for (final target in targets) {
    if (!availableChecks.contains(target)) {
      stderr.writeln('未知的检查项: "$target"');
      stderr.writeln('可用: ${availableChecks.join(', ')}, all');
      exit(exitToolError);
    }
  }

  final quiet = options['quiet'] as bool;
  final writeReport = !(options['no-report'] as bool);

  try {
    final repo = Repo.locate(from: options['repo'] as String?);
    final ruleSet = RuleSet(repo: repo, directory: options['rules'] as String);

    final reports = <GuardReport>[];
    for (final target in targets) {
      reports.add(_runSingle(target, repo, ruleSet));
    }

    _printHeader(repo, targets);

    var hasError = false;
    for (final report in reports) {
      stdout.write(report.render(verbose: !quiet));
      stdout.writeln();
      if (!report.ok) hasError = true;
      if (writeReport) {
        repo.writeFile('$reportDirectory/${report.check}.json', report.toJsonString());
      }
    }

    _printSummary(reports, writeReport: writeReport);
    exit(hasError ? exitFail : exitPass);
  } on GuardException catch (error) {
    stderr.writeln();
    stderr.writeln('✗ 门禁无法完成判定（退出码 $exitToolError）');
    stderr.writeln('  ${error.message}');
    final hint = error.hint;
    if (hint != null) stderr.writeln('  → $hint');
    exit(exitToolError);
  } on ProcessException catch (error) {
    stderr.writeln('✗ 进程调用失败: ${error.message}');
    exit(exitToolError);
  }
}

GuardReport _runSingle(String target, Repo repo, RuleSet ruleSet) {
  switch (target) {
    case 'deps':
      return runDepsCheck(
        repo: repo,
        rules: ruleSet.loadDepRules(),
        allowlist: ruleSet.loadDepAllowlist(),
      );
    case 'banned-api':
      return runBannedApiCheck(repo: repo, rules: ruleSet.loadBannedApiRules());
    case 'logging':
      return runLoggingCheck(repo: repo, rules: ruleSet.loadLoggingRules());
    case 'manifest':
      return runManifestCheck(repo: repo, rules: ruleSet.loadManifestRules());
    case 'version':
      return runVersionCheck(repo: repo);
    default:
      throw GuardException('未实现的检查项: $target');
  }
}

void _printHeader(Repo repo, List<String> targets) {
  stdout
    ..writeln('═' * 72)
    ..writeln('PF Wallet · guards')
    ..writeln('  repo   : ${repo.root}')
    ..writeln('  checks : ${targets.join(', ')}')
    ..writeln('═' * 72)
    ..writeln();
}

void _printSummary(List<GuardReport> reports, {required bool writeReport}) {
  final errors = reports.fold<int>(0, (sum, r) => sum + r.errorCount);
  final warnings = reports.fold<int>(0, (sum, r) => sum + r.warningCount);
  final infos = reports.fold<int>(0, (sum, r) => sum + r.infoCount);

  stdout
    ..writeln('═' * 72)
    ..writeln('汇总：${reports.length} 项检查，error=$errors warning=$warnings info=$infos');

  for (final report in reports) {
    final mark = report.ok ? '✓' : '✗';
    stdout.writeln(
      '  $mark ${report.check.padRight(12)} '
      'error=${report.errorCount} warning=${report.warningCount} info=${report.infoCount}',
    );
  }

  if (writeReport) {
    stdout.writeln('  结构化报告：$reportDirectory/<check>.json');
  }
  stdout.writeln(errors == 0 ? '结果：PASS' : '结果：FAIL');
  stdout.writeln('═' * 72);
}

void _printUsage(ArgParser parser) {
  stdout
    ..writeln('PF Wallet 自定义 CI 门禁')
    ..writeln()
    ..writeln('用法: dart run tools/guards/bin/guards.dart <check> [选项]')
    ..writeln()
    ..writeln('check:')
    ..writeln('  deps        依赖黑名单（含传递依赖）与来源审计')
    ..writeln('  banned-api  禁用 API 扫描（动态执行 / 网络客户端 / 弱随机 / 弱哈希 …）')
    ..writeln('  logging     日志敏感信息扫描')
    ..writeln('  manifest    Android / iOS 平台隐私清单校验')
    ..writeln('  version     版本号一致性（version.dart ↔ 各 pubspec）')
    ..writeln('  all         依次执行以上全部')
    ..writeln()
    ..writeln('选项:')
    ..writeln(parser.usage)
    ..writeln()
    ..writeln('退出码: 0 通过 / 1 检查不通过 / 2 工具或配置错误');
}

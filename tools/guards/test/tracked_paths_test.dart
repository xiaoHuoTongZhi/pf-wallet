/// 入库路径检查的测试。
///
/// 分两部分：
///   1. **用真实规则文件**（从仓库 tools/guards/rules 复制到临时仓库）——
///      规则 YAML 的字段与语义都被真实覆盖，改规则时先在这里看到结果。
///   2. **手工构造规则** —— 覆盖只有放宽/收紧配置才出现的分支
///      （severity 覆盖、截断上限）。这些分支不能靠改真实规则来测：
///      真实规则必须始终是 error，否则测试会把生产配置带偏。
///
/// 全部用例都通过 `trackedPaths` 注入路径，不依赖 git ——
/// 临时目录不是 git 仓库，而「规则是否按预期命中」必须能脱离 git 验证。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pf_guards/checks/tracked_paths.dart';
import 'package:pf_guards/glob.dart';
import 'package:pf_guards/model.dart';
import 'package:pf_guards/repo.dart';
import 'package:pf_guards/rules.dart';
import 'package:test/test.dart';

/// 当前仓库里真实存在、且**必须**被白名单接受的代表性路径。
///
/// 这是白名单的「金丝雀」：它不检查整个仓库（那需要 git），
/// 但每个受控区域各取一样，任何一处白名单被写坏都会在这里现形。
const List<String> _canaryPaths = <String>[
  '.editorconfig',
  '.flutter-version',
  '.gitattributes',
  '.gitignore',
  'README.md',
  'analysis_options.yaml',
  'melos.yaml',
  'pubspec.lock',
  'pubspec.yaml',
  '.github/workflows/gate1-static.yml',
  'apps/pf_mobile/lib/main.dart',
  'apps/pf_mobile/test/smoke_test.dart',
  'docs/M0_ACCEPTANCE.md',
  'packages/pf_core/lib/src/ulid.dart',
  'packages/pf_crypto/test/params_test.dart',
  'packages/pf_testkit/bin/assert_test_report.dart',
  'test_vectors/pending_baseline.json',
  'test_vectors/schema/vector.schema.json',
  'test_vectors/v1/money.json',
  'tools/ci/compare_verdicts.py',
  'tools/guards/lib/checks/tracked_paths.dart',
  'tools/guards/rules/tracked_paths.yaml',
  'tools/guards/test/glob_test.dart',
];

void main() {
  late Directory temp;
  late Repo repo;
  late TrackedPathRules rules;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('pf_tracked_paths_');
    final rulesDirectory = Directory(p.join(temp.path, 'tools', 'guards', 'rules'))
      ..createSync(recursive: true);
    File(
      p.join(_realRulesDirectory(), 'tracked_paths.yaml'),
    ).copySync(p.join(rulesDirectory.path, 'tracked_paths.yaml'));
    File(p.join(temp.path, 'melos.yaml')).writeAsStringSync('name: fixture\n');
    repo = Repo(temp.path);
    rules = RuleSet(repo: repo).loadTrackedPathRules();
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  GuardReport run(List<String> paths, {TrackedPathRules? override}) =>
      runTrackedPathsCheck(repo: repo, rules: override ?? rules, trackedPaths: paths);

  Set<String> ruleIds(GuardReport report) => report.findings.map((f) => f.ruleId).toSet();

  // -------------------------------------------------------------------------
  group('规则文件本身', () {
    test('可解析且关键字段到位', () {
      expect(rules.deny, isNotEmpty);
      expect(rules.allow.globs, isNotEmpty);
      expect(rules.unknownPathSeverity, Severity.error);
      expect(rules.caseCollisionSeverity, Severity.error);
      expect(rules.maxFindingsPerRule, greaterThan(0));
      expect(rules.sourcePath, 'tools/guards/rules/tracked_paths.yaml');
    });

    test('id 唯一且都带 rationale（报告要能解释为什么禁止）', () {
      final ids = rules.deny.map((r) => r.id).toList(growable: false);
      expect(ids.toSet().length, ids.length);
      for (final rule in rules.deny) {
        expect(rule.rationale, isNotEmpty, reason: '${rule.id} 缺少 rationale');
      }
    });

    test('deny 缺失 / patterns 为空 / allow 为空 / id 重复 ⇒ GuardException（退出码 2）', () {
      void writeRules(String body) => File(
        p.join(temp.path, 'tools', 'guards', 'rules', 'tracked_paths.yaml'),
      ).writeAsStringSync(body);

      writeRules('version: 1\nallow:\n  - "**"\n');
      expect(() => RuleSet(repo: repo).loadTrackedPathRules(), throwsA(isA<GuardException>()));

      writeRules(
        'version: 1\ndeny:\n  - id: a\n    severity: error\n    patterns: []\n'
        'allow:\n  - "**"\n',
      );
      expect(() => RuleSet(repo: repo).loadTrackedPathRules(), throwsA(isA<GuardException>()));

      writeRules(
        'version: 1\ndeny:\n  - id: a\n    severity: error\n    patterns:\n      - "*.db"\n',
      );
      expect(() => RuleSet(repo: repo).loadTrackedPathRules(), throwsA(isA<GuardException>()));

      writeRules(
        'version: 1\ndeny:\n'
        '  - id: dup\n    severity: error\n    patterns:\n      - "*.db"\n'
        '  - id: dup\n    severity: error\n    patterns:\n      - "*.pfb"\n'
        'allow:\n  - "**"\n',
      );
      expect(() => RuleSet(repo: repo).loadTrackedPathRules(), throwsA(isA<GuardException>()));
    });
  });

  // -------------------------------------------------------------------------
  group('正例：应当通过', () {
    test('本仓真实路径的代表性集合全部落在白名单内', () {
      final report = run(_canaryPaths);
      expect(ruleIds(report), isEmpty, reason: report.render());
      expect(report.ok, isTrue);
      expect(report.metrics['unexpectedPaths'], 0);
      expect(report.metrics['trackedFiles'], _canaryPaths.length);
    });

    test('空索引不算失败（没有待判定的东西）', () {
      final report = run(const <String>[]);
      expect(report.ok, isTrue);
      expect(report.metrics['trackedFiles'], 0);
    });

    test('路径归一化：./ 前缀与反斜杠都能正确落到白名单', () {
      final report = run(<String>[
        './docs/M0_ACCEPTANCE.md',
        r'docs\M0_CI_RUNBOOK.md',
        'packages/pf_core/lib/src/ulid.dart',
      ]);
      expect(report.ok, isTrue, reason: report.render());
      expect(report.metrics['trackedFiles'], 3);
    });

    test('重复路径只算一次（去重后不影响判定）', () {
      final report = run(<String>['README.md', './README.md', r'README.md']);
      expect(report.metrics['trackedFiles'], 1);
      expect(report.ok, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('反例：禁止入库的路径', () {
    test('回归用例：.flutter_tool_state 必须被拦住（3ebe837 的事故）', () {
      final report = run(<String>[
        'apps/pf_mobile/lib/main.dart',
        'apps/pf_mobile/.flutter_tool_state',
      ]);
      expect(report.ok, isFalse);
      expect(ruleIds(report), <String>{'tracked-local-state'});
      expect(report.findings.single.path, 'apps/pf_mobile/.flutter_tool_state');
      expect(report.findings.single.severity, Severity.error);
      expect(report.findings.single.hint, isNotNull, reason: '必须给出为什么禁止');
    });

    test('本机状态 / 构建输出 / 数据库 / 密钥 / 安装包 / 日志各归其规则', () {
      const cases = <String, String>{
        'apps/pf_mobile/.dart_tool/package_config.json': 'tracked-build-output',
        'build/app.dill': 'tracked-build-output',
        'data/ledger.db': 'tracked-database',
        'docs/architecture.pfb': 'tracked-vault-file',
        'android/app/upload-keystore.jks': 'tracked-secret-material',
        'dist/pf-wallet-release.apk': 'tracked-installer-artifact',
        'logs/integration.log': 'tracked-log-file',
      };

      for (final entry in cases.entries) {
        final report = run(<String>[entry.key]);
        expect(ruleIds(report), <String>{
          entry.value,
        }, reason: '${entry.key} 应当只命中 ${entry.value}\n${report.render()}');
        expect(report.ok, isFalse);
      }
    });

    test('deny 优先于 allow：白名单目录里的密钥文件也要拦（test_vectors 下不允许放容器）', () {
      final report = run(<String>['test_vectors/v1/leak.pfb']);
      expect(report.ok, isFalse);
      expect(ruleIds(report), <String>{'tracked-vault-file'});
    });

    test('一条路径只归属第一条命中的规则（build/app.db 不会被报两次）', () {
      final report = run(<String>['build/app.db']);
      expect(report.findings, hasLength(1));
      expect(report.findings.single.ruleId, 'tracked-build-output');
    });

    test('白名单外的路径 ⇒ tracked-unexpected（error）', () {
      final report = run(<String>['scripts/publish.sh']);
      expect(report.ok, isFalse);
      expect(ruleIds(report), <String>{'tracked-unexpected'});
      expect(report.findings.single.hint, contains('tracked_paths.yaml'));
    });

    test('大小写折叠后重名 ⇒ tracked-case-collision', () {
      final report = run(<String>['docs/Guide.md', 'docs/guide.md']);
      expect(report.ok, isFalse);
      expect(ruleIds(report), <String>{'tracked-case-collision'});
      expect(report.findings.single.message, contains('docs/Guide.md'));
      expect(report.findings.single.message, contains('docs/guide.md'));
    });

    test('互不冲突的多类问题会同时报出（不是遇到第一个就停）', () {
      final report = run(<String>[
        'README.md',
        'apps/pf_mobile/.flutter_tool_state',
        'data/ledger.db',
        'scripts/publish.sh',
      ]);
      expect(report.ok, isFalse);
      expect(ruleIds(report), <String>{
        'tracked-local-state',
        'tracked-database',
        'tracked-unexpected',
      });
      expect(report.metrics['trackedFiles'], 4);
      expect(report.metrics['deniedPaths'], 2);
      expect(report.metrics['unexpectedPaths'], 1);
      expect(report.metrics['allowedPaths'], 1);
    });

    test('命中条数被 maxFindingsPerRule 截断，但检查仍然失败（截断不等于放过）', () {
      final capped = TrackedPathRules(
        sourcePath: 'inline',
        deny: <TrackedPathRule>[
          TrackedPathRule(
            id: 'tracked-database',
            severity: Severity.error,
            patterns: PathMatcher(<String>['**/*.db']),
            rationale: '夹具',
          ),
        ],
        allow: PathMatcher(<String>['**']),
        unknownPathSeverity: Severity.error,
        caseCollisionSeverity: Severity.error,
        maxFindingsPerRule: 3,
      );

      final paths = List<String>.generate(25, (i) => 'data/table_$i.db');
      final report = run(paths, override: capped);

      expect(report.ok, isFalse);
      expect(report.errorCount, 4, reason: '3 条逐条 + 1 条汇总\n${report.render()}');
      expect(report.findings.last.message, contains('另有 22 条'));
    });

    test('unknownPathSeverity 可放宽为 warning —— 放宽是一次 YAML 改动，不是删检查', () {
      final relaxed = TrackedPathRules(
        sourcePath: 'inline',
        deny: rules.deny,
        allow: rules.allow,
        unknownPathSeverity: Severity.warning,
        caseCollisionSeverity: Severity.error,
        maxFindingsPerRule: rules.maxFindingsPerRule,
      );

      final report = run(<String>['scripts/publish.sh'], override: relaxed);
      expect(report.ok, isTrue, reason: 'warning 不阻塞');
      expect(ruleIds(report), <String>{'tracked-unexpected'});

      // 但硬禁止项不受该开关影响：它永远是 error。
      final stillRed = run(<String>['data/ledger.db'], override: relaxed);
      expect(stillRed.ok, isFalse);
    });
  });
}

/// 向上查找仓库根，返回真实规则目录的绝对路径。
String _realRulesDirectory() {
  var current = Directory.current.absolute;
  while (true) {
    if (File(p.join(current.path, 'melos.yaml')).existsSync()) {
      return p.join(current.path, 'tools', 'guards', 'rules');
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('未找到仓库根（从 ${Directory.current.path} 向上没有 melos.yaml）');
    }
    current = parent;
  }
}

/// 门禁脚本的集成测试：直接使用仓库里真实的规则文件，在临时目录上跑完整流水线。
///
/// 这样做的价值：
///   1. 规则 YAML 的语法与字段被真实覆盖 —— 规则写错会在这里就炸。
///   2. 不需要真的 pub get，测试可以离线、毫秒级完成。
///   3. 想加规则时，先加一条测试，再改 YAML。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pf_guards/checks/deps.dart';
import 'package:pf_guards/checks/manifest.dart';
import 'package:pf_guards/checks/source_checks.dart';
import 'package:pf_guards/model.dart';
import 'package:pf_guards/repo.dart';
import 'package:pf_guards/rules.dart';
import 'package:test/test.dart';

const List<String> _ruleFiles = <String>[
  'banned_api.yaml',
  'deps.yaml',
  'deps_allowlist.yaml',
  'logging.yaml',
  'manifest.yaml',
];

/// 固定时间，保证与真实日期无关（allowlist 的 reviewBy 默认是 2027-03-15）。
final DateTime _now = DateTime.utc(2026, 9, 15);

void main() {
  late Directory temp;
  late Repo repo;
  late RuleSet ruleSet;

  void write(String relativePosix, String content) {
    final file = File(p.joinAll(<String>[temp.path, ...relativePosix.split('/')]));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  void writeRootPubspec(String workspaceEntry) {
    write(
      'pubspec.yaml',
      'name: fixture_root\n'
          'publish_to: none\n'
          'environment:\n'
          '  sdk: ^3.7.0\n'
          'workspace:\n'
          '  - $workspaceEntry\n',
    );
  }

  void writeMember(String directory, String dependencies) {
    write(
      '$directory/pubspec.yaml',
      'name: ${p.basename(directory)}\n'
          'publish_to: none\n'
          'resolution: workspace\n'
          'version: 0.1.0\n'
          'environment:\n'
          '  sdk: ^3.7.0\n'
          '$dependencies',
    );
  }

  /// 用一份「什么都没登记」的登记表覆盖夹具。
  ///
  /// 「review 分类未登记 → 失败」这条路必须由夹具自己保证前提：
  /// 若依赖真实 `rules/deps_allowlist.yaml` 里「恰好缺某个包」，
  /// 那么每次给真实登记表补条目，这个用例就会悄悄滑向「已登记 → 通过」，
  /// 覆盖在无人察觉的情况下丢失（本项目已经真实发生过一次）。
  void writeEmptyAllowlist() {
    write('tools/guards/rules/deps_allowlist.yaml', 'version: 1\nentries: []\n');
  }

  void writeLock(Map<String, Map<String, Object?>> packages) {
    final buffer = StringBuffer('packages:\n');
    packages.forEach((name, attributes) {
      buffer.writeln('  $name:');
      buffer.writeln('    dependency: ${attributes['dependency'] ?? 'transitive'}');
      buffer.writeln('    description:');
      buffer.writeln('      name: $name');
      buffer.writeln('      url: "${attributes['url'] ?? 'https://pub.dev'}"');
      buffer.writeln('    source: ${attributes['source'] ?? 'hosted'}');
      buffer.writeln('    version: "${attributes['version'] ?? '1.0.0'}"');
    });
    buffer.writeln('sdks:');
    buffer.writeln('  dart: ">=3.7.0 <4.0.0"');
    write('pubspec.lock', buffer.toString());
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('pf_guards_it_');
    final rulesDirectory = Directory(p.join(temp.path, 'tools', 'guards', 'rules'))
      ..createSync(recursive: true);
    for (final name in _ruleFiles) {
      File(p.join(_realRulesDirectory(), name)).copySync(p.join(rulesDirectory.path, name));
    }
    File(p.join(temp.path, 'melos.yaml')).writeAsStringSync('name: fixture\n');
    repo = Repo(temp.path);
    ruleSet = RuleSet(repo: repo);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('规则文件本身', () {
    test('全部规则文件可解析且字段完整', () {
      expect(() => ruleSet.loadDepRules(), returnsNormally);
      expect(() => ruleSet.loadDepAllowlist(), returnsNormally);
      expect(() => ruleSet.loadBannedApiRules(), returnsNormally);
      expect(() => ruleSet.loadLoggingRules(), returnsNormally);
      expect(() => ruleSet.loadManifestRules(), returnsNormally);
    });

    test('依赖黑名单覆盖了常见遥测与后端 SDK', () {
      final rules = ruleSet.loadDepRules();
      for (final name in <String>[
        'sentry_flutter',
        'firebase_analytics',
        'amplitude_flutter',
        'google_analytics',
        'in_app_purchase',
        'connectivity_plus',
      ]) {
        expect(rules.denyReason(name), isNotNull, reason: '$name 应当被硬拒绝');
      }
    });

    test('前缀规则能拦住未逐一列举的同族包', () {
      final rules = ruleSet.loadDepRules();
      expect(rules.denyReason('firebase_something_new'), isNotNull);
      expect(rules.denyReason('sentry_flutter_extra'), isNotNull);
      expect(rules.denyReason('google_fonts'), isNotNull, reason: 'google_fonts 会联网下载字体');
    });

    test('正常依赖不会被误判', () {
      final rules = ruleSet.loadDepRules();
      for (final name in <String>[
        'collection',
        'meta',
        'crypto',
        'flutter_riverpod',
        'sqflite_sqlcipher',
        'argon2',
      ]) {
        expect(rules.denyReason(name), isNull, reason: '$name 不应当被拒绝');
      }
    });
  });

  group('deps 检查', () {
    test('传递依赖里的遥测 SDK 也会被拦下', () {
      writeRootPubspec('packages/pf_core');
      writeMember('packages/pf_core', 'dependencies:\n  collection: ^1.19.0\n');
      writeLock(<String, Map<String, Object?>>{
        'collection': <String, Object?>{'dependency': 'direct main'},
        'sentry_flutter': <String, Object?>{'dependency': 'transitive'},
      });

      final report = runDepsCheck(
        repo: repo,
        rules: ruleSet.loadDepRules(),
        allowlist: ruleSet.loadDepAllowlist(),
        now: _now,
      );

      expect(report.ok, isFalse);
      expect(
        report.findings.where(
          (f) => f.ruleId == 'dep-denied' && f.message.contains('sentry_flutter'),
        ),
        hasLength(1),
      );
    });

    test('review 分类未登记 → 失败', () {
      writeEmptyAllowlist();
      writeRootPubspec('packages/pf_core');
      writeMember('packages/pf_core', '');
      // 从真实 deps.yaml 里取出一个 review 分类的包名，
      // 这样 review 列表增删条目时用例不会失效。
      final reviewPackage = ruleSet.loadDepRules().reviewPackages.first;
      writeLock(<String, Map<String, Object?>>{
        reviewPackage: <String, Object?>{'dependency': 'direct main'},
      });

      final report = runDepsCheck(
        repo: repo,
        rules: ruleSet.loadDepRules(),
        allowlist: ruleSet.loadDepAllowlist(),
        now: _now,
      );

      expect(report.ok, isFalse);
      expect(report.findings.where((f) => f.ruleId == 'dep-review-missing'), hasLength(1));
    });

    test('review 分类已登记且在有效期内 → 通过', () {
      writeRootPubspec('packages/pf_core');
      writeMember('packages/pf_core', 'dependencies:\n  path_provider: ^2.1.0\n');
      writeLock(<String, Map<String, Object?>>{
        'path_provider': <String, Object?>{'dependency': 'direct main'},
      });

      final report = runDepsCheck(
        repo: repo,
        rules: ruleSet.loadDepRules(),
        allowlist: ruleSet.loadDepAllowlist(),
        now: _now,
      );

      expect(report.errorCount, 0, reason: report.render());
    });

    test('登记条目过期 → 失败', () {
      writeRootPubspec('packages/pf_core');
      writeMember('packages/pf_core', 'dependencies:\n  path_provider: ^2.1.0\n');
      writeLock(<String, Map<String, Object?>>{
        'path_provider': <String, Object?>{'dependency': 'direct main'},
      });

      final report = runDepsCheck(
        repo: repo,
        rules: ruleSet.loadDepRules(),
        allowlist: ruleSet.loadDepAllowlist(),
        now: DateTime.utc(2030, 1, 1),
      );

      expect(report.ok, isFalse);
      expect(report.findings.where((f) => f.ruleId == 'dep-review-expired'), hasLength(1));
    });

    test('git 来源在 shipping 范围内被拒绝', () {
      writeRootPubspec('packages/pf_core');
      writeMember(
        'packages/pf_core',
        'dependencies:\n'
            '  sketchy_pkg:\n'
            '    git:\n'
            '      url: https://example.com/sketchy.git\n',
      );
      writeLock(<String, Map<String, Object?>>{
        'sketchy_pkg': <String, Object?>{'dependency': 'direct main', 'source': 'git'},
      });

      final report = runDepsCheck(
        repo: repo,
        rules: ruleSet.loadDepRules(),
        allowlist: ruleSet.loadDepAllowlist(),
        now: _now,
      );

      expect(report.ok, isFalse);
      expect(report.findings.where((f) => f.ruleId == 'dep-source-banned'), hasLength(1));
    });

    test('非白名单 pub 镜像被拒绝', () {
      writeRootPubspec('packages/pf_core');
      writeMember(
        'packages/pf_core',
        'dependencies:\n'
            '  some_pkg:\n'
            '    hosted:\n'
            '      url: https://mirror.example.com\n'
            '    version: ^1.0.0\n',
      );
      writeLock(<String, Map<String, Object?>>{
        'some_pkg': <String, Object?>{
          'dependency': 'direct main',
          'url': 'https://mirror.example.com',
        },
      });

      final report = runDepsCheck(
        repo: repo,
        rules: ruleSet.loadDepRules(),
        allowlist: ruleSet.loadDepAllowlist(),
        now: _now,
      );

      expect(report.ok, isFalse);
      expect(report.findings.where((f) => f.ruleId == 'dep-source-host'), hasLength(1));
    });

    test('缺少 pubspec.lock 时抛 GuardException（退出码 2，而非检查失败）', () {
      writeRootPubspec('packages/pf_core');
      writeMember('packages/pf_core', '');
      expect(
        () => runDepsCheck(
          repo: repo,
          rules: ruleSet.loadDepRules(),
          allowlist: ruleSet.loadDepAllowlist(),
          now: _now,
        ),
        throwsA(isA<GuardException>()),
      );
    });

    test('工作区成员缺少 resolution: workspace → 抛 GuardException', () {
      writeRootPubspec('packages/pf_core');
      write(
        'packages/pf_core/pubspec.yaml',
        'name: pf_core\npublish_to: none\nenvironment:\n  sdk: ^3.7.0\n',
      );
      expect(
        () => runDepsCheck(
          repo: repo,
          rules: ruleSet.loadDepRules(),
          allowlist: ruleSet.loadDepAllowlist(),
          now: _now,
        ),
        throwsA(isA<GuardException>()),
      );
    });
  });

  group('logging 检查', () {
    test('shipping 内直接使用 print → 失败', () {
      write('packages/pf_x/lib/bad.dart', "void f() {\n  print('hello');\n}\n");
      final report = runLoggingCheck(repo: repo, rules: ruleSet.loadLoggingRules());
      expect(report.ok, isFalse);
      expect(report.findings.where((f) => f.ruleId == 'log-direct-sink'), hasLength(1));
    });

    test('工具目录内的 print 被放行（exempt 生效）', () {
      write('tools/scratch/debug.dart', "void f() {\n  print('hello');\n}\n");
      final report = runLoggingCheck(repo: repo, rules: ruleSet.loadLoggingRules());
      expect(report.errorCount, 0, reason: report.render());
    });

    test('密钥出现在字符串插值中 → 失败', () {
      write('packages/pf_x/lib/bad.dart', "final s = 'db=\$dbKey';\n");
      final report = runLoggingCheck(repo: repo, rules: ruleSet.loadLoggingRules());
      expect(report.ok, isFalse);
      expect(report.findings.where((f) => f.ruleId == 'log-secret-interpolation'), hasLength(1));
    });

    test('密钥出现在日志调用实参中 → 失败', () {
      write(
        'packages/pf_x/lib/bad.dart',
        'void f(String masterPassword) {\n  logger.error(masterPassword);\n}\n',
      );
      final report = runLoggingCheck(repo: repo, rules: ruleSet.loadLoggingRules());
      expect(report.ok, isFalse);
      expect(report.findings.where((f) => f.ruleId == 'log-secret-in-call'), isNotEmpty);
    });

    test('guards:ignore 抑制生效', () {
      write(
        'packages/pf_x/lib/bad.dart',
        'void f() {\n'
            '  // guards:ignore log-direct-sink —— 这是本文件唯一的调试输出，M1 删除\n'
            "  print('hello');\n"
            '}\n',
      );
      final report = runLoggingCheck(repo: repo, rules: ruleSet.loadLoggingRules());
      expect(report.errorCount, 0, reason: report.render());
    });

    test('业务字段只产生 info，不阻塞 CI', () {
      write(
        'packages/pf_x/lib/bad.dart',
        "void f(num amount) {\n  logger.info('total=\$amount');\n}\n",
      );
      final report = runLoggingCheck(repo: repo, rules: ruleSet.loadLoggingRules());
      expect(report.ok, isTrue, reason: report.render());
      expect(report.findings.where((f) => f.ruleId == 'log-business-data'), isNotEmpty);
    });
  });

  group('banned-api 检查', () {
    test('dart:mirrors 被拦截', () {
      write('packages/pf_x/lib/bad.dart', "import 'dart:mirrors';\n\nvoid f() {}\n");
      final report = runBannedApiCheck(repo: repo, rules: ruleSet.loadBannedApiRules());
      expect(report.ok, isFalse);
      expect(report.findings.where((f) => f.ruleId == 'no-dynamic-execution'), hasLength(1));
    });

    test('字符串里提到 dart:mirrors 不误报（逐字符匹配的必要性）', () {
      write(
        'packages/pf_x/lib/ok.dart',
        "const note = 'we never use dart:mirrors in this project';\n",
      );
      final report = runBannedApiCheck(repo: repo, rules: ruleSet.loadBannedApiRules());
      // 该模式按 URI 形态匹配，注释与普通字符串都不会命中
      expect(report.findings.where((f) => f.ruleId == 'no-dynamic-execution'), isEmpty);
    });

    test('加密层使用 math.Random() 被拦截', () {
      write(
        'packages/pf_crypto/lib/bad.dart',
        'import "dart:math";\n\nint f() => Random().nextInt(256);\n',
      );
      final report = runBannedApiCheck(repo: repo, rules: ruleSet.loadBannedApiRules());
      expect(report.ok, isFalse);
      expect(report.findings.where((f) => f.ruleId == 'no-insecure-random-in-crypto'), isNotEmpty);
    });

    test('加密层使用 Random.secure() 被放行', () {
      write(
        'packages/pf_crypto/lib/ok.dart',
        'import "dart:math";\n\nint f() => Random.secure().nextInt(256);\n',
      );
      final report = runBannedApiCheck(repo: repo, rules: ruleSet.loadBannedApiRules());
      expect(report.errorCount, 0, reason: report.render());
    });

    test('加密层使用 SHA-1 被拦截', () {
      write('packages/pf_crypto/lib/bad.dart', 'void f() {\n  final x = sha1.convert([]);\n}\n');
      final report = runBannedApiCheck(repo: repo, rules: ruleSet.loadBannedApiRules());
      expect(report.ok, isFalse);
      expect(report.findings.where((f) => f.ruleId == 'no-weak-hash-in-crypto'), isNotEmpty);
    });

    test('加密层使用 ListEquality 比对被拦截（计时侧信道）', () {
      write(
        'packages/pf_crypto/lib/bad.dart',
        'void f(List<int> a, List<int> b) {\n  final same = ListEquality().equals(a, b);\n}\n',
      );
      final report = runBannedApiCheck(repo: repo, rules: ruleSet.loadBannedApiRules());
      expect(report.ok, isFalse);
      expect(report.findings.where((f) => f.ruleId == 'no-non-constant-time-compare'), isNotEmpty);
    });
  });

  group('manifest 检查', () {
    test('平台目录未生成时按容忍级别报告（不阻塞 M0）', () {
      final report = runManifestCheck(repo: repo, rules: ruleSet.loadManifestRules());
      expect(report.ok, isTrue, reason: report.render());
      expect(report.findings.where((f) => f.ruleId == 'manifest-android-missing'), hasLength(1));
      expect(report.findings.where((f) => f.ruleId == 'manifest-ios-missing'), hasLength(1));
    });

    test('开启了 allowBackup 的 manifest 会被拦下', () {
      write(
        'apps/pf_mobile/android/app/src/main/AndroidManifest.xml',
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '  <uses-permission android:name="android.permission.INTERNET" />\n'
            '  <application android:label="x" android:allowBackup="true">\n'
            '  </application>\n'
            '</manifest>\n',
      );

      final report = runManifestCheck(repo: repo, rules: ruleSet.loadManifestRules());
      final ruleIds = report.findings.map((f) => f.ruleId).toSet();
      expect(ruleIds, contains('manifest-android-permission'));
      expect(ruleIds, contains('manifest-android-attr-value'));
      expect(report.ok, isFalse);
    });

    test('配置正确的 manifest 通过', () {
      write(
        'apps/pf_mobile/android/app/src/main/AndroidManifest.xml',
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '  <application\n'
            '      android:label="PF Wallet"\n'
            '      android:allowBackup="false"\n'
            '      android:fullBackupContent="@xml/backup_rules"\n'
            '      android:dataExtractionRules="@xml/data_extraction_rules">\n'
            '  </application>\n'
            '</manifest>\n',
      );
      write(
        'apps/pf_mobile/android/app/src/main/res/xml/backup_rules.xml',
        '<full-backup-content />\n',
      );
      write(
        'apps/pf_mobile/android/app/src/main/res/xml/data_extraction_rules.xml',
        '<data-extraction-rules />\n',
      );

      final report = runManifestCheck(repo: repo, rules: ruleSet.loadManifestRules());
      final androidFindings = report.findings.where((f) => f.ruleId.startsWith('manifest-android'));
      expect(androidFindings, isEmpty, reason: report.render());
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

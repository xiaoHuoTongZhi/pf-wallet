/// 版本一致性检查。
///
/// ## 为什么这是门禁而不是文档里的「记得同步」
///
/// 应用版本号在两个地方以两种形式存在：
///   - `packages/pf_core/lib/src/version.dart` 的 `PfBuildInfo.appVersion`
///      —— 代码里读得到的那个（设置页、报错日志、导出文件命名）
///   - `apps/pf_mobile/pubspec.yaml` 的 `version`
///      —— 打包系统读的那个（商店列表、崩溃报告、安装包元数据）
///
/// 它们不一致时不会有任何编译错误、不会有任何测试失败，
/// 唯一的症状是：用户报障时给出的版本号是错的，于是排查方向从头就偏了。
/// 而且这个偏差会一直累积 —— 每次只差一个小版本，没人会注意到。
///
/// 因此这里把它变成一条硬约束：不一致即 error。
/// 刻意**不提供关闭开关**：一个「可以关掉的版本一致性检查」
/// 等价于一个迟早会被关掉的检查。
///
/// ## 同时检查「全仓一个版本」
///
/// 本项目所有 workspace 成员一起发布、互相之间用 `^` 约束。
/// 若某个包的版本单独跑到 0.2.0，而依赖它的包写着 `^0.1.0`，
/// 工作区解析（`resolution: workspace`）会照常成功 ——
/// 因为成员间走的是本地路径。等到某天想把某个包拆出去发布时，
/// 这个不一致才会以「依赖解析失败」的形式炸出来，而那时已经很难回溯是谁改的。
library;

import 'package:yaml/yaml.dart';

import '../model.dart';
import '../repo.dart';

/// `version.dart` 的相对路径。
const String versionSourcePath = 'packages/pf_core/lib/src/version.dart';

/// 需要检查版本一致性的 pubspec（应用 + 全部库包）。
///
/// 工具包（`tools/**`）刻意排除：它们不发布、不参与版本号，
/// 强行要求同步只会制造无意义的改动。
const List<String> versionedPubspecs = <String>[
  'apps/pf_mobile/pubspec.yaml',
  'packages/pf_core/pubspec.yaml',
  'packages/pf_crypto/pubspec.yaml',
  'packages/pf_data/pubspec.yaml',
  'packages/pf_io/pubspec.yaml',
  'packages/pf_testkit/pubspec.yaml',
  'packages/pf_ui/pubspec.yaml',
];

/// 运行版本一致性检查。
GuardReport runVersionCheck({required Repo repo}) {
  final report = GuardReport(check: 'version', ruleFiles: const <String>[]);

  final source = repo.tryReadFile(versionSourcePath);
  if (source == null) {
    throw GuardException(
      '找不到 $versionSourcePath',
      hint: '版本一致性检查依赖该文件；若它被移动，请同步更新 checks/version.dart',
    );
  }

  final appVersion = _extractString(source, 'appVersion');
  if (appVersion == null) {
    throw GuardException(
      '$versionSourcePath 中未能解析出 PfBuildInfo.appVersion',
      hint: '期望形如：static const String appVersion = \'0.1.0\';',
    );
  }

  report
    ..metric('appVersion', appVersion)
    ..metric('schemaVersion', _extractInt(source, 'schemaVersion'))
    ..metric('containerFormatVersion', _extractInt(source, 'containerFormatVersion'))
    ..metric('containerFormatMinorVersion', _extractInt(source, 'containerFormatMinorVersion'))
    ..metric('payloadSchemaVersion', _extractInt(source, 'payloadSchemaVersion'));

  final declarations = <String, String>{};

  for (final path in versionedPubspecs) {
    final raw = repo.tryReadFile(path);
    if (raw == null) {
      report.add(
        Finding(
          ruleId: 'version-missing-pubspec',
          severity: Severity.error,
          message: '登记在册的包缺少 pubspec：$path',
          path: path,
          hint: '要么补回该文件，要么把它从 versionedPubspecs 中移除',
        ),
      );
      continue;
    }

    final declared = _pubspecVersion(raw);
    if (declared == null) {
      report.add(
        Finding(
          ruleId: 'version-missing-field',
          severity: Severity.error,
          message: 'pubspec 缺少 version 字段',
          path: path,
          hint:
              '工作区成员必须声明 version —— '
              '否则发布时会被兜底成 0.0.0，而那时往往已经来不及改',
        ),
      );
      continue;
    }

    declarations[path] = declared;

    if (declared != appVersion) {
      report.add(
        Finding(
          ruleId: 'version-mismatch',
          severity: Severity.error,
          message:
              '版本不一致：pubspec 为 $declared，'
              '而 PfBuildInfo.appVersion 为 $appVersion',
          path: path,
          hint:
              '两处必须一致。改哪一处都可以，但必须一起改 —— '
              '不一致时编译器与测试都不会报错，'
              '只有用户报障时的版本号会错。',
        ),
      );
    }
  }

  report.metric('declaredVersions', declarations);

  // 构建号（`1.2.3+45`）刻意不参与比较：它由打包流程递增，
  // 与应用语义版本是两件事。这里只校验语义版本部分。
  if (declarations.length == versionedPubspecs.length && declarations.values.toSet().length == 1) {
    report.metric('consistent', true);
  } else {
    report.metric('consistent', false);
  }

  return report;
}

/// 从 `version.dart` 提取 `static const String <name> = '...';`
String? _extractString(String source, String name) {
  final pattern = RegExp('static\\s+const\\s+String\\s+$name\\s*=\\s*([\'"])([^\'"]*)\\1');
  return pattern.firstMatch(source)?.group(2);
}

/// 从 `version.dart` 提取 `static const int <name> = <digits>;`
int? _extractInt(String source, String name) {
  final pattern = RegExp('static\\s+const\\s+int\\s+$name\\s*=\\s*(\\d+)');
  final matched = pattern.firstMatch(source)?.group(1);
  return matched == null ? null : int.tryParse(matched);
}

/// 读取 pubspec 的 `version`，去掉构建号。
String? _pubspecVersion(String raw) {
  final Object? parsed = loadYaml(raw);
  if (parsed is! YamlMap) {
    throw GuardException('pubspec 不是合法的 YAML 映射');
  }
  final Object? version = parsed['version'];
  if (version is! String) return null;
  final plus = version.indexOf('+');
  final semver = plus == -1 ? version : version.substring(0, plus);
  return semver.trim();
}

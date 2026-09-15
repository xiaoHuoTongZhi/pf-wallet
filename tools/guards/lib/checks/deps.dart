/// 依赖黑名单检查（deps）。
///
/// 判定顺序：
///   1. 硬拒绝：pubspec.lock 中**每一个**包（含传递依赖）依次过 deny 规则。
///   2. 需登记：命中 review 列表的包必须在 deps_allowlist.yaml 中有未过期的条目。
///   3. 来源审计：shipping 范围内直接声明的依赖，来源必须干净（禁 git / path / 非白名单主机）。
///   4. 卫生检查：未使用的登记条目、过短的理由、缺复核日期 → warning。
///
/// 为什么扫 lock 而不是只扫 pubspec：
///   遥测 SDK 最常见的进入方式是「某个依赖顺手带进来的」。
///   只查直接依赖等于给自己留后门。
library;

import 'package:path/path.dart' as p;

import '../model.dart';
import '../repo.dart';
import '../rules.dart';
import '../yaml_util.dart';

/// 工作区成员（含根 pubspec）。
final class WorkspaceMember {
  const WorkspaceMember({
    required this.relativePath,
    required this.name,
    required this.dependencies,
    required this.devDependencies,
    required this.dependencyOverrides,
  });

  /// 相对仓库根的 POSIX 路径；根为 `.`。
  final String relativePath;
  final String name;
  final Map<String, Object?> dependencies;
  final Map<String, Object?> devDependencies;
  final Map<String, Object?> dependencyOverrides;

  /// 是否有任何交付到用户设备的依赖。
  bool get isShippingCandidate => dependencies.isNotEmpty || devDependencies.isNotEmpty;

  /// 所有直接声明的依赖（主依赖 + 开发依赖 + 覆盖）。
  /// 记录为 (包名, 声明值, 所在字段名)。
  List<(String, Object?, String)> allDeclared() {
    final result = <(String, Object?, String)>[];
    dependencies.forEach((k, v) => result.add((k, v, 'dependencies')));
    devDependencies.forEach((k, v) => result.add((k, v, 'dev_dependencies')));
    dependencyOverrides.forEach((k, v) => result.add((k, v, 'dependency_overrides')));
    return result;
  }
}

/// `pubspec.lock` 中的一条解析结果。
final class LockedPackage {
  const LockedPackage({required this.name, this.version, this.kind, this.source, this.host});

  final String name;
  final String? version;

  /// `direct main` / `direct dev` / `transitive`。
  final String? kind;

  /// `hosted` / `git` / `path` / `sdk`。
  final String? source;

  /// hosted 来源的主机名。
  final String? host;
}

/// 依赖来源描述。
typedef DependencySource = ({String source, String? host, String? detail});

/// 解析单个依赖声明（String 简写 或 Map 完整写法）的来源。
DependencySource describeDependencySource(Object? spec) {
  if (spec == null) {
    return (source: 'unknown', host: null, detail: '依赖声明为空');
  }
  if (spec is String) {
    return (source: 'hosted', host: 'pub.dev', detail: spec);
  }
  if (spec is! Map) {
    return (source: 'unknown', host: null, detail: '无法识别的依赖声明类型 ${spec.runtimeType}');
  }
  final map = spec.cast<String, Object?>();
  if (map.containsKey('git')) {
    return (source: 'git', host: null, detail: 'git 依赖');
  }
  if (map.containsKey('path')) {
    return (source: 'path', host: null, detail: '${map['path']}');
  }
  if (map.containsKey('sdk')) {
    return (source: 'sdk', host: null, detail: '${map['sdk']}');
  }
  final hosted = map['hosted'];
  if (hosted is String) {
    return (source: 'hosted', host: hosted, detail: hosted);
  }
  if (hosted is Map) {
    final url = hosted['url'];
    if (url is String) {
      final host = Uri.tryParse(url)?.host;
      return (source: 'hosted', host: host ?? url, detail: url);
    }
    return (source: 'hosted', host: 'pub.dev', detail: 'hosted 但未声明 url');
  }
  if (map.containsKey('version')) {
    return (source: 'hosted', host: 'pub.dev', detail: '${map['version']}');
  }
  return (source: 'unknown', host: null, detail: '未知的依赖声明形式');
}

/// 读取根 pubspec 的 `workspace:` 列表并载入各成员 pubspec。
List<WorkspaceMember> loadWorkspaceMembers(Repo repo) {
  const rootPath = 'pubspec.yaml';
  final root = repo.loadYamlMap(rootPath);
  final members = <WorkspaceMember>[
    WorkspaceMember(
      relativePath: '.',
      name: optionalString(root, 'name', path: rootPath) ?? '<root>',
      dependencies: optionalMap(root, 'dependencies', path: rootPath) ?? const <String, Object?>{},
      devDependencies:
          optionalMap(root, 'dev_dependencies', path: rootPath) ?? const <String, Object?>{},
      dependencyOverrides:
          optionalMap(root, 'dependency_overrides', path: rootPath) ?? const <String, Object?>{},
    ),
  ];

  final workspace = stringList(root, 'workspace', path: rootPath);
  if (workspace.isEmpty) {
    throw GuardException(
      '根 pubspec.yaml 未声明 workspace 字段',
      hint: '本仓依赖 pub workspaces 保证全仓单一依赖解析，见 dart.dev/tools/pub/workspaces',
    );
  }

  for (final entry in workspace) {
    if (entry.contains('*')) {
      throw GuardException(
        'workspace 条目 "$entry" 使用了 glob',
        hint: 'glob 需要 Dart 3.11+；当前仓库约束为 ^3.7.0，请使用显式路径',
      );
    }
    final pubspecPath = '$entry/pubspec.yaml';
    final json =
        repo.tryReadFile(pubspecPath) == null
            ? throw GuardException('workspace 成员缺少 pubspec.yaml: $entry')
            : repo.loadYamlMap(pubspecPath);
    if (optionalString(json, 'resolution', path: pubspecPath) != 'workspace') {
      throw GuardException(
        '$pubspecPath 缺少 `resolution: workspace`',
        hint: '工作区成员必须声明该字段，否则 pub 无法把它纳入统一解析',
      );
    }
    members.add(
      WorkspaceMember(
        relativePath: entry,
        name: optionalString(json, 'name', path: pubspecPath) ?? p.basename(entry),
        dependencies:
            optionalMap(json, 'dependencies', path: pubspecPath) ?? const <String, Object?>{},
        devDependencies:
            optionalMap(json, 'dev_dependencies', path: pubspecPath) ?? const <String, Object?>{},
        dependencyOverrides:
            optionalMap(json, 'dependency_overrides', path: pubspecPath) ??
            const <String, Object?>{},
      ),
    );
  }
  return members;
}

/// 解析根 `pubspec.lock`。
Map<String, LockedPackage> loadLockedPackages(Repo repo) {
  if (repo.tryReadFile('pubspec.lock') == null) {
    throw GuardException(
      'pubspec.lock 不存在，无法审计传递依赖',
      hint: '先在仓库根执行 `flutter pub get`（含 Flutter 成员，不能用 dart pub get）',
    );
  }
  final json = repo.loadYamlMap('pubspec.lock');
  final packages = json['packages'];
  if (packages is! Map) {
    throw GuardException('pubspec.lock 缺少 packages 段');
  }
  final result = <String, LockedPackage>{};
  packages.forEach((key, value) {
    if (key is! String || value is! Map) return;
    final map = value.cast<String, Object?>();
    final description = map['description'];
    String? host;
    if (description is Map) {
      final url = description['url'];
      host = url is String ? Uri.tryParse(url)?.host : null;
    }
    // 先取到局部变量再判类型：写成 `map['x'] is String ? map['x'] as String : null`
    // 会被 cast_nullable_to_non_nullable 拦下，而且重复索引本身也更易出错。
    final version = map['version'];
    final kind = map['dependency'];
    final source = map['source'];
    result[key] = LockedPackage(
      name: key,
      version: version is String ? version : null,
      kind: kind is String ? kind : null,
      source: source is String ? source : null,
      host: host,
    );
  });
  return result;
}

/// 执行依赖黑名单检查。
GuardReport runDepsCheck({
  required Repo repo,
  required DepRules rules,
  required DepAllowlist allowlist,
  DateTime? now,
}) {
  final report = GuardReport(
    check: 'deps',
    ruleFiles: <String>[rules.sourcePath, allowlist.sourcePath],
  );
  final currentTime = (now ?? DateTime.now()).toUtc();

  final members = loadWorkspaceMembers(repo);
  final shippingMembers = members.where((m) => rules.scope.ships(m.relativePath)).toList();
  final locked = loadLockedPackages(repo);

  report.metric('workspaceMembers', members.length);
  report.metric('shippingMembers', shippingMembers.map((m) => m.name).join(', '));
  report.metric('resolvedPackages', locked.length);

  // ---- 1. 硬拒绝：覆盖 lock 中的全部包（含传递依赖） ----
  var deniedFromLock = 0;
  final deniedNames = <String>{};
  for (final pkg in locked.values) {
    final reason = rules.denyReason(pkg.name);
    if (reason == null) continue;
    deniedFromLock++;
    deniedNames.add(pkg.name);
    report.add(
      Finding(
        ruleId: 'dep-denied',
        severity: Severity.error,
        message:
            '解析结果中出现被禁止的依赖 "${pkg.name}"'
            '（${pkg.version ?? '?'}，来源=${pkg.source ?? '?'}，类型=${pkg.kind ?? '?'}）：$reason',
        path: 'pubspec.lock',
        hint:
            '遥测 / 广告 / 归因 / 云端后端类依赖一律禁止，传递依赖同样适用。'
            '若确属误判，修改 ${rules.sourcePath} 的 deny 段并说明理由。',
      ),
    );
  }

  // ---- 1b. 硬拒绝：shipping 成员直接声明但尚未 get 的依赖 ----
  var deniedFromPubspec = 0;
  for (final member in shippingMembers) {
    // 用通配符跳过版本约束：这一轮只关心「名字是否在拒绝名单里」，
    // 约束本身由后续的 review 与 allowlist 逻辑处理。
    for (final (name, _, section) in member.allDeclared()) {
      if (deniedNames.contains(name)) continue;
      final reason = rules.denyReason(name);
      if (reason == null) continue;
      deniedFromPubspec++;
      deniedNames.add(name);
      report.add(
        Finding(
          ruleId: 'dep-denied',
          severity: Severity.error,
          message: '${member.name} 的 $section 声明了被禁止的依赖 "$name"：$reason',
          path: '${member.relativePath == '.' ? '' : '${member.relativePath}/'}pubspec.yaml',
          hint: '删除该依赖。若该成员尚未 pub get，此告警会先于 lock 扫描出现。',
        ),
      );
    }
  }

  report.metric('deniedHits', deniedFromLock + deniedFromPubspec);

  // ---- 2. 需登记：review 列表 ----
  var reviewHits = 0;
  var missingAllowlist = 0;
  final usedEntries = <String>{};
  for (final pkg in locked.values) {
    if (!rules.needsReview(pkg.name)) continue;
    reviewHits++;
    final entry = allowlist.entryFor(pkg.name);
    if (entry == null) {
      missingAllowlist++;
      report.add(
        Finding(
          ruleId: 'dep-review-missing',
          severity: Severity.error,
          message:
              '"${pkg.name}"（${pkg.version ?? '?'}，${pkg.kind ?? '?'}）属于 review 分类，'
              '但 ${allowlist.sourcePath} 中没有登记条目。',
          path: 'pubspec.lock',
          hint:
              '在 ${allowlist.sourcePath} 中添加条目，必须写明 justification / dataFlow / '
              'owner / reviewBy 四项。',
        ),
      );
      continue;
    }
    usedEntries.add(pkg.name);
    if (entry.reviewBy == null) {
      report.add(
        Finding(
          ruleId: 'dep-review-no-deadline',
          severity: Severity.warning,
          message: '"${pkg.name}" 的登记条目未设置 reviewBy，等于永久豁免。',
          path: allowlist.sourcePath,
          hint: '补一个 6 个月内的复核日期。永久豁免在实践中等同于从未评估。',
        ),
      );
    } else if (entry.expiredAt(currentTime)) {
      report.add(
        Finding(
          ruleId: 'dep-review-expired',
          severity: Severity.error,
          message:
              '"${pkg.name}" 的登记条目已于 ${entry.reviewBy!.toIso8601String().substring(0, 10)} '
              '到期，必须重新评估。',
          path: allowlist.sourcePath,
          hint: '重新确认该依赖是否仍不可替代、数据流是否变化，然后更新 reviewBy。',
        ),
      );
    }
    if (entry.justification.trim().length < 20) {
      report.add(
        Finding(
          ruleId: 'dep-review-weak-justification',
          severity: Severity.warning,
          message: '"${pkg.name}" 的 justification 过短（< 20 字），无法支撑评审。',
          path: allowlist.sourcePath,
          hint: '写清「为什么非它不可」以及「替代方案为何不行」。',
        ),
      );
    }
    if ((entry.dataFlow ?? '').trim().isEmpty) {
      report.add(
        Finding(
          ruleId: 'dep-review-no-dataflow',
          severity: Severity.warning,
          message: '"${pkg.name}" 的登记条目缺少 dataFlow。',
          path: allowlist.sourcePath,
          hint: '写明它可能接触到的数据，以及数据会去哪里。',
        ),
      );
    }
  }
  report.metric('reviewHits', reviewHits);
  report.metric('reviewMissingAllowlist', missingAllowlist);
  report.metric('allowlistEntries', allowlist.byPackage.length);

  for (final entry in allowlist.byPackage.values) {
    if (usedEntries.contains(entry.package)) continue;
    report.add(
      Finding(
        ruleId: 'dep-allowlist-stale',
        severity: Severity.warning,
        message: '"${entry.package}" 的登记条目未被任何已解析依赖命中（可能是历史遗留或提前登记）。',
        path: allowlist.sourcePath,
        hint: '若是有意留存的「已评估并拒绝」记录，可保留；否则删除以保持登记表可信。',
      ),
    );
  }

  // ---- 3. 来源审计 ----
  var sourceIssues = 0;
  for (final member in shippingMembers) {
    for (final (name, spec, section) in member.allDeclared()) {
      final source = describeDependencySource(spec);
      final pubspecPath =
          '${member.relativePath == '.' ? '' : '${member.relativePath}/'}pubspec.yaml';

      if (rules.bannedSources.contains(source.source)) {
        sourceIssues++;
        report.add(
          Finding(
            ruleId: 'dep-source-banned',
            severity: Severity.error,
            message:
                '${member.name} / $section 中的 "$name" 使用了 ${source.source} 来源'
                '（${source.detail ?? '—'}），该来源被禁止。',
            path: pubspecPath,
            hint:
                '原因：git/path 依赖无法做发布时的完整性校验，且会在解析期执行构建逻辑。'
                '改为 pub.dev 上的已发布版本；确需本地包请把该包加入 workspace 成员。',
          ),
        );
        continue;
      }

      if (source.source == 'hosted' &&
          source.host != null &&
          !rules.allowedHosts.contains(source.host)) {
        sourceIssues++;
        report.add(
          Finding(
            ruleId: 'dep-source-host',
            severity: Severity.error,
            message: '${member.name} / $section 中的 "$name" 来自非白名单主机 "${source.host}"。',
            path: pubspecPath,
            hint:
                '允许的主机：${rules.allowedHosts.join(', ')}。'
                '第三方 pub 镜像可能滞后或被投毒，需先加入白名单并评估。',
          ),
        );
        continue;
      }

      if (source.source == 'sdk') {
        final sdkName = source.detail ?? '';
        if (!rules.allowedSdk.contains(sdkName)) {
          sourceIssues++;
          report.add(
            Finding(
              ruleId: 'dep-source-sdk',
              severity: Severity.error,
              message: '${member.name} / $section 中的 "$name" 使用了未知 SDK 来源 "$sdkName"。',
              path: pubspecPath,
              hint: '允许的 SDK 来源：${rules.allowedSdk.join(', ')}。',
            ),
          );
        }
        continue;
      }

      if (source.source == 'unknown') {
        sourceIssues++;
        report.add(
          Finding(
            ruleId: 'dep-source-unknown',
            severity: Severity.error,
            message: '${member.name} / $section 中的 "$name" 来源无法识别（${source.detail ?? '—'}）。',
            path: pubspecPath,
            hint: '无法识别的来源一律视为不安全。请改用标准写法。',
          ),
        );
      }
    }
  }
  report.metric('sourceIssues', sourceIssues);

  return report;
}

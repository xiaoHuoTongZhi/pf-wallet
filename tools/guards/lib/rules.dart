/// 规则文件 → 强类型配置对象。
///
/// 原则：规则文件里的任何笔误都必须是**硬失败**（GuardException → 退出码 2），
/// 不允许出现「写错了但看起来没事」的情况。
library;

import 'dart:io';

import 'glob.dart';
import 'model.dart';
import 'repo.dart';
import 'yaml_util.dart';

/// 规则目录（相对仓库根）。
const String defaultRuleDirectory = 'tools/guards/rules';

/// 作用范围：shipping 命中且未被 exempt 排除的路径才受约束。
final class Scope {
  Scope({required this.shipping, required this.exempt});

  factory Scope.fromJson(Map<String, Object?> json, {required String path}) {
    return Scope(
      shipping: PathMatcher(stringList(json, 'shipping', path: path)),
      exempt: PathMatcher(stringList(json, 'exempt', path: path)),
    );
  }

  final PathMatcher shipping;
  final PathMatcher exempt;

  bool ships(String relativePath) =>
      shipping.matches(relativePath) && !exempt.matches(relativePath);

  List<String> get shippingGlobs => shipping.globs;
  List<String> get exemptGlobs => exempt.globs;
}

// ---------------------------------------------------------------------------
// deps.yaml
// ---------------------------------------------------------------------------

final class DepRules {
  DepRules({
    required this.sourcePath,
    required this.scope,
    required this.deniedPackages,
    required this.deniedPrefixes,
    required this.deniedRegexes,
    required this.reviewPackages,
    required this.bannedSources,
    required this.allowedHosts,
    required this.allowedSdk,
  });

  final String sourcePath;
  final Scope scope;
  final Set<String> deniedPackages;
  final List<String> deniedPrefixes;
  final List<RegExp> deniedRegexes;
  final Set<String> reviewPackages;
  final Set<String> bannedSources;
  final Set<String> allowedHosts;
  final Set<String> allowedSdk;

  /// 命中硬拒绝时返回可直接写进报告的原因，未命中返回 null。
  String? denyReason(String packageName) {
    if (deniedPackages.contains(packageName)) {
      return '与 deny.packages 中的条目精确匹配';
    }
    for (final prefix in deniedPrefixes) {
      if (packageName.startsWith(prefix)) {
        return '命中 deny.prefixes 前缀 "$prefix"';
      }
    }
    for (final regex in deniedRegexes) {
      if (regex.hasMatch(packageName)) {
        return '命中 deny.regexes 正则 /${regex.pattern}/';
      }
    }
    return null;
  }

  bool needsReview(String packageName) => reviewPackages.contains(packageName);
}

/// 二级依赖登记条目。
final class AllowlistEntry {
  const AllowlistEntry({
    required this.package,
    required this.usedBy,
    required this.justification,
    required this.dataFlow,
    required this.owner,
    required this.reviewBy,
  });

  final String package;
  final List<String> usedBy;
  final String justification;
  final String? dataFlow;
  final String? owner;

  /// 复核截止日（UTC 零点）。缺省表示「永久豁免」—— 不推荐，会在报告里提示。
  final DateTime? reviewBy;

  bool expiredAt(DateTime now) {
    final deadline = reviewBy;
    if (deadline == null) return false;
    return now.toUtc().isAfter(deadline.toUtc());
  }
}

final class DepAllowlist {
  const DepAllowlist({required this.sourcePath, required this.byPackage});

  final String sourcePath;
  final Map<String, AllowlistEntry> byPackage;

  AllowlistEntry? entryFor(String packageName) => byPackage[packageName];
}

// ---------------------------------------------------------------------------
// banned_api.yaml
// ---------------------------------------------------------------------------

final class BannedApiRule {
  BannedApiRule({
    required this.id,
    required this.severity,
    required this.description,
    required this.rationale,
    required this.patterns,
    required this.allowPatterns,
    required this.appliesTo,
    required this.exemptPaths,
  });

  final String id;
  final Severity severity;
  final String description;
  final String rationale;
  final List<RegExp> patterns;
  final List<RegExp> allowPatterns;
  final PathMatcher appliesTo;
  final PathMatcher exemptPaths;

  bool applies(String relativePath) =>
      appliesTo.matches(relativePath) && !exemptPaths.matches(relativePath);

  /// 命中片段若同时命中 allow 列表则放行。
  bool allowedByFragment(String fragment) {
    for (final regex in allowPatterns) {
      if (regex.hasMatch(fragment)) return true;
    }
    return false;
  }
}

final class BannedApiRules {
  BannedApiRules({required this.sourcePath, required this.scope, required this.rules});

  final String sourcePath;
  final Scope scope;
  final List<BannedApiRule> rules;
}

// ---------------------------------------------------------------------------
// logging.yaml
// ---------------------------------------------------------------------------

final class SinkRule {
  SinkRule({required this.severity, required this.patterns});

  final Severity severity;
  final List<RegExp> patterns;
}

final class LoggingRules {
  LoggingRules({
    required this.sourcePath,
    required this.scope,
    required this.directSinks,
    required this.secretIdentifiers,
    required this.secretInterpolationEnabled,
    required this.secretInterpolationSeverity,
    required this.logCallIdentifierPattern,
    required this.secretInLogCallEnabled,
    required this.secretInLogCallSeverity,
    required this.businessDataIdentifiers,
    required this.hintEnabled,
    required this.hintSeverity,
    required this.hintMessage,
  });

  final String sourcePath;
  final Scope scope;
  final SinkRule directSinks;
  final List<String> secretIdentifiers;
  final bool secretInterpolationEnabled;
  final Severity secretInterpolationSeverity;
  final RegExp logCallIdentifierPattern;
  final bool secretInLogCallEnabled;
  final Severity secretInLogCallSeverity;
  final List<String> businessDataIdentifiers;
  final bool hintEnabled;
  final Severity hintSeverity;
  final String hintMessage;
}

// ---------------------------------------------------------------------------
// manifest.yaml
// ---------------------------------------------------------------------------

final class AttributeRule {
  const AttributeRule({required this.attribute, required this.value, required this.rationale});

  final String attribute;
  final String? value;
  final String? rationale;
}

final class KeyRule {
  const KeyRule({required this.key, required this.valueType, required this.rationale});

  final String key;
  final String? valueType;
  final String? rationale;
}

final class AndroidManifestRules {
  const AndroidManifestRules({
    required this.mainManifestCandidates,
    required this.forbidPermissions,
    required this.requireApplicationAttributes,
    required this.forbidApplicationAttributes,
    required this.requireFiles,
  });

  final List<String> mainManifestCandidates;
  final Set<String> forbidPermissions;
  final List<AttributeRule> requireApplicationAttributes;
  final List<AttributeRule> forbidApplicationAttributes;
  final List<String> requireFiles;
}

final class IosManifestRules {
  const IosManifestRules({
    required this.infoPlistCandidates,
    required this.requireKeys,
    required this.forbidKeys,
  });

  final List<String> infoPlistCandidates;
  final List<KeyRule> requireKeys;
  final List<KeyRule> forbidKeys;
}

final class ManifestRules {
  const ManifestRules({
    required this.sourcePath,
    required this.missingPlatformTolerance,
    required this.android,
    required this.ios,
  });

  final String sourcePath;
  final Severity missingPlatformTolerance;
  final AndroidManifestRules android;
  final IosManifestRules ios;
}

// ---------------------------------------------------------------------------
// 载入器
// ---------------------------------------------------------------------------

/// 从规则目录载入全部规则。
final class RuleSet {
  RuleSet({required this.repo, this.directory = defaultRuleDirectory});

  final Repo repo;
  final String directory;

  String _path(String fileName) => '$directory/$fileName';

  DepRules loadDepRules() {
    final path = _path('deps.yaml');
    final json = repo.loadYamlMap(path);
    return DepRules(
      sourcePath: path,
      scope: Scope.fromJson(requireMap(json, 'scope', path: path), path: '$path.scope'),
      deniedPackages:
          requireMap(json, 'deny', path: path)['packages'] == null
              ? const <String>{}
              : stringList(
                requireMap(json, 'deny', path: path),
                'packages',
                path: '$path.deny',
              ).toSet(),
      deniedPrefixes: stringList(
        requireMap(json, 'deny', path: path),
        'prefixes',
        path: '$path.deny',
      ),
      deniedRegexes: stringList(
        requireMap(json, 'deny', path: path),
        'regexes',
        path: '$path.deny',
      ).map(_compileRegExp).toList(growable: false),
      reviewPackages:
          stringList(
            requireMap(json, 'review', path: path),
            'packages',
            path: '$path.review',
          ).toSet(),
      bannedSources:
          stringList(
            requireMap(json, 'sources', path: path),
            'banned',
            path: '$path.sources',
          ).toSet(),
      allowedHosts:
          stringList(
            requireMap(json, 'sources', path: path),
            'allowedHosts',
            path: '$path.sources',
          ).toSet(),
      allowedSdk:
          stringList(
            requireMap(json, 'sources', path: path),
            'allowedSdk',
            path: '$path.sources',
          ).toSet(),
    );
  }

  DepAllowlist loadDepAllowlist() {
    final path = _path('deps_allowlist.yaml');
    final json = repo.loadYamlMap(path);
    final rawEntries = json['entries'];
    if (rawEntries != null && rawEntries is! List) {
      throw GuardException('$path.entries 必须是列表');
    }
    final byPackage = <String, AllowlistEntry>{};
    final list = (rawEntries as List?) ?? const <Object?>[];
    for (var i = 0; i < list.length; i++) {
      final item = list[i];
      if (item is! Map) {
        throw GuardException('$path.entries[$i] 必须是映射');
      }
      final entryPath = '$path.entries[$i]';
      final map = item.cast<String, Object?>();
      final name = requireString(map, 'package', path: entryPath);
      final reviewByRaw = optionalString(map, 'reviewBy', path: entryPath);
      final reviewByDate = reviewByRaw == null ? null : DateTime.tryParse(reviewByRaw);
      if (reviewByRaw != null && reviewByDate == null) {
        throw GuardException('$entryPath.reviewBy 不是合法日期: "$reviewByRaw"');
      }
      if (byPackage.containsKey(name)) {
        throw GuardException('$path 中包名 "$name" 重复登记');
      }
      byPackage[name] = AllowlistEntry(
        package: name,
        usedBy: stringList(map, 'usedBy', path: entryPath),
        justification: requireString(map, 'justification', path: entryPath),
        dataFlow: optionalString(map, 'dataFlow', path: entryPath),
        owner: optionalString(map, 'owner', path: entryPath),
        reviewBy: reviewByDate,
      );
    }
    return DepAllowlist(
      sourcePath: path,
      byPackage: Map<String, AllowlistEntry>.unmodifiable(byPackage),
    );
  }

  BannedApiRules loadBannedApiRules() {
    final path = _path('banned_api.yaml');
    final json = repo.loadYamlMap(path);
    final rawRules = json['rules'];
    if (rawRules is! List) {
      throw GuardException('$path.rules 必须是列表');
    }
    final rules = <BannedApiRule>[];
    for (var i = 0; i < rawRules.length; i++) {
      final item = rawRules[i];
      final rulePath = '$path.rules[$i]';
      if (item is! Map) {
        throw GuardException('$rulePath 必须是映射');
      }
      final map = item.cast<String, Object?>();
      rules.add(
        BannedApiRule(
          id: requireString(map, 'id', path: rulePath),
          severity: Severity.parse(requireString(map, 'severity', path: rulePath)),
          description: optionalString(map, 'description', path: rulePath) ?? '',
          rationale: optionalString(map, 'rationale', path: rulePath) ?? '',
          patterns: stringList(
            map,
            'patterns',
            path: rulePath,
          ).map(_compileRegExp).toList(growable: false),
          allowPatterns: stringList(
            map,
            'allowPatterns',
            path: rulePath,
          ).map(_compileRegExp).toList(growable: false),
          appliesTo: PathMatcher(stringList(map, 'appliesTo', path: rulePath)),
          exemptPaths: PathMatcher(stringList(map, 'exemptPaths', path: rulePath)),
        ),
      );
    }
    return BannedApiRules(
      sourcePath: path,
      scope: Scope.fromJson(requireMap(json, 'scope', path: path), path: '$path.scope'),
      rules: List<BannedApiRule>.unmodifiable(rules),
    );
  }

  LoggingRules loadLoggingRules() {
    final path = _path('logging.yaml');
    final json = repo.loadYamlMap(path);
    final sinks = requireMap(json, 'directSinks', path: path);
    final interpolation = optionalMap(json, 'secretInterpolation', path: path);
    final inLogCall = optionalMap(json, 'secretInLogCall', path: path);
    final hint = optionalMap(json, 'hint', path: path);
    final callPattern = requireString(json, 'logCallIdentifierPattern', path: path);
    return LoggingRules(
      sourcePath: path,
      scope: Scope.fromJson(requireMap(json, 'scope', path: path), path: '$path.scope'),
      directSinks: SinkRule(
        severity: Severity.parse(requireString(sinks, 'severity', path: '$path.directSinks')),
        patterns: stringList(
          sinks,
          'patterns',
          path: '$path.directSinks',
        ).map(_compileRegExp).toList(growable: false),
      ),
      secretIdentifiers: stringList(json, 'secretIdentifiers', path: path),
      secretInterpolationEnabled:
          interpolation == null
              ? false
              : optionalBool(
                interpolation,
                'enabled',
                path: '$path.secretInterpolation',
                fallback: true,
              ),
      secretInterpolationSeverity:
          interpolation == null
              ? Severity.error
              : Severity.parse(
                optionalString(interpolation, 'severity', path: '$path.secretInterpolation') ??
                    'error',
              ),
      logCallIdentifierPattern: _compileRegExp(callPattern),
      secretInLogCallEnabled:
          inLogCall == null
              ? false
              : optionalBool(inLogCall, 'enabled', path: '$path.secretInLogCall', fallback: true),
      secretInLogCallSeverity:
          inLogCall == null
              ? Severity.error
              : Severity.parse(
                optionalString(inLogCall, 'severity', path: '$path.secretInLogCall') ?? 'error',
              ),
      businessDataIdentifiers: stringList(json, 'businessDataIdentifiers', path: path),
      hintEnabled:
          hint == null ? false : optionalBool(hint, 'enabled', path: '$path.hint', fallback: true),
      hintSeverity:
          hint == null
              ? Severity.info
              : Severity.parse(optionalString(hint, 'severity', path: '$path.hint') ?? 'info'),
      hintMessage: hint == null ? '' : (optionalString(hint, 'message', path: '$path.hint') ?? ''),
    );
  }

  ManifestRules loadManifestRules() {
    final path = _path('manifest.yaml');
    final json = repo.loadYamlMap(path);
    final androidPath = '$path.android';
    final iosPath = '$path.ios';
    final android = requireMap(json, 'android', path: path);
    final ios = requireMap(json, 'ios', path: path);

    List<AttributeRule> attributes(Map<String, Object?> source, String key) {
      final value = source[key];
      if (value == null) return const <AttributeRule>[];
      if (value is! List) throw GuardException('$key 必须是列表');
      return value.indexed
          .map((entry) {
            final item = entry.$2;
            if (item is! Map) throw GuardException('$key[${entry.$1}] 必须是映射');
            final map = item.cast<String, Object?>();
            return AttributeRule(
              attribute: requireString(map, 'attribute', path: '$key[${entry.$1}]'),
              value: optionalString(map, 'value', path: '$key[${entry.$1}]'),
              rationale: optionalString(map, 'rationale', path: '$key[${entry.$1}]'),
            );
          })
          .toList(growable: false);
    }

    List<KeyRule> keys(Map<String, Object?> source, String key, String parentPath) {
      final value = source[key];
      if (value == null) return const <KeyRule>[];
      if (value is! List) throw GuardException('$parentPath.$key 必须是列表');
      return value.indexed
          .map((entry) {
            final item = entry.$2;
            final itemPath = '$parentPath.$key[${entry.$1}]';
            if (item is String) {
              return KeyRule(key: item, valueType: null, rationale: null);
            }
            if (item is! Map) throw GuardException('$itemPath 必须是字符串或映射');
            final map = item.cast<String, Object?>();
            return KeyRule(
              key: requireString(map, 'key', path: itemPath),
              valueType: optionalString(map, 'valueType', path: itemPath),
              rationale: optionalString(map, 'rationale', path: itemPath),
            );
          })
          .toList(growable: false);
    }

    return ManifestRules(
      sourcePath: path,
      missingPlatformTolerance: Severity.parse(
        optionalString(json, 'missingPlatformTolerance', path: path) ?? 'warning',
      ),
      android: AndroidManifestRules(
        mainManifestCandidates: stringList(android, 'mainManifestCandidates', path: androidPath),
        forbidPermissions: stringList(android, 'forbidPermissions', path: androidPath).toSet(),
        requireApplicationAttributes: attributes(android, 'requireApplicationAttributes'),
        forbidApplicationAttributes: attributes(android, 'forbidApplicationAttributes'),
        requireFiles: stringList(android, 'requireFiles', path: androidPath),
      ),
      ios: IosManifestRules(
        infoPlistCandidates: stringList(ios, 'infoPlistCandidates', path: iosPath),
        requireKeys: keys(ios, 'requireKeys', iosPath),
        forbidKeys: keys(ios, 'forbidKeys', iosPath),
      ),
    );
  }
}

RegExp _compileRegExp(String pattern) {
  try {
    return RegExp(pattern);
  } on FormatException catch (error) {
    throw GuardException('正则表达式非法: /$pattern/', hint: error.message);
  }
}

/// 供检查器使用：列出仓库内符合 [matcher] 的全部文件。
List<String> filesMatching(Repo repo, PathMatcher matcher, {Iterable<String>? candidates}) {
  final files = candidates ?? repo.walkAllFiles();
  return files.where(matcher.matches).toList(growable: false);
}

/// 判断某个路径是否为存在的目录（用于平台目录缺失时的容错判定）。
bool directoryExistsAt(Repo repo, String relativePosix) =>
    Directory(repo.absolute(relativePosix)).existsSync();

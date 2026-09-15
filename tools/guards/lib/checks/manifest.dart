/// 平台隐私清单检查（manifest）。
///
/// 这一条检查的存在理由：Android 默认 `allowBackup=true`，
/// 系统会把应用私有目录（含 SQLCipher 加密库）自动备份到云端。
/// 界面上没有任何提示，用户也不会知道 —— 这是一个纯粹的架构级泄漏，
/// 必须由 CI 拦住，不能靠人记得。
library;

import '../glob.dart';
import '../model.dart';
import '../repo.dart';
import '../rules.dart';

/// 执行平台清单检查。
GuardReport runManifestCheck({
  required Repo repo,
  required ManifestRules rules,
  Iterable<String>? candidates,
}) {
  final report = GuardReport(check: 'manifest', ruleFiles: <String>[rules.sourcePath]);
  final allFiles = (candidates ?? repo.walkAllFiles()).toList(growable: false);

  _checkAndroid(repo: repo, rules: rules, report: report, allFiles: allFiles);
  _checkIos(repo: repo, rules: rules, report: report, allFiles: allFiles);

  return report;
}

// ---------------------------------------------------------------------------
// Android
// ---------------------------------------------------------------------------

void _checkAndroid({
  required Repo repo,
  required ManifestRules rules,
  required GuardReport report,
  required List<String> allFiles,
}) {
  final android = rules.android;
  final manifestMatcher = PathMatcher(android.mainManifestCandidates);
  final manifests = filesMatching(repo, manifestMatcher, candidates: allFiles);

  report.metric('androidManifests', manifests.length);

  if (manifests.isEmpty) {
    report.add(
      Finding(
        ruleId: 'manifest-android-missing',
        severity: rules.missingPlatformTolerance,
        message:
            '未找到 Android 主 manifest（候选模式：${android.mainManifestCandidates.join(', ')}）。'
            '平台目录尚未生成，本项 Android 检查已跳过。',
        hint:
            '执行 `cd apps/pf_mobile && flutter create --platforms=android,ios .` 后本项自动生效。'
            'M0 验收要求生成后本项为 error 级别且通过。',
      ),
    );
  }

  for (final path in manifests) {
    final content = repo.readFile(path);
    final appTag = _firstTag(content, 'application');

    // 1) 禁止权限
    for (final permission in _permissionNames(content)) {
      if (!android.forbidPermissions.contains(permission)) continue;
      report.add(
        Finding(
          ruleId: 'manifest-android-permission',
          severity: Severity.error,
          message: '主 manifest 声明了禁止的权限 "$permission"。',
          path: path,
          line: _lineOf(content, permission),
          hint:
              '本应用无网络、无定位、无通讯录需求。'
              'Flutter 调试所需的 INTERNET 权限应当只出现在 debug/profile manifest 中。',
        ),
      );
    }

    // 2) 必须存在的 application 属性
    for (final rule in android.requireApplicationAttributes) {
      final actual = appTag == null ? null : _attributeValue(appTag, rule.attribute);
      if (actual == null) {
        report.add(
          Finding(
            ruleId: 'manifest-android-attr-missing',
            severity: Severity.error,
            message: '<application> 缺少必需属性 ${rule.attribute}（期望值 ${rule.value ?? '任意'}）。',
            path: path,
            line: _lineOf(content, '<application'),
            hint: rule.rationale,
          ),
        );
        continue;
      }
      final expected = rule.value;
      if (expected != null && actual != expected) {
        report.add(
          Finding(
            ruleId: 'manifest-android-attr-value',
            severity: Severity.error,
            message: '${rule.attribute} 的值是 "$actual"，必须是 "$expected"。',
            path: path,
            line: _lineOf(content, rule.attribute),
            hint: rule.rationale,
          ),
        );
      }
    }

    // 3) 禁止的 application 属性
    for (final rule in android.forbidApplicationAttributes) {
      final actual = appTag == null ? null : _attributeValue(appTag, rule.attribute);
      if (actual == null) continue;
      final bannedValue = rule.value;
      if (bannedValue != null && actual != bannedValue) continue;
      report.add(
        Finding(
          ruleId: 'manifest-android-attr-forbidden',
          severity: Severity.error,
          message: '${rule.attribute} 出现了禁止的取值 "$actual"。',
          path: path,
          line: _lineOf(content, rule.attribute),
          hint: rule.rationale,
        ),
      );
    }
  }

  // 4) 必须存在的资源文件
  final requiredMatcher = PathMatcher(android.requireFiles);
  if (manifests.isNotEmpty) {
    for (final pattern in android.requireFiles) {
      final matcher = PathMatcher(<String>[pattern]);
      final found = allFiles.any(matcher.matches);
      if (found) continue;
      report.add(
        Finding(
          ruleId: 'manifest-android-file-missing',
          severity: Severity.error,
          message: '缺少必需文件：$pattern（来自 ${requiredMatcher.globs.length} 条要求）。',
          hint:
              '该文件用于彻底排除云备份与设备转移，内容必须显式全排除。'
              '模板已随仓库提供于 apps/pf_mobile/android/app/src/main/res/xml/。',
        ),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// iOS
// ---------------------------------------------------------------------------

void _checkIos({
  required Repo repo,
  required ManifestRules rules,
  required GuardReport report,
  required List<String> allFiles,
}) {
  final ios = rules.ios;
  final matcher = PathMatcher(ios.infoPlistCandidates);
  final plists = filesMatching(repo, matcher, candidates: allFiles);

  report.metric('iosInfoPlists', plists.length);

  if (plists.isEmpty) {
    report.add(
      Finding(
        ruleId: 'manifest-ios-missing',
        severity: rules.missingPlatformTolerance,
        message:
            '未找到 iOS Info.plist（候选模式：${ios.infoPlistCandidates.join(', ')}）。'
            '平台目录尚未生成，本项 iOS 检查已跳过。',
        hint: '执行 `cd apps/pf_mobile && flutter create --platforms=android,ios .` 后本项自动生效。',
      ),
    );
  }

  for (final path in plists) {
    final content = repo.readFile(path);

    for (final rule in ios.requireKeys) {
      final type = _plistValueType(content, rule.key);
      if (type == null) {
        report.add(
          Finding(
            ruleId: 'manifest-ios-key-missing',
            severity: Severity.error,
            message: 'Info.plist 缺少必需键 "${rule.key}"。',
            path: path,
            line: _lineOf(content, '</dict>'),
            hint: rule.rationale,
          ),
        );
        continue;
      }
      final expectedType = rule.valueType;
      if (expectedType != null && type != expectedType) {
        report.add(
          Finding(
            ruleId: 'manifest-ios-key-type',
            severity: Severity.error,
            message: '"${rule.key}" 的值类型是 $type，期望 $expectedType（常见错误写法）。',
            path: path,
            line: _lineOf(content, rule.key),
            hint: rule.rationale,
          ),
        );
      }
    }

    for (final rule in ios.forbidKeys) {
      if (_plistValueType(content, rule.key) == null) continue;
      report.add(
        Finding(
          ruleId: 'manifest-ios-key-forbidden',
          severity: Severity.error,
          message: 'Info.plist 出现了禁止的键 "${rule.key}"。',
          path: path,
          line: _lineOf(content, rule.key),
          hint: rule.rationale,
        ),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// 文本解析工具（刻意使用正则而非 XML 库：清单文件由工具生成、格式稳定，
// 且引入 XML 解析器会带来实体展开等新的攻击面）
// ---------------------------------------------------------------------------

final RegExp _permissionPattern = RegExp(
  r'<uses-permission[^>]*android:name\s*=\s*"([^"]+)"',
  multiLine: true,
);

Set<String> _permissionNames(String content) {
  final names = <String>{};
  for (final match in _permissionPattern.allMatches(content)) {
    final value = match.group(1);
    if (value != null) names.add(value);
  }
  return names;
}

/// 返回第一个 `<tag ...>` 开始标签的完整文本。
String? _firstTag(String content, String tag) {
  final match = RegExp('<$tag\\b[^>]*>', multiLine: true).firstMatch(content);
  return match?.group(0);
}

/// 从一段标签文本中读取属性值。
String? _attributeValue(String tagText, String attribute) {
  final match = RegExp('${RegExp.escape(attribute)}\\s*=\\s*"([^"]*)"').firstMatch(tagText);
  return match?.group(1);
}

/// 返回 plist 中某个 key 对应值的类型名（`string` / `boolean` / `array` / `dict` / `integer`），
/// key 不存在时返回 null。
String? _plistValueType(String content, String key) {
  final pattern = RegExp(
    '<key>\\s*${RegExp.escape(key)}\\s*</key>\\s*<([a-zA-Z]+)\\s*/?>',
    multiLine: true,
  );
  final match = pattern.firstMatch(content);
  if (match == null) return null;
  final tag = match.group(1)!.toLowerCase();
  switch (tag) {
    case 'true':
    case 'false':
      return 'boolean';
    case 'string':
      return 'string';
    case 'array':
      return 'array';
    case 'dict':
      return 'dict';
    case 'integer':
      return 'integer';
    case 'real':
      return 'number';
    case 'date':
      return 'date';
    default:
      return tag;
  }
}

/// 1-based 行号；未找到时返回 null。
int? _lineOf(String content, String needle) {
  final index = content.indexOf(needle);
  if (index < 0) return null;
  var line = 1;
  for (var i = 0; i < index; i++) {
    if (content.codeUnitAt(i) == 0x0A) line += 1;
  }
  return line;
}

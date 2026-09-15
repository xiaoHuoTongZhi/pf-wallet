/// 源码级检查：禁用 API 扫描（banned-api）与日志敏感信息扫描（logging）。
///
/// 两者的共同点：都在「逻辑语句」粒度上扫描，并支持 `// guards:ignore <rule-id>` 抑制。
///
/// 关于用哪种投影做匹配（重要，容易搞错）：
///   banned-api 用 `noComments` —— 因为要匹配 `import 'dart:mirrors'`，
///                字符串内容被掩码后就什么都匹配不到了。
///   logging   用 `masked`    —— 因为要匹配 `print(`，必须排除写在字符串里的 "print("。
///   例外：logging 的「秘密出现在插值里」用 `noComments`，因为秘密本来就在字符串里。
library;

import '../model.dart';
import '../repo.dart';
import '../rules.dart';
import '../scan.dart';

/// 收集 shipping 范围内所有 Dart 文件（已排序）。
List<String> shippingDartFiles(Repo repo, Scope scope, {Iterable<String>? candidates}) {
  final files = candidates ?? repo.walkAllFiles();
  return files.where((path) => path.endsWith('.dart') && scope.ships(path)).toList(growable: false);
}

// ---------------------------------------------------------------------------
// banned-api
// ---------------------------------------------------------------------------

/// 执行禁用 API 扫描。
GuardReport runBannedApiCheck({
  required Repo repo,
  required BannedApiRules rules,
  Iterable<String>? candidates,
}) {
  final report = GuardReport(check: 'banned-api', ruleFiles: <String>[rules.sourcePath]);
  final files = shippingDartFiles(repo, rules.scope, candidates: candidates);

  report.metric('scannedFiles', files.length);
  report.metric('rules', rules.rules.length);

  var hits = 0;
  var suppressed = 0;

  for (final path in files) {
    final projection = SourceProjection.of(path, repo.readFile(path));
    final units = splitLogicalUnits(projection);

    for (final rule in rules.rules) {
      if (!rule.applies(path)) continue;
      for (final unit in units) {
        for (final pattern in rule.patterns) {
          for (final match in pattern.allMatches(unit.noComments)) {
            final fragment = unit.noComments.substring(match.start, match.end);
            if (rule.allowedByFragment(fragment)) continue;

            final offset = unit.startOffset + match.start;
            final line = projection.lineOf(offset);
            final endLine = projection.lineOf(unit.startOffset + match.end);
            if (hasIgnoreDirective(projection.rawLines, line, endLine, rule.id)) {
              suppressed++;
              continue;
            }
            hits++;
            report.add(
              Finding(
                ruleId: rule.id,
                severity: rule.severity,
                message: '${rule.description}（命中片段：$fragment）',
                path: path,
                line: line,
                column: projection.columnOf(offset),
                snippet: projection.snippetAt(offset),
                hint:
                    rule.rationale.isEmpty
                        ? null
                        : collapseWhitespace(rule.rationale, maxLength: 240),
              ),
            );
          }
        }
      }
    }
  }

  report.metric('hits', hits);
  report.metric('suppressedByDirective', suppressed);
  return report;
}

// ---------------------------------------------------------------------------
// logging
// ---------------------------------------------------------------------------

/// 执行日志敏感信息扫描。
GuardReport runLoggingCheck({
  required Repo repo,
  required LoggingRules rules,
  Iterable<String>? candidates,
}) {
  final report = GuardReport(check: 'logging', ruleFiles: <String>[rules.sourcePath]);
  final files = shippingDartFiles(repo, rules.scope, candidates: candidates);

  report.metric('scannedFiles', files.length);

  final secretPattern = _identifierPattern(rules.secretIdentifiers);
  final businessPattern = _identifierPattern(rules.businessDataIdentifiers);
  final interpolationPattern = RegExp(r'\$\{([^}]*)\}|\$([A-Za-z_$][\w$]*)');
  final sinkPattern = _sinkPattern(rules.directSinks.patterns);

  var sinkHits = 0;
  var interpolationHits = 0;
  var logCallHits = 0;
  var hintHits = 0;
  var suppressed = 0;

  for (final path in files) {
    final projection = SourceProjection.of(path, repo.readFile(path));
    final units = splitLogicalUnits(projection);

    for (final unit in units) {
      // ---- 规则 A：直接使用日志出口 ----
      final directSinkLines = <int, int>{};
      if (sinkPattern != null) {
        for (final match in sinkPattern.allMatches(unit.masked)) {
          final offset = unit.startOffset + match.start;
          final line = projection.lineOf(offset);
          if (hasIgnoreDirective(projection.rawLines, line, line, 'log-direct-sink')) {
            suppressed++;
            continue;
          }
          if (directSinkLines.containsKey(line)) continue;
          directSinkLines[line] = offset;
          sinkHits++;
          report.add(
            Finding(
              ruleId: 'log-direct-sink',
              severity: rules.directSinks.severity,
              message: 'shipping 代码直接使用了日志出口 "${collapseWhitespace(match.group(0) ?? '')}"。',
              path: path,
              line: line,
              column: projection.columnOf(offset),
              snippet: projection.snippetAt(offset),
              hint:
                  '所有输出必须走 pf_core 的 PfLogger —— 它按白名单序列化字段，'
                  '是「不泄漏敏感信息」这条约束唯一的结构性保障。',
            ),
          );
        }
      }

      // ---- 规则 B：秘密出现在字符串插值中 ----
      if (rules.secretInterpolationEnabled && secretPattern != null) {
        for (final match in interpolationPattern.allMatches(unit.noComments)) {
          final inner = match.group(1) ?? match.group(2) ?? '';
          final secret = secretPattern.firstMatch(inner);
          if (secret == null) continue;
          final offset = unit.startOffset + match.start;
          final line = projection.lineOf(offset);
          if (hasIgnoreDirective(projection.rawLines, line, line, 'log-secret-interpolation')) {
            suppressed++;
            continue;
          }
          interpolationHits++;
          report.add(
            Finding(
              ruleId: 'log-secret-interpolation',
              severity: rules.secretInterpolationSeverity,
              message: '字符串插值中出现密钥类标识符 "${secret.group(0)}"。',
              path: path,
              line: line,
              column: projection.columnOf(offset),
              snippet: projection.snippetAt(offset),
              hint:
                  '插值出的字符串会进入异常消息、assert 文本与 toString()，'
                  '最终一定会出现在某个日志或崩溃上报里 —— 即使你从未写过 print。',
            ),
          );
        }
      }

      // ---- 规则 C：日志类调用实参中出现秘密 ----
      if (rules.secretInLogCallEnabled && secretPattern != null) {
        for (final match in rules.logCallIdentifierPattern.allMatches(unit.masked)) {
          if (!_isFollowedByOpenParen(unit.masked, match.end)) continue;
          final tail = unit.noComments.substring(match.start);
          final secret = secretPattern.firstMatch(tail);
          if (secret == null) continue;
          final offset = unit.startOffset + match.start;
          final line = projection.lineOf(offset);
          if (hasIgnoreDirective(projection.rawLines, line, unit.endLine, 'log-secret-in-call')) {
            suppressed++;
            continue;
          }
          logCallHits++;
          report.add(
            Finding(
              ruleId: 'log-secret-in-call',
              severity: rules.secretInLogCallSeverity,
              message: '日志类调用 "${match.group(0)}" 的实参中出现密钥类标识符 "${secret.group(0)}"。',
              path: path,
              line: line,
              column: projection.columnOf(offset),
              snippet: projection.snippetAt(offset),
              hint: '改为输出不可逆的标识（如 keyId / 指纹前 8 位），绝不输出密钥材料本身。',
            ),
          );
        }
      }

      // ---- 提示规则：业务字段出现在输出路径上 ----
      if (rules.hintEnabled &&
          businessPattern != null &&
          (directSinkLines.isNotEmpty ||
              _containsLogCall(unit.masked, rules.logCallIdentifierPattern))) {
        final business = businessPattern.firstMatch(unit.noComments);
        if (business != null) {
          final offset = unit.startOffset + (business.start);
          final line = projection.lineOf(offset);
          final isDuplicate = report.findings.any(
            (f) => f.path == path && f.line == line && f.ruleId == 'log-business-data',
          );
          if (!isDuplicate) {
            hintHits++;
            report.add(
              Finding(
                ruleId: 'log-business-data',
                severity: rules.hintSeverity,
                message: '输出路径上出现业务字段 "${business.group(0)}"。${rules.hintMessage}',
                path: path,
                line: line,
                column: projection.columnOf(offset),
                snippet: projection.snippetAt(offset),
              ),
            );
          }
        }
      }
    }
  }

  report.metric('directSinkHits', sinkHits);
  report.metric('secretInterpolationHits', interpolationHits);
  report.metric('secretInLogCallHits', logCallHits);
  report.metric('businessDataHints', hintHits);
  report.metric('suppressedByDirective', suppressed);
  return report;
}

// ---------------------------------------------------------------------------
// 内部工具
// ---------------------------------------------------------------------------

RegExp? _identifierPattern(List<String> identifiers) {
  if (identifiers.isEmpty) return null;
  return RegExp(r'\b(' + identifiers.map(RegExp.escape).join('|') + r')\b');
}

RegExp? _sinkPattern(List<RegExp> patterns) {
  if (patterns.isEmpty) return null;
  final alternatives = patterns.map((p) => p.pattern.replaceAll(r'\b', '')).join('|');
  return RegExp('(?:$alternatives)');
}

bool _isFollowedByOpenParen(String masked, int from) {
  var i = from;
  while (i < masked.length) {
    final c = masked.codeUnitAt(i);
    if (c == 0x28) return true; // (
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
      i += 1;
      continue;
    }
    return false;
  }
  return false;
}

bool _containsLogCall(String masked, RegExp identifierPattern) {
  for (final match in identifierPattern.allMatches(masked)) {
    if (_isFollowedByOpenParen(masked, match.end)) return true;
  }
  return false;
}

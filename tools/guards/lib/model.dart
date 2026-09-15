/// 门禁脚本的通用数据模型：严重级别、问题条目、检查报告。
///
/// 设计要点：**退出码语义分离**
///   0 = 通过
///   1 = 检查不通过（代码有问题）
///   2 = 工具/配置错误（脚本无法完成判定，例如规则文件写错、lock 文件缺失）
///
/// 这个区分很重要：CI 里 2 必须被当作「基础设施故障」处理，
/// 而不是被当成「代码有问题」去改业务代码 —— 后者会导致有人为了让 CI 变绿
/// 而删掉规则。
library;

import 'dart:convert';

/// 问题严重级别。
enum Severity {
  error('error'),
  warning('warning'),
  info('info');

  const Severity(this.label);

  /// 用于输出的稳定字面量（不要改，CI 日志有依赖）。
  final String label;

  /// 由规则文件里的字符串解析，无法识别时抛 [GuardException]。
  static Severity parse(String raw) {
    switch (raw) {
      case 'error':
        return Severity.error;
      case 'warning':
        return Severity.warning;
      case 'info':
        return Severity.info;
      default:
        throw GuardException('未知的 severity: "$raw"', hint: '只允许 error / warning / info');
    }
  }
}

/// 配置文件或运行环境问题：工具无法完成判定，对应退出码 2。
final class GuardException implements Exception {
  const GuardException(this.message, {this.hint});

  final String message;
  final String? hint;

  @override
  String toString() =>
      hint == null ? 'GuardException: $message' : 'GuardException: $message\n  → $hint';
}

/// 一条门禁问题。
final class Finding implements Comparable<Finding> {
  const Finding({
    required this.ruleId,
    required this.severity,
    required this.message,
    this.path,
    this.line,
    this.column,
    this.snippet,
    this.hint,
  });

  /// 规则标识，形如 `no-dynamic-execution` 或 `dep-denied`。
  final String ruleId;
  final Severity severity;
  final String message;

  /// 相对仓库根的 POSIX 路径。
  final String? path;

  /// 1-based 行号。
  final int? line;

  /// 1-based 列号。
  final int? column;

  /// 命中的原代码片段（已单行化、已截断）。
  final String? snippet;

  /// 修复建议。
  final String? hint;

  /// `path:line` 形式的定位串，无路径时返回空串。
  String get location {
    final p = path;
    if (p == null) return '';
    final l = line;
    if (l == null) return p;
    final c = column;
    return c == null ? '$p:$l' : '$p:$l:$c';
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'ruleId': ruleId,
    'severity': severity.label,
    'message': message,
    if (path != null) 'path': path,
    if (line != null) 'line': line,
    if (column != null) 'column': column,
    if (snippet != null) 'snippet': snippet,
    if (hint != null) 'hint': hint,
  };

  @override
  int compareTo(Finding other) {
    final a = path ?? '\u{10FFFF}';
    final b = other.path ?? '\u{10FFFF}';
    final byPath = a.compareTo(b);
    if (byPath != 0) return byPath;
    final byLine = (line ?? 0).compareTo(other.line ?? 0);
    if (byLine != 0) return byLine;
    final byColumn = (column ?? 0).compareTo(other.column ?? 0);
    if (byColumn != 0) return byColumn;
    return ruleId.compareTo(other.ruleId);
  }

  @override
  String toString() {
    final head = '${severity.label.toUpperCase().padRight(7)} [$ruleId] $location';
    final buffer = StringBuffer(head)..write('\n        $message');
    final s = snippet;
    if (s != null && s.isNotEmpty) buffer.write('\n        > $s');
    final h = hint;
    if (h != null && h.isNotEmpty) buffer.write('\n        → $h');
    return buffer.toString();
  }
}

/// 单次检查的结构化结果。
final class GuardReport {
  GuardReport({
    required this.check,
    required this.ruleFiles,
    List<Finding>? findings,
    Map<String, Object?>? metrics,
  }) : findings = findings ?? <Finding>[],
       metrics = metrics ?? <String, Object?>{};

  /// 检查名，如 `deps` / `banned-api` / `logging` / `manifest`。
  final String check;

  /// 本次检查读取的规则文件（相对仓库根的 POSIX 路径）。
  final List<String> ruleFiles;

  final List<Finding> findings;
  final Map<String, Object?> metrics;

  int get errorCount => findings.where((f) => f.severity == Severity.error).length;
  int get warningCount => findings.where((f) => f.severity == Severity.warning).length;
  int get infoCount => findings.where((f) => f.severity == Severity.info).length;

  /// 只有 error 会让检查失败。warning / info 不阻塞。
  bool get ok => errorCount == 0;

  void add(Finding finding) => findings.add(finding);

  void addAll(Iterable<Finding> items) => findings.addAll(items);

  void metric(String key, Object? value) => metrics[key] = value;

  /// 稳定排序后的条目，保证输出可 diff。
  List<Finding> sorted() => (List<Finding>.of(findings)..sort());

  Map<String, Object?> toJson() => <String, Object?>{
    'check': check,
    'ruleFiles': ruleFiles,
    'ok': ok,
    'summary': <String, Object?>{
      'error': errorCount,
      'warning': warningCount,
      'info': infoCount,
      'total': findings.length,
    },
    'metrics': metrics,
    'findings': sorted().map((f) => f.toJson()).toList(growable: false),
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// 人类可读输出。[verbose] 为 false 时只打印 error 与 warning。
  String render({bool verbose = true}) {
    final separator = '─' * (60 - check.length).clamp(0, 60);
    final buffer =
        StringBuffer()
          ..writeln('── check: $check $separator')
          ..writeln('   rules: ${ruleFiles.isEmpty ? '(none)' : ruleFiles.join(', ')}');

    for (final entry in metrics.entries) {
      buffer.writeln('   ${entry.key}: ${entry.value}');
    }

    final shown = sorted()
        .where((f) => verbose || f.severity != Severity.info)
        .toList(growable: false);

    if (shown.isEmpty) {
      buffer.writeln('   ✓ 无问题');
    } else {
      buffer.writeln();
      for (final finding in shown) {
        buffer.writeln(finding.toString());
      }
    }

    buffer.writeln();
    buffer.writeln(
      '   ${ok ? '✓ PASS' : '✗ FAIL'}  '
      'error=$errorCount warning=$warningCount info=$infoCount',
    );
    return buffer.toString();
  }
}

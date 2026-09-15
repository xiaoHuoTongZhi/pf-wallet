/// 向量运行报告。
///
/// ## 为什么必须有「判定摘要」（[VectorReport.verdictDigest]）
///
/// 关卡 3 的核心不是「本机跑过了」，而是「三个平台跑出的结论完全一致」。
/// 直接比对整份报告是行不通的：里面有时间戳、耗时、Dart 版本号，
/// 天然处处不同。
///
/// 因此报告被切成两半：
///   - **判定部分**：`用例 ID + 状态`，排序后求 SHA-256，得到摘要。
///     摘要相同 ⇔ 三个平台对每一条向量得出了同一个结论。
///   - **诊断部分**：时间、耗时、平台、实际值。供人排查，不参与比对。
///
/// 这个切分让「跨平台一致性」变成一个可以一行 `if` 判断的事实，
/// 而不是靠人肉翻三份 JSON。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'outcome.dart';
import 'schema.dart';

/// 单条用例的运行结果。
final class VectorCaseResult {
  const VectorCaseResult({
    required this.caseId,
    required this.suite,
    required this.kind,
    required this.title,
    required this.milestone,
    required this.status,
    required this.durationMicros,
    this.message,
    this.expected,
    this.actual,
  });

  final String caseId;
  final String suite;
  final String kind;
  final String title;
  final String milestone;
  final VectorStatus status;
  final int durationMicros;

  /// 失败原因 / pending 原因。
  final String? message;

  /// 期望值（失败时写入，便于定位）。
  final Map<String, Object?>? expected;

  /// 实际值（失败时写入）。
  final Map<String, Object?>? actual;

  bool get isFailure => status == VectorStatus.fail;

  /// 判定行：跨平台比对只认这一行。
  String get verdictLine => '$caseId|${status.wireName}';

  Map<String, Object?> toJson() => <String, Object?>{
    'caseId': caseId,
    'suite': suite,
    'kind': kind,
    'title': title,
    'milestone': milestone,
    'status': status.wireName,
    'durationMicros': durationMicros,
    if (message != null) 'message': message,
    if (expected != null) 'expected': expected,
    if (actual != null) 'actual': actual,
  };
}

/// 一次完整运行的结果。
final class VectorReport {
  VectorReport({
    required this.results,
    required this.generatedAt,
    required this.dartVersion,
    required this.operatingSystem,
    this.schemaVersion = VectorSchema.current,
  });

  final List<VectorCaseResult> results;
  final DateTime generatedAt;
  final String dartVersion;
  final String operatingSystem;
  final int schemaVersion;

  int get total => results.length;

  int get passed => results.where((VectorCaseResult r) => r.status == VectorStatus.pass).length;

  int get failed => results.where((VectorCaseResult r) => r.status == VectorStatus.fail).length;

  int get pending => results.where((VectorCaseResult r) => r.status == VectorStatus.pending).length;

  /// 判定是否干净：没有任何 fail。
  ///
  /// 注意 pending **不影响**这个值 —— 是否容忍 pending 由基线机制决定
  /// （见 [PendingBaseline.diff]），不在这里一刀切。
  bool get isClean => failed == 0;

  /// 当前处于 pending 的用例 ID 集合。
  Set<String> get pendingCaseIds =>
      results
          .where((VectorCaseResult r) => r.status == VectorStatus.pending)
          .map((VectorCaseResult r) => r.caseId)
          .toSet();

  List<VectorCaseResult> get failures =>
      results.where((VectorCaseResult r) => r.isFailure).toList();

  /// 判定摘要。相同 ⇔ 两个平台的结论完全一致。
  String get verdictDigest {
    final lines = results.map((VectorCaseResult r) => r.verdictLine).toList()..sort();
    return sha256.convert(utf8.encode(lines.join('\n'))).toString();
  }

  /// 全量耗时（诊断用）。
  int get totalDurationMicros =>
      results.fold(0, (int sum, VectorCaseResult r) => sum + r.durationMicros);

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'dartVersion': dartVersion,
    'operatingSystem': operatingSystem,
    'verdictDigest': verdictDigest,
    'totals': <String, Object?>{
      'total': total,
      'passed': passed,
      'failed': failed,
      'pending': pending,
      'durationMicros': totalDurationMicros,
    },
    'results': results.map((VectorCaseResult r) => r.toJson()).toList(),
  };

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// 人类可读的单行摘要，供 CI 日志首行显示。
  String get summaryLine =>
      '向量 $total 条：通过 $passed，失败 $failed，待实现 $pending，'
      '摘要 ${verdictDigest.substring(0, 12)}…';
}

/// 采集当前运行环境指纹。
({String dartVersion, String operatingSystem}) captureEnvironment() => (
  dartVersion: Platform.version,
  operatingSystem: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
);

/// 覆盖检查报告（`vector_report.dart --require-coverage` 产出）。
///
/// ## 为什么覆盖结论要落成文件
///
/// 这条检查的结论原本只出现在 stdout 里。stdout 有两个问题：
///
///   1. **会过期。** 一个红的 run，日志链接过几个月就没人点得开了；
///      而「这次提交的驱动是不是都被向量引用过」是 M1/M2 验收的一部分。
///   2. **不可机读。** 「缺了哪几个 kind」这件事在文本里只能靠人眼找。
///
/// 因此这里产出与 `tools/guards`（`build/guards/*.json`）同构的报告：
/// 顶层一个 `ok`，下面 `totals` 计数、`uncoveredKinds` / `orphanKinds` 明细、
/// `drivers` / `orphans` 逐条。CI 把它当 artifact 传上去，验收时点开看的
/// 是一份可 diff、可断言的文件。
///
/// ## 两个方向都要判：漏写向量，与写错 kind
///
/// 覆盖检查守的是「向量先于实现」。但「覆盖面」这个说法有两个方向，
/// 只判一个方向会让报告出现自相矛盾：
///
///   - [uncoveredKinds]：**已实现**但没有任何向量引用它 —— 实现先落地了。
///   - [orphanKinds]：**向量引用了**但没人在注册表里认领 —— kind 写错了。
///
/// 后者在运行器里已经是 fail（不是跳过），所以门禁不会漏；
/// 但它此前完全不进这份报告：向量计数只投影到已注册的 kind 上，
/// 于是会出现「`coverage.json` 里 `ok: true`，而这个 run 是红的」——
/// 一份与门禁结论相反的证据比没有证据更坏，因此 [ok] 要求两者都为空。
library;

import 'dart:convert';

/// 覆盖检查结果。
final class CoverageReport {
  const CoverageReport({
    required this.generatedAt,
    required this.dartVersion,
    required this.operatingSystem,
    required this.vectorCounts,
    required this.passed,
    required this.failed,
    required this.pending,
    required this.uncoveredKinds,
    this.orphanCounts = const <String, int>{},
  });

  /// 报告格式版本。与向量文件的 `schemaVersion` 一样，
  /// 读到不认识的版本应当拒绝而不是猜。
  static const int schemaVersion = 1;

  final DateTime generatedAt;
  final String dartVersion;
  final String operatingSystem;

  /// 每个已注册驱动（kind）被多少条向量引用。顺序不敏感，输出时按 kind 排序。
  final Map<String, int> vectorCounts;

  /// 本次全量跑的向量判定计数。
  final int passed;
  final int failed;
  final int pending;

  /// **已实现**但没有任何向量引用的 kind（判定失败的原因之一）。
  final List<String> uncoveredKinds;

  /// kind → 引用它的向量条数，只含**未注册**的 kind（判定失败的原因之二）。
  ///
  /// 未就绪（`isImplemented == false`）的驱动不算孤儿：它们本来就在等
  /// 期望值，向量写在前面是正确的顺序。
  final Map<String, int> orphanCounts;

  /// 判定是否通过：漏写向量（[uncoveredKinds]）与写错 kind（[orphanKinds]）
  /// 都为空才算通过。
  ///
  /// 刻意**不**把「向量跑失败了」并进来：那是 `build/vectors/report.json`
  /// 的结论，同一个判定在两处各写一遍，只会退化成「两处都读、两处都不信」。
  /// 这份文件只回答「覆盖面完整吗」；要判整个 run 是否绿，看 `totals.failed`
  /// 与退出码。
  bool get ok => uncoveredKinds.isEmpty && orphanCounts.isEmpty;

  /// 向量引用了、但注册表里没有的 kind（排序）。
  List<String> get orphanKinds => orphanCounts.keys.toList()..sort();

  int get driverCount => vectorCounts.length;

  int get coveredDriverCount => driverCount - uncoveredKinds.length;

  /// 已注册驱动的向量条数之和（含 pending 用例 —— 它们同样算「有向量」）。
  int get vectorCount => vectorCounts.values.fold(0, (int sum, int count) => sum + count);

  /// 孤儿 kind 的向量条数之和。
  int get orphanVectorCount => orphanCounts.values.fold(0, (int sum, int count) => sum + count);

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'dartVersion': dartVersion,
    'operatingSystem': operatingSystem,
    'ok': ok,
    'totals': <String, Object?>{
      'drivers': driverCount,
      'coveredDrivers': coveredDriverCount,
      'uncoveredDrivers': uncoveredKinds.length,
      'orphanKinds': orphanCounts.length,
      'vectors': vectorCount,
      'orphanVectors': orphanVectorCount,
      'passed': passed,
      'failed': failed,
      'pending': pending,
    },
    'uncoveredKinds': _sortedUncoveredKinds,
    'orphanKinds': orphanKinds,
    'drivers': _sortedDrivers,
    'orphans': _sortedOrphans,
  };

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// 单行摘要，供 CI 日志首行显示 —— 与向量报告的 `summaryLine` 呼应。
  ///
  /// 判失败时两个方向都要说清，否则读的人只修了驱动那一侧就又红一次。
  String get summaryLine {
    if (ok) return '✓ 覆盖检查：$driverCount 个驱动全部有向量引用';
    final reasons = <String>[
      if (uncoveredKinds.isNotEmpty) '${uncoveredKinds.length} 个已实现驱动没有任何向量引用',
      if (orphanCounts.isNotEmpty) '${orphanCounts.length} 个 kind 被向量引用但未注册',
    ];
    return '✗ 覆盖检查：$driverCount 个驱动，${reasons.join("；")}';
  }

  /// 给人看的明细（失败时打印）。
  String describeUncovered() => uncoveredKinds.map((String kind) => '    - $kind').join('\n');

  /// 孤儿 kind 的明细，带上被引用条数 —— 条数能提示「是一处笔误还是一整片」。
  String describeOrphans() =>
      orphanKinds.map((String kind) => '    - $kind（被 ${orphanCounts[kind]} 条向量引用）').join('\n');

  List<String> get _sortedUncoveredKinds => uncoveredKinds.toList()..sort();

  List<Map<String, Object?>> get _sortedDrivers {
    final kinds = vectorCounts.keys.toList()..sort();
    return <Map<String, Object?>>[
      for (final kind in kinds) <String, Object?>{'kind': kind, 'vectors': vectorCounts[kind] ?? 0},
    ];
  }

  List<Map<String, Object?>> get _sortedOrphans {
    final kinds = orphanKinds;
    return <Map<String, Object?>>[
      for (final kind in kinds) <String, Object?>{'kind': kind, 'vectors': orphanCounts[kind] ?? 0},
    ];
  }
}

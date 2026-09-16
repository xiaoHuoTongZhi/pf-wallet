/// 入库路径检查（tracked-paths）。
///
/// ## 这一条与其余所有门禁的分工
///
/// 其余检查都在回答「代码内容对不对」；这一条回答「**哪些路径被提交了**」。
/// 它是 M1 第一步那次事故的产物：提交 `3ebe837` 混进了
/// `apps/pf_mobile/.flutter_tool_state`（flutter_tools 写的运行时状态），
/// 而当时三关卡**全绿** —— 因为没有任何一关在回答这个问题。
///
/// 它读的是 **git 索引**（`git ls-files --cached`），不是工作区文件树。
/// 工作区里本来就躺着大量不会入库的产物，扫它们只会产生噪音；
/// 而「将被提交的东西」在 `git add` 之后就已确定。详见规则文件
/// `rules/tracked_paths.yaml` 开头的说明。
///
/// ## 判定顺序（后面的不看前面已命中的路径）
///
///   1. `deny`      —— 命中即 error（除 deny 外不做例外）
///   2. `collisions` —— 大小写折叠后重名的路径
///   3. `allow`     —— 未命中前两者且不在白名单内 ⇒ 按 unknownPathSeverity 报告
///
/// 「每条路径只归属一条 deny 规则」是刻意的：`build/app.db` 同时命中
/// 「构建输出」与「数据库文件」两条规则，报两条只会让人以为是两个问题。
/// 规则文件里的顺序即优先级，第一条命中的负责解释。
library;

import '../model.dart';
import '../repo.dart';
import '../rules.dart';

/// 执行入库路径检查。
///
/// [trackedPaths] 是**测试注入点**：缺省时读真实 git 索引。
/// 之所以留这个口子：单元测试跑在临时目录里（不是 git 仓库），
/// 而「规则是否按预期命中」这件事必须能脱离 git 被验证 ——
/// 否则规则文件写错时要等到 CI 上才发现。
GuardReport runTrackedPathsCheck({
  required Repo repo,
  required TrackedPathRules rules,
  Iterable<String>? trackedPaths,
}) {
  final report = GuardReport(check: 'tracked-paths', ruleFiles: <String>[rules.sourcePath]);

  final paths = normalizeTrackedPaths(trackedPaths ?? repo.trackedFiles());

  final denied = _checkDenied(report: report, rules: rules, paths: paths);
  final collisions = _checkCaseCollisions(report: report, rules: rules, paths: paths);
  final unexpected = _checkUnexpected(report: report, rules: rules, paths: paths, denied: denied);

  report
    ..metric('trackedFiles', paths.length)
    ..metric('denyRules', rules.deny.length)
    ..metric('allowGlobs', rules.allow.globs.length)
    ..metric('deniedPaths', denied.length)
    ..metric('caseCollisions', collisions)
    ..metric('unexpectedPaths', unexpected.length)
    ..metric('allowedPaths', paths.length - denied.length - unexpected.length);

  return report;
}

/// 归一化路径列表：去掉 `./` 前缀、统一 POSIX 分隔符、去重并排序。
///
/// 排序是为了让报告可 diff —— 同一份索引两次运行必须得到逐字节相同的输出。
List<String> normalizeTrackedPaths(Iterable<String> raw) {
  final normalized = <String>{};
  for (final entry in raw) {
    var path = entry.replaceAll(r'\', '/').trim();
    while (path.startsWith('./')) {
      path = path.substring(2);
    }
    if (path.isEmpty) continue;
    normalized.add(path);
  }
  return normalized.toList(growable: false)..sort();
}

// ---------------------------------------------------------------------------
// 1) deny
// ---------------------------------------------------------------------------

Set<String> _checkDenied({
  required GuardReport report,
  required TrackedPathRules rules,
  required List<String> paths,
}) {
  final hitsByRule = <TrackedPathRule, List<String>>{};
  final denied = <String>{};

  for (final path in paths) {
    final rule = rules.firstMatch(path);
    if (rule == null) continue;
    denied.add(path);
    (hitsByRule[rule] ??= <String>[]).add(path);
  }

  for (final entry in hitsByRule.entries) {
    final rule = entry.key;
    _emitCapped<String>(
      report: report,
      entries: entry.value,
      max: rules.maxFindingsPerRule,
      ruleId: rule.id,
      severity: rule.severity,
      build:
          (String path) => Finding(
            ruleId: rule.id,
            severity: rule.severity,
            message: '该路径禁止入库（命中规则 ${rule.id}）。',
            path: path,
            hint: rule.rationale.isEmpty ? null : rule.rationale,
          ),
    );
  }

  return denied;
}

// ---------------------------------------------------------------------------
// 2) 大小写折叠后重名
// ---------------------------------------------------------------------------

int _checkCaseCollisions({
  required GuardReport report,
  required TrackedPathRules rules,
  required List<String> paths,
}) {
  final folded = <String, List<String>>{};
  for (final path in paths) {
    (folded[path.toLowerCase()] ??= <String>[]).add(path);
  }

  final groups = folded.values
    .where((group) => group.length > 1)
    .map((group) => List<String>.of(group)..sort())
    .toList(growable: false)..sort((a, b) => a.first.compareTo(b.first));

  if (groups.isEmpty) return 0;

  _emitCapped<List<String>>(
    report: report,
    entries: groups,
    max: rules.maxFindingsPerRule,
    ruleId: 'tracked-case-collision',
    severity: rules.caseCollisionSeverity,
    build:
        (List<String> group) => Finding(
          ruleId: 'tracked-case-collision',
          severity: rules.caseCollisionSeverity,
          message: '这些路径只有大小写不同，在区分大小写的文件系统上能同时存在：${group.join('  ↔  ')}',
          path: group.first,
          hint:
              'macOS 与 Windows 的文件系统默认不区分大小写：checkout 时两者会互相覆盖，'
              'Windows 上甚至得不到一个可用的工作区。本仓是三平台 CI，必须重命名其中一个。',
        ),
  );

  return groups.length;
}

// ---------------------------------------------------------------------------
// 3) 白名单
// ---------------------------------------------------------------------------

List<String> _checkUnexpected({
  required GuardReport report,
  required TrackedPathRules rules,
  required List<String> paths,
  required Set<String> denied,
}) {
  final unexpected = paths
      .where((path) => !denied.contains(path) && !rules.allow.matches(path))
      .toList(growable: false);

  if (unexpected.isEmpty) return unexpected;

  _emitCapped<String>(
    report: report,
    entries: unexpected,
    max: rules.maxFindingsPerRule,
    ruleId: 'tracked-unexpected',
    severity: rules.unknownPathSeverity,
    build:
        (String path) => Finding(
          ruleId: 'tracked-unexpected',
          severity: rules.unknownPathSeverity,
          message: '该路径不在入库白名单内。',
          path: path,
          hint:
              '若是有意新增的区域（新目录），请在 '
              'tools/guards/rules/tracked_paths.yaml 的 allow 下登记一条 glob —— '
              '那个动作会出现在 diff 里，这正是本条要的「新增区域必须是一次看得见的决定」；'
              '若是误提交，用 `git rm --cached <path>` 移出索引，并把规则补进 .gitignore。',
        ),
  );

  return unexpected;
}

// ---------------------------------------------------------------------------
// 共同输出逻辑
// ---------------------------------------------------------------------------

/// 逐条输出 [entries]，超过 [max] 条时截断并补一条汇总。
///
/// 截断是必需的：「一次误提交 5000 个构建产物」不该把 CI 日志冲成一屏噪音。
/// 但**截断不会让检查变绿** —— 汇总条与逐条命中同级别，
/// 退出码语义完全一致。
void _emitCapped<T>({
  required GuardReport report,
  required List<T> entries,
  required int max,
  required String ruleId,
  required Severity severity,
  required Finding Function(T entry) build,
}) {
  final limit = max <= 0 ? entries.length : max;
  final shown = entries.length > limit ? entries.sublist(0, limit) : entries;

  for (final entry in shown) {
    report.add(build(entry));
  }

  final hidden = entries.length - shown.length;
  if (hidden > 0) {
    report.add(
      Finding(
        ruleId: ruleId,
        severity: severity,
        message: '另有 $hidden 条同类命中未逐条列出（本规则共命中 ${entries.length} 条）。',
        hint: '输出被规则文件里的 maxFindingsPerRule=$max 截断。先修已列出的，重跑即可看到下一批。',
      ),
    );
  }
}

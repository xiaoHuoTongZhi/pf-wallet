/// schema 迁移编排。
///
/// ## 迁移为什么需要一份独立的「计划」逻辑
///
/// 迁移代码本身很简单（就是一堆 DDL），出问题的地方在于**怎么决定跑哪几个**：
///   - v3 的迁移跑在 v5 的库上会做出错误假设。
///   - 缺一环（v2 存在、v3 缺失）必须**立刻失败**，绝不能"跳过继续"——
///     那会留下一个结构不完整的库，而下一个迁移会以更晦涩的方式崩溃。
///   - 同一版本号被两个迁移占用，会导致不同设备升到同一个版本号却是不同结构，
///     这在「双端数据格式完全兼容」的前提下是不可接受的。
///
/// 这些判断是纯逻辑，与 SQLite 无关，因此放在 M0 实现并用测试钉死。
library;

import 'package:pf_core/pf_core.dart';

/// 语句分隔符：R4 校验和按 `statements.join(kMigrationStatementSeparator)` 计算。
/// 定义在迁移契约这一侧（而非执行器），生成器、执行器与审计读取共用一份口径。
const String kMigrationStatementSeparator = '\n';

/// 一次 schema 迁移。
final class Migration {
  const Migration({required this.version, required this.description, required this.statements});

  /// 目标版本号。跑完这个迁移，schema 版本就变成 [version]。
  ///
  /// 约定：**一个版本号只允许一个迁移**，版本号必须从 [PfSchema.initial] 起连续。
  final int version;

  /// 一句话说明这次改了什么（会进日志，因此不得包含任何数据内容）。
  final String description;

  /// 迁移步骤。按顺序执行。
  ///
  /// 约束：每条语句必须是**幂等安全**的写法或用 `IF NOT EXISTS` / `IF EXISTS` 保护，
  /// 因为迁移可能因为中途断电而被重放（外层事务会回滚，但重放时不能出错）。
  final List<String> statements;

  /// 迁移是否在结构上可用。
  void validate() {
    if (version < PfSchema.initial) {
      throw DomainError.validation(
        detail: '迁移版本号 $version 低于初始版本 ${PfSchema.initial}',
        userMessage: '数据升级配置有误，请联系开发者。',
      );
    }
    if (statements.isEmpty) {
      throw DomainError.validation(detail: '迁移 v$version 没有任何语句', userMessage: '数据升级配置有误，请联系开发者。');
    }
    for (final statement in statements) {
      if (statement.trim().isEmpty) {
        throw DomainError.validation(detail: '迁移 v$version 含空语句', userMessage: '数据升级配置有误，请联系开发者。');
      }
    }
  }

  @override
  String toString() => 'Migration(v$version, ${statements.length} statements)';
}

/// 迁移计划：从 [from] 升到 [to] 需要依次执行的有序迁移列表。
final class MigrationPlan {
  MigrationPlan._({required this.from, required this.to, required this.steps});

  /// 计算迁移计划。
  ///
  /// [maxSupportedVersion] 缺省为本实现支持的 schema 版本。
  /// 之所以允许外部指定：一是让计划逻辑可以被测试（否则只有 1 个版本时
  /// 无法覆盖多步链），二是供「跨端兼容性检查工具」在更高版本上做干跑。
  ///
  /// 抛出的错误都是 [PfError] 子类（`PFI_E_...` / `PFD_E_...` 系），
  /// 便于上层按码决定是"重试"、"提示升级"还是"提示损坏"。
  static MigrationPlan build({
    required int from,
    required int to,
    required List<Migration> registered,
    int maxSupportedVersion = PfSchema.current,
  }) {
    if (from == to) {
      return MigrationPlan._(from: from, to: to, steps: const <Migration>[]);
    }

    if (to > maxSupportedVersion) {
      throw StorageError.schemaTooNew(found: to, supported: maxSupportedVersion);
    }
    if (from > to) {
      throw StorageError.schemaTooNew(found: from, supported: to);
    }
    if (from < PfSchema.initial) {
      throw DomainError.validation(detail: '当前 schema 版本 $from 低于初始版本 ${PfSchema.initial}');
    }

    // 版本号唯一性：同号两个迁移意味着不同设备可能升到同一版本号却是不同结构
    final byVersion = <int, Migration>{};
    for (final migration in registered) {
      migration.validate();
      if (byVersion.containsKey(migration.version)) {
        throw DomainError.validation(
          detail: '版本号 v${migration.version} 被多个迁移占用',
          userMessage: '数据升级配置有误，请联系开发者。',
        );
      }
      byVersion[migration.version] = migration;
    }

    if (!byVersion.containsKey(to)) {
      throw DomainError.validation(detail: '缺少目标版本 v$to 的迁移定义', userMessage: '数据升级配置有误，请联系开发者。');
    }

    final steps = <Migration>[];
    for (var version = from + 1; version <= to; version++) {
      final migration = byVersion[version];
      if (migration == null) {
        // 缺一环必须硬失败，绝不能跳过 —— 跳过会留下结构不完整的库
        throw DomainError.validation(
          detail: '迁移链断裂：缺少 v$version（需要 $from → $to）',
          userMessage: '数据升级缺少必要的中间步骤，已停止升级且未修改任何数据。',
        );
      }
      steps.add(migration);
    }

    return MigrationPlan._(from: from, to: to, steps: List<Migration>.unmodifiable(steps));
  }

  /// 起始版本。
  final int from;

  /// 目标版本。
  final int to;

  /// 需要依次执行的迁移。空列表表示无需迁移。
  final List<Migration> steps;

  bool get isEmpty => steps.isEmpty;

  int get stepCount => steps.length;

  @override
  String toString() => 'MigrationPlan(v$from → v$to, ${steps.length} steps)';
}

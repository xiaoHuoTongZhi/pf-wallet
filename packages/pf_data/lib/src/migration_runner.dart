/// 迁移执行器（§2.7 伪码的 M1 落地）。
///
/// ## 职责边界
///
/// [MigrationPlan.build]（M0）只回答"要跑哪几个"；本类回答"怎么跑"：
///   - **R2 一步一事务**：每个迁移独立事务，失败整步回滚；
///   - **R4 校验和记录**：脚本 sha256 写入 `schema_migration`，改历史必留痕；
///   - **外键切换**：DDL 期间 `foreign_keys = OFF`，完成即 `ON`
///     （§2.3 脚本首尾的 PRAGMA 由这里统一承担，见 schema_v1.dart 的说明）；
///   - **user_version 推进**：`PRAGMA user_version = N` 作为事务的最后一条
///     语句 —— 结构与版本号要么都生效、要么都不生效。
///
/// ## 不在本类职责内（M2 平台装配层）
///
///   - **R3 迁移前备份**（`sqlcipher_export`）：需要真实文件句柄；
///   - **R7 迁移前库样本回放**：fixtures 由 CI 侧提供；
///   - 打开流程与版本门（`PFD_E_SCHEMA_TOO_NEW`）：在 [SqlCipherOpenFlow]，
///     本类默认入口的 user_version 一定 ≤ 支持版本。
///
/// ## v0 空库的处理
///
/// `user_version = 0` 表示"空库，还没有任何结构"（§3.4 打开流程对 0 的
/// 语义）。[MigrationPlan] 的契约是"必须从初始版本起"（from=0 被拒），
/// 那是**对已有库**的正确约束；空库没有可保护的数据，直接按
/// 初始版本起步执行整条链即可 —— 效果与"0 → N"完全一致，又不破坏
/// M0 已被向量/单测钉死的计划契约。
library;

import 'dart:convert' show utf8;
import 'dart:math' show max;

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';

import 'db.dart';
import 'migration.dart';

/// 迁移执行器。
final class MigrationRunner {
  /// [clock] 只用于 `schema_migration.applied_at` 审计列；
  /// 测试注入 [FixedClock] 保证确定性。
  MigrationRunner({required this.db, this.clock = const SystemClock()});

  final PfDb db;
  final Clock clock;

  /// 把当前库（`user_version` 可能为 0 或已注册版本）升到
  /// [registered] 中的最高版本。
  ///
  /// [maxSupportedVersion] 缺省为 [PfSchema.current]；显式抬高仅供
  /// 「跨端兼容性检查工具」做干跑（与 [MigrationPlan.build] 同语义）。
  ///
  /// 全部迁移幂等：重复调用是空操作（返回 0 步）。
  /// 返回实际执行的迁移数。
  Future<int> run({
    required List<Migration> registered,
    int maxSupportedVersion = PfSchema.current,
  }) async {
    final int current = await _readUserVersion();
    final int target = registered.map((m) => m.version).fold(0, max);
    if (target > maxSupportedVersion) {
      throw StorageError.schemaTooNew(found: target, supported: maxSupportedVersion);
    }
    if (current >= target) {
      return 0; // 已在目标版本（含空注册表），幂等短路。
    }

    final List<Migration> steps;
    if (current == 0) {
      // v0 空库（见文件头说明）：直接执行全部注册迁移。
      // [MigrationPlan] 的"必须从初始版本起"是对已有库的约束；
      // 空库没有可保护的数据，这里自建步骤表并做同等校验：
      // 版本号必须从初始版本起连续（缺一环 = 链断裂，绝不跳过）。
      final sorted = <Migration>[...registered]..sort((a, b) => a.version.compareTo(b.version));
      for (var i = 0; i < sorted.length; i++) {
        sorted[i].validate();
        if (sorted[i].version != PfSchema.initial + i) {
          throw DomainError.validation(
            detail: '空库迁移链断裂：期望 v${PfSchema.initial + i}，实际 v${sorted[i].version}',
            userMessage: '数据升级配置缺少必要的步骤，已停止且未修改任何数据。',
          );
        }
      }
      steps = sorted;
    } else {
      steps =
          MigrationPlan.build(
            from: current,
            to: target,
            registered: registered,
            maxSupportedVersion: maxSupportedVersion,
          ).steps;
    }
    if (steps.isEmpty) {
      return 0;
    }

    var applied = 0;
    for (final step in steps) {
      await _apply(step);
      applied++;
    }
    return applied;
  }

  Future<int> _readUserVersion() async {
    final rows = await db.query('PRAGMA user_version');
    if (rows.isEmpty) {
      throw StorageError.migrationFailed(
        from: -1,
        to: -1,
        cause: StateError('PRAGMA user_version 无结果'),
      );
    }
    final raw = rows.first.values.first;
    final parsed = raw is int ? raw : int.tryParse('$raw');
    if (parsed == null || parsed < 0) {
      throw StorageError.migrationFailed(
        from: -1,
        to: -1,
        cause: StateError('user_version 不可解析: $raw'),
      );
    }
    return parsed;
  }

  Future<void> _apply(Migration step) async {
    final sw = Stopwatch()..start();
    final checksum = migrationChecksum(step);
    try {
      await db.transaction<void>((tx) async {
        // §2.7 伪码：DDL 期间关闭外键（建表顺序与触发器不需要 FK 检查），
        // 结束即恢复 —— 无论成败（事务回滚后 ON 也必须成立，由驱动语义保证）。
        await tx.run('PRAGMA foreign_keys = OFF');
        for (final statement in step.statements) {
          await tx.run(statement);
        }
        await tx.run('PRAGMA foreign_keys = ON');
        // 版本号来自代码常量（int），不是用户输入 —— 允许拼接的唯一例外。
        await tx.run('PRAGMA user_version = ${step.version}');
      });
    } on PfError {
      rethrow;
    } catch (error) {
      throw StorageError.migrationFailed(from: step.version - 1, to: step.version, cause: error);
    }
    sw.stop();
    // 审计行在业务事务之外：即使它失败，结构迁移本身已原子生效，
    // 重放时因 user_version 已推进而幂等跳过 —— 审计缺失可见、可补，优于把
    // 结构与审计绑成一个"成功一半"的事务。
    await db.run(
      'INSERT INTO schema_migration (version, name, checksum, applied_at, duration_ms) '
      'VALUES (?, ?, ?, ?, ?)',
      arguments: <Object?>[
        step.version,
        step.description,
        checksum,
        clock.nowUtc().millisecondsSinceEpoch,
        sw.elapsedMilliseconds,
      ],
    );
  }
}

/// R4 校验和：`statements` 以 `\n` 连接后的 sha256（小写 hex）。
///
/// 摘要走 pf_crypto 的唯一实现（README 红线：加密/摘要只有一份）；
/// 生成器与执行器共用本函数，保证"算什么"只有一份定义。
String migrationChecksum(Migration migration) =>
    Sha256.instance.hashHex(utf8.encode(migration.statements.join(kMigrationStatementSeparator)));

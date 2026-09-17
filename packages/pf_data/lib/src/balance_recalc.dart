/// 全量余额重算（§2.7 伪码里的 `RecalcBalances.run`）。
///
/// ## 什么时候必须全量重算
///
/// 增量维护（txn_repository 的事务内 UPDATE）只在"本机记一笔"的路径上
/// 成立。凡是**批量写入**的场景 —— 导入合并、schema 迁移后的回填、
/// 跨端合并、（未来的）撤销导入 —— 都绕过增量路径，写完必须全量重算：
/// 逐笔回放既慢又容易在半途失败处留下半更新的缓存。
///
/// ## 不变式与等价性
///
/// 全量重算直接从账目聚合（两条腿 UNION，见下），不信任任何缓存值，
/// 因此它是**事实标准**：跑完之后
/// `cached_balance_minor == opening_balance_minor + Σ(生效 txn 的影响)`
/// 对所有账户重新成立。「随机 1000 笔操作后增量 == 全量」由
/// balance_engine_test.dart 与 `db.balance.replay` 向量钉死。
///
/// ## SQL 说明
///
///   - 腿拆分：支出与转出腿从 `account_id` 取（转出含手续费），
///     收入腿从 `account_id` 取，转入腿从 `to_account_id` 取；
///     三段 UNION ALL 后按账户聚合 —— 与 [BalanceEngine.effectOf]
///     的规则**逐字对应**，review 时必须两边一起看。
///   - 第二条语句把**没有任何生效交易**的账户归位到初始余额 ——
///     删光账目后缓存必须回到推演起点，而不是停在最后一次增量值。
///   - `UPDATE ... FROM` 需要 SQLite ≥ 3.33（SQLCipher 4.x 内置
///     ≥ 3.34，§1.5 版本钉死）；M2 真库首开测试会再验证一次。
///   - 同样刻意不碰 `updated_at` / `rev`（缓存不参与同步判决）。
library;

import 'db.dart';

/// 全量余额重算器。
abstract final class BalanceRecalculator {
  /// 三段腿聚合（支出 / 收入 / 转账双腿），与 BalanceEngine.effectOf 逐字对应。
  static const String recalcStatement =
      'WITH legs AS ('
      'SELECT account_id AS id, -(amount_minor + fee_minor) AS d, occurred_at AS occ '
      'FROM txn WHERE deleted_at IS NULL AND type IN (1, 3) '
      'UNION ALL '
      'SELECT account_id AS id, amount_minor AS d, occurred_at AS occ '
      'FROM txn WHERE deleted_at IS NULL AND type = 2 '
      'UNION ALL '
      'SELECT to_account_id AS id, amount_minor AS d, occurred_at AS occ '
      'FROM txn WHERE deleted_at IS NULL AND type = 3), '
      'agg AS (SELECT id, SUM(d) AS delta, MAX(occ) AS max_occ FROM legs GROUP BY id) '
      'UPDATE account SET '
      'cached_balance_minor = opening_balance_minor + COALESCE(agg.delta, 0), '
      'balance_as_of = COALESCE(agg.max_occ, 0) '
      'FROM agg WHERE account.id = agg.id';

  /// 没有任何生效交易的账户归位到初始余额（含 balance_as_of 清零）。
  static const String resetStatement =
      'UPDATE account SET cached_balance_minor = opening_balance_minor, balance_as_of = 0 '
      'WHERE deleted_at IS NULL AND id NOT IN ('
      'SELECT account_id FROM txn WHERE deleted_at IS NULL '
      'UNION '
      'SELECT to_account_id FROM txn WHERE deleted_at IS NULL AND to_account_id IS NOT NULL)';

  static Future<void> run(PfDb db) async {
    await db.run(recalcStatement);
    await db.run(resetStatement);
  }
}

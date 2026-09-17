/// 余额推演引擎（方案 §2.3 余额语义 + §7.2 验收的纯逻辑核心）。
///
/// ## 为什么推演规则必须是纯函数
///
/// 余额缓存（`account.cached_balance_minor`）在三条路径上被维护：
///
///   1. 仓储增量更新（记一笔/改一笔/删一笔，事务内 UPDATE 两个账户）；
///   2. 全量重算（导入后、升级后、或用户触发的校正）；
///   3. 跨端合并（导入器写完历史账目后跑一次全量重算）。
///
/// 三条路径如果各自维护一套"哪笔账对哪个账户加多少"的规则，
/// 缓存不一致只是时间问题。本文件把规则收敛成 [TxnEffect] 与
/// [BalanceEngine.recompute] 两个纯函数：仓储的 SQL 是规则的**执行器**，
/// 全量重算是规则的**聚合器**，向量的 Python 生成器是规则的**独立实现**
/// —— 三者在测试与向量处会合，任何一处口径漂移都会红。
///
/// ## 余额语义（§2.3 account 表注释，写进代码的就是契约）
///
///   - 支出：账户余额 `-amount`；
///   - 收入：账户余额 `+amount`；
///   - 转账：转出账户 `-(amount + fee)`，转入账户 `+amount`。
///     手续费由**转出账户额外承担**（`fee_minor` 是转账的附加成本，
///     不在 `amount_minor` 里），统计口径计入支出；
///   - 信用卡无特殊代码路径：消费（type=1，挂信用卡）同样 `-amount`，
///     还款（type=3 转入）同样 `+amount` —— 余额天然落在负数区，
///     负数即负债。§2.3 的「净资产 = Σ 所有账户 cached_balance_minor」
///     由此在所有账户类型下统一成立，不需要任何按账户类型的分支。
///
/// ## 增量与全量的关系
///
/// 增量是**性能优化**，全量是**事实标准**。不变式：
/// `cached_balance_minor == opening_balance_minor + Σ(生效 txn 的影响)`
/// 对任何账户、任何时刻成立。增量路径靠本文件的 delta 规则维持不变式；
/// 全量重算（balance_recalc.dart）直接从账目重推。两者的等价性由
/// 「随机 1000 笔操作」单测与 `db.balance.replay` 向量共同钉死。
library;

import 'package:pf_core/pf_core.dart';

import 'entities.dart';

/// 一笔交易对各账户余额的影响（单位：分；正数加、负数减）。
final class TxnEffect {
  const TxnEffect._({required this.accountDelta, required this.toAccountDelta});

  /// 挂账账户（txn.account_id）的余额变化。转账时含手续费。
  final int accountDelta;

  /// 转入账户（txn.to_account_id）的余额变化。非转账恒为 null。
  final int? toAccountDelta;

  /// 是否涉及两个账户（即转账）。
  bool get isTransferLeg => toAccountDelta != null;
}

/// 余额推演规则。
abstract final class BalanceEngine {
  /// 单笔交易对账户余额的影响。
  ///
  /// 输入必须已通过 [TxnRecord.validate] 的结构校验；
  /// 这里只做与余额直接相关的最终裁决（防御性，开销可忽略）。
  static TxnEffect effectOf({
    required TxnType type,
    required int amountMinor,
    required int feeMinor,
    String? toAccountId,
  }) {
    if (amountMinor <= 0) {
      throw DomainError.validation(detail: '金额必须为正，实际 $amountMinor');
    }
    if (feeMinor < 0) {
      throw DomainError.validation(detail: '手续费不能为负：$feeMinor');
    }
    switch (type) {
      case TxnType.expense:
        if (feeMinor != 0) {
          throw DomainError.validation(detail: '只有转账可以有手续费：$feeMinor');
        }
        return TxnEffect._(accountDelta: -amountMinor, toAccountDelta: null);
      case TxnType.income:
        if (feeMinor != 0) {
          throw DomainError.validation(detail: '只有转账可以有手续费：$feeMinor');
        }
        return TxnEffect._(accountDelta: amountMinor, toAccountDelta: null);
      case TxnType.transfer:
        if (toAccountId == null) {
          throw DomainError.validation(detail: '转账缺少 toAccountId，无法推演转入腿');
        }
        return TxnEffect._(accountDelta: -(amountMinor + feeMinor), toAccountDelta: amountMinor);
    }
  }

  /// 一条交易记录的推演影响（等于 [effectOf] 作用于记录字段）。
  static TxnEffect effectOfRecord(TxnRecord txn) => effectOf(
    type: txn.type,
    amountMinor: txn.amountMinor,
    feeMinor: txn.feeMinor,
    toAccountId: txn.toAccountId,
  );

  /// 全量重算：从账目直接推每个账户的缓存余额。
  ///
  /// 输入必须是**该账本的全部生效交易**（调用方负责过滤软删：
  /// 引擎只看 `!isDeleted` 的记录，避免两层过滤各写一套口径）。
  /// 返回 `accountId → (cachedBalanceMinor, balanceAsOf)`，
  /// 覆盖输入里出现的所有账户（opening 取传入值）。
  ///
  /// `balanceAsOf` = 该账户所有生效交易的最大 `occurred_at`（无交易为 0）
  /// —— "缓存已包含到的时间点"（§2.3 列注释）。
  static Map<String, RecalculatedBalance> recompute({
    required Iterable<({String id, int openingBalanceMinor})> accounts,
    required Iterable<TxnRecord> txns,
  }) {
    final deltas = <String, int>{};
    final asOf = <String, int>{};
    for (final account in accounts) {
      deltas[account.id] = account.openingBalanceMinor;
      asOf[account.id] = 0;
    }
    for (final txn in txns) {
      if (txn.isDeleted || txn.excludedFromBalance()) {
        continue;
      }
      final effect = effectOfRecord(txn);
      deltas.update(
        txn.accountId,
        (v) => v + effect.accountDelta,
        ifAbsent: () => effect.accountDelta,
      );
      asOf.update(
        txn.accountId,
        (v) => v < txn.occurredAt ? txn.occurredAt : v,
        ifAbsent: () => txn.occurredAt,
      );
      final toDelta = effect.toAccountDelta;
      if (toDelta != null) {
        final toId = txn.toAccountId!;
        deltas.update(toId, (v) => v + toDelta, ifAbsent: () => toDelta);
        asOf.update(
          toId,
          (v) => v < txn.occurredAt ? txn.occurredAt : v,
          ifAbsent: () => txn.occurredAt,
        );
      }
    }
    return <String, RecalculatedBalance>{
      for (final entry in deltas.entries)
        entry.key: RecalculatedBalance(balanceMinor: entry.value, balanceAsOf: asOf[entry.key]!),
    };
  }
}

/// 全量重算的单账户结果。
final class RecalculatedBalance {
  const RecalculatedBalance({required this.balanceMinor, required this.balanceAsOf});

  final int balanceMinor;
  final int balanceAsOf;
}

extension on TxnRecord {
  /// `excluded_from_stats` 只豁免统计口径，**不豁免余额推演**
  /// （钱确实动了，只是不计收支）。此扩展仅在全量重算处标注语义，
  /// 目前恒为 false —— 留作显式挂点，防止未来有人把两者混为一谈。
  bool excludedFromBalance() => false;
}

/// 收支合计的统计口径（§7.2：「转账不进收入/支出合计」）。
final class LedgerSummary {
  const LedgerSummary._({
    required this.currency,
    required this.incomeMinor,
    required this.expenseMinor,
    required this.transferMinor,
    required this.feeMinor,
  });

  final String currency;

  /// Σ 收入金额（type=2，不含 `excluded_from_stats`）。
  final int incomeMinor;

  /// Σ 支出金额（type=1）+ 转账手续费（§2.3：fee 计入支出），
  /// 不含 `excluded_from_stats`。**转账本金不在此列。**
  final int expenseMinor;

  /// Σ 转账本金（type=3）。只做展示口径，不进收入也不进支出。
  final int transferMinor;

  /// Σ 转账手续费（已并入 [expenseMinor]，单列供明细展示）。
  final int feeMinor;

  /// 净资产（§2.3）：Σ 所有账户的 `cached_balance_minor`。
  /// 信用卡的负余额在此自然抵减 —— 不需要任何类型分支。
  static int netWorth(Iterable<AccountRecord> accounts) =>
      accounts.where((a) => !a.isDeleted).fold(0, (sum, a) => sum + a.cachedBalanceMinor);

  /// 从生效交易统计。输入应是同一账本、同一币种的全部生效交易
  /// （软删过滤由调用方负责）；`excluded_from_stats` 的记录跳过。
  static LedgerSummary summarize(Iterable<TxnRecord> liveTxns) {
    String? currency;
    var income = 0;
    var expense = 0;
    var transfer = 0;
    var fee = 0;
    for (final txn in liveTxns) {
      if (txn.isDeleted || txn.excludedFromStats) {
        continue;
      }
      if (currency == null) {
        currency = txn.currency;
      } else if (currency != txn.currency) {
        throw DomainError.currencyMismatch(left: currency, right: txn.currency);
      }
      switch (txn.type) {
        case TxnType.expense:
          expense += txn.amountMinor;
        case TxnType.income:
          income += txn.amountMinor;
        case TxnType.transfer:
          transfer += txn.amountMinor;
          expense += txn.feeMinor;
          fee += txn.feeMinor;
      }
    }
    return LedgerSummary._(
      currency: currency ?? 'CNY',
      incomeMinor: income,
      expenseMinor: expense,
      transferMinor: transfer,
      feeMinor: fee,
    );
  }
}

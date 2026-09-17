/// 驱动：余额推演回放（§2.3 余额语义 + §7.2 验收口径，已实装，纯 Dart）。
///
/// ## 为什么余额推演值得向量
///
/// 缓存余额的正确性有三条独立路径在维护：仓储增量 SQL、全量重算 SQL、
/// 本驱动的纯函数回放。SQL 的执行语义要等 M2 真库才能验证，但**推演
/// 规则本身**（哪笔账对哪个账户加多少、手续费落在哪条腿、软删如何回退、
/// 信用卡为什么不需要特殊分支）是纯数据进出 —— 向量在这里锁死规则，
/// 规则一变（或 SQL 与规则漂移）三平台同时红。
///
/// 期望值来自 `tools/golden_vectors_gen/balance_replay.py`：Python 侧
/// 按 §2.3 的语义**独立实现**同一套推演（含 day_key/month_key 的
/// 日历拆解），与 Dart 侧 BalanceEngine / TxnTime 在向量处会合。
/// 这是 §7.6 第一条顺序原则的同类做法：两侧独立实现，一侧漂移即红。
library;

import 'package:pf_data/pf_data.dart';

import '../driver.dart';
import '../json_util.dart';
import '../outcome.dart';

/// 余额推演回放驱动。
final class DbBalanceReplayDriver extends VectorDriver {
  const DbBalanceReplayDriver();

  @override
  String get kind => 'db.balance.replay';

  @override
  String get description => '余额推演规则：支出/收入/转账双腿/手续费/软删回退/信用卡/统计口径/day_key 派生';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'accounts': '账户数组：{id, openingMinor, type?, creditLimitMinor?}',
    'ops': '操作数组：txn（记账）/ edit（编辑，整条新值）/ delete（软删）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final accountsIn = requireList(input, 'accounts', kind);
    final ops = requireList(input, 'ops', kind);

    final accountRows = <AccountRecord>[];
    for (final item in accountsIn) {
      if (item is! Map<String, Object?>) {
        throwVectorInput('$kind.accounts', '账户元素必须是对象，实际 ${item.runtimeType}');
      }
      final row = item;
      final id = requireString(row, 'id', '$kind.accounts.id');
      final creditLimit = optionalInt(row, 'creditLimitMinor', 0);
      accountRows.add(
        AccountRecord(
          id: id,
          ledgerId: testLedgerId,
          name: id,
          type: AccountType.fromValue(optionalInt(row, 'type', 2)),
          currency: 'CNY',
          openingBalanceMinor: requireInt(row, 'openingMinor', '$kind.accounts.openingMinor'),
          cachedBalanceMinor: 0,
          balanceAsOf: 0,
          creditLimitMinor: creditLimit == 0 ? null : creditLimit,
          createdAt: 0,
          updatedAt: 0,
          deviceId: 'vector',
        ),
      );
    }

    final live = <String, TxnRecord>{};
    final tombstones = <String, TxnRecord>{};
    final orderedIds = <String>[];

    for (final item in ops) {
      if (item is! Map<String, Object?>) {
        throwVectorInput('$kind.ops', '操作元素必须是对象，实际 ${item.runtimeType}');
      }
      final op = item;
      final name = requireString(op, 'op', '$kind.ops.op');
      switch (name) {
        case 'txn':
        case 'edit':
          final txn = _txnFrom(op);
          if (!live.containsKey(txn.id)) {
            orderedIds.add(txn.id);
          }
          live[txn.id] = txn;
          tombstones.remove(txn.id);
        case 'delete':
          final id = requireString(op, 'id', '$kind.ops.id');
          final txn = live.remove(id);
          if (txn == null) {
            throwVectorInput('$kind.ops.delete', '删除了不存在的交易：$id');
          }
          // 墓碑必须带 deleted_at，否则全量重算会把它当存活账目。
          tombstones[id] = _markDeleted(txn);
        default:
          throwVectorInput('$kind.ops.op', '未知操作：$name');
      }
    }

    final allTxns = <TxnRecord>[...orderedIds.map((id) => live[id] ?? tombstones[id]!)];
    final balances = BalanceEngine.recompute(
      accounts: <({String id, int openingBalanceMinor})>[
        for (final a in accountRows) (id: a.id, openingBalanceMinor: a.openingBalanceMinor),
      ],
      txns: allTxns,
    );
    final summary = LedgerSummary.summarize(allTxns);

    return VectorOutcome.value(<String, Object?>{
      'balances': <String, Object?>{
        for (final entry in balances.entries)
          entry.key: <String, Object?>{
            'balanceMinor': entry.value.balanceMinor,
            'balanceAsOf': entry.value.balanceAsOf,
          },
      },
      'summary': <String, Object?>{
        'incomeMinor': summary.incomeMinor,
        'expenseMinor': summary.expenseMinor,
        'transferMinor': summary.transferMinor,
        'feeMinor': summary.feeMinor,
      },
      'dayKeys': <Object?>[
        // 墓碑不参与 day_key 口径（与 Python 生成器一致：只看存活交易）。
        for (final id in orderedIds)
          if (live[id] != null)
            <String, Object?>{'id': id, 'dayKey': live[id]!.dayKey, 'monthKey': live[id]!.monthKey},
      ],
    });
  }

  /// 软删副本：deleted_at 置为原 updated_at（向量语义只要求非空）。
  TxnRecord _markDeleted(TxnRecord txn) => TxnRecord(
    id: txn.id,
    ledgerId: txn.ledgerId,
    type: txn.type,
    amountMinor: txn.amountMinor,
    currency: txn.currency,
    occurredAt: txn.occurredAt,
    tzOffsetMin: txn.tzOffsetMin,
    accountId: txn.accountId,
    toAccountId: txn.toAccountId,
    categoryId: txn.categoryId,
    merchant: txn.merchant,
    note: txn.note,
    tags: txn.tags,
    feeMinor: txn.feeMinor,
    isReimbursable: txn.isReimbursable,
    excludedFromStats: txn.excludedFromStats,
    sourceImportJob: txn.sourceImportJob,
    createdAt: txn.createdAt,
    updatedAt: txn.updatedAt,
    deletedAt: txn.updatedAt,
    deviceId: txn.deviceId,
    originDeviceId: txn.originDeviceId,
    rev: txn.rev + 1,
  );

  TxnRecord _txnFrom(Map<String, Object?> op) {
    final id = requireString(op, 'id', '$kind.ops.id');
    final type = TxnType.fromValue(requireInt(op, 'type', '$kind.ops.type'));
    return TxnRecord(
      id: id,
      ledgerId: testLedgerId,
      type: type,
      amountMinor: requireInt(op, 'amountMinor', '$kind.ops.amountMinor'),
      currency: 'CNY',
      occurredAt: requireInt(op, 'occurredAt', '$kind.ops.occurredAt'),
      tzOffsetMin: optionalInt(op, 'tzOffsetMin', 0),
      accountId: requireString(op, 'accountId', '$kind.ops.accountId'),
      toAccountId: op['toAccountId'] as String?,
      categoryId: type == TxnType.transfer ? null : 'cat-vector',
      feeMinor: optionalInt(op, 'feeMinor', 0),
      excludedFromStats: optionalBool(op, 'excludedFromStats', false),
      createdAt: 0,
      updatedAt: 0,
      deviceId: 'vector',
      originDeviceId: 'vector',
    );
  }
}

/// 向量共用的账本占位 ID（不参与余额语义，仅满足记录构造）。
const String testLedgerId = '01J8Z9K2M4P6Q8R0T2V4X6Z8B1';

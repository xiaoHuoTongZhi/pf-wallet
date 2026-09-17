import 'dart:math' as math;

import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';
import 'package:test/test.dart';

/// 固定时间轴：2026-09-01 起的毫秒步进。
const int _baseMs = 1789000000000;

TxnRecord _txn({
  required String id,
  required TxnType type,
  required int amountMinor,
  required String accountId,
  String? toAccountId,
  String? categoryId,
  int feeMinor = 0,
  int dayOffset = 0,
  bool excludedFromStats = false,
  int? occurredAt,
}) => TxnRecord(
  id: id,
  ledgerId: '01J8Z9K2M4P6Q8R0T2V4X6Z8B1',
  type: type,
  amountMinor: amountMinor,
  currency: 'CNY',
  occurredAt: occurredAt ?? _baseMs + dayOffset * 86400000,
  tzOffsetMin: 8 * 60,
  accountId: accountId,
  toAccountId: toAccountId,
  categoryId: categoryId ?? (type == TxnType.transfer ? null : '01JCATEGORY000000000000000A'),
  feeMinor: feeMinor,
  excludedFromStats: excludedFromStats,
  createdAt: _baseMs,
  updatedAt: _baseMs,
  deviceId: 'test-device',
  originDeviceId: 'test-device',
);

({String id, int openingBalanceMinor}) _account(String id, {int opening = 0}) => (
  id: id,
  openingBalanceMinor: opening,
);

void main() {
  group('BalanceEngine.effectOf · 单笔影响规则', () {
    test('支出：-amount', () {
      final effect = BalanceEngine.effectOf(type: TxnType.expense, amountMinor: 3000, feeMinor: 0);
      expect(effect.accountDelta, -3000);
      expect(effect.toAccountDelta, isNull);
      expect(effect.isTransferLeg, isFalse);
    });

    test('收入：+amount', () {
      final effect = BalanceEngine.effectOf(type: TxnType.income, amountMinor: 500000, feeMinor: 0);
      expect(effect.accountDelta, 500000);
    });

    test('转账：转出 -(amount+fee)，转入 +amount（§2.3 fee 由转出承担）', () {
      final effect = BalanceEngine.effectOf(
        type: TxnType.transfer,
        amountMinor: 10000,
        feeMinor: 200,
        toAccountId: 'to',
      );
      expect(effect.accountDelta, -10200);
      expect(effect.toAccountDelta, 10000);
      expect(effect.isTransferLeg, isTrue);
    });

    test('非转账带手续费 → 拒绝', () {
      expect(
        () => BalanceEngine.effectOf(type: TxnType.expense, amountMinor: 100, feeMinor: 5),
        throwsA(isA<DomainError>()),
      );
      expect(
        () => BalanceEngine.effectOf(type: TxnType.income, amountMinor: 100, feeMinor: 5),
        throwsA(isA<DomainError>()),
      );
    });

    test('金额非正 / 手续费为负 → 拒绝', () {
      expect(
        () => BalanceEngine.effectOf(type: TxnType.expense, amountMinor: 0, feeMinor: 0),
        throwsA(isA<DomainError>()),
      );
      expect(
        () => BalanceEngine.effectOf(type: TxnType.income, amountMinor: -1, feeMinor: 0),
        throwsA(isA<DomainError>()),
      );
      expect(
        () => BalanceEngine.effectOf(
          type: TxnType.transfer,
          amountMinor: 100,
          feeMinor: -1,
          toAccountId: 'to',
        ),
        throwsA(isA<DomainError>()),
      );
    });

    test('转账缺 toAccountId → 拒绝', () {
      expect(
        () => BalanceEngine.effectOf(type: TxnType.transfer, amountMinor: 100, feeMinor: 0),
        throwsA(isA<DomainError>()),
      );
    });
  });

  group('BalanceEngine.recompute · 全量重算', () {
    test('支出/收入/转账的聚合（含信用卡负债语义）', () {
      final cash = _ulid('acc-cash');
      final card = _ulid('acc-card');
      final balances = BalanceEngine.recompute(
        accounts: <({String id, int openingBalanceMinor})>[
          _account(cash, opening: 100000),
          _account(card),
        ],
        txns: <TxnRecord>[
          _txn(
            id: _ulid('1'),
            type: TxnType.expense,
            amountMinor: 3500,
            accountId: card,
          ), // 刷信用卡：余额 -35.00
          _txn(
            id: _ulid('2'),
            type: TxnType.income,
            amountMinor: 20000,
            accountId: cash,
            dayOffset: 1,
          ),
          _txn(
            id: _ulid('3'),
            type: TxnType.transfer,
            amountMinor: 5000,
            feeMinor: 100,
            accountId: cash,
            toAccountId: card,
            dayOffset: 2,
          ), // 还款
        ],
      );
      expect(balances[cash]!.balanceMinor, 100000 + 20000 - 5100, reason: '支出挂在信用卡上，现金只受收入与转出影响');
      expect(balances[card]!.balanceMinor, -3500 + 5000, reason: '信用卡消费使余额变小，还款使余额变大（§2.3）');
      expect(
        balances[cash]!.balanceAsOf,
        _baseMs + 2 * 86400000,
        reason: 'as_of = 该账户生效交易的 MAX(occurred_at)',
      );
    });

    test('净资产 = Σ 所有账户 cached_balance_minor（§2.1，信用卡自然抵减）', () {
      final cash = _ulid('acc-cash');
      final card = _ulid('acc-card');
      final balances = BalanceEngine.recompute(
        accounts: <({String id, int openingBalanceMinor})>[
          _account(cash, opening: 100000),
          _account(card),
        ],
        txns: <TxnRecord>[
          _txn(id: _ulid('1'), type: TxnType.expense, amountMinor: 3500, accountId: card),
        ],
      );
      final netWorth = LedgerSummary.netWorth(<AccountRecord>[
        _accountRecord(cash, cached: balances[cash]!.balanceMinor),
        _accountRecord(card, cached: balances[card]!.balanceMinor, isCredit: true),
      ]);
      expect(netWorth, 100000 - 3500);
    });

    test('软删的交易不参与推演（调用方过滤由记录的 isDeleted 表达）', () {
      const cash = '01JACCOUNTCASH0000000000000A';
      final deleted = TxnRecord(
        id: _ulid('9'),
        ledgerId: '01J8Z9K2M4P6Q8R0T2V4X6Z8B1',
        type: TxnType.expense,
        amountMinor: 999,
        currency: 'CNY',
        occurredAt: _baseMs,
        tzOffsetMin: 480,
        accountId: cash,
        categoryId: '01JCATEGORY000000000000000A',
        createdAt: _baseMs,
        updatedAt: _baseMs,
        deletedAt: _baseMs,
        deviceId: 'd',
        originDeviceId: 'd',
      );
      expect(deleted.isDeleted, isTrue);
      final balances = BalanceEngine.recompute(
        accounts: <({String id, int openingBalanceMinor})>[_account(cash, opening: 1000)],
        txns: <TxnRecord>[deleted],
      );
      expect(balances[cash]!.balanceMinor, 1000);
    });
  });

  group('LedgerSummary · 转账不进收支合计（§7.2）', () {
    test('转账本金只进 transfer，手续费进 expense', () {
      final summary = LedgerSummary.summarize(<TxnRecord>[
        _txn(id: _ulid('1'), type: TxnType.expense, amountMinor: 3000, accountId: 'a'),
        _txn(id: _ulid('2'), type: TxnType.income, amountMinor: 10000, accountId: 'a'),
        _txn(
          id: _ulid('3'),
          type: TxnType.transfer,
          amountMinor: 5000,
          feeMinor: 100,
          accountId: 'a',
          toAccountId: 'b',
        ),
      ]);
      expect(summary.incomeMinor, 10000);
      expect(summary.expenseMinor, 3100, reason: '支出 30.00 + 手续费 1.00；转账本金 50.00 绝不能混入');
      expect(summary.transferMinor, 5000);
      expect(summary.feeMinor, 100);
    });

    test('excluded_from_stats 跳过统计但仍影响余额', () {
      final excluded = _txn(
        id: _ulid('4'),
        type: TxnType.expense,
        amountMinor: 700,
        accountId: 'a',
        excludedFromStats: true,
      );
      final summary = LedgerSummary.summarize(<TxnRecord>[excluded]);
      expect(summary.expenseMinor, 0);
      // 余额推演不受 excluded_from_stats 影响（钱确实动了）。
      final balances = BalanceEngine.recompute(
        accounts: <({String id, int openingBalanceMinor})>[_account('a', opening: 1000)],
        txns: <TxnRecord>[excluded],
      );
      expect(balances['a']!.balanceMinor, 300);
    });

    test('币种混用 → PFC_E_CURRENCY_MISMATCH', () {
      final other = TxnRecord(
        id: _ulid('5'),
        ledgerId: '01J8Z9K2M4P6Q8R0T2V4X6Z8B1',
        type: TxnType.expense,
        amountMinor: 100,
        currency: 'USD',
        occurredAt: _baseMs,
        tzOffsetMin: 480,
        accountId: 'a',
        categoryId: 'c',
        createdAt: _baseMs,
        updatedAt: _baseMs,
        deviceId: 'd',
        originDeviceId: 'd',
      );
      expect(
        () => LedgerSummary.summarize(<TxnRecord>[
          _txn(id: _ulid('6'), type: TxnType.expense, amountMinor: 1, accountId: 'a'),
          other,
        ]),
        throwsA(
          isA<DomainError>().having((e) => e.code, 'code', PfErrorCode.moneyCurrencyMismatch),
        ),
      );
    });
  });

  group('TxnTime · 冗余列派生（§2.1 的关键设计）', () {
    test('UTC+8 的日/月键', () {
      // 2026-09-01 16:30:00Z = UTC+8 的 2026-09-02 00:30 —— 跨日边界。
      final ms = DateTime.utc(2026, 9, 1, 16, 30).millisecondsSinceEpoch;
      expect(TxnTime.dayKey(ms, 480), '2026-09-02');
      expect(TxnTime.monthKey(ms, 480), '2026-09');
    });

    test('负偏移同样按录入设备口径', () {
      // 2026-09-01 20:00:00Z = UTC-5 的 2026-09-01 15:00。
      final ms = DateTime.utc(2026, 9, 1, 20, 0).millisecondsSinceEpoch;
      expect(TxnTime.dayKey(ms, -300), '2026-09-01');
      // 2026-09-01 04:00:00Z = UTC-5 的 2026-08-31 23:00 —— 跨月边界。
      final ms2 = DateTime.utc(2026, 9, 1, 4, 0).millisecondsSinceEpoch;
      expect(TxnTime.dayKey(ms2, -300), '2026-08-31');
      expect(TxnTime.monthKey(ms2, -300), '2026-08');
    });

    test('偏移越界拒绝', () {
      expect(() => TxnTime.dayKey(_baseMs, 15 * 60), throwsA(isA<DomainError>()));
    });
  });

  group('随机 1000 笔操作 · 增量 == 全量（§7.2 验收口径）', () {
    test('固定种子回放：增量折叠与全量重算在每个检查点一致', () {
      const accountCount = 5;
      const opCount = 1000;
      const checkpointEvery = 100;
      const ledgerId = '01J8Z9K2M4P6Q8R0T2V4X6Z8B1';
      final random = math.Random(20260917);

      final accountIds = List<String>.generate(accountCount, (i) => _ulid('A$i'));
      final openings = <String, int>{for (final id in accountIds) id: random.nextInt(100000)};

      // 增量路径：直接折叠 effectOf（txn_repository 的 SQL 就是它的执行器）。
      final incremental = Map<String, int>.from(openings);

      // 全量路径的事实来源：全部交易（含软删标记）。
      final txns = <TxnRecord>[];

      String nextId() => _ulid(random.nextInt(0xFFFFFFF).toRadixString(36));

      for (var op = 0; op < opCount; op++) {
        final choice = random.nextInt(100);
        if (txns.isEmpty || choice < 55) {
          // 记一笔（支出 45% / 收入 30% / 转账 25%）。
          final roll = random.nextInt(100);
          final type =
              roll < 45 ? TxnType.expense : (roll < 75 ? TxnType.income : TxnType.transfer);
          final from = accountIds[random.nextInt(accountCount)];
          final to = accountIds[random.nextInt(accountCount)];
          final occurredAt = _baseMs + random.nextInt(365) * 86400000 + random.nextInt(86400000);
          final txn = TxnRecord(
            id: nextId(),
            ledgerId: ledgerId,
            type: type,
            amountMinor: 1 + random.nextInt(50000),
            currency: 'CNY',
            occurredAt: occurredAt,
            tzOffsetMin: 480,
            accountId: from,
            toAccountId:
                type == TxnType.transfer
                    ? (to == from ? accountIds[(accountIds.indexOf(to) + 1) % accountCount] : to)
                    : null,
            categoryId: type == TxnType.transfer ? null : '01JCATEGORY000000000000000A',
            feeMinor: type == TxnType.transfer && random.nextBool() ? random.nextInt(500) : 0,
            createdAt: _baseMs,
            updatedAt: _baseMs,
            deviceId: 'test-device',
            originDeviceId: 'test-device',
          );
          txns.add(txn);
          _applyEffect(incremental, txn, sign: 1);
        } else if (choice < 75) {
          // 编辑：金额/方向变化（含类型切换；转账↔收支切换覆盖账户变更路径）。
          final live = txns.where((t) => !t.isDeleted).toList();
          final target = live[random.nextInt(live.length)];
          final index = txns.indexOf(target);
          final type = TxnType.values[random.nextInt(3)];
          final from = accountIds[random.nextInt(accountCount)];
          var to = accountIds[random.nextInt(accountCount)];
          if (from == to) {
            to = accountIds[(accountIds.indexOf(to) + 1) % accountCount];
          }
          final edited = TxnRecord(
            id: target.id,
            ledgerId: ledgerId,
            type: type,
            amountMinor: 1 + random.nextInt(50000),
            currency: 'CNY',
            occurredAt: target.occurredAt + 86400000,
            tzOffsetMin: 480,
            accountId: from,
            toAccountId: type == TxnType.transfer ? to : null,
            categoryId: type == TxnType.transfer ? null : '01JCATEGORY000000000000000A',
            feeMinor: type == TxnType.transfer && random.nextBool() ? random.nextInt(500) : 0,
            createdAt: target.createdAt,
            updatedAt: target.updatedAt + 1,
            deviceId: 'test-device',
            originDeviceId: target.originDeviceId,
            rev: target.rev + 1,
          );
          txns[index] = edited;
          _applyEffect(incremental, target, sign: -1);
          _applyEffect(incremental, edited, sign: 1);
        } else if (choice < 90) {
          // 软删。
          final live = txns.where((t) => !t.isDeleted).toList();
          final target = live[random.nextInt(live.length)];
          final index = txns.indexOf(target);
          txns[index] = TxnRecord(
            id: target.id,
            ledgerId: target.ledgerId,
            type: target.type,
            amountMinor: target.amountMinor,
            currency: target.currency,
            occurredAt: target.occurredAt,
            tzOffsetMin: target.tzOffsetMin,
            accountId: target.accountId,
            toAccountId: target.toAccountId,
            categoryId: target.categoryId,
            merchant: target.merchant,
            note: target.note,
            tags: target.tags,
            feeMinor: target.feeMinor,
            isReimbursable: target.isReimbursable,
            excludedFromStats: target.excludedFromStats,
            sourceImportJob: target.sourceImportJob,
            createdAt: target.createdAt,
            updatedAt: target.updatedAt + 1,
            deletedAt: target.updatedAt + 1,
            deviceId: target.deviceId,
            originDeviceId: target.originDeviceId,
            rev: target.rev + 1,
          );
          _applyEffect(incremental, target, sign: -1);
        } else {
          // 不操作，只做检查点（保证至少 1000 笔操作里插入多个检查点）。
        }

        if ((op + 1) % checkpointEvery == 0) {
          final full = BalanceEngine.recompute(
            accounts: <({String id, int openingBalanceMinor})>[
              for (final id in accountIds) _account(id, opening: openings[id]!),
            ],
            txns: txns,
          );
          for (final id in accountIds) {
            expect(incremental[id], full[id]!.balanceMinor, reason: '检查点 $op：账户 $id 增量 != 全量');
          }
        }
      }

      // 终点：检查点恰好覆盖每 100 笔（含第 1000 笔）。
      final full = BalanceEngine.recompute(
        accounts: <({String id, int openingBalanceMinor})>[
          for (final id in accountIds) _account(id, opening: openings[id]!),
        ],
        txns: txns,
      );
      for (final id in accountIds) {
        expect(incremental[id], full[id]!.balanceMinor);
      }
      expect(txns.length, greaterThanOrEqualTo(400), reason: '1000 次操作里应产生足量交易');
    });
  });
}

/// 增量路径的折叠器：txn_repository._applyEffect 的余额部分直译。
/// 两者必须保持逐字对应 —— SQL 侧的任何规则改动都要同步到这里，
/// 并由随机回放与向量共同验证。
/// （balance_as_of 不在此折叠：SQL 侧每次按存活账目重算，
/// 与全量重算口径恒等，无需在增量侧重复维护。）
void _applyEffect(Map<String, int> balances, TxnRecord txn, {required int sign}) {
  final effect = BalanceEngine.effectOfRecord(txn);
  balances.update(
    txn.accountId,
    (v) => v + sign * effect.accountDelta,
    ifAbsent: () => sign * effect.accountDelta,
  );
  final toDelta = effect.toAccountDelta;
  if (toDelta != null) {
    final toId = txn.toAccountId!;
    balances.update(toId, (v) => v + sign * toDelta, ifAbsent: () => sign * toDelta);
  }
}

AccountRecord _accountRecord(String id, {required int cached, bool isCredit = false}) =>
    AccountRecord(
      id: id,
      ledgerId: '01J8Z9K2M4P6Q8R0T2V4X6Z8B1',
      name: '测试账户',
      type: isCredit ? AccountType.creditCard : AccountType.savingsCard,
      currency: 'CNY',
      openingBalanceMinor: 0,
      cachedBalanceMinor: cached,
      balanceAsOf: 0,
      creditLimitMinor: isCredit ? 50000 : null,
      createdAt: _baseMs,
      updatedAt: _baseMs,
      deviceId: 'd',
    );

/// 从种子生成确定性的"类 ULID"标识（向量/测试专用，不进生产路径）。
String _ulid(String suffix) {
  final base = '01J8Z9K2M4P6Q8R0T2V4X6Z8B1'.split('');
  const chars = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  var hash = 0;
  for (final unit in suffix.codeUnits) {
    hash = (hash * 31 + unit) & 0x7FFFFFFF;
  }
  for (var i = 0; i < suffix.length && i < base.length; i++) {
    base[i] = chars[(suffix.codeUnitAt(i) + i) % chars.length];
  }
  for (var i = base.length - 1; i >= 0 && hash > 0; i--) {
    base[i] = chars[hash % chars.length];
    hash ~/= chars.length;
  }
  return base.join();
}

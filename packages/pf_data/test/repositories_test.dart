import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';
import 'package:test/test.dart';

import 'recording_db.dart';

const String _ledger = '01J8Z9K2M4P6Q8R0T2V4X6Z8B1';
const int _baseMs = 1789000000000;

TxnRecord _txn({
  required String id,
  required TxnType type,
  required int amountMinor,
  required String accountId,
  String? toAccountId,
  int feeMinor = 0,
}) => TxnRecord(
  id: id,
  ledgerId: _ledger,
  type: type,
  amountMinor: amountMinor,
  currency: 'CNY',
  occurredAt: _baseMs,
  tzOffsetMin: 480,
  accountId: accountId,
  toAccountId: toAccountId,
  categoryId: type == TxnType.transfer ? null : testUlid('cat-default'),
  feeMinor: feeMinor,
  createdAt: _baseMs,
  updatedAt: _baseMs,
  deviceId: 'device-a',
  originDeviceId: 'device-a',
);

void main() {
  group('SqlTxnRepository.create · 事务内双腿推演', () {
    test('支出：INSERT + 单腿余额 UPDATE，包在一个事务里', () async {
      final db = RecordingDb(
        canned: <String, List<Map<String, Object?>>>{
          'SELECT currency, deleted_at FROM account': <Map<String, Object?>>[
            {'currency': 'CNY', 'deleted_at': null},
          ],
          'SELECT deleted_at FROM category': <Map<String, Object?>>[
            {'deleted_at': null},
          ],
          'SELECT id, ledger_id, type, amount_minor': const <Map<String, Object?>>[],
        },
      );
      final repo = SqlTxnRepository(db);
      final txn = _txn(
        id: testUlid('txn-expense'),
        type: TxnType.expense,
        amountMinor: 3500,
        accountId: 'acc-cash',
      );

      await repo.create(txn);

      expect(db.transactionLog, <String>['BEGIN', 'COMMIT']);
      final insertIdx = db.statements.indexWhere((s) => s.startsWith('INSERT INTO txn'));
      final updateIdx = db.statements.indexWhere((s) => s.startsWith('UPDATE account'));
      expect(insertIdx, greaterThanOrEqualTo(0));
      expect(updateIdx, greaterThan(insertIdx), reason: '先写账目、后更新余额（同一事务）');

      final update = db.statements[updateIdx];
      expect(update, contains('cached_balance_minor = cached_balance_minor + ?'));
      expect(update, contains('SELECT MAX(occurred_at) FROM txn'), reason: 'as_of 按存活账目全量口径重算');
      // 刻意不碰同步元数据。
      expect(update, isNot(contains('updated_at')), reason: '余额缓存不参与同步判决');
      expect(update, isNot(contains('rev')));
      // 参数：-3500（支出）、as_of 子查询账户 ×2、WHERE 账户。
      final args = db.argumentsOf(updateIdx);
      expect(args, <Object?>[-3500, 'acc-cash', 'acc-cash', 'acc-cash']);
    });

    test('转账：两条腿各一条 UPDATE（转出含手续费）', () async {
      final db = RecordingDb(
        canned: <String, List<Map<String, Object?>>>{
          'SELECT currency, deleted_at FROM account': <Map<String, Object?>>[
            {'currency': 'CNY', 'deleted_at': null},
          ],
          'SELECT id, ledger_id, type, amount_minor': const <Map<String, Object?>>[],
        },
      );
      final repo = SqlTxnRepository(db);
      await repo.create(
        _txn(
          id: testUlid('txn-transfer'),
          type: TxnType.transfer,
          amountMinor: 10000,
          feeMinor: 200,
          accountId: 'acc-a',
          toAccountId: 'acc-b',
        ),
      );

      final updates = <List<Object?>>[
        for (var i = 0; i < db.statements.length; i++)
          if (db.statements[i].startsWith('UPDATE account')) db.argumentsOf(i),
      ];
      expect(updates, hasLength(2));
      expect(updates[0], <Object?>[-10200, 'acc-a', 'acc-a', 'acc-a'], reason: '转出腿含手续费');
      expect(updates[1], <Object?>[10000, 'acc-b', 'acc-b', 'acc-b'], reason: '转入腿只有本金');
    });

    test('账户已删除 → 拒绝且不写任何语句', () async {
      final db = RecordingDb(
        canned: <String, List<Map<String, Object?>>>{
          'SELECT currency, deleted_at FROM account': <Map<String, Object?>>[
            {'currency': 'CNY', 'deleted_at': _baseMs},
          ],
        },
      );
      final repo = SqlTxnRepository(db);
      await expectLater(
        repo.create(
          _txn(
            id: testUlid('txn-dead'),
            type: TxnType.expense,
            amountMinor: 100,
            accountId: 'acc-dead',
          ),
        ),
        throwsA(isA<DomainError>()),
      );
      expect(db.statements.where((s) => s.startsWith('INSERT INTO txn')), isEmpty);
      expect(db.transactionLog, <String>['BEGIN', 'ROLLBACK']);
    });

    test('余额 UPDATE 的 WHERE 只有 id —— 不过滤账户 deleted_at（§4.4 S16/S18）', () async {
      final db = RecordingDb(
        canned: <String, List<Map<String, Object?>>>{
          'SELECT currency, deleted_at FROM account': <Map<String, Object?>>[
            {'currency': 'CNY', 'deleted_at': null},
          ],
          'SELECT deleted_at FROM category': <Map<String, Object?>>[
            {'deleted_at': null},
          ],
          'SELECT id, ledger_id, type, amount_minor': const <Map<String, Object?>>[],
        },
      );
      final repo = SqlTxnRepository(db);
      await repo.create(
        _txn(
          id: testUlid('txn-tombacc'),
          type: TxnType.expense,
          amountMinor: 3500,
          accountId: 'acc-cash',
        ),
      );

      final update = db.statements.singleWhere((s) => s.startsWith('UPDATE account'));
      // SQL 里唯一的 deleted_at 是 as_of 子查询对 **txn 表**的过滤；
      // 对 account 的 WHERE 必须只有 id —— 软删账户的余额也要继续被
      // 推演更新（S16/S18：账户删了交易还在，导入合并的一致性校验
      // 「Σ账户余额 == opening + Σ交易影响」要求它的缓存不能失真）。
      expect(update, contains('WHERE id = ?'));
      final accountWhere = update.lastIndexOf('WHERE id = ?');
      expect(
        update.indexOf('deleted_at'),
        lessThan(accountWhere),
        reason: 'deleted_at 只允许出现在 txn 子查询里，不得进入 account 的 WHERE',
      );
    });

    test('币种不一致 → PFC_E_CURRENCY_MISMATCH', () async {
      final db = RecordingDb(
        canned: <String, List<Map<String, Object?>>>{
          'SELECT currency, deleted_at FROM account': <Map<String, Object?>>[
            {'currency': 'USD', 'deleted_at': null},
          ],
        },
      );
      final repo = SqlTxnRepository(db);
      await expectLater(
        repo.create(
          _txn(
            id: testUlid('txn-usd'),
            type: TxnType.expense,
            amountMinor: 100,
            accountId: 'acc-usd',
          ),
        ),
        throwsA(
          isA<DomainError>().having((e) => e.code, 'code', PfErrorCode.moneyCurrencyMismatch),
        ),
      );
    });

    test('收支缺分类 → 校验失败发生在任何 SQL 之前', () async {
      final db = RecordingDb();
      final repo = SqlTxnRepository(db);
      await expectLater(
        repo.create(
          TxnRecord(
            id: testUlid('txn-nocat'),
            ledgerId: _ledger,
            type: TxnType.expense,
            amountMinor: 100,
            currency: 'CNY',
            occurredAt: _baseMs,
            tzOffsetMin: 480,
            accountId: 'acc-a',
            createdAt: _baseMs,
            updatedAt: _baseMs,
            deviceId: 'device-a',
            originDeviceId: 'device-a',
          ),
        ),
        throwsA(isA<DomainError>()),
      );
      expect(db.statements, isEmpty, reason: 'validate() 在 INSERT 之前');
    });
  });

  group('SqlTxnRepository.update · 旧值回退 + 新值施加', () {
    test('改金额：同账户净差值（两条 UPDATE）', () async {
      final old = _txn(
        id: testUlid('txn-edit'),
        type: TxnType.expense,
        amountMinor: 3000,
        accountId: 'acc-a',
      );
      final db = RecordingDb(
        canned: <String, List<Map<String, Object?>>>{
          'SELECT id, ledger_id, type, amount_minor': <Map<String, Object?>>[old.toRow()],
          'SELECT currency, deleted_at FROM account': <Map<String, Object?>>[
            {'currency': 'CNY', 'deleted_at': null},
          ],
          'SELECT deleted_at FROM category': <Map<String, Object?>>[
            {'deleted_at': null},
          ],
        },
      );
      final repo = SqlTxnRepository(db);
      await repo.update(
        _txn(id: old.id, type: TxnType.expense, amountMinor: 5000, accountId: 'acc-a'),
      );

      final updateArgs = <List<Object?>>[
        for (var i = 0; i < db.statements.length; i++)
          if (db.statements[i].startsWith('UPDATE account')) db.argumentsOf(i),
      ];
      expect(updateArgs, hasLength(2));
      expect(updateArgs[0][0], 3000, reason: '回退旧值：-(-3000)');
      expect(updateArgs[1][0], -5000, reason: '施加新值：-(5000)');
    });

    test('支出改转账：旧账户回退 + 新账户双腿施加（三个账户触达）', () async {
      final old = _txn(
        id: testUlid('txn-retype'),
        type: TxnType.expense,
        amountMinor: 3000,
        accountId: 'acc-a',
      );
      final db = RecordingDb(
        canned: <String, List<Map<String, Object?>>>{
          'SELECT id, ledger_id, type, amount_minor': <Map<String, Object?>>[old.toRow()],
          'SELECT currency, deleted_at FROM account': <Map<String, Object?>>[
            {'currency': 'CNY', 'deleted_at': null},
          ],
        },
      );
      final repo = SqlTxnRepository(db);
      await repo.update(
        _txn(
          id: old.id,
          type: TxnType.transfer,
          amountMinor: 3000,
          accountId: 'acc-b',
          toAccountId: 'acc-c',
        ),
      );

      final updateArgs = <List<Object?>>[
        for (var i = 0; i < db.statements.length; i++)
          if (db.statements[i].startsWith('UPDATE account')) db.argumentsOf(i),
      ];
      expect(updateArgs, hasLength(3));
      expect(updateArgs[0], <Object?>[3000, 'acc-a', 'acc-a', 'acc-a'], reason: '旧账户回退');
      expect(updateArgs[1], <Object?>[-3000, 'acc-b', 'acc-b', 'acc-b'], reason: '新转出腿');
      expect(updateArgs[2], <Object?>[3000, 'acc-c', 'acc-c', 'acc-c'], reason: '新转入腿');
    });
  });

  group('SqlTxnRepository.softDelete · 幂等 + 回退', () {
    test('软删回退余额影响', () async {
      final old = _txn(
        id: testUlid('txn-del'),
        type: TxnType.expense,
        amountMinor: 3000,
        accountId: 'acc-a',
      );
      final db = RecordingDb(
        canned: <String, List<Map<String, Object?>>>{
          'SELECT id, ledger_id, type, amount_minor': <Map<String, Object?>>[old.toRow()],
        },
      );
      final repo = SqlTxnRepository(db);
      await repo.softDelete(old.id, atMs: _baseMs + 1);

      final updateArgs = <List<Object?>>[
        for (var i = 0; i < db.statements.length; i++)
          if (db.statements[i].startsWith('UPDATE account')) db.argumentsOf(i),
      ];
      expect(updateArgs, <List<Object?>>[
        <Object?>[3000, 'acc-a', 'acc-a', 'acc-a'],
      ], reason: '回退支出：-(-3000)');
      expect(db.statements.where((s) => s.startsWith('UPDATE txn SET deleted_at')), isNotEmpty);
    });

    test('重复软删是空操作（墓碑不重复立）', () async {
      final tombstone = TxnRecord(
        id: testUlid('txn-tomb'),
        ledgerId: _ledger,
        type: TxnType.expense,
        amountMinor: 100,
        currency: 'CNY',
        occurredAt: _baseMs,
        tzOffsetMin: 480,
        accountId: 'acc-a',
        categoryId: testUlid('cat-default'),
        createdAt: _baseMs,
        updatedAt: _baseMs,
        deletedAt: _baseMs,
        deviceId: 'device-a',
        originDeviceId: 'device-a',
      );
      final db = RecordingDb(
        canned: <String, List<Map<String, Object?>>>{
          'SELECT id, ledger_id, type, amount_minor': <Map<String, Object?>>[tombstone.toRow()],
        },
      );
      final repo = SqlTxnRepository(db);
      await repo.softDelete(tombstone.id, atMs: _baseMs + 1);
      expect(db.statements.where((s) => s.startsWith('UPDATE')), isEmpty);
    });
  });

  group('SqlAccountRepository · 初始余额与软删拦截', () {
    test('update 平移 opening：缓存差值进入参数', () async {
      final old = _accountRow(cached: 97000, opening: 100000);
      final db = RecordingDb(
        canned: <String, List<Map<String, Object?>>>{
          'SELECT id, ledger_id, name, type': <Map<String, Object?>>[old],
        },
      );
      final repo = SqlAccountRepository(db);
      final next = AccountRecord.fromRow(old);
      final updated = AccountRecord(
        id: next.id,
        ledgerId: next.ledgerId,
        name: '现金',
        type: next.type,
        currency: next.currency,
        openingBalanceMinor: 120000,
        cachedBalanceMinor: next.cachedBalanceMinor,
        balanceAsOf: next.balanceAsOf,
        createdAt: next.createdAt,
        updatedAt: next.updatedAt + 1,
        deviceId: 'device-a',
        rev: next.rev + 1,
      );
      await repo.update(updated);

      final updateIdx = db.statements.indexWhere((s) => s.startsWith('UPDATE account SET name'));
      expect(updateIdx, greaterThanOrEqualTo(0));
      final args = db.argumentsOf(updateIdx);
      expect(args, contains(20000), reason: 'opening +20000 ⇒ 缓存平移 +20000');
      final update = db.statements[updateIdx];
      expect(update, contains('cached_balance_minor = cached_balance_minor + ?'));
    });

    test('有生效交易 → 拒绝软删（§7.2：删除被引用的账户 → 拦住）', () async {
      final db = RecordingDb(
        canned: <String, List<Map<String, Object?>>>{
          'SELECT id, ledger_id, name, type': <Map<String, Object?>>[
            _accountRow(cached: 0, opening: 0),
          ],
          'SELECT COUNT(*) AS n FROM txn': <Map<String, Object?>>[
            {'n': 3},
          ],
        },
      );
      final repo = SqlAccountRepository(db);
      await expectLater(
        repo.softDelete(testUlid('acc-a'), atMs: _baseMs),
        throwsA(isA<DomainError>().having((e) => e.userMessage, 'userMessage', contains('3'))),
      );
      expect(db.statements.where((s) => s.startsWith('UPDATE account SET deleted_at')), isEmpty);
    });

    test('软删按两条腿计数（转入也算被引用）', () async {
      final db = RecordingDb(
        canned: <String, List<Map<String, Object?>>>{
          'SELECT id, ledger_id, name, type': <Map<String, Object?>>[
            _accountRow(cached: 0, opening: 0),
          ],
          'SELECT COUNT(*) AS n FROM txn': <Map<String, Object?>>[
            {'n': 0},
          ],
        },
      );
      final repo = SqlAccountRepository(db);
      await repo.softDelete(testUlid('acc-a'), atMs: _baseMs);
      final countSql = db.statements.singleWhere((s) => s.startsWith('SELECT COUNT(*)'));
      expect(countSql, contains('account_id = ? OR to_account_id = ?'));
    });
  });

  group('BalanceRecalculator · 全量重算语句', () {
    test('聚合语句覆盖三条腿且与 effectOf 规则对应', () async {
      final db = RecordingDb();
      await BalanceRecalculator.run(db);
      expect(db.statements, <String>[
        BalanceRecalculator.recalcStatement,
        BalanceRecalculator.resetStatement,
      ]);
      const recalc = BalanceRecalculator.recalcStatement;
      expect(
        recalc,
        contains('SELECT account_id AS id, -(amount_minor + fee_minor) AS d'),
        reason: '支出/转出腿含手续费',
      );
      expect(recalc, contains('SELECT to_account_id AS id, amount_minor AS d'), reason: '转入腿');
      expect(
        recalc,
        contains('cached_balance_minor = opening_balance_minor + COALESCE(agg.delta, 0)'),
      );
      const reset = BalanceRecalculator.resetStatement;
      expect(reset, contains('cached_balance_minor = opening_balance_minor'));
      expect(reset, contains('to_account_id IS NOT NULL'), reason: 'NULL 腿不得混入 NOT IN');
    });
  });
}

Map<String, Object?> _accountRow({required int cached, required int opening}) => <String, Object?>{
  'id': testUlid('acc-a'),
  'ledger_id': _ledger,
  'name': '现金',
  'type': 2,
  'currency': 'CNY',
  'opening_balance_minor': opening,
  'cached_balance_minor': cached,
  'balance_as_of': _baseMs,
  'credit_limit_minor': null,
  'statement_day': null,
  'due_day': null,
  'repay_account_id': null,
  'icon': null,
  'color': null,
  'is_archived': 0,
  'sort_order': 0,
  'note': null,
  'created_at': _baseMs,
  'updated_at': _baseMs,
  'deleted_at': null,
  'device_id': 'device-a',
  'rev': 1,
};

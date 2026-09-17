import 'package:pf_data/pf_data.dart';
import 'package:test/test.dart';

void main() {
  group('schema v1 · 结构契约', () {
    test('版本号与描述', () {
      expect(schemaV1Migration.version, 1);
      expect(() => schemaV1Migration.validate(), returnsNormally);
      expect(schemaV1Migration.statements, isNotEmpty);
    });

    test('checksum 是稳定的 sha256（R4：改历史必留痕）', () {
      final checksum = migrationChecksum(schemaV1Migration);
      expect(checksum, hasLength(64));
      expect(checksum, matches(RegExp(r'^[0-9a-f]{64}$')));
      // 与重算值一致（同一函数，重复求值必须相同）。
      expect(migrationChecksum(schemaV1Migration), checksum);
    });

    test('建表顺序满足外键引用（ledger → account → txn）', () {
      final statements = schemaV1Migration.statements;
      int indexOfCreate(String table) => statements.indexWhere(
        (s) => s.startsWith('CREATE TABLE $table ') || s.startsWith('CREATE VIRTUAL TABLE $table '),
      );
      final ledger = indexOfCreate('ledger');
      final account = indexOfCreate('account');
      final category = indexOfCreate('category');
      final txn = indexOfCreate('txn');
      expect(ledger, greaterThanOrEqualTo(0));
      expect(account, greaterThan(ledger), reason: 'account 引用 ledger');
      expect(txn, greaterThan(account), reason: 'txn 引用 account/category');
      expect(category, greaterThan(ledger));
      expect(indexOfCreate('txn_fts'), greaterThan(txn), reason: 'FTS 触发器引用 txn');
    });

    test('全部实体表都是 WITHOUT ROWID（TEXT 主键表，§2.1）', () {
      final withoutRowid =
          schemaV1Migration.statements
              .where((s) => s.startsWith('CREATE TABLE'))
              .where((s) => s.contains('WITHOUT ROWID'))
              .toList();
      // 实体表 8 张（ledger/account/category/txn/tag/budget/attachment/theme_profile）
      // + 元信息 5 张（app_meta/import_job/imported_file/conflict/sync_peer）。
      expect(withoutRowid.length, 13);
      // change_log 需要 AUTOINCREMENT（本机单调游标），schema_migration 是
      // INTEGER 主键 —— 两张**必须不是** WITHOUT ROWID。
      final withRowid =
          schemaV1Migration.statements
              .where((s) => s.startsWith('CREATE TABLE') && !s.contains('WITHOUT ROWID'))
              .toList();
      expect(withRowid, hasLength(2));
      expect(withRowid.any((s) => s.contains('change_log')), isTrue);
      expect(withRowid.any((s) => s.contains('schema_migration')), isTrue);
    });

    test('FTS5 按 §2.6 方案 A（独立表 + 触发器，不用外部内容模式）', () {
      final statements = schemaV1Migration.statements;
      expect(
        statements.any((s) => s.contains("content='txn'")),
        isFalse,
        reason: '§2.6 指出的 bug：WITHOUT ROWID 无 rowid',
      );
      expect(statements.where((s) => s.contains('txn_fts')), isNotEmpty);
      expect(statements.any((s) => s.startsWith('CREATE TRIGGER trg_txn_fts_ai')), isTrue);
      expect(statements.any((s) => s.startsWith('CREATE TRIGGER trg_txn_fts_au')), isTrue);
      expect(statements.any((s) => s.startsWith('CREATE TRIGGER trg_txn_fts_ad')), isTrue);
    });

    test('txn 的转账语义被 CHECK 钉死（§2.3）', () {
      final txnDdl = schemaV1Migration.statements.singleWhere(
        (s) => s.startsWith('CREATE TABLE txn '),
      );
      expect(
        txnDdl,
        contains(
          'CHECK (type <> 3 OR (to_account_id IS NOT NULL AND to_account_id <> account_id))',
        ),
      );
      expect(txnDdl, contains('CHECK (type = 3 OR to_account_id IS NULL)'));
      expect(txnDdl, contains('CHECK (type = 3 OR category_id IS NOT NULL)'));
      expect(txnDdl, contains('CHECK (amount_minor > 0)'));
      expect(txnDdl, contains('CHECK (json_valid(tags))'));
    });

    test('account 的余额语义列齐全（§2.3）', () {
      final accountDdl = schemaV1Migration.statements.singleWhere(
        (s) => s.startsWith('CREATE TABLE account '),
      );
      for (final column in [
        'opening_balance_minor',
        'cached_balance_minor',
        'balance_as_of',
        'credit_limit_minor',
        'repay_account_id',
      ]) {
        expect(accountDdl, contains(column));
      }
      expect(accountDdl, contains('CHECK (type <> 3 OR credit_limit_minor IS NOT NULL)'));
    });

    test('迁移注册表：只有 v1，且就是 schemaV1Migration', () {
      expect(kRegisteredMigrations, hasLength(1));
      expect(kRegisteredMigrations.single, same(schemaV1Migration));
    });

    test('PRAGMA foreign_keys 不在语句列表里（执行器职责）', () {
      expect(schemaV1Migration.statements.any((s) => s.contains('PRAGMA')), isFalse);
    });
  });
}

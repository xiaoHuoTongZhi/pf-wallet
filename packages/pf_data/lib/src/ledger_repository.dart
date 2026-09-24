/// 账本仓储：根实体的 CRUD + 软删。
///
/// ## 为什么它到这一笔才出现
///
/// 账本是所有业务实体的挂载点（§2.2：一切业务记录都带 `ledger_id`），
/// 但 M1 之前的几条命令都是**只读**的（`info` / `verify`）或只读向量驱动的，
/// 从来没有人需要新建一个账本 —— 于是它一直只有 DDL 没有仓储。
/// `pf seed` 是本仓第一个需要写账本的地方（它要造一份可导出、可往返的样本），
/// 这个缺口因此暴露出来。
///
/// ## 两个唯一约束都要有可读的前置校验
///
/// `ux_ledger_default`（至多一个未删除的默认账本）与 `code` 的唯一性都由
/// DDL 兜底，但裸的 SQL 报错对调用方没有指导意义（`UNIQUE constraint failed:
/// ledger.code` 不会告诉用户「换一个短码」）。因此这里先查一次，
/// 抛出带 `userMessage` 的领域错误 —— 与 `SqlCategoryRepository` 对
/// 「分类最多两级」的处理同一条思路。
library;

import 'package:pf_core/pf_core.dart';

import 'db.dart';
import 'entities.dart';

/// 账本仓储。
abstract interface class LedgerRepository {
  Future<void> create(LedgerRecord ledger);
  Future<LedgerRecord?> byId(String id);

  /// 按短码查（含已软删的行）。
  ///
  /// 「含已软删」是刻意的：`code` 的唯一约束**不带** `deleted_at IS NULL`
  /// 条件（`code TEXT NOT NULL UNIQUE`），所以一个软删的账本仍然占着它的短码。
  /// 只查未删除的行会让调用方以为这个短码可用，然后在写入时撞上约束 ——
  /// 那是一个本可以在这一层说清楚的失败。
  Future<LedgerRecord?> byCode(String code);

  /// 全部未删除账本（默认账本在前，然后按 sort_order, id）。
  Future<List<LedgerRecord>> listAll();

  /// 全量更新（记录为完整新值）。
  Future<void> update(LedgerRecord ledger);

  /// 软删。[atMs] 为本次操作的 epoch 毫秒。
  ///
  /// 账本下还有未删除的账户或交易时拒绝 —— 软删一个还有数据的账本，
  /// 会让那些记录挂在一个已删除的父实体上，而引用规则表里
  /// `txn.ledger_id → ledger` 是**修不了**的那一类悬空（§4.4：
  /// 没有可凭空编造的 `ledger.code`，因此导入整体回滚）。
  Future<void> softDelete(String id, {required int atMs});
}

final class SqlLedgerRepository implements LedgerRepository {
  SqlLedgerRepository(this.db);

  final PfDb db;

  static const String _columns =
      'id, name, code, currency, is_default, sort_order, '
      'created_at, updated_at, deleted_at, device_id, rev';

  @override
  Future<void> create(LedgerRecord ledger) async {
    if (await byId(ledger.id) != null) {
      throw DomainError.validation(detail: '账本已存在：${ledger.id}', userMessage: '这个账本已经存在，请勿重复创建。');
    }
    final occupied = await byCode(ledger.code);
    if (occupied != null) {
      throw DomainError.validation(
        detail: '账本短码被占用：${ledger.code}（已属于 ${occupied.id}）',
        userMessage: '这个账本短码已经被用过了，请换一个。',
      );
    }
    if (ledger.isDefault) {
      final existing = await _defaultLedger();
      if (existing != null) {
        throw DomainError.validation(
          detail: '已存在默认账本：${existing.id}',
          userMessage: '已经有一个默认账本了，请先取消它再设置新的。',
        );
      }
    }
    await db.run(
      'INSERT INTO ledger ($_columns) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
      arguments: ledger.toRow().values.toList(),
    );
  }

  @override
  Future<LedgerRecord?> byId(String id) async {
    final rows = await db.query(
      'SELECT $_columns FROM ledger WHERE id = ?',
      arguments: <Object?>[id],
    );
    return rows.isEmpty ? null : LedgerRecord.fromRow(rows.single);
  }

  @override
  Future<LedgerRecord?> byCode(String code) async {
    final rows = await db.query(
      'SELECT $_columns FROM ledger WHERE code = ?',
      arguments: <Object?>[code],
    );
    return rows.isEmpty ? null : LedgerRecord.fromRow(rows.single);
  }

  @override
  Future<List<LedgerRecord>> listAll() async {
    final rows = await db.query(
      'SELECT $_columns FROM ledger WHERE deleted_at IS NULL '
      'ORDER BY is_default DESC, sort_order, id',
    );
    return rows.map(LedgerRecord.fromRow).toList(growable: false);
  }

  @override
  Future<void> update(LedgerRecord ledger) async {
    final old = await byId(ledger.id);
    if (old == null) {
      throw DomainError.validation(detail: '账本不存在：${ledger.id}');
    }
    if (ledger.code != old.code) {
      final occupied = await byCode(ledger.code);
      if (occupied != null) {
        throw DomainError.validation(
          detail: '账本短码被占用：${ledger.code}（已属于 ${occupied.id}）',
          userMessage: '这个账本短码已经被用过了，请换一个。',
        );
      }
    }
    if (ledger.isDefault && !old.isDefault) {
      final existing = await _defaultLedger();
      if (existing != null) {
        throw DomainError.validation(
          detail: '已存在默认账本：${existing.id}',
          userMessage: '已经有一个默认账本了，请先取消它再设置新的。',
        );
      }
    }
    await db.run(
      'UPDATE ledger SET name = ?, code = ?, currency = ?, is_default = ?, sort_order = ?, '
      'updated_at = ?, deleted_at = ?, device_id = ?, rev = ? WHERE id = ?',
      arguments: <Object?>[
        ledger.name,
        ledger.code,
        ledger.currency,
        ledger.isDefault ? 1 : 0,
        ledger.sortOrder,
        ledger.updatedAt,
        ledger.deletedAt,
        ledger.deviceId,
        ledger.rev,
        ledger.id,
      ],
    );
  }

  @override
  Future<void> softDelete(String id, {required int atMs}) async {
    if (await byId(id) == null) {
      throw DomainError.validation(detail: '账本不存在：$id');
    }
    for (final table in const <String>['account', 'txn']) {
      final rows = await db.query(
        'SELECT COUNT(*) AS n FROM $table WHERE deleted_at IS NULL AND ledger_id = ?',
        arguments: <Object?>[id],
      );
      if ((rows.single['n']! as int) > 0) {
        throw DomainError.validation(
          detail: '账本 $id 仍有未删除的 $table 行，禁止软删',
          userMessage: '这个账本里还有数据，先把它们清空或转移到别的账本。',
        );
      }
    }
    await db.run(
      'UPDATE ledger SET deleted_at = ?, updated_at = ?, rev = rev + 1 WHERE id = ?',
      arguments: <Object?>[atMs, atMs, id],
    );
  }

  Future<LedgerRecord?> _defaultLedger() async {
    final rows = await db.query(
      'SELECT $_columns FROM ledger WHERE is_default = 1 AND deleted_at IS NULL',
    );
    return rows.isEmpty ? null : LedgerRecord.fromRow(rows.single);
  }
}

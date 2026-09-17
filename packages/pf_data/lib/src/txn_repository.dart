/// 交易仓储：CRUD + 软删 + **事务内的余额推演**。
///
/// ## 为什么余额更新必须与账目写入同事务
///
/// "INSERT 一笔账 + UPDATE 两个账户"拆成两步，任何一步失败都会留下
/// 缓存与账目不一致的库 —— 而缓存不一致是**静默的**：列表照常显示、
/// 数字悄悄错掉。SQLite 事务把三（四）条语句变成一个原子操作，
/// 这是缓存可信的最低要求。
///
/// ## 软删的余额语义
///
/// 软删 = 从推演中移除该笔（缓存回退它的影响），行保留作墓碑；
/// 编辑 = 先按旧值回退、再按新值施加（净差值一次 UPDATE 完成，
/// 账户更换时新旧两个账户都会被触达）。
/// 恢复（undelete）属导入/撤销流程（M1 ⑤），不在本仓储 ——
/// 那边写完后统一跑全量重算，不依赖增量路径。
library;

import 'package:pf_core/pf_core.dart';

import 'balance_engine.dart';
import 'db.dart';
import 'entities.dart';

/// 交易仓储。
abstract interface class TxnRepository {
  /// 记一笔。事务内完成：校验 → 插入 → 双腿余额更新。
  Future<void> create(TxnRecord txn);

  Future<TxnRecord?> byId(String id);

  /// 编辑一笔（[txn] 为完整新值；id 不变）。事务内完成：
  /// 旧值回退 + 新值施加（净差值），账户/类型/金额变化都覆盖。
  Future<void> update(TxnRecord txn);

  /// 软删（幂等：重复软删同一条是空操作）。[atMs] 为本次操作的
  /// epoch 毫秒（App 层来自注入的 Clock）。
  Future<void> softDelete(String id, {required int atMs});

  /// 按账本列出未删除交易（day_key 倒序、同日 id 倒序 = §2.3 主列表口径）。
  Future<List<TxnRecord>> listByLedger(String ledgerId, {int limit, int offset});
}

final class SqlTxnRepository implements TxnRepository {
  SqlTxnRepository(this.db);

  final PfDb db;

  static const String _columns =
      'id, ledger_id, type, amount_minor, currency, occurred_at, day_key, month_key, '
      'tz_offset_min, account_id, to_account_id, category_id, merchant, note, tags, '
      'fee_minor, is_reimbursable, excluded_from_stats, source_import_job, created_at, '
      'updated_at, deleted_at, device_id, origin_device_id, rev';

  @override
  Future<void> create(TxnRecord txn) => db.transaction<void>((d) async {
    txn.validate();
    if (await _byId(d, txn.id) != null) {
      throw DomainError.validation(detail: '交易已存在：${txn.id}', userMessage: '这笔账已经存在，请勿重复提交。');
    }
    await _validateReferences(d, txn);
    await _insert(d, txn);
    await _applyEffect(d, txn, sign: 1);
  });

  @override
  Future<TxnRecord?> byId(String id) => _byId(db, id);

  @override
  Future<void> update(TxnRecord txn) => db.transaction<void>((d) async {
    final old = await _byId(d, txn.id);
    if (old == null) {
      throw DomainError.validation(detail: '交易不存在：${txn.id}');
    }
    if (old.isDeleted) {
      throw DomainError.validation(detail: '交易已删除，禁止编辑：${txn.id}', userMessage: '这笔账已删除，不能编辑。');
    }
    txn.validate();
    await _validateReferences(d, txn);
    // rev 是同步元数据，仓储递增；updatedAt 由调用方（注入 Clock）提供。
    final updated = TxnRecord(
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
      createdAt: old.createdAt,
      updatedAt: txn.updatedAt,
      deviceId: txn.deviceId,
      originDeviceId: old.originDeviceId,
      rev: old.rev + 1,
    );
    await _updateRow(d, updated);
    // 先回退旧值、再施加新值（净差值）。账户更换时新旧账户各得其所。
    await _applyEffect(d, old, sign: -1);
    await _applyEffect(d, updated, sign: 1);
  });

  @override
  Future<void> softDelete(String id, {required int atMs}) => db.transaction<void>((d) async {
    final old = await _byId(d, id);
    if (old == null) {
      throw DomainError.validation(detail: '交易不存在：$id');
    }
    if (old.isDeleted) {
      return; // 幂等：墓碑不重复立。
    }
    await d.run(
      'UPDATE txn SET deleted_at = ?, updated_at = ?, rev = rev + 1 WHERE id = ?',
      arguments: <Object?>[atMs, atMs, id],
    );
    await _applyEffect(d, old, sign: -1);
  });

  @override
  Future<List<TxnRecord>> listByLedger(String ledgerId, {int limit = 50, int offset = 0}) async {
    final rows = await db.query(
      'SELECT $_columns FROM txn WHERE ledger_id = ? AND deleted_at IS NULL '
      'ORDER BY day_key DESC, id DESC LIMIT ? OFFSET ?',
      arguments: <Object?>[ledgerId, limit, offset],
    );
    return rows.map(TxnRecord.fromRow).toList(growable: false);
  }

  // ---------- 内部：读取与校验 ----------

  Future<TxnRecord?> _byId(PfDb d, String id) async {
    final rows = await d.query('SELECT $_columns FROM txn WHERE id = ?', arguments: <Object?>[id]);
    return rows.isEmpty ? null : TxnRecord.fromRow(rows.single);
  }

  /// 账户（双腿）与分类的存在性 / 软删 / 币种校验。
  ///
  /// 真库上外键只保证"存在"，保证不了"未删除"与"币种一致"；
  /// 后两者是余额推演正确性的前提（跨币种推演毫无意义），因此在
  /// 事务内显式校验。
  Future<void> _validateReferences(PfDb d, TxnRecord txn) async {
    final ids = <String>{txn.accountId, if (txn.toAccountId != null) txn.toAccountId!};
    for (final accountId in ids) {
      final rows = await d.query(
        'SELECT currency, deleted_at FROM account WHERE id = ?',
        arguments: <Object?>[accountId],
      );
      if (rows.isEmpty) {
        throw DomainError.validation(detail: '账户不存在：$accountId', userMessage: '账户不存在，请刷新后重试。');
      }
      if (rows.single['deleted_at'] != null) {
        throw DomainError.validation(detail: '账户已删除：$accountId', userMessage: '这个账户已被删除，不能再记账。');
      }
      if (rows.single['currency'] != txn.currency) {
        throw DomainError.currencyMismatch(
          left: rows.single['currency']! as String,
          right: txn.currency,
        );
      }
    }
    if (txn.categoryId != null) {
      final rows = await d.query(
        'SELECT deleted_at FROM category WHERE id = ?',
        arguments: <Object?>[txn.categoryId],
      );
      if (rows.isEmpty || rows.single['deleted_at'] != null) {
        throw DomainError.validation(
          detail: '分类不存在或已删除：${txn.categoryId}',
          userMessage: '所选分类不存在，请重新选择。',
        );
      }
    }
  }

  // ---------- 内部：写入 ----------

  Future<void> _insert(PfDb d, TxnRecord txn) async {
    await d.run(
      'INSERT INTO txn ($_columns) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
      arguments: txn.toRow().values.toList(),
    );
  }

  Future<void> _updateRow(PfDb d, TxnRecord txn) async {
    await d.run(
      'UPDATE txn SET type = ?, amount_minor = ?, currency = ?, occurred_at = ?, day_key = ?, '
      'month_key = ?, tz_offset_min = ?, account_id = ?, to_account_id = ?, category_id = ?, '
      'merchant = ?, note = ?, tags = ?, fee_minor = ?, is_reimbursable = ?, '
      'excluded_from_stats = ?, source_import_job = ?, updated_at = ?, deleted_at = ?, '
      'device_id = ?, rev = ? WHERE id = ?',
      arguments: <Object?>[
        txn.type.value,
        txn.amountMinor,
        txn.currency,
        txn.occurredAt,
        txn.dayKey,
        txn.monthKey,
        txn.tzOffsetMin,
        txn.accountId,
        txn.toAccountId,
        txn.categoryId,
        txn.merchant,
        txn.note,
        txn.toRow()['tags'],
        txn.feeMinor,
        txn.isReimbursable ? 1 : 0,
        txn.excludedFromStats ? 1 : 0,
        txn.sourceImportJob,
        txn.updatedAt,
        txn.deletedAt,
        txn.deviceId,
        txn.rev,
        txn.id,
      ],
    );
  }

  /// 把 [txn] 的推演影响施加（[sign] = 1）或回退（[sign] = -1）到账户缓存。
  ///
  /// 刻意**不触碰** `account.updated_at` / `rev`（见 account_repository.dart
  /// 的说明：缓存不参与同步判决）。
  ///
  /// `balance_as_of` 每次**全量口径重算**（COALESCE 子查询取该账户所有
  /// 生效交易的 MAX(occurred_at)），而不是增量 MAX：软删/编辑回退会让
  /// "最新一笔"消失，只进不退的增量值就会高于事实 —— 那与全量重算
  /// （balance_recalc.dart）直接冲突。子查询读的是当前表状态，
  /// 增量与全量的 as_of 口径由此恒等。
  static const String _balanceUpdateSql =
      'UPDATE account SET cached_balance_minor = cached_balance_minor + ?, '
      'balance_as_of = COALESCE((SELECT MAX(occurred_at) FROM txn '
      'WHERE deleted_at IS NULL AND (account_id = ? OR to_account_id = ?)), 0) '
      'WHERE id = ?';

  Future<void> _applyEffect(PfDb d, TxnRecord txn, {required int sign}) async {
    final effect = BalanceEngine.effectOfRecord(txn);
    final delta = sign * effect.accountDelta;
    // delta 为 0 也要执行：occurred_at 单独变化时 as_of 仍需重算。
    await d.run(
      _balanceUpdateSql,
      arguments: <Object?>[delta, txn.accountId, txn.accountId, txn.accountId],
    );
    final toDelta = effect.toAccountDelta;
    if (toDelta != null) {
      await d.run(
        _balanceUpdateSql,
        arguments: <Object?>[sign * toDelta, txn.toAccountId, txn.toAccountId, txn.toAccountId],
      );
    }
  }
}

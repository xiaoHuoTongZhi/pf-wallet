/// 账户仓储：CRUD + 软删 + 余额缓存的一致性维护。
///
/// ## SQL 纪律
///
/// 本文件（与 txn_repository / category_repository / balance_recalc）
/// 是 pf_data 里**仅有的**允许出现表名与列名的地方。仓储对上层只暴露
/// [AccountRecord]，SQL 永不外泄。
///
/// ## 余额缓存的维护规则（与 balance_engine.dart 的分工）
///
///   - "一笔账对余额的影响"由 [BalanceEngine.effectOf] 裁决（纯函数，
///     向量锁定）；本文件只负责把它翻译成一条参数化 UPDATE；
///   - **余额更新刻意不碰 `updated_at` / `rev`**：账目才是事实，
///     缓存只是推导值。若余额维护也推进同步元数据，每记一笔账就会把
///     两个账户都变成"刚被修改"，跨端合并的冲突面板会被缓存噪声淹没。
///     缓存的最终一致性由全量重算（导入后/升级后）兜底。
///   - `opening_balance_minor` 修改时，缓存随之平移同样的差值 ——
///     推演起点变了，已推演结果必须跟着变，否则不变式当场破坏。
library;

import 'package:pf_core/pf_core.dart';

import 'db.dart';
import 'entities.dart';

/// 账户仓储。
abstract interface class AccountRepository {
  Future<void> create(AccountRecord account);
  Future<AccountRecord?> byId(String id);

  /// 按账本列出未删除账户（sort_order, id 稳定排序）。
  Future<List<AccountRecord>> listByLedger(String ledgerId);

  /// 全量更新（记录为完整新值）；`opening_balance_minor` 的变化会
  /// 同步平移缓存余额。
  Future<void> update(AccountRecord account);

  /// 软删。**仍有生效交易的账户会被拒绝**（§7.2 验收：
  /// "删除被引用的账户 → 拦住并提示"）。
  ///
  /// [atMs] 为本次操作的 epoch 毫秒（App 层来自注入的 Clock）。
  Future<void> softDelete(String id, {required int atMs});
}

final class SqlAccountRepository implements AccountRepository {
  SqlAccountRepository(this.db);

  final PfDb db;

  static const String _columns =
      'id, ledger_id, name, type, currency, opening_balance_minor, cached_balance_minor, '
      'balance_as_of, credit_limit_minor, statement_day, due_day, repay_account_id, icon, color, '
      'is_archived, sort_order, note, created_at, updated_at, deleted_at, device_id, rev';

  @override
  Future<void> create(AccountRecord account) async {
    if (await byId(account.id) != null) {
      throw DomainError.validation(detail: '账户已存在：${account.id}', userMessage: '这个账户已经存在，请勿重复创建。');
    }
    await db.run(
      'INSERT INTO account ($_columns) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
      arguments: account.toRow().values.toList(),
    );
  }

  @override
  Future<AccountRecord?> byId(String id) async {
    final rows = await db.query(
      'SELECT $_columns FROM account WHERE id = ?',
      arguments: <Object?>[id],
    );
    return rows.isEmpty ? null : AccountRecord.fromRow(rows.single);
  }

  @override
  Future<List<AccountRecord>> listByLedger(String ledgerId) async {
    final rows = await db.query(
      'SELECT $_columns FROM account WHERE ledger_id = ? AND deleted_at IS NULL ORDER BY sort_order, id',
      arguments: <Object?>[ledgerId],
    );
    return rows.map(AccountRecord.fromRow).toList(growable: false);
  }

  @override
  Future<void> update(AccountRecord account) async {
    final old = await byId(account.id);
    if (old == null) {
      throw DomainError.validation(detail: '账户不存在：${account.id}');
    }
    if (account.ledgerId != old.ledgerId) {
      throw DomainError.validation(detail: '账户不允许更换账本（${old.ledgerId} → ${account.ledgerId}）');
    }
    final openingDelta = account.openingBalanceMinor - old.openingBalanceMinor;
    await db.run(
      'UPDATE account SET name = ?, type = ?, currency = ?, opening_balance_minor = ?, '
      'cached_balance_minor = cached_balance_minor + ?, balance_as_of = balance_as_of, '
      'credit_limit_minor = ?, statement_day = ?, due_day = ?, repay_account_id = ?, icon = ?, '
      'color = ?, is_archived = ?, sort_order = ?, note = ?, updated_at = ?, deleted_at = ?, '
      'device_id = ?, rev = ? WHERE id = ?',
      arguments: <Object?>[
        account.name,
        account.type.value,
        account.currency,
        account.openingBalanceMinor,
        openingDelta,
        account.creditLimitMinor,
        account.statementDay,
        account.dueDay,
        account.repayAccountId,
        account.icon,
        account.color,
        account.isArchived ? 1 : 0,
        account.sortOrder,
        account.note,
        account.updatedAt,
        account.deletedAt,
        account.deviceId,
        account.rev,
        account.id,
      ],
    );
  }

  @override
  Future<void> softDelete(String id, {required int atMs}) async {
    final account = await byId(id);
    if (account == null) {
      throw DomainError.validation(detail: '账户不存在：$id');
    }
    // 两条腿都要查：转出的、转入的都算"被引用"。
    final rows = await db.query(
      'SELECT COUNT(*) AS n FROM txn WHERE deleted_at IS NULL AND (account_id = ? OR to_account_id = ?)',
      arguments: <Object?>[id, id],
    );
    final liveTxnCount = rows.single['n']! as int;
    if (liveTxnCount > 0) {
      throw DomainError.validation(
        detail: '账户 $id 仍有 $liveTxnCount 笔生效交易，禁止软删',
        userMessage: '这个账户还有 $liveTxnCount 笔账没有删除或转移，先处理它们再删除账户。',
      );
    }
    await db.run(
      'UPDATE account SET deleted_at = ?, updated_at = ?, rev = rev + 1 WHERE id = ?',
      arguments: <Object?>[atMs, atMs, id],
    );
  }
}

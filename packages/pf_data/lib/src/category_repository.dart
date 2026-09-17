/// 分类仓储：CRUD + 软删 + 二级深度校验。
///
/// 深度与防环由 schema 触发器兜底（`PF_E_CATEGORY_DEPTH` /
/// `PF_E_CATEGORY_CYCLE`，DB 最后防线）；仓储层先做一轮**可读的**
/// 前置校验，让用户在保存前就拿到"分类只能两级"的提示，
/// 而不是等一个裸的 SQL 报错。
library;

import 'package:pf_core/pf_core.dart';

import 'db.dart';
import 'entities.dart';

/// 分类仓储。
abstract interface class CategoryRepository {
  Future<void> create(CategoryRecord category);
  Future<CategoryRecord?> byId(String id);

  /// 按账本列出未删除分类（一级在前、同父按 sort_order, id 稳定排序）。
  Future<List<CategoryRecord>> listByLedger(String ledgerId);

  /// 全量更新（记录为完整新值）。`parent_id` 变化会重新校验深度。
  Future<void> update(CategoryRecord category);

  /// 软删。[atMs] 为本次操作的 epoch 毫秒。
  Future<void> softDelete(String id, {required int atMs});
}

final class SqlCategoryRepository implements CategoryRepository {
  SqlCategoryRepository(this.db);

  final PfDb db;

  static const String _columns =
      'id, ledger_id, parent_id, kind, name, icon, color, is_system, is_hidden, '
      'sort_order, created_at, updated_at, deleted_at, device_id, rev';

  @override
  Future<void> create(CategoryRecord category) async {
    if (await byId(category.id) != null) {
      throw DomainError.validation(detail: '分类已存在：${category.id}', userMessage: '这个分类已经存在，请勿重复创建。');
    }
    await _validateParent(category.parentId, selfId: category.id);
    await db.run(
      'INSERT INTO category ($_columns) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
      arguments: category.toRow().values.toList(),
    );
  }

  @override
  Future<CategoryRecord?> byId(String id) async {
    final rows = await db.query(
      'SELECT $_columns FROM category WHERE id = ?',
      arguments: <Object?>[id],
    );
    return rows.isEmpty ? null : CategoryRecord.fromRow(rows.single);
  }

  @override
  Future<List<CategoryRecord>> listByLedger(String ledgerId) async {
    final rows = await db.query(
      'SELECT $_columns FROM category WHERE ledger_id = ? AND deleted_at IS NULL '
      'ORDER BY parent_id, sort_order, id',
      arguments: <Object?>[ledgerId],
    );
    return rows.map(CategoryRecord.fromRow).toList(growable: false);
  }

  @override
  Future<void> update(CategoryRecord category) async {
    final old = await byId(category.id);
    if (old == null) {
      throw DomainError.validation(detail: '分类不存在：${category.id}');
    }
    if (category.ledgerId != old.ledgerId) {
      throw DomainError.validation(detail: '分类不允许更换账本（${old.ledgerId} → ${category.ledgerId}）');
    }
    await _validateParent(category.parentId, selfId: category.id);
    await db.run(
      'UPDATE category SET parent_id = ?, kind = ?, name = ?, icon = ?, color = ?, '
      'is_system = ?, is_hidden = ?, sort_order = ?, updated_at = ?, deleted_at = ?, '
      'device_id = ?, rev = ? WHERE id = ?',
      arguments: <Object?>[
        category.parentId,
        category.kind.value,
        category.name,
        category.icon,
        category.color,
        category.isSystem ? 1 : 0,
        category.isHidden ? 1 : 0,
        category.sortOrder,
        category.updatedAt,
        category.deletedAt,
        category.deviceId,
        category.rev,
        category.id,
      ],
    );
  }

  @override
  Future<void> softDelete(String id, {required int atMs}) async {
    final category = await byId(id);
    if (category == null) {
      throw DomainError.validation(detail: '分类不存在：$id');
    }
    // 有生效交易或未删除子分类 → 拦住（与账户同一条 §7.2 验收）。
    final txnRows = await db.query(
      'SELECT COUNT(*) AS n FROM txn WHERE deleted_at IS NULL AND category_id = ?',
      arguments: <Object?>[id],
    );
    if (txnRows.single['n']! as int > 0) {
      throw DomainError.validation(
        detail: '分类 $id 仍有生效交易，禁止软删',
        userMessage: '这个分类下还有账目，先转移或删除它们再删除分类。',
      );
    }
    final childRows = await db.query(
      'SELECT COUNT(*) AS n FROM category WHERE deleted_at IS NULL AND parent_id = ?',
      arguments: <Object?>[id],
    );
    if (childRows.single['n']! as int > 0) {
      throw DomainError.validation(
        detail: '分类 $id 仍有未删除子分类，禁止软删',
        userMessage: '这个分类下还有子分类，先删除或转移它们。',
      );
    }
    await db.run(
      'UPDATE category SET deleted_at = ?, updated_at = ?, rev = rev + 1 WHERE id = ?',
      arguments: <Object?>[atMs, atMs, id],
    );
  }

  /// 二级深度校验：父分类必须存在、必须是一级、不能指向自己。
  Future<void> _validateParent(String? parentId, {required String selfId}) async {
    if (parentId == null) {
      return;
    }
    if (parentId == selfId) {
      throw DomainError.validation(detail: '分类不能以自己为父', userMessage: '分类不能是自己的子分类。');
    }
    final parent = await byId(parentId);
    if (parent == null || parent.isDeleted) {
      throw DomainError.validation(detail: '父分类不存在或已删除：$parentId', userMessage: '上级分类不存在，请重新选择。');
    }
    if (parent.parentId != null) {
      throw DomainError.validation(
        detail: '父分类 $parentId 是二级分类，不允许再挂子分类',
        userMessage: '分类最多两级，请选择一级分类作为上级。',
      );
    }
  }
}

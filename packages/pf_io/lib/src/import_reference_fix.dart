/// 引用修复（§4.4 S11–S14）—— 提交 B。
///
/// ## 它修的是什么
///
/// 一份**增量或部分**导出的文件里，交易可以提着本地没有的账户或分类：
/// 那笔交易是这次导出的，而它引用的账户属于上次导出的范围。这不是「文件坏了」，
/// 而是「文件只讲了一半的故事」。§4.3 阶段 I.2 因此把它列成一步显式动作。
///
/// 提交 A 的态度是**宁可整体回滚**（`ImportIntegrityCheck` 发现悬空就抛
/// `PFI_E_INCOMPATIBLE`），因为在没有裁决能力时「造一个父实体」是一种猜测。
/// 提交 B 有了裁决与报告能力，于是把它落成四类**有据可依**的修复：
///
/// | 场景 | 现象 | 动作 |
/// | --- | --- | --- |
/// | S11 | `txn.account_id` / `to_account_id` / `account.repay_account_id` 指向的账户既不在文件里、本地也没有 | 造**占位账户**（保留被引用的 id），置 `is_archived=1` |
/// | S12 | `txn.category_id` / `budget.category_id` 同上 | 造**占位分类**（保留 id），置 `is_hidden=1` |
/// | S13 | 文件里的分类与本地活着的分类**同名同父同类型**但不同 id | 两个并存，**只报告**不合并 |
/// | S14 | 分类的 `parent_id` 指向的父分类不存在或已软删 | 子分类**升级为一级**，并报告 |
/// | 环 / 超深 | `parent_id` 链成环，或链长超过 [ImportReferenceFixer.maxCategoryDepth] | 同上：升级为一级 + 报告 |
///
/// ## 三条必须写明的边界
///
///   1. **`ledger_id` 不造占位账本。** §2.3 的 `ledger.code` 是
///      `NOT NULL UNIQUE` 的 6 字符 Base32 —— 凭空编一个「唯一」的 code
///      是做不到的（只能靠重试猜，而重试的结果不确定，进不了向量）。
///      因此悬空的 `ledger_id` 仍然走「整体回滚」这条路：那种文件不是
///      「只讲了一半的故事」，而是**讲的这个故事根本不成立**。
///   2. **墓碑算「存在」。** 引用一个已删账户是合法的（§4.4 S16/S18：
///      账户列表隐藏、归档里可见，交易照常显示）。孤儿扫描用的是
///      「id 在不在父表里」而不是「父行活着没」，这里必须同口径 ——
///      否则一次删除会让所有历史交易批量变成「悬空」。
///      唯一例外是 `parent_id`：父分类被删后子分类在界面里**不可达**，
///      所以它按「活着没」判定（S14）。
///   3. **`abort` 策略下不做任何修复**（§4.4 的「不猜」）。修复也是猜测的一种，
///      它必须由「逐条裁决」这个决定一起被授权。
///
/// ## 占位实体为什么长这样
///
///   - **保留被引用的 id**：S11/S12 的原文要求。将来用户把占位账户合并到
///     真实账户时，两条路径（交易 → 占位 → 真实）才不需要改数据。
///   - **名字带 id 后缀（分类）**：§2.3 的 `ux_category_name` 是
///     `(ledger_id, kind, IFNULL(parent_id,''), name)` 上的**唯一索引**，
///     而 `WHERE deleted_at IS NULL`。两个占位分类若都叫「（来自其他设备）」
///     就是一次 UNIQUE 冲突 —— 一次「修复」把整次导入炸掉。
///     账户名没有唯一约束（`ux_` 里没有它），因此账户名字保持干净的可读名。
///   - **`is_archived=1` / `is_hidden=1`**：占位实体是导入的副产品，
///     不该出现在记账时的账户列表与分类选择器里。用户把它合并掉之后，
///     这两行自然被清掉。
library;

import 'package:pf_core/pf_core.dart';

import 'import_payload.dart';

/// 一次引用修复的种类。
enum ReferenceFixKind {
  /// S11：造占位账户。
  placeholderAccount('placeholder_account'),

  /// S12：造占位分类。
  placeholderCategory('placeholder_category'),

  /// S14 / 环 / 超深：子分类升级为一级。
  promoteToRoot('promote_to_root'),

  /// S13：同名分类并存，提示用户合并。
  duplicateName('duplicate_name');

  const ReferenceFixKind(this.wireName);

  final String wireName;
}

/// 一条修复动作（进导入报告，也是向量的输出）。
final class ReferenceFix {
  const ReferenceFix({
    required this.kind,
    required this.reason,
    required this.entity,
    required this.recordId,
    required this.referencedId,
    this.column = '',
    this.placeholderName = '',
  });

  final ReferenceFixKind kind;

  /// 为什么修：`missing` / `deleted` / `cycle` / `too_deep` / `duplicate_name`。
  ///
  /// 与 [kind] 分开是必要的：同样是「升级为一级」，
  /// 「父分类被删了」与「parent 链成环」给用户的解释完全不同。
  final String reason;

  /// 被修复记录所在的表。
  final String entity;

  /// 被修复记录的 id。
  final String recordId;

  /// 出问题的引用目标 id（[ReferenceFixKind.duplicateName] 时为空串）。
  final String referencedId;

  /// 出问题的列名。
  final String column;

  /// 占位实体的名字（仅占位类修复）。
  final String placeholderName;

  /// 稳定的报告键（可复现，进向量）。
  String get key => '$entity.$column/${kind.wireName}';

  @override
  String toString() => 'ReferenceFix($entity/$recordId ${kind.wireName}/$reason → $referencedId)';
}

/// 一次引用修复的结果。
final class ReferenceFixResult {
  const ReferenceFixResult({
    required this.records,
    required this.placeholders,
    required this.fixes,
  });

  /// **归一化后**的记录：`parent_id` 需要升级的那些已被改写。
  final List<ImportRecord> records;

  /// 需要插入的占位实体（顺序确定：按 id 排序）。
  final List<ImportRecord> placeholders;

  /// 修复动作（按 `(表, 记录, 列)` 排序）。
  final List<ReferenceFix> fixes;
}

/// 引用修复器。纯函数：同输入同输出，不读时钟、不生成随机数。
abstract final class ImportReferenceFixer {
  /// 占位账户名。
  ///
  /// 「来自其他设备」而不是「未知」：用户看到它时该想到的动作是
  /// 「这是另一台设备记的账，我把它并到我认得的账户上」，
  /// 而不是「这里有脏数据」。
  static const String placeholderAccountName = '（来自其他设备）';

  /// 占位分类名的前缀（真正的名字带 id 后缀，见文件头）。
  static const String placeholderCategoryPrefix = '（来自其他设备·';

  /// `parent_id` 链的遍历上限。
  ///
  /// **它不是产品语义**（产品语义是二级分类，由 §2.3 的触发器兜底），
  /// 而是遍历的边界：一条构造出来的超长 parent 链不应该让修复过程
  /// 变成一次无界遍历。超过上限一律升级为一级 —— 那种文件本来就写不进
  /// 这个 schema。
  static const int maxCategoryDepth = 8;

  /// 占位分类名（带 id 后缀，保证 UNIQUE 不冲突）。
  static String placeholderCategoryName(String id) =>
      '$placeholderCategoryPrefix${id.length <= 8 ? id : id.substring(id.length - 8)}）';

  /// 需要修复的引用列 → 该列指向的父表。
  ///
  /// 刻意只列**有合理修复动作**的那些：`ledger_id` 不在其中（见文件头边界 1），
  /// `tag.ledger_id` / `attachment.txn_id` 同理（前者同 `ledger_id`，
  /// 后者指向的交易若不在文件里，说明这份文件是被人为裁剪过的，
  /// 造一个空交易比回滚危险得多）。
  static const Map<String, Map<String, String>> repairTargets = <String, Map<String, String>>{
    'txn': <String, String>{
      'account_id': 'account',
      'to_account_id': 'account',
      'category_id': 'category',
    },
    'budget': <String, String>{'category_id': 'category'},
    'account': <String, String>{'repay_account_id': 'account'},
  };

  /// 归一化 + 修复。
  ///
  /// [localRows] 只用来回答两个问题：「这个 id 库里有没有」「这个 id 库里还活着吗」。
  static ReferenceFixResult apply({
    required List<ImportRecord> records,
    required Map<String, List<Map<String, Object?>>> localRows,
    required String placeholderDeviceId,
    required int placeholderAtMilliseconds,
  }) {
    _assertRepairTargetsAreScanned();

    final exists = _idIndex(localRows, aliveOnly: false);
    final alive = _idIndex(localRows, aliveOnly: true);
    for (final record in records) {
      (exists[record.table] ??= <String>{}).add(record.id);
      if (!record.isTombstone) {
        (alive[record.table] ??= <String>{}).add(record.id);
      }
    }

    final fixes = <ReferenceFix>[];
    final placeholders = <String, ImportRecord>{};

    // 被改写的记录（目前只有「升级为一级」这一种）。
    //
    // 用「原行序 + 打补丁」而不是「边遍历边累积输出」：后者必须让每一轮的
    // 过滤条件完全互补，漏掉一类记录的表现是**那条记录被静默丢弃** ——
    // 而「导入之后少了几个分类」这种事故，用户要过很久才会发现。
    final patched = <String, ImportRecord>{};

    // ── 第一遍：分类父子关系（S14 + 环 + 超深 + S13 重名）──────────────
    final parentOf = _parentLinks(records, localRows);
    for (final record in records) {
      if (record.type != 'category') {
        continue;
      }
      final parentId = record.columns['parent_id'];
      if (parentId is! String) {
        // 一级分类：没有父子关系可检查（`parent_id` 为空或整列为 NULL）。
        continue;
      }
      final reason = _parentBrokenReason(
        parentId,
        record.id,
        parentOf,
        alive['category'] ?? const <String>{},
        exists['category'] ?? const <String>{},
      );
      if (reason != null) {
        patched[record.id] = _withColumns(record, <String, Object?>{'parent_id': null});
        fixes.add(
          ReferenceFix(
            kind: ReferenceFixKind.promoteToRoot,
            reason: reason,
            entity: record.table,
            recordId: record.id,
            referencedId: parentId,
            column: 'parent_id',
          ),
        );
        continue;
      }
      final duplicate = _duplicateName(record, parentId, localRows);
      if (duplicate != null) {
        fixes.add(
          ReferenceFix(
            kind: ReferenceFixKind.duplicateName,
            reason: 'duplicate_name',
            entity: record.table,
            recordId: record.id,
            referencedId: duplicate,
            column: 'name',
          ),
        );
      }
    }

    // ── 第二遍：缺失的父实体 → 占位（S11/S12）──────────────────────────
    for (final record in records) {
      final targets = repairTargets[record.table];
      if (targets == null) {
        continue;
      }
      for (final column in targets.keys.toList()..sort()) {
        final parent = targets[column]!;
        final referenced = record.columns[column];
        if (referenced is! String || (exists[parent] ?? const <String>{}).contains(referenced)) {
          continue;
        }
        placeholders.putIfAbsent(
          '$parent/$referenced',
          () => _placeholderRecord(
            parent: parent,
            id: referenced,
            referrer: record,
            deviceId: placeholderDeviceId,
            atMilliseconds: placeholderAtMilliseconds,
          ),
        );
        fixes.add(
          ReferenceFix(
            kind:
                parent == 'account'
                    ? ReferenceFixKind.placeholderAccount
                    : ReferenceFixKind.placeholderCategory,
            reason: 'missing',
            entity: record.table,
            recordId: record.id,
            referencedId: referenced,
            column: column,
            placeholderName:
                parent == 'account' ? placeholderAccountName : placeholderCategoryName(referenced),
          ),
        );
      }
    }

    final placeholderList =
        placeholders.entries.toList()..sort(
          (MapEntry<String, ImportRecord> a, MapEntry<String, ImportRecord> b) =>
              a.key.compareTo(b.key),
        );

    // ── 输出：按**原行序**归还记录，只替换被改写的那几条 ────────────────
    //
    // 原行序是有意义的：`recordIndex` 与它一致，而计划的语句序列按 `recordIndex`
    // 排。让修复器重排记录，等于让「文件里的行序」被修复逻辑改写一遍 ——
    // 那种改动没有任何收益，却会让「打乱行序后结果是否一致」这条性质多一个变量。
    final normalized = <ImportRecord>[for (final record in records) patched[record.id] ?? record];

    fixes.sort((ReferenceFix a, ReferenceFix b) {
      final byEntity = a.entity.compareTo(b.entity);
      if (byEntity != 0) return byEntity;
      final byRecord = a.recordId.compareTo(b.recordId);
      if (byRecord != 0) return byRecord;
      final byColumn = a.column.compareTo(b.column);
      if (byColumn != 0) return byColumn;
      return a.kind.wireName.compareTo(b.kind.wireName);
    });

    return ReferenceFixResult(
      records: normalized,
      placeholders: <ImportRecord>[for (final entry in placeholderList) entry.value],
      fixes: fixes,
    );
  }

  /// 修复表必须是扫描表的子集。
  ///
  /// 一旦「扫描认得某条引用、修复不认得」，表现是**导入整体回滚**
  /// （扫描发现没修好的悬空）—— 那种失败看起来像数据坏了，实际是两张表不一致。
  /// 这条断言把它的暴露点提前到「第一次用到修复器」。
  static void _assertRepairTargetsAreScanned() {
    final scanned = <String>{
      for (final rule in kPayloadReferenceRules) '${rule.child}.${rule.column}',
    };
    for (final entry in repairTargets.entries) {
      for (final column in entry.value.keys) {
        if (!scanned.contains('${entry.key}.$column')) {
          throw StateError(
            '引用修复表里的 ${entry.key}.$column 不在孤儿扫描表里：'
            '修了一条没人检查的引用（或反之）会让不一致以「整体回滚」的形式出现',
          );
        }
      }
    }
  }

  /// 库中 id 索引：`表 → id 集合`（[aliveOnly] 时排除墓碑）。
  static Map<String, Set<String>> _idIndex(
    Map<String, List<Map<String, Object?>>> localRows, {
    required bool aliveOnly,
  }) {
    final index = <String, Set<String>>{};
    for (final entry in localRows.entries) {
      for (final row in entry.value) {
        final id = row['id'];
        if (id is! String) {
          continue;
        }
        if (aliveOnly && row['deleted_at'] != null) {
          continue;
        }
        (index[entry.key] ??= <String>{}).add(id);
      }
    }
    return index;
  }

  /// `分类 id → 父 id`，覆盖本批与库中的活着的分类。
  static Map<String, String> _parentLinks(
    List<ImportRecord> records,
    Map<String, List<Map<String, Object?>>> localRows,
  ) {
    final links = <String, String>{};
    for (final row in localRows['category'] ?? const <Map<String, Object?>>[]) {
      final id = row['id'];
      final parent = row['parent_id'];
      if (id is String && parent is String && row['deleted_at'] == null) {
        links[id] = parent;
      }
    }
    for (final record in records) {
      final parent = record.columns['parent_id'];
      if (record.type == 'category' && parent is String && !record.isTombstone) {
        links[record.id] = parent;
      }
    }
    return links;
  }

  /// 父引用坏在哪。返回 null 表示没坏。
  static String? _parentBrokenReason(
    String parentId,
    String selfId,
    Map<String, String> parentOf,
    Set<String> aliveCategories,
    Set<String> knownCategories,
  ) {
    if (parentId == selfId) {
      return 'cycle';
    }
    // 链上逐级向上走：既用来判环，也用来给「超深」一个可判的边界。
    var current = parentId;
    final visited = <String>{selfId};
    var depth = 0;
    while (true) {
      if (!visited.add(current)) {
        return 'cycle';
      }
      depth++;
      if (depth > maxCategoryDepth) {
        return 'too_deep';
      }
      final next = parentOf[current];
      if (next == null) {
        break;
      }
      current = next;
    }
    if (aliveCategories.contains(parentId)) {
      return null;
    }
    // 「被删」与「从没存在过」要分开报：前者用户能去归档里找回来，
    // 后者说明这份文件本来就不完整。
    return knownCategories.contains(parentId) ? 'deleted' : 'missing';
  }

  /// S13：本地已有**同名同父同类型**的活分类且不是同一条 → 返回它的 id。
  static String? _duplicateName(
    ImportRecord record,
    String parentId,
    Map<String, List<Map<String, Object?>>> localRows,
  ) {
    for (final row in localRows['category'] ?? const <Map<String, Object?>>[]) {
      if (row['deleted_at'] != null || row['id'] == record.id) {
        continue;
      }
      if (row['ledger_id'] != record.columns['ledger_id'] ||
          row['kind'] != record.columns['kind'] ||
          row['name'] != record.columns['name']) {
        continue;
      }
      final localParent = row['parent_id'];
      if ((localParent is String ? localParent : '') != parentId) {
        continue;
      }
      return row['id']! as String;
    }
    return null;
  }

  /// 造一条占位实体。列集合与 §2.3 的 DDL 对齐（NOT NULL 列一个不少）。
  static ImportRecord _placeholderRecord({
    required String parent,
    required String id,
    required ImportRecord referrer,
    required String deviceId,
    required int atMilliseconds,
  }) {
    final ledgerId = referrer.columns['ledger_id'];
    if (ledgerId is! String) {
      throw ImportExportError.incompatible(detail: '记录 ${referrer.id} 缺少 ledger_id，无法为它造占位父实体');
    }
    final common = <String, Object?>{
      'created_at': atMilliseconds,
      'updated_at': atMilliseconds,
      'deleted_at': null,
      'device_id': deviceId,
      'rev': 1,
    };
    if (parent == 'account') {
      return ImportRecord(
        type: 'account',
        table: 'account',
        id: id,
        columns: <String, Object?>{
          'id': id,
          'ledger_id': ledgerId,
          'name': placeholderAccountName,
          'type': 1, // CHECK (type IN (1,2,3,4,5))：占位取「储蓄」这一档
          'currency': referrer.columns['currency'] ?? 'CNY',
          'opening_balance_minor': 0,
          'credit_limit_minor': null,
          'statement_day': null,
          'due_day': null,
          'repay_account_id': null,
          'icon': null,
          'color': null,
          // 归档：占位账户不该出现在记账时的账户选择器里（见文件头）。
          'is_archived': 1,
          'sort_order': 0,
          'note': '导入占位：文件里引用了本机没有的账户，请合并到真实账户',
          ...common,
        },
        updatedAt: atMilliseconds,
        deviceId: deviceId,
        isTombstone: false,
        recordIndex: -1,
      );
    }
    final kind = _categoryKindOf(referrer);
    return ImportRecord(
      type: 'category',
      table: 'category',
      id: id,
      columns: <String, Object?>{
        'id': id,
        'ledger_id': ledgerId,
        'parent_id': null,
        'kind': kind,
        'name': placeholderCategoryName(id),
        'icon': null,
        'color': null,
        'is_system': 0,
        // 隐藏：占位分类不该出现在记账时的分类选择器里（见文件头）。
        'is_hidden': 1,
        'sort_order': 0,
        ...common,
      },
      updatedAt: atMilliseconds,
      deviceId: deviceId,
      isTombstone: false,
      recordIndex: -1,
    );
  }

  /// 占位分类的 `kind`（1 支出 / 2 收入）：由引用方的交易类型推出来。
  ///
  /// 推不出来时取 1（支出）：`budget` 没有方向字段，而支出是绝大多数场景。
  /// 猜错方向不会损坏数据 —— 用户合并到真实分类时会一并修正。
  static int _categoryKindOf(ImportRecord referrer) {
    if (referrer.type == 'txn') {
      return referrer.columns['type'] == 2 ? 2 : 1;
    }
    return 1;
  }

  static ImportRecord _withColumns(ImportRecord record, Map<String, Object?> patch) => ImportRecord(
    type: record.type,
    table: record.table,
    id: record.id,
    columns: <String, Object?>{...record.columns, ...patch},
    updatedAt: record.updatedAt,
    deviceId: record.deviceId,
    isTombstone: record.isTombstone,
    recordIndex: record.recordIndex,
  );
}

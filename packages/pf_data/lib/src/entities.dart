/// 仓储层的记录类型（row ↔ 对象的边界）。
///
/// ## 为什么叫 Record 而不是实体类，且放在 pf_data
///
/// 它们是**表结构的 Dart 投影**（列一一对应），不是领域模型：
/// 没有行为不变式（余额推演规则在 balance_engine.dart），
/// 字段集与 §2.3 DDL 逐列对齐，由 fromRow/toRow 强制同步。
/// 放 pf_data（而不是 pf_core）让"表结构变更"只需要改一个包。
///
/// ## 命名与取值纪律
///
///   - 金额一律 `int` **最小货币单位**（§2.1：恒为正，方向由 type 决定）；
///   - 时间一律 epoch 毫秒（UTC）；
///   - 主键 ULID（26 字符，`Ulid.isValid` 校验）；
///   - `dayKey` / `monthKey` 是**冗余列**（§2.1 的关键设计）：
///     由录入设备按本地时区计算后落库。本仓把"怎么算"收敛到
///     [TxnTime] 一处 —— 仓储写入时自动算，向量用 Python 独立算，
///     两边对不上就红。
library;

import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:pf_core/pf_core.dart';

/// 账户类型（§2.3 account.type）。
enum AccountType {
  cash(1),
  savingsCard(2),
  creditCard(3),
  ewallet(4),
  investment(5);

  const AccountType(this.value);

  final int value;

  static AccountType fromValue(int value) => AccountType.values.singleWhere(
    (t) => t.value == value,
    orElse: () => throw DomainError.validation(detail: '未知账户类型 $value'),
  );
}

/// 交易类型（§2.3 txn.type）。
enum TxnType {
  expense(1),
  income(2),
  transfer(3);

  const TxnType(this.value);

  final int value;

  static TxnType fromValue(int value) => TxnType.values.singleWhere(
    (t) => t.value == value,
    orElse: () => throw DomainError.validation(detail: '未知交易类型 $value'),
  );
}

/// 分类方向（§2.3 category.kind）。
enum CategoryKind {
  expense(1),
  income(2);

  const CategoryKind(this.value);

  final int value;

  static CategoryKind fromValue(int value) => CategoryKind.values.singleWhere(
    (k) => k.value == value,
    orElse: () => throw DomainError.validation(detail: '未知分类方向 $value'),
  );
}

/// 本地日 / 月键的计算 —— 全仓唯一实现。
abstract final class TxnTime {
  /// 允许的时区偏移范围：UTC±14 小时（ISO 8601 上限）。
  static const int maxTzOffsetMin = 14 * 60;

  /// epoch 毫秒 + 录入时区偏移 → 录入设备的本地日 `YYYY-MM-DD`。
  ///
  /// 不用 `DateTime.toLocal()`：那会把"设备当前时区"混进来，
  /// 而正确语义是**录入那一刻的偏移**（已存进 `tz_offset_min`）。
  /// 直接对 `occurred_at + offset` 做 UTC 日历拆解，无 DST、无漂移。
  static String dayKey(int occurredAtMs, int tzOffsetMin) =>
      _localDate(occurredAtMs, tzOffsetMin).$1;

  /// epoch 毫秒 + 录入时区偏移 → 录入设备的本地月 `YYYY-MM`。
  static String monthKey(int occurredAtMs, int tzOffsetMin) =>
      _localDate(occurredAtMs, tzOffsetMin).$2;

  static (String, String) _localDate(int occurredAtMs, int tzOffsetMin) {
    if (tzOffsetMin.abs() > maxTzOffsetMin) {
      throw DomainError.validation(detail: '时区偏移 $tzOffsetMin 超出 ±$maxTzOffsetMin 分钟');
    }
    final local = DateTime.fromMillisecondsSinceEpoch(
      occurredAtMs + tzOffsetMin * 60000,
      isUtc: true,
    );
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return (
      '${local.year.toString().padLeft(4, '0')}-$month-$day',
      '${local.year.toString().padLeft(4, '0')}-$month',
    );
  }
}

/// account 表的一行（§2.3）。
final class AccountRecord {
  AccountRecord({
    required this.id,
    required this.ledgerId,
    required this.name,
    required this.type,
    required this.currency,
    required this.openingBalanceMinor,
    required this.cachedBalanceMinor,
    required this.balanceAsOf,
    this.creditLimitMinor,
    this.statementDay,
    this.dueDay,
    this.repayAccountId,
    this.icon,
    this.color,
    this.isArchived = false,
    this.sortOrder = 0,
    this.note,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    required this.deviceId,
    this.rev = 1,
  }) {
    _check();
  }

  void _check() {
    if (!Ulid.isValid(id)) {
      throw DomainError.validation(detail: 'account.id 不是合法 ULID：$id');
    }
    // 信用卡必须有额度（与 DDL 的 CHECK 一致；仓储层前置校验给出更清晰的错误）。
    if (type == AccountType.creditCard && creditLimitMinor == null) {
      throw DomainError.validation(detail: '信用卡账户必须提供 creditLimitMinor', userMessage: '请先填写信用卡额度。');
    }
    if (repayAccountId != null && repayAccountId == id) {
      throw DomainError.validation(detail: 'repayAccountId 不能指向账户自身', userMessage: '还款账户不能是这张卡自己。');
    }
  }

  final String id;
  final String ledgerId;
  final String name;
  final AccountType type;
  final String currency;

  /// 初始余额：仅作为推演起点，不参与统计（§2.3）。
  final int openingBalanceMinor;

  /// 缓存余额 = opening + Σ(该账户所有生效 txn 的影响)。可随时全量重算。
  final int cachedBalanceMinor;

  /// 缓存已包含到的时间点（epoch ms）；0 = 尚无任何影响。
  final int balanceAsOf;

  /// 信用卡专有：额度，正数。
  final int? creditLimitMinor;
  final int? statementDay;
  final int? dueDay;

  /// 信用卡专有：默认还款账户。
  final String? repayAccountId;
  final String? icon;
  final String? color;
  final bool isArchived;
  final int sortOrder;
  final String? note;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final String deviceId;
  final int rev;

  bool get isDeleted => deletedAt != null;

  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'ledger_id': ledgerId,
    'name': name,
    'type': type.value,
    'currency': currency,
    'opening_balance_minor': openingBalanceMinor,
    'cached_balance_minor': cachedBalanceMinor,
    'balance_as_of': balanceAsOf,
    'credit_limit_minor': creditLimitMinor,
    'statement_day': statementDay,
    'due_day': dueDay,
    'repay_account_id': repayAccountId,
    'icon': icon,
    'color': color,
    'is_archived': isArchived ? 1 : 0,
    'sort_order': sortOrder,
    'note': note,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'deleted_at': deletedAt,
    'device_id': deviceId,
    'rev': rev,
  };

  static AccountRecord fromRow(Map<String, Object?> row) => AccountRecord(
    id: row['id']! as String,
    ledgerId: row['ledger_id']! as String,
    name: row['name']! as String,
    type: AccountType.fromValue(row['type']! as int),
    currency: row['currency']! as String,
    openingBalanceMinor: row['opening_balance_minor']! as int,
    cachedBalanceMinor: row['cached_balance_minor']! as int,
    balanceAsOf: row['balance_as_of']! as int,
    creditLimitMinor: row['credit_limit_minor'] as int?,
    statementDay: row['statement_day'] as int?,
    dueDay: row['due_day'] as int?,
    repayAccountId: row['repay_account_id'] as String?,
    icon: row['icon'] as String?,
    color: row['color'] as String?,
    isArchived: (row['is_archived']! as int) != 0,
    sortOrder: row['sort_order']! as int,
    note: row['note'] as String?,
    createdAt: row['created_at']! as int,
    updatedAt: row['updated_at']! as int,
    deletedAt: row['deleted_at'] as int?,
    deviceId: row['device_id']! as String,
    rev: row['rev']! as int,
  );
}

/// category 表的一行（§2.3）。
final class CategoryRecord {
  const CategoryRecord({
    required this.id,
    required this.ledgerId,
    this.parentId,
    required this.kind,
    required this.name,
    this.icon,
    this.color,
    this.isSystem = false,
    this.isHidden = false,
    this.sortOrder = 0,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    required this.deviceId,
    this.rev = 1,
  });

  final String id;
  final String ledgerId;
  final String? parentId;
  final CategoryKind kind;
  final String name;
  final String? icon;
  final String? color;
  final bool isSystem;
  final bool isHidden;
  final int sortOrder;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final String deviceId;
  final int rev;

  bool get isDeleted => deletedAt != null;

  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'ledger_id': ledgerId,
    'parent_id': parentId,
    'kind': kind.value,
    'name': name,
    'icon': icon,
    'color': color,
    'is_system': isSystem ? 1 : 0,
    'is_hidden': isHidden ? 1 : 0,
    'sort_order': sortOrder,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'deleted_at': deletedAt,
    'device_id': deviceId,
    'rev': rev,
  };

  static CategoryRecord fromRow(Map<String, Object?> row) => CategoryRecord(
    id: row['id']! as String,
    ledgerId: row['ledger_id']! as String,
    parentId: row['parent_id'] as String?,
    kind: CategoryKind.fromValue(row['kind']! as int),
    name: row['name']! as String,
    icon: row['icon'] as String?,
    color: row['color'] as String?,
    isSystem: (row['is_system']! as int) != 0,
    isHidden: (row['is_hidden']! as int) != 0,
    sortOrder: row['sort_order']! as int,
    createdAt: row['created_at']! as int,
    updatedAt: row['updated_at']! as int,
    deletedAt: row['deleted_at'] as int?,
    deviceId: row['device_id']! as String,
    rev: row['rev']! as int,
  );
}

/// txn 表的一行（§2.3）。
final class TxnRecord {
  TxnRecord({
    required this.id,
    required this.ledgerId,
    required this.type,
    required this.amountMinor,
    required this.currency,
    required this.occurredAt,
    required this.tzOffsetMin,
    String? dayKey,
    String? monthKey,
    required this.accountId,
    this.toAccountId,
    this.categoryId,
    this.merchant,
    this.note,
    this.tags = const <String>[],
    this.feeMinor = 0,
    this.isReimbursable = false,
    this.excludedFromStats = false,
    this.sourceImportJob,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    required this.deviceId,
    required this.originDeviceId,
    this.rev = 1,
  }) : dayKey = dayKey ?? TxnTime.dayKey(occurredAt, tzOffsetMin),
       monthKey = monthKey ?? TxnTime.monthKey(occurredAt, tzOffsetMin);

  final String id;
  final String ledgerId;
  final TxnType type;

  /// 恒为正（§2.1）；方向由 [type] 决定。
  final int amountMinor;
  final String currency;

  /// epoch 毫秒（用于精确排序与区间查询）。
  final int occurredAt;
  final int tzOffsetMin;

  /// 冗余列（§2.1）：由 (occurredAt, tzOffsetMin) 派生；缺省时用 [TxnTime]
  /// 自动计算。显式传入的场景只有一类 —— 校验"库里的冗余列与派生值一致"
  /// 的测试与向量。
  final String dayKey;
  final String monthKey;
  final String accountId;

  /// 仅转账（type=3）非空，且 ≠ [accountId]。
  final String? toAccountId;

  /// 非转账必填；转账必须为空（§2.3 CHECK）。
  final String? categoryId;
  final String? merchant;
  final String? note;
  final List<String> tags;

  /// 转账手续费（由转出账户额外承担；统计口径计入支出）。
  final int feeMinor;
  final bool isReimbursable;
  final bool excludedFromStats;
  final String? sourceImportJob;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final String deviceId;

  /// 首次创建该记录的设备；deviceId 会被后续修改覆盖，此列不变（§2.3）。
  final String originDeviceId;
  final int rev;

  bool get isDeleted => deletedAt != null;

  /// 结构校验（§2.3 CHECK 的仓储侧前置，错误信息比 SQL 报错可读）。
  void validate() {
    if (!Ulid.isValid(id)) {
      throw DomainError.validation(detail: 'txn.id 不是合法 ULID：$id');
    }
    if (amountMinor <= 0) {
      throw DomainError.validation(detail: '金额必须为正，实际 $amountMinor', userMessage: '请输入大于零的金额。');
    }
    if (feeMinor < 0) {
      throw DomainError.validation(detail: '手续费不能为负：$feeMinor');
    }
    if (TxnTime.maxTzOffsetMin < tzOffsetMin.abs()) {
      throw DomainError.validation(detail: '时区偏移 $tzOffsetMin 超出范围');
    }
    if (type == TxnType.transfer) {
      if (toAccountId == null) {
        throw DomainError.validation(detail: '转账缺少 toAccountId', userMessage: '请选择转入账户。');
      }
      if (toAccountId == accountId) {
        throw DomainError.validation(detail: '转账双方不能是同一账户', userMessage: '转入账户不能与转出账户相同。');
      }
      if (categoryId != null) {
        throw DomainError.validation(detail: '转账不得挂分类：$categoryId');
      }
    } else {
      if (toAccountId != null) {
        throw DomainError.validation(detail: '非转账交易不得设置 toAccountId');
      }
      if (categoryId == null) {
        throw DomainError.validation(detail: '收支交易必须挂分类', userMessage: '请选择一个分类。');
      }
      if (feeMinor != 0) {
        throw DomainError.validation(detail: '只有转账可以有手续费：$feeMinor');
      }
    }
  }

  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'ledger_id': ledgerId,
    'type': type.value,
    'amount_minor': amountMinor,
    'currency': currency,
    'occurred_at': occurredAt,
    'day_key': dayKey,
    'month_key': monthKey,
    'tz_offset_min': tzOffsetMin,
    'account_id': accountId,
    'to_account_id': toAccountId,
    'category_id': categoryId,
    'merchant': merchant,
    'note': note,
    'tags': jsonEncode(tags),
    'fee_minor': feeMinor,
    'is_reimbursable': isReimbursable ? 1 : 0,
    'excluded_from_stats': excludedFromStats ? 1 : 0,
    'source_import_job': sourceImportJob,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'deleted_at': deletedAt,
    'device_id': deviceId,
    'origin_device_id': originDeviceId,
    'rev': rev,
  };

  static TxnRecord fromRow(Map<String, Object?> row) {
    final tagsRaw = row['tags'];
    final tags =
        tagsRaw is String
            ? (jsonDecode(tagsRaw) as List<Object?>)
                .map((e) => e is String ? e : throw DomainError.validation(detail: 'tags 含非字符串元素'))
                .toList()
            : const <String>[];
    return TxnRecord(
      id: row['id']! as String,
      ledgerId: row['ledger_id']! as String,
      type: TxnType.fromValue(row['type']! as int),
      amountMinor: row['amount_minor']! as int,
      currency: row['currency']! as String,
      occurredAt: row['occurred_at']! as int,
      dayKey: row['day_key']! as String,
      monthKey: row['month_key']! as String,
      tzOffsetMin: row['tz_offset_min']! as int,
      accountId: row['account_id']! as String,
      toAccountId: row['to_account_id'] as String?,
      categoryId: row['category_id'] as String?,
      merchant: row['merchant'] as String?,
      note: row['note'] as String?,
      tags: tags,
      feeMinor: row['fee_minor']! as int,
      isReimbursable: (row['is_reimbursable']! as int) != 0,
      excludedFromStats: (row['excluded_from_stats']! as int) != 0,
      sourceImportJob: row['source_import_job'] as String?,
      createdAt: row['created_at']! as int,
      updatedAt: row['updated_at']! as int,
      deletedAt: row['deleted_at'] as int?,
      deviceId: row['device_id']! as String,
      originDeviceId: row['origin_device_id']! as String,
      rev: row['rev']! as int,
    );
  }
}

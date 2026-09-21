/// 导入载荷（NDJSON）解码器 —— 规格 §4.1 / §4.3 阶段 I。
///
/// 与编码器（`export_payload.dart`）严格对称：那边把记录编成字节，
/// 这边把字节还原成**可直接参数化写入的行值**。对称性不是审美 ——
/// 两边的字段表必须是同一张表的两个方向，否则「导出带、导入丢」
/// 这类错误不会有任何一条用例变红。
///
/// ## 三条兼容规则（§4.1 C1–C3）的落点
///
///   - **C1 忽略未知字段**：字段表只认 [PayloadRecordSpec.fields] 里的键，
///     其余一律丢弃。这条规则在这里是**结构性**的，不是靠 if 判断 ——
///     行值由字段表逐项生成，文件里多一个键在结构上就没有位置可去。
///   - **C2 忽略未知记录类型**：不认识的 `type` 跳过并计数（[DecodedPayload.unknownTypes]），
///     **不阻断导入**。注意它仍然计入 contentHash 的覆盖范围（见下）。
///   - **C3 缺失字段取默认值**：默认值逐条来自 §2.3 的 DDL `DEFAULT` 子句，
///     在字段表里显式写出，并注明出处。没有默认值（NOT NULL 且无 DEFAULT）
///     的字段缺失 → 拒绝整份文件：**编不出这一行就不能假装它没问题**。
///
/// 一个反直觉但必须如此的点：**未知类型的行也要计入 contentHash**。
/// 若只对「认得的记录行」求摘要，V1 读 V2 导出的文件时摘要必然失配，
/// 而 C1/C2 又要求 V1 必须能读 —— 两条规则会当场打架。
/// 摘要的覆盖范围因此固定为「manifest 与 end 之间的**全部字节**」。
///
/// ## 流式
///
/// [PayloadLineScanner] 逐行扫描：不预先 split 出全部行、不复制整份文档，
/// 单行超过 [kMaxJsonLineBytes] 立即中止（资源耗尽防线，§4.3 硬约束表）。
/// 摘要是对记录区**一次**求的（零拷贝视图）—— M1 的载荷本来就在内存里，
/// 与编码端同一取舍；M3 接文件网关时换分块摘要接口，规则不变。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';
import 'package:pf_data/pf_data.dart';

import 'export_payload.dart';

/// 单行 JSON 的字节上限（§4.3 硬约束表：16 MiB）。
const int kMaxJsonLineBytes = 16 * 1024 * 1024;

/// 单次导入的记录数上限（§4.3 硬约束表：默认 200 万）。
const int kMaxImportRecords = 2000000;

/// 载荷内 JSON 的嵌套深度上限（§4.3 硬约束表：4）。
const int kMaxPayloadDepth = 4;

/// 文本字段的长度上限（§4.3：note ≤ 8 KiB；merchant / name / file_name 同档）。
const int kMaxTextBytes = 8 * 1024;

/// `tags` / 其它 id 数组的长度上限（§4.3：tags ≤ 64）。
const int kMaxIdListLength = 64;

/// 单笔金额的上限（§4.3：`0 < x ≤ 1e15`）。
const int kMaxAmountMinor = 1000000000000000;

/// 已知记录类型 = 载荷阶段顺序（父实体先行，见 [kPayloadStageOrder]）。
///
/// 「已知」的定义就是「有字段表」——迁移到 v2 时新增类型要同时加字段表，
/// 否则它会以未知类型被跳过（这是 C2 的本意：宁可跳过也不要猜）。
List<String> get kKnownRecordTypes => kPayloadStageOrder;

/// 字段值的形态。决定「怎么从 JSON 取值」与「怎么校验」。
enum PayloadValueKind {
  /// 必填非空字符串。
  text,

  /// 可空字符串（缺省 → NULL）。
  optionalText,

  /// 必填整数。
  integer,

  /// 可空整数（缺省 → NULL）。
  optionalInteger,

  /// 0/1 标志（缺省 → 0）。
  flag,

  /// 引用型 id（可空；形状校验同 [text]）。
  optionalId,

  /// id 数组（缺省 → `[]`）。
  idList,

  /// JSON 对象（序列化后写 TEXT 列；缺省由字段表给）。
  jsonObject,

  /// Base64 → BLOB（缺省 → NULL）。
  base64Blob,

  /// 派生字段：`day_key`。缺失时由 `occurred_at` + `tz_offset_min` 派生。
  derivedDayKey,

  /// 派生字段：`month_key`。同上。
  derivedMonthKey,
}

/// 一个字段的映射与校验规则。
final class PayloadField {
  const PayloadField(
    this.jsonKey,
    this.column,
    this.kind, {
    this.defaultValue,
    this.source = '',
    this.intMinimum,
    this.intMaximum,
    this.allowedInts,
    this.ignoredOnImport = false,
  });

  /// 载荷里的键名（camelCase，§4.1）。
  final String jsonKey;

  /// 数据库列名（snake_case，§2.3）。
  final String column;

  final PayloadValueKind kind;

  /// C3 默认值（`null` 且非 [PayloadValueKind.optionalText]/[PayloadValueKind.optionalInteger]
  /// 表示「无默认值 → 缺失即拒绝」）。
  final Object? defaultValue;

  /// 默认值的出处（§2.3 的哪一条 DEFAULT，或 §4.1 的哪一行）。
  /// 写在这里是给 review 用的：默认值不许凭感觉定。
  final String source;

  final int? intMinimum;
  final int? intMaximum;

  /// 枚举型整数的合法取值（如 `type ∈ {1,2,3}`）。
  final List<int>? allowedInts;

  /// 派生缓存字段：**导出照带、导入丢弃**（§4.3 末尾的「account 行缓存字段的导入语义」）。
  ///
  /// 丢弃不是「忘了处理」——它是显式登记在这里、并被向量反向钉死的一等公民：
  /// 若实现把 `cached_balance_minor` 写进去，导入的余额会静默错掉，
  /// 而全量重算（`BalanceRecalculator`，唯一权威来源）也会被覆盖成文件里的旧值。
  final bool ignoredOnImport;

  /// 是否「缺失即拒绝整份文件」。
  ///
  /// 三种情况都不算必需：
  ///   - [ignoredOnImport]（本来就不写）；
  ///   - 有 [defaultValue]（C3：缺了取默认值）；
  ///   - 该 kind **本身就可空** —— [PayloadValueKind.optionalText] /
  ///     `optionalInteger` / `optionalId` / `base64Blob` 的缺省语义就是 NULL。
  ///
  /// 第三条不是修辞上的区别，而是踩过的坑：把「可空」写成「无默认值 ⇒ 必需」，
  /// 会让一条只是没带 `merchant` 的交易行、或一条只存外部路径的附件行
  /// （storage=2，本就不该有 `data`）被整份拒绝 —— 而导出方**没有任何义务**
  /// 写一个值为 null 的键。
  bool get required {
    if (ignoredOnImport || defaultValue != null) {
      return false;
    }
    return switch (kind) {
      PayloadValueKind.optionalText ||
      PayloadValueKind.optionalInteger ||
      PayloadValueKind.optionalId ||
      PayloadValueKind.base64Blob => false,
      _ => true,
    };
  }
}

/// 一种记录类型的字段表 + 目标表。
final class PayloadRecordSpec {
  const PayloadRecordSpec({required this.type, required this.table, required this.fields});

  /// `type` 取值（与阶段名一致）。
  final String type;

  /// 目标表名（§2.3）。SQL 由 `pf_data` 的导入写入器拼装，本文件只给表名。
  final String table;

  final List<PayloadField> fields;

  PayloadField? fieldByJsonKey(String key) {
    for (final field in fields) {
      if (field.jsonKey == key) {
        return field;
      }
    }
    return null;
  }
}

const List<PayloadField> _common = <PayloadField>[
  PayloadField('id', 'id', PayloadValueKind.text),
  PayloadField('createdAt', 'created_at', PayloadValueKind.integer),
  PayloadField('updatedAt', 'updated_at', PayloadValueKind.integer),
  PayloadField('deletedAt', 'deleted_at', PayloadValueKind.optionalInteger),
  PayloadField('deviceId', 'device_id', PayloadValueKind.text),
  PayloadField(
    'rev',
    'rev',
    PayloadValueKind.integer,
    defaultValue: 1,
    source: '§2.3 rev INTEGER NOT NULL DEFAULT 1',
    intMinimum: 1,
  ),
];

const PayloadField _ledgerId = PayloadField('ledgerId', 'ledger_id', PayloadValueKind.text);

/// 八种记录类型的字段表。**顺序敏感**：它同时是写入语句的列序（可复现）。
final Map<String, PayloadRecordSpec> kPayloadRecordSpecs = <String, PayloadRecordSpec>{
  'ledger': const PayloadRecordSpec(
    type: 'ledger',
    table: 'ledger',
    fields: <PayloadField>[
      PayloadField('id', 'id', PayloadValueKind.text),
      PayloadField('name', 'name', PayloadValueKind.text),
      PayloadField('code', 'code', PayloadValueKind.text),
      PayloadField(
        'currency',
        'currency',
        PayloadValueKind.text,
        defaultValue: 'CNY',
        source: "§2.3 ledger.currency TEXT NOT NULL DEFAULT 'CNY'",
      ),
      PayloadField(
        'isDefault',
        'is_default',
        PayloadValueKind.flag,
        defaultValue: 0,
        source: '§2.3 DEFAULT 0',
      ),
      PayloadField(
        'sortOrder',
        'sort_order',
        PayloadValueKind.integer,
        defaultValue: 0,
        source: '§2.3 DEFAULT 0',
      ),
      ..._common,
    ],
  ),
  'account': const PayloadRecordSpec(
    type: 'account',
    table: 'account',
    fields: <PayloadField>[
      PayloadField('id', 'id', PayloadValueKind.text),
      _ledgerId,
      PayloadField('name', 'name', PayloadValueKind.text),
      // 载荷键 `accountType`（不是 `type`）：判别键在记录行里独占，
      // 两个同名键会被 JSON 的「取末次」规则吞掉判别键 —— 2026-09-21 裁决，
      // 见 export_payload.dart 的 kPayloadDiscriminatorKey。
      PayloadField(
        'accountType',
        'type',
        PayloadValueKind.integer,
        allowedInts: <int>[1, 2, 3, 4, 5],
        source: '§2.3 CHECK (type IN (1,2,3,4,5))；载荷键改名见 §4.1「判别键独占」',
      ),
      PayloadField('currency', 'currency', PayloadValueKind.text),
      PayloadField(
        'openingBalanceMinor',
        'opening_balance_minor',
        PayloadValueKind.integer,
        defaultValue: 0,
        source: '§2.3 DEFAULT 0',
      ),
      // ↓↓ 派生态：导出照带、导入丢弃（§4.3 末段）
      PayloadField(
        'cachedBalanceMinor',
        'cached_balance_minor',
        PayloadValueKind.integer,
        defaultValue: 0,
        ignoredOnImport: true,
        source: '§4.3「account 行缓存字段的导入语义」：缓存余额由全量重算裁决',
      ),
      PayloadField(
        'balanceAsOf',
        'balance_as_of',
        PayloadValueKind.integer,
        defaultValue: 0,
        ignoredOnImport: true,
        source: '同上',
      ),
      PayloadField('creditLimitMinor', 'credit_limit_minor', PayloadValueKind.optionalInteger),
      PayloadField(
        'statementDay',
        'statement_day',
        PayloadValueKind.optionalInteger,
        intMinimum: 1,
        intMaximum: 31,
        source: '§2.3 CHECK (statement_day BETWEEN 1 AND 31)',
      ),
      PayloadField(
        'dueDay',
        'due_day',
        PayloadValueKind.optionalInteger,
        intMinimum: 1,
        intMaximum: 31,
        source: '§2.3 CHECK (due_day BETWEEN 1 AND 31)',
      ),
      PayloadField('repayAccountId', 'repay_account_id', PayloadValueKind.optionalId),
      PayloadField('icon', 'icon', PayloadValueKind.optionalText),
      PayloadField('color', 'color', PayloadValueKind.optionalText),
      PayloadField(
        'isArchived',
        'is_archived',
        PayloadValueKind.flag,
        defaultValue: 0,
        source: '§2.3 DEFAULT 0',
      ),
      PayloadField(
        'sortOrder',
        'sort_order',
        PayloadValueKind.integer,
        defaultValue: 0,
        source: '§2.3 DEFAULT 0',
      ),
      PayloadField('note', 'note', PayloadValueKind.optionalText),
      PayloadField('createdAt', 'created_at', PayloadValueKind.integer),
      PayloadField('updatedAt', 'updated_at', PayloadValueKind.integer),
      PayloadField('deletedAt', 'deleted_at', PayloadValueKind.optionalInteger),
      PayloadField('deviceId', 'device_id', PayloadValueKind.text),
      PayloadField(
        'rev',
        'rev',
        PayloadValueKind.integer,
        defaultValue: 1,
        source: '§2.3 DEFAULT 1',
        intMinimum: 1,
      ),
    ],
  ),
  'category': const PayloadRecordSpec(
    type: 'category',
    table: 'category',
    fields: <PayloadField>[
      PayloadField('id', 'id', PayloadValueKind.text),
      _ledgerId,
      PayloadField('parentId', 'parent_id', PayloadValueKind.optionalId),
      PayloadField(
        'kind',
        'kind',
        PayloadValueKind.integer,
        allowedInts: <int>[1, 2],
        source: '§2.3 CHECK (kind IN (1,2))',
      ),
      PayloadField('name', 'name', PayloadValueKind.text),
      PayloadField('icon', 'icon', PayloadValueKind.optionalText),
      PayloadField('color', 'color', PayloadValueKind.optionalText),
      PayloadField(
        'isSystem',
        'is_system',
        PayloadValueKind.flag,
        defaultValue: 0,
        source: '§2.3 DEFAULT 0',
      ),
      PayloadField(
        'isHidden',
        'is_hidden',
        PayloadValueKind.flag,
        defaultValue: 0,
        source: '§2.3 DEFAULT 0',
      ),
      PayloadField(
        'sortOrder',
        'sort_order',
        PayloadValueKind.integer,
        defaultValue: 0,
        source: '§2.3 DEFAULT 0',
      ),
      ..._common,
    ],
  ),
  'tag': const PayloadRecordSpec(
    type: 'tag',
    table: 'tag',
    fields: <PayloadField>[
      PayloadField('id', 'id', PayloadValueKind.text),
      _ledgerId,
      PayloadField('name', 'name', PayloadValueKind.text),
      PayloadField('color', 'color', PayloadValueKind.optionalText),
      ..._common,
    ],
  ),
  'theme': const PayloadRecordSpec(
    type: 'theme',
    table: 'theme_profile',
    fields: <PayloadField>[
      PayloadField('id', 'id', PayloadValueKind.text),
      PayloadField('name', 'name', PayloadValueKind.text),
      PayloadField(
        'specJson',
        'spec_json',
        PayloadValueKind.jsonObject,
        defaultValue: <String, Object?>{},
        // 空对象是 §2.3 允许的最小 spec_json：NOT NULL 但语义由应用层定义。
        source: '§2.3 spec_json TEXT NOT NULL CHECK (json_valid(spec_json))',
      ),
      PayloadField(
        'isActive',
        'is_active',
        PayloadValueKind.flag,
        defaultValue: 0,
        source: '§2.3 DEFAULT 0',
      ),
      ..._common,
    ],
  ),
  'txn': const PayloadRecordSpec(
    type: 'txn',
    table: 'txn',
    fields: <PayloadField>[
      PayloadField('id', 'id', PayloadValueKind.text),
      _ledgerId,
      // 载荷键 `txnType`（不是 `type`）：理由同 account 行。
      PayloadField(
        'txnType',
        'type',
        PayloadValueKind.integer,
        allowedInts: <int>[1, 2, 3],
        source: '§2.3 CHECK (type IN (1,2,3))；载荷键改名见 §4.1「判别键独占」',
      ),
      PayloadField(
        'amountMinor',
        'amount_minor',
        PayloadValueKind.integer,
        intMinimum: 1,
        intMaximum: kMaxAmountMinor,
        source: '§2.3 CHECK (amount_minor > 0) + §4.3 硬约束表',
      ),
      PayloadField('currency', 'currency', PayloadValueKind.text),
      PayloadField('occurredAt', 'occurred_at', PayloadValueKind.integer),
      PayloadField(
        'dayKey',
        'day_key',
        PayloadValueKind.derivedDayKey,
        defaultValue: '',
        source: '§2.3 NOT NULL；缺失时按 occurred_at + tz_offset_min 派生（§2.3 TxnTime）',
      ),
      PayloadField(
        'monthKey',
        'month_key',
        PayloadValueKind.derivedMonthKey,
        defaultValue: '',
        source: '同上',
      ),
      PayloadField(
        'tzOffsetMin',
        'tz_offset_min',
        PayloadValueKind.integer,
        defaultValue: 0,
        source: '§2.3 DEFAULT 0',
        intMinimum: -TxnTime.maxTzOffsetMin,
        intMaximum: TxnTime.maxTzOffsetMin,
      ),
      PayloadField('accountId', 'account_id', PayloadValueKind.text),
      PayloadField('toAccountId', 'to_account_id', PayloadValueKind.optionalId),
      PayloadField('categoryId', 'category_id', PayloadValueKind.optionalId),
      PayloadField('merchant', 'merchant', PayloadValueKind.optionalText),
      PayloadField('note', 'note', PayloadValueKind.optionalText),
      PayloadField(
        'tags',
        'tags',
        PayloadValueKind.idList,
        defaultValue: <String>[],
        source: "§2.3 tags TEXT NOT NULL DEFAULT '[]'",
      ),
      PayloadField(
        'feeMinor',
        'fee_minor',
        PayloadValueKind.integer,
        defaultValue: 0,
        source: '§2.3 DEFAULT 0 + CHECK (fee_minor >= 0)',
        intMinimum: 0,
      ),
      PayloadField(
        'isReimbursable',
        'is_reimbursable',
        PayloadValueKind.flag,
        defaultValue: 0,
        source: '§2.3 DEFAULT 0',
      ),
      PayloadField(
        'excludedFromStats',
        'excluded_from_stats',
        PayloadValueKind.flag,
        defaultValue: 0,
        source: '§2.3 DEFAULT 0（C3 的例子：V2 才有的字段，V1 取 0）',
      ),
      PayloadField('createdAt', 'created_at', PayloadValueKind.integer),
      PayloadField('updatedAt', 'updated_at', PayloadValueKind.integer),
      PayloadField('deletedAt', 'deleted_at', PayloadValueKind.optionalInteger),
      PayloadField('deviceId', 'device_id', PayloadValueKind.text),
      PayloadField('originDeviceId', 'origin_device_id', PayloadValueKind.text),
      PayloadField(
        'rev',
        'rev',
        PayloadValueKind.integer,
        defaultValue: 1,
        source: '§2.3 DEFAULT 1',
        intMinimum: 1,
      ),
    ],
  ),
  'budget': const PayloadRecordSpec(
    type: 'budget',
    table: 'budget',
    fields: <PayloadField>[
      PayloadField('id', 'id', PayloadValueKind.text),
      _ledgerId,
      PayloadField(
        'periodType',
        'period_type',
        PayloadValueKind.integer,
        allowedInts: <int>[1, 2],
        source: '§2.3 CHECK (period_type IN (1,2))',
      ),
      PayloadField('periodKey', 'period_key', PayloadValueKind.text),
      PayloadField(
        'scope',
        'scope',
        PayloadValueKind.integer,
        allowedInts: <int>[1, 2],
        source: '§2.3 CHECK (scope IN (1,2))',
      ),
      PayloadField('categoryId', 'category_id', PayloadValueKind.optionalId),
      PayloadField(
        'amountMinor',
        'amount_minor',
        PayloadValueKind.integer,
        intMinimum: 0,
        source: '§2.3 CHECK (amount_minor >= 0)',
      ),
      PayloadField('currency', 'currency', PayloadValueKind.text),
      PayloadField(
        'rollover',
        'rollover',
        PayloadValueKind.flag,
        defaultValue: 0,
        source: '§2.3 DEFAULT 0',
      ),
      PayloadField(
        'alertBp',
        'alert_bp',
        PayloadValueKind.integer,
        defaultValue: 8000,
        source: '§2.3 DEFAULT 8000 CHECK (alert_bp BETWEEN 0 AND 20000)',
        intMinimum: 0,
        intMaximum: 20000,
      ),
      ..._common,
    ],
  ),
  'attachment': const PayloadRecordSpec(
    type: 'attachment',
    table: 'attachment',
    fields: <PayloadField>[
      PayloadField('id', 'id', PayloadValueKind.text),
      _ledgerId,
      PayloadField('txnId', 'txn_id', PayloadValueKind.optionalId),
      PayloadField('fileName', 'file_name', PayloadValueKind.text),
      PayloadField('mime', 'mime', PayloadValueKind.text),
      PayloadField(
        'sizeBytes',
        'size_bytes',
        PayloadValueKind.integer,
        intMinimum: 0,
        source: '§2.3 CHECK (size_bytes >= 0)',
      ),
      PayloadField('sha256', 'sha256', PayloadValueKind.text),
      PayloadField(
        'storage',
        'storage',
        PayloadValueKind.integer,
        allowedInts: <int>[1, 2],
        source: '§2.3 CHECK (storage IN (1,2))',
      ),
      PayloadField('dataB64', 'data', PayloadValueKind.base64Blob),
      PayloadField('extRelPath', 'ext_rel_path', PayloadValueKind.optionalText),
      PayloadField('wrappedDek', 'wrapped_dek', PayloadValueKind.base64Blob),
      PayloadField('dekNonce', 'dek_nonce', PayloadValueKind.base64Blob),
      PayloadField('width', 'width', PayloadValueKind.optionalInteger),
      PayloadField('height', 'height', PayloadValueKind.optionalInteger),
      ..._common,
    ],
  ),
};

/// 引用完整性规则：子表某列必须指向父表的既有行。
///
/// **这张表只有一个定义处**（2026-09-21 提交 B 提取）：孤儿扫描
/// （`import_apply.dart` 的 `ImportIntegrityCheck`）与引用修复
/// （`import_reference_fix.dart`）用的是同一张表。
///
/// 提取的理由不是「少写几行」：两张表一旦并存，就会出现
/// 「扫描认得这条引用、修复不认得」的组合 —— 而那时的表现是
/// **导入整体回滚**（扫描发现没修好的悬空）。这种失败看起来像数据坏了，
/// 实际是两张表不一致，排查方向会被彻底带偏。
final class PayloadReferenceRule {
  const PayloadReferenceRule({required this.child, required this.column, required this.parent});

  /// 子表（引用方）。
  final String child;

  /// 子表的引用列。
  final String column;

  /// 父表（被引用方）。
  final String parent;

  /// 面向排查的名字：`txn.account_id→account`。
  String get name => '$child.$column→$parent';

  /// 面向向量输入的键（纯 ASCII）：`txn.account_id`。
  ///
  /// 单独给一个键而不是复用 [name]：向量文件是给人看也会被别的实现读的，
  /// 让它的键里出现 `→` 只会平添编码争议（`name` 用于日志与错误详情）。
  String get key => '$child.$column';

  /// 孤儿扫描。**常量 SQL**（表名/列名都是本仓字面量），不带参数。
  ///
  /// `NOT IN` 遇 NULL 得 NULL、行被过滤 —— 这正是想要的：
  /// 可空引用列取 NULL 表示「没有引用」，不是「引用了不存在的行」。
  String get orphanScanSql =>
      'SELECT COUNT(*) AS n FROM $child WHERE $column NOT IN (SELECT id FROM $parent)';
}

/// §2.3 的全部外键引用。顺序即扫描顺序（可复现）。
const List<PayloadReferenceRule> kPayloadReferenceRules = <PayloadReferenceRule>[
  PayloadReferenceRule(child: 'account', column: 'ledger_id', parent: 'ledger'),
  PayloadReferenceRule(child: 'account', column: 'repay_account_id', parent: 'account'),
  PayloadReferenceRule(child: 'category', column: 'ledger_id', parent: 'ledger'),
  PayloadReferenceRule(child: 'category', column: 'parent_id', parent: 'category'),
  PayloadReferenceRule(child: 'tag', column: 'ledger_id', parent: 'ledger'),
  PayloadReferenceRule(child: 'txn', column: 'ledger_id', parent: 'ledger'),
  PayloadReferenceRule(child: 'txn', column: 'account_id', parent: 'account'),
  PayloadReferenceRule(child: 'txn', column: 'to_account_id', parent: 'account'),
  PayloadReferenceRule(child: 'txn', column: 'category_id', parent: 'category'),
  PayloadReferenceRule(child: 'budget', column: 'ledger_id', parent: 'ledger'),
  PayloadReferenceRule(child: 'budget', column: 'category_id', parent: 'category'),
  PayloadReferenceRule(child: 'attachment', column: 'ledger_id', parent: 'ledger'),
  PayloadReferenceRule(child: 'attachment', column: 'txn_id', parent: 'txn'),
];

/// 由 `(updatedAt, deviceId)` 合成版本戳 —— §4.4 实现口径注记的公式原文。
///
/// 同一 `(updatedAt, deviceId)` 恒等产出同一戳，因此它可进黄金向量。
/// **前置条件**：`updatedAtMs` 落在 ULID 的 48 位毫秒域内（`0 .. 2^48-1`）。
/// 域外的值（时钟回拨产生的负数、被篡改的超大值）由调用方先归一 ——
/// 见 [normalizeUpdatedAtMilliseconds]。
///
/// 放在本文件（而不是 `import_merge.dart`）的理由很实在：它是
/// [ImportRecord] 的一个**派生属性**（见 `ImportRecord.versionStamp`），
/// 而记录的定义在这里。放远了会形成 `import_payload` ↔ `import_merge`
/// 的循环导入 —— Dart 允许循环，但那意味着两个文件都无法被单独读懂。
String synthesizeVersionStamp(int updatedAtMs, String deviceId) =>
    UlidGenerator.encode(updatedAtMs, Sha256.instance.hash(utf8.encode(deviceId)).sublist(0, 10));

/// `updated_at < 1` 归一到 0（§4.4 S25「视为最旧处理」）。
///
/// 为什么归一而不是丢弃该行：一条 `updated_at` 为 0 或负数的记录**确实是用户的
/// 数据**（可能来自时钟从未校准过的设备）。把它当最旧的那一条参与裁决，它就会
/// 在任何一个有意义的版本面前输掉 —— 这正是「视为最旧」该有的效果。
/// 而如果让它直接进合成公式，负数会让 `UlidGenerator.encode` 抛错：
/// 一条坏时间戳的记录就能炸掉整次导入。
int normalizeUpdatedAtMilliseconds(int raw) => raw < 1 ? 0 : raw;

/// 一条已解码、已校验、可直接参数化写入的记录。
final class ImportRecord {
  const ImportRecord({
    required this.type,
    required this.table,
    required this.id,
    required this.columns,
    required this.updatedAt,
    required this.deviceId,
    required this.isTombstone,
    required this.recordIndex,
  });

  final String type;

  /// 目标表名。
  final String table;

  final String id;

  /// 列名 → 值（列序由字段表固定，`pf_data` 的写入器只按它拼 SQL）。
  final Map<String, Object?> columns;

  /// 版本元数据：裁决（§4.4）与入库元数据都要它，但**不在字段表里**
  /// —— 它同时出现在所有类型上，且不参与 contentEquals（§4.4）。
  final int updatedAt;
  final String deviceId;

  /// 墓碑（`deleted_at` 非空）。
  final bool isTombstone;

  /// 在载荷里的行序（0 起，不含 manifest）。诊断用：报告里说「第 N 行」。
  final int recordIndex;

  /// 业务字段指纹（§4.4 的 `contentEquals` 口径）。
  ///
  /// 排除 `rev` / `updated_at` / `created_at` / `device_id`：它们在两台设备上
  /// 天然不同，把它们算进指纹会让「两端都改成了同样的值」被判成冲突。
  /// 指纹的用途只有一个：**判断本地已存在的那一行与文件里的这一行是否同内容**，
  /// 从而把「重复导入」识别成 skip 而不是 update。
  String get contentFingerprint => contentFingerprintOf(columns);

  /// 版本戳（§4.4 实现口径）：由 [updatedAt] 与 [deviceId] 合成。
  ///
  /// 不做缓存：它是一次哈希 + 一次 Base32 编码，而导入是批处理路径 ——
  /// 为它加一个字段只会让 [ImportRecord] 多一个可能与 [columns] 不一致的状态。
  String get versionStamp =>
      synthesizeVersionStamp(normalizeUpdatedAtMilliseconds(updatedAt), deviceId);

  @override
  String toString() => 'ImportRecord($type/$id)';

  /// 与 [contentFingerprint] 同口径的独立函数（写入器对比本地行时也用它）。
  static String contentFingerprintOf(Map<String, Object?> columns) {
    final keys =
        columns.keys.where((String key) => !fingerprintExcluded.contains(key)).toList()..sort();
    final canonical = <String, Object?>{for (final key in keys) key: columns[key]};
    return Sha256.instance.hashHex(utf8.encode(jsonEncode(canonical)));
  }

  /// 本地行是否与这一行「同内容」（§4.4 的 `contentEquals` 口径）。
  ///
  /// 比较只覆盖**本行携带的列**（即 [columns] 的键）：本地行可能多出
  /// `cached_balance_minor` / `balance_as_of` / `source_import_job` 这些
  /// 「导出不带、本地才有」的列，若按列名求并集，任何 attachment 或 account
  /// 行都会永远判成「内容不同」—— 于是重复导入变成一次冲突弹窗。
  ///
  /// 排除项与 [contentFingerprint] 一致：`rev` / `updated_at` / `created_at` /
  /// `device_id` 在两台设备上天然不同，它们**不构成内容差异**。
  bool matchesLocal(Map<String, Object?> local) {
    final keys =
        columns.keys.where((String key) => !fingerprintExcluded.contains(key)).toList()..sort();
    final incoming = <String, Object?>{for (final key in keys) key: columns[key]};
    final existing = <String, Object?>{for (final key in keys) key: local[key]};
    return contentFingerprintOf(incoming) == contentFingerprintOf(existing);
  }

  static const Set<String> fingerprintExcluded = <String>{
    'rev',
    'updated_at',
    'created_at',
    'device_id',
    // 导入时才填的溯源列：不在载荷里，也不参与内容比较。
    'source_import_job',
  };
}

/// 解码结果。
final class DecodedPayload {
  const DecodedPayload({
    required this.manifest,
    required this.records,
    required this.unknownTypes,
    required this.declaredRecordCount,
    required this.observedRecordCount,
    required this.contentHashHex,
    required this.recordsRegionBytes,
    required this.warnings,
  });

  /// manifest 行（未做业务解释，原样保留）。
  final Map<String, Object?> manifest;

  final List<ImportRecord> records;

  /// C2：未知类型 → 出现次数。不阻断导入，但必须出现在报告里。
  final Map<String, int> unknownTypes;

  /// end 行声明的记录数。
  final int declaredRecordCount;

  /// 实际观察到的记录数（含被跳过的未知类型）。
  final int observedRecordCount;

  /// 校验通过的 contentHash（十六进制，不含 `sha256:` 前缀）。
  final String contentHashHex;

  /// 记录区字节数（manifest 与 end 之间的全部字节）。
  final int recordsRegionBytes;

  /// 非致命提醒（时钟异常等），进导入报告。
  final List<String> warnings;

  String get exportKind => '${manifest['exportKind']}';

  int get skippedUnknownRecordCount =>
      unknownTypes.values.fold(0, (int sum, int count) => sum + count);
}

/// 逐行扫描 NDJSON 字节。**不 split 整份文档**，也不复制行内容以外的字节。
///
/// 回调给出的是**字节区间**而不是 String：行的原始字节要参与 contentHash，
/// 先解码成 String 再编码回去会让「摘要覆盖哪些字节」变得依赖编解码实现。
final class PayloadLineScanner {
  PayloadLineScanner(this._bytes, {this.maxLineBytes = kMaxJsonLineBytes});

  final Uint8List _bytes;
  final int maxLineBytes;

  /// 逐行回调 `(行首下标, 行尾下标（不含换行）, 行号（0 起）)`。
  void scan({required void Function(int start, int end, int lineNumber) onLine}) {
    var index = 0;
    var lineNumber = 0;
    final length = _bytes.length;
    while (index < length) {
      final newline = _bytes.indexOf(0x0A, index);
      final lineEnd = newline == -1 ? length : newline;
      if (lineEnd - index > maxLineBytes) {
        throw DomainError.validation(
          detail: '第 ${lineNumber + 1} 行超过 $maxLineBytes 字节上限',
          userMessage: '这份导入文件里有超长的数据行，已停止处理。',
        );
      }
      onLine(index, lineEnd, lineNumber);
      index = newline == -1 ? length : newline + 1;
      lineNumber++;
    }
  }
}

/// 字段表的自检：任何业务字段都不得把判别键当作 jsonKey。
///
/// 判别键在记录行里独占（§4.1「判别键独占」，2026-09-21 裁决）。字段表若违反，
/// 出问题的地方**不在这一张表上**：account 行的 `type` 与行类型同名，
/// JSON 的「取末次」规则会让行类型静默变成整数，而这一行本身完全合法 ——
/// 报错会出现在「认不出类型」和「缺少 type」两个互相矛盾的结论上。
/// 所以在解析之前先把表检查掉，把错误钉在真正的成因处。
void _assertFieldTablesExcludeDiscriminator() {
  for (final entry in kPayloadRecordSpecs.entries) {
    for (final field in entry.value.fields) {
      if (field.jsonKey == kPayloadDiscriminatorKey) {
        throw StateError(
          '字段表把判别键当成了业务字段：${entry.key} 行的 jsonKey '
          '"${field.jsonKey}"（列 ${field.column}）—— '
          '载荷键必须改名（如 accountType / txnType），见 §4.1「判别键独占」',
        );
      }
    }
  }
}

/// 载荷解码器。
abstract final class PfbPayloadDecoder {
  /// 解码 + 校验。任何违反格式契约的地方都抛 [DomainError]（`PFC_E_VALIDATION`）。
  ///
  /// 这里**不接触密钥与容器** —— 它拿到的已经是解压后的明文字节。
  /// 分层的原因很实际：载荷格式的正确性可以在没有密码、没有文件、
  /// 没有数据库的情况下被向量穷举。
  static DecodedPayload decode(Uint8List ndjsonBytes) {
    // 先在**任何解析动作之前**自检字段表：字段表的 jsonKey 若占用了判别键，
    // 该字段会在 JSON「取末次」规则下把行类型吞掉（2026-09-21 事故的代码侧成因）。
    // 刻意放在这里而不是 try 内部：这是**我们自己的表写错了**，
    // 抛 StateError 而不是 DomainError —— 它绝不能被当作「文件损坏」报给用户。
    _assertFieldTablesExcludeDiscriminator();

    final records = <ImportRecord>[];
    final unknown = <String, int>{};
    final observedByType = <String, int>{};
    final warnings = <String>[];
    Map<String, Object?>? manifest;
    Map<String, Object?>? endLine;
    var recordIndex = 0;
    var regionStart = -1;
    var regionEnd = -1;
    var lineNumber = 0;
    var sawEnd = false;

    final scanner = PayloadLineScanner(ndjsonBytes);
    scanner.scan(
      onLine: (int start, int end, int index) {
        lineNumber = index + 1;
        if (sawEnd) {
          throw _invalid('end 行之后还有内容（第 $lineNumber 行）—— 载荷被追加过');
        }
        final lineBytes = Uint8List.sublistView(ndjsonBytes, start, end);
        if (_isBlank(lineBytes)) {
          throw _invalid('第 $lineNumber 行是空行 —— NDJSON 每行必须是完整对象');
        }
        final Object? decoded = _decodeJsonLine(lineBytes, lineNumber);
        if (decoded is! Map<String, Object?>) {
          throw _invalid('第 $lineNumber 行不是 JSON 对象');
        }
        final type = decoded['type'];
        if (type is! String || type.isEmpty) {
          throw _invalid('第 $lineNumber 行缺少 type');
        }
        if (index == 0) {
          if (type != 'manifest') {
            throw _invalid('首行必须是 manifest，实际是 "$type"（§4.1）');
          }
          manifest = decoded;
          // 记录区从 manifest 行的换行之后开始（零记录载荷时它是一个空区间）。
          regionStart = end + 1;
          return;
        }
        if (type == 'manifest') {
          throw _invalid('manifest 只能出现一次（第 $lineNumber 行又出现了一次）');
        }
        if (type == 'end') {
          endLine = decoded;
          sawEnd = true;
          regionEnd = start;
          return;
        }
        final spec = kPayloadRecordSpecs[type];
        if (spec == null) {
          // C2：跳过并计数，不阻断。
          unknown.update(type, (int n) => n + 1, ifAbsent: () => 1);
          recordIndex++;
          return;
        }
        if (records.length >= kMaxImportRecords) {
          throw _invalid('记录数超过上限 $kMaxImportRecords');
        }
        records.add(_buildRecord(spec, decoded, recordIndex, warnings));
        observedByType.update(type, (int n) => n + 1, ifAbsent: () => 1);
        recordIndex++;
      },
    );

    final manifestLine = manifest;
    if (manifestLine == null) {
      throw _invalid('载荷为空或缺少 manifest 行');
    }
    final end = endLine;
    if (end == null) {
      throw _invalid('载荷缺少 end 行（文件可能被截断）');
    }
    if (regionStart == -1 || regionStart > regionEnd) {
      throw _invalid('记录区边界异常（manifest 与 end 行之间不是合法区间）');
    }
    final declaredContentHash = _requireContentHash(manifestLine);
    final endContentHash = _requireContentHash(end);
    if (endContentHash != declaredContentHash) {
      throw _invalid('manifest 与 end 行的 contentHash 不一致');
    }

    // 零拷贝视图：记录区在载荷里本来就是连续的，摘要直接对它求。
    final region = Uint8List.sublistView(ndjsonBytes, regionStart, regionEnd);
    final observed = Sha256.instance.hashHex(region);
    if (observed != declaredContentHash) {
      throw _invalid(
        '载荷 contentHash 不符：声明 $declaredContentHash，实际 $observed'
        '（记录行被改动过）',
      );
    }

    final declaredCount = end['recordCount'];
    if (declaredCount is! int) {
      throw _invalid('end 行缺少 recordCount');
    }
    if (declaredCount != recordIndex) {
      throw _invalid('end 行声明 $declaredCount 条记录，实际 $recordIndex 条');
    }

    _validateManifestForImport(manifestLine);
    _validateScopeMatchesContent(manifestLine, records);
    _validateCountsMatchContent(manifestLine, observedByType);

    return DecodedPayload(
      manifest: manifestLine,
      records: records,
      unknownTypes: unknown,
      declaredRecordCount: declaredCount,
      observedRecordCount: recordIndex,
      contentHashHex: observed,
      recordsRegionBytes: region.length,
      warnings: warnings,
    );
  }

  static ImportRecord _buildRecord(
    PayloadRecordSpec spec,
    Map<String, Object?> line,
    int recordIndex,
    List<String> warnings,
  ) {
    // ── 第一遍：逐字段取值（缺失 → 默认；派生字段缺席先跳过）────────────
    final pending = <String, Object?>{};
    for (final field in spec.fields) {
      if (field.ignoredOnImport) {
        // 显式丢弃：见 PayloadField.ignoredOnImport。
        continue;
      }
      final present = line.containsKey(field.jsonKey);
      if (!present) {
        if (field.required) {
          throw _invalid('${spec.type} 行缺少必需字段 "${field.jsonKey}"（列 ${field.column}）');
        }
        if (field.kind != PayloadValueKind.derivedDayKey &&
            field.kind != PayloadValueKind.derivedMonthKey) {
          pending[field.column] = _defaultValue(field);
        }
        continue;
      }
      final raw = line[field.jsonKey];
      if (raw == null) {
        if (field.required) {
          throw _invalid('${spec.type}.${field.jsonKey} 为 null，但该列 NOT NULL 且无默认值');
        }
        if (field.kind == PayloadValueKind.derivedDayKey ||
            field.kind == PayloadValueKind.derivedMonthKey) {
          continue; // 交给派生步骤
        }
        // 显式 null 落到「有 DEFAULT 的 NOT NULL 列」上时**取默认值**，不是 null。
        // 照原样写 null 只会把一次可定位的数据问题变成事务里的一句
        // `NOT NULL constraint failed: txn.tags` —— 而 C3 已经给了安全值。
        // 对**可空**列（无默认）_defaultValue 就是 null，语义不变。
        pending[field.column] = _defaultValue(field);
        continue;
      }
      pending[field.column] = _coerce(field, raw, spec);
    }

    // ── 派生字段：day_key / month_key 缺失时按 §2.3 的 TxnTime 口径派生 ──
    final occurredAt = pending['occurred_at'];
    if (occurredAt is int) {
      final tz = pending['tz_offset_min'];
      final tzOffsetMin = tz is int ? tz : 0;
      pending.putIfAbsent('day_key', () => TxnTime.dayKey(occurredAt, tzOffsetMin));
      pending.putIfAbsent('month_key', () => TxnTime.monthKey(occurredAt, tzOffsetMin));
    }

    // ── 第二遍：按字段表序装配 ───────────────────────────────────────
    //
    // 两遍不是为了好看：派生的 day_key / month_key 依赖同一行**后面**的
    // tz_offset_min，只能在一遍取值之后算；而列序又必须恒等于字段表序
    // （它是 INSERT 的列序，也是向量比对的依据）。用一遍取值 + 一遍装配，
    // 两条性质同时成立 —— 若改成「算完直接 append 到尾部」，写入列序就会
    // 随「文件里有没有带 dayKey」而变，同一份数据两种列序。
    final columns = <String, Object?>{};
    for (final field in spec.fields) {
      if (field.ignoredOnImport) {
        continue;
      }
      if (pending.containsKey(field.column)) {
        columns[field.column] = pending[field.column];
      }
    }

    if (spec.type == 'txn') {
      _validateTxnShape(columns);
      _noteClockAnomaly(columns, warnings);
    }

    final id = columns['id'];
    if (id is! String || !_isSafeId(id)) {
      throw _invalid('${spec.type} 行的 id 非法："$id"');
    }
    final updatedAt = columns['updated_at'] ?? 0;
    return ImportRecord(
      type: spec.type,
      table: spec.table,
      id: id,
      columns: columns,
      updatedAt: updatedAt is int ? updatedAt : 0,
      deviceId: '${columns['device_id'] ?? ''}',
      isTombstone: columns['deleted_at'] != null,
      recordIndex: recordIndex,
    );
  }

  /// §2.3 的 CHECK 约束在这里**前置**执行：让「不可写入的行」在解码期就死掉，
  /// 而不是等到 SQL 层报一个没有任何上下文的约束错误。
  static void _validateTxnShape(Map<String, Object?> columns) {
    final type = columns['type'];
    final toAccount = columns['to_account_id'];
    final category = columns['category_id'];
    if (type == 3) {
      if (toAccount == null) {
        throw _invalid('转账（type=3）必须有 to_account_id');
      }
      if (toAccount == columns['account_id']) {
        throw _invalid('转账的 to_account_id 不得等于 account_id');
      }
      if (category != null) {
        throw _invalid('转账的 category_id 必须为空（§2.3 CHECK）');
      }
    } else if (type is int) {
      if (toAccount != null) {
        throw _invalid('非转账的 to_account_id 必须为空（§2.3 CHECK）');
      }
      if (category == null) {
        throw _invalid('非转账必须有 category_id（§2.3 CHECK）');
      }
    }
  }

  /// §4.3 硬约束表最后一行：`updatedAt` 在未来 >24h 的设备 → 不修改数据但列入报告。
  ///
  /// 判定依赖真实时钟（这条规则本身就是「你的时钟和我差多少」），
  /// 因此**测试样本的时间戳必须落在过去**：向量里出现未来时间戳会让结果
  /// 随时间漂移。这是本文件唯一一处读时钟的地方，刻意留下这段说明。
  static void _noteClockAnomaly(Map<String, Object?> columns, List<String> warnings) {
    final updatedAt = columns['updated_at'];
    if (updatedAt is! int) {
      return;
    }
    if (updatedAt < 1) {
      warnings.add('记录 ${columns['id']} 的 updatedAt=$updatedAt 不合法，按最旧处理');
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (updatedAt - now > const Duration(hours: 24).inMilliseconds) {
      warnings.add('记录 ${columns['id']} 的 updatedAt 在未来超过 24 小时，该文件来自时钟异常的设备');
    }
  }

  static Object? _defaultValue(PayloadField field) {
    if (field.kind == PayloadValueKind.idList) {
      return jsonEncode(field.defaultValue! as List<String>);
    }
    if (field.kind == PayloadValueKind.jsonObject) {
      return jsonEncode(field.defaultValue! as Map<String, Object?>);
    }
    return field.defaultValue;
  }

  static Object? _coerce(PayloadField field, Object? raw, PayloadRecordSpec spec) {
    final path = '${spec.type}.${field.jsonKey}';
    switch (field.kind) {
      case PayloadValueKind.text:
        if (raw is! String || raw.isEmpty) {
          throw _invalid('$path 必须是非空字符串，实际 ${raw.runtimeType}');
        }
        if (utf8.encode(raw).length > kMaxTextBytes) {
          throw _invalid('$path 超过 $kMaxTextBytes 字节');
        }
        return raw;
      case PayloadValueKind.optionalText:
        if (raw is! String) {
          throw _invalid('$path 必须是字符串，实际 ${raw.runtimeType}');
        }
        if (utf8.encode(raw).length > kMaxTextBytes) {
          throw _invalid('$path 超过 $kMaxTextBytes 字节');
        }
        return raw;
      case PayloadValueKind.optionalId:
        if (raw is! String || !_isSafeId(raw)) {
          throw _invalid('$path 不是合法的 id："$raw"');
        }
        return raw;
      case PayloadValueKind.integer:
      case PayloadValueKind.optionalInteger:
        if (raw is! int) {
          throw _invalid('$path 必须是整数，实际 ${raw.runtimeType}（JSON 浮点会让金额失真）');
        }
        _checkIntRange(field, raw, spec);
        return raw;
      case PayloadValueKind.flag:
        if (raw is! int || (raw != 0 && raw != 1)) {
          throw _invalid('$path 只能是 0 或 1，实际 $raw');
        }
        return raw;
      case PayloadValueKind.idList:
        if (raw is! List<Object?>) {
          throw _invalid('$path 必须是数组，实际 ${raw.runtimeType}');
        }
        if (raw.length > kMaxIdListLength) {
          throw _invalid('$path 长度 ${raw.length} 超过上限 $kMaxIdListLength');
        }
        for (final item in raw) {
          if (item is! String || !_isSafeId(item)) {
            throw _invalid('$path 含非 id 元素："$item"');
          }
        }
        return jsonEncode(raw);
      case PayloadValueKind.jsonObject:
        if (raw is! Map<String, Object?> || raw.isEmpty) {
          throw _invalid('$path 必须是对象');
        }
        return jsonEncode(raw);
      case PayloadValueKind.base64Blob:
        if (raw is! String) {
          throw _invalid('$path 必须是 Base64 字符串');
        }
        try {
          return base64Decode(raw);
        } on FormatException {
          throw _invalid('$path 不是合法 Base64');
        }
      case PayloadValueKind.derivedDayKey:
      case PayloadValueKind.derivedMonthKey:
        if (raw is! String || raw.isEmpty) {
          throw _invalid('$path 必须是非空字符串');
        }
        return raw;
    }
  }

  static void _checkIntRange(PayloadField field, int value, PayloadRecordSpec spec) {
    final allowed = field.allowedInts;
    if (allowed != null && !allowed.contains(value)) {
      throw _invalid('${spec.type}.${field.jsonKey}=$value 不在合法取值 $allowed 内（${field.source}）');
    }
    final min = field.intMinimum;
    if (min != null && value < min) {
      throw _invalid('${spec.type}.${field.jsonKey}=$value 小于下限 $min（${field.source}）');
    }
    final max = field.intMaximum;
    if (max != null && value > max) {
      throw _invalid('${spec.type}.${field.jsonKey}=$value 超过上限 $max（${field.source}）');
    }
  }

  static Object? _decodeJsonLine(Uint8List line, int lineNumber) {
    final String text;
    try {
      text = utf8.decode(line);
    } on FormatException {
      throw _invalid('第 $lineNumber 行不是合法 UTF-8');
    }
    try {
      final decoded = jsonDecode(text);
      _checkDepth(decoded, 0, lineNumber);
      return decoded;
    } on FormatException catch (error) {
      throw _invalid('第 $lineNumber 行不是合法 JSON：${error.message}');
    }
  }

  static void _checkDepth(Object? value, int depth, int lineNumber) {
    if (depth > kMaxPayloadDepth) {
      throw _invalid('第 $lineNumber 行的嵌套深度超过 $kMaxPayloadDepth');
    }
    if (value is Map<String, Object?>) {
      for (final child in value.values) {
        _checkDepth(child, depth + 1, lineNumber);
      }
    } else if (value is List<Object?>) {
      for (final child in value) {
        _checkDepth(child, depth + 1, lineNumber);
      }
    }
  }

  static bool _isBlank(Uint8List line) {
    for (final byte in line) {
      if (byte != 0x20 && byte != 0x09 && byte != 0x0D) {
        return false;
      }
    }
    return true;
  }

  /// id 的形状校验：非空、≤64 字符、只含 URL 安全字符。
  ///
  /// 刻意**不**在这里做严格 ULID 校验：id 的权威定义在 id 层（`id.ulid.*` 向量）。
  /// 这里守的是**注入面** —— 这串东西会进 SQL 参数与报告，不能被用来拼路径或拼语句。
  static bool _isSafeId(String value) =>
      value.isNotEmpty && value.length <= 64 && RegExp(r'^[0-9A-Za-z_-]+$').hasMatch(value);

  static String _requireContentHash(Map<String, Object?> line) {
    final raw = line['contentHash'];
    if (raw is! String || !raw.startsWith('sha256:')) {
      throw _invalid('缺少 contentHash（应为 "sha256:…"）');
    }
    final hex = raw.substring('sha256:'.length);
    if (hex.length != 64) {
      throw _invalid('contentHash 长度不是 64 位十六进制');
    }
    return hex;
  }

  /// 载荷侧的前置校验（§4.2 第 0 步在导入侧的对应物）。
  static void _validateManifestForImport(Map<String, Object?> manifest) {
    final version = manifest['payloadVersion'];
    if (version is! int) {
      throw _invalid('manifest 缺少 payloadVersion');
    }
    if (version > kPayloadVersion) {
      // C4：只有主版本更高才拒读。
      throw ImportExportError.versionIncompatible(
        detail: '载荷版本 v$version 高于本实现支持的 v$kPayloadVersion',
      );
    }
    final kind = manifest['exportKind'];
    if (kind is! String || !kPayloadExportKinds.contains(kind)) {
      throw _invalid('manifest.exportKind 非法：$kind');
    }
    switch (kind) {
      case 'range':
        if (manifest['range'] is! Map<String, Object?>) {
          throw _invalid('exportKind=range 缺少 range（scope 与内容不符）');
        }
      case 'ledger':
        final ids = manifest['ledgerIds'];
        if (ids is! List<Object?> || ids.isEmpty) {
          throw _invalid('exportKind=ledger 缺少非空 ledgerIds（scope 与内容不符）');
        }
      case 'incremental':
        if (manifest['changeLogRange'] is! Map<String, Object?> ||
            manifest['sinceExportAt'] is! int) {
          throw _invalid('exportKind=incremental 缺少 changeLogRange / sinceExportAt');
        }
    }
  }

  static DomainError _invalid(String detail) =>
      DomainError.validation(detail: detail, userMessage: '这份导入文件的内容不合法（已停止处理，你的数据没有被修改）。');

  /// 「scope 与内容不符」—— 声明与实际内容的矛盾，而不是格式错误。
  ///
  /// 目前只有一条可判的：`exportKind=ledger` 的 `ledgerIds` 是**范围声明**，
  /// 文件里却混进了其它账本的行。这类矛盾必须在写入之前死掉 ——
  /// 放它过去，用户会在「我只导出一个账本」的前提下把另一个账本的数据并进来，
  /// 而事后没有任何办法把混进来的那部分摘出去（软删标记会破坏原账本的语义）。
  static void _validateScopeMatchesContent(
    Map<String, Object?> manifest,
    List<ImportRecord> records,
  ) {
    if (manifest['exportKind'] != 'ledger') {
      return;
    }
    final raw = manifest['ledgerIds'];
    final allowed = <String>{
      if (raw is List<Object?>)
        for (final item in raw)
          if (item is String) item,
    };
    for (final record in records) {
      // ledger 行自身没有 ledger_id 列，它的「账本」就是它的 id。
      final ledgerId = record.type == 'ledger' ? record.id : record.columns['ledger_id'];
      if (ledgerId is! String) {
        continue; // theme 之类不挂账本的类型
      }
      if (!allowed.contains(ledgerId)) {
        throw _invalid(
          'exportKind=ledger 声明只含账本 ${allowed.toList()..sort()}，'
          '但出现了属于账本 $ledgerId 的 ${record.type} 行（scope 与内容不符）',
        );
      }
    }
  }

  /// 「scope 与内容不符」的另一半：manifest 自报的条数与实际不符。
  ///
  /// 一个反直觉但必须如此的点：**只核对已知类型的条数**。
  /// 未知类型的行按 C2 要跳过并计数，它的条数天然对不上 ——
  /// 若一并核对，`V1 读 V2 文件` 会因为 V2 新增的类型而整份被拒，
  /// 与 C2 的要求当场打架。
  static void _validateCountsMatchContent(
    Map<String, Object?> manifest,
    Map<String, int> observedByType,
  ) {
    final raw = manifest['counts'];
    if (raw == null) {
      return; // 缺 counts 不做这项检查（它不是格式的必需字段）
    }
    if (raw is! Map<String, Object?>) {
      throw _invalid('manifest.counts 必须是对象');
    }
    for (final entry in raw.entries) {
      if (!kKnownRecordTypes.contains(entry.key)) {
        continue; // C2：未知类型不参与核对
      }
      final declared = entry.value;
      if (declared is! int) {
        throw _invalid('manifest.counts.${entry.key} 必须是整数');
      }
      final observed = observedByType[entry.key] ?? 0;
      if (declared != observed) {
        throw _invalid(
          'manifest.counts.${entry.key} 声明 $declared 条，实际 $observed 条'
          '（scope 与内容不符：文件被截断或被改动过）',
        );
      }
    }
  }
}

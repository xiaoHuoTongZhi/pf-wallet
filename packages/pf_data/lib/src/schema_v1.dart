/// schema v1 的建表迁移（方案 §2.3，FTS5 按 §2.6 方案 A 修正）。
///
// 本文件的 DDL 语句按可读行用相邻字符串拼接（每个元素对应一条 SQL），
// no_adjacent_strings_in_list 在这里只会制造噪音；SQL 字面量里含
// 单引号（如 IFNULL(parent_id,'')），引号风格也不能一刀切。
// ignore_for_file: no_adjacent_strings_in_list, prefer_single_quotes
///
/// ## 与规格原文的三处刻意的出入
///
///   1. **`PRAGMA foreign_keys = OFF/ON` 不在语句列表里。**
///      §2.3 把它写在脚本首尾，但那是"脚本式执行"的视角；迁移执行器
///      （[MigrationRunner]）按 §2.7 伪码统一在外层切换 —— 每个迁移
///      一事务、事务内 OFF→DDL→ON。放进语句列表反而会让"幂等重放"
///      无法与执行器的职责对齐。
///   2. **`txn_fts` 用 §2.6 方案 A，而不是 §2.3 原文。**
///      原文的 `content='txn', content_rowid='rowid'` 与 `WITHOUT ROWID`
///      不兼容（§2.6 自己指出的 bug）。方案 A：独立 FTS 表只存 `id`，
///      三个触发器手工同步。
///   3. **MVP 阶段其余全部照抄 §2.3**，包括 M1 暂不使用的
///      budget / attachment / theme_profile / sync_peer 等表 ——
///      §7.2 "不做但不留坑"：迁移只加不拆，事后加列比现在多写几行贵得多。
///
/// ## 为什么 schema DDL 是 Migration 对象而不是 .sql 文件
///
/// R4（校验和锁定）要求"改历史迁移"必须被发现。Migration 对象在 Dart
/// 源码里、进 git、随迁移执行器算 sha256 记入 `schema_migration` ——
/// 改一行语句，新旧库的 checksum 就对不上。独立 .sql 文件还要解决
/// "文件加载失败/编码漂移/语句切分歧义"，收益为零。
library;

import 'migration.dart';

/// 每条语句用注释标注来源小节，review 时可对照规格逐行核对。
const Migration schemaV1Migration = Migration(
  version: 1,
  description: '初始 schema：元信息 + 账本/账户/分类/交易/标签/预算/附件/主题 + 运维表（§2.3）',
  statements: <String>[
    // ---------- 元信息（§2.3，不含敏感数据） ----------
    'CREATE TABLE app_meta ('
        'key TEXT PRIMARY KEY, '
        'value TEXT NOT NULL'
        ') WITHOUT ROWID',
    'CREATE TABLE schema_migration ('
        'version INTEGER PRIMARY KEY, '
        'name TEXT NOT NULL, '
        'checksum TEXT NOT NULL, '
        'applied_at INTEGER NOT NULL, '
        'duration_ms INTEGER NOT NULL'
        ')',
    // ---------- 账本（§2.2：所有业务实体挂 ledger_id，导出最小单位） ----------
    'CREATE TABLE ledger ('
        'id TEXT PRIMARY KEY, '
        'name TEXT NOT NULL, '
        'code TEXT NOT NULL UNIQUE, '
        "currency TEXT NOT NULL DEFAULT 'CNY', "
        'is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0,1)), '
        'sort_order INTEGER NOT NULL DEFAULT 0, '
        'created_at INTEGER NOT NULL, '
        'updated_at INTEGER NOT NULL, '
        'deleted_at INTEGER, '
        'device_id TEXT NOT NULL, '
        'rev INTEGER NOT NULL DEFAULT 1'
        ') WITHOUT ROWID',
    'CREATE UNIQUE INDEX ux_ledger_default ON ledger(is_default) '
        'WHERE is_default = 1 AND deleted_at IS NULL',
    // ---------- 账户（§2.3；余额语义见 account 表注释） ----------
    // 关键语义（§2.3 原文）：
    //   · 储蓄/现金/钱包/投资：余额 ≥ 0 表示持有资产，可为负（透支）
    //   · 信用卡：余额为「负债」，消费使余额变小、还款使余额变大
    //     → 欠款 = -balance，可用额度 = credit_limit + MIN(0, cached_balance_minor)
    //   净资产 = Σ 所有账户 cached_balance_minor 在所有账户类型下统一成立。
    'CREATE TABLE account ('
        'id TEXT PRIMARY KEY, '
        'ledger_id TEXT NOT NULL REFERENCES ledger(id) ON DELETE RESTRICT, '
        'name TEXT NOT NULL, '
        'type INTEGER NOT NULL CHECK (type IN (1,2,3,4,5)), '
        'currency TEXT NOT NULL, '
        'opening_balance_minor INTEGER NOT NULL DEFAULT 0, '
        'cached_balance_minor INTEGER NOT NULL DEFAULT 0, '
        'balance_as_of INTEGER NOT NULL DEFAULT 0, '
        'credit_limit_minor INTEGER, '
        'statement_day INTEGER CHECK (statement_day BETWEEN 1 AND 31), '
        'due_day INTEGER CHECK (due_day BETWEEN 1 AND 31), '
        'repay_account_id TEXT REFERENCES account(id) ON DELETE RESTRICT, '
        'icon TEXT, '
        'color TEXT, '
        'is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0,1)), '
        'sort_order INTEGER NOT NULL DEFAULT 0, '
        'note TEXT, '
        'created_at INTEGER NOT NULL, '
        'updated_at INTEGER NOT NULL, '
        'deleted_at INTEGER, '
        'device_id TEXT NOT NULL, '
        'rev INTEGER NOT NULL DEFAULT 1, '
        'CHECK (type <> 3 OR credit_limit_minor IS NOT NULL), '
        'CHECK (repay_account_id IS NULL OR repay_account_id <> id)'
        ') WITHOUT ROWID',
    'CREATE INDEX ix_account_ledger ON account(ledger_id, sort_order) WHERE deleted_at IS NULL',
    'CREATE INDEX ix_account_upd ON account(updated_at, device_id)',
    // ---------- 分类（§2.3；二级 + 防环触发器） ----------
    'CREATE TABLE category ('
        'id TEXT PRIMARY KEY, '
        'ledger_id TEXT NOT NULL REFERENCES ledger(id) ON DELETE RESTRICT, '
        'parent_id TEXT REFERENCES category(id) ON DELETE RESTRICT, '
        'kind INTEGER NOT NULL CHECK (kind IN (1,2)), '
        'name TEXT NOT NULL, '
        'icon TEXT, '
        'color TEXT, '
        'is_system INTEGER NOT NULL DEFAULT 0 CHECK (is_system IN (0,1)), '
        'is_hidden INTEGER NOT NULL DEFAULT 0 CHECK (is_hidden IN (0,1)), '
        'sort_order INTEGER NOT NULL DEFAULT 0, '
        'created_at INTEGER NOT NULL, '
        'updated_at INTEGER NOT NULL, '
        'deleted_at INTEGER, '
        'device_id TEXT NOT NULL, '
        'rev INTEGER NOT NULL DEFAULT 1, '
        'CHECK (parent_id IS NULL OR parent_id <> id)'
        ') WITHOUT ROWID',
    // 软删后可复用同名；IFNULL 把 NULL 归一成 '' 才能进唯一索引（§2.3）
    'CREATE UNIQUE INDEX ux_category_name ON category(ledger_id, kind, IFNULL(parent_id,\'\'), name) '
        'WHERE deleted_at IS NULL',
    'CREATE INDEX ix_category_parent ON category(parent_id, sort_order)',
    // 二级分类硬限制（DB 兜底防脚本/导入写脏）
    "CREATE TRIGGER trg_category_depth_ins BEFORE INSERT ON category "
        'WHEN NEW.parent_id IS NOT NULL '
        'AND (SELECT parent_id FROM category WHERE id = NEW.parent_id) IS NOT NULL '
        "BEGIN SELECT RAISE(ABORT, 'PF_E_CATEGORY_DEPTH'); END",
    "CREATE TRIGGER trg_category_depth_upd BEFORE UPDATE OF parent_id ON category "
        'WHEN NEW.parent_id IS NOT NULL '
        'AND (SELECT parent_id FROM category WHERE id = NEW.parent_id) IS NOT NULL '
        "BEGIN SELECT RAISE(ABORT, 'PF_E_CATEGORY_DEPTH'); END",
    'CREATE TRIGGER trg_category_self BEFORE UPDATE OF parent_id ON category '
        'WHEN NEW.parent_id = NEW.id '
        "BEGIN SELECT RAISE(ABORT, 'PF_E_CATEGORY_CYCLE'); END",
    // ---------- 交易（§2.3 核心表；CHECK 约束把转账语义钉死在库里） ----------
    //   · type=3 必须有 to_account_id 且 ≠ account_id；非转账必须没有
    //   · 非转账必须有 category_id；转账的 category_id 必须为 NULL（仓储层保证）
    //   · amount 恒正，方向由 type 决定（§2.1：正负号 + 类型双语义是记账 App 最经典 bug）
    'CREATE TABLE txn ('
        'id TEXT PRIMARY KEY, '
        'ledger_id TEXT NOT NULL REFERENCES ledger(id) ON DELETE RESTRICT, '
        'type INTEGER NOT NULL CHECK (type IN (1,2,3)), '
        'amount_minor INTEGER NOT NULL CHECK (amount_minor > 0), '
        'currency TEXT NOT NULL, '
        'occurred_at INTEGER NOT NULL, '
        "day_key TEXT NOT NULL, "
        "month_key TEXT NOT NULL, "
        'tz_offset_min INTEGER NOT NULL DEFAULT 0, '
        'account_id TEXT NOT NULL REFERENCES account(id) ON DELETE RESTRICT, '
        'to_account_id TEXT REFERENCES account(id) ON DELETE RESTRICT, '
        'category_id TEXT REFERENCES category(id) ON DELETE RESTRICT, '
        'merchant TEXT, '
        'note TEXT, '
        "tags TEXT NOT NULL DEFAULT '[]', "
        'fee_minor INTEGER NOT NULL DEFAULT 0, '
        'is_reimbursable INTEGER NOT NULL DEFAULT 0 CHECK (is_reimbursable IN (0,1)), '
        'excluded_from_stats INTEGER NOT NULL DEFAULT 0 CHECK (excluded_from_stats IN (0,1)), '
        'source_import_job TEXT, '
        'created_at INTEGER NOT NULL, '
        'updated_at INTEGER NOT NULL, '
        'deleted_at INTEGER, '
        'device_id TEXT NOT NULL, '
        'origin_device_id TEXT NOT NULL, '
        'rev INTEGER NOT NULL DEFAULT 1, '
        'CHECK (type <> 3 OR (to_account_id IS NOT NULL AND to_account_id <> account_id)), '
        'CHECK (type = 3 OR to_account_id IS NULL), '
        'CHECK (type = 3 OR category_id IS NOT NULL), '
        'CHECK (fee_minor >= 0), '
        'CHECK (json_valid(tags))'
        ') WITHOUT ROWID',
    // 主列表：按日倒序 + 同日按 id 倒序（id 是 ULID，等价于创建时间倒序，稳定分页）
    'CREATE INDEX ix_txn_day ON txn(ledger_id, day_key DESC, id DESC) WHERE deleted_at IS NULL',
    'CREATE INDEX ix_txn_acct ON txn(account_id, day_key DESC) WHERE deleted_at IS NULL',
    'CREATE INDEX ix_txn_toacct ON txn(to_account_id, day_key DESC) WHERE deleted_at IS NULL',
    'CREATE INDEX ix_txn_cat ON txn(category_id, day_key DESC) WHERE deleted_at IS NULL',
    'CREATE INDEX ix_txn_month ON txn(ledger_id, month_key, type, category_id) WHERE deleted_at IS NULL',
    'CREATE INDEX ix_txn_amount ON txn(ledger_id, amount_minor) WHERE deleted_at IS NULL',
    // 增量导出/合并：不筛 deleted_at，必须能看到墓碑
    'CREATE INDEX ix_txn_upd ON txn(updated_at, device_id)',
    'CREATE INDEX ix_txn_origin ON txn(origin_device_id)',
    // ---------- 标签（§2.3） ----------
    'CREATE TABLE tag ('
        'id TEXT PRIMARY KEY, '
        'ledger_id TEXT NOT NULL REFERENCES ledger(id) ON DELETE RESTRICT, '
        'name TEXT NOT NULL, '
        'color TEXT, '
        'created_at INTEGER NOT NULL, '
        'updated_at INTEGER NOT NULL, '
        'deleted_at INTEGER, '
        'device_id TEXT NOT NULL, '
        'rev INTEGER NOT NULL DEFAULT 1'
        ') WITHOUT ROWID',
    'CREATE UNIQUE INDEX ux_tag_name ON tag(ledger_id, name) WHERE deleted_at IS NULL',
    // ---------- 预算（§2.3，MVP 不用但不留坑） ----------
    'CREATE TABLE budget ('
        'id TEXT PRIMARY KEY, '
        'ledger_id TEXT NOT NULL REFERENCES ledger(id) ON DELETE RESTRICT, '
        'period_type INTEGER NOT NULL CHECK (period_type IN (1,2)), '
        "period_key TEXT NOT NULL, "
        'scope INTEGER NOT NULL CHECK (scope IN (1,2)), '
        'category_id TEXT REFERENCES category(id) ON DELETE RESTRICT, '
        'amount_minor INTEGER NOT NULL CHECK (amount_minor >= 0), '
        'currency TEXT NOT NULL, '
        'rollover INTEGER NOT NULL DEFAULT 0 CHECK (rollover IN (0,1)), '
        'alert_bp INTEGER NOT NULL DEFAULT 8000 CHECK (alert_bp BETWEEN 0 AND 20000), '
        'created_at INTEGER NOT NULL, '
        'updated_at INTEGER NOT NULL, '
        'deleted_at INTEGER, '
        'device_id TEXT NOT NULL, '
        'rev INTEGER NOT NULL DEFAULT 1, '
        'CHECK ((scope = 1 AND category_id IS NULL) OR (scope = 2 AND category_id IS NOT NULL))'
        ') WITHOUT ROWID',
    'CREATE UNIQUE INDEX ux_budget_period ON budget(ledger_id, period_type, period_key, scope, IFNULL(category_id,\'\')) '
        'WHERE deleted_at IS NULL',
    'CREATE INDEX ix_budget_upd ON budget(updated_at, device_id)',
    // ---------- 附件（§2.3，V2 启用） ----------
    'CREATE TABLE attachment ('
        'id TEXT PRIMARY KEY, '
        'ledger_id TEXT NOT NULL REFERENCES ledger(id) ON DELETE RESTRICT, '
        'txn_id TEXT REFERENCES txn(id) ON DELETE CASCADE, '
        'file_name TEXT NOT NULL, '
        'mime TEXT NOT NULL, '
        'size_bytes INTEGER NOT NULL CHECK (size_bytes >= 0), '
        'sha256 TEXT NOT NULL, '
        'storage INTEGER NOT NULL CHECK (storage IN (1,2)), '
        'data BLOB, '
        'ext_rel_path TEXT, '
        'wrapped_dek BLOB, '
        'dek_nonce BLOB, '
        'width INTEGER, '
        'height INTEGER, '
        'created_at INTEGER NOT NULL, '
        'updated_at INTEGER NOT NULL, '
        'deleted_at INTEGER, '
        'device_id TEXT NOT NULL, '
        'rev INTEGER NOT NULL DEFAULT 1, '
        'CHECK ((storage = 1 AND data IS NOT NULL AND ext_rel_path IS NULL) '
        'OR (storage = 2 AND data IS NULL AND ext_rel_path IS NOT NULL))'
        ') WITHOUT ROWID',
    'CREATE INDEX ix_att_txn ON attachment(txn_id) WHERE deleted_at IS NULL',
    // ---------- 主题（§2.3 / §6.6，V1 启用） ----------
    'CREATE TABLE theme_profile ('
        'id TEXT PRIMARY KEY, '
        'name TEXT NOT NULL, '
        'spec_json TEXT NOT NULL CHECK (json_valid(spec_json)), '
        'is_active INTEGER NOT NULL DEFAULT 0 CHECK (is_active IN (0,1)), '
        'created_at INTEGER NOT NULL, '
        'updated_at INTEGER NOT NULL, '
        'deleted_at INTEGER, '
        'device_id TEXT NOT NULL, '
        'rev INTEGER NOT NULL DEFAULT 1'
        ') WITHOUT ROWID',
    'CREATE UNIQUE INDEX ux_theme_active ON theme_profile(is_active) WHERE is_active = 1 AND deleted_at IS NULL',
    // ============================================================
    // 同步/运维表（不参与导出）（§2.3）
    // ============================================================
    'CREATE TABLE change_log ('
        'seq INTEGER PRIMARY KEY AUTOINCREMENT, '
        'entity TEXT NOT NULL, '
        'entity_id TEXT NOT NULL, '
        'op INTEGER NOT NULL CHECK (op IN (1,2,3)), '
        'updated_at INTEGER NOT NULL, '
        'device_id TEXT NOT NULL, '
        'ledger_id TEXT, '
        'exported_at INTEGER'
        ')',
    'CREATE INDEX ix_cl_pending ON change_log(exported_at, seq)',
    'CREATE INDEX ix_cl_entity ON change_log(entity, entity_id, seq)',
    'CREATE TABLE import_job ('
        'id TEXT PRIMARY KEY, '
        'file_name TEXT NOT NULL, '
        'file_sha256 TEXT NOT NULL, '
        'mode INTEGER NOT NULL CHECK (mode IN (1,2,3)), '
        'status INTEGER NOT NULL CHECK (status IN (0,1,2,3)), '
        'started_at INTEGER NOT NULL, '
        'finished_at INTEGER, '
        'inserted_cnt INTEGER NOT NULL DEFAULT 0, '
        'updated_cnt INTEGER NOT NULL DEFAULT 0, '
        'skipped_cnt INTEGER NOT NULL DEFAULT 0, '
        'conflict_cnt INTEGER NOT NULL DEFAULT 0, '
        'removed_cnt INTEGER NOT NULL DEFAULT 0, '
        'backup_file TEXT, '
        'manifest_json TEXT NOT NULL, '
        'error_code TEXT'
        ') WITHOUT ROWID',
    'CREATE TABLE imported_file ('
        'file_sha256 TEXT PRIMARY KEY, '
        'file_name TEXT NOT NULL, '
        'job_id TEXT NOT NULL, '
        'imported_at INTEGER NOT NULL'
        ') WITHOUT ROWID',
    'CREATE TABLE conflict ('
        'id TEXT PRIMARY KEY, '
        'job_id TEXT NOT NULL REFERENCES import_job(id) ON DELETE CASCADE, '
        'entity TEXT NOT NULL, '
        'entity_id TEXT NOT NULL, '
        'kind INTEGER NOT NULL, '
        'local_json TEXT, '
        'remote_json TEXT, '
        'resolution INTEGER, '
        'resolved_at INTEGER'
        ') WITHOUT ROWID',
    'CREATE INDEX ix_conflict_pending ON conflict(job_id, resolution)',
    'CREATE TABLE sync_peer ('
        'device_id TEXT PRIMARY KEY, '
        'device_name TEXT NOT NULL, '
        'platform TEXT NOT NULL, '
        'app_version TEXT, '
        'last_seen_at INTEGER, '
        'last_export_seq INTEGER NOT NULL DEFAULT 0, '
        'last_import_at INTEGER, '
        'last_import_seq INTEGER NOT NULL DEFAULT 0, '
        'notes TEXT'
        ') WITHOUT ROWID',
    // ---------- 全文检索（§2.6 方案 A：独立 FTS 表 + 触发器，不用外部内容模式） ----------
    // §2.3 原文的 content='txn' 与 txn 的 WITHOUT ROWID 不兼容（§2.6 指出的 bug）。
    // 触发器使 FTS 与 txn 保持同步；trigram 分词支持中文子串搜索。
    // §2.6 决策：启动时用 `SELECT fts5(?1)` 探测可用性，不可用走 LIKE（SearchRepository 兜底），
    // 但 FTS 表随 v1 一起建 —— 加表是迁移，删表也是迁移，宁可先建。
    'CREATE VIRTUAL TABLE txn_fts USING fts5('
        'id UNINDEXED, '
        'merchant, note, '
        "tokenize='trigram'"
        ')',
    'CREATE TRIGGER trg_txn_fts_ai AFTER INSERT ON txn WHEN NEW.deleted_at IS NULL '
        'BEGIN '
        "INSERT INTO txn_fts(id, merchant, note) VALUES (NEW.id, IFNULL(NEW.merchant,''), IFNULL(NEW.note,'')); "
        'END',
    'CREATE TRIGGER trg_txn_fts_au AFTER UPDATE ON txn '
        'BEGIN '
        'DELETE FROM txn_fts WHERE id = OLD.id; '
        "INSERT INTO txn_fts(id, merchant, note) SELECT NEW.id, IFNULL(NEW.merchant,''), IFNULL(NEW.note,'') WHERE NEW.deleted_at IS NULL; "
        'END',
    'CREATE TRIGGER trg_txn_fts_ad AFTER DELETE ON txn '
        'BEGIN '
        'DELETE FROM txn_fts WHERE id = OLD.id; '
        'END',
  ],
);

/// 全部已注册的 schema 迁移（按版本号排列）。
///
/// 迁移链规则（R1/R4，见 migration.dart 与 §2.7）：一个版本号一个迁移、
/// 从初始版本（PfSchema.initial = 1）起连续、历史内容不可改 ——
/// 改动即 checksum 漂移。
const List<Migration> kRegisteredMigrations = <Migration>[schemaV1Migration];

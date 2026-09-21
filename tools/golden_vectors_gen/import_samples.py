#!/usr/bin/env python3
"""导入器（§4.3）的固定样本与黄金向量的生成器 —— 独立参考实现。

## 它产出两个文件

    test_vectors/fixtures/import_samples.json   样本字节（hex）+ 导入器读出来的东西
    test_vectors/v1/import_payload.json         四个 kind 的向量用例

前者是**样本字节的权威存放处**（`.pfb` 本体不允许入库 —— `tracked_paths.yaml`
的 `tracked-vault-file` 规则，B1 决策）。后者必须自包含：向量驱动不读文件系统
（`driver.dart` 的确定性要求），因此同一批 hex 会在向量里内联一份。
这份重复是刻意的，并且被 `--check` 断言（两份文件里的 hex 必须逐字节相同）。

## 期望值从哪来：两类，必须分清

**一、可独立推导的（真验证）**

  - **样本字节**：由本脚本用 `container_pfb.py`（Python `cryptography` +
    `argon2-cffi` + 手写打包）封包，与 Dart 的 `PfbContainer` 是两套实现；
    解开用 `container_pfb.open_pfb`，逐行对账 NDJSON。
  - **载荷的语义**：默认值来自 §2.3 的 `DEFAULT` 子句、合法取值来自 `CHECK`、
    列序来自 §2.3 的 DDL、`day_key`/`month_key` 的拆解来自 §2.1
    （复用 `balance_replay.py` 里那份独立实现）、余额重算复用同一份推演引擎。
  - **幂等/引用/版本这些行为**：直接按 §4.1 C1–C4 与 §4.3 伪码写出来，
    Dart 侧是实现，两者在向量处会合。

**二、编排契约的转录（回归锁，不是推导）**

  - `import.apply` 那一组里的 **SQL 措辞**（`INSERT INTO … (列)`、`SAVEPOINT
    import_stage`、台账表的 UPDATE 语句）在规格里没有逐字原文 —— 规格给的是
    表/列（§2.3）、阶段顺序（§4.3 I.1）、回滚点名字（§4.3 I）与「100% 参数化」
    这条硬约束。转录部分锁的是「以后不能悄悄改」，不是「当初推导得对」；
    凡属这一类的用例，`notes` 里都写明了。

## 用法

    python import_samples.py            # 自检 + 打印摘要，不写文件
    python import_samples.py --write    # 写入上面两个文件（LF 行尾）
    python import_samples.py --check    # 只用磁盘上的样本重算一遍并比对（不产出）
"""

from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import json
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import balance_replay  # noqa: E402  —— 同目录的独立推演引擎（§2.3 语义）
import container_pfb  # noqa: E402  —— 同目录的独立容器实现（§3.3）

REPO = Path(__file__).resolve().parents[2]
VECTOR_PATH = REPO / "test_vectors" / "v1" / "import_payload.json"
FIXTURE_PATH = REPO / "test_vectors" / "fixtures" / "import_samples.json"

# ---------------------------------------------------------------------------
# 固定输入：与 container_pfb.py 共用同一套随机源（「固定随机源」是字节级断言的前提）
# ---------------------------------------------------------------------------

PASSWORD = container_pfb.PASSWORD
WRONG_PASSWORD = container_pfb.WRONG_PASSWORD
KDF = container_pfb.FIXED_KDF
SALT = container_pfb.SALT
NONCE_PREFIX = container_pfb.NONCE_PREFIX
VOLUME_SET_ID = container_pfb.VOLUME_SET_ID

FLAG_AESGCM = container_pfb.FLAG_AESGCM
FLAG_GZIP = container_pfb.FLAG_GZIP
FLAG_CHUNKED = container_pfb.FLAG_CHUNKED
FLAG_HAS_ATTACH = container_pfb.FLAG_HAS_ATTACH

CHUNK_KIB = 1024

# ---------------------------------------------------------------------------
# 时间与 id（全部写死：向量必须可复现，且时间戳必须落在**过去** ——
# 载荷解码器有一条「updated_at 在未来 >24h 则告警」的规则，样本若用未来时间，
# 期望值会随时间漂移）
# ---------------------------------------------------------------------------

DEVICE = "01J8Z9K2M4P6Q8R0T2V4X6Z8B1"
CREATED = 1789452000000  # 2026-09-15T06:00:00Z
OCCURRED_1 = 1789452000000  # 同上（tz+480 → 2026-09-15 14:00）
OCCURRED_2 = 1789455600000  # 2026-09-15T07:00:00Z
UPDATED_1 = 1789455600000
UPDATED_DELETED = 1789538400000  # 2026-09-16T07:00:00Z

L1 = "01J8TESTLEDGER0000000000001"
A1 = "01J8TESTACCNT00000000000001"
A2 = "01J8TESTACCNT00000000000002"
C1 = "01J8TESTCATEG0000000000001"
C2 = "01J8TESTCATEG0000000000002"
T1 = "01J8TESTTAG000000000000001"
TH1 = "01J8TESTTHEME0000000000001"
X1 = "01J8TESTTXN00000000000001"
X2 = "01J8TESTTXN00000000000002"
X3 = "01J8TESTTXN00000000000003"
XT = "01J8TESTTXN00000000000009"
B1 = "01J8TESTBUDGT0000000000001"
AT1 = "01J8TESTATTCH0000000000001"

# 附件内容：四个字节的 PNG 魔数 + 一段填充（**不是**真图片，只是字节）
ATTACHMENT_BYTES = b"\x89PNG\r\n\x1a\n" + bytes(range(0x20, 0x40))
ATTACHMENT_B64 = base64.b64encode(ATTACHMENT_BYTES).decode("ascii")
ATTACHMENT_SHA256 = hashlib.sha256(ATTACHMENT_BYTES).hexdigest()

# ---------------------------------------------------------------------------
# 字段表：**从 §2.3 的 DDL 逐条转录**（jsonKey, column, kind, default）
#
#   kind：text 必填文本 / otext 可空文本 / int 必填整数 / oint 可空整数
#         flag 0|1 / oid 可空 id / idlist id 数组 / json JSON 对象
#         b64 Base64 → BLOB / day,month 派生日历键
#   default：§2.3 的 DEFAULT 子句原文；None 表示「没有默认值」
#
# 列序即 §2.3 DDL 的列序 —— 它同时是导入写入语句的列序。
# 「缺字段取默认值」与「可空字段缺省为 NULL」由 kind + default 共同决定：
# 本文件里的 `is_required` 必须与 Dart 侧 `PayloadField.required` 同口径。
# ---------------------------------------------------------------------------

COMMON = [
    ("createdAt", "created_at", "int", None),
    ("updatedAt", "updated_at", "int", None),
    ("deletedAt", "deleted_at", "oint", None),
    ("deviceId", "device_id", "text", None),
    ("rev", "rev", "int", 1),
]

TYPES: dict[str, list[tuple[str, str, str, object]]] = {
    "ledger": [
        ("id", "id", "text", None),
        ("name", "name", "text", None),
        ("code", "code", "text", None),
        ("currency", "currency", "text", "CNY"),
        ("isDefault", "is_default", "flag", 0),
        ("sortOrder", "sort_order", "int", 0),
        *COMMON,
    ],
    "account": [
        ("id", "id", "text", None),
        ("ledgerId", "ledger_id", "text", None),
        ("name", "name", "text", None),
        # 载荷键 `accountType`（不是 `type`）：判别键在记录行里独占，
        # 同名会被 JSON 的「取末次」规则吞掉判别键 —— 2026-09-21 裁决。
        ("accountType", "type", "int", None),
        ("currency", "currency", "text", None),
        ("openingBalanceMinor", "opening_balance_minor", "int", 0),
        ("cachedBalanceMinor", "cached_balance_minor", "int", 0),
        ("balanceAsOf", "balance_as_of", "int", 0),
        ("creditLimitMinor", "credit_limit_minor", "oint", None),
        ("statementDay", "statement_day", "oint", None),
        ("dueDay", "due_day", "oint", None),
        ("repayAccountId", "repay_account_id", "oid", None),
        ("icon", "icon", "otext", None),
        ("color", "color", "otext", None),
        ("isArchived", "is_archived", "flag", 0),
        ("sortOrder", "sort_order", "int", 0),
        ("note", "note", "otext", None),
        *COMMON,
    ],
    "category": [
        ("id", "id", "text", None),
        ("ledgerId", "ledger_id", "text", None),
        ("parentId", "parent_id", "oid", None),
        ("kind", "kind", "int", None),
        ("name", "name", "text", None),
        ("icon", "icon", "otext", None),
        ("color", "color", "otext", None),
        ("isSystem", "is_system", "flag", 0),
        ("isHidden", "is_hidden", "flag", 0),
        ("sortOrder", "sort_order", "int", 0),
        *COMMON,
    ],
    "tag": [
        ("id", "id", "text", None),
        ("ledgerId", "ledger_id", "text", None),
        ("name", "name", "text", None),
        ("color", "color", "otext", None),
        *COMMON,
    ],
    # 键是**表名**（theme_profile），不是载荷类型名（theme）——
    # 本字典的消费方（required_columns / default_for / explain_record）拿到的
    # 都是经 TABLE_OF_TYPE 归一后的表名。载荷类型名 → 表名的唯一映射在 TABLE_OF_TYPE。
    "theme_profile": [
        ("id", "id", "text", None),
        ("name", "name", "text", None),
        ("specJson", "spec_json", "json", {}),
        ("isActive", "is_active", "flag", 0),
        *COMMON,
    ],
    # txn 不用 COMMON：§2.3 的 DDL 把 origin_device_id 放在 device_id 与 rev 之间，
    # 而 source_import_job 虽然在 DDL 里，却**不在载荷里**（导入时才填）。
    "txn": [
        ("id", "id", "text", None),
        ("ledgerId", "ledger_id", "text", None),
        # 载荷键 `txnType`（不是 `type`）：理由同 account 行。
        ("txnType", "type", "int", None),
        ("amountMinor", "amount_minor", "int", None),
        ("currency", "currency", "text", None),
        ("occurredAt", "occurred_at", "int", None),
        ("dayKey", "day_key", "day", ""),
        ("monthKey", "month_key", "month", ""),
        ("tzOffsetMin", "tz_offset_min", "int", 0),
        ("accountId", "account_id", "text", None),
        ("toAccountId", "to_account_id", "oid", None),
        ("categoryId", "category_id", "oid", None),
        ("merchant", "merchant", "otext", None),
        ("note", "note", "otext", None),
        ("tags", "tags", "idlist", []),
        ("feeMinor", "fee_minor", "int", 0),
        ("isReimbursable", "is_reimbursable", "flag", 0),
        ("excludedFromStats", "excluded_from_stats", "flag", 0),
        ("createdAt", "created_at", "int", None),
        ("updatedAt", "updated_at", "int", None),
        ("deletedAt", "deleted_at", "oint", None),
        ("deviceId", "device_id", "text", None),
        ("originDeviceId", "origin_device_id", "text", None),
        ("rev", "rev", "int", 1),
    ],
    "budget": [
        ("id", "id", "text", None),
        ("ledgerId", "ledger_id", "text", None),
        ("periodType", "period_type", "int", None),
        ("periodKey", "period_key", "text", None),
        ("scope", "scope", "int", None),
        ("categoryId", "category_id", "oid", None),
        ("amountMinor", "amount_minor", "int", None),
        ("currency", "currency", "text", None),
        ("rollover", "rollover", "flag", 0),
        ("alertBp", "alert_bp", "int", 8000),
        *COMMON,
    ],
    "attachment": [
        ("id", "id", "text", None),
        ("ledgerId", "ledger_id", "text", None),
        ("txnId", "txn_id", "oid", None),
        ("fileName", "file_name", "text", None),
        ("mime", "mime", "text", None),
        ("sizeBytes", "size_bytes", "int", None),
        ("sha256", "sha256", "text", None),
        ("storage", "storage", "int", None),
        ("dataB64", "data", "b64", None),
        ("extRelPath", "ext_rel_path", "otext", None),
        ("wrappedDek", "wrapped_dek", "b64", None),
        ("dekNonce", "dek_nonce", "b64", None),
        ("width", "width", "oint", None),
        ("height", "height", "oint", None),
        *COMMON,
    ],
}

TABLE_OF_TYPE = {
    "ledger": "ledger",
    "account": "account",
    "category": "category",
    "tag": "tag",
    "theme": "theme_profile",
    "txn": "txn",
    "budget": "budget",
    "attachment": "attachment",
}

STAGE_ORDER = ["ledger", "account", "category", "tag", "theme", "txn", "budget", "attachment"]

# 记录行的判别键（§4.1）。在载荷里独占：业务列 account.type / txn.type
# 在载荷层改名 accountType / txnType（2026-09-21 裁决）。
DISCRIMINATOR = "type"

# 派生态：导出照带、导入丢弃（§4.3 末段）
DROP_ON_IMPORT = {"cached_balance_minor", "balance_as_of"}

# §2.3 的 CHECK 约束（只用于生成**非法**样本；合法样本不依赖它）
ALLOWED_INTS = {
    ("account", "type"): [1, 2, 3, 4, 5],
    ("category", "kind"): [1, 2],
    ("txn", "type"): [1, 2, 3],
    ("budget", "period_type"): [1, 2],
    ("budget", "scope"): [1, 2],
    ("attachment", "storage"): [1, 2],
}

# ---------------------------------------------------------------------------
# 引用完整性规则（§4.3 I.4 的「外键孤儿扫描」）。与 Dart 侧
# ImportIntegrityCheck.referenceRules 同一张表，顺序相同。
# ---------------------------------------------------------------------------

REFERENCE_RULES = [
    ("account", "ledger_id", "ledger"),
    ("account", "repay_account_id", "account"),
    ("category", "ledger_id", "ledger"),
    ("category", "parent_id", "category"),
    ("tag", "ledger_id", "ledger"),
    ("txn", "ledger_id", "ledger"),
    ("txn", "account_id", "account"),
    ("txn", "to_account_id", "account"),
    ("txn", "category_id", "category"),
    ("budget", "ledger_id", "ledger"),
    ("budget", "category_id", "category"),
    ("attachment", "ledger_id", "ledger"),
    ("attachment", "txn_id", "txn"),
]


def rule_key(child: str, column: str) -> str:
    return f"{child}.{column}"


def orphan_sql(child: str, column: str, parent: str) -> str:
    return f"SELECT COUNT(*) AS n FROM {child} WHERE {column} NOT IN (SELECT id FROM {parent})"


# ---------------------------------------------------------------------------
# 导入写入编排的 SQL（**转录**：见文件头「第二类期望值」）
#
# 转录自 packages/pf_io/lib/src/import_apply.dart 与
# packages/pf_data/lib/src/balance_recalc.dart。它们不是独立推导出来的，
# 作用是让「悄悄改一条写入语句」必须同时改向量文件（diff 里看得见）。
# ---------------------------------------------------------------------------

FIND_IMPORTED_FILE_SQL = "SELECT job_id, imported_at FROM imported_file WHERE file_sha256 = ?"
MARK_IMPORTED_FILE_SQL = (
    "INSERT INTO imported_file (file_sha256, file_name, job_id, imported_at) VALUES (?, ?, ?, ?)"
)
CREATE_JOB_SQL = (
    "INSERT INTO import_job "
    "(id, file_name, file_sha256, mode, status, started_at, backup_file, manifest_json) "
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
)
FINISH_JOB_SQL = (
    "UPDATE import_job SET status = ?, finished_at = ?, inserted_cnt = ?, updated_cnt = ?, "
    "skipped_cnt = ?, conflict_cnt = ?, removed_cnt = ?, error_code = ? WHERE id = ?"
)
SAVEPOINT_SQL = "SAVEPOINT import_stage"
ROLLBACK_TO_SQL = "ROLLBACK TO import_stage"
RELEASE_SQL = "RELEASE import_stage"
QUICK_CHECK_SQL = "PRAGMA quick_check"

# 余额重算的两条语句在向量里用记号代替（见 m1_import.dart 的说明）
RECALC_TOKEN = "<balance.recalc>"
RESET_TOKEN = "<balance.reset>"

# import_job 的取值（§2.3 只给 CHECK (mode IN (1,2,3)) / CHECK (status IN (0,1,2,3))，
# 命名是本实现的裁决；向量把它锁死）
MODE_MERGE = 1
STATUS_RUNNING = 0
STATUS_OK = 1
STATUS_FAILED = 3

APPLY_NOW = 1789550000000  # 2026-09-17T07:00:00Z，晚于样本里所有 updated_at


# ---------------------------------------------------------------------------
# NDJSON 载荷
# ---------------------------------------------------------------------------


def line_bytes(obj: dict) -> bytes:
    return (json.dumps(obj, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")


def build_payload(manifest: dict, records: list[dict], generated_at: int, *,
                  version: int = 1, hashed_records: list[dict] | None = None,
                  declared_digest: str | None = None,
                  drop_end: bool = False, end_record_count: int | None = None) -> bytes:
    """独立实现 §4.1 的载荷布局（与 Dart 编码器是两套实现）。

    contentHash 覆盖「manifest 与 end 之间的全部字节」—— 与 §3.2 的
    「所有非 manifest 行」等价，但口径写得更死：未知类型的行也在这段字节里，
    这正是 C2 与 manifest 摘要能同时成立的前提。

    `declared_digest` 是**故意让声明与实际不符**的入口（不带 `sha256:` 前缀）：
    「有人改了记录行却没重算摘要」这个攻击场景没法用 `hashed_records` 表达 ——
    那个参数同时决定产出字节与摘要，两侧永远自洽。要构造不一致，
    必须能分别指定「字节」与「声明的摘要」。
    """
    hashed = hashed_records if hashed_records is not None else records
    body = b"".join(line_bytes(r) for r in hashed)
    digest = declared_digest if declared_digest is not None else hashlib.sha256(body).hexdigest()
    head = {**manifest, "payloadVersion": version, "contentHash": f"sha256:{digest}"}
    out = line_bytes(head) + body
    if not drop_end:
        out += line_bytes({
            "type": "end",
            "recordCount": len(records) if end_record_count is None else end_record_count,
            "contentHash": f"sha256:{digest}",
            "generatedAt": generated_at,
        })
    return out


def manifest_of(kind: str, counts: dict, includes_attachments: bool, *,
                ledger_ids: list[str] | None = None,
                day_range: dict | None = None,
                change_log_range: dict | None = None,
                since_export_at: int | None = None,
                exported_at: int = OCCURRED_1) -> dict:
    """按 §4.1 的字段顺序构造 manifest（键序影响 .pfb 字节，因此写死）。"""
    m: dict = {
        "type": "manifest",
        "appVersion": "1.0.0",
        "deviceId": DEVICE,
        "deviceName": "向量生成器",
        "platform": "android",
        "exportedAt": exported_at,
        "exportKind": kind,
    }
    if day_range is not None:
        m["range"] = day_range
    if ledger_ids is not None:
        m["ledgerIds"] = ledger_ids
    if change_log_range is not None:
        m["changeLogRange"] = change_log_range
    if since_export_at is not None:
        m["sinceExportAt"] = since_export_at
    m["includesAttachments"] = includes_attachments
    m["counts"] = counts
    return m


# ---------------------------------------------------------------------------
# 样本记录（§4.1 的行形状；键序与 DDL 一致，便于人工核对）
# ---------------------------------------------------------------------------


def row_ledger(rev: int = 1) -> dict:
    return {
        "type": "ledger", "id": L1, "name": "日常", "code": "MAIN01", "currency": "CNY",
        "isDefault": 1, "sortOrder": 0, "createdAt": CREATED, "updatedAt": CREATED,
        "deletedAt": None, "deviceId": DEVICE, "rev": rev,
    }


def row_account_a1(*, cached: int = 1284500, deleted_at: int | None = None,
                   rev: int = 1, extra: dict | None = None) -> dict:
    row = {
        "type": "account", "id": A1, "ledgerId": L1, "name": "招行储蓄卡", "accountType": 2,
        "currency": "CNY", "openingBalanceMinor": 0, "cachedBalanceMinor": cached,
        "balanceAsOf": OCCURRED_2, "creditLimitMinor": None, "statementDay": None,
        "dueDay": None, "repayAccountId": None, "icon": "card", "color": "#3B82F6",
        "isArchived": 0, "sortOrder": 1, "note": None, "createdAt": CREATED,
        "updatedAt": CREATED, "deletedAt": deleted_at, "deviceId": DEVICE, "rev": rev,
    }
    if extra:
        row.update(extra)
    return row


def row_account_a2(*, opening: int = 500000, cached: int = 500000,
                   deleted_at: int | None = None, updated_at: int = CREATED) -> dict:
    return {
        "type": "account", "id": A2, "ledgerId": L1, "name": "现金", "accountType": 1,
        "currency": "CNY", "openingBalanceMinor": opening, "cachedBalanceMinor": cached,
        "balanceAsOf": 0, "creditLimitMinor": None, "statementDay": None, "dueDay": None,
        "repayAccountId": None, "icon": "wallet", "color": "#10B981", "isArchived": 0,
        "sortOrder": 2, "note": None, "createdAt": CREATED, "updatedAt": updated_at,
        "deletedAt": deleted_at, "deviceId": DEVICE, "rev": 1,
    }


def row_category_c1() -> dict:
    return {
        "type": "category", "id": C1, "ledgerId": L1, "parentId": None, "kind": 1,
        "name": "餐饮", "icon": "restaurant", "color": "#F97316", "isSystem": 1,
        "isHidden": 0, "sortOrder": 10, "createdAt": CREATED, "updatedAt": CREATED,
        "deletedAt": None, "deviceId": DEVICE, "rev": 1,
    }


def row_category_c2() -> dict:
    return {
        "type": "category", "id": C2, "ledgerId": L1, "parentId": C1, "kind": 1,
        "name": "咖啡", "icon": "cafe", "color": "#F97316", "isSystem": 0, "isHidden": 0,
        "sortOrder": 20, "createdAt": CREATED, "updatedAt": CREATED, "deletedAt": None,
        "deviceId": DEVICE, "rev": 1,
    }


def row_tag() -> dict:
    return {
        "type": "tag", "id": T1, "ledgerId": L1, "name": "出差", "color": "#8B5CF6",
        "createdAt": CREATED, "updatedAt": CREATED, "deletedAt": None, "deviceId": DEVICE,
        "rev": 1,
    }


def row_theme() -> dict:
    return {
        "type": "theme", "id": TH1, "name": "我的配色", "specJson": {"primary": "#3B82F6"},
        "isActive": 1, "createdAt": CREATED, "updatedAt": CREATED, "deletedAt": None,
        "deviceId": DEVICE, "rev": 1,
    }


def row_txn_x1(*, keys: bool, extra: dict | None = None) -> dict:
    """收入一笔（type=2）。keys=False 时**不带** dayKey/monthKey → 由导入端派生。"""
    row = {
        "type": "txn", "id": X1, "ledgerId": L1, "txnType": 2, "amountMinor": 3800,
        "currency": "CNY", "occurredAt": OCCURRED_1, "tzOffsetMin": 480,
        "accountId": A1, "toAccountId": None, "categoryId": C1, "merchant": "星巴克",
        "note": "拿铁", "tags": [T1], "feeMinor": 0, "isReimbursable": 0,
        "excludedFromStats": 0, "createdAt": CREATED, "updatedAt": UPDATED_1,
        "deletedAt": None, "deviceId": DEVICE, "originDeviceId": DEVICE, "rev": 1,
    }
    if keys:
        row["dayKey"] = "2026-09-15"
        row["monthKey"] = "2026-09"
    if extra:
        row.update(extra)
    return row


def row_txn_x2() -> dict:
    """转账（type=3）到软删账户 A2：证明「被删的实体仍然解引用」（§4.4 S18）。"""
    return {
        "type": "txn", "id": X2, "ledgerId": L1, "txnType": 3, "amountMinor": 50000,
        "currency": "CNY", "occurredAt": OCCURRED_2, "dayKey": "2026-09-15",
        "monthKey": "2026-09", "tzOffsetMin": 480, "accountId": A1, "toAccountId": A2,
        "categoryId": None, "merchant": None, "note": None, "tags": [], "feeMinor": 0,
        "isReimbursable": 0, "excludedFromStats": 0, "createdAt": CREATED,
        "updatedAt": CREATED, "deletedAt": None, "deviceId": DEVICE,
        "originDeviceId": DEVICE, "rev": 1,
    }


def row_txn_x3() -> dict:
    return {
        "type": "txn", "id": X3, "ledgerId": L1, "txnType": 2, "amountMinor": 9900,
        "currency": "CNY", "occurredAt": OCCURRED_2, "tzOffsetMin": 480, "accountId": A1,
        "toAccountId": None, "categoryId": C1, "merchant": None, "note": None,
        "tags": [], "feeMinor": 0, "isReimbursable": 0, "excludedFromStats": 0,
        "createdAt": UPDATED_1, "updatedAt": UPDATED_1, "deletedAt": None,
        "deviceId": DEVICE, "originDeviceId": DEVICE, "rev": 3,
    }


def row_txn_xt(*, amount: int = 12345) -> dict:
    return {
        "type": "txn", "id": XT, "ledgerId": L1, "txnType": 3, "amountMinor": amount,
        "currency": "CNY", "occurredAt": OCCURRED_1, "tzOffsetMin": 480, "accountId": A1,
        "toAccountId": A2, "categoryId": None, "merchant": None, "note": None,
        "tags": [], "feeMinor": 0, "isReimbursable": 0, "excludedFromStats": 0,
        "createdAt": CREATED, "updatedAt": CREATED, "deletedAt": None, "deviceId": DEVICE,
        "originDeviceId": DEVICE, "rev": 1,
    }


def row_budget() -> dict:
    return {
        "type": "budget", "id": B1, "ledgerId": L1, "periodType": 1, "periodKey": "2026-09",
        "scope": 2, "categoryId": C1, "amountMinor": 150000, "currency": "CNY",
        "rollover": 0, "alertBp": 8000, "createdAt": CREATED, "updatedAt": CREATED,
        "deletedAt": None, "deviceId": DEVICE, "rev": 1,
    }


def row_attachment(*, storage: int = 1) -> dict:
    row = {
        "type": "attachment", "id": AT1, "ledgerId": L1, "txnId": X1,
        "fileName": "发票.jpg", "mime": "image/jpeg",
        "sizeBytes": len(ATTACHMENT_BYTES), "sha256": ATTACHMENT_SHA256,
        "storage": storage, "width": 1200, "height": 900,
        "createdAt": CREATED, "updatedAt": CREATED, "deletedAt": None, "deviceId": DEVICE,
        "rev": 1,
    }
    if storage == 1:
        # storage=1：内容内联在 data 列，ext_rel_path 必须为 NULL（§2.3 CHECK）
        row["dataB64"] = ATTACHMENT_B64
    else:
        # storage=2：内容在外部文件，data / wrapped_dek / dek_nonce 都必须缺席。
        # 这三个字段**没有**键也**没有**默认值 —— 一条只存外部路径的附件行
        # 正是「可空字段不等于必需字段」的证据。
        row["extRelPath"] = "attachments/2026/09/a1.jpg"
    return row


# ---------------------------------------------------------------------------
# 样本定义
# ---------------------------------------------------------------------------


def sample_full() -> dict:
    records = [
        row_ledger(),
        row_account_a1(),
        row_account_a2(deleted_at=UPDATED_DELETED, updated_at=UPDATED_DELETED),
        row_category_c1(),
        row_category_c2(),
        row_tag(),
        row_theme(),
        # 多一个 V2 才有的未知字段：C1 要求忽略它，且它仍在 contentHash 覆盖范围里
        row_txn_x1(keys=False, extra={"unknownV2Field": "应被忽略"}),
        row_txn_x2(),
        row_budget(),
        row_attachment(),
    ]
    manifest = manifest_of(
        "full",
        {"ledger": 1, "account": 2, "category": 2, "tag": 1, "theme": 1, "txn": 2,
         "budget": 1, "attachment": 1},
        includes_attachments=True,
    )
    return {
        "id": "sample-full",
        "title": "full 导出：含内联附件、一个软删账户、以及一条与重算结果不一致的缓存余额",
        "records": records,
        "manifest": manifest,
        "flags": FLAG_AESGCM | FLAG_GZIP | FLAG_CHUNKED | FLAG_HAS_ATTACH,
        "notes": (
            "这一份同时承担三件事：(1) 三种 scope 之外的基线（全部阶段都在）；"
            "(2) account.cachedBalanceMinor=1284500 与按本文件交易重算的结果"
            "（A1 = -46200）不一致 —— 导入端必须丢弃文件里的值并全量重算；"
            "(3) A2 是软删账户，仍被转账 X2 引用（§4.4 S18：引用了已删实体不是错误）。"
            "txn X1 刻意**不带** dayKey/monthKey（派生路径），X2 显式带上（直读路径）。"
            "X1 还带了一个 V2 才有的未知字段，用于 C1。"
        ),
    }


def sample_range() -> dict:
    records = [
        row_ledger(),
        row_account_a1(cached=0),
        row_account_a2(),
        row_category_c1(),
        row_txn_x1(keys=True),
        row_txn_x2(),
    ]
    manifest = manifest_of(
        "range",
        {"ledger": 1, "account": 2, "category": 1, "txn": 2},
        includes_attachments=False,
        day_range={"fromDayKey": "2026-09-01", "toDayKey": "2026-09-15"},
    )
    return {
        "id": "sample-range",
        "title": "range 导出：带 range 声明的区间导出（无附件、无 tag/theme/budget）",
        "records": records,
        "manifest": manifest,
        "flags": FLAG_AESGCM | FLAG_GZIP | FLAG_CHUNKED,
        "notes": (
            "exportKind=range 必须携带 range（§4.1）；缺 range 的 range 载荷会被"
            "「scope 与内容不符」拒绝。这一份也是 import.file.read 里各类**损坏/版本**"
            "变体的底本 —— 它比 full 小，变体的 hex 因此不至于把向量文件撑爆。"
        ),
    }


def sample_ledger() -> dict:
    records = [
        row_ledger(),
        row_account_a1(cached=0),
        row_category_c1(),
        row_txn_x1(keys=True),
    ]
    manifest = manifest_of(
        "ledger",
        {"ledger": 1, "account": 1, "category": 1, "txn": 1},
        includes_attachments=False,
        ledger_ids=[L1],
    )
    return {
        "id": "sample-ledger",
        "title": "ledger 导出：只含一个账本（ledgerIds 是范围声明）",
        "records": records,
        "manifest": manifest,
        "flags": FLAG_AESGCM | FLAG_GZIP | FLAG_CHUNKED,
        "notes": (
            "ledgerIds 不只是元数据：它声明「这份文件只含这些账本」。"
            "decode 向量里有一条变体把某一行的 ledgerId 换成别的账本 —— "
            "混账本导入事后无法摘除（软删标记会破坏原账本语义），必须在写入前死掉。"
        ),
    }


def sample_incremental() -> dict:
    records = [row_txn_x3()]
    manifest = manifest_of(
        "incremental",
        {"txn": 1},
        includes_attachments=False,
        change_log_range={"minSeq": 120, "maxSeq": 456},
        since_export_at=1789000000000,
    )
    return {
        "id": "sample-incremental",
        "title": "incremental 导出：只含 1 条交易（changeLogRange + sinceExportAt）",
        "records": records,
        "manifest": manifest,
        "flags": FLAG_AESGCM | FLAG_GZIP | FLAG_CHUNKED | container_pfb.FLAG_INCREMENTAL,
        "notes": (
            "增量文件里只有交易 —— 它引用的 ledger/account/category 必须已经在本地库里。"
            "这正是「引用完整性」在真实场景下的样子，也是 §4.4 S11/S12（缺父实体）"
            "为什么需要裁决表：本提交的选择是**整体回滚**，绝不悄悄造占位实体。"
        ),
    }


def sample_apply_minimal() -> dict:
    """刻意做小：import.apply 的期望值要逐条列出语句与参数，样本越小越好读。"""
    records = [
        row_ledger(),
        row_account_a1(cached=0),
        row_account_a2(),
        row_txn_xt(),
    ]
    manifest = manifest_of(
        "full",
        {"ledger": 1, "account": 2, "txn": 1},
        includes_attachments=False,
    )
    return {
        "id": "sample-apply-minimal",
        "title": "写入编排的最小样本：1 个账本 + 2 个账户 + 1 笔转账",
        "records": records,
        "manifest": manifest,
        "flags": FLAG_AESGCM | FLAG_GZIP | FLAG_CHUNKED,
        "notes": (
            "只服务 import.apply：它要打印**完整语句日志**（含每条语句的参数），"
            "样本一大，向量文件就没法读了。转账而非收支，是因为转账不需要分类行，"
            "四行记录就能把「父实体先行」这条顺序要求压出来。"
        ),
    }


SAMPLES = [
    sample_full,
    sample_range,
    sample_ledger,
    sample_incremental,
    sample_apply_minimal,
]


# ---------------------------------------------------------------------------
# 导入期解释：载荷行 → 写入列（Dart 侧 PfbPayloadDecoder._buildRecord 的镜像）
# ---------------------------------------------------------------------------


def default_value(kind: str, default: object) -> object:
    """与 Dart 侧 `_defaultValue` 同口径。

    列表/对象类型的默认值在**库里是序列化后的文本**，不是 Python 的 list/dict ——
    `tags TEXT NOT NULL DEFAULT '[]'` 存的是字符串 `'[]'`。少了这一步，
    向量与实现会在 `tags` 缺省时给出 `[]` 与 `'[]'`（真差异，不是键序）。
    """
    if kind in ("idlist", "json"):
        return json.dumps(default, separators=(",", ":"), ensure_ascii=False)
    return default


def is_required(kind: str, default: object) -> bool:
    """与 Dart 侧 PayloadField.required 同口径。

    可空 kind（otext/oint/oid/b64）**不是**必需字段 —— 缺省语义就是 NULL。
    """
    if default is not None:
        return False
    return kind not in ("otext", "oint", "oid", "b64")


def required_columns(table: str) -> list[str]:
    return [
        column for _, column, kind, default in TYPES[table]
        if not is_required(kind, default)
    ]


def default_for(table: str, column: str) -> object:
    for _, col, _kind, default in TYPES[table]:
        if col == column:
            return default
    raise KeyError(f"{table}.{column}")


def derived_keys(occurred_at: int, tz_offset_min: int) -> tuple[str, str]:
    """§2.1 的日历拆解 —— 复用 balance_replay.py 的独立实现。"""
    return balance_replay.day_key(occurred_at, tz_offset_min)


def explain_record(record: dict) -> dict:
    """把一条载荷行解释成「导入器会写进库的列」—— 期望值的来源。"""
    type_name = record["type"]
    table = TABLE_OF_TYPE[type_name]
    pending: dict[str, object] = {}
    for json_key, column, kind, default in TYPES[table]:
        if column in DROP_ON_IMPORT:
            continue  # 派生态：显式丢弃
        if json_key not in record or record[json_key] is None:
            if kind in ("day", "month"):
                continue  # 交给派生
            if is_required(kind, default):
                raise AssertionError(f"{type_name} 行缺少必需字段 {json_key}")
            # 「缺失」与「显式为 null」同路：都落到 DEFAULT。
            # 显式 null 不能照原样写进去 —— 有 DEFAULT 的列通常也是 NOT NULL，
            # 那句 INSERT 会被 SQL 拒掉，把一个可定位的数据问题变成事务里的
            # 一句 NOT NULL constraint failed（Dart 侧同口径）。
            pending[column] = default_value(kind, default)
            continue
        value = record[json_key]
        if kind == "idlist":
            pending[column] = json.dumps(value, separators=(",", ":"), ensure_ascii=False)
        elif kind == "json":
            pending[column] = json.dumps(value, separators=(",", ":"), ensure_ascii=False)
        elif kind == "b64":
            pending[column] = {"hex": base64.b64decode(value).hex()}
        elif kind in ("int", "oint", "flag"):
            pending[column] = int(value)
        else:
            pending[column] = value

    if table == "txn":
        day, month = derived_keys(int(record["occurredAt"]), int(record.get("tzOffsetMin", 0)))
        pending.setdefault("day_key", day)
        pending.setdefault("month_key", month)

    # 第二遍：按字段表序装配（等于写入列序）
    columns: dict[str, object] = {}
    for _, column, _, _ in TYPES[table]:
        if column in DROP_ON_IMPORT:
            continue
        if column in pending:
            columns[column] = pending[column]
    return {"type": type_name, "table": table, "id": record["id"], "columns": columns}


def project_record(record: dict, record_index: int) -> dict:
    """与 Dart 侧驱动 `_projectPayload` 完全相同的投影（向量 expect 的形态）。

    **键序本身是被比对的一部分**（向量按规范化 JSON 文本比对），
    所以这里的键序必须逐字对齐 Dart：`recordIndex` 在 `columns` **之前**。
    recordIndex 计的是**全部**记录行（含被跳过的未知类型）—— 与 Dart 一致：
    报告里说的「第 N 行」是文件里的行号，不是「认得的第 N 行」。
    """
    explained = explain_record(record)
    columns = explained["columns"]
    return {
        "type": explained["type"],
        "table": explained["table"],
        "id": explained["id"],
        "isTombstone": columns.get("deleted_at") is not None,
        "updatedAt": columns.get("updated_at", 0),
        "deviceId": str(columns.get("device_id", "")),
        "recordIndex": record_index,
        "columns": columns,
    }


def project_payload(payload: bytes) -> dict:
    """载荷字节 → 驱动 `_projectPayload` 的形态（含 recordIndex 与摘要）。"""
    lines = payload.decode("utf-8").splitlines()
    manifest = json.loads(lines[0])
    end = json.loads(lines[-1])
    region = b"".join((ln + "\n").encode("utf-8") for ln in lines[1:-1])

    kept: list[dict] = []
    unknown_types: dict[str, int] = {}
    for index, line in enumerate(lines[1:-1]):
        obj = json.loads(line)
        if obj["type"] in STAGE_ORDER:
            kept.append(project_record(obj, index))
        else:
            unknown_types[obj["type"]] = unknown_types.get(obj["type"], 0) + 1

    return {
        "records": kept,
        "unknownTypes": unknown_types,
        "skippedUnknownRecords": sum(unknown_types.values()),
        "declaredRecordCount": end["recordCount"],
        "observedRecordCount": len(lines) - 2,
        "contentHashHex": end["contentHash"].removeprefix("sha256:"),
        "recordsRegionBytes": len(region),
        "warnings": [],
        "exportKind": manifest["exportKind"],
    }


def manifest_line(payload_hex: str) -> dict:
    return json.loads(bytes.fromhex(payload_hex).decode("utf-8").splitlines()[0])


def recalculated_balances(records: list[dict]) -> dict[str, dict]:
    """按 §2.3 的推演语义独立重算（复用 balance_replay.py 的引擎）。

    引擎的输入契约用 `type` 表示「交易类型 1/2/3」与「账户类型」（它自己的
    向量 balance_replay.json 就是这么锁的），而载荷侧这两个字段叫 `txnType` /
    `accountType`（判别键 `type` 独占，§4.1）。所以这里做一次**翻译**，
    **不改引擎** —— 引擎的字节级行为不能因为载荷改名而漂移。
    """
    accounts = [
        {
            "id": r["id"],
            "openingMinor": r.get("openingBalanceMinor", 0),
            "type": r.get("accountType"),
        }
        for r in records if r["type"] == "account"
    ]
    engine = balance_replay.Engine(accounts)
    for record in records:
        if record["type"] == "txn":
            engine.txn({**record, "type": record["txnType"]})
    return {
        acc_id: {"balanceMinor": balance, "balanceAsOf": as_of}
        for acc_id, (balance, as_of) in engine.replay_from_scratch().items()
    }


# ---------------------------------------------------------------------------
# 容器封包（复用 container_pfb 的独立实现）
# ---------------------------------------------------------------------------


def seal(payload: bytes, *, password: str = PASSWORD, flags: int = 0) -> bytes:
    """用 container_pfb.py 的独立实现封包（固定随机源，字节可复现）。"""
    return container_pfb.seal(
        payload, password, KDF, SALT, NONCE_PREFIX, flags, CHUNK_KIB, VOLUME_SET_ID,
    )


def seal_with_container_version(payload: bytes, version: int, flags: int) -> bytes:
    """容器主版本更高的变体（用来构造「版本不兼容」）。

    `container_pfb.seal` 把版本钉在 1（正确 —— 那是唯一 v1 格式），
    因此这里改法很直接：封包后改文件头的版本字节并重算头部 CRC32。
    """
    blob = bytearray(seal(payload, flags=flags))
    blob[8:10] = version.to_bytes(2, "big")
    blob[44:48] = (zlib.crc32(bytes(blob[0:44])) & 0xFFFFFFFF).to_bytes(4, "big")
    return bytes(blob)


def patch_flags(blob: bytes, flags: int) -> bytes:
    """改特性位并重算头部 CRC32（构造「未知特性位」）。"""
    out = bytearray(blob)
    out[12:14] = flags.to_bytes(2, "big")
    out[44:48] = (zlib.crc32(bytes(out[0:44])) & 0xFFFFFFFF).to_bytes(4, "big")
    return bytes(out)


def tamper_first_chunk(blob: bytes, *, recompute_digest: bool) -> bytes:
    """破坏第一个分块密文里的一个字节；可选地把尾部摘要一起重算。"""
    out = bytearray(blob)
    offset = 128 + 4 + 12 + 3  # 分块头 4B 长度 + 12B nonce 之后的第 4 个密文字节
    out[offset] ^= 0x01
    if recompute_digest:
        out[-32:] = hashlib.sha256(bytes(out[48:-32])).digest()
    return bytes(out)


def gzip_bytes(payload: bytes) -> bytes:
    # mtime 固定为 0：同样的输入永远得到同样的压缩字节（字节级断言的前提）
    return gzip.compress(payload, mtime=0)


# ---------------------------------------------------------------------------
# 样本装配
# ---------------------------------------------------------------------------


def build_sample_artifacts(spec: dict) -> dict:
    payload = build_payload(spec["manifest"], spec["records"], OCCURRED_2)
    blob = seal(gzip_bytes(payload), flags=spec["flags"])
    return {
        "id": spec["id"],
        "title": spec["title"],
        "fileName": f"{spec['id']}.pfb",
        "exportKind": spec["manifest"]["exportKind"],
        "fileHex": blob.hex(),
        "fileSha256": hashlib.sha256(blob).hexdigest(),
        "fileBytes": len(blob),
        "payloadNdjsonHex": payload.hex(),
        "payloadSha256": hashlib.sha256(payload).hexdigest(),
        "payloadBytes": len(payload),
        "contentHash": "sha256:" + hashlib.sha256(
            b"".join(line_bytes(r) for r in spec["records"])
        ).hexdigest(),
        "recordCount": len(spec["records"]),
        "manifest": spec["manifest"],
        "records": spec["records"],
        "decoded": project_payload(payload),
        "recalculatedBalances": recalculated_balances(spec["records"]),
        "fileCachedBalanceMinor": {
            r["id"]: r["cachedBalanceMinor"]
            for r in spec["records"] if r["type"] == "account"
        },
        "notes": spec["notes"],
    }


# ---------------------------------------------------------------------------
# import.apply 的编排模拟（Dart ImportApplier.apply 的镜像）
# ---------------------------------------------------------------------------


class InjectedFailure(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


class ApplySim:
    def __init__(self, payload: bytes, *, import_job_id: str, file_name: str, file_sha256: str,
                 local_rows: dict[str, list[dict]] | None = None,
                 imported_file: list[dict] | None = None,
                 quick_check: str = "ok",
                 orphan_violations: dict[str, int] | None = None,
                 backup: str = "ok",
                 fail_on: str | None = None):
        self.payload = payload
        self.job_id = import_job_id
        self.file_name = file_name
        self.file_sha256 = file_sha256
        self.local_rows = local_rows or {}
        self.imported_file = imported_file or []
        self.quick_check = quick_check
        self.orphan_violations = orphan_violations or {}
        self.backup = backup
        self.fail_on = fail_on

        self.statements: list[str] = []
        self.arguments: list[list] = []
        self.transactions: list[str] = []
        self.backup_calls: list[str] = []
        self.outcome = "ok"
        self.error_code: str | None = None
        self.summary: dict | None = None

        # 罐头结果表 + 命中集：镜像 ScriptedDb 的「登记 → 命中 → 报未命中」。
        # 它不是可有可无的对照物 —— 一个拼错的键会让假驱动**静默返回空结果**，
        # 于是「本地没有这行」被误判成「需要插入」，向量照样全绿。
        # 未命中的键被放进 expect 里比对，是这条静默通道唯一的闸门。
        self.canned: dict[str, list] = {}
        self._hit_canned: set[str] = set()
        self._register_canned()

    # ---- 罐头结果（镜像 ScriptedDb._scriptedDb） ------------------------

    def _register_canned(self) -> None:
        """登记顺序与 Dart 驱动逐字一致（键序影响命中优先级）。"""
        self.canned[FIND_IMPORTED_FILE_SQL] = [
            {"job_id": r["job_id"], "imported_at": r["imported_at"]} for r in self.imported_file
        ]
        self.canned[QUICK_CHECK_SQL] = [{"quick_check": self.quick_check}]
        for table in self.local_rows:
            self.canned["SELECT * FROM " + table + " WHERE id IN ("] = list(self.local_rows[table])
        for child, column, parent in REFERENCE_RULES:
            n = self.orphan_violations.get(rule_key(child, column), 0)
            self.canned[orphan_sql(child, column, parent)] = [{"n": n}]

    def _query(self, sql: str, args: list | None = None) -> list:
        """查询：记语句 + 走罐头匹配（只有查询会命中罐头，写语句不会）。"""
        self._run(sql, args)
        for key, rows in self.canned.items():
            if sql.startswith(key):
                self._hit_canned.add(key)
                return rows
        return []

    # ---- 基础 ----------------------------------------------------------

    def _run(self, sql: str, args: list | None = None) -> None:
        self.statements.append(sql)
        self.arguments.append(args if args is not None else [])
        if self.fail_on and sql.startswith(self.fail_on):
            raise InjectedFailure("PFD_E_OPEN")

    def _rows(self, table: str) -> dict[str, dict]:
        return {row["id"]: row for row in self.local_rows.get(table, [])}

    # ---- 主流程 --------------------------------------------------------

    def run(self) -> dict:
        self._query(FIND_IMPORTED_FILE_SQL, [self.file_sha256])
        if self.imported_file:
            row = self.imported_file[0]
            self.summary = {
                "inserted": 0, "skipped": 0,
                "alreadyImportedJobId": row["job_id"],
                "alreadyImportedAt": row["imported_at"],
                "backupPath": None, "unknownTypes": {}, "warnings": [],
            }
            return self._result()

        decoded = project_payload(self.payload)
        inserts: list[dict] = []
        touched: list[str] = []
        skipped = 0
        conflicts = 0

        for type_name in STAGE_ORDER:
            records = [r for r in decoded["records"] if r["type"] == type_name]
            if not records:
                continue
            table = TABLE_OF_TYPE[type_name]
            touched.append(table)
            ids = list(dict.fromkeys(r["id"] for r in records))
            self._query(
                "SELECT * FROM " + table + " WHERE id IN (" + ", ".join(["?"] * len(ids)) + ")",
                ids,
            )
            local = self._rows(table)
            for record in records:
                existing = local.get(record["id"])
                if existing is None:
                    inserts.append(record)
                elif _same_content(record["columns"], existing):
                    skipped += 1
                else:
                    conflicts += 1

        if conflicts:
            self.outcome = "error"
            self.error_code = "PFI_E_CONFLICT"
            return self._result()

        if self.backup == "fail":
            self.backup_calls.append(self.job_id)
            self.outcome = "error"
            self.error_code = "PFI_E_BACKUP"
            return self._result()
        self.backup_calls.append(self.job_id)
        backup_path = f"backup/pf-pre-import-{self.job_id}.db"

        self._run(CREATE_JOB_SQL, [
            self.job_id, self.file_name, self.file_sha256, MODE_MERGE, STATUS_RUNNING,
            APPLY_NOW, backup_path,
            json.dumps(decoded_manifest(self.payload), separators=(",", ":"), ensure_ascii=False),
        ])

        self.transactions.append("BEGIN")
        try:
            self._run(SAVEPOINT_SQL)
            for record in inserts:
                columns = record["columns"]
                sql = (
                    f"INSERT INTO {record['table']} ({', '.join(columns)}) "
                    f"VALUES ({', '.join(['?'] * len(columns))})"
                )
                self._run(sql, [columns[key] for key in columns])
            self._query(QUICK_CHECK_SQL)
            if self.quick_check != "ok":
                raise InjectedFailure("PFD_E_OPEN")
            failures = []
            for child, column, parent in REFERENCE_RULES:
                if child not in touched:
                    continue
                self._query(orphan_sql(child, column, parent))
                n = self.orphan_violations.get(rule_key(child, column), 0)
                if n > 0:
                    failures.append(f"{child}.{column}→{parent} 有 {n} 行悬空")
            if failures:
                raise InjectedFailure("PFI_E_INCOMPATIBLE")
            self._run(RECALC_TOKEN)
            self._run(RESET_TOKEN)
        except InjectedFailure as failure:
            self._run(ROLLBACK_TO_SQL)
            self._run(RELEASE_SQL)
            self.transactions.append("ROLLBACK")
            self._finish_job(STATUS_FAILED, 0, 0, failure.code)
            self.outcome = "error"
            self.error_code = failure.code
            return self._result()

        self._run(RELEASE_SQL)
        self.transactions.append("COMMIT")
        self._finish_job(STATUS_OK, len(inserts), skipped, None)
        self._run(MARK_IMPORTED_FILE_SQL, [
            self.file_sha256, self.file_name, self.job_id, APPLY_NOW,
        ])
        self.summary = {
            "inserted": len(inserts), "skipped": skipped,
            "alreadyImportedJobId": None, "alreadyImportedAt": None,
            "backupPath": backup_path, "unknownTypes": decoded["unknownTypes"], "warnings": [],
        }
        return self._result()

    def _finish_job(self, status: int, inserted: int, skipped: int, error_code: str | None) -> None:
        self._run(FINISH_JOB_SQL, [
            status, APPLY_NOW, inserted, 0, skipped, 0, 0, error_code, self.job_id,
        ])

    def _result(self) -> dict:
        return {
            "outcome": self.outcome,
            "errorCode": self.error_code,
            "statements": self.statements,
            "arguments": self.arguments,
            "transactions": self.transactions,
            "backupCalls": self.backup_calls,
            # 登记了却从未命中的罐头键（升序）—— 拼错的键会让向量变红。
            "unusedCanned": sorted(k for k in self.canned if k not in self._hit_canned),
            "summary": self.summary,
        }


def decoded_manifest(payload: bytes) -> dict:
    return json.loads(payload.decode("utf-8").splitlines()[0])


def _same_content(columns: dict, local: dict) -> bool:
    """与 Dart 侧 ImportRecord.matchesLocal 同口径：只比本行带的列，排除版本戳。"""
    excluded = {"rev", "updated_at", "created_at", "device_id", "source_import_job"}
    inc = {k: v for k, v in columns.items() if k not in excluded}
    loc = {k: local.get(k) for k in inc}
    return inc == loc


def local_row_of(record: dict, *, override: dict | None = None, bump_rev: bool = True) -> dict:
    """由载荷行造一条「本地已有」的行。

    刻意改动 rev / updated_at / created_at / device_id，并补上载荷里没有的列
    （`source_import_job`，以及 account 的 `cached_balance_minor`）——
    这些都是「内容相同」判定必须忽略的东西。改完仍应判为 skip。
    """
    columns = explain_record(record)["columns"]
    row = dict(columns)
    if bump_rev:
        row["rev"] = int(columns.get("rev", 1)) + 7
        row["updated_at"] = int(columns.get("updated_at", 0)) + 1000
        row["created_at"] = int(columns.get("created_at", 0)) + 1000
        row["device_id"] = "01J8OTHERDEVICE00000000000"
    if record["type"] == "txn":
        row["source_import_job"] = None
    if record["type"] == "account":
        row["cached_balance_minor"] = 999999
        row["balance_as_of"] = 0
    if override:
        row.update(override)
    return row


# ---------------------------------------------------------------------------
# 用例构造
# ---------------------------------------------------------------------------


def case(case_id: str, kind: str, title: str, input_: dict, expect: dict,
         notes: str, tags: list[str]) -> dict:
    return {
        "id": case_id,
        "kind": kind,
        "title": title,
        "milestone": "M1",
        "input": input_,
        "expect": expect,
        "notes": notes,
        "tags": tags,
    }


def value_case(case_id: str, kind: str, title: str, input_: dict, value: dict,
               notes: str, tags: list[str]) -> dict:
    return case(case_id, kind, title, input_, {"ok": True, "value": value}, notes, tags)


def error_case(case_id: str, kind: str, title: str, input_: dict, code: str,
               notes: str, tags: list[str]) -> dict:
    return case(case_id, kind, title, input_, {"ok": False, "errorCode": code}, notes, tags)


def triage_cases() -> list[dict]:
    """§4.3 阶段 A–D 的分流表。三态互斥且穷尽 —— 判错一次用户就会走错方向。"""
    rows = [
        ("header", "PFB_E_MAGIC", "notPfbFile", "PFI_E_CORRUPT",
         "魔数不对 ⇒ 这不是本应用的文件。注意它归入「损坏」这一态而不是单独一态："
         "用户能做的动作与文件损坏完全相同（换一份文件）。"),
        ("header", "PFB_E_VERSION_UNSUPPORTED", "versionIncompatible", "PFI_E_VERSION",
         "容器主版本更高 ⇒ 升级应用。这是唯一一个「文件没坏、密码也对，就是读不了」的情形。"),
        ("header", "PFB_E_TRUNCATED", "corruptedHeader", "PFI_E_CORRUPT",
         "头都不够 128 字节 ⇒ 传输中断。三态里归「损坏」。"),
        ("header", "PFB_E_HEADER_INVALID", "corruptedHeader", "PFI_E_CORRUPT",
         "头部字段自相矛盾（如盐长度 0）⇒ 结构不对，归「损坏」。"),
        ("header", "PFB_E_KDF_PARAMS", "suspiciousKdfParams", "PFI_E_VERSION",
         "KDF 参数越界的文件既可能是伪造的、也可能是更新版本用的更强参数，"
         "对用户而言动作相同（升级或换文件），因此与版本不兼容同态。"),
        ("integrity", "PFB_E_DIGEST_MISMATCH", "corrupted", "PFI_E_CORRUPT",
         "免密摘要不符 ⇒ 密文字节已经不是封包时的字节。这一态**不可能**是密码错。"),
        ("integrity", "PFI_E_WRONG_PASSWORD", "wrongPassword", "PFI_E_WRONG_PASSWORD",
         "三态前哨：已经是三态之一的错误码不得被二次分流改写。"
         "这条守的是「同一个失败在两条路径上得到同一个结论」。"),
        ("decrypt", "PFB_E_AUTH_FAILED", "wrongPassword", "PFI_E_WRONG_PASSWORD",
         "★ 整个分流的关键：免密摘要已经通过 ⇒ 密文逐字节完好 ⇒ 解不开只能是密钥不对。"
         "顺序反过来（先解密再看摘要）就会把「文件坏了」误报成「密码错」，"
         "让用户反复试一个其实正确的密码。"),
        ("decrypt", "PFB_E_DIGEST_MISMATCH", "corrupted", "PFI_E_CORRUPT",
         "解密阶段也会出现摘要类错误（分块链校验），它仍然只说明字节不对。"),
        ("decrypt", "PFB_E_VERSION_UNSUPPORTED", "versionIncompatible", "PFI_E_VERSION",
         "解密阶段再次发现版本过高（例如分块头声明的特性），仍归版本态。"),
        ("payload", "PFC_E_VALIDATION", "payloadInvalid", "PFC_E_VALIDATION",
         "载荷格式违反契约（schema / scope / contentHash）⇒ 这份文件的内容不合法，"
         "不修改任何数据。"),
        ("payload", "PFI_E_VERSION", "versionIncompatible", "PFI_E_VERSION",
         "载荷主版本更高（C4）⇒ 升级应用。判错一次就会把用户引向完全无效的动作："
         "归「损坏」他会去重新导出，而重导出仍是同一版；归「密码错」他会反复试一个"
         "其实正确的密码。只有「版本不兼容」这一态给出了能解决问题的动作。"),
        ("decrypt", "PFD_E_OPEN", "corrupted", "PFI_E_CORRUPT",
         "★ 兜底：没列入表的组合按「损坏」处理，**绝不猜密码错**。"
         "错误地让用户反复试密码，比让他换一份文件更糟。"),
    ]
    cases = []
    for stage, code, kind_name, expected_code, note in rows:
        cases.append(value_case(
            f"import.triage.failure.{stage}-{code.lower().replace('_', '-')}",
            "import.triage.failure",
            f"{stage} 阶段遇到 {code} ⇒ {kind_name}",
            {"stage": stage, "code": code, "detail": ""},
            {"kind": kind_name, "code": expected_code, "triaged": kind_name in (
                "wrongPassword", "corrupted", "versionIncompatible")},
            note,
            ["security", "forward-compat"],
        ))
    return cases


def decode_cases(samples: dict[str, dict]) -> list[dict]:
    full = samples["sample-full"]
    range_ = samples["sample-range"]
    ledger_ = samples["sample-ledger"]
    full_payload = bytes.fromhex(full["payloadNdjsonHex"])
    range_payload = bytes.fromhex(range_["payloadNdjsonHex"])
    ledger_payload = bytes.fromhex(ledger_["payloadNdjsonHex"])

    cases: list[dict] = []

    cases.append(value_case(
        "import.payload.decode.full",
        "import.payload.decode",
        "full 载荷 → 记录：未知字段忽略 / 缺 dayKey 派生 / 缓存余额丢弃 / 软删保留",
        {"ndjsonHex": full["payloadNdjsonHex"]},
        full["decoded"],
        "期望值由 Python 独立解释同一批字节得到（默认值来自 §2.3 的 DEFAULT，"
        "列序来自 §2.3 的 DDL，dayKey/monthKey 的拆解复用 balance_replay.py 的实现）。"
        "三条最要紧的事实：① account 的 columns 里**没有** cached_balance_minor / "
        "balance_as_of（导入丢弃派生态）；② X1 的 columns 里有 day_key / month_key，"
        "而文件里没写这两个键（派生）；③ X1 行里那个 V2 未知字段在 columns 里不存在（C1）。",
        ["format", "forward-compat"],
    ))

    # 缺字段取默认值：把 V1 文件里「V2 才有的字段」整列去掉
    strips = {"excludedFromStats", "isReimbursable", "alertBp", "rollover", "isSystem",
              "isHidden", "sortOrder", "isArchived", "tags"}
    stripped = [
        {k: v for k, v in r.items() if k not in strips} for r in full["records"]
    ]
    stripped_payload = build_payload(full["manifest"], stripped, OCCURRED_2)
    cases.append(value_case(
        "import.payload.decode.defaults",
        "import.payload.decode",
        "C3：缺失字段取 §2.3 的 DEFAULT（旧文件读进新库）",
        {"ndjsonHex": stripped_payload.hex()},
        project_payload(stripped_payload),
        "去掉的是 9 个有 DEFAULT 的字段（★ 不是随便挑的：每个都必须是 C3 意义上"
        "「不影响历史语义的安全值」）。若实现把「缺失」当成 0 或 NULL 硬塞，"
        "或误判成「必需字段缺失」而拒读，这里都会红。",
        ["forward-compat"],
    ))

    # 显式 null 落到「有 DEFAULT 的 NOT NULL 列」上 —— 取 DEFAULT，不是 null。
    # 这条与上一条的区别很实际：上一条是**键不在**（C3 的字面场景），
    # 这一条是**键在、值是 null**。两者都是「文件没给值」，
    # 但实现很容易只在「缺失」分支上走默认值，把显式 null 原样写进去 ——
    # 那句 INSERT 会被 SQL 的 NOT NULL 拒掉，报出来是一句
    # `NOT NULL constraint failed: ledger.is_default`，与文件无关、无从排查。
    nulled = [
        {**r, "isDefault": None, "sortOrder": None} if r["type"] == "ledger" else r
        for r in full["records"]
    ]
    nulled = [
        {**r, "tags": None, "feeMinor": None, "isReimbursable": None}
        if r["type"] == "txn" else r
        for r in nulled
    ]
    nulled = [
        {**r, "isActive": None, "specJson": None} if r["type"] == "theme" else r
        for r in nulled
    ]
    nulled_payload = build_payload(full["manifest"], nulled, OCCURRED_2)
    cases.append(value_case(
        "import.payload.decode.explicit-null-takes-default",
        "import.payload.decode",
        "C3 边界：键在但值为 null ⇒ 同样取 DEFAULT（列是 NOT NULL）",
        {"ndjsonHex": nulled_payload.hex()},
        project_payload(nulled_payload),
        "★ 锁的是一个**实现极易走岔**的分支：代码里「缺键」与「值是 null」往往是"
        "两条不同的路径，只在其中一条上取默认值是很自然的疏忽 —— 而后果不在解析期，"
        "而在事务里变成一句 `NOT NULL constraint failed`：用户看到的是"
        "「导入失败」加一个列名，既不是三态之一，也没有可行动的动作。"
        "注意 `specJson` 的默认值是 `{}`、`tags` 是 `[]`，**不是** null 也不是空串。",
        ["format"],
    ))

    # C2：未知类型跳过并计数
    unknown_rows = full["records"] + [
        {"type": "v2_goal", "id": "01J8TESTGOAL0000000000001", "ledgerId": L1,
         "targetMinor": 1000000},
        {"type": "v2_goal", "id": "01J8TESTGOAL0000000000002", "ledgerId": L1,
         "targetMinor": 2000000},
    ]
    unknown_manifest = manifest_of(
        "full", {**full["manifest"]["counts"], "v2_goal": 2},
        includes_attachments=True,
    )
    unknown_payload = build_payload(unknown_manifest, unknown_rows, OCCURRED_2)
    cases.append(value_case(
        "import.payload.decode.unknown-type",
        "import.payload.decode",
        "C2：未知记录类型跳过并计数，不阻断导入",
        {"ndjsonHex": unknown_payload.hex()},
        project_payload(unknown_payload),
        "★ 反直觉但必须如此：未知类型的行**也要计入 contentHash**（摘要覆盖"
        "manifest 与 end 之间的全部字节）。若只对认得的行求摘要，V1 读 V2 的"
        "文件时摘要必然失配，而 C2 又要求 V1 必须能读 —— 两条规则会当场打架。"
        "同时注意 counts 里的 v2_goal 不参与条数核对（它是未知类型）。",
        ["forward-compat"],
    ))

    # 各类拒绝路径
    cases.append(error_case(
        "import.payload.decode.payload-version-newer",
        "import.payload.decode",
        "C4：载荷主版本更高 ⇒ 拒读（PFI_E_VERSION）",
        {"ndjsonHex": build_payload(range_["manifest"], range_["records"], OCCURRED_2,
                                    version=2).hex()},
        "PFI_E_VERSION",
        "版本不兼容与「内容不合法」是两回事：前者要用户升级应用，后者要用户换文件。"
        "合并成一个错误码，用户就会在「升级」与「换文件」之间被指错方向。",
        ["security", "forward-compat"],
    ))
    cases.append(error_case(
        "import.payload.decode.missing-end",
        "import.payload.decode",
        "载荷被截断（缺 end 行）⇒ PFC_E_VALIDATION",
        {"ndjsonHex": build_payload(range_["manifest"], range_["records"], OCCURRED_2,
                                    drop_end=True).hex()},
        "PFC_E_VALIDATION",
        "缺 end 行意味着有一个来源不明的截断点。**不能**接受它："
        "接受就等于把「文件传输到一半」当成一次完整的导入。",
        ["format"],
    ))
    cases.append(error_case(
        "import.payload.decode.content-hash-tampered",
        "import.payload.decode",
        "记录行被改动但 end 行的 contentHash 没跟着改 ⇒ PFC_E_VALIDATION",
        {"ndjsonHex": build_payload(
            range_["manifest"],
            # 产出的记录行是**改过的**（最后一笔的金额被改）
            range_["records"][:-1] + [{**range_["records"][-1], "amountMinor": 999999}],
            OCCURRED_2,
            # 而声明的摘要仍是**原始记录**的 —— 这正是「改了字节没改摘要」。
            declared_digest=hashlib.sha256(
                b"".join(line_bytes(r) for r in range_["records"])
            ).hexdigest(),
        ).hex()},
        "PFC_E_VALIDATION",
        "contentHash 是载荷级的完整性契约：攻击者能改字节但改不出对应摘要"
        "（没有密钥就改不出，因为改完摘要也要能被同一个人接受）。"
        "这条同时说明**为什么摘要不覆盖 manifest/end 自身** —— 否则就是自指。",
        ["security"],
    ))
    cases.append(error_case(
        "import.payload.decode.record-count-mismatch",
        "import.payload.decode",
        "end 行声明条数与实际不符 ⇒ PFC_E_VALIDATION",
        {"ndjsonHex": build_payload(range_["manifest"], range_["records"], OCCURRED_2,
                                    end_record_count=len(range_["records"]) + 3).hex()},
        "PFC_E_VALIDATION",
        "条数是 sheet 级的一致性检查：它能抓到「有记录行被整段删掉但摘要被一并重算」"
        "这一类（摘要只能证明字节没变，不能证明内容完整）。",
        ["format"],
    ))
    cases.append(error_case(
        "import.payload.decode.counts-mismatch",
        "import.payload.decode",
        "manifest.counts 与内容不符 ⇒ PFC_E_VALIDATION（scope 与内容不符）",
        {"ndjsonHex": build_payload(
            {**range_["manifest"], "counts": {**range_["manifest"]["counts"], "txn": 5}},
            range_["records"], OCCURRED_2).hex()},
        "PFC_E_VALIDATION",
        "counts 是导出方自报的条数。它一旦与实际不符，说明这份文件在生成或传输"
        "途中被改过。**注意只核对已知类型**：未知类型会被 C2 跳过，"
        "拿它去核对会让 V1 读 V2 文件时整份被拒。",
        ["format", "forward-compat"],
    ))
    cases.append(error_case(
        "import.payload.decode.scope-ledger-mismatch",
        "import.payload.decode",
        "exportKind=ledger 声明只含 L1，却混进别的账本 ⇒ PFC_E_VALIDATION",
        {"ndjsonHex": build_payload(
            ledger_["manifest"],
            ledger_["records"][:-1] + [{**ledger_["records"][-1], "ledgerId": A1}],
            OCCURRED_2).hex()},
        "PFC_E_VALIDATION",
        "★ 为什么值得一条向量：混账本导入**事后无法摘除** —— 软删掉那条记录会"
        "破坏原账本的语义（这条记录本来就属于另一个账本，不该在这里被删）。"
        "因此范围声明与内容不符必须在写入之前死掉。",
        ["format", "security"],
    ))
    cases.append(error_case(
        "import.payload.decode.txn-transfer-missing-target",
        "import.payload.decode",
        "转账（type=3）缺 to_account_id ⇒ PFC_E_VALIDATION",
        {"ndjsonHex": build_payload(
            range_["manifest"],
            [r for r in range_["records"] if r["id"] != X2] + [
                {**row_txn_x2(), "toAccountId": None}
            ],
            OCCURRED_2).hex()},
        "PFC_E_VALIDATION",
        "§2.3 的 CHECK 在导入期**前置**执行：这类行即使侥幸进了库，"
        "全量重算也会把它算成「一笔支出」而不是转账，余额会静默错掉。"
        "前置校验的收益是错误信息带上下文（哪一行、哪个字段），"
        "而不是一句 SQLite 约束失败。",
        ["format"],
    ))
    cases.append(error_case(
        "import.payload.decode.missing-required-id",
        "import.payload.decode",
        "记录行缺 id（NOT NULL 且无默认值）⇒ PFC_E_VALIDATION",
        {"ndjsonHex": build_payload(
            range_["manifest"],
            [{k: v for k, v in r.items() if k != "id"} for r in range_["records"]],
            OCCURRED_2).hex()},
        "PFC_E_VALIDATION",
        "没有默认值的必填字段缺失时必须**拒绝整份**：编不出这一行就不能假装它没问题"
        "（id 是主键，猜一个等于凭空造出一条记录）。",
        ["format"],
    ))
    cases.append(error_case(
        "import.payload.decode.tags-too-long",
        "import.payload.decode",
        "tags 数组超过 64 项 ⇒ PFC_E_VALIDATION（资源边界）",
        {"ndjsonHex": build_payload(
            range_["manifest"],
            [r for r in range_["records"] if r["id"] != X1] + [
                {**row_txn_x1(keys=True),
                 "tags": [f"01J8TESTTAG{i:019d}" for i in range(65)]}
            ],
            OCCURRED_2).hex()},
        "PFC_E_VALIDATION",
        "§4.3 的硬约束表把 tags 钉在 64 项以内。这类上限不是洁癖："
        "导入文件是外部输入，任何「没有上限」的容器都是一个放大器。",
        ["security", "boundary"],
    ))
    return cases


def file_read_cases(samples: dict[str, dict]) -> list[dict]:
    full = samples["sample-full"]
    range_ = samples["sample-range"]
    base = bytes.fromhex(range_["fileHex"])
    cases: list[dict] = []

    cases.append(value_case(
        "import.file.read.ok",
        "import.file.read",
        "读一份完好的 full 文件：免密摘要 → 解密 → 解压 → 解载荷",
        {"fileHex": full["fileHex"], "password": PASSWORD, "fileName": full["fileName"]},
        {
            "fileSha256Hex": full["fileSha256"],
            "payloadVersion": 1,
            "hasAttachments": True,
            "isIncremental": False,
            "isMultiVolume": False,
            "manifest": manifest_line(full["payloadNdjsonHex"]),
            "payload": full["decoded"],
        },
        "★ 这一条是「导入器能打开导出器写的文件」的机器化断言：Dart 侧走"
        "Argon2id → 分块 GCM → GUNZIP → NDJSON，样本由 Python 的"
        "container_pfb.py 独立封包（另一套实现）。两侧任何一处格式口径漂移，这里都红。",
        ["format", "crypto"],
    ))
    cases.append(error_case(
        "import.file.read.wrong-password",
        "import.file.read",
        "密码错（文件完好）⇒ PFI_E_WRONG_PASSWORD",
        {"fileHex": range_["fileHex"], "password": WRONG_PASSWORD, "fileName": range_["fileName"]},
        "PFI_E_WRONG_PASSWORD",
        "★ 三态的第一态。能给出这个码的前提是**免密摘要先过了** —— "
        "否则「密码错」只是猜测。这条向量与下面那条 digest-recomputed 一起，"
        "把「先免密、后解密」的顺序钉死。",
        ["security", "ux"],
    ))
    cases.append(error_case(
        "import.file.read.ciphertext-tampered",
        "import.file.read",
        "密文被改一个字节（尾部摘要没跟着改）⇒ PFI_E_CORRUPT",
        {"fileHex": tamper_first_chunk(base, recompute_digest=False).hex(),
         "password": PASSWORD, "fileName": range_["fileName"]},
        "PFI_E_CORRUPT",
        "免密阶段就能判死，**根本不需要密钥**。这正是三态互斥的结构保证："
        "摘要不符时不可能误报成密码错。",
        ["security", "format"],
    ))
    cases.append(error_case(
        "import.file.read.tampered-with-recomputed-digest",
        "import.file.read",
        "密文被改且尾部摘要一并重算 ⇒ 落到 PFI_E_WRONG_PASSWORD（口径边界）",
        {"fileHex": tamper_first_chunk(base, recompute_digest=True).hex(),
         "password": PASSWORD, "fileName": range_["fileName"]},
        "PFI_E_WRONG_PASSWORD",
        "★ 这条向量锁的是一个**边界**，不是缺陷：有人改了一个字节又重算了"
        "免密摘要，于是「文件完好」成立、GCM 认证失败 ⇒ 报告密码错。"
        "另一个选择（认证失败一律报损坏）会让手滑打错密码的用户被支去换文件，"
        "代价大得多。能重算摘要的人本来就需要能改文件，这不是威胁模型内的攻击者。",
        ["security", "ux"],
    ))
    cases.append(error_case(
        "import.file.read.truncated",
        "import.file.read",
        "文件被截断（尾部摘要不在）⇒ PFI_E_CORRUPT",
        {"fileHex": base[:140].hex(), "password": PASSWORD, "fileName": range_["fileName"]},
        "PFI_E_CORRUPT",
        "网盘同步到一半、聊天软件压缩失败都会产生这种文件。"
        "注意：低层抛的是 PFB_E_TRUNCATED，**分流后**必须变成三态之一 —— "
        "否则用户看到的是一句他无法行动的技术描述。",
        ["format"],
    ))
    cases.append(error_case(
        "import.file.read.not-a-pfb",
        "import.file.read",
        "文件头魔数不对 ⇒ PFI_E_CORRUPT",
        {"fileHex": (b"\x00" * 8 + base[8:]).hex(), "password": PASSWORD,
         "fileName": range_["fileName"]},
        "PFI_E_CORRUPT",
        "选错文件是最常见的用户操作。这条路径必须与「文件损坏」同态："
        "用户能做的动作完全一样（换一个文件）。",
        ["ux"],
    ))
    cases.append(error_case(
        "import.file.read.unknown-feature-flag",
        "import.file.read",
        "头部声明了本版本不认识的特性位 ⇒ PFI_E_VERSION",
        {"fileHex": patch_flags(base, FLAG_AESGCM | FLAG_GZIP | FLAG_CHUNKED | (1 << 6)).hex(),
         "password": PASSWORD, "fileName": range_["fileName"]},
        "PFI_E_VERSION",
        "★ 特性位**不能**按「忽略未知位」处理（那是 C1/C2 对字段与记录类型的放宽，"
        "对象不同）：字段是数据，特性位是格式语义。忽略一个声明了"
        "「数据以我不理解的方式组织」的位，等于凭运气解析。",
        ["security", "forward-compat"],
    ))
    cases.append(error_case(
        "import.file.read.container-version-newer",
        "import.file.read",
        "容器主版本更高 ⇒ PFI_E_VERSION",
        {"fileHex": seal_with_container_version(
            gzip_bytes(bytes.fromhex(range_["payloadNdjsonHex"])), 2,
            FLAG_AESGCM | FLAG_GZIP | FLAG_CHUNKED).hex(),
         "password": PASSWORD, "fileName": range_["fileName"]},
        "PFI_E_VERSION",
        "容器版本与载荷版本独立演进（§3.2），但两者都归同一个用户动作：升级应用。",
        ["security", "forward-compat"],
    ))
    cases.append(error_case(
        "import.file.read.payload-version-newer",
        "import.file.read",
        "容器可读但载荷主版本更高 ⇒ PFI_E_VERSION",
        {"fileHex": seal(gzip_bytes(build_payload(
            range_["manifest"], range_["records"], OCCURRED_2, version=2)),
            flags=FLAG_AESGCM | FLAG_GZIP | FLAG_CHUNKED).hex(),
         "password": PASSWORD, "fileName": range_["fileName"]},
        "PFI_E_VERSION",
        "C4：只有主版本更高才拒读。这条与 decode 的同名用例、以及"
        "「未知类型跳过」那条一起，划出了「什么必须拒、什么必须读」的完整边界。",
        ["forward-compat"],
    ))
    return cases


def apply_cases(samples: dict[str, dict]) -> list[dict]:
    minimal = samples["sample-apply-minimal"]
    payload_hex = minimal["payloadNdjsonHex"]
    payload = bytes.fromhex(payload_hex)
    file_sha = minimal["fileSha256"]
    file_name = minimal["fileName"]
    job_id = "01J8TESTJOB000000000000001"

    # 第二套装订参数：full 样本（11 条记录，八个阶段全在）。
    # 存在的理由只有一个 —— minimal 只含 ledger/account/txn，
    # 于是 ImportIntegrityCheck 的 touchedTables 过滤会把
    # category / tag / budget / attachment 这四张表的引用规则全部跳过，
    # 13 条规则里有 7 条在任何 apply 向量里都**没有执行证据**。
    full_sample = samples["sample-full"]
    full_hex = full_sample["payloadNdjsonHex"]
    full_payload = bytes.fromhex(full_hex)
    full_sha = full_sample["fileSha256"]
    full_name = full_sample["fileName"]

    def apply_input(**overrides) -> dict:
        base = {
            "jobId": job_id, "fileName": file_name, "fileSha256": file_sha,
            "nowMillis": APPLY_NOW, "ndjsonHex": payload_hex,
            "localRows": {}, "importedFile": [], "quickCheck": "ok",
            "orphanViolations": {}, "backup": "ok",
        }
        base.update(overrides)
        return base

    def sim(**kwargs) -> dict:
        params = {"import_job_id": job_id, "file_name": file_name,
                  "file_sha256": file_sha}
        params.update(kwargs)
        return ApplySim(payload, **params).run()

    def full_apply_input(**overrides) -> dict:
        base = {
            "jobId": job_id, "fileName": full_name, "fileSha256": full_sha,
            "nowMillis": APPLY_NOW, "ndjsonHex": full_hex,
            "localRows": {}, "importedFile": [], "quickCheck": "ok",
            "orphanViolations": {}, "backup": "ok",
        }
        base.update(overrides)
        return base

    def full_sim(**kwargs) -> dict:
        params = {"import_job_id": job_id, "file_name": full_name,
                  "file_sha256": full_sha}
        params.update(kwargs)
        return ApplySim(full_payload, **params).run()

    cases: list[dict] = []

    cases.append(value_case(
        "import.apply.insert-new",
        "import.apply",
        "空库导入：全部插入 —— 语句日志、列序、事务边界逐条钉死",
        apply_input(),
        sim(),
        "★ 一条用例同时钉住五件事：① 写入按阶段序（父实体先行）；"
        "② account 的 INSERT 列里**没有** cached_balance_minor / balance_as_of"
        "（派生态丢弃）；③ 所有值都走参数（SQL 里没有任何字面量数据）——"
        "「100% 参数化」这条硬约束的唯一机器化证据；④ SAVEPOINT 在所有写入之前、"
        "RELEASE 在余额重算之后；⑤ 余额重算在提交之前被调用。"
        "SQL 措辞是**转录**（规格没给逐字原文），它锁的是「以后不能悄悄改」。",
        ["security", "format"],
    ))

    full_minimal_rows = {
        TABLE_OF_TYPE[r["type"]]: [] for r in minimal["records"]
    }
    for record in minimal["records"]:
        full_minimal_rows[TABLE_OF_TYPE[record["type"]]].append(local_row_of(record))

    cases.append(value_case(
        "import.apply.idempotent-skip",
        "import.apply",
        "同 id 同内容 ⇒ 跳过（版本戳与本地独有列都不参与内容比较）",
        apply_input(localRows=full_minimal_rows),
        sim(local_rows=full_minimal_rows),
        "★ 本地行刻意改了 rev / updated_at / created_at / device_id，"
        "并补上了载荷里没有的列（txn.source_import_job、account 的缓存余额）—— "
        "这些在两台设备上天然不同，若算进「内容是否相同」，"
        "同一份文件的重复导入就会变成一次冲突弹窗。"
        "注意 summary.skipped=4 而语句日志里一条数据 INSERT 都没有。",
        ["convergence"],
    ))

    cases.append(value_case(
        "import.apply.file-sha256-short-circuit",
        "import.apply",
        "整文件 sha256 命中 imported_file ⇒ 幂等短路（零写入、不备份）",
        apply_input(importedFile=[{"job_id": "01J8PREVJOB00000000000001",
                                   "imported_at": 1789540000000}]),
        sim(imported_file=[{"job_id": "01J8PREVJOB00000000000001",
                            "imported_at": 1789540000000}]),
        "★ 与上一条的区别：上一条比的是**记录内容**（数据库被别处改过也能正确跳过），"
        "这一条比的是**文件字节**（同样的字节导入两次，第二次连读都不必读）。"
        "两条都要有：只做字节短路，用户改一个字节重导就会重复插入；"
        "只做内容比较，反向增量文件的行序变化会让短路失效。",
        ["convergence"],
    ))

    changed = [local_row_of(minimal["records"][2]), local_row_of(minimal["records"][3],
                                                               override={"amount_minor": 1})]
    conflict_rows = {"ledger": [local_row_of(minimal["records"][0])],
                     "account": [local_row_of(minimal["records"][1]), changed[0]],
                     "txn": [changed[1]]}
    cases.append(value_case(
        "import.apply.conflict-deferred",
        "import.apply",
        "同 id 但内容不同 ⇒ 整批中止并抛 PFI_E_CONFLICT（不猜、不覆盖）",
        apply_input(localRows=conflict_rows),
        sim(local_rows=conflict_rows),
        "★ 这是**提交 B 的接缝**，不是本提交的能力：§4.4 的三十组裁决表"
        "（LWW、墓碑、宽限窗口）未落地前，执行器没有任何依据决定"
        "「文件里的值」与「本地值」谁该赢。此时唯一正确的动作是中止 ——"
        "注意 outcome=error 且 statements 停在计划查询，backupCalls 为空："
        "**连备份都没有做**，因为还没写任何东西。",
        ["convergence"],
    ))

    cases.append(value_case(
        "import.apply.backup-failed",
        "import.apply",
        "导入前备份失败 ⇒ PFI_E_BACKUP，且一条写语句都没发",
        apply_input(backup="fail"),
        sim(backup="fail"),
        "★ 备份在事务之前、在写任何行之前（§4.5）。因此备份失败时"
        "「数据没有被修改」不是承诺，而是**结构上不可能**被修改 —— "
        "要证明这一点，就得证明语句日志里连 SAVEPOINT 都没有。",
        ["security"],
    ))

    cases.append(value_case(
        "import.apply.reference-missing",
        "import.apply",
        "孤儿扫描发现 3 行悬空 ⇒ PFI_E_INCOMPATIBLE + ROLLBACK TO import_stage",
        apply_input(orphanViolations={"txn.account_id": 3}),
        sim(orphan_violations={"txn.account_id": 3}),
        "★ 引用修复（§4.4 S11/S12 的「造一个占位账户」）属提交 B；"
        "本提交的选择是**整体回滚**并说清哪条引用悬空。"
        "注意轨迹：全体写入已发生 → 扫描 → 抛错 → ROLLBACK TO → RELEASE → "
        "事务回滚 → 台账记为 failed 且计数为 0（被回滚的 insert 不能记进 inserted_cnt，"
        "否则「报告说写了 4 条」与「库里一条都没有」会同时成立）。",
        ["format"],
    ))

    cases.append(value_case(
        "import.apply.reference-rules-full",
        "import.apply",
        "full 载荷（11 条 / 八阶段齐全）⇒ 13 条引用规则全部执行，四表写入逐列钉死",
        full_apply_input(),
        full_sim(),
        "★ 这条向量补的是一个**覆盖空洞**，不是一条新行为："
        "其余 apply 用例的载荷都是 minimal（只含 ledger/account/txn），"
        "而 ImportIntegrityCheck.assertAll 按 touchedTables 过滤 —— "
        "于是 category.ledger_id / category.parent_id / tag.ledger_id / "
        "budget.ledger_id / budget.category_id / attachment.ledger_id / "
        "attachment.txn_id 这七条规则在补它之前从未被执行过，"
        "四张表的写入路径也一次都没走过。"
        "换成 full 载荷（category×2 / tag / budget / attachment 各一）后 "
        "13/13 条规则都真跑了一次（n=0 的罐头被扫过），"
        "且这四张表的 INSERT 列集合与参数顺序第一次有了逐字证据。"
        "注意 INSERT 走 run() 不查罐头：它的列集合由 statements 锁定、"
        "参数顺序由 arguments 锁定，unusedCanned 只覆盖查询面；"
        "四表罐头在命中矩阵里全 Y 才是「规则执行过」的证据。",
        ["format"],
    ))

    cases.append(value_case(
        "import.apply.write-failure-rollback",
        "import.apply",
        "写入途中底层失败 ⇒ 原样上抛底层码 + 整体回滚 + 台账记 failed",
        apply_input(failOn="INSERT INTO txn"),
        sim(fail_on="INSERT INTO txn"),
        "两条性质一次锁住：① 低层错误码**不被包装**（包装会抹掉唯一有用的排查线索），"
        "这里上抛的是 PFD_E_OPEN；② 半途失败不留残迹 —— "
        "ROLLBACK TO import_stage + RELEASE + 事务级 ROLLBACK 三件套齐备。",
        ["format"],
    ))

    cases.append(value_case(
        "import.apply.quick-check-damaged",
        "import.apply",
        "写入后 PRAGMA quick_check 未通过 ⇒ PFD_E_OPEN + 整体回滚",
        apply_input(quickCheck="corrupted"),
        sim(quick_check="corrupted"),
        "页级自检是「这次写入有没有把库写坏」的兜底观测点。它排在孤儿扫描**之前**："
        "库页都坏了的时候，再去问「引用是否悬空」得到的是没有意义的答案。",
        ["format"],
    ))
    return cases


# ---------------------------------------------------------------------------
# 自检
# ---------------------------------------------------------------------------


def self_check(samples: dict[str, dict], cases: list[dict]) -> None:
    # 1. 样本必须真的能被独立解开，且逐条对得上
    for sample in samples.values():
        blob = bytes.fromhex(sample["fileHex"])
        assert blob[:8] == container_pfb.MAGIC, f"{sample['id']}: 魔数不对"
        assert hashlib.sha256(blob).hexdigest() == sample["fileSha256"], "文件 SHA 自洽"
        plain = container_pfb.open_pfb(blob, PASSWORD, KDF, SALT)
        payload = gzip.decompress(plain)
        assert payload.hex() == sample["payloadNdjsonHex"], f"{sample['id']}: 载荷对不上"
        assert hashlib.sha256(payload).hexdigest() == sample["payloadSha256"]
        # 载荷自身的 contentHash 必须等于记录区字节的摘要
        lines = payload.decode("utf-8").splitlines()
        end = json.loads(lines[-1])
        region = b"".join((ln + "\n").encode("utf-8") for ln in lines[1:-1])
        assert end["contentHash"] == "sha256:" + hashlib.sha256(region).hexdigest()
        assert end["recordCount"] == len(lines) - 2 == sample["recordCount"]
        # 缓存余额与重算结果**必须**不一致（这条是样本设计的硬要求）
        if sample["id"] in ("sample-full", "sample-range"):
            mismatch = any(
                sample["fileCachedBalanceMinor"][acc] != recalc["balanceMinor"]
                for acc, recalc in sample["recalculatedBalances"].items()
                if acc in sample["fileCachedBalanceMinor"]
            )
            assert mismatch, f"{sample['id']}: 缓存余额必须与重算结果不一致"

    # 2. 写入列序必须真的来自 DDL：抽查几处关键事实
    account_columns = list(explain_record(row_account_a1())["columns"])
    assert account_columns[0] == "id" and account_columns[5] == "opening_balance_minor"
    assert "cached_balance_minor" not in account_columns, "派生态必须被丢弃"
    assert "balance_as_of" not in account_columns
    # 派生键必须落在字段表的位置上（不因「文件里没写」而跑到末尾）
    txn_with_keys = list(explain_record(row_txn_x1(keys=True))["columns"])
    txn_derived = list(explain_record(row_txn_x1(keys=False))["columns"])
    assert txn_with_keys == txn_derived, "day_key/month_key 的列序不随「文件里有没有」而变"
    assert txn_derived[6] == "day_key" and txn_derived[7] == "month_key"
    assert txn_derived[-1] == "rev", "rev 必须仍在末尾（origin_device_id 在它之前）"
    # storage=2 的附件行不得因为缺 data 而被判为「必需字段缺失」。
    # 注意：`data` **在 columns 里是有的**，值为 null —— 缺失的可空字段
    # 仍然占位（列序 = 字段表序，与「文件里带没带」无关）。
    external = explain_record(row_attachment(storage=2))["columns"]
    assert external["ext_rel_path"].endswith(".jpg")
    assert external["data"] is None and external["wrapped_dek"] is None
    inline = explain_record(row_attachment(storage=1))["columns"]
    assert inline["data"] == {"hex": ATTACHMENT_BYTES.hex()}
    assert inline["ext_rel_path"] is None

    # 3. 字段表的键必须是**表名**，且与「载荷类型 → 表名」映射的值域严格一致。
    #    这是结构性防御：TYPES 与 TABLE_OF_TYPE 是两份手工维护的清单，
    #    一旦键名漂移（theme vs theme_profile），explain_record 只会在
    #    **样本恰好用到该类型时**才 KeyError —— 偏偏最容易漏测的就是 theme。
    assert set(TYPES) == set(TABLE_OF_TYPE.values()), (
        "字段表键与类型映射值域不一致："
        f"仅在 TYPES={sorted(set(TYPES) - set(TABLE_OF_TYPE.values()))}，"
        f"仅在映射={sorted(set(TABLE_OF_TYPE.values()) - set(TYPES))}"
    )
    assert set(TABLE_OF_TYPE) == set(STAGE_ORDER), "类型映射的键域必须等于载荷阶段序"
    for table, fields in TYPES.items():
        cols = [column for _, column, _, _ in fields]
        json_keys = [json_key for json_key, _, _, _ in fields]
        assert len(cols) == len(set(cols)), f"{table}: 列名重复"
        # 判别键在记录行里独占（§4.1）。查的是**载荷键**（第一分量），
        # 列名当然可以叫 type —— DB 层不受影响。
        # 与 Dart 侧 _assertFieldTablesExcludeDiscriminator 同一条约束 ——
        # account/txn 曾经就是在这里把行类型吞掉的。
        assert DISCRIMINATOR not in json_keys, (
            f"{table}: 字段表把判别键 {DISCRIMINATOR!r} 当成了业务字段的载荷键"
        )
    assert {"day_key", "month_key"} <= {c for _, c, _, _ in TYPES["txn"]}, "派生键必须进字段表"

    # 4. 用例 id 唯一、kind 是已知的四种
    kinds = {"import.triage.failure", "import.payload.decode", "import.file.read", "import.apply"}
    ids = [c["id"] for c in cases]
    assert len(ids) == len(set(ids)), "用例 id 必须唯一"
    assert all(c["kind"] in kinds for c in cases)
    assert all(c["expect"] for c in cases)

    # 5. apply 用例的期望值必须自洽：语句与参数一一对应
    for c in cases:
        if c["kind"] != "import.apply":
            continue
        value = c["expect"]["value"]
        assert len(value["statements"]) == len(value["arguments"]), f"{c['id']}: 语句/参数不等长"
        # 罐头键的未命中集必须有序且无重复；更要紧的是：**登记了 localRows 的表
        # 必须真的被查询过** —— 否则「本地已有行」那批罐头根本没被读到，
        # 幂等跳过与冲突中止这几条就会在空数据上跑，然后静默假通过。
        assert value["unusedCanned"] == sorted(set(value["unusedCanned"])), c["id"]
        for table in c["input"].get("localRows", {}):
            probe = "SELECT * FROM " + table + " WHERE id IN ("
            assert probe not in value["unusedCanned"], (
                f"{c['id']}: 登记了 {table} 的本地行，却从没查过它"
            )
        if value["outcome"] == "error":
            assert value["errorCode"], f"{c['id']}: 出错却没有码"

    # 6. 参数化这条硬约束的机器化检查：SQL 里不许出现样本数据
    for c in cases:
        if c["kind"] != "import.apply":
            continue
        for sql in c["expect"]["value"]["statements"]:
            assert "01J8" not in sql, f"{c['id']}: SQL 里出现了数据（{sql[:60]}）"
            assert "星巴克" not in sql and "招行" not in sql


def build_fixture(samples: dict[str, dict]) -> dict:
    return {
        "schemaVersion": 1,
        "description": (
            "导入器的固定样本（§4.3）：字节以 hex 存放，因为 .pfb 本体按 "
            "tracked_paths.yaml 的 tracked-vault-file 规则不允许入库（B1 决策 2026-09-18）。"
            "本文件是样本字节的权威存放处，由 tools/golden_vectors_gen/import_samples.py "
            "生成；test_vectors/v1/import_payload.json 里内联的同一批 hex 由同一次生成产出，"
            "并由该脚本的 --check 断言两者一致（向量必须自包含：驱动不读文件系统）。"
            "decoded / recalculatedBalances 是 Python 独立解开后得到的解释，"
            "不是 Dart 实现的输出。"
        ),
        "password": PASSWORD,
        "wrongPassword": WRONG_PASSWORD,
        "kdf": KDF,
        "saltHex": SALT.hex(),
        "noncePrefixHex": NONCE_PREFIX.hex(),
        "volumeSetIdHex": VOLUME_SET_ID.hex(),
        "chunkPlainSizeKiB": CHUNK_KIB,
        "samples": [samples[key] for key in (
            "sample-full", "sample-range", "sample-ledger", "sample-incremental",
            "sample-apply-minimal",
        )],
    }


def build_suite(samples: dict[str, dict], cases: list[dict]) -> dict:
    return {
        "schemaVersion": 1,
        "suite": "import_payload",
        "title": "导入器：三态分流 / 载荷解码 / 整文件读取 / 写入编排（§4.3）",
        "description": (
            "四个 kind 对应导入器四段可独立判定的性质。载荷与文件两组用 "
            "test_vectors/fixtures/import_samples.json 里的固定样本（Python 独立封包并解开），"
            "分流表与编排轨迹来自规格 §4.3 的原文转录。"
            "编排轨迹（import.apply）里含**转录**的 SQL 措辞 —— 那部分锁的是"
            "「以后不能悄悄改」，不是「当初推导得对」；相关用例的 notes 已写明。"
        ),
        "cases": cases,
    }


def build_all() -> tuple[dict, dict]:
    samples = {
        spec["id"]: build_sample_artifacts(spec) for spec in (fn() for fn in SAMPLES)
    }
    cases: list[dict] = []
    cases += triage_cases()
    cases += decode_cases(samples)
    cases += file_read_cases(samples)
    cases += apply_cases(samples)
    self_check(samples, cases)
    return build_fixture(samples), build_suite(samples, cases)


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------


def _dump(obj: dict) -> str:
    return json.dumps(obj, ensure_ascii=False, indent=2) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="写入 fixtures 与 vectors")
    parser.add_argument("--check", action="store_true", help="只核对磁盘上的文件")
    args = parser.parse_args()
    if args.write and args.check:
        print("--write 与 --check 互斥", file=sys.stderr)
        return 2

    fixture, suite = build_all()

    if args.write:
        FIXTURE_PATH.parent.mkdir(parents=True, exist_ok=True)
        FIXTURE_PATH.write_text(_dump(fixture), encoding="utf-8", newline="\n")
        VECTOR_PATH.write_text(_dump(suite), encoding="utf-8", newline="\n")
        print(f"[ok] 写入 {FIXTURE_PATH.relative_to(REPO)}"
              f"（{len(fixture['samples'])} 个样本）")
        print(f"[ok] 写入 {VECTOR_PATH.relative_to(REPO)}（{len(suite['cases'])} 条用例）")
        return 0

    if args.check:
        # 只校验、不产出：用磁盘上的样本重算，逐字节比对。
        # 它守两件事：① 样本没被动过（hex 与 sha256 自洽）；② 向量文件没有
        # 与样本漂移（同一批 hex 在两处必须相同）。
        for path, expected in ((FIXTURE_PATH, fixture), (VECTOR_PATH, suite)):
            if not path.exists():
                print(f"missing {path}", file=sys.stderr)
                return 1
            if json.loads(path.read_text(encoding="utf-8")) != expected:
                print(f"MISMATCH {path.name}", file=sys.stderr)
                return 1
        print(f"checked {FIXTURE_PATH.name} + {VECTOR_PATH.name}")
        return 0

    print(f"[dry] {len(fixture['samples'])} 个样本、{len(suite['cases'])} 条用例（未写文件）")
    for sample in fixture["samples"]:
        print(f"  · {sample['id']:22s} {sample['fileBytes']:5d} B .pfb"
              f" / {sample['payloadBytes']:5d} B 载荷 / {sample['recordCount']} 条记录")
    kinds: dict[str, int] = {}
    for c in suite["cases"]:
        kinds[c["kind"]] = kinds.get(c["kind"], 0) + 1
    for kind, count in sorted(kinds.items()):
        print(f"  {kind:26s} {count} 条")
    return 0


if __name__ == "__main__":
    sys.exit(main())

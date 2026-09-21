#!/usr/bin/env python3
"""导入期裁决 / 计划 / 收敛性 / 引用修复的黄金向量生成器（规格 §4.4）—— 提交 B。

覆盖的 kind（对应 packages/pf_testkit/lib/src/drivers/m1_import_conflict.dart）：
  - import.merge.record      单条记录的七态裁决（§4.4 裁决表）
  - import.merge.plan        一批记录的写入计划（语句序列 / 计数 / 待软删 / 冲突登记）
  - import.merge.converge    可交换 / 幂等 / 可结合（§4.4 S27–S29）
  - import.merge.reference   引用修复（§4.4 S11–S14）

## 期望值从哪来

**本脚本按 §4.4 的规则独立实现了一遍裁决、计划与引用修复**，期望值由这一份
实现在生成时算出（Python 侧零共享 Dart 代码）。这与 `balance_replay.py` 是同一
手法：不放「跑一遍实现、把它的输出抄进来」的期望值。

三个基础件也必须独立可信，因此脚本开头先把它们对齐到**已发布的向量**
（`self_check()`，对不上直接退出，不写文件）：

  1. **ULID 编码** —— 对齐 `test_vectors/v1/ulid.json` 的四条 encode 用例
     （参考 ULID `01JGFJJZ00000G40R40M30E209` 等）。合成版本戳与冲突主键都靠它。
  2. **Crockford 表** —— 与 `UlidGenerator` 同一张表（排除 I / L / O / U）。
  3. **规范化 JSON** —— 与 Dart `jsonEncode` 同口径（无空格、键序保持、非 ASCII
     不转义），因为内容指纹就是「规范化 JSON 的 SHA-256」。

ULID 与 JSON 这两条是**真正的锚点**：它们不是「我认为应该这样」，而是
已经在别的套件里被锁死的事实。剩下的规则（裁决表 / 计划 / 修复）是本脚本
按规格重写的一份，它与 Dart 侧的对账就是这套向量的全部意义。

## 与 A 的样例 id 的差别（有意为之）

`fixtures/import_samples.json` 里的 id **不是合法 ULID**（见 test_vectors/README
「未来约束」一节），因为 A 的路径不做格式校验。本套件的裁决路径会走
`resolveRecordVersion`，而它**要求**版本元数据是合法 ULID（`RecordVersion.isValid`）。
因此本套件的 id 一律由本脚本的 ULID 编码器生成 —— 这不是迁就实现，
而是 A 的样本与 B 的裁决表本来就服务于两件不同的事。

用法：
  python import_conflict.py            # 自检 + 打印条数，不写文件
  python import_conflict.py --write    # 写入 test_vectors/v1/import_conflict.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

# ─────────────────────────── 基础件：ULID / 哈希 / JSON ───────────────────────────

CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
MAX_ULID_MS = 0xFFFFFFFFFFFF

REPO_ROOT = Path(__file__).resolve().parents[2]
VECTOR_PATH = REPO_ROOT / "test_vectors" / "v1" / "import_conflict.json"

ULID_ANCHORS = [
    (0, "00000000000000000000", "00000000000000000000000000"),
    (1, "00000000000000000000", "00000000010000000000000000"),
    (1735689600000, "00010203040506070809", "01JGFJJZ00000G40R40M30E209"),
    (281474976710655, "ffffffffffffffffffff", "7ZZZZZZZZZZZZZZZZZZZZZZZZZ"),
]


def ulid_encode(milliseconds: int, random_bytes: bytes) -> str:
    """`UlidGenerator.encode` 的镜像：48 位毫秒 + 80 位随机 → 26 字符 Crockford。"""
    assert 0 <= milliseconds <= MAX_ULID_MS, milliseconds
    assert len(random_bytes) == 10, len(random_bytes)
    values = [0] * 26
    remaining = milliseconds
    for i in range(9, -1, -1):
        values[i] = remaining & 0x1F
        remaining >>= 5
    buffer = 0
    bits = 0
    index = 10
    for byte in random_bytes:
        buffer = (buffer << 8) | byte
        bits += 8
        while bits >= 5:
            bits -= 5
            values[index] = (buffer >> bits) & 0x1F
            index += 1
    return "".join(CROCKFORD[v] for v in values)


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canon_json(value: object) -> str:
    """与 Dart `jsonEncode` 同口径的规范化 JSON（无空格、键序保持、非 ASCII 原样）。"""
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def mk_id(seed: str, at: int = 1789452000000) -> str:
    """由种子确定性派生的合法 ULID（26 字符、首字符 ≤ 7）。"""
    return ulid_encode(at & MAX_ULID_MS, hashlib.sha256(seed.encode("utf-8")).digest()[:10])


FINGERPRINT_EXCLUDED = {"rev", "updated_at", "created_at", "device_id", "source_import_job"}


def content_fingerprint(columns: dict) -> str:
    keys = sorted(k for k in columns if k not in FINGERPRINT_EXCLUDED)
    return sha256_hex(canon_json({k: columns[k] for k in keys}).encode("utf-8"))


def normalize_ms(raw: int) -> int:
    return 0 if raw < 1 else raw


def version_stamp(updated_at_ms: int, device_id: str) -> str:
    return ulid_encode(normalize_ms(updated_at_ms), hashlib.sha256(device_id.encode("utf-8")).digest()[:10])


SKEW_WINDOW_MS = 60000

# ─────────────────────────── 阶段序与表 ───────────────────────────

STAGE_ORDER = ["ledger", "account", "category", "tag", "theme", "txn", "budget", "attachment"]
TABLE_OF = {
    "ledger": "ledger",
    "account": "account",
    "category": "category",
    "tag": "tag",
    "theme": "theme_profile",
    "txn": "txn",
    "budget": "budget",
    "attachment": "attachment",
}

# §2.3 的全部外键引用（顺序即扫描顺序）。`ledger_id` 一族用于覆盖模式的待软删清单。
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

# ─────────────────────────── 固定时间轴与身份 ───────────────────────────

DEV_FILE = mk_id("pf-vector-device-file")
DEV_LOCAL = mk_id("pf-vector-device-local")

T_FILE = 1789452000000
T_NEW = T_FILE + 600000  # 晚 10 分钟（远超 60s 宽限窗口）
T_NEAR = T_FILE + 30000  # 晚 30 秒（落在 60s 宽限窗口内）
T_OLD = T_FILE - 600000
NOW = 1789550000000
JOB = "01J8TESTJOB000000000000001"
SPLIT_SHIFT = 4  # ULID 前缀共 10 字符，判「是否落在同一毫秒」看前 10 位


# ─────────────────────────── 记录构造 ───────────────────────────


def rec(type_: str, id_: str, at: int, columns: dict, device: str | None = None) -> dict:
    """构造一条记录（列集合自洽：id / updated_at / device_id 三处一致）。

    `id` 放在列首、版本元数据放列尾：SQL 的列序就是这里的键序，而
    「INSERT INTO account (id, ledger_id, …, updated_at, device_id)」是人读得懂的顺序。
    """
    device = device or DEV_FILE
    cols = {"id": id_, **columns}
    cols["updated_at"] = at
    cols["device_id"] = device
    return {
        "type": type_,
        "table": TABLE_OF[type_],
        "id": id_,
        "columns": cols,
        "updatedAt": at,
        "deviceId": device,
        "isTombstone": cols.get("deleted_at") is not None,
    }


def as_input(record: dict, index: int | None = None) -> dict:
    """记录 → 向量输入形态（去掉派生的 table / isTombstone，可选带 recordIndex）。"""
    out = {
        "type": record["type"],
        "id": record["id"],
        "updatedAt": record["updatedAt"],
        "deviceId": record["deviceId"],
        "columns": record["columns"],
    }
    if index is not None:
        out["recordIndex"] = index
    return out


def matches_local(remote: dict, local: dict) -> bool:
    keys = sorted(k for k in remote["columns"] if k not in FINGERPRINT_EXCLUDED)
    incoming = {k: remote["columns"][k] for k in keys}
    existing = {k: local.get(k) for k in keys}
    return content_fingerprint(incoming) == content_fingerprint(existing)


def remote_version(remote: dict) -> dict:
    return {
        "id": remote["id"],
        "versionStamp": version_stamp(remote["updatedAt"], remote["deviceId"]),
        "deviceId": remote["deviceId"],
        "contentHash": content_fingerprint(remote["columns"]),
        "deleted": remote["isTombstone"],
    }


def local_version(remote: dict, local: dict) -> dict | None:
    """库行的版本；`device_id` 不可用时返回 None（镜像 `_localVersionOrNull`）。"""
    device = local.get("device_id")
    if not isinstance(device, str) or not device:
        return None
    keys = [k for k in remote["columns"] if k not in FINGERPRINT_EXCLUDED]
    updated_at = local.get("updated_at")
    return {
        "id": remote["id"],
        "versionStamp": version_stamp(updated_at if isinstance(updated_at, int) else 0, device),
        "deviceId": device,
        "contentHash": content_fingerprint({k: local.get(k) for k in keys}),
        "deleted": local.get("deleted_at") is not None,
    }


def resolve(local_v: dict, remote_v: dict) -> tuple[str, str, bool]:
    """`resolveRecordVersion` 的镜像 → (side, reason, needsUserReview)。"""
    if local_v["id"] != remote_v["id"]:
        raise AssertionError("id 不同，不能比较版本")
    if all(local_v[k] == remote_v[k] for k in ("id", "versionStamp", "deviceId", "contentHash", "deleted")):
        return ("none", "identical", False)
    comparison = (local_v["versionStamp"] > remote_v["versionStamp"]) - (
        local_v["versionStamp"] < remote_v["versionStamp"]
    )
    same_content = (
        local_v["contentHash"] == remote_v["contentHash"] and local_v["deleted"] == remote_v["deleted"]
    )
    if same_content:
        return ("local" if comparison > 0 else "remote", "metadata_only", False)
    if comparison == 0:
        local_wins = local_v["contentHash"] > remote_v["contentHash"]
        return ("local" if local_wins else "remote", "stamp_collision", True)
    same_ms = local_v["versionStamp"][:SPLIT_SHIFT] == remote_v["versionStamp"][:SPLIT_SHIFT]
    return ("local" if comparison > 0 else "remote", "newer_stamp", same_ms)


# ─────────────────────────── mergeRecord 的镜像（§4.4） ───────────────────────────


def _write(record: dict, replace: bool) -> dict:
    columns = record["columns"]
    if replace:
        sql = "UPDATE {} SET {} WHERE id = ?".format(
            record["table"], ", ".join(f"{c} = ?" for c in columns)
        )
        args = list(columns.values()) + [record["id"]]
    else:
        sql = "INSERT INTO {} ({}) VALUES ({})".format(
            record["table"], ", ".join(columns), ", ".join("?" for _ in columns)
        )
        args = list(columns.values())
    return {
        "table": record["table"],
        "id": record["id"],
        "columns": columns,
        "sql": sql,
        "arguments": args,
        "replace": replace,
    }


def merge_record(
    remote: dict,
    local: dict | None,
    mode: str = "merge",
    strategy: str = "abort",
    delete_edit: str = "delete_wins",
    skew_window: int = SKEW_WINDOW_MS,
) -> dict:
    """`mergeRecord` 的镜像。返回的内部字典比驱动输出多几个键（见 `record_expect`）。"""

    def plain(outcome, rule, side="none", write=None, conflict=None, lv=None, rv=None):
        return {
            "entityKind": remote["table"],
            "recordId": remote["id"],
            "outcome": outcome,
            "rule": rule,
            "side": side,
            "conflictKind": conflict,
            "needsUserReview": conflict is not None,
            "write": write,
            "localVersion": lv,
            "remoteVersion": rv,
        }

    if mode == "supplement_only":
        if local is None:
            return plain(
                "insert_tombstone" if remote["isTombstone"] else "insert",
                "fill_only_new",
                side="remote",
                write=_write(remote, False),
            )
        return plain("skip", "fill_only_existing", side="local")

    if mode == "replace":
        if local is None:
            return plain(
                "insert_tombstone" if remote["isTombstone"] else "insert",
                "overwrite_tombstone" if remote["isTombstone"] else "overwrite_by_file",
                side="remote",
                write=_write(remote, False),
            )
        return plain(
            "mark_deleted" if remote["isTombstone"] else "update",
            "overwrite_tombstone" if remote["isTombstone"] else "overwrite_by_file",
            side="remote",
            write=_write(remote, True),
        )

    if local is None:
        return plain(
            "insert_tombstone" if remote["isTombstone"] else "insert",
            "local_missing_tombstone" if remote["isTombstone"] else "local_missing",
            side="remote",
            write=_write(remote, False),
        )

    if strategy == "abort":
        if matches_local(remote, local):
            return plain("skip", "identical_content")
        deleted_local = local.get("deleted_at") is not None
        return plain(
            "conflict",
            "abort_on_divergence",
            conflict=2 if deleted_local != remote["isTombstone"] else 1,
            lv=local_version(remote, local),
            rv=remote_version(remote),
        )

    same_content = matches_local(remote, local)
    deleted_local = local.get("deleted_at") is not None
    if same_content and deleted_local == remote["isTombstone"]:
        return plain("skip", "identical_content")

    lv = local_version(remote, local)
    rv = remote_version(remote)
    assert lv is not None, "converge 路径要求本地行有 device_id"
    side, _reason, _review = resolve(lv, rv)
    remote_wins = side == "remote"

    if deleted_local and remote["isTombstone"]:
        return plain("skip", "both_deleted", side=side, lv=lv, rv=rv)

    if deleted_local != remote["isTombstone"]:
        revised_is_newer = remote_wins if deleted_local else not remote_wins
        if not revised_is_newer:
            if deleted_local:
                return plain("skip", "tombstone_wins", side="local", lv=lv, rv=rv)
            return plain(
                "mark_deleted", "tombstone_wins", side="remote", write=_write(remote, True), lv=lv, rv=rv
            )
        if delete_edit == "edit_wins_by_lww":
            return plain(
                "resurrect", "delete_vs_edit_lww", side="remote", write=_write(remote, True), lv=lv, rv=rv
            )
        return plain(
            "conflict",
            "delete_vs_edit",
            side=side,
            write=_write(remote, True) if remote_wins else None,
            conflict=2,
            lv=lv,
            rv=rv,
        )

    if same_content:
        return plain("skip", "identical_content", side=side, lv=lv, rv=rv)

    local_updated_at = local.get("updated_at")
    delta = abs(remote["updatedAt"] - (local_updated_at if isinstance(local_updated_at, int) else 0))
    collided = lv["versionStamp"] == rv["versionStamp"]
    if collided or delta < skew_window:
        return plain(
            "conflict",
            "stamp_collision" if collided else "ambiguous_window",
            side=side,
            write=_write(remote, True) if remote_wins else None,
            conflict=1,
            lv=lv,
            rv=rv,
        )
    if remote_wins:
        return plain("update", "remote_newer", side="remote", write=_write(remote, True), lv=lv, rv=rv)
    return plain("skip", "local_newer", side="local", lv=lv, rv=rv)


def decision_reason_of(decision: dict) -> str:
    return {
        "stamp_collision": "stamp_collision",
        "ambiguous_window": "metadata_only",
    }.get(decision["rule"], "newer_stamp")


def record_expect(decision: dict) -> dict:
    """把内部裁决投影成 `import.merge.record` 驱动的输出（键必须逐字一致）。"""
    return {
        "entityKind": decision["entityKind"],
        "outcome": decision["outcome"],
        "rule": decision["rule"],
        "side": decision["side"],
        "conflictKind": decision["conflictKind"],
        "needsUserReview": decision["needsUserReview"],
        "write": None if decision["write"] is None else pub_write(decision["write"]),
        "localVersionStamp": None if decision["localVersion"] is None else decision["localVersion"]["versionStamp"],
        "remoteVersionStamp": None
        if decision["remoteVersion"] is None
        else decision["remoteVersion"]["versionStamp"],
    }


def pub_write(write: dict) -> dict:
    """对外形态的写入（驱动输出只有这三个键）。"""
    return {"sql": write["sql"], "arguments": write["arguments"], "replace": write["replace"]}


# ─────────────────────────── 引用修复的镜像（§4.4 S11–S14） ───────────────────────────

PLACEHOLDER_ACCOUNT_NAME = "（来自其他设备）"
PLACEHOLDER_CATEGORY_PREFIX = "（来自其他设备·"
MAX_CATEGORY_DEPTH = 8

REPAIR_TARGETS = {
    "txn": {"account_id": "account", "to_account_id": "account", "category_id": "category"},
    "budget": {"category_id": "category"},
    "account": {"repay_account_id": "account"},
}


def placeholder_category_name(id_: str) -> str:
    tail = id_ if len(id_) <= 8 else id_[-8:]
    return f"{PLACEHOLDER_CATEGORY_PREFIX}{tail}）"


def _id_index(local_rows: dict, alive_only: bool) -> dict:
    index: dict[str, set] = {}
    for table, rows in local_rows.items():
        for row in rows:
            id_ = row.get("id")
            if not isinstance(id_, str):
                continue
            if alive_only and row.get("deleted_at") is not None:
                continue
            index.setdefault(table, set()).add(id_)
    return index


def _parent_links(records: list, local_rows: dict) -> dict:
    links: dict[str, str] = {}
    for row in local_rows.get("category", []):
        if (
            isinstance(row.get("id"), str)
            and isinstance(row.get("parent_id"), str)
            and row.get("deleted_at") is None
        ):
            links[row["id"]] = row["parent_id"]
    for record in records:
        parent = record["columns"].get("parent_id")
        if record["type"] == "category" and isinstance(parent, str) and not record["isTombstone"]:
            links[record["id"]] = parent
    return links


def _parent_broken_reason(parent_id, self_id, parent_of, alive_categories, known_categories):
    if parent_id == self_id:
        return "cycle"
    current = parent_id
    visited = {self_id}
    depth = 0
    while True:
        if current in visited:
            return "cycle"
        visited.add(current)
        depth += 1
        if depth > MAX_CATEGORY_DEPTH:
            return "too_deep"
        nxt = parent_of.get(current)
        if nxt is None:
            break
        current = nxt
    if parent_id in alive_categories:
        return None
    return "deleted" if parent_id in known_categories else "missing"


def _duplicate_name(record: dict, parent_id, local_rows: dict):
    for row in sorted(local_rows.get("category", []), key=lambda r: str(r.get("id"))):
        if row.get("deleted_at") is not None or row.get("id") == record["id"]:
            continue
        if (
            row.get("ledger_id") != record["columns"].get("ledger_id")
            or row.get("kind") != record["columns"].get("kind")
            or row.get("name") != record["columns"].get("name")
        ):
            continue
        local_parent = row.get("parent_id")
        if (local_parent if isinstance(local_parent, str) else "") != parent_id:
            continue
        return row["id"]
    return None


def _category_kind_of(referrer: dict) -> int:
    if referrer["type"] == "txn":
        return 2 if referrer["columns"].get("type") == 2 else 1
    return 1


def _placeholder_record(parent: str, id_: str, referrer: dict, device_id: str, at: int) -> dict:
    ledger_id = referrer["columns"].get("ledger_id")
    assert isinstance(ledger_id, str), "被引用记录缺 ledger_id"
    common = {"created_at": at, "updated_at": at, "deleted_at": None, "device_id": device_id, "rev": 1}
    if parent == "account":
        return {
            "table": "account",
            "id": id_,
            "columns": {
                "id": id_,
                "ledger_id": ledger_id,
                "name": PLACEHOLDER_ACCOUNT_NAME,
                "type": 1,
                "currency": referrer["columns"].get("currency") or "CNY",
                "opening_balance_minor": 0,
                "credit_limit_minor": None,
                "statement_day": None,
                "due_day": None,
                "repay_account_id": None,
                "icon": None,
                "color": None,
                "is_archived": 1,
                "sort_order": 0,
                "note": "导入占位：文件里引用了本机没有的账户，请合并到真实账户",
                **common,
            },
        }
    return {
        "table": "category",
        "id": id_,
        "columns": {
            "id": id_,
            "ledger_id": ledger_id,
            "parent_id": None,
            "kind": _category_kind_of(referrer),
            "name": placeholder_category_name(id_),
            "icon": None,
            "color": None,
            "is_system": 0,
            "is_hidden": 1,
            "sort_order": 0,
            **common,
        },
    }


def fix_references(records: list, local_rows: dict, device_id: str, at: int) -> dict:
    """`ImportReferenceFixer.apply` 的镜像。"""
    scanned = {f"{child}.{column}" for child, column, _p in REFERENCE_RULES}
    for child, columns in REPAIR_TARGETS.items():
        for column in columns:
            assert f"{child}.{column}" in scanned, f"修复表 {child}.{column} 不在扫描表里"

    exists = _id_index(local_rows, alive_only=False)
    alive = _id_index(local_rows, alive_only=True)
    for record in records:
        exists.setdefault(record["table"], set()).add(record["id"])
        if not record["isTombstone"]:
            alive.setdefault(record["table"], set()).add(record["id"])

    fixes: list[dict] = []
    patched: dict[str, dict] = {}
    placeholders: dict[str, dict] = {}

    parent_of = _parent_links(records, local_rows)
    for record in records:
        if record["type"] != "category":
            continue
        parent_id = record["columns"].get("parent_id")
        if not isinstance(parent_id, str):
            continue
        reason = _parent_broken_reason(
            parent_id, record["id"], parent_of, alive.get("category", set()), exists.get("category", set())
        )
        if reason is not None:
            patched[record["id"]] = {**record, "columns": {**record["columns"], "parent_id": None}}
            fixes.append(
                {
                    "key": "category.parent_id/promote_to_root",
                    "kind": "promote_to_root",
                    "reason": reason,
                    "entity": record["table"],
                    "recordId": record["id"],
                    "column": "parent_id",
                    "referencedId": parent_id,
                    "placeholderName": "",
                }
            )
            continue
        duplicate = _duplicate_name(record, parent_id, local_rows)
        if duplicate is not None:
            fixes.append(
                {
                    "key": "category.name/duplicate_name",
                    "kind": "duplicate_name",
                    "reason": "duplicate_name",
                    "entity": record["table"],
                    "recordId": record["id"],
                    "column": "name",
                    "referencedId": duplicate,
                    "placeholderName": "",
                }
            )

    for record in records:
        targets = REPAIR_TARGETS.get(record["table"])
        if targets is None:
            continue
        for column in sorted(targets):
            parent = targets[column]
            referenced = record["columns"].get(column)
            if not isinstance(referenced, str) or referenced in exists.get(parent, set()):
                continue
            placeholders.setdefault(
                f"{parent}/{referenced}", _placeholder_record(parent, referenced, record, device_id, at)
            )
            is_account = parent == "account"
            fixes.append(
                {
                    "key": f"{record['table']}.{column}/"
                    + ("placeholder_account" if is_account else "placeholder_category"),
                    "kind": "placeholder_account" if is_account else "placeholder_category",
                    "reason": "missing",
                    "entity": record["table"],
                    "recordId": record["id"],
                    "column": column,
                    "referencedId": referenced,
                    "placeholderName": PLACEHOLDER_ACCOUNT_NAME
                    if is_account
                    else placeholder_category_name(referenced),
                }
            )

    fixes.sort(key=lambda f: (f["entity"], f["recordId"], f["column"], f["kind"]))
    return {
        "records": [patched.get(r["id"], r) for r in records],
        "placeholders": [placeholders[k] for k in sorted(placeholders)],
        "fixes": fixes,
    }


# ─────────────────────────── plan 的镜像（§4.4） ───────────────────────────


def apply_ledger_remap(records: list, remap: dict) -> list:
    if not remap:
        return records
    out = []
    for record in records:
        is_ledger = record["type"] == "ledger"
        key = record["id"] if is_ledger else record["columns"].get("ledger_id")
        target = remap.get(key) if isinstance(key, str) else None
        if target is None:
            out.append(record)
            continue
        columns = {**record["columns"], ("id" if is_ledger else "ledger_id"): target}
        out.append({**record, "id": target if is_ledger else record["id"], "columns": columns})
    return out


def conflict_id(job_id: str, entity: str, entity_id: str, kind: int, now_ms: int) -> str:
    digest = hashlib.sha256(f"{job_id}|{entity}|{entity_id}|{kind}".encode("utf-8")).digest()[:10]
    return ulid_encode(normalize_ms(now_ms), digest)


def plan(
    records: list,
    local_rows: dict | None = None,
    mode: str = "merge",
    strategy: str = "abort",
    delete_edit: str = "delete_wins",
    skew_window: int = SKEW_WINDOW_MS,
    job_id: str = JOB,
    now_ms: int = NOW,
    local_device_id: str | None = None,
    ledger_remap: dict | None = None,
    target_ledger_id: str | None = None,
) -> dict:
    """`ImportMergePlanner.plan` 的镜像。返回的内部字典比驱动输出多几个键。"""
    local_rows = local_rows or {}
    local_device_id = local_device_id or DEV_LOCAL
    outcomes = ("insert", "update", "skip", "mark_deleted", "resurrect", "conflict", "insert_tombstone")
    counts = {k: 0 for k in outcomes}

    records = apply_ledger_remap(records, ledger_remap or {})
    placeholders: list = []
    fixes: list = []
    if strategy == "converge":
        fixed = fix_references(records, local_rows, local_device_id, normalize_ms(now_ms))
        records = fixed["records"]
        placeholders = fixed["placeholders"]
        fixes = fixed["fixes"]

    touched = set()
    by_table: dict[str, list] = {}
    for record in records:
        by_table.setdefault(record["table"], []).append(record)
        touched.add(record["table"])

    decisions: list[dict] = []
    for stage in STAGE_ORDER:
        table = TABLE_OF[stage]
        table_records = by_table.get(table)
        if not table_records:
            continue
        table_records = sorted(table_records, key=lambda r: r.get("recordIndex", 0))
        local_by_id = {row["id"]: row for row in local_rows.get(table, []) if isinstance(row.get("id"), str)}
        for record in table_records:
            decision = merge_record(
                record,
                local_by_id.get(record["id"]),
                mode=mode,
                strategy=strategy,
                delete_edit=delete_edit,
                skew_window=skew_window,
            )
            decisions.append(decision)
            counts[decision["outcome"]] += 1

    record_writes = [d["write"] for d in decisions if d["write"] is not None]
    placeholder_writes = [_write(placeholder_as_record(p), False) for p in placeholders]

    # 覆盖模式的待软删清单。
    #
    # 没有目标账本 ⇒ **一条也不软删**：范围不确定时，「少删」的代价是用户发现旧数据
    # 还在，「多删」的代价是他再也找不回来。执行器那一侧同样如此（`_loadLedgerScope`
    # 在 targetLedgerId 为空时返回空集），两层必须同口径，否则「计划说删、执行不删」
    # 会让护栏上的那个条数变成一个谎。
    candidates: list[tuple[str, str]] = []
    if mode == "replace" and target_ledger_id is not None:
        seen = {d["recordId"] for d in decisions}
        for child, column, _parent in REFERENCE_RULES:
            if column != "ledger_id":
                continue
            for row in local_rows.get(child, []):
                id_ = row.get("id")
                if not isinstance(id_, str) or id_ in seen or row.get("deleted_at") is not None:
                    continue
                if row.get("ledger_id") != target_ledger_id:
                    continue
                candidates.append((child, id_))
        candidates.sort()

    removal_writes = []
    for table, id_ in candidates:
        row = next(r for r in local_rows[table] if r["id"] == id_)
        columns = {
            "deleted_at": now_ms,
            "updated_at": now_ms,
            "rev": (row["rev"] if isinstance(row.get("rev"), int) else 1) + 1,
            "device_id": local_device_id,
        }
        removal_writes.append(
            {
                "table": table,
                "id": id_,
                "columns": columns,
                "sql": "UPDATE {} SET {} WHERE id = ?".format(table, ", ".join(f"{c} = ?" for c in columns)),
                "arguments": list(columns.values()) + [id_],
                "replace": True,
            }
        )

    reviewable = [] if strategy == "abort" else [d for d in decisions if d["conflictKind"] is not None]
    conflicts = [
        {
            "entity": d["entityKind"],
            "entityId": d["recordId"],
            "kind": d["conflictKind"],
            "side": d["side"],
            "reason": decision_reason_of(d),
            "localVersionStamp": None if d["localVersion"] is None else d["localVersion"]["versionStamp"],
            "remoteVersionStamp": None if d["remoteVersion"] is None else d["remoteVersion"]["versionStamp"],
        }
        for d in reviewable
    ]

    conflict_writes = []
    for decision, conflict in zip(reviewable, conflicts):
        cid = conflict_id(job_id, conflict["entity"], conflict["entityId"], conflict["kind"], now_ms)
        lv = decision["localVersion"]
        rv = decision["remoteVersion"]
        columns = {
            "id": cid,
            "job_id": job_id,
            "entity": conflict["entity"],
            "entity_id": conflict["entityId"],
            "kind": conflict["kind"],
            "local_json": canon_json(
                {
                    "versionStamp": None if lv is None else lv["versionStamp"],
                    "contentHash": None if lv is None else lv["contentHash"],
                    "deleted": None if lv is None else lv["deleted"],
                }
            ),
            "remote_json": canon_json(
                {"versionStamp": rv["versionStamp"], "contentHash": rv["contentHash"], "deleted": rv["deleted"]}
            ),
            "resolution": None,
            "resolved_at": None,
        }
        conflict_writes.append(
            {
                "table": "conflict",
                "id": cid,
                "columns": columns,
                "sql": "INSERT INTO conflict ({}) VALUES ({})".format(
                    ", ".join(columns), ", ".join("?" for _ in columns)
                ),
                "arguments": list(columns.values()),
                "replace": False,
            }
        )

    # `MergePlan.writes`：按阶段序「先占位、后裁决」，再软删，最后冲突登记
    writes = []
    for stage in STAGE_ORDER:
        table = TABLE_OF[stage]
        writes.extend([w for w in placeholder_writes if w["table"] == table])
        writes.extend([w for w in record_writes if w["table"] == table])
    writes.extend(removal_writes)
    writes.extend(conflict_writes)

    return {
        "mode": mode,
        "writes": writes,
        "counts": counts,
        "insertedCount": sum(1 for w in record_writes if not w["replace"]) + len(placeholder_writes),
        "updatedCount": sum(1 for w in record_writes if w["replace"]),
        "removedCount": len(removal_writes),
        "skippedCount": counts["skip"],
        "conflictCount": len(conflicts),
        "removedCandidates": [id_ for _t, id_ in candidates],
        "requiresCountConfirmation": mode == "replace" and len(candidates) > 0,
        "touchedTables": sorted(touched),
        "conflicts": conflicts,
        "referenceFixes": fixes,
    }


def placeholder_as_record(placeholder: dict) -> dict:
    """占位实体（只有 table / id / columns）伪装成一条可写记录。"""
    return {"table": placeholder["table"], "id": placeholder["id"], "columns": placeholder["columns"]}


def plan_expect(result: dict) -> dict:
    """把内部计划投影成 `import.merge.plan` 驱动的输出（键必须逐字一致）。"""
    return {
        "mode": result["mode"],
        "writes": [pub_write(w) for w in result["writes"]],
        "counts": result["counts"],
        "insertedCount": result["insertedCount"],
        "updatedCount": result["updatedCount"],
        "removedCount": result["removedCount"],
        "skippedCount": result["skippedCount"],
        "conflictCount": result["conflictCount"],
        "removedCandidates": result["removedCandidates"],
        "requiresCountConfirmation": result["requiresCountConfirmation"],
        "touchedTables": result["touchedTables"],
        "conflicts": result["conflicts"],
        "referenceFixes": result["referenceFixes"],
    }


# ─────────────────────────── 假库（与驱动里的模拟器同语义） ───────────────────────────


def sim_apply(state: dict, writes: list) -> dict:
    for write in writes:
        key = f"{write['table']}|{write['id']}"
        if write["replace"]:
            assert key in state, f"对不存在的行 {key} 执行 UPDATE（计划与本地状态不一致）"
            state[key].update(write["columns"])
        else:
            state[key] = dict(write["columns"])
    return state


def sim_state(local_rows: dict) -> dict:
    return {f"{table}|{row['id']}": dict(row) for table, rows in local_rows.items() for row in rows}


def to_local_rows(state: dict) -> dict:
    out: dict[str, list] = {}
    for key, row in state.items():
        table = key.split("|", 1)[0]
        out.setdefault(table, []).append(row)
    for rows in out.values():
        rows.sort(key=lambda r: str(r.get("id")))
    return out


def _token(value) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def tokens(state: dict) -> list:
    return sorted(f"{key}|" + ",".join(f"{c}={_token(row[c])}" for c in sorted(row)) for key, row in state.items())


def lcg_shuffle(items: list, seed: int, out: list | None = None) -> list:
    """与驱动 `_shuffle` 同参数的 Fisher–Yates（因此两边的乱序结果逐项一致）。"""
    out = list(items)
    state = seed & 0x7FFFFFFF
    for i in range(len(out) - 1, 0, -1):
        state = (1103515245 * state + 12345) & 0x7FFFFFFF
        j = state % (i + 1)
        out[i], out[j] = out[j], out[i]
    return out


def stage_order_of(writes: list) -> str:
    """语句序列的阶段序，压成 `a > b > c` —— 与驱动 `_stageOrderOf` 同口径。

    压成字符串而不是留列表：Dart 侧 `List` 的 `==` 是同一性比较，列表对列表
    恒为 false。两侧都落到文本上，这条断言才可能在两边同时为真、也才可能
    同时抓到真问题。
    """
    stages = []
    for write in writes:
        stage = "conflict" if write["table"] == "conflict" else TABLE_STAGE[write["table"]]
        if not stages or stages[-1] != stage:
            stages.append(stage)
    return " > ".join(stages)


TABLE_STAGE = {TABLE_OF[stage]: stage for stage in STAGE_ORDER}

# ─────────────────────────── 用例素材 ───────────────────────────

LG1 = mk_id("ledger-main")
LG2 = mk_id("ledger-other")
LG_SRC = mk_id("ledger-source")
LG_DST = mk_id("ledger-dest")

A1 = mk_id("acct-bank")
A2 = mk_id("acct-cash")
A9 = mk_id("acct-missing")
C1 = mk_id("cat-food")
C2 = mk_id("cat-lunch")
C9 = mk_id("cat-missing")
T1 = mk_id("txn-coffee")
T2 = mk_id("txn-salary")
T4 = mk_id("txn-rent")
T9 = mk_id("txn-hidden")


def ledger_cols(name: str = "日常", code: str = "MAIN01") -> dict:
    return {"name": name, "code": code, "currency": "CNY", "is_default": 1, "sort_order": 0}


def acct_cols(
    name: str = "招行储蓄卡", type_: int = 2, ledger: str = LG1, opening: int = 0, is_archived: int = 0
) -> dict:
    return {
        "ledger_id": ledger,
        "name": name,
        "type": type_,
        "currency": "CNY",
        "opening_balance_minor": opening,
        "is_archived": is_archived,
        "note": None,
    }


def cat_cols(name: str = "餐饮", kind: int = 1, ledger: str = LG1, parent=None, is_hidden: int = 0) -> dict:
    return {"ledger_id": ledger, "parent_id": parent, "kind": kind, "name": name, "is_hidden": is_hidden}


def txn_cols(
    account: str = A1,
    to_account=None,
    category=None,
    type_: int = 1,
    amount: int = 12345,
    ledger: str = LG1,
    note=None,
) -> dict:
    return {
        "ledger_id": ledger,
        "type": type_,
        "amount_minor": amount,
        "currency": "CNY",
        "occurred_at": T_FILE,
        "account_id": account,
        "to_account_id": to_account,
        "category_id": category,
        "note": note,
    }


def budget_cols(category: str = C9, ledger: str = LG1, amount: int = 100000) -> dict:
    return {
        "ledger_id": ledger,
        "period_type": 1,
        "period_key": "2026-09",
        "amount_minor": amount,
        "category_id": category,
    }


def local_row(
    id_: str,
    columns: dict,
    at: int = T_FILE,
    deleted_at=None,
    device: str = DEV_LOCAL,
    rev: int = 3,
    extra: dict | None = None,
) -> dict:
    """一条库中已有行（DB 列，含版本元数据与本地独有列）。"""
    return {
        "id": id_,
        **(extra or {}),
        **columns,
        "created_at": at,
        "updated_at": at,
        "deleted_at": deleted_at,
        "device_id": device,
        "rev": rev,
    }


def case(cid: str, kind: str, title: str, notes: str, tags: list, inp: dict, value: dict) -> dict:
    return {
        "id": cid,
        "kind": kind,
        "title": title,
        "milestone": "M1",
        "input": inp,
        "expect": {"ok": True, "value": value},
        "notes": notes,
        "tags": tags,
    }


def record_case(
    cid: str,
    title: str,
    notes: str,
    tags: list,
    remote: dict,
    local: dict | None,
    mode: str = "merge",
    strategy: str = "converge",
    delete_edit: str = "delete_wins",
    skew: int = SKEW_WINDOW_MS,
) -> dict:
    decision = merge_record(remote, local, mode, strategy, delete_edit, skew)
    return case(
        cid,
        "import.merge.record",
        title,
        notes,
        tags,
        {
            "remote": as_input(remote),
            "local": local,
            "mode": mode,
            "strategy": strategy,
            "deleteEdit": delete_edit,
            "skewWindowMs": skew,
        },
        record_expect(decision),
    )


def plan_case(
    cid: str,
    title: str,
    notes: str,
    tags: list,
    records: list,
    local_rows: dict | None = None,
    **kwargs,
) -> dict:
    inp = {
        "records": [as_input(r) for r in records],
        "localRows": local_rows or {},
        "mode": kwargs.get("mode", "merge"),
        "strategy": kwargs.get("strategy", "abort"),
        "deleteEdit": kwargs.get("delete_edit", "delete_wins"),
        "skewWindowMs": kwargs.get("skew_window", SKEW_WINDOW_MS),
        "jobId": kwargs.get("job_id", JOB),
        "nowMillis": kwargs.get("now_ms", NOW),
        "localDeviceId": kwargs.get("local_device_id", DEV_LOCAL),
    }
    if kwargs.get("ledger_remap"):
        inp["ledgerRemap"] = kwargs["ledger_remap"]
    if kwargs.get("target_ledger_id"):
        inp["targetLedgerId"] = kwargs["target_ledger_id"]
    result = plan(records, local_rows, **kwargs)
    return case(cid, "import.merge.plan", title, notes, tags, inp, plan_expect(result))


def converge_case(
    cid: str,
    title: str,
    notes: str,
    tags: list,
    records: list,
    local_rows: dict | None = None,
    seed: int = 20260921,
    split_after: str | None = None,
    **kwargs,
) -> dict:
    """`import.merge.converge` 的期望值 —— 与驱动逐条同一步骤地推演。"""
    local_rows = local_rows or {}
    mode = kwargs.get("mode", "merge")
    strategy = kwargs.get("strategy", "converge")
    delete_edit = kwargs.get("delete_edit", "delete_wins")
    skew = kwargs.get("skew_window", SKEW_WINDOW_MS)

    def run(batch: list, rows: dict) -> dict:
        return plan(
            [dict(r, recordIndex=i) for i, r in enumerate(batch)],
            rows,
            mode=mode,
            strategy=strategy,
            delete_edit=delete_edit,
            skew_window=skew,
            job_id=JOB,
            now_ms=NOW,
            local_device_id=DEV_LOCAL,
            **{k: v for k, v in kwargs.items() if k in ("ledger_remap", "target_ledger_id")},
        )

    baseline = run(records, local_rows)
    state = sim_apply(sim_state(local_rows), baseline["writes"])
    final_state = tokens(state)

    shuffled = lcg_shuffle(records, seed)
    shuffled_plan = run(shuffled, local_rows)

    second = run(records, to_local_rows(state))

    value = {
        "baselineWrites": [pub_write(w) for w in baseline["writes"]],
        "baselineCounts": baseline["counts"],
        "shuffledCountsEqual": shuffled_plan["counts"] == baseline["counts"],
        "shuffledWritesMultisetEqual": sorted(
            f"{w['sql']}|{canon_json(w['arguments'])}" for w in shuffled_plan["writes"]
        )
        == sorted(f"{w['sql']}|{canon_json(w['arguments'])}" for w in baseline["writes"]),
        "shuffledStageOrderPreserved": stage_order_of(shuffled_plan["writes"])
        == stage_order_of(baseline["writes"]),
        "baselineStageOrder": stage_order_of(baseline["writes"]),
        "shuffledStageOrder": stage_order_of(shuffled_plan["writes"]),
        "secondPassWrites": len(second["writes"]),
        "secondPassCounts": second["counts"],
        "finalState": final_state,
    }
    if split_after is not None:
        boundary = STAGE_ORDER.index(split_after)
        first = [r for r in records if STAGE_ORDER.index(TABLE_STAGE[r["table"]]) <= boundary]
        second_batch = [r for r in records if STAGE_ORDER.index(TABLE_STAGE[r["table"]]) > boundary]
        split_state = sim_state(local_rows)
        for batch in (first, second_batch):
            if not batch:
                continue
            result = run(batch, to_local_rows(split_state))
            sim_apply(split_state, result["writes"])
        value["splitFinalStateEqual"] = tokens(split_state) == final_state
        value["splitFinalState"] = tokens(split_state)

    inp = {
        "records": [as_input(r) for r in records],
        "localRows": local_rows,
        "mode": mode,
        "strategy": strategy,
        "deleteEdit": delete_edit,
        "skewWindowMs": skew,
        "jobId": JOB,
        "nowMillis": NOW,
        "localDeviceId": DEV_LOCAL,
        "shuffleSeed": seed,
    }
    if split_after is not None:
        inp["splitAfterStage"] = split_after
    return case(cid, "import.merge.converge", title, notes, tags, inp, value)


def reference_case(
    cid: str, title: str, notes: str, tags: list, records: list, local_rows: dict | None = None
) -> dict:
    result = fix_references(records, local_rows or {}, DEV_LOCAL, normalize_ms(NOW))
    value = {
        "placeholders": [
            {"table": p["table"], "id": p["id"], "columns": p["columns"]} for p in result["placeholders"]
        ],
        "fixes": result["fixes"],
        "normalized": [
            {"table": r["table"], "id": r["id"], "parentId": r["columns"].get("parent_id")}
            for r in result["records"]
        ],
    }
    inp = {
        "records": [as_input(r) for r in records],
        "localRows": local_rows or {},
        "nowMillis": NOW,
        "localDeviceId": DEV_LOCAL,
    }
    return case(cid, "import.merge.reference", title, notes, tags, inp, value)


# ─────────────────────────── 43 条用例 ───────────────────────────


def build_cases() -> list:
    cases: list = []

    # ═══ import.merge.record（20）—— §4.4 的裁决表逐格 ═══
    acct_new = rec("account", A1, T_NEW, acct_cols())
    acct_base = rec("account", A1, T_FILE, acct_cols())
    acct_tomb = rec("account", A1, T_NEW, {**acct_cols(), "deleted_at": T_NEW})
    local_identical = local_row(A1, acct_cols(), at=T_FILE)
    local_edited = local_row(A1, acct_cols(name="现金"), at=T_FILE)
    local_edited_newer = local_row(A1, acct_cols(name="现金"), at=T_NEW)
    local_tomb_older = local_row(A1, acct_cols(name="现金"), at=T_FILE, deleted_at=T_FILE)
    local_tomb_newer = local_row(A1, acct_cols(name="现金"), at=T_NEW, deleted_at=T_NEW)

    cases.append(
        record_case(
            "import.merge.record.local-missing-insert",
            "本地没有这条 id ⇒ insert（新数据一律进得来）",
            "「中止」策略拦的是**改动本地已有行**，不是新增。把新增也拦下，等于让用户在"
            "「先导入一次新账本」这一步就卡住 —— 而这一步没有任何东西可被破坏。",
            ["convergence"],
            acct_base,
            None,
        )
    )
    cases.append(
        record_case(
            "import.merge.record.local-missing-tombstone",
            "本地没有、文件带来墓碑 ⇒ insertTombstone（把删除也写下来）",
            "只跳过墓碑而不记录它，会让「已删除」这件事在下次导入时被复活：文件里那条记录"
            "在别的设备上还是活的，本机什么都没记，下一份文件一进来就又插回去了。",
            ["convergence"],
            acct_tomb,
            None,
        )
    )
    cases.append(
        record_case(
            "import.merge.record.identical-content-skip",
            "业务列逐字相同、只有版本元数据不同 ⇒ skip（幂等就落在这里）",
            "若先比版本戳，「同一份备份导入两次」会变成一次 update —— 无后端同步里最危险的"
            "一类假动作：数据没变，但每导入一次就产生一批新版本戳，永不收敛。",
            ["convergence"],
            acct_new,
            local_identical,
        )
    )
    cases.append(
        record_case(
            "import.merge.record.remote-newer-update",
            "双方都活、远端更新且差超过 60s ⇒ update / remote_newer",
            "最普通的一路。它同时是「宽限窗口」的对照面：只有差得足够远，才敢说谁更新。",
            ["convergence"],
            acct_new,
            local_edited,
        )
    )
    cases.append(
        record_case(
            "import.merge.record.local-newer-skip",
            "双方都活、本地更新 ⇒ skip / local_newer（保本地）",
            "反向的那一半。没有它，「总取远端」也能让上面那条用例全绿。",
            ["convergence"],
            acct_base,
            local_edited_newer,
        )
    )
    cases.append(
        record_case(
            "import.merge.record.skew-window-conflict",
            "差 30 秒且内容不同 ⇒ conflict / ambiguous_window（取值仍确定：远端胜）",
            "两台设备的时钟差几秒完全正常，此时「谁更新」没有语义上的强弱。"
            "若静默 LWW，用户会看到自己的修改被另一台设备上更早的修改覆盖，且没有任何提示。",
            ["convergence", "ux"],
            rec("account", A1, T_NEAR, acct_cols()),
            local_edited,
        )
    )
    cases.append(
        record_case(
            "import.merge.record.stamp-collision-conflict",
            "版本戳相同、内容不同 ⇒ conflict / stamp_collision",
            "正常流程不可能产生（同设备同毫秒的两次写入会单调递增）。出现即说明版本戳生成"
            "被破坏或数据被外部改过；悄悄选一个会让这类损坏永久隐身。",
            ["convergence", "security"],
            acct_base,
            local_row(A1, acct_cols(name="现金"), at=T_FILE, device=DEV_FILE),
        )
    )
    cases.append(
        record_case(
            "import.merge.record.tombstone-wins-mark-deleted",
            "远端墓碑更新、本地是活着的编辑 ⇒ markDeleted / tombstone_wins",
            "删除在别处发生过，就必须在本机生效。若让「本地还活着」赢，用户会看到一条"
            "自己在另一台设备上已经删掉的记录又冒出来。",
            ["convergence"],
            acct_tomb,
            local_edited,
        )
    )
    cases.append(
        record_case(
            "import.merge.record.stale-edit-loses-to-tombstone",
            "本地墓碑更新、远端是更早的编辑 ⇒ skip / tombstone_wins（迟到的编辑不得复活）",
            "这是「绝不静默复活」的第一半：编辑比墓碑更早 ⇒ 墓碑胜，且连待复核都不记"
            "（删掉就是删掉了，没有什么要用户确认的）。",
            ["convergence"],
            acct_base,
            local_tomb_newer,
        )
    )
    cases.append(
        record_case(
            "import.merge.record.late-edit-conflict",
            "本地墓碑较早、远端编辑较晚 ⇒ conflict / delete_vs_edit（取值取编辑，但必须复核）",
            "「绝不静默复活」的第二半：复活可以发生，但不能悄无声息。取值仍按版本戳确定"
            "（编辑晚），因此收敛性不受影响 —— 有影响的是「打不打扰用户」。",
            ["convergence", "ux"],
            acct_new,
            local_tomb_older,
        )
    )
    cases.append(
        record_case(
            "import.merge.record.late-edit-resurrect-lww",
            "同一分歧改用 editWinsByLww ⇒ resurrect（且不记复核）",
            "§4.4 策略表的另一行。它是七态里 `resurrect` 唯一的出口 —— 默认策略下它不可达，"
            "这条用例就是那个「不可达」的反证。",
            ["convergence"],
            acct_new,
            local_tomb_older,
            delete_edit="edit_wins_by_lww",
        )
    )
    cases.append(
        record_case(
            "import.merge.record.zero-timestamp-normalized",
            "本地 updated_at 为负数（时钟从未校准）⇒ 归一为最旧，远端胜出",
            "坏时间戳必须被归一而不是被丢弃，也不能直接进合成公式（负数会让 ULID 编码抛错 ——"
            "一条坏记录就能炸掉整次导入）。归一之后它作为「最旧的那一条」参与裁决。",
            ["boundary"],
            acct_base,
            local_row(A1, acct_cols(name="现金"), at=-5),
        )
    )
    cases.append(
        record_case(
            "import.merge.record.abort-insert-passes",
            "abort 策略 + 本地没有这条 id ⇒ 照样 insert",
            "「中止」不是「什么都不做」，而是「不改动已有数据」。把新增一起拦掉会让"
            "首次导入（空库）无法完成 —— 那是本策略最容易被误伤的场景。",
            ["convergence"],
            acct_base,
            None,
            strategy="abort",
        )
    )
    cases.append(
        record_case(
            "import.merge.record.abort-content-divergence",
            "abort 策略 + 同 id 内容不同 ⇒ conflict / abort_on_divergence（且不写）",
            "这是提交 A 的全部行为，也是本引擎的缺省：没人显式要求裁决之前，引擎不擅自改"
            "用户已有的数据。它同时被 A 的 `import.apply.conflict-deferred` 在编排层锁死。",
            ["convergence"],
            acct_new,
            local_edited,
            strategy="abort",
        )
    )
    cases.append(
        record_case(
            "import.merge.record.abort-delete-vs-edit",
            "abort 策略 + 一边删除一边编辑 ⇒ conflict，且 kind 记 2",
            "冲突的种类决定用户在面板里看到什么、能做什么（「保留我改的」vs「按删除处理」）。"
            "把两种冲突记成同一种，用户就没有可依据的动作。",
            ["convergence", "ux"],
            acct_tomb,
            local_edited,
            strategy="abort",
        )
    )
    cases.append(
        record_case(
            "import.merge.record.abort-identical-skip",
            "abort 策略 + 内容相同 ⇒ skip（中止策略也要先认幂等）",
            "若 ``abort`` 只看「本地已存在」就中止，重复导入同一份备份会次次报冲突 ——"
            "而用户重试导入正是最常见的操作。",
            ["convergence"],
            acct_new,
            local_identical,
            strategy="abort",
        )
    )
    cases.append(
        record_case(
            "import.merge.record.replace-existing-update",
            "replace 模式 + 本地已存在 ⇒ update / overwrite_by_file（不做版本比较）",
            "覆盖模式的语义是「以文件为准」，因此它**刻意不比版本**：用户说的就是要这一份。"
            "一旦这里插入版本比较，覆盖模式就会在「文件更旧」时悄悄变成合并。",
            ["convergence"],
            acct_base,
            local_edited_newer,
            mode="replace",
        )
    )
    cases.append(
        record_case(
            "import.merge.record.replace-missing-tombstone-reinsert",
            "replace 模式 + 本地没有、文件是墓碑 ⇒ insertTombstone",
            "覆盖模式同样要记录墓碑：否则「文件里已删除、本机从没见过的记录」会在下一次"
            "同步时以活着的形态回来。",
            ["convergence"],
            acct_tomb,
            None,
            mode="replace",
        )
    )
    cases.append(
        record_case(
            "import.merge.record.supplement-existing-skip",
            "supplement_only + 本地已存在 ⇒ skip（绝不修改已有记录，含墓碑）",
            "「仅补充」的全部意义就是「只加不减不改」。任何一处漏判都会让用户精心挑选的"
            "补充导入变成一次静默覆盖。",
            ["convergence"],
            acct_new,
            local_edited,
            mode="supplement_only",
        )
    )
    cases.append(
        record_case(
            "import.merge.record.supplement-missing-insert",
            "supplement_only + 本地没有 ⇒ insert / fill_only_new",
            "同上，另一半：只加不减，不改 —— 加是它的职责。",
            ["convergence"],
            acct_base,
            None,
            mode="supplement_only",
        )
    )

    # ═══ import.merge.plan（9）—— 写什么、按什么顺序写 ═══

    txn_update = rec("txn", T1, T_NEW, txn_cols(amount=20000))
    txn_skip = rec("txn", T1, T_FILE, txn_cols(amount=12345))
    txn_tomb = rec("txn", T2, T_NEW, {**txn_cols(amount=500000, type_=2), "deleted_at": T_NEW})
    ledger_new = rec("ledger", LG1, T_FILE, ledger_cols())
    account_new = rec("account", A2, T_FILE, acct_cols(name="现金", type_=1, opening=500000))

    mixed_records = [ledger_new, account_new, txn_update, txn_tomb]
    mixed_local = {
        "account": [
            local_row(
                A2,
                acct_cols(name="现金", type_=1, opening=500000),
                extra={"cached_balance_minor": 500000, "balance_as_of": 0, "source_import_job": None},
            )
        ],
        "txn": [local_row(T1, txn_cols(amount=12345)), local_row(T2, txn_cols(amount=500000, type_=2))],
    }
    cases.append(
        plan_case(
            "import.merge.plan.merge-batch-mixed",
            "一批四条的完整计划：语句序列按阶段序、七态各归各位",
            "这是「写什么、按什么顺序写」的总纲。语句顺序不是风格问题：`foreign_keys = ON` 之下，"
            "父实体（ledger）必须先于子实体（account / txn），否则整批失败并回滚 ——"
            "而失败的表现是「导入报错」，排查方向会被引到数据上。"
            "本地行里刻意带了 `cached_balance_minor` / `source_import_job` 这些"
            "「导出不带、本地才有」的列：它们不进内容指纹，否则任何一条 account 行都会永远判成"
            "「内容不同」，于是重复导入变成一次冲突弹窗。",
            ["convergence", "format"],
            mixed_records,
            mixed_local,
            strategy="converge",
        )
    )
    cases.append(
        plan_case(
            "import.merge.plan.abort-conflict-stops-before-write",
            "abort 策略下计划里仍有新增、但没有一条冲突登记",
            "计划是**预演**：它照常算出「本可以插哪几条」，而中止由执行器在备份之前拦下"
            "（见 A 的 `import.apply.conflict-deferred`）。中止时不登记 `conflict` 行是有意的："
            "那条记录会指向一个 status=failed 的 job，用户在冲突面板里永远处理不掉它。",
            ["convergence"],
            [account_new, rec("txn", T1, T_NEW, txn_cols(amount=20000))],
            {"txn": [local_row(T1, txn_cols(amount=12345))]},
            strategy="abort",
        )
    )
    replace_local = {
        "account": [
            local_row(A1, acct_cols(), extra={"cached_balance_minor": 0}),
            local_row(A9, acct_cols(name="旧卡")),
        ],
        "category": [local_row(C1, cat_cols(), rev=5)],
        "txn": [local_row(T9, txn_cols(ledger=LG2))],
    }
    cases.append(
        plan_case(
            "import.merge.plan.replace-removal-candidates",
            "覆盖模式：目标账本内「文件没提到」的本地行进待软删清单，别的账本一条不动",
            "跨账本误删是这一块最严重的可能事故：用户只想用一份账本的文件覆盖那个账本，"
            "而清单里混进了另一个账本的行。软删清单必须由调用方展示、按条数确认后才执行"
            "（`requiresCountConfirmation` 就是那个闸门）。",
            ["boundary", "ux"],
            [rec("account", A1, T_FILE, acct_cols()), rec("txn", T1, T_FILE, txn_cols())],
            replace_local,
            mode="replace",
            strategy="converge",
            target_ledger_id=LG1,
        )
    )
    cases.append(
        plan_case(
            "import.merge.plan.replace-without-target-ledger-no-removal",
            "覆盖模式但没有目标账本 ⇒ 一条也不软删（失败方向指向「少删」）",
            "范围不确定时，「少删」的代价是用户发现旧数据还在，「多删」的代价是他再也找不回来。"
            "两者不对称，所以缺省必须是不删 —— 而不是「把整个库都当成覆盖范围」。",
            ["boundary"],
            [rec("account", A1, T_FILE, acct_cols()), rec("txn", T1, T_FILE, txn_cols())],
            replace_local,
            mode="replace",
            strategy="converge",
        )
    )
    cases.append(
        plan_case(
            "import.merge.plan.supplement-only-inserts-only",
            "仅补充：本地已有的跳过、没有的插入，一句 UPDATE 都没有",
            "「绝不修改已有记录」是模式契约。计划里出现任何一条 UPDATE 都说明模式串了 ——"
            "这种错误在人工比对时极难发现（条数对得上，内容不对）。",
            ["convergence"],
            [rec("account", A1, T_NEW, acct_cols()), account_new],
            {"account": [local_row(A1, acct_cols(name="现金"))]},
            mode="supplement_only",
            strategy="converge",
        )
    )
    cases.append(
        plan_case(
            "import.merge.plan.placeholder-before-referrer",
            "缺失父实体 ⇒ 占位实体排在被引用记录之前，且落回它自己的阶段位",
            "顺序错一步就是整批回滚：`txn.account_id` 指向的 account 行必须已经写入。"
            "注意占位**不是**简单前置到队首，而是插在它所处阶段的位置上（account 阶段 /"
            "category 阶段各归各位），否则「父实体先于子实体」这条链在不同表之间会串。",
            ["convergence"],
            [
                rec("txn", T1, T_FILE, txn_cols(account=A9, category=C9)),
                account_new,
            ],
            None,
            strategy="converge",
        )
    )
    remap_local = {
        "account": [local_row(A1, acct_cols(ledger=LG_DST), extra={"cached_balance_minor": 0})],
    }
    cases.append(
        plan_case(
            "import.merge.plan.ledger-remap-before-decision",
            "账本映射发生在裁决之前 ⇒ 重映射后同内容的那条被认成 skip",
            "`ledger_id` 是内容的一部分（它进内容指纹）。若先把记录按旧账本判成 update、"
            "再按新账本写进去，这一行的**字面值**与它的**判决依据**就来自两个不同的世界 ——"
            "结果看起来对，但下次导入会再判一次，永远收敛不到 skip。",
            ["convergence"],
            [rec("account", A1, T_NEW, acct_cols(ledger=LG_SRC))],
            remap_local,
            strategy="converge",
            ledger_remap={LG_SRC: LG_DST},
        )
    )
    cases.append(
        plan_case(
            "import.merge.plan.conflict-row-deterministic",
            "冲突登记：主键由 (job, 实体, id, 种类) 派生，两侧版本写进 json 列",
            "主键派生而不是随机生成：同一次导入里的同一处冲突不可能产生两行。随机 id 会让"
            "「一条分歧被记了两次」变成靠概率保证的事 —— 而用户会以为自己有两条要处理。"
            "`resolution` 留 NULL：自动收敛只是为了收敛性，不代表已经替用户做了决定。",
            ["convergence", "security"],
            [rec("txn", T1, T_NEW, txn_cols(amount=20000))],
            {"txn": [local_row(T1, txn_cols(amount=12345), at=T_NEAR)]},
            strategy="converge",
        )
    )
    cases.append(
        plan_case(
            "import.merge.plan.empty-file-empty-plan",
            "空记录集 ⇒ 空计划（不写、不计数、不碰任何表）",
            "「文件里一条记录都没有」是合法输入（用户可能只导出了附件）。"
            "若计划里凭空出现语句（例如无条件软删），一份空文件就能清空用户的库。",
            ["boundary"],
            [],
            None,
            strategy="converge",
        )
    )

    # ═══ import.merge.converge（6）—— 可交换 / 幂等 / 可结合 ═══

    batch_records = [
        ledger_new,
        account_new,
        rec("account", A1, T_FILE, acct_cols(name="招行储蓄卡·改")),
        txn_skip,
        txn_tomb,
    ]
    batch_local = {
        "account": [
            local_row(
                A1,
                acct_cols(),
                extra={"cached_balance_minor": 0, "source_import_job": None},
            )
        ],
        "txn": [local_row(T2, txn_cols(amount=500000, type_=2))],
    }
    cases.append(
        converge_case(
            "import.merge.converge.batch-order-independent",
            "行序打乱后写入集合与阶段序都不变（可交换）",
            "文件里的行序是导出方的实现细节，不该影响合并结果。若某条写入依赖「谁先被处理」，"
            "两台设备拿到的同一份文件会得到不同的库 —— 而用户永远看不出差别在哪。",
            ["convergence"],
            batch_records,
            batch_local,
        )
    )
    cases.append(
        converge_case(
            "import.merge.converge.tombstone-and-edit-order-independent",
            "含「一边删除一边编辑」的分歧时，乱序仍然收敛（且冲突登记逐字相同）",
            "冲突是最容易被实现成「停下来等用户」的地方，而那会立刻破坏收敛性。"
            "这里要证明的是：**冲突不影响收敛** —— 取值照旧确定，只是多一条待复核。",
            ["convergence"],
            [account_new, txn_tomb, rec("txn", T2, T_FILE, txn_cols(amount=500000, type_=2))],
            {
                "account": [local_row(A1, acct_cols(name="现金"))],
                "txn": [local_row(T2, txn_cols(amount=500000, type_=2), at=T_FILE)],
            },
        )
    )
    cases.append(
        converge_case(
            "import.merge.converge.second-import-is-noop",
            "本地已是「导入之后」的状态 ⇒ 计划里一条写入都没有（幂等）",
            "用户重试导入是常态（网络中断、误操作）。若第二次导入产生任何写入，"
            "「同一份备份导入两次结果不变」就不成立 —— 反复重试会不断推高版本戳，"
            "让所有设备都以为有新改动。",
            ["convergence"],
            [account_new, rec("account", A1, T_NEW, acct_cols()), txn_skip],
            {
                "account": [
                    local_row(A2, acct_cols(name="现金", type_=1, opening=500000)),
                    local_row(A1, acct_cols(), at=T_NEW),
                ],
                "txn": [local_row(T1, txn_cols(amount=12345), at=T_FILE)],
            },
        )
    )
    cases.append(
        converge_case(
            "import.merge.converge.skew-conflict-still-converges",
            "宽限窗口内的分歧：乱序仍收敛，且第二次导入不再产生写入",
            "冲突路径最危险的失败模式是「每次导入都再冲突一次」：用户看见的是一份永远处理不完"
            "的待办。这里连着锁两件事：乱序不影响结果，以及冲突写完之后第二遍是 no-op。",
            ["convergence", "ux"],
            [rec("account", A1, T_NEAR, acct_cols(name="招行储蓄卡·改")), account_new],
            {"account": [local_row(A1, acct_cols())]},
        )
    )
    cases.append(
        converge_case(
            "import.merge.converge.split-import-after-account",
            "把文件按「account 之后」切成两批依次导入 ⇒ 最终状态与一次导入完全相同（可结合）",
            "「分两次导入一份文件」是真实场景（先导账本与账户，隔天再导交易）。"
            "若两次导入的结果与一次导入不同，用户得到的库就取决于他当时的操作顺序 ——"
            "这是无后端同步里最难排查的一类不一致。",
            ["convergence"],
            batch_records,
            batch_local,
            split_after="account",
        )
    )
    cases.append(
        converge_case(
            "import.merge.converge.split-import-after-ledger",
            "把文件按「ledger 之后」切成两批 ⇒ 最终状态同样与一次导入完全相同",
            "批界换一个位置再验一次。只验一个批界的话，实现里那条「第一批先跑」的假设可能"
            "恰好只在那个位置成立。",
            ["convergence"],
            batch_records,
            batch_local,
            split_after="ledger",
        )
    )

    # ═══ import.merge.reference（8）—— §4.4 S11–S14 ═══

    cases.append(
        reference_case(
            "import.merge.reference.placeholder-account",
            "S11：txn.account_id 指向本地没有的账户 ⇒ 造占位账户（保留 id、置 is_archived）",
            "一份**部分导出**的文件里，交易可以提着本地没有的账户：那笔交易在这次导出范围内，"
            "账户属于上次导出的范围。这不是「文件坏了」，而是「文件只讲了一半的故事」——"
            "整体回滚会让用户永远导不进这份文件，而凭空丢下这笔交易等于丢数据。",
            ["convergence", "ux"],
            [rec("txn", T1, T_FILE, txn_cols(account=A9))],
        )
    )
    cases.append(
        reference_case(
            "import.merge.reference.placeholder-account-dedup",
            "同一个缺失账户被两条记录引用 ⇒ 只造一个占位；不同 id 各造一个",
            "同一 id 造两个占位是一次主键冲突，会让整批回滚 —— 一次「修复」把整次导入炸掉，"
            "而失败信息只会说「UNIQUE constraint failed」。",
            ["convergence"],
            [
                rec("txn", T1, T_FILE, txn_cols(account=A9, to_account=A9, type_=3)),
                rec("account", A2, T_FILE, {**acct_cols(name="现金"), "repay_account_id": A9}),
            ],
        )
    )
    cases.append(
        reference_case(
            "import.merge.reference.placeholder-category-out",
            "S12：支出交易引用缺失分类 ⇒ 占位分类 kind=1，名字带 id 后缀",
            "名字必须带 id 后缀：`ux_category_name` 是 `(ledger_id, kind, parent, name)` 上的唯一索引。"
            "两个占位分类都叫「（来自其他设备）」就是一次 UNIQUE 冲突 —— 又是「修复把导入炸掉」。",
            ["convergence"],
            [rec("txn", T1, T_FILE, txn_cols(category=C9, type_=1))],
        )
    )
    cases.append(
        reference_case(
            "import.merge.reference.placeholder-category-in",
            "S12：收入交易引用缺失分类 ⇒ 占位分类 kind 跟交易方向走（2）",
            "分类的方向（支出/收入）错了，用户合并到真实分类时要先改方向 —— 而方向字段没有"
            "界面入口。能推出来的信息不该丢。",
            ["convergence", "ux"],
            [rec("txn", T2, T_FILE, txn_cols(category=C9, type_=2, amount=500000))],
        )
    )
    cases.append(
        reference_case(
            "import.merge.reference.placeholder-budget-category",
            "S12：预算引用缺失分类 ⇒ 占位分类 kind=1（预算没有方向字段，取支出）",
            "猜不出来时取支出：支出是绝大多数场景，且猜错方向不会损坏数据 ——"
            "用户合并到真实分类时会一并修正。反过来「因为猜不准所以不修」会让预算永远悬空。",
            ["convergence"],
            [rec("budget", mk_id("budget-food"), T_FILE, budget_cols())],
        )
    )
    cases.append(
        reference_case(
            "import.merge.reference.placeholder-repay-account",
            "S11：account.repay_account_id 指向缺失账户 ⇒ 同样造占位账户",
            "还款账户是账户自己的引用。漏掉这一条的后果不是报错，而是账户列表里那张卡"
            "「还款账户」一栏空着 —— 用户只能自己回忆当年绑的是哪张卡。",
            ["convergence"],
            [rec("account", A1, T_FILE, {**acct_cols(), "repay_account_id": A9})],
        )
    )
    cases.append(
        reference_case(
            "import.merge.reference.promote-parent-deleted-and-missing",
            "S14：父分类被删 ⇒ 升级为一级（deleted）；父分类从没存在过 ⇒ 同样升级（missing）",
            "「被删」与「从没存在过」要分开报：前者用户能去归档里找回来，后者说明这份文件"
            "本来就不完整。而处置相同（升级为一级）—— 子分类挂在不可达的父下，在界面里"
            "就是彻底看不见，那比挂在根上更糟。",
            ["convergence", "ux"],
            [
                rec("category", C2, T_FILE, cat_cols(name="午饭", parent=C1)),
                rec("category", mk_id("cat-orphan"), T_FILE, cat_cols(name="孤儿", parent=mk_id("cat-never"))),
            ],
            {"category": [local_row(C1, cat_cols(), deleted_at=T_NEAR)]},
        )
    )
    deep = [mk_id(f"cat-deep-{i}") for i in range(10)]
    cases.append(
        reference_case(
            "import.merge.reference.parent-cycle-self-and-too-deep",
            "环 / 自指 / 超过 8 层 ⇒ 一律升级为一级（cycle / too_deep），一级分类原样保留",
            "构造出来的 parent 链不该让修复变成一次无界遍历（超深的那条同时是遍历的边界）。"
            "而**一级分类必须原样保留**：修复器若只处理「有父」的那些记录、又忘了把「没有父」的"
            "还回去，表现就是「导入之后少了几个分类」—— 用户要过很久才会发现。",
            ["boundary", "convergence"],
            [
                rec("category", deep[0], T_FILE, cat_cols(name="根分类", parent=None)),
                *[
                    rec("category", deep[i], T_FILE, cat_cols(name=f"第 {i} 层", parent=deep[i - 1]))
                    for i in range(1, 10)
                ],
                rec("category", mk_id("cat-cycle-a"), T_FILE, cat_cols(name="环 A", parent=mk_id("cat-cycle-b"))),
                rec("category", mk_id("cat-cycle-b"), T_FILE, cat_cols(name="环 B", parent=mk_id("cat-cycle-a"))),
                rec("category", mk_id("cat-self"), T_FILE, cat_cols(name="自指", parent=mk_id("cat-self"))),
                rec("category", mk_id("cat-child-ok"), T_FILE, cat_cols(name="正常的子分类", parent=deep[0])),
            ],
        )
    )

    return cases


# ─────────────────────────── 自检 / 产出 ───────────────────────────


def self_check() -> None:
    """三个基础件对齐已发布的向量；对不上直接退出，不写文件。

    这里守的是「我的地基和别人的地基是同一块」。ULID 编码与 JSON 口径
    一旦漂移，成百条期望值会一起漂移，而且漂移得很像「实现有 bug」。
    """
    for ms, random_hex, expected in ULID_ANCHORS:
        got = ulid_encode(ms, bytes.fromhex(random_hex))
        if got != expected:
            raise SystemExit(f"ULID 锚点失配：ms={ms} random={random_hex}\n  期望 {expected}\n  实得 {got}")
    # JSON 口径：无空格、键序保持、非 ASCII 原样（Dart jsonEncode 同口径）。
    if canon_json({"b": 1, "a": "中"}) != '{"b":1,"a":"中"}':
        raise SystemExit("规范化 JSON 失配（Dart jsonEncode 同口径）")


SUITE = "import_conflict"

TITLE = "导入器 B：裁决 / 计划 / 收敛性 / 引用修复（§4.4）"

DESCRIPTION = (
    "四个 kind 对应 §4.4 冲突处置的四层可独立判定的性质：单条记录怎么裁决（七态）、"
    "一批记录怎么落库（语句序 / 计数 / 待软删 / 冲突登记）、同一批记录换个顺序或拆两次导入"
    "结果是否一致（可交换 / 幂等 / 可结合）、以及引用指向缺失时怎么补。"
    "期望值由 tools/golden_vectors_gen/import_conflict.py 按 §4.4 独立实现算出（Python 侧零共享 Dart 代码），"
    "脚本开头把 ULID 编码与 JSON 口径对齐到已发布的 ulid.json —— 那两条是锚点，不是主张。"
)


def suite_payload(cases: list) -> dict:
    return {
        "schemaVersion": 1,
        "suite": SUITE,
        "title": TITLE,
        "description": DESCRIPTION,
        "cases": cases,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="§4.4 导入期裁决 / 计划 / 收敛 / 引用修复的黄金向量生成器")
    parser.add_argument("--write", action="store_true", help="写入 test_vectors/v1/import_conflict.json")
    parser.add_argument("--check", action="store_true", help="只用磁盘文件重算比对，不写盘")
    args = parser.parse_args()

    self_check()
    cases = build_cases()
    payload = suite_payload(cases)

    ids = [c["id"] for c in cases]
    if len(ids) != len(set(ids)):
        dupes = sorted({i for i in ids if ids.count(i) > 1})
        print(f"用例 id 重复：{dupes}", file=sys.stderr)
        return 1

    if args.check:
        if not VECTOR_PATH.exists():
            print(f"missing {VECTOR_PATH}", file=sys.stderr)
            return 1
        if json.loads(VECTOR_PATH.read_text(encoding="utf-8")) != payload:
            print(f"MISMATCH {VECTOR_PATH.name}", file=sys.stderr)
            return 1
        print(f"checked {VECTOR_PATH.name}（{len(cases)} 条）")
        return 0

    if args.write:
        VECTOR_PATH.parent.mkdir(parents=True, exist_ok=True)
        # newline="\n" 不能省：本机是 Windows，默认文本模式会把 "\n" 翻成 CRLF，
        # 而 .gitattributes 里 `*.json text eol=lf` 让索引存 LF —— 结果是
        # 工作区 CRLF / 索引 LF，`git status` 一直显示「已修改」而 `git diff` 是空的。
        # .gitattributes 的注释把这条列为「生成脚本自己的责任」，与 import_samples.py 同口径。
        VECTOR_PATH.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
            newline="\n",
        )
        print(f"wrote {VECTOR_PATH}（{len(cases)} 条）")
        return 0

    kinds: dict[str, int] = {}
    for c in cases:
        kinds[c["kind"]] = kinds.get(c["kind"], 0) + 1
    print(f"[dry] 共 {len(cases)} 条用例（未写文件；--write 落盘）")
    for kind, count in sorted(kinds.items()):
        print(f"  {kind:26s} {count} 条")
    return 0


if __name__ == "__main__":
    sys.exit(main())


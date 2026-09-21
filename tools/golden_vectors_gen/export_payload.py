#!/usr/bin/env python3
"""导出载荷（NDJSON）黄金向量的生成器 —— 独立参考实现。

## 为什么需要独立实现

`export_payload` 套件锁的是**载荷 NDJSON 的字节**：行序、manifest 的
contentHash 注入位置、end 行字段。期望值若由 Dart 自己算，就是「实现算出
什么就接受什么」。本脚本用 Python 标准库（json / hashlib）独立编出载荷，
与 Dart 侧 `pf_io/src/export_payload.dart` 是两套实现。

JSON 序列化的字节确定性：Dart `jsonEncode` 与 Python
`json.dumps(separators=(",",":"), ensure_ascii=False)` 对「紧凑分隔符、
非 ASCII 原样输出、控制字符转义」的规则一致；测试语料避开两类实现
有分歧的码点（U+2028/2029、 lone surrogate），键序由构造顺序钉死。

## 覆盖范围

- export_payload.full：8 个阶段各 1 条记录（行序 = 父实体先行）+
  manifest 注入 payloadVersion / contentHash + end 行
- export_payload.incremental：增量 manifest（changeLogRange / sinceExportAt）
  只含 txn 阶段
- export_payload.empty：零记录载荷（contentHash = SHA256(空)）

用法：

    python export_payload.py            # 打印 JSON 到标准输出
    python export_payload.py --write    # 写入 test_vectors/v1/
    python export_payload.py --check    # 只做核对，不输出向量
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

VECTOR_DIR = Path(__file__).resolve().parents[2] / "test_vectors" / "v1"

STAGE_ORDER = ["ledger", "account", "category", "tag", "theme", "txn", "budget", "attachment"]
PAYLOAD_VERSION = 1

# 记录行的判别键（§4.1）。在载荷里独占：业务列 `account.type` / `txn.type`
# 在载荷层改名为 accountType / txnType（2026-09-21 裁决）。
DISCRIMINATOR = "type"


def dumps_line(line: dict) -> bytes:
    return (json.dumps(line, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")


def encode(manifest: dict, stages: dict[str, list[dict]], generated_at: int) -> dict:
    """独立实现 §3.2 编码：manifest → 记录行 → end。"""
    assert manifest[DISCRIMINATOR] == "manifest"
    assert "contentHash" not in manifest and "payloadVersion" not in manifest

    record_bytes = bytearray()
    record_count = 0
    for stage in STAGE_ORDER:  # 行序由 STAGE_ORDER 决定，与传入键序无关
        for fields in stages.get(stage, []):
            # 判别键独占（2026-09-21 裁决）。`{"type": stage, **fields}` 里
            # fields 写在后面，一旦它自带 "type" 就会把判别键**静默抹掉** ——
            # 这正是 account / txn 曾经在真实导出里失型的原因。这里断言拦住，
            # 业务列在载荷层的键是 accountType / txnType。
            assert DISCRIMINATOR not in fields, (
                f"阶段 {stage} 的记录字段含判别键 {DISCRIMINATOR!r}："
                "业务列请在载荷层改名（accountType / txnType）"
            )
            record_bytes += dumps_line({DISCRIMINATOR: stage, **fields})
            record_count += 1
    content_hash = hashlib.sha256(bytes(record_bytes)).hexdigest()

    out = bytearray()
    out += dumps_line({**manifest, "payloadVersion": PAYLOAD_VERSION, "contentHash": f"sha256:{content_hash}"})
    out += record_bytes
    out += dumps_line({
        DISCRIMINATOR: "end",
        "recordCount": record_count,
        "contentHash": f"sha256:{content_hash}",
        "generatedAt": generated_at,
    })

    # 自检：解析回去，首行 manifest、末行 end；记录行重序列化后哈希一致
    # （contentHash 只覆盖记录行 —— manifest 携带它、end 引用它，均不在覆盖内）。
    lines = [json.loads(x) for x in bytes(out).decode("utf-8").splitlines()]
    assert lines[0][DISCRIMINATOR] == "manifest" and lines[-1][DISCRIMINATOR] == "end"
    # 每一条记录行的判别键都必须是已知阶段名。
    # 这是 account/txn 撞名事故的回归闸：业务字段一旦覆盖判别键，
    # 该行的 type 会变成整数 1..5，这一句立刻失败。
    assert all(x[DISCRIMINATOR] in STAGE_ORDER for x in lines[1:-1]), (
        "记录行的判别键被覆盖了："
        f"{[x[DISCRIMINATOR] for x in lines[1:-1] if x[DISCRIMINATOR] not in STAGE_ORDER]}"
    )
    assert lines[-1]["recordCount"] == record_count
    record_re = b"".join(dumps_line(x) for x in lines[1:-1])
    assert record_re == bytes(record_bytes)
    assert hashlib.sha256(record_re).hexdigest() == content_hash
    return {
        "ndjsonHex": bytes(out).hex(),
        "recordCount": record_count,
        "contentHashHex": content_hash,
    }


def case(case_id: str, title: str, manifest: dict, stages: dict, generated_at: int,
         notes: str, tags: list[str]) -> dict:
    return {
        "id": case_id,
        "kind": "export.payload.ndjson",
        "title": title,
        "milestone": "M1",
        "input": {"manifest": manifest, "stages": stages, "generatedAt": generated_at},
        "expect": {"ok": True, "value": encode(manifest, stages, generated_at)},
        "notes": notes,
        "tags": tags,
    }


def build_suite() -> dict:
    manifest_full = {
        "type": "manifest",
        "appVersion": "1.0.0",
        "deviceId": "01J8Z9K2M4P6Q8R0T2V4X6Z8B1",
        "deviceName": "向量生成器",
        "platform": "android",
        "exportedAt": 1757922436789,
        "exportKind": "full",
        "includesAttachments": False,
        "counts": {"ledger": 1, "account": 1, "category": 1, "txn": 1, "budget": 1, "tag": 1, "theme": 1, "attachment": 1},
    }
    stages_full = {
        "ledger": [{"id": "01J8TESTLEDGER0000000000001", "name": "日常", "code": "MAIN01", "currency": "CNY", "isDefault": 1, "sortOrder": 0, "createdAt": 1757922436789, "updatedAt": 1757922436789, "deletedAt": None, "deviceId": "01J8Z9K2M4P6Q8R0T2V4X6Z8B1", "rev": 1}],
        "account": [{"id": "01J8TESTACCNT00000000000001", "ledgerId": "01J8TESTLEDGER0000000000001", "name": "招行储蓄卡", "accountType": 2, "currency": "CNY", "openingBalanceMinor": 0, "cachedBalanceMinor": 1284500, "balanceAsOf": 1757900000000, "creditLimitMinor": None, "statementDay": None, "dueDay": None, "repayAccountId": None, "icon": "card", "color": "#3B82F6", "isArchived": 0, "sortOrder": 1, "note": None, "createdAt": 1, "updatedAt": 1, "deletedAt": None, "deviceId": "01J8Z9K2M4P6Q8R0T2V4X6Z8B1", "rev": 1}],
        "category": [{"id": "01J8TESTCATEG0000000000001", "ledgerId": "01J8TESTLEDGER0000000000001", "parentId": None, "kind": 1, "name": "餐饮", "icon": "restaurant", "color": "#F97316", "isSystem": 1, "isHidden": 0, "sortOrder": 10, "createdAt": 1, "updatedAt": 1, "deletedAt": None, "deviceId": "01J8Z9K2M4P6Q8R0T2V4X6Z8B1", "rev": 1}],
        "tag": [{"id": "01J8TESTTAG000000000000001", "ledgerId": "01J8TESTLEDGER0000000000001", "name": "出差", "color": "#8B5CF6", "createdAt": 1, "updatedAt": 1, "deletedAt": None, "deviceId": "01J8Z9K2M4P6Q8R0T2V4X6Z8B1", "rev": 1}],
        "theme": [{"id": "01J8TESTTHEME0000000000001", "name": "我的配色", "specJson": {"primary": "#3B82F6"}, "isActive": 1, "createdAt": 1, "updatedAt": 1, "deletedAt": None, "deviceId": "01J8Z9K2M4P6Q8R0T2V4X6Z8B1", "rev": 1}],
        "txn": [{"id": "01J8TESTTXN00000000000001", "ledgerId": "01J8TESTLEDGER0000000000001", "txnType": 1, "amountMinor": 3800, "currency": "CNY", "occurredAt": 1757900000000, "dayKey": "2026-09-15", "monthKey": "2026-09", "tzOffsetMin": 480, "accountId": "01J8TESTACCNT00000000000001", "toAccountId": None, "categoryId": "01J8TESTCATEG0000000000001", "merchant": "星巴克", "note": "拿铁", "tags": ["01J8TESTTAG000000000000001"], "feeMinor": 0, "isReimbursable": 0, "excludedFromStats": 0, "createdAt": 1, "updatedAt": 1, "deletedAt": None, "deviceId": "01J8Z9K2M4P6Q8R0T2V4X6Z8B1", "originDeviceId": "01J8Z9K2M4P6Q8R0T2V4X6Z8B1", "rev": 1}],
        "budget": [{"id": "01J8TESTBUDGT0000000000001", "ledgerId": "01J8TESTLEDGER0000000000001", "periodType": 1, "periodKey": "2026-09", "scope": 2, "categoryId": "01J8TESTCATEG0000000000001", "amountMinor": 150000, "currency": "CNY", "rollover": 0, "alertBp": 8000, "createdAt": 1, "updatedAt": 1, "deletedAt": None, "deviceId": "01J8Z9K2M4P6Q8R0T2V4X6Z8B1", "rev": 1}],
        "attachment": [],
    }
    manifest_incremental = {
        "type": "manifest",
        "appVersion": "1.0.0",
        "deviceId": "01J8Z9K2M4P6Q8R0T2V4X6Z8B1",
        "deviceName": "向量生成器",
        "platform": "ios",
        "exportedAt": 1757922500000,
        "exportKind": "incremental",
        "sinceExportAt": 1757000000000,
        "changeLogRange": {"minSeq": 120, "maxSeq": 456},
        "includesAttachments": False,
        "counts": {"txn": 1},
    }
    stages_incremental = {
        "txn": [{"id": "01J8TESTTXN00000000000002", "ledgerId": "01J8TESTLEDGER0000000000001", "txnType": 2, "amountMinor": 9900, "currency": "CNY", "occurredAt": 1757920000000, "dayKey": "2026-09-15", "monthKey": "2026-09", "tzOffsetMin": 480, "accountId": "01J8TESTACCNT00000000000001", "toAccountId": None, "categoryId": None, "merchant": None, "note": None, "tags": [], "feeMinor": 0, "isReimbursable": 0, "excludedFromStats": 0, "createdAt": 1757920000000, "updatedAt": 1757920000000, "deletedAt": None, "deviceId": "01J8Z9K2M4P6Q8R0T2V4X6Z8B1", "originDeviceId": "01J8Z9K2M4P6Q8R0T2V4X6Z8B1", "rev": 3}],
    }

    return {
        "schemaVersion": 1,
        "suite": "export_payload",
        "title": "导出载荷 NDJSON（§3.2 / §4.2 3.3–3.5）",
        "description": "行序（父实体先行）、manifest 的 payloadVersion / contentHash 注入、"
                       "end 行字段全部被 Python 独立实现的字节级快照锁死；"
                       "contentHash 覆盖全部非 manifest 行，是导入端载荷完整性的裁决依据。",
        "cases": [
            case(
                "export.payload.ndjson.full",
                "full 导出：8 阶段行序 + manifest 注入 + end 行",
                manifest_full,
                stages_full,
                1757922437000,
                "行序是导入正确性的前提（txn 引用的 account 必须先导入）；contentHash "
                "把全部非 manifest 行钉进一个摘要，行序或字节漂移都会被导入端拒绝。",
                ["format", "security"],
            ),
            case(
                "export.payload.ndjson.incremental",
                "增量导出：scope 专属 manifest 字段 + 单阶段",
                manifest_incremental,
                stages_incremental,
                1757922500000,
                "增量导出携带 changeLogRange / sinceExportAt，三设备场景下增量链"
                "依赖这些字段与原始 deviceId —— 缺失或漂移会让后续增量永久漏记录。",
                ["format", "security"],
            ),
            case(
                "export.payload.ndjson.empty",
                "零记录载荷：contentHash = SHA256(空串)",
                {**manifest_full, "exportedAt": 1757922436790, "counts": {}},
                {},
                1757922437001,
                "空载荷是合法输入（空账本导出），其 contentHash 必须等于空串摘要 "
                "e3b0c442…—— 若实现走「无记录就不算哈希」的捷径，这里立刻变红。",
                ["format"],
            ),
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="写入 test_vectors/v1/")
    parser.add_argument("--check", action="store_true", help="只核对已写入的文件")
    args = parser.parse_args()
    if args.write and args.check:
        print("--write 与 --check 互斥", file=sys.stderr)
        return 2

    suite = build_suite()
    if args.write:
        path = VECTOR_DIR / "export_payload.json"
        # 显式写 LF（`newline="\n"`）：`Path.write_text` 的默认行为在 Windows 上把
        # `\n` 翻译成 `\r\n`，而 `.gitattributes` 把 `*.json` 规范化成 LF 入库 ——
        # 结果是工作区副本 CRLF、索引 LF，`git status` 永远显示「已修改」而
        # `git diff` 是空的。`.gitattributes` 里那段注释点名的就是这个坑。
        path.write_text(
            json.dumps(suite, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
            newline="\n",
        )
        print(f"wrote {path} ({len(suite['cases'])} cases)")
    elif args.check:
        path = VECTOR_DIR / "export_payload.json"
        if not path.exists():
            print(f"missing {path}", file=sys.stderr)
            return 1
        existing = json.loads(path.read_text(encoding="utf-8"))
        if existing != suite:
            print(f"MISMATCH {path.name}", file=sys.stderr)
            return 1
        print(f"checked {path.name} ({len(suite['cases'])} cases)")
    else:
        print(json.dumps(suite, ensure_ascii=False, indent=2))
    print(f"total {len(suite['cases'])} cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())

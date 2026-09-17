#!/usr/bin/env python3
"""SQLCipher 打开流程的黄金向量生成器（方案 §3.4）。

覆盖的 kind（对应 packages/pf_testkit/lib/src/drivers/m2_db.dart）：
  - db.open.plan       打开前/后的有序 PRAGMA 脚本（含 iOS 明文头变体、密钥长度错误）
  - db.open.classify   SQLite 打开期错误的分类（NOTADB 双分支 / 损坏 / 一般失败）

期望值的独立来源：**规格 §3.4 原文的人工转录**（与 AES 的 NIST 锚点同理 ——
来源是文档而非实现）。Python 侧按 §3.4 的表格逐条写出语句序列，
Dart 侧 PfSqlitePragma.openSetup / postOpen / classifySqliteOpenError 独立产出，
两者在向量比对处会合。任何一侧改动顺序、数值或措辞都会红。

用法：
  python db_open.py            # 自检 + 打印，不写文件
  python db_open.py --write    # 写入 ../../test_vectors/v1/db_open.json（LF 行尾）
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# ---- 固定测试输入（全部写死，保证向量可复现） ----

DEK_HEX = "303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f"  # 0x30..0x4f
DEK_TOO_SHORT_HEX = DEK_HEX[:-2]  # 31 字节

IOS_PLAINTEXT_HEADER_BYTES = 32  # §3.4 iOS 特例，推荐值
CIPHER_COMPATIBILITY = 4  # §3.4 ②
CIPHER_PAGE_SIZE = 4096  # §3.4 ③


def setup_statements(dek_hex: str, plaintext_header_bytes: int) -> list[str]:
    """§3.4 ①–⑤，人工转录。顺序不可换；iOS 明文头必须在 key 之前。"""
    statements: list[str] = []
    if plaintext_header_bytes > 0:
        statements.append(f"PRAGMA cipher_plaintext_header_size = {plaintext_header_bytes}")
    statements.append(f'PRAGMA key = "x\'{dek_hex}\'"')
    statements.append(f"PRAGMA cipher_compatibility = {CIPHER_COMPATIBILITY}")
    statements.append(f"PRAGMA cipher_page_size = {CIPHER_PAGE_SIZE}")
    statements.append("PRAGMA cipher_memory_security = ON")
    statements.append("PRAGMA foreign_keys = ON")
    return statements


def post_open_statements() -> list[str]:
    """§3.4 ⑦（+ M0 增补 trusted_schema=OFF），人工转录。"""
    return [
        "PRAGMA journal_mode = WAL",
        "PRAGMA synchronous = NORMAL",
        "PRAGMA busy_timeout = 5000",
        "PRAGMA temp_store = MEMORY",
        "PRAGMA secure_delete = ON",
        "PRAGMA trusted_schema = OFF",
    ]


def self_check() -> None:
    """生成器自检：转录结果必须与 §3.4 伪码逐行对得上。"""
    setup = setup_statements(DEK_HEX, 0)
    assert len(setup) == 5, "默认平台 setup 应为 5 条"
    assert setup[0].startswith('PRAGMA key = "x\''), "key 必须是第一条"
    assert 'x\'' in setup[0] and setup[0].endswith(DEK_HEX + "'\""), "原始密钥模式"

    ios = setup_statements(DEK_HEX, IOS_PLAINTEXT_HEADER_BYTES)
    assert len(ios) == 6 and ios[0] == "PRAGMA cipher_plaintext_header_size = 32", (
        "iOS 明文头必须是第一条、且在 key 之前"
    )

    post = post_open_statements()
    assert post[0] == "PRAGMA journal_mode = WAL", "WAL 必须先行"
    assert "PRAGMA temp_store = MEMORY" in post, "temp_store=MEMORY 是最重要的泄漏防线"


def build_cases() -> list[dict]:
    cases: list[dict] = []

    # ---- db.open.plan ----
    for header_bytes, ref, title, note in [
        (0, "default", "默认平台（Android/桌面）的完整打开脚本", "完全加密头：头 16 字节魔数也在密文里。"),
        (
            IOS_PLAINTEXT_HEADER_BYTES,
            "ios-plaintext-header",
            "iOS 变体：32 字节明文头声明必须在 key 之前",
            "§3.4 iOS 特例：NSFileProtection / 文件协调要读文件头。声明值建库时定死，之后不可更改。",
        ),
    ]:
        cases.append(
            {
                "id": f"db.open.plan.{ref}",
                "kind": "db.open.plan",
                "title": title,
                "milestone": "M1",
                "input": {"dekHex": DEK_HEX, "plaintextHeaderBytes": header_bytes},
                "expect": {
                    "ok": True,
                    "value": {
                        "setupStatements": setup_statements(DEK_HEX, header_bytes),
                        "postOpenStatements": post_open_statements(),
                    },
                },
                "notes": note,
                "tags": ["db", "security"],
            }
        )

    cases.append(
        {
            "id": "db.open.plan.dek-too-short",
            "kind": "db.open.plan",
            "title": "密钥 31 字节 ⇒ 拒绝构造脚本",
            "milestone": "M1",
            "input": {"dekHex": DEK_TOO_SHORT_HEX, "plaintextHeaderBytes": 0},
            "expect": {"ok": False, "errorCode": "PFC_E_VALIDATION"},
            "notes": "原始密钥模式要求恰好 32 字节；长度不对宁可立刻失败，不能生成一段会被 SQLCipher 静默 KDF 的口令。",
            "tags": ["db", "error"],
        }
    )

    # ---- db.open.classify ----
    classify_cases = [
        (
            "notadb-password",
            "file is not a database",
            26,
            False,
            "PFK_E_WRONG_PASSWORD",
            "§3.4 原文路径：NOTADB ⇒ 密码错（加密层无法区分密码错与库被换）。",
        ),
        (
            "notadb-after-keycheck",
            "file is not a database",
            26,
            True,
            "PFD_E_OPEN",
            "keyCheck 已过、密钥已证明正确 ⇒ NOTADB 只能是库文件损坏或被替换，按库损坏处理。",
        ),
        (
            "malformed",
            "database disk image is malformed",
            11,
            True,
            "PFD_E_OPEN",
            "明确的损坏信号（含 WAL 损坏）——无论密钥状态如何都按库损坏。",
        ),
        (
            "io-error",
            "unable to open database file",
            14,
            False,
            "PFD_E_OPEN",
            "一般打开期失败（磁盘/权限/锁）不往密码错上猜：密码错只有 NOTADB 一种表现。",
        ),
    ]
    for ref, message, code, key_verified, error_code, note in classify_cases:
        cases.append(
            {
                "id": f"db.open.classify.{ref}",
                "kind": "db.open.classify",
                "title": f"{message!r}（code={code}，keyCheck{'已' if key_verified else '未'}过）⇒ {error_code}",
                "milestone": "M1",
                "input": {
                    "message": message,
                    "resultCode": code,
                    "keyVerifiedViaKeyCheck": key_verified,
                },
                "expect": {"ok": False, "errorCode": error_code},
                "notes": note,
                "tags": ["db", "error"],
            }
        )

    return cases


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="写入向量文件（LF 行尾）")
    args = parser.parse_args()

    self_check()
    cases = build_cases()

    suite = {
        "schemaVersion": 1,
        "suite": "db_open",
        "title": "SQLCipher 打开流程",
        "description": (
            "锁死 §3.4 打开脚本的顺序与内容（key → cipher 参数 → 安全 PRAGMA、iOS 明文头变体）"
            "以及打开期错误的分类（NOTADB 双分支）。"
            "期望值由规格原文人工转录，与 Dart 侧 PfSqlitePragma / classifySqliteOpenError 独立会合。"
        ),
        "cases": cases,
    }
    text = json.dumps(suite, ensure_ascii=False, indent=2) + "\n"

    if not args.write:
        print(f"[dry] {len(cases)} 条用例（未写文件，--write 落盘）")
        return

    out = Path("test_vectors/v1/db_open.json")
    out.write_bytes(text.encode("utf-8"))
    print(f"[ok] 写入 {out}（{len(cases)} 条用例）")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Argon2id 黄金向量的生成器 —— 独立参考实现。

## 为什么这个脚本必须用另一套实现

`packages/pf_testkit/bin/vector_forge.dart` 做的是相反的事：它用**本仓实现**
跑一遍向量、把实际输出落盘供人对照，并且显式拒绝写入 `test_vectors/`。
理由是让实现给自己出考卷，等于取消考试。

本脚本是它的对偶：期望值来自 Python 的 `argon2-cffi`（libargon2 的绑定，
与 Dart 侧 `package:cryptography` 的 `DartArgon2id` 是**两套完全独立的实现**），
在**独立进程、独立检查**下生成。

## 三层核对

1. **自检（本脚本内）**：argon2-cffi 必须对同一输入产出确定且定长的结果。
   这一步只证明「绑定没接错」。
2. **主生成**：用 argon2-cffi 算出全部成功用例的期望值。
3. **第二套实现（可选）**：环境里若装了纯 Python 的 `argon2pure`，再用它
   独立复算全部成功用例。装不上不算失败（只打印提示）。

## 关于 RFC 9106 §5.3 锚点（重要）

RFC 9106 §5.3 的锚点向量（pwd=0x01×32 / salt=0x02×16 / **secret=0x03×8 /
AD=0x04×12**，期望 tag `0d640df5…e659`）**不在本脚本里**：argon2-cffi 25.x 的
`hash_secret_raw` 签名是
`(secret, salt, time_cost, memory_cost, parallelism, hash_len, type, version)`
——**没有 secret(K) / associated_data(AD) 参数**，无法复现该锚点。

因此该锚点改由 **Dart 侧单测** 用 `DartArgon2id` 直接验证
（见 `packages/pf_crypto/test/argon2id_test.dart`）。证据链是闭合的：

    RFC 9106 §5.3  ──(Dart 单测)──▶  DartArgon2id 正确
    argon2-cffi 值 ──(向量运行器)──▶  Argon2idDeriver(DartArgon2id) 复现
    ⟹ argon2-cffi 在本项目契约路径（空 K / 空 AD）上与 RFC 一致

## 覆盖范围

成功用例：§3.2 三档（P_DEFAULT / P_STRONG / P_MIN）+ 盐长度边界（8 / 32 字节）。
失败用例：m / t / p 各自超上限（含「构造文件声明 16 GiB 内存」的 OOM 攻击场景）
→ `PFB_E_KDF_PARAMS`；密码为空、盐长度与头不符 → `PFB_E_HEADER_INVALID`。

用法：

    python tools/golden_vectors_gen/argon2id.py            # 打印 JSON 到标准输出
    python tools/golden_vectors_gen/argon2id.py --write    # 写入 test_vectors/v1/
    python tools/golden_vectors_gen/argon2id.py --check    # 只做核对，不输出向量

退出码：0 全部一致；1 核对失败；2 用法错误。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from argon2.low_level import Type, hash_secret_raw

# ---------------------------------------------------------------------------
# 固定输入（全部确定、无随机、无时钟）
# ---------------------------------------------------------------------------
PASSWORD = "correct horse battery staple"      # 密码按 UTF-8 编码后参与派生
PW_UTF8 = PASSWORD.encode("utf-8")
PW_HEX = PW_UTF8.hex()

SALT_16 = b"pfwalletsalt0123"                   # 16 字节（默认盐长）
SALT_8 = bytes(range(0x10, 0x18))               # 16..23，8 字节（minSaltLength 边界）
SALT_32 = bytes(range(0x20))                    # 00..1f，32 字节（非默认盐长）

VERSION = 19                                    # 0x13，RFC 9106

# ---------------------------------------------------------------------------
# §3.2 三档（与 packages/pf_crypto/lib/src/argon2_params.dart 对齐）
# ---------------------------------------------------------------------------
P_DEFAULT = dict(m=65536, t=3, p=1, saltLength=16, outputLength=32)   # 64 MiB
P_STRONG = dict(m=262144, t=4, p=4, saltLength=16, outputLength=32)   # 256 MiB
P_MIN = dict(m=19456, t=2, p=1, saltLength=16, outputLength=32)       # 19 MiB


def hx(b: bytes) -> str:
    return b.hex()


# ---------------------------------------------------------------------------
# 主实现：argon2-cffi（底层 libargon2 绑定，无 K / AD）
# ---------------------------------------------------------------------------
def kdf(password: bytes, salt: bytes, params: dict) -> bytes:
    return hash_secret_raw(
        secret=password,
        salt=salt,
        time_cost=params["t"],
        memory_cost=params["m"],
        parallelism=params["p"],
        hash_len=params["outputLength"],
        type=Type.ID,
        version=VERSION,
    )


# ---------------------------------------------------------------------------
# 第二套实现：argon2pure（可选，纯 Python）
# ---------------------------------------------------------------------------
def _argon2pure():
    try:
        import argon2pure  # type: ignore

        return argon2pure
    except Exception:  # pragma: no cover - 可选依赖
        return None


def pure_kdf(password: bytes, salt: bytes, params: dict) -> bytes:
    """argon2pure.argon2(...) —— 参数名与 argon2-cffi 不同，需显式转接。"""
    ap = _argon2pure()
    assert ap is not None
    return bytes(
        ap.argon2(
            password,
            salt,
            time_cost=params["t"],
            memory_cost=params["m"],
            parallelism=params["p"],
            tag_length=params["outputLength"],
            type=ap.Argon2id,
        )
    )


def _params_json(p: dict) -> dict:
    return {"m": p["m"], "t": p["t"], "p": p["p"],
            "saltLength": p["saltLength"], "outputLength": p["outputLength"]}


def _ok_case(case_id: str, title: str, params: dict, salt: bytes, tag: bytes,
             note: str, tags: list[str]) -> dict:
    assert len(tag) == params["outputLength"], "输出长度与参数不符"
    return {
        "id": case_id,
        "kind": "kdf.argon2id.derive",
        "title": title,
        "milestone": "M1",
        "input": {"passwordUtf8Hex": PW_HEX, "saltHex": hx(salt), "params": _params_json(params)},
        "expect": {"ok": True, "value": {"derivedKeyHex": hx(tag)}},
        "notes": note,
        "tags": tags,
    }


def _err_case(case_id: str, title: str, params: dict, salt: bytes, password_hex: str,
              error_code: str, note: str, tags: list[str]) -> dict:
    return {
        "id": case_id,
        "kind": "kdf.argon2id.derive",
        "title": title,
        "milestone": "M1",
        "input": {"passwordUtf8Hex": password_hex, "saltHex": hx(salt), "params": _params_json(params)},
        "expect": {"ok": False, "errorCode": error_code},
        "notes": note,
        "tags": tags,
    }


def build_cases() -> tuple[list[dict], dict[str, tuple[dict, bytes, bytes | None]]]:
    """返回 (用例列表, {ref: (params, salt, 期望值 bytes 或 None)})，第二个供 Layer-3 复用。"""
    cases: list[dict] = []
    computed: dict[str, tuple[dict, bytes, bytes | None]] = {}

    # ---- 成功：§3.2 三档 ----
    tiers = [
        ("preset-default", "§3.2 P_DEFAULT（64 MiB / t=3 / p=1）—— 移动端与导出的默认档", P_DEFAULT,
         "锁定默认档参数。改这个数字等于改所有用户的解锁耗时与安全性，必须显式改向量。",
         ["crypto", "preset"]),
        ("preset-strong", "§3.2 P_STRONG（256 MiB / t=4 / p=4）—— 桌面端加强档", P_STRONG,
         "锁定加强档。p=4 会把多核打满，锁住它防止有人「顺手」把移动端也调上来。",
         ["crypto", "preset"]),
        ("preset-min", "§3.2 P_MIN（19 MiB / t=2 / p=1）—— 允许下限（OWASP 建议）", P_MIN,
         "锁定允许下限。低于它 validate 直接拒绝，因此这档本身必须能算出来。",
         ["crypto", "preset", "boundary"]),
    ]
    for ref, title, params, note, tags in tiers:
        tag = kdf(PW_UTF8, SALT_16, params)
        cases.append(_ok_case(f"kdf.argon2id.derive.{ref}", title, params, SALT_16, tag, note, tags))
        computed[ref] = (params, SALT_16, tag)

    # ---- 成功：盐长度边界 ----
    salt8_params = dict(P_DEFAULT, saltLength=8)
    tag8 = kdf(PW_UTF8, SALT_8, salt8_params)
    cases.append(_ok_case(
        "kdf.argon2id.derive.salt-8-byte", "盐长度下限 8 字节（minSaltLength）",
        salt8_params, SALT_8, tag8,
        "守盐长度下限：8 字节是 Argon2 规范允许的最小盐。salt.length 必须与 params.saltLength 一致。",
        ["crypto", "boundary"]))
    computed["salt-8-byte"] = (salt8_params, SALT_8, tag8)

    salt32_params = dict(P_DEFAULT, saltLength=32)
    tag32 = kdf(PW_UTF8, SALT_32, salt32_params)
    cases.append(_ok_case(
        "kdf.argon2id.derive.salt-32-byte", "非默认盐长 32 字节",
        salt32_params, SALT_32, tag32,
        "守「盐长不等于 16 也要正确」：salt 长度由头里的 saltLength 决定，不是写死的 16。",
        ["crypto", "boundary"]))
    computed["salt-32-byte"] = (salt32_params, SALT_32, tag32)

    # ---- 失败：参数超上限（PFB_E_KDF_PARAMS）----
    m_over = dict(P_DEFAULT, m=16777216)  # 16 GiB
    cases.append(_err_case(
        "kdf.argon2id.derive.params.memory-over-limit",
        "内存参数超上限（构造文件声明 16 GiB）", m_over, SALT_16, PW_HEX,
        "PFB_E_KDF_PARAMS",
        "这是 OOM 攻击场景：文件头声明 m=16 GiB，受害设备打开瞬间就会被榨干内存。"
        "必须在解析头时就拒绝，不能等到派生。",
        ["crypto", "security", "boundary"]))
    computed["memory-over-limit"] = (m_over, SALT_16, None)

    t_over = dict(P_DEFAULT, t=17)
    cases.append(_err_case(
        "kdf.argon2id.derive.params.iterations-over-limit", "迭代次数超上限（t=17）",
        t_over, SALT_16, PW_HEX, "PFB_E_KDF_PARAMS",
        "迭代次数直接乘在耗时上：t=17 会把一次解锁拖到几十秒。上限必须卡死。",
        ["crypto", "security", "boundary"]))
    computed["iterations-over-limit"] = (t_over, SALT_16, None)

    p_over = dict(P_DEFAULT, p=9)
    cases.append(_err_case(
        "kdf.argon2id.derive.params.parallelism-over-limit", "并行度超上限（p=9）",
        p_over, SALT_16, PW_HEX, "PFB_E_KDF_PARAMS",
        "并行度上限 8：p 过大在多核上会把设备打满、触发降频，耗时不可预测。",
        ["crypto", "security", "boundary"]))
    computed["parallelism-over-limit"] = (p_over, SALT_16, None)

    # ---- 失败：输入契约（PFB_E_HEADER_INVALID）----
    cases.append(_err_case(
        "kdf.argon2id.derive.password-empty", "密码为空 ⇒ 输入契约破坏",
        P_DEFAULT, SALT_16, "", "PFB_E_HEADER_INVALID",
        "空密码不是「密码错」，而是调用方没按契约传输入。用 headerInvalid（PFB_E_HEADER_INVALID）"
        "而非 authFailed，调用方才能把「输入非法」与「密码不对」分开提示。",
        ["crypto", "contract", "boundary"]))
    computed["password-empty"] = (P_DEFAULT, SALT_16, None)

    cases.append(_err_case(
        "kdf.argon2id.derive.salt-length-mismatch",
        "盐长度与头声明的 saltLength 不符（头说 16、实际给 8）",
        P_DEFAULT, SALT_8, PW_HEX, "PFB_E_HEADER_INVALID",
        "盐长度是文件头承诺的契约。调用方传的盐必须与之一致，否则属于调用错误而非密码错误。",
        ["crypto", "contract", "boundary"]))
    computed["salt-length-mismatch"] = (P_DEFAULT, SALT_8, None)

    return cases, computed


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true", help="写入 test_vectors/v1/argon2id.json")
    ap.add_argument("--check", action="store_true", help="只做核对，不输出向量")
    args = ap.parse_args()

    # ---- Layer 1：自检（确定性 + 定长）----
    a = kdf(PW_UTF8, SALT_16, P_DEFAULT)
    b = kdf(PW_UTF8, SALT_16, P_DEFAULT)
    if a != b or len(a) != 32:
        print("[FAIL] argon2-cffi 自检失败：非确定或输出长度不对", file=sys.stderr)
        return 1
    print("[ok] argon2-cffi 自检通过（确定且 32 字节定长）")

    cases, computed = build_cases()

    # ---- Layer 3（可选）：argon2pure 交叉核对全部成功用例 ----
    ap_mod = _argon2pure()
    if ap_mod is not None:
        checked = 0
        for ref, (params, salt, expected) in computed.items():
            if expected is None:
                continue
            if pure_kdf(PW_UTF8, salt, params) != expected:
                print(f"[FAIL] argon2pure 与 argon2-cffi 不一致：{ref}", file=sys.stderr)
                return 1
            checked += 1
        print(f"[ok] argon2pure 交叉核对 {checked} 条成功用例一致")
    else:
        print("[skip] 未安装 argon2pure，跳过第二套实现交叉核对（Layer 3 可选）")

    suite = {
        "schemaVersion": 1,
        "suite": "argon2id",
        "title": "Argon2id 黄金测试向量",
        "description": (
            "Argon2id（RFC 9106，version 0x13）的密钥派生向量，输出固定 32 字节。\n"
            "期望值由 Python argon2-cffi（libargon2 绑定）独立复算，与 Dart 侧 "
            "package:cryptography 的 DartArgon2id 是两套独立实现。\n"
            "RFC 9106 §5.3 的带 K/AD 锚点不在本文件（argon2-cffi 无 K/AD 参数），"
            "由 packages/pf_crypto/test/argon2id_test.dart 用 DartArgon2id 直接验证。\n"
            "覆盖 §3.2 三档（P_DEFAULT/P_STRONG/P_MIN）、盐长度边界（8/32 字节）、"
            "以及 m/t/p 超上限（PFB_E_KDF_PARAMS）与输入契约破坏（密码空 / 盐长不符 → PFB_E_HEADER_INVALID）。"
        ),
        "cases": cases,
    }

    if args.check:
        print(f"[ok] 共 {len(cases)} 条用例，自检与交叉核对通过")
        return 0

    text = json.dumps(suite, indent=2, ensure_ascii=False) + "\n"
    if args.write:
        out = Path("test_vectors/v1/argon2id.json")
        out.write_bytes(text.encode("utf-8"))  # 显式 LF，避免 Windows CRLF
        print(f"[ok] 写入 {out}（{len(cases)} 条用例）")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

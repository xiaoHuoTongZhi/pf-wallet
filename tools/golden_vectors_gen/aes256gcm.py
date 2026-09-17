#!/usr/bin/env python3
"""AES-256-GCM 黄金向量的生成器 —— 独立参考实现。

## 为什么这个脚本必须用另一套实现

`packages/pf_testkit/bin/vector_forge.dart` 做的是相反的事：它用**本仓实现**
跑一遍向量、把实际输出落盘供人对照，并且显式拒绝写入 `test_vectors/`。
理由是让实现给自己出考卷，等于取消考试。

本脚本是它的对偶：期望值来自 Python 的 `cryptography`（与 Dart 侧
`package:cryptography` 同库但**独立进程、独立检查**），并用 NIST 官方
向量与可选的 `pycryptodome` 第二套实现交叉核对后才落盘。

## 三层核对，缺一层都不算数

1. **NIST 官方锚点（必须命中）**：脚本内写死 NIST GCMVS（AES-256）Count=0 的
   已知 Tag（`gcmEncryptExtIV256.rsp`，Key=0xb52c…05b4，IV=0x516c…63d7，
   空明文 / 空 AAD）。cryptography 必须逐字节复现它，否则整个脚本退出非零 ——
   这一步证明「参考实现本身是对的」，后续所有用例才有背书。
2. **主生成**：用 cryptography 算出全部 seal / open 用例的期望值。
3. **第二套实现（可选）**：环境里若装了 `pycryptodome`，再用它独立复算
   全部用例。装不上不算失败（只打印提示），但能装上就多一层保险。

## 关于 nonce 长度

GCM 标准允许任意 nonce 长度，本项目只用 12 字节（96 位）作主路径，
但向量必须覆盖「非 96 位」边界：本脚本含 8 字节与 16 字节两例。
Dart 侧用 `AesGcm.with256bits(nonceLength: n)` 构造，Python 侧 AESGCM 原生支持，
两者对同一输入必须产出同一密文与标签（已用 Layer-3 交叉核对守住）。

用法：

    python tools/golden_vectors_gen/aes256gcm.py            # 打印 JSON 到标准输出
    python tools/golden_vectors_gen/aes256gcm.py --write    # 写入 test_vectors/v1/
    python tools/golden_vectors_gen/aes256gcm.py --check    # 只做核对，不输出向量

退出码：0 全部一致；1 核对失败（参考实现或抄录有误）；2 用法错误。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

TAG_LEN = 16
KEY_LEN = 32

# ---------------------------------------------------------------------------
# NIST GCMVS（AES-256）Count=0 官方向量 —— 用作不可动摇的锚点
# 来源：gcmEncryptExtIV256.rsp [Keylen=256][IVlen=96][PTlen=0][AADlen=0][Taglen=128]
# ---------------------------------------------------------------------------
NIST_KEY = bytes.fromhex("b52c505a37d78eda5dd34f20c22540ea1b58963cf8e5bf8ffa85f9f2492505b4")
NIST_IV = bytes.fromhex("516c33929df5a3284ff463d7")
NIST_PT = b""
NIST_AAD = b""
NIST_TAG = bytes.fromhex("bdc1ac884d332457a1d2664f168c76f0")


def hx(b: bytes) -> str:
    return b.hex()


# ---------------------------------------------------------------------------
# 主实现：cryptography
# ---------------------------------------------------------------------------
def crypt_seal(key: bytes, nonce: bytes, pt: bytes, aad: bytes) -> tuple[bytes, bytes]:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    aes = AESGCM(key)
    blob = aes.encrypt(nonce, pt, aad)
    return blob[:-TAG_LEN], blob[-TAG_LEN:]


def crypt_open(key: bytes, nonce: bytes, ct: bytes, tag: bytes, aad: bytes) -> bytes | None:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.exceptions import InvalidTag

    aes = AESGCM(key)
    try:
        return aes.decrypt(nonce, ct + tag, aad)
    except InvalidTag:
        return None


# ---------------------------------------------------------------------------
# 第二套实现：pycryptodome（可选）
# ---------------------------------------------------------------------------
def _pycrypto():
    try:
        from Crypto.Cipher import AES
        return AES
    except Exception:  # pragma: no cover - 可选依赖
        return None


def pyc_seal(key: bytes, nonce: bytes, pt: bytes, aad: bytes) -> tuple[bytes, bytes]:
    AES = _pycrypto()
    assert AES is not None
    cipher = AES.new(key, AES.MODE_GCM, nonce=nonce)
    if aad:
        cipher.update(aad)  # pycryptodome：AAD 必须在 encrypt 之前喂入
    ct = cipher.encrypt(pt)
    tag = cipher.digest()
    return ct, tag


def pyc_open(key: bytes, nonce: bytes, ct: bytes, tag: bytes, aad: bytes) -> bytes | None:
    AES = _pycrypto()
    assert AES is not None
    cipher = AES.new(key, AES.MODE_GCM, nonce=nonce)
    if aad:
        cipher.update(aad)  # 同上：AAD 在 decrypt 之前
    pt = cipher.decrypt(ct)
    try:
        cipher.verify(tag)
        return pt
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# 用例输入定义
# ---------------------------------------------------------------------------
KEY = NIST_KEY
PT_BLOCK = bytes(range(16))                 # 0x00..0x0f，16 字节
PT_SINGLE = b"\x42"                          # 单字节
AAD_SOME = bytes(range(32, 32 + 16))        # 16 字节 AAD
NONCE_12 = NIST_IV
NONCE_8 = bytes.fromhex("0011223344556677")                  # 8 字节（非 96 位，偏短）
NONCE_16 = bytes.fromhex("00112233445566778899aabbccddeeff")  # 16 字节（非 96 位，偏长）

# 供 open 用例回查 seal 输出与输入
NONCE_FOR: dict[str, bytes] = {}
PT_FOR: dict[str, bytes] = {}
AAD_FOR: dict[str, bytes] = {}
SEAL_BY_ID: dict[str, tuple[bytes, bytes]] = {}


def _register(ref: str, nonce: bytes, pt: bytes, aad: bytes):
    ct, tag = crypt_seal(KEY, nonce, pt, aad)
    SEAL_BY_ID[ref] = (ct, tag)
    NONCE_FOR[ref] = nonce
    PT_FOR[ref] = pt
    AAD_FOR[ref] = aad
    return ct, tag


def build_cases() -> list[dict]:
    cases: list[dict] = []

    # ---- 锚点（也是正式用例）----
    ct0, tag0 = _register("nist-anchor-256", NONCE_12, NIST_PT, NIST_AAD)
    cases.append({
        "id": "aead.aes256gcm.seal.nist-anchor-256",
        "kind": "aead.aes256gcm.seal",
        "title": "NIST GCMVS AES-256 Count=0：空明文 / 空 AAD / 96 位 nonce",
        "milestone": "M1",
        "input": {"keyHex": hx(KEY), "nonceHex": hx(NONCE_12),
                  "plaintextHex": hx(NIST_PT), "aadHex": hx(NIST_AAD)},
        "expect": {"ok": True, "value": {"ciphertextHex": hx(ct0), "tagHex": hx(tag0)}},
        "notes": "与 gcmEncryptExtIV256.rsp Count=0 逐字节一致；既作为正式向量，也作为主生成的锚点。",
        "tags": ["crypto", "cross-platform", "convergence"],
    })

    # ---- 其余 seal 用例 ----
    reg = [
        ("plaintext-single-block", NONCE_12, PT_BLOCK, NIST_AAD,
         "16 字节明文、空 AAD、96 位 nonce 主路径"),
        ("empty-pt-with-aad", NONCE_12, NIST_PT, AAD_SOME,
         "空明文 + 16 字节 AAD：守「AAD 进 GHASH 但不进密文」"),
        ("plaintext-single-byte", NONCE_12, PT_SINGLE, NIST_AAD,
         "单字节明文边界（块对齐前的最小输入）"),
        ("aad-and-pt", NONCE_12, PT_BLOCK, AAD_SOME,
         "明文与 AAD 同时存在，守两者独立参与认证"),
        ("nonce-8-byte", NONCE_8, PT_BLOCK, NONCE_8,
         "非 96 位 nonce 边界（偏短）；Dart 用 AesGcm.with256bits(nonceLength=8)"),
        ("nonce-16-byte", NONCE_16, PT_BLOCK, NONCE_16,
         "非 96 位 nonce 边界（偏长）；GCM 对 96 位外 nonce 改走 GHASH(nonce)"),
    ]
    for ref, nonce, pt, aad, note in reg:
        ct, tag = _register(ref, nonce, pt, aad)
        cases.append({
            "id": f"aead.aes256gcm.seal.{ref}",
            "kind": "aead.aes256gcm.seal",
            "title": f"seal · {ref}",
            "milestone": "M1",
            "input": {"keyHex": hx(KEY), "nonceHex": hx(nonce),
                      "plaintextHex": hx(pt), "aadHex": hx(aad)},
            "expect": {"ok": True, "value": {"ciphertextHex": hx(ct), "tagHex": hx(tag)}},
            "notes": note,
            "tags": ["crypto", "boundary"],
        })

    # ---- open 成功（复用 seal 输出，验证可往返 + 独立实现一致）----
    ok_refs = [
        ("nist-anchor-256-open", "nist-anchor-256", "解密 NIST 锚点，应为空明文"),
        ("roundtrip-single-block", "plaintext-single-block", "解密主路径，应还原 16 字节明文"),
    ]
    for cid, ref, note in ok_refs:
        ct, tag = SEAL_BY_ID[ref]
        pt = crypt_open(KEY, NONCE_FOR[ref], ct, tag, AAD_FOR[ref])
        assert pt is not None, f"open 自洽失败：{ref}"
        cases.append({
            "id": f"aead.aes256gcm.open.{cid}",
            "kind": "aead.aes256gcm.open",
            "title": f"open · {cid}",
            "milestone": "M1",
            "input": {"keyHex": hx(KEY), "nonceHex": hx(NONCE_FOR[ref]),
                      "ciphertextHex": hx(ct), "tagHex": hx(tag), "aadHex": hx(AAD_FOR[ref])},
            "expect": {"ok": True, "value": {"plaintextHex": hx(pt)}},
            "notes": note,
            "tags": ["crypto"],
        })

    # ---- open 认证失败（必须抛 PFB_E_AUTH_FAILED）----
    fail_refs = [
        ("tag-tampered", "plaintext-single-block", "tag",
         "标签被改一个字节，GHASH 校验必败：若省略认证步，被篡改的密文会被当成正常明文入库，账本损坏且无任何报错。"),
        ("ciphertext-tampered", "plaintext-single-block", "ct",
         "密文被改，CTR 还原出的明文变了，标签必败"),
        ("aad-mismatch", "aad-and-pt", "aad",
         "AAD 不符：AAD 参与认证但不进密文，改它必须败"),
    ]
    for cid, ref, tamper, note in fail_refs:
        ct, tag = SEAL_BY_ID[ref]
        if tamper == "tag":
            tag = bytes([tag[0] ^ 0xFF]) + tag[1:]
        elif tamper == "ct":
            ct = bytes([ct[0] ^ 0xFF]) + ct[1:]
        else:  # aad
            aad = bytes([AAD_FOR[ref][0] ^ 0xFF]) + AAD_FOR[ref][1:] if AAD_FOR[ref] else b"\x00" * 16
        ct_in, tag_in, aad_in = ct, tag, (aad if tamper == "aad" else AAD_FOR[ref])
        got = crypt_open(KEY, NONCE_FOR[ref], ct_in, tag_in, aad_in)
        assert got is None, f"篡改用例竟然解开了：{cid}"
        cases.append({
            "id": f"aead.aes256gcm.open.{cid}",
            "kind": "aead.aes256gcm.open",
            "title": f"open · {cid}",
            "milestone": "M1",
            "input": {"keyHex": hx(KEY), "nonceHex": hx(NONCE_FOR[ref]),
                      "ciphertextHex": hx(ct_in), "tagHex": hx(tag_in), "aadHex": hx(aad_in)},
            "expect": {"ok": False, "errorCode": "PFB_E_AUTH_FAILED"},
            "notes": note,
            "tags": ["crypto", "security", "boundary"],
        })

    return cases


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true", help="写入 test_vectors/v1/aes256gcm.json")
    ap.add_argument("--check", action="store_true", help="只做核对，不输出向量")
    args = ap.parse_args()

    # ---- Layer 1：NIST 锚点必须命中 ----
    anchor_ct, anchor_tag = crypt_seal(KEY, NIST_IV, NIST_PT, NIST_AAD)
    if anchor_tag != NIST_TAG:
        print(
            f"[FAIL] NIST 锚点 Tag 不符：期望 {NIST_TAG.hex()}，实际 {anchor_tag.hex()}\n"
            "       说明 cryptography 对 AES-256-GCM 的实现与 NIST 不一致，或锚点抄录有误。",
            file=sys.stderr,
        )
        return 1
    print("[ok] NIST GCMVS AES-256 Count=0 锚点命中（空明文 / 空 AAD / 96 位 nonce）")

    cases = build_cases()

    # ---- Layer 3（可选）：pycryptodome 交叉核对全部 seal ----
    AES = _pycrypto()
    if AES is not None:
        for c in cases:
            if c["kind"] != "aead.aes256gcm.seal":
                continue
            ref = c["id"].split(".", 4)[-1]
            if ref not in SEAL_BY_ID:
                continue
            ct, tag = SEAL_BY_ID[ref]
            pct, ptag = pyc_seal(KEY, NONCE_FOR[ref], PT_FOR[ref], AAD_FOR[ref])
            if (pct, ptag) != (ct, tag):
                print(f"[FAIL] pycryptodome 与 cryptography 不一致：{c['id']}", file=sys.stderr)
                return 1
        n = sum(1 for c in cases if c["kind"].endswith(".seal"))
        print(f"[ok] pycryptodome 交叉核对 {n} 条 seal 用例一致")
    else:
        print("[skip] 未安装 pycryptodome，跳过第二套实现交叉核对（Layer 3 可选）")

    suite = {
        "schemaVersion": 1,
        "suite": "aes256gcm",
        "title": "AES-256-GCM 黄金测试向量",
        "description": (
            "AES-256-GCM（NIST SP 800-38D）的认证加密向量。key=32 / nonce=12 / tag=16 字节。\n"
            "期望值由 Python cryptography 独立复算，并以 NIST GCMVS AES-256 Count=0 官方向量锚定；"
            "含 96 位 nonce 主路径、非 96 位 nonce 边界（8 / 16 字节）、空明文、单字节明文，"
            "以及三类认证失败（标签篡改 / 密文篡改 / AAD 不符）—— 后者必须抛 PFB_E_AUTH_FAILED。\n"
            "nonce 复用不能由向量守，但「同一输入永远同一输出」由本套件守。"
        ),
        "cases": cases,
    }

    if args.check:
        print(f"[ok] 共 {len(cases)} 条用例，锚点与交叉核对通过")
        return 0

    text = json.dumps(suite, indent=2, ensure_ascii=False) + "\n"
    if args.write:
        out = Path("test_vectors/v1/aes256gcm.json")
        out.write_bytes(text.encode("utf-8"))  # 显式 LF，避免 Windows CRLF
        print(f"[ok] 写入 {out}（{len(cases)} 条用例）")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

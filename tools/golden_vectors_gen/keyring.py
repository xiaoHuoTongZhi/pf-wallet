#!/usr/bin/env python3
"""Keyring 编排层的黄金向量生成器（方案 §3.1 / §3.5.1）。

覆盖的 kind（对应 packages/pf_testkit/lib/src/drivers/m2_keyring.dart）：
  - keyring.dbkey.derive       MK → DBKey（HKDF-SHA256，info="pf/db/1"）
  - keyring.keycheck.seal      DBKey + installId + nonce → keyCheck 块
  - keyring.keycheck.open      校验 keyCheck（含密码错 / 块被改两个错误分支）
  - keyring.recovery.wrap      RK 包裹 MK → recovery.blob
  - keyring.recovery.unwrap    解包 recovery.blob（含恢复码错 / 标签被改两个错误分支）

期望值由 Python 独立复算，与 Dart 侧（HkdfSha256 + Aes256Gcm + KeyringCore）
是两套实现：
  - HKDF：标准库 hmac 手拼（RFC 5869 两行构造）× cryptography 的 HKDF 交叉核对
  - AES-256-GCM：cryptography 主算 × pycryptodome 交叉核对（与 aes256gcm.py 同源）

规格裁决（见 KeyringCore 的文件注释）：keyCheck 明文采用 §3.1 的字符串
"PF:KEYCHECK:v1"（14 字节），ct = 14 + 16 = 30 字节；§3.5.1 示例的
"48B(32+16)" 与 §3.1 自相矛盾，不采用。

用法：
  python keyring.py            # 自检 + 打印，不写文件
  python keyring.py --write    # 写入 ../../test_vectors/v1/keyring.json（LF 行尾）
"""

from __future__ import annotations

import argparse
import hmac
import hashlib
import json
import sys
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

# ---- 固定测试输入（全部写死，保证向量可复现） ----

MK_HEX = "3d7f" "a1c2" "9b04" "e5f6" "7a83" "c1d9" "0b25" "4e68" "f7a2" "c309" "58d1" "6b4e" "92f0" "ad37" "16c8" "e45b"
MK_HEX = "".join(MK_HEX.split()) if False else (
    "3d7fa1c29b04e5f67a83c1d90b254e68f7a2c30958d16b4e92f0ad3716c8e45b"
)
MK2_HEX = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

NONCE_12 = bytes.fromhex("21 22 23 24 25 26 27 28 29 2a 2b 2c".replace(" ", ""))
NONCE_13 = bytes.fromhex("31 32 33 34 35 36 37 38 39 3a 3b 3c 3d".replace(" ", ""))

INSTALL_ID = "01J8Z9K2M4P6Q8R0T2V4X6Z8B1"  # §3.5.1 示例
INSTALL_ID_2 = "01J8ZOTHERDEVICE0000000000X"
CFG_VERSION = 1

KEYCHECK_PT = b"PF:KEYCHECK:v1"  # §3.1，14 字节
DBKEY_INFO = b"pf/db/1"


def hkdf_sha256(ikm: bytes, info: bytes, length: int = 32) -> bytes:
    """RFC 5869 两行构造，salt 缺省 = HashLen 个 0x00（与 Dart 实现同语义）。"""
    prk = hmac.new(b"\x00" * 32, ikm, hashlib.sha256).digest()
    okm = b""
    t = b""
    counter = 1
    while len(okm) < length:
        t = hmac.new(prk, t + info + bytes([counter]), hashlib.sha256).digest()
        okm += t
        counter += 1
    return okm[:length]


def aead_seal(key: bytes, nonce: bytes, plaintext: bytes, aad: bytes) -> tuple[bytes, bytes]:
    """返回 (ciphertext, tag)。AESGCM.encrypt 的返回 = ct || tag（16B 尾部）。"""
    blob = AESGCM(key).encrypt(nonce, plaintext, aad)
    return blob[:-16], blob[-16:]


def aead_open(key: bytes, nonce: bytes, ciphertext: bytes, tag: bytes, aad: bytes) -> bytes:
    return AESGCM(key).decrypt(nonce, ciphertext + tag, aad)


def keycheck_aad(cfg_version: int, install_id: str) -> bytes:
    return f"pf-keycheck-v1|{cfg_version}|{install_id}".encode()


def recovery_aad(cfg_version: int) -> bytes:
    return f"pf-recovery-v1|{cfg_version}".encode()


def self_check() -> None:
    """Layer 1 自检：两套独立 Python 路径必须一致，否则生成脚本本身不可信。"""
    mk = bytes.fromhex(MK_HEX)

    # HKDF：手拼 × cryptography 交叉核对
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF

    ref = HKDF(algorithm=hashes.SHA256(), length=32, salt=b"", info=DBKEY_INFO).derive(mk)
    mine = hkdf_sha256(mk, DBKEY_INFO)
    if ref != mine:
        print("[fatal] HKDF 两条 Python 路径不一致", file=sys.stderr)
        sys.exit(1)

    # AES-GCM：cryptography × pycryptodome 交叉核对
    dbkey = mine
    ct, tag = aead_seal(dbkey, NONCE_12, KEYCHECK_PT, keycheck_aad(CFG_VERSION, INSTALL_ID))
    from Crypto.Cipher import AES as _AES

    cipher = _AES.new(dbkey, _AES.MODE_GCM, nonce=NONCE_12)
    cipher.update(keycheck_aad(CFG_VERSION, INSTALL_ID))
    ct2, tag2 = cipher.encrypt_and_digest(KEYCHECK_PT)
    if ct != ct2 or tag != tag2:
        print("[fatal] AES-GCM 两条 Python 路径不一致", file=sys.stderr)
        sys.exit(1)

    # 确定性 + 定长
    assert len(dbkey) == 32 and len(ct) == len(KEYCHECK_PT) and len(tag) == 16
    print("[ok] 自检通过：HKDF 双路径一致，AES-GCM 双路径一致")


def build_cases() -> list[dict]:
    cases: list[dict] = []
    mk = bytes.fromhex(MK_HEX)
    mk2 = bytes.fromhex(MK2_HEX)

    # ---- keyring.dbkey.derive：MK → DBKey ----
    dbkey = hkdf_sha256(mk, DBKEY_INFO)
    dbkey2 = hkdf_sha256(mk2, DBKEY_INFO)
    assert dbkey != dbkey2, "不同 MK 必须得到不同 DBKey"
    cases.append(
        {
            "id": "keyring.dbkey.derive.default",
            "kind": "keyring.dbkey.derive",
            "title": "MK → DBKey（HKDF-SHA256，info=\"pf/db/1\"，缺省 salt）",
            "milestone": "M1",
            "input": {"masterKeyHex": MK_HEX},
            "expect": {"ok": True, "value": {"dbKeyHex": dbkey.hex()}},
            "notes": (
                "锁死 §7.4 的 DBKey 派生。info 标签 \"pf/db/1\" 是格式契约："
                "改一个字符，所有已创建的数据库一个字节不动却再也打不开。"
                "期望值由 Python 标准库 hmac 手拼的 HKDF 与 cryptography 的 HKDF 交叉复算。"
            ),
            "tags": ["crypto", "preset"],
        }
    )
    cases.append(
        {
            "id": "keyring.dbkey.derive.other-mk",
            "kind": "keyring.dbkey.derive",
            "title": "不同 MK ⇒ 不同 DBKey（用途分离的前提）",
            "milestone": "M1",
            "input": {"masterKeyHex": MK2_HEX},
            "expect": {"ok": True, "value": {"dbKeyHex": dbkey2.hex()}},
            "notes": (
                "锁「HKDF 真的在吃输入」：若实现把 MK 写死或复用 PRK，"
                "这条会与上一条撞车。附件 KEK、生物识别包裹密钥的分离性同理依赖于此。"
            ),
            "tags": ["crypto", "boundary"],
        }
    )

    # ---- keyring.keycheck.seal：生成 keyCheck 块 ----
    ct, tag = aead_seal(dbkey, NONCE_12, KEYCHECK_PT, keycheck_aad(CFG_VERSION, INSTALL_ID))
    cases.append(
        {
            "id": "keyring.keycheck.seal.default",
            "kind": "keyring.keycheck.seal",
            "title": "生成 keyCheck 块（§3.5.1 的 keyCheck 对象）",
            "milestone": "M1",
            "input": {
                "dbKeyHex": dbkey.hex(),
                "nonceHex": NONCE_12.hex(),
                "installId": INSTALL_ID,
                "cfgVersion": CFG_VERSION,
            },
            "expect": {
                "ok": True,
                "value": {
                    "nonceHex": NONCE_12.hex(),
                    "ciphertextHex": ct.hex(),
                    "tagHex": tag.hex(),
                    "aad": keycheck_aad(CFG_VERSION, INSTALL_ID).decode(),
                },
            },
            "notes": (
                "锁 AAD 拼法 \"pf-keycheck-v1|<cfgVersion>|<installId>\" 与固定明文 "
                "\"PF:KEYCHECK:v1\"。规格裁决：§3.5.1 示例的 ct=48B 与 §3.1 的 14 字节"
                "明文矛盾，采用 §3.1，ct = 14+16 = 30 字节。"
            ),
            "tags": ["crypto", "preset"],
        }
    )
    ct_v2, tag_v2 = aead_seal(dbkey, NONCE_12, KEYCHECK_PT, keycheck_aad(2, INSTALL_ID))
    cases.append(
        {
            "id": "keyring.keycheck.seal.cfg-version-binding",
            "kind": "keyring.keycheck.seal",
            "title": "cfgVersion 进入 AAD（v=2 时密文不同）",
            "milestone": "M1",
            "input": {
                "dbKeyHex": dbkey.hex(),
                "nonceHex": NONCE_12.hex(),
                "installId": INSTALL_ID,
                "cfgVersion": 2,
            },
            "expect": {
                "ok": True,
                "value": {
                    "nonceHex": NONCE_12.hex(),
                    "ciphertextHex": ct_v2.hex(),
                    "tagHex": tag_v2.hex(),
                    "aad": keycheck_aad(2, INSTALL_ID).decode(),
                },
            },
            "notes": "锁「版本号真的进了 AAD」：同 DBKey 同 nonce 下 v=1 与 v=2 的密文必须不同。",
            "tags": ["crypto", "boundary"],
        }
    )
    cases.append(
        {
            "id": "keyring.keycheck.seal.nonce-length-invalid",
            "kind": "keyring.keycheck.seal",
            "title": "nonce 不是 12 字节 ⇒ headerInvalid（输入契约破坏）",
            "milestone": "M1",
            "input": {
                "dbKeyHex": dbkey.hex(),
                "nonceHex": NONCE_13.hex(),
                "installId": INSTALL_ID,
                "cfgVersion": CFG_VERSION,
            },
            "expect": {"ok": False, "errorCode": "PFK_E_TAMPERED"},
            "notes": "keyCheck 块的 nonce 钉死 12 字节（§3.5.1 存进 cfg 的块格式契约）：长度不符 = 块结构破坏 → PFK_E_TAMPERED。与 AEAD 层自身的 headerInvalid（nonce 8/16 字节在 GCM 合法）分层不冲突。",
            "tags": ["crypto", "error"],
        }
    )

    # ---- keyring.keycheck.open：校验 keyCheck 块 ----
    cases.append(
        {
            "id": "keyring.keycheck.open.roundtrip",
            "kind": "keyring.keycheck.open",
            "title": "正确的 DBKey 解开 keyCheck 并命中固定明文",
            "milestone": "M1",
            "input": {
                "dbKeyHex": dbkey.hex(),
                "nonceHex": NONCE_12.hex(),
                "ciphertextHex": ct.hex(),
                "tagHex": tag.hex(),
                "installId": INSTALL_ID,
                "cfgVersion": CFG_VERSION,
            },
            "expect": {"ok": True, "value": {"plaintextUtf8": "PF:KEYCHECK:v1"}},
            "notes": "解锁路径的第一步：keyCheck 过了才去开数据库。明文必须逐字节等于固定常量。",
            "tags": ["crypto", "preset"],
        }
    )
    wrong_dbkey = bytes(a ^ 1 for a in dbkey)
    cases.append(
        {
            "id": "keyring.keycheck.open.wrong-dbkey",
            "kind": "keyring.keycheck.open",
            "title": "DBKey 错（密码错）⇒ wrongPassword",
            "milestone": "M1",
            "input": {
                "dbKeyHex": wrong_dbkey.hex(),
                "nonceHex": NONCE_12.hex(),
                "ciphertextHex": ct.hex(),
                "tagHex": tag.hex(),
                "installId": INSTALL_ID,
                "cfgVersion": CFG_VERSION,
            },
            "expect": {"ok": False, "errorCode": "PFK_E_WRONG_PASSWORD"},
            "notes": (
                "§3.1 的核心价值：密码错在这里现形，不必去开数据库。"
                "注意加密层无法区分「密码错」与「块被改」—— 两者都是认证失败，"
                "统一映射为 PFK_E_WRONG_PASSWORD，由 App 层结合恢复码路径消歧。"
            ),
            "tags": ["crypto", "error"],
        }
    )
    cases.append(
        {
            "id": "keyring.keycheck.open.install-id-mismatch",
            "kind": "keyring.keycheck.open",
            "title": "installId 不符（AAD 被换）⇒ 认证失败 ⇒ wrongPassword",
            "milestone": "M1",
            "input": {
                "dbKeyHex": dbkey.hex(),
                "nonceHex": NONCE_12.hex(),
                "ciphertextHex": ct.hex(),
                "tagHex": tag.hex(),
                "installId": INSTALL_ID_2,
                "cfgVersion": CFG_VERSION,
            },
            "expect": {"ok": False, "errorCode": "PFK_E_WRONG_PASSWORD"},
            "notes": (
                "锁「AAD 真的参与认证」：把别人的 cfg 抄过来换上自己的 installId "
                "也过不去。与密码错同一错误码 —— App 层消歧，见 wrong-dbkey 的 notes。"
            ),
            "tags": ["crypto", "error"],
        }
    )
    cases.append(
        {
            "id": "keyring.keycheck.open.ciphertext-short",
            "kind": "keyring.keycheck.open",
            "title": "密文长度不足 ⇒ tampered（结构破坏，未进 AEAD 先拦下）",
            "milestone": "M1",
            "input": {
                "dbKeyHex": dbkey.hex(),
                "nonceHex": NONCE_12.hex(),
                "ciphertextHex": ct[:-4].hex(),
                "tagHex": tag.hex(),
                "installId": INSTALL_ID,
                "cfgVersion": CFG_VERSION,
            },
            "expect": {"ok": False, "errorCode": "PFK_E_TAMPERED"},
            "notes": "ct 长度 ≠ 明文长度（14）= 块被截断或写坏 → PFK_E_TAMPERED，不走认证。",
            "tags": ["crypto", "error"],
        }
    )

    # ---- keyring.recovery.wrap / unwrap ----
    rk = hkdf_sha256(mk, b"pf/recovery-test-rk")  # 向量里 RK 直接给定，不重跑 Argon2id
    rkblob_ct, rkblob_tag = aead_seal(rk, NONCE_12, mk, recovery_aad(CFG_VERSION))
    assert len(rkblob_ct) == 32, "GCM 密文应与明文等长（32 字节）"
    cases.append(
        {
            "id": "keyring.recovery.wrap.default",
            "kind": "keyring.recovery.wrap",
            "title": "RK 包裹 MK → recovery.blob（§3.5.2）",
            "milestone": "M1",
            "input": {
                "recoveryKeyHex": rk.hex(),
                "masterKeyHex": MK_HEX,
                "nonceHex": NONCE_12.hex(),
                "cfgVersion": CFG_VERSION,
            },
            "expect": {
                "ok": True,
                "value": {
                    "nonceHex": NONCE_12.hex(),
                    "ciphertextHex": rkblob_ct.hex(),
                    "tagHex": rkblob_tag.hex(),
                    "aad": recovery_aad(CFG_VERSION).decode(),
                },
            },
            "notes": (
                "锁 AAD 拼法 \"pf-recovery-v1|<cfgVersion>\" 与「密文 = MK 原文」。"
                "RK = Argon2id(恢复码, salt_rec, P_*)，派生已有独立向量，此处直接给定 RK。"
            ),
            "tags": ["crypto", "preset"],
        }
    )
    cases.append(
        {
            "id": "keyring.recovery.unwrap.roundtrip",
            "kind": "keyring.recovery.unwrap",
            "title": "正确的 RK 解开 recovery.blob 还原 MK",
            "milestone": "M1",
            "input": {
                "recoveryKeyHex": rk.hex(),
                "nonceHex": NONCE_12.hex(),
                "ciphertextHex": rkblob_ct.hex(),
                "tagHex": rkblob_tag.hex(),
                "cfgVersion": CFG_VERSION,
            },
            "expect": {"ok": True, "value": {"masterKeyHex": MK_HEX}},
            "notes": "恢复通路：解开 blob 即得 MK，与主密码解锁完全等价。",
            "tags": ["crypto", "preset"],
        }
    )
    wrong_rk = bytes(a ^ 1 for a in rk)
    cases.append(
        {
            "id": "keyring.recovery.unwrap.wrong-rk",
            "kind": "keyring.recovery.unwrap",
            "title": "RK 错（恢复码错）⇒ wrongRecoveryCode",
            "milestone": "M1",
            "input": {
                "recoveryKeyHex": wrong_rk.hex(),
                "nonceHex": NONCE_12.hex(),
                "ciphertextHex": rkblob_ct.hex(),
                "tagHex": rkblob_tag.hex(),
                "cfgVersion": CFG_VERSION,
            },
            "expect": {"ok": False, "errorCode": "PFK_E_WRONG_RECOVERY_CODE"},
            "notes": (
                "与主密码错分开编码：用户动作不同（核对抄写 vs 重输密码），"
                "App 层按码分支给出不同提示与不同的重试策略。"
            ),
            "tags": ["crypto", "error"],
        }
    )
    tampered_tag = bytes([rkblob_tag[0] ^ 0xFF]) + rkblob_tag[1:]
    cases.append(
        {
            "id": "keyring.recovery.unwrap.tag-tampered",
            "kind": "keyring.recovery.unwrap",
            "title": "标签被篡改 ⇒ wrongRecoveryCode",
            "milestone": "M1",
            "input": {
                "recoveryKeyHex": rk.hex(),
                "nonceHex": NONCE_12.hex(),
                "ciphertextHex": rkblob_ct.hex(),
                "tagHex": tampered_tag.hex(),
                "cfgVersion": CFG_VERSION,
            },
            "expect": {"ok": False, "errorCode": "PFK_E_WRONG_RECOVERY_CODE"},
            "notes": "任何一位被改，认证必须失败。恢复码路径无「内容被换」中间态：能过认证就等于 RK 正确。",
            "tags": ["crypto", "error"],
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
        "suite": "keyring",
        "title": "Keyring 密钥层级编排",
        "description": (
            "锁死 §3.1 密钥层级（MK → DBKey → keyCheck → 恢复码包裹）的全部组合规则："
            "HKDF info 标签、两个 AAD 的拼法、固定明文、错误码分支。"
            "期望值由 Python（标准库 hmac + cryptography，交叉核对 pycryptodome）独立复算。"
        ),
        "cases": cases,
    }
    text = json.dumps(suite, ensure_ascii=False, indent=2) + "\n"

    if not args.write:
        print(f"[dry] {len(cases)} 条用例（未写文件，--write 落盘）")
        return

    out = Path("test_vectors/v1/keyring.json")
    out.write_bytes(text.encode("utf-8"))
    print(f"[ok] 写入 {out}（{len(cases)} 条用例）")


if __name__ == "__main__":
    main()

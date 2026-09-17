#!/usr/bin/env python3
"""PFB 分块容器（规格 §3.3）黄金向量的生成器 —— 独立参考实现。

## 为什么这个脚本必须用另一套实现

容器向量锁的是**发布格式**的字节。期望值若由 Dart 实现自己算，就是
「实现算出什么就接受什么」。本脚本用 Python 的 `cryptography`（AES-GCM）、
`argon2-cffi`（Argon2id）、`zlib.crc32` 与手手工打包独立算出全部期望值，
与 Dart 侧 `pf_crypto` 是两套完全独立的实现。

## 2026-09-17 裁决的落地

M0 曾有 76 字节 "PFB1" 单块容器的三套向量（container_header / container_layout /
container_trailer）。落实导出器时确认与规格 §3.3 冲突，裁决 §3.3 为唯一 v1：
本脚本**替换**那三套向量（重写为 128 字节分块格式）并新增 container_file
（完整文件字节级断言，附录 B 的 pfb-file.json 落地）。76B 格式从未发布过
任何文件，替换无迁移问题。

## 覆盖范围

- container_constants：发布常量快照（规格 §3.3 人工转录，maxPlaintextLength
  为 2026-09-17 与实现同步固定的 1 TiB）
- container_header：128B 头部编码快照 ×2、解码往返、CRC 篡改 / 魔数错 /
  版本过高 / 未知 flag 位 四类错误分流
- container_layout：3 块 / 1 块文件的逐段切分指纹、截断、尾部多字节
- container_digest：contentDigest 一致、密文篡改、**固定头篡改仍在覆盖外**
  （那是 CRC 的辖区 —— 覆盖边界本身是契约）、文件尾篡改
- container_file：完整文件封包（KDF + 分块 + 链式 AAD）单块/多块、
  正确解包、密码错（PFB_E_AUTH_FAILED）、密文篡改（PFB_E_DIGEST_MISMATCH，
  免密先判）、头部篡改（PFB_E_HEADER_INVALID）

## 链式 AAD 的关键细节（本脚本与 Dart 实现必须逐字节一致）

    aad(idx) = SHA256(file[0:128]) || u32BE(idx) || prevTag
    prevTag(0)    = 32 个 0x00 字节   ← 规格原文如此，不是 16 个
    prevTag(idx>0) = 上一块 box 的末 16 字节（即该块 GCM tag）

chunkNonce = noncePrefix || u32BE(idx)；contentDigest = SHA256(file[48:len-32])。

用法：

    python container_pfb.py            # 打印 JSON 到标准输出
    python container_pfb.py --write    # 写入 test_vectors/v1/
    python container_pfb.py --check    # 只做核对，不输出向量

退出码：0 全部一致；1 核对失败；2 用法错误。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
import zlib
from pathlib import Path

from argon2.low_level import Type, hash_secret_raw
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

VECTOR_DIR = Path(__file__).resolve().parents[2] / "test_vectors" / "v1"

MAGIC = b"PFBOOK\x01\x00"
FORMAT_VERSION = 1
MIN_READER_VERSION = 1
FLAG_AESGCM = 1 << 0
FLAG_GZIP = 1 << 1
FLAG_CHUNKED = 1 << 2
FLAG_HAS_ATTACH = 1 << 3
FLAG_MULTI_VOLUME = 1 << 4
FLAG_INCREMENTAL = 1 << 5

FIXED_KDF = {"m": 19456, "t": 2, "p": 1, "saltLength": 16, "outputLength": 32}
HEADER_KDF = {"m": 65536, "t": 3, "p": 1, "saltLength": 16, "outputLength": 32}
SALT = bytes.fromhex("101112131415161718191a1b1c1d1e1f")
NONCE_PREFIX = bytes.fromhex("a0a1a2a3a4a5a6a7")
VOLUME_SET_ID = bytes.fromhex("0001020304050607")
PASSWORD = "pfb-vector-pass-1"
WRONG_PASSWORD = "not-the-password"


def kdf_key(kdf: dict, password: str, salt: bytes) -> bytes:
    return hash_secret_raw(
        password.encode("utf-8"), salt,
        time_cost=kdf["t"], memory_cost=kdf["m"], parallelism=kdf["p"],
        hash_len=kdf["outputLength"], type=Type.ID,
    )


def build_header(
    feature_flags: int,
    plaintext_length: int,
    chunk_count: int,
    kdf: dict,
    salt: bytes,
    nonce_prefix: bytes,
    chunk_plain_kib: int,
    volume_set_id: bytes,
    volume_index: int,
    volume_total: int,
    set_digest: bytes,
    min_reader_version: int = MIN_READER_VERSION,
    format_version: int = FORMAT_VERSION,
) -> bytes:
    head = bytearray(128)
    head[0:8] = MAGIC
    struct.pack_into(">HH", head, 8, format_version, min_reader_version)
    struct.pack_into(">H", head, 12, feature_flags)
    head[14] = 1  # kdfId Argon2id
    head[15] = 1  # aeadId AES-256-GCM
    struct.pack_into(">II", head, 16, kdf["m"], kdf["t"])
    head[24] = kdf["p"]
    head[25] = kdf["outputLength"]
    struct.pack_into(">HHH", head, 26, kdf["saltLength"], len(nonce_prefix), chunk_plain_kib)
    struct.pack_into(">QI", head, 32, plaintext_length, chunk_count)
    head[48:64] = salt
    head[64:72] = nonce_prefix
    head[72:84] = nonce_prefix + b"\x00" * 4
    head[84:92] = volume_set_id
    struct.pack_into(">HH", head, 92, volume_index, volume_total)
    head[96:128] = set_digest
    struct.pack_into(">I", head, 44, zlib.crc32(bytes(head[0:44])) & 0xFFFFFFFF)
    return bytes(head)


def seal(payload: bytes, password: str, kdf: dict, salt: bytes, nonce_prefix: bytes,
         feature_flags: int, chunk_plain_kib: int, volume_set_id: bytes,
         volume_index: int = 1, volume_total: int = 1) -> bytes:
    chunk_bytes = chunk_plain_kib * 1024
    if payload:
        chunk_count = (len(payload) + chunk_bytes - 1) // chunk_bytes
    else:
        chunk_count = 0
    header = build_header(
        feature_flags, len(payload), chunk_count, kdf, salt, nonce_prefix,
        chunk_plain_kib, volume_set_id, volume_index, volume_total, b"\x00" * 32,
    )
    key = kdf_key(kdf, password, salt)
    aead = AESGCM(key)
    aad_base = hashlib.sha256(header).digest()
    out = bytearray(header)
    prev_tag = b"\x00" * 32
    for idx in range(chunk_count):
        plain = payload[idx * chunk_bytes:(idx + 1) * chunk_bytes]
        nonce = nonce_prefix + struct.pack(">I", idx)
        aad = aad_base + struct.pack(">I", idx) + prev_tag
        box = aead.encrypt(nonce, plain, aad)  # ct || tag
        out += struct.pack(">I", len(box)) + nonce + box
        prev_tag = box[-16:]
    content_digest = hashlib.sha256(bytes(out[48:])).digest()
    out += content_digest
    return bytes(out)


def open_pfb(blob: bytes, password: str, kdf: dict, salt: bytes) -> bytes:
    assert blob[0:8] == MAGIC
    (fmt_ver, _min_rdr, flags, kdf_id, aead_id) = struct.unpack(">HHHBB", blob[8:16])
    assert fmt_ver <= 1
    assert flags & FLAG_CHUNKED
    assert kdf_id == 1 and aead_id == 1
    (m, t) = struct.unpack(">II", blob[16:24])
    p, out_len, salt_len, np_len, chunk_kib = struct.unpack(">BBHHH", blob[24:32])
    (plain_len, chunk_count, crc) = struct.unpack(">QII", blob[32:48])
    assert crc == zlib.crc32(blob[0:44]) & 0xFFFFFFFF, "header crc"
    nonce_prefix = blob[64:72]
    assert blob[72:84] == nonce_prefix + b"\x00" * 4
    assert blob[48:48 + salt_len] == salt
    digest = hashlib.sha256(blob[48:len(blob) - 32]).digest()
    assert digest == blob[-32:], "content digest"
    key = kdf_key({"m": m, "t": t, "p": p, "saltLength": salt_len, "outputLength": out_len},
                  password, blob[48:48 + salt_len])
    aead = AESGCM(key)
    aad_base = hashlib.sha256(blob[0:128]).digest()
    off, prev_tag, out = 128, b"\x00" * 32, bytearray()
    for idx in range(chunk_count):
        (clen,) = struct.unpack(">I", blob[off:off + 4])
        nonce = blob[off + 4:off + 16]
        assert nonce == nonce_prefix + struct.pack(">I", idx), "nonce order"
        box = blob[off + 16:off + 4 + 12 + clen]
        aad = aad_base + struct.pack(">I", idx) + prev_tag
        out += aead.decrypt(nonce, box, aad)
        prev_tag = box[-16:]
        off += 4 + 12 + clen
    assert off == len(blob) - 32
    assert len(out) == plain_len
    return bytes(out)


def pattern(length: int, seed: int) -> bytes:
    return bytes((i * 31 + seed) & 0xFF for i in range(length))


def case(case_id: str, kind: str, title: str, input_: dict, expect: dict, notes: str,
         tags: list[str] | None = None) -> dict:
    return {
        "id": case_id,
        "kind": kind,
        "title": title,
        "milestone": "M1",
        "input": input_,
        "expect": expect,
        "notes": notes,
        "tags": tags or ["format", "security", "crypto"],
    }


def build_suites() -> dict[str, dict]:
    # ---------- 公共输入 ----------
    flags_plain = FLAG_AESGCM | FLAG_CHUNKED  # 5
    payload_single = b'{"type":"ledger","id":"01J8TESTLEDGER0000000000001"}\n'
    payload_multi = pattern(2500, 3)
    set_digest_zero = "00" * 32

    header_input_1 = {
        "kdf": HEADER_KDF,
        "featureFlags": FLAG_AESGCM | FLAG_GZIP | FLAG_CHUNKED,
        "minReaderVersion": 1,
        "chunkPlainSizeKiB": 1024,
        "plaintextLength": 240 * 1024 * 1024,
        "chunkCount": 240,
        "saltHex": SALT.hex(),
        "noncePrefixHex": NONCE_PREFIX.hex(),
        "volumeSetIdHex": VOLUME_SET_ID.hex(),
        "volumeIndex": 1,
        "volumeTotal": 1,
        "setDigestHex": set_digest_zero,
    }
    header_1 = build_header(
        header_input_1["featureFlags"], 240 * 1024 * 1024, 240, HEADER_KDF, SALT, NONCE_PREFIX,
        1024, VOLUME_SET_ID, 1, 1, bytes(32),
    )
    header_input_2 = {
        "kdf": HEADER_KDF,
        "featureFlags": FLAG_AESGCM | FLAG_CHUNKED | FLAG_HAS_ATTACH | FLAG_MULTI_VOLUME | FLAG_INCREMENTAL,
        "minReaderVersion": 1,
        "chunkPlainSizeKiB": 1024,
        "plaintextLength": 0,
        "chunkCount": 0,
        "saltHex": SALT.hex(),
        "noncePrefixHex": NONCE_PREFIX.hex(),
        "volumeSetIdHex": VOLUME_SET_ID.hex(),
        "volumeIndex": 2,
        "volumeTotal": 3,
        "setDigestHex": "9f" * 32,
    }
    header_2 = build_header(
        header_input_2["featureFlags"], 0, 0, HEADER_KDF, SALT, NONCE_PREFIX,
        1024, VOLUME_SET_ID, 2, 3, bytes.fromhex("9f" * 32),
    )

    header_cases = [
        case(
            "container.header.encode.default-full",
            "container.header.encode",
            "默认参数与 GZIP+CHUNKED 标志下的 128 字节头部字节",
            header_input_1,
            {
                "ok": True,
                "value": {
                    "hex": header_1.hex(),
                    "lengthBytes": 128,
                    "crc32Hex": f"{zlib.crc32(header_1[0:44]) & 0xFFFFFFFF:08X}",
                    "headerSha256Hex": hashlib.sha256(header_1).hexdigest(),
                },
            },
            "这是发布格式的第一个字节序快照。任何让这串十六进制变化的改动都会让"
            "已导出的旧文件失去可读性，必须走格式主版本升级，而不是直接改。",
            ["format", "security"],
        ),
        case(
            "container.header.encode.attachments-incremental-multivolume",
            "container.header.encode",
            "HAS_ATTACH + INCREMENTAL + 多卷（2/3）与非零 setDigest 的头部",
            header_input_2,
            {
                "ok": True,
                "value": {
                    "hex": header_2.hex(),
                    "lengthBytes": 128,
                    "crc32Hex": f"{zlib.crc32(header_2[0:44]) & 0xFFFFFFFF:08X}",
                    "headerSha256Hex": hashlib.sha256(header_2).hexdigest(),
                },
            },
            "变长区的 setDigest 参与 AAD 基础摘要（SHA256 头 128 字节）——"
            "这条向量把「变量区也在 AAD 保护范围内」钉死。",
            ["format", "security"],
        ),
        case(
            "container.header.decode.roundtrip",
            "container.header.decode",
            "解析合法头部并还原全部字段",
            {"hex": header_1.hex()},
            {
                "ok": True,
                "value": {
                    "formatVersion": 1,
                    "minReaderVersion": 1,
                    "featureFlags": FLAG_AESGCM | FLAG_GZIP | FLAG_CHUNKED,
                    "kdfMemoryKiB": 65536,
                    "kdfIterations": 3,
                    "kdfParallelism": 1,
                    "kdfSaltLen": 16,
                    "noncePrefixLen": 8,
                    "chunkPlainSizeKiB": 1024,
                    "plaintextLength": 251658240,
                    "chunkCount": 240,
                    "saltHex": SALT.hex(),
                    "noncePrefixHex": NONCE_PREFIX.hex(),
                    "volumeSetIdHex": VOLUME_SET_ID.hex(),
                    "volumeIndex": 1,
                    "volumeTotal": 1,
                    "setDigestHex": set_digest_zero,
                },
            },
            "解析必须逐字段还原；宽松解析会让拼写错误变成假绿灯。",
            ["format"],
        ),
    ]

    def tampered_crc(src: bytes, offset: int) -> bytes:
        data = bytearray(src)
        data[offset] ^= 0x01
        return bytes(data)

    def fixed_crc(src: bytes) -> bytes:
        data = bytearray(src)
        struct.pack_into(">I", data, 44, zlib.crc32(bytes(data[0:44])) & 0xFFFFFFFF)
        return bytes(data)

    version_bumped = bytearray(header_1)
    struct.pack_into(">H", version_bumped, 8, 2)
    version_bumped = fixed_crc(version_bumped)

    unknown_flag = bytearray(header_1)
    struct.pack_into(">H", unknown_flag, 12, FLAG_AESGCM | FLAG_GZIP | FLAG_CHUNKED | (1 << 11))
    unknown_flag = fixed_crc(unknown_flag)

    header_cases.append(case(
        "container.header.decode.crc-tampered",
        "container.header.decode",
        "头部一个字节被改且未重算 CRC → 结构损坏",
        {"hex": tampered_crc(header_1, 10).hex()},
        {"ok": False, "errorCode": "PFB_E_HEADER_INVALID"},
        "CRC 先于字段语义校验。没有这一层，被篡改的头部可能被解释成"
        "「合法但奇怪的文件」，为后续攻击铺路。",
        ["security", "format"],
    ))
    header_cases.append(case(
        "container.header.decode.magic-wrong",
        "container.header.decode",
        "魔数不符 → 不是本格式",
        {"hex": (b"PFB0OK\x01\x00" + header_1[8:]).hex()},
        {"ok": False, "errorCode": "PFB_E_MAGIC"},
        "选错文件的第一道分流；必须在读任何参数之前拒绝。",
        ["security", "format"],
    ))
    header_cases.append(case(
        "container.header.decode.version-too-new",
        "container.header.decode",
        "formatVersion=2（CRC 正确）→ 版本不兼容",
        {"hex": bytes(version_bumped).hex()},
        {"ok": False, "errorCode": "PFB_E_VERSION_UNSUPPORTED"},
        "CRC 修好之后版本分支才轮得到 —— 这条向量确认两个分支互不遮蔽。",
        ["forward-compat", "format"],
    ))
    header_cases.append(case(
        "container.header.decode.unknown-flag-bit",
        "container.header.decode",
        "未知 flag 位（bit11，CRC 正确）→ 拒绝解析",
        {"hex": bytes(unknown_flag).hex()},
        {"ok": False, "errorCode": "PFB_E_HEADER_INVALID"},
        "未知位意味着「来自更新的次版本」。本实现无法安全解释它，"
        "静默忽略会把未知语义当成已知语义。",
        ["forward-compat", "security"],
    ))

    # ---------- container_layout ----------
    file_multi = seal(payload_multi, PASSWORD, FIXED_KDF, SALT, NONCE_PREFIX,
                      flags_plain, 1, VOLUME_SET_ID)
    file_single = seal(payload_single, PASSWORD, FIXED_KDF, SALT, NONCE_PREFIX,
                       flags_plain, 1, VOLUME_SET_ID)
    chunk_size = 1024
    boxes = []
    off = 128
    aead = AESGCM(kdf_key(FIXED_KDF, PASSWORD, SALT))
    aad_base_multi = hashlib.sha256(file_multi[0:128]).digest()
    prev_tag = b"\x00" * 32
    for idx in range(3):
        (clen,) = struct.unpack(">I", file_multi[off:off + 4])
        nonce = file_multi[off + 4:off + 16]
        box = file_multi[off + 16:off + 4 + 12 + clen]
        plain = aead.decrypt(nonce, box, aad_base_multi + struct.pack(">I", idx) + prev_tag)
        assert len(plain) == clen - 16
        boxes.append(box)
        prev_tag = box[-16:]
        off += 4 + 12 + clen

    layout_cases = [
        case(
            "container.layout.slice.multi-chunk",
            "container.layout.slice",
            "3 块文件（末块不满）的逐段切分指纹",
            {"hex": file_multi.hex()},
            {
                "ok": True,
                "value": {
                    "fileLength": len(file_multi),
                    "chunkCount": 3,
                    "saltHex": SALT.hex(),
                    "noncePrefixHex": NONCE_PREFIX.hex(),
                    "firstChunkNonceHex": (NONCE_PREFIX + b"\x00" * 4).hex(),
                    "volumeSetIdHex": VOLUME_SET_ID.hex(),
                    "volumeIndex": 1,
                    "volumeTotal": 1,
                    "setDigestHex": "00" * 32,
                    "contentDigestHex": file_multi[-32:].hex(),
                    "chunkPlainLengths": [1024, 1024, 452],
                    "chunkNonceHexs": [(NONCE_PREFIX + struct.pack(">I", i)).hex() for i in range(3)],
                    "saltSha256": hashlib.sha256(SALT).hexdigest(),
                    "chunkBoxesSha256": [hashlib.sha256(b).hexdigest() for b in boxes],
                },
            },
            "切分必须把字节放进正确的区段：长度对了但区段错位只有内容指纹能抓到。",
            ["format"],
        ),
        case(
            "container.layout.slice.single-chunk",
            "container.layout.slice",
            "单块文件的切分",
            {"hex": file_single.hex()},
            {
                "ok": True,
                "value": {
                    "fileLength": len(file_single),
                    "chunkCount": 1,
                    "saltHex": SALT.hex(),
                    "noncePrefixHex": NONCE_PREFIX.hex(),
                    "firstChunkNonceHex": (NONCE_PREFIX + b"\x00" * 4).hex(),
                    "volumeSetIdHex": VOLUME_SET_ID.hex(),
                    "volumeIndex": 1,
                    "volumeTotal": 1,
                    "setDigestHex": "00" * 32,
                    "contentDigestHex": file_single[-32:].hex(),
                    "chunkPlainLengths": [len(payload_single)],
                    "chunkNonceHexs": [(NONCE_PREFIX + struct.pack(">I", 0)).hex()],
                    "saltSha256": hashlib.sha256(SALT).hexdigest(),
                    "chunkBoxesSha256": [
                        # 单块的 box 从 128+4+12=144 起，长度 = 明文 + 16 tag。
                        hashlib.sha256(file_single[144:144 + len(payload_single) + 16]).hexdigest(),
                    ],
                },
            },
            "载荷小于块大小时也是一分块结构（chunkCount=1），不是「无分块」。"
            "container 单块与多块共用同一条解包路径。",
            ["format"],
        ),
        case(
            "container.layout.slice.truncated",
            "container.layout.slice",
            "截断文件 → 长度不足",
            {"hex": file_multi[:-10].hex()},
            {"ok": False, "errorCode": "PFB_E_TRUNCATED"},
            "网盘同步未完成的典型症状。必须在读任何参数之前拒绝。",
            ["security", "format"],
        ),
        case(
            "container.layout.slice.extra-trailing-byte",
            "container.layout.slice",
            "尾部多一个字节 → 拒绝（未受保护的私货）",
            {"hex": (file_multi + b"\x00").hex()},
            {"ok": False, "errorCode": "PFB_E_HEADER_INVALID"},
            "contentDigest 只覆盖到 trailer 之前，多出的字节不受任何完整性保护 ——"
            "放行它等于给「在文件末尾夹带私货」留口子。",
            ["security", "format"],
        ),
    ]

    # ---------- container_digest ----------
    file_tampered_ct = bytearray(file_single)
    file_tampered_ct[200] ^= 0x01
    file_tampered_ct = bytes(file_tampered_ct)
    file_tampered_hdr = bytearray(file_single)
    file_tampered_hdr[10] ^= 0x01
    file_tampered_hdr = bytes(file_tampered_hdr)
    file_tampered_trailer = bytearray(file_single)
    file_tampered_trailer[-1] ^= 0x01
    file_tampered_trailer = bytes(file_tampered_trailer)

    digest_cases = [
        case(
            "container.digest.verify.ok",
            "container.digest.verify",
            "未改动文件：contentDigest 一致",
            {"hex": file_single.hex()},
            {
                "ok": True,
                "value": {
                    "matches": True,
                    "computedDigestHex": file_single[-32:].hex(),
                    "declaredDigestHex": file_single[-32:].hex(),
                },
            },
            "免密完整性的正向基线：损坏判定先于密码校验 —— 用户还没输密码"
            "就知道文件坏了，而不是输完密码才被告知「打不开」。",
            ["security"],
        ),
        case(
            "container.digest.verify.ciphertext-tampered",
            "container.digest.verify",
            "密文区改一字节 → 摘要不符（文件损坏，无需密码即判定）",
            {"hex": file_tampered_ct.hex()},
            {
                "ok": True,
                "value": {
                    "matches": False,
                    "computedDigestHex": hashlib.sha256(file_tampered_ct[48:-32]).hexdigest(),
                    "declaredDigestHex": file_single[-32:].hex(),
                },
            },
            "这是「损坏」与「密码错」能区分的全部依据：摘要对密文计算，"
            "不泄漏明文信息，却能在拿密码之前拦住损坏的文件。",
            ["security"],
        ),
        case(
            "container.digest.verify.header-tampered-outside-coverage",
            "container.digest.verify",
            "固定头改一字节 → 摘要仍相符（固定头是 CRC 的辖区）",
            {"hex": file_tampered_hdr.hex()},
            {
                "ok": True,
                "value": {
                    "matches": True,
                    "computedDigestHex": file_single[-32:].hex(),
                    "declaredDigestHex": file_single[-32:].hex(),
                },
            },
            "覆盖边界本身是契约：contentDigest 覆盖 [48..长度-32)，固定头由 "
            "headerCrc32 负责。两者的分工被这条向量显式钉死 —— 若有人把摘要"
            "改成覆盖整文件或漏掉变量区，这里会立刻变红。",
            ["security", "format"],
        ),
        case(
            "container.digest.verify.trailer-tampered",
            "container.digest.verify",
            "文件尾声明值被改 → 不符，计算值不变",
            {"hex": file_tampered_trailer.hex()},
            {
                "ok": True,
                "value": {
                    "matches": False,
                    "computedDigestHex": file_single[-32:].hex(),
                    "declaredDigestHex": file_tampered_trailer[-32:].hex(),
                },
            },
            "两个值都要比对：只断言布尔值的话，「无论如何都返回 false」的实现"
            "能让全部反例通过。",
            ["security"],
        ),
    ]

    # ---------- container_file ----------
    file_seal_single = seal(payload_single, PASSWORD, FIXED_KDF, SALT, NONCE_PREFIX,
                            flags_plain, 1, VOLUME_SET_ID)
    file_seal_multi = seal(payload_multi, PASSWORD, FIXED_KDF, SALT, NONCE_PREFIX,
                           flags_plain, 1, VOLUME_SET_ID)

    def aad_chain(blob: bytes) -> list[str]:
        aads = []
        base = hashlib.sha256(blob[0:128]).digest()
        prev_tag = b"\x00" * 32
        off = 128
        idx = 0
        while off < len(blob) - 32:
            (clen,) = struct.unpack(">I", blob[off:off + 4])
            aads.append((base + struct.pack(">I", idx) + prev_tag).hex())
            prev_tag = blob[off + 16 + clen - 16:off + 16 + clen]
            off += 4 + 12 + clen
            idx += 1
        return aads

    def wrong_password_file_error(password: str, blob: bytes, salt: bytes) -> dict:
        return {"ok": False, "errorCode": "PFB_E_AUTH_FAILED"}

    file_cases = [
        case(
            "container.file.seal.single-chunk",
            "container.file.seal",
            "完整封包（KDF + 单块 + 链式 AAD + 摘要）的字节级快照",
            {
                "password": PASSWORD,
                "kdf": FIXED_KDF,
                "saltHex": SALT.hex(),
                "noncePrefixHex": NONCE_PREFIX.hex(),
                "payloadHex": payload_single.hex(),
                "flagGzip": False,
                "flagHasAttachments": False,
                "flagMultiVolume": False,
                "flagIncremental": False,
                "chunkPlainSizeKiB": 1,
                "volumeSetIdHex": VOLUME_SET_ID.hex(),
            },
            {
                "ok": True,
                "value": {
                    "fileHex": file_seal_single.hex(),
                    "fileSha256": hashlib.sha256(file_seal_single).hexdigest(),
                    "contentDigestHex": file_seal_single[-32:].hex(),
                    "chunkCount": 1,
                    "plaintextLength": len(payload_single),
                    "aadHexs": aad_chain(file_seal_single),
                },
            },
            "附录 B「固定随机源」的落地：salt / noncePrefix / volumeSetId 全部固定，"
            "KDF 与 GCM 的期望值来自 Python 独立实现。这条向量证明的是"
            "「Dart 能复现第三方实现算出的完整文件」，是格式开放性的机器判据。",
            ["crypto", "security", "format"],
        ),
        case(
            "container.file.seal.multi-chunk",
            "container.file.seal",
            "2500 字节载荷 → 3 块（1024/1024/452），链式 AAD 三条快照",
            {
                "password": PASSWORD,
                "kdf": FIXED_KDF,
                "saltHex": SALT.hex(),
                "noncePrefixHex": NONCE_PREFIX.hex(),
                "payloadHex": payload_multi.hex(),
                "flagGzip": False,
                "flagHasAttachments": False,
                "flagMultiVolume": False,
                "flagIncremental": False,
                "chunkPlainSizeKiB": 1,
                "volumeSetIdHex": VOLUME_SET_ID.hex(),
            },
            {
                "ok": True,
                "value": {
                    "fileHex": file_seal_multi.hex(),
                    "fileSha256": hashlib.sha256(file_seal_multi).hexdigest(),
                    "contentDigestHex": file_seal_multi[-32:].hex(),
                    "chunkCount": 3,
                    "plaintextLength": len(payload_multi),
                    "aadHexs": aad_chain(file_seal_multi),
                },
            },
            "首块 AAD 的 prevTag 是 32 个 0x00（规格原文），其后才是上一块的 "
            "16 字节 tag —— 这条不对称被三条 AAD 快照逐字节锁死。",
            ["crypto", "security", "format"],
        ),
        case(
            "container.file.open.ok",
            "container.file.open",
            "正确密码解出原文",
            {
                "fileHex": file_seal_single.hex(),
                "password": PASSWORD,
                "kdf": FIXED_KDF,
                "saltHex": SALT.hex(),
            },
            {
                "ok": True,
                "value": {"payloadHex": payload_single.hex(), "payloadLength": len(payload_single)},
            },
            "往返正向基线。",
            ["crypto"],
        ),
        case(
            "container.file.open.wrong-password",
            "container.file.open",
            "密码错误 → 认证失败（文件本身完好）",
            {
                "fileHex": file_seal_single.hex(),
                "password": WRONG_PASSWORD,
                "kdf": FIXED_KDF,
                "saltHex": SALT.hex(),
            },
            {"ok": False, "errorCode": "PFB_E_AUTH_FAILED"},
            "三态分流的第三态：CRC 与摘要都过、GCM 认证失败 ⇒ 密码错。"
            "用户看到的提示必须是「密码不正确」，而不是「文件损坏」。",
            ["crypto", "security"],
        ),
        case(
            "container.file.open.ciphertext-tampered",
            "container.file.open",
            "密文被改 → 免密摘要先挡（PFB_E_DIGEST_MISMATCH，不是认证失败）",
            {
                "fileHex": file_tampered_ct.hex(),
                "password": PASSWORD,
                "kdf": FIXED_KDF,
                "saltHex": SALT.hex(),
            },
            {"ok": False, "errorCode": "PFB_E_DIGEST_MISMATCH"},
            "分流顺序即用户体验：损坏的文件绝不能被报告成「密码错」——"
            "那会让用户疯狂重试一个永远打不开的文件。",
            ["security"],
        ),
        case(
            "container.file.open.header-crc-tampered",
            "container.file.open",
            "头部被改 → CRC 先挡（PFB_E_HEADER_INVALID）",
            {
                "fileHex": file_tampered_hdr.hex(),
                "password": PASSWORD,
                "kdf": FIXED_KDF,
                "saltHex": SALT.hex(),
            },
            {"ok": False, "errorCode": "PFB_E_HEADER_INVALID"},
            "三道防线各司其职：CRC 管头部、contentDigest 管密文、GCM 管密钥。",
            ["security"],
        ),
    ]

    # ---------- container_constants（发布常量快照） ----------
    # 期望值来源：规格 §3.3 人工转录（与 NIST 锚点同理）。maxPlaintextLength
    # 规格未定死数值，2026-09-17 与实现同步固定为 1 TiB（u64 头字段的应用侧
    # 抗 DoS 上限）—— 写入向量即发布承诺，改动它 = 破坏兼容。
    constants_cases = [
        case(
            "container.format.constants.v1",
            "container.format.constants",
            "§3.3 容器格式全部发布常量",
            {},
            {
                "ok": True,
                "value": {
                    "magicHex": MAGIC.hex(),
                    "headerSize": 128,
                    "fixedHeaderSize": 48,
                    "trailerSize": 32,
                    "payloadOffset": 128,
                    "formatVersion": 1,
                    "minReaderVersion": 1,
                    "saltLength": 16,
                    "noncePrefixLength": 8,
                    "nonceLength": 12,
                    "tagLength": 16,
                    "volumeSetIdLength": 8,
                    "setDigestLength": 32,
                    "trailerDigestLength": 32,
                    "defaultChunkPlainSizeKiB": 1024,
                    "maxVolumes": 64,
                    "maxPlaintextLength": 1099511627776,
                    "bitAesGcm": 1,
                    "bitGzip": 2,
                    "bitChunked": 4,
                    "bitHasAttachments": 8,
                    "bitMultiVolume": 16,
                    "bitIncremental": 32,
                    "knownFlagsMask": 63,
                    "kdfArgon2id": 1,
                    "aeadAes256Gcm": 1,
                },
            },
            "格式常量一旦发布就不可更改：这份快照是「不可更改」的机器判据 —— "
            "任何常量漂移都会让用户已导出的备份失去可读性，且静默发生。",
            ["format", "security"],
        ),
    ]

    return {
        "container_constants.json": {
            "schemaVersion": 1,
            "suite": "container_constants",
            "title": "PFB 容器格式发布常量（§3.3）",
            "description": "魔数、头部布局偏移、长度约束、featureFlags 位、算法 ID 的"
                           "全部发布常量。期望值为规格 §3.3 的人工转录。",
            "cases": constants_cases,
        },
        "container_header.json": {
            "schemaVersion": 1,
            "suite": "container_header",
            "title": "PFB 分块容器文件头（§3.3，2026-09-17 裁决的唯一 v1）",
            "description": "锁定 128 字节头部的字节布局（48 固定 + 变量区）、CRC32、"
                           "featureFlags 位语义与四类错误分流。期望值由 Python 独立实现生成。",
            "cases": header_cases,
        },
        "container_layout.json": {
            "schemaVersion": 1,
            "suite": "container_layout",
            "title": "PFB 容器布局切分",
            "description": "按 §3.3 切分密文区（chunkLen + chunkNonce + box），"
                           "逐段指纹证明字节落在正确区段；截断与尾部私货被拒绝。",
            "cases": layout_cases,
        },
        "container_digest.json": {
            "schemaVersion": 1,
            "suite": "container_digest",
            "title": "PFB 内容摘要（免密完整性）",
            "description": "contentDigest = SHA256(文件[48..长度-32])：覆盖盐起到密文区末尾；"
                           "固定头的完整性由 headerCrc32 负责。覆盖边界本身是契约。",
            "cases": digest_cases,
        },
        "container_file.json": {
            "schemaVersion": 1,
            "suite": "container_file",
            "title": "PFB 完整文件字节级断言（附录 B 的 pfb-file）",
            "description": "固定随机源（salt/noncePrefix/volumeSetId）下的完整封包与解包："
                           "KDF + 分块 + 链式 AAD + 摘要全链路由 Python 独立实现核对；"
                           "三态错误（密码错 / 损坏 / 结构非法）各有专属向量。",
            "cases": file_cases,
        },
    }


def self_check() -> None:
    """生成器内部自检：封包后必须能用独立路径解开，篡改必须被拦。"""
    payload = pattern(2500, 3)
    blob = seal(payload, PASSWORD, FIXED_KDF, SALT, NONCE_PREFIX,
                FLAG_AESGCM | FLAG_CHUNKED, 1, VOLUME_SET_ID)
    assert open_pfb(blob, PASSWORD, FIXED_KDF, SALT) == payload
    bad = bytearray(blob)
    bad[300] ^= 0x01
    try:
        open_pfb(bytes(bad), PASSWORD, FIXED_KDF, SALT)
        raise AssertionError("篡改文件必须被摘要拦住")
    except AssertionError as exc:
        if "content digest" not in str(exc):
            raise
    print("self-check: ok (seal→open 往返 + 篡改拦截)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="写入 test_vectors/v1/")
    parser.add_argument("--check", action="store_true", help="只核对已写入的文件")
    args = parser.parse_args()
    if args.write and args.check:
        print("--write 与 --check 互斥", file=sys.stderr)
        return 2

    self_check()
    suites = build_suites()
    total = 0
    for filename, suite in suites.items():
        total += len(suite["cases"])
        if args.write:
            path = VECTOR_DIR / filename
            path.write_text(json.dumps(suite, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            print(f"wrote {path} ({len(suite['cases'])} cases)")
        elif args.check:
            path = VECTOR_DIR / filename
            if not path.exists():
                print(f"missing {path}", file=sys.stderr)
                return 1
            existing = json.loads(path.read_text(encoding="utf-8"))
            if existing != suite:
                print(f"MISMATCH {filename}", file=sys.stderr)
                return 1
            print(f"checked {filename} ({len(suite['cases'])} cases)")
    if not args.write and not args.check:
        print(json.dumps(suites, ensure_ascii=False, indent=2))
    print(f"total {total} cases across {len(suites)} suites")
    return 0


if __name__ == "__main__":
    sys.exit(main())

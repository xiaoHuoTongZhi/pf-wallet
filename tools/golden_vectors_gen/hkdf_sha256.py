#!/usr/bin/env python3
"""HKDF-SHA256 黄金向量的生成器 —— 独立参考实现。

## 为什么这个脚本必须用另一套实现

`packages/pf_testkit/bin/vector_forge.dart` 做的是相反的事：它用**本仓实现**
跑一遍向量、把实际输出落盘供人对照，并且显式拒绝写入 `test_vectors/`。
理由是让实现给自己出考卷，等于取消考试。

本脚本是它的对偶：这里算期望值用的是 **Python 标准库的 `hmac` / `hashlib`**，
与 Dart 侧（`package:crypto`）既不同语言也不同代码库。所以它写进
`test_vectors/v1/` 的期望值才具备「独立」的含义。

## 三层核对，缺一层都不算数

1. **RFC 逐字抄录**：脚本内写死了 RFC 5869 附录 A 中 Test Case 1/2/3 的
   PRK 与 OKM，并用标准库复算，两者必须逐字节相同。这一步证明**参考实现本身是对的** ——
   若跳过它就直接去算新用例，那新用例的正确性没有任何东西背书。
2. **第二套独立实现**：环境里若装了 `cryptography`，再用它的
   `hazmat.primitives.kdf.hkdf.HKDF` 复算全部用例。装不上不算失败（只打印提示），
   但能装上就多一层保险。
3. **RFC 未覆盖的边界**：L=1 / L=32 / L=33 / L=64 与「真实用途」那一组
   （MK → DBKey）。这些是 RFC 没有举例子、却最容易写错的地方：
   计数器是 1 起始、最后一块要截断、`info` 为空不等于「用零填充」。

用法：

    python tools/golden_vectors_gen/hkdf_sha256.py            # 打印 JSON 到标准输出
    python tools/golden_vectors_gen/hkdf_sha256.py --write    # 写入 test_vectors/v1/
    python tools/golden_vectors_gen/hkdf_sha256.py --check    # 只做核对，不输出向量

退出码：0 全部一致；1 核对失败（说明参考实现或抄录有误）；2 用法错误。
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# 常数
# ---------------------------------------------------------------------------

HASH_NAME = "sha256"
HASH_LEN = 32  # SHA-256 输出字节数
BLOCK_LEN = 64  # SHA-256 压缩函数的块长，HMAC 补位到它

# 项目实际使用的 info 标签。来源：方案 §A「HKDF info 标签」。
# 改这个字符串 = 已导出的备份文件全部解不开，因此它属于格式契约，不是文案。
INFO_DB_KEY = "pf/db/1"

# 真实用途那一组里的输入密钥材料（MK）。
# 真实运行时 MK 是 32 字节随机数；这里是固定值，因为向量不允许有不确定源。
TEST_MK = "42" * 32


def hkdf_extract(salt: bytes, ikm: bytes) -> bytes:
    """RFC 5869 §2.2：PRK = HMAC-Hash(salt, IKM)。

    注意 salt 为空时**不必**特殊处理：RFC 5869 说「未提供则设为 HashLen 个 0x00」，
    而 HMAC 会把长度短于块长的密钥右侧补零到块长（64 字节），
    于是「空密钥」与「32 个 0x00 字节密钥」补位后完全相同。
    两种读法在这里给出同一个 PRK —— 这一点由 Test Case 3 与单测共同守住。
    """
    return hmac.new(salt, ikm, hashlib.sha256).digest()


def hkdf_expand(prk: bytes, info: bytes, length: int) -> bytes:
    """RFC 5869 §2.3：T(1..N) = HMAC-Hash(PRK, T(i-1) | info | i)，OKM 为前缀。

    三个容易写错的点，本函数刻意写得不「简洁」：
      - 计数器 i 从 **1** 起（不是 0），且只占 1 个字节；
      - 第 1 块的 T(0) 是**空**，不是全零；
      - 最后一块按需**截断**，多出来的字节必须丢掉。
    """
    if length <= 0:
        raise ValueError("L 必须为正")
    if length > 255 * HASH_LEN:
        raise ValueError("L 不得超过 255*HashLen")

    blocks = (length + HASH_LEN - 1) // HASH_LEN
    previous = b""
    okm = b""
    for counter in range(1, blocks + 1):
        previous = hmac.new(prk, previous + info + bytes([counter]), hashlib.sha256).digest()
        okm += previous
    return okm[:length]


def hkdf(ikm: bytes, salt: bytes, info: bytes, length: int) -> tuple[bytes, bytes]:
    """一步到位，返回 (prk, okm)。"""
    prk = hkdf_extract(salt, ikm)
    return prk, hkdf_expand(prk, info, length)


# ---------------------------------------------------------------------------
# 第一层：RFC 5869 附录 A 的逐字抄录
# ---------------------------------------------------------------------------

# 只抄 PRK / OKM 这类**结果**，输入仍在下面用 test_case() 显式构造 ——
# 抄输入等于抄自己的理解，抄结果才能验证自己的理解。
RFC5869_APPENDIX_A = {
    1: {
        "prk": "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5",
        "okm": (
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
            "34007208d5b887185865"
        ),
    },
    2: {
        "prk": "06a6b88c5853361a06104c9ceb35b45cef760014904671014a193f40c15fc244",
        "okm": (
            "b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c"
            "59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71"
            "cc30c58179ec3e87c14c01d5c1f3434f1d87"
        ),
    },
    3: {
        "prk": "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04",
        "okm": (
            "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d"
            "9d201395faa4b61a96c8"
        ),
    },
}


def rfc_case(number: int) -> tuple[bytes, bytes, bytes, int]:
    """RFC 5869 附录 A 的三组输入（sdk 名称：ikm / salt / info / L）。"""
    ikm = bytes.fromhex("0b" * 22)
    if number == 1:
        return ikm, bytes.fromhex("000102030405060708090a0b0c"), bytes.fromhex("f0f1f2f3f4f5f6f7f8f9"), 42
    if number == 2:
        return (
            bytes(range(0x00, 0x50)),
            bytes(range(0x60, 0xB0)),
            bytes(range(0xB0, 0x100)),
            82,
        )
    if number == 3:
        return ikm, b"", b"", 42
    raise ValueError(f"没有 Test Case {number}")


def verify_reference() -> None:
    """第一层核对：标准库的结论必须与 RFC 抄录的结论一致。"""
    for number, expected in RFC5869_APPENDIX_A.items():
        ikm, salt, info, length = rfc_case(number)
        prk, okm = hkdf(ikm, salt, info, length)
        if prk.hex() != expected["prk"]:
            raise SystemExit(
                f"✗ RFC 5869 Test Case {number} 的 PRK 不一致\n"
                f"  抄录：{expected['prk']}\n  标准库：{prk.hex()}"
            )
        if okm.hex() != expected["okm"]:
            raise SystemExit(
                f"✗ RFC 5869 Test Case {number} 的 OKM 不一致\n"
                f"  抄录：{expected['okm']}\n  标准库：{okm.hex()}"
            )
    print("✓ 第一层：标准库复算与 RFC 5869 附录 A 逐字节一致（Test Case 1 / 2 / 3）")


def verify_with_cryptography(cases: list[dict]) -> bool:
    """第二层核对（尽力而为）：用 `cryptography` 复算全部用例。

    这里有个容易踩的坑，值得写下来：`cryptography` 的 `HKDF` 是**一步到底**的
    （内部先 extract 再 expand），并没有公开「只做 extract」的入口。
    所以用它取 PRK 必须退回到 `hmac.HMAC`，取 OKM 则用 `HKDFExpand`（它接受的正是 PRK）。
    若这里图省事写成 `HKDF(length=32).derive(ikm)`，拿到的是 OKM 的第 1 块而不是 PRK，
    核对会**报假警**（而且看起来像是向量错了，而不是探针错了）。
    """
    try:
        from cryptography.hazmat.primitives import hashes, hmac as ct_hmac  # noqa: PLC0415
        from cryptography.hazmat.primitives.kdf.hkdf import HKDFExpand  # noqa: PLC0415
    except ImportError:
        print("· 第二层：环境里没有 `cryptography`，跳过（不影响结论，只少一层保险）")
        return False

    def ct_prk(salt: bytes, ikm: bytes) -> bytes:
        mac = ct_hmac.HMAC(salt, hashes.SHA256())
        mac.update(ikm)
        return mac.finalize()

    for case in cases:
        inp = case["input"]
        want = case["expect"].get("value", {})
        if inp.get("ikmHex") is not None:
            got = ct_prk(bytes.fromhex(inp["saltHex"]), bytes.fromhex(inp["ikmHex"])).hex()
            if got != want["prkHex"]:
                raise SystemExit(f"✗ `cryptography` 复算 PRK 不一致：{case['id']}")
        else:
            got = HKDFExpand(
                algorithm=hashes.SHA256(),
                length=inp["length"],
                info=bytes.fromhex(inp.get("infoHex", "")),
            ).derive(bytes.fromhex(inp["prkHex"])).hex()
            if got != want["okmHex"]:
                raise SystemExit(f"✗ `cryptography` 复算 OKM 不一致：{case['id']}")
    print(f"✓ 第二层：`cryptography` 复算 {len(cases)} 条用例，全部一致")
    return True


# ---------------------------------------------------------------------------
# 向量用例
# ---------------------------------------------------------------------------

_TAGS_RFC = ["crypto"]
_TAGS_BOUNDARY = ["crypto", "boundary"]


def build_cases() -> list[dict]:
    cases: list[dict] = []

    def extract_case(
        case_id: str,
        title: str,
        salt_hex: str,
        ikm_hex: str,
        notes: str,
        tags: list[str],
    ) -> None:
        prk = hkdf_extract(bytes.fromhex(salt_hex), bytes.fromhex(ikm_hex))
        cases.append(
            {
                "id": case_id,
                "kind": "kdf.hkdf.extract",
                "title": title,
                "milestone": "M1",
                "input": {"saltHex": salt_hex, "ikmHex": ikm_hex},
                "expect": {
                    "ok": True,
                    "value": {"prkHex": prk.hex(), "prkLength": HASH_LEN},
                },
                "notes": notes,
                "tags": tags,
            }
        )

    def expand_case(
        case_id: str,
        title: str,
        prk_hex: str,
        info_hex: str,
        length: int,
        notes: str,
        tags: list[str],
    ) -> None:
        okm = hkdf_expand(bytes.fromhex(prk_hex), bytes.fromhex(info_hex), length)
        blocks = (length + HASH_LEN - 1) // HASH_LEN
        cases.append(
            {
                "id": case_id,
                "kind": "kdf.hkdf.expand",
                "title": title,
                "milestone": "M1",
                "input": {"prkHex": prk_hex, "infoHex": info_hex, "length": length},
                "expect": {
                    "ok": True,
                    "value": {"okmHex": okm.hex(), "okmLength": length, "blocks": blocks},
                },
                "notes": notes,
                "tags": tags,
            }
        )

    ikm1, salt1, info1, l1 = rfc_case(1)
    ikm2, salt2, info2, l2 = rfc_case(2)
    ikm3, salt3, info3, l3 = rfc_case(3)
    prk1 = RFC5869_APPENDIX_A[1]["prk"]
    prk2 = RFC5869_APPENDIX_A[2]["prk"]
    prk3 = RFC5869_APPENDIX_A[3]["prk"]

    # ---- extract ----
    extract_case(
        "kdf.hkdf.extract.rfc5869-case1",
        "RFC 5869 Test Case 1 · 提取阶段",
        salt1.hex(),
        ikm1.hex(),
        "RFC 官方用例。PRK 是后续 expand 的唯一输入，所以它自己必须先被钉死："
        "如果 PRK 错而 expand 正好也把错误「一致地」传下去，只测整体输出是看不出来的。",
        _TAGS_RFC,
    )
    extract_case(
        "kdf.hkdf.extract.rfc5869-case2",
        "RFC 5869 Test Case 2 · 盐长于 HMAC 块长",
        salt2.hex(),
        ikm2.hex(),
        f"盐 80 字节，已超过 SHA-256 的块长 {BLOCK_LEN} 字节。HMAC 对超长密钥的处理是"
        "「先做一次摘要再当密钥用」—— 少了这一步，结果会与任何其他实现都不兼容，"
        "而且是静默不兼容：本地自测全过，跨设备互换备份时才炸。",
        _TAGS_RFC,
    )
    extract_case(
        "kdf.hkdf.extract.rfc5869-case3-empty-salt",
        "RFC 5869 Test Case 3 · 空盐（缺省语义）",
        "",
        ikm3.hex(),
        "RFC 5869 §2.2 定义 salt 缺省为「HashLen 个 0x00」。本条锁住的是**结果**："
        "空盐得到的 PRK 必须是这一个。"
        "补充一句免得有人误以为这里能区分两种读法：HMAC 会把短于块长的密钥补零到块长，"
        "所以「空密钥」与「32 个 0x00 字节的密钥」补位后逐字节相同，两种读法必然同值。"
        "换言之本条挡不住「把空盐当作空密钥直接塞进非 HMAC 构造」这种改法 ——"
        "那种改法由 `hkdf_test.dart` 里的等价性单测挡住。",
        _TAGS_RFC + ["security"],
    )
    extract_case(
        "kdf.hkdf.extract.db-key",
        "真实用途：主密钥 → DBKey 的前半段",
        "",
        TEST_MK,
        f"本项目里 HKDF 的真实用法：DBKey = HKDF-SHA256(MK, salt=空, info=\"{INFO_DB_KEY}\")。"
        "MK 在真实运行时是 32 字节随机数，向量里必须换成固定值 —— 向量不允许有不确定源。"
        "写这一条不是为了测 HKDF（上面三条已经测了），而是把"
        "「主密钥 → DBKey」这条链路的**确切字节**固定下来："
        "方案 §7.4 说改主密码只需重算 MK 之后这一段，DBKey 不变、数据库一个字节都不用动。"
        "那个承诺成立的前提正是这条链表在两侧都算出同一串字节。",
        _TAGS_RFC + ["security"],
    )

    # ---- expand ----
    expand_case(
        "kdf.hkdf.expand.rfc5869-case1",
        "RFC 5869 Test Case 1 · 扩展阶段",
        prk1,
        info1.hex(),
        l1,
        "与 extract 的 case1 用同一个 PRK，两条合起来就是完整的 HKDF。"
        "L=42 不是块长 32 的整数倍，因此它同时钉住了「最后一块要截断」。",
        _TAGS_RFC,
    )
    expand_case(
        "kdf.hkdf.expand.rfc5869-case2",
        "RFC 5869 Test Case 2 · 长 info，三块",
        prk2,
        info2.hex(),
        l2,
        "L=82 需要 3 个块，是 RFC 给出的最长输出。计数器从 1 递增到 3，"
        "任何「计数器从 0 起」或「计数器写成多字节」的实现都会在这里现形 ——"
        "而这类 bug 在 L<=32 的用例里是看不出来的。",
        _TAGS_RFC,
    )
    expand_case(
        "kdf.hkdf.expand.rfc5869-case3-empty-info",
        "RFC 5869 Test Case 3 · 空 info",
        prk3,
        "",
        l3,
        "info 为空就是**空**，不做任何填充、也不退化成零字节串。"
        "注意这与 salt 的缺省语义相反：salt 空有定义好的替代值（32 个 0x00），"
        "info 空没有。把两者都按「补零」处理，是一条很自然的错误直觉。",
        _TAGS_RFC,
    )
    expand_case(
        "kdf.hkdf.expand.db-key",
        "真实用途：主密钥 → DBKey 的后半段",
        hkdf_extract(b"", bytes.fromhex(TEST_MK)).hex(),
        INFO_DB_KEY.encode("utf-8").hex(),
        HASH_LEN,
        f"接着上面 extract 那一条，输出 32 字节 DBKey。"
        f"info 是 UTF-8 编码后的 \"{INFO_DB_KEY}\"（{len(INFO_DB_KEY.encode('utf-8'))} 字节）—— "
        "用的是**字节**而非字符串，因为 info 一旦按不同平台/版本的编码规则处理，"
        "同一句话就会派生出不同的密钥，而错误只会在跨设备导入时暴露。",
        _TAGS_RFC + ["security"],
    )
    expand_case(
        "kdf.hkdf.expand.single-byte",
        "边界：最短输出 L=1",
        prk1,
        "",
        1,
        "L 的最小合法值是 1。它锁住「输出是第一块的前缀」这件事，"
        "顺带挡住「输出长度不足一块时补零到一块」这类会把长度搞错的实现。",
        _TAGS_BOUNDARY,
    )
    expand_case(
        "kdf.hkdf.expand.two-block-boundary",
        "边界：跨块 L=33",
        prk1,
        INFO_DB_KEY.encode("utf-8").hex(),
        HASH_LEN + 1,
        "L=33 只比一个块多 1 个字节，是最省字数的「跨块」用例："
        "它要求第 2 个块确实被算出来、且只取头 1 个字节。"
        "第 2 块的输入是 T(1) | info | 0x02 —— 少传 T(1) 或多传一个零字节都会在这里失败。",
        _TAGS_BOUNDARY,
    )
    expand_case(
        "kdf.hkdf.expand.exact-two-blocks",
        "边界：恰好两块 L=64",
        prk1,
        "",
        HASH_LEN * 2,
        "L=64 是块长的整数倍，最后一块**不截断**。"
        "与上一条配对，才能把「截断逻辑」与「计数逻辑」分开定位："
        "只测 L=33 的话，一处多留一个字节的实现会同时被截断和长度两个原因抓住。",
        _TAGS_BOUNDARY,
    )

    return cases


# ---------------------------------------------------------------------------
# 组装与输出
# ---------------------------------------------------------------------------

SUITE = "hkdf_sha256"

TITLE = "HKDF-SHA256 密钥扩展"

DESCRIPTION = (
    "RFC 5869 定义的 HKDF，用于把主密钥 MK 扩展成各用途密钥（DBKey 等）。"
    "选它是 M1 的第二个原语，理由是它**现在就有独立期望值可依**："
    "RFC 5869 附录 A 给出了三组官方向量，可以用另一套实现（Python 标准库）复算后再抄进这里，"
    "而不是等实现写完了让它自己产出期望值。"
)


def build_document(cases: list[dict]) -> dict:
    return {
        "schemaVersion": 1,
        "suite": SUITE,
        "title": TITLE,
        "description": DESCRIPTION,
        "cases": cases,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="生成 / 核对 HKDF-SHA256 黄金向量（独立参考实现：Python 标准库）",
    )
    parser.add_argument("--write", action="store_true", help="写入 test_vectors/v1/hkdf_sha256.json")
    parser.add_argument("--check", action="store_true", help="只核对，不打印向量")
    parser.add_argument("--out", default=None, help="输出路径（缺省 test_vectors/v1/<suite>.json）")
    args = parser.parse_args(argv)

    verify_reference()
    cases = build_cases()
    verify_with_cryptography(cases)

    for case in cases:
        validate_case_shape(case)

    document = build_document(cases)
    text = json.dumps(document, ensure_ascii=False, indent=2) + "\n"

    if args.check:
        print(f"✓ 核对完成：{len(cases)} 条用例，未写出任何文件")
        return 0

    if args.write or args.out:
        repo_root = Path(__file__).resolve().parents[2]
        target = (
            Path(args.out)
            if args.out
            else repo_root / "test_vectors" / "v1" / f"{SUITE}.json"
        )
        target.parent.mkdir(parents=True, exist_ok=True)
        write_lf(target, text)
        print(f"✓ 已写入 {target}（{len(cases)} 条用例）")
        return 0

    sys.stdout.write(text)
    return 0


def write_lf(target: Path, text: str) -> None:
    """按 LF 写盘，**不经过任何行尾转换**。

    这不是风格问题。`Path.write_text` 在 Windows 上会把 `\\n` 翻译成 `\\r\\n`，
    于是同一份生成脚本在 Windows 与 Linux 上产出的**字节不同**：
      - `git status` 会一直显示这个文件「已修改」而 `git diff` 为空（行尾差异）；
      - 而 `.gitattributes` 里 `test_vectors/** -text` 的本意正是
        「向量文件不做任何行尾改写」。
    直接写 bytes 是最省事也最不会出错的做法 —— 没有中间层可以出错。
    """
    target.write_bytes(text.encode("utf-8"))


def validate_case_shape(case: dict) -> None:
    """照着 test_vectors/schema/vector.schema.json 的约束自检。

    schema 由 Dart 侧的加载器执行；这里按同一套规则先拦一遍，
    是为了让「向量文件写错」在**生成时**就报错，而不是等到 CI 上由另一门语言报出来。
    """
    import re

    if not re.fullmatch(r"[a-z][a-zA-Z0-9]*(\.[a-z][a-zA-Z0-9-]*)+", case["id"]):
        raise SystemExit(f"✗ 用例 ID 不符合 schema 的命名约定：{case['id']}")
    if not re.fullmatch(r"M\d{1,2}", case["milestone"]):
        raise SystemExit(f"✗ milestone 不符合 M<数字>：{case['milestone']}")
    for tag in case.get("tags", []):
        if not re.fullmatch(r"[a-z][a-z0-9-]*", tag):
            raise SystemExit(f"✗ 标签不符合 schema：{tag}")
    expect = case["expect"]
    if expect.get("ok") is True and not expect.get("value"):
        raise SystemExit(f"✗ 成功形态的期望值不得为空：{case['id']}")
    if expect.get("ok") is False and not expect.get("errorCode"):
        raise SystemExit(f"✗ 失败形态必须写明 errorCode：{case['id']}")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""跨实现 PFB 校验：把「Python 独立实现解出来的四层」与「Dart 侧解出来的四层」对上。

## 这个脚本要回答的问题

黄金向量已经证明了「两套实现算出的**加密原语中间值**一致」（`aes256gcm.json` /
`argon2id.json` / `container_file.json` 的期望值全部由本目录之外的 Python 独立算出）。
但那证明的是**逐函数**的一致。

本脚本补的是**另一件**事：把一整个 `.pfb` 文件交给两套实现，各自从头走到尾，
把沿途**四层**的产物摆在一起比对：

| 层 | 绑定的对象 | 为什么单列这一层 |
|---|---|---|
| 1 | 文件字节 | 输入本身。它一变，下面全部跟着变 —— 先把它钉住，后续差异才有意义 |
| 2 | 压缩载荷（容器明文 = gzip 流） | 容器层的产出。AES-GCM 解出来的是**压缩后**的字节，`open_pfb` 的返回值就是它 |
| 3 | 记录行（解压后的 NDJSON 全区字节，逐行摘要） | 解压层的产出。**逐行**而不是只给全区摘要：只给全区摘要时，「两行对调、字节数不变」这类差异会被掩盖 |
| 4 | 逐条清单（每行键排序后的紧凑 JSON） | 解析层的产出。第 3 层绑的是**字节**，第 4 层绑的是**含义** —— 两者都能抓到对方抓不到的东西 |

为什么第 4 层绑「行」而不是绑「库表列」（默认值、派生的 dayKey、被丢弃的缓存余额）：
那是 §4.1 的规范，且已经由 `import.payload.decode.*` 向量核对过 —— 那边的期望值同样是
这套 Python 独立实现算的。在这里再抄一遍字段表，只会得到**第二张会与第一张分叉的表**，
而分叉那天不会有任何东西变红。

## 复用而不是复制

容器解密**只有一处实现**：`tools/golden_vectors_gen/container_pfb.py` 的 `open_pfb`。
本脚本 `import` 它，不复制。复制一份解密流程的代价不是多几十行，而是
「两份会分叉的 Argon2/AES 参数」—— 而分叉的表现是**校验通过但文件其实读不出来**，
那是这个脚本唯一不能有的失败。

`open_pfb` 的签名要求调用方给出 `kdf` 与 `salt`（它内部会断言这两者与头部一致）。
因此本脚本自己从头部**读**出这两个值再传回去 —— 这是调用约定，不是第二份解密实现。

## 与 Dart 侧的接口

Dart 侧 `pf info <file> --records --password-file <f> --out <file>` 产出**同样的规范文本**。
两份文本必须逐字节相同（CI 用 `diff` 判定）。规范文本里刻意**不含**文件名、路径、
实现名与时间戳 —— 路径是调用方的选择，不是被验对象的属性；带上它只会让
「换个目录跑」变成一次假失败。

## 四层的例外：第 2 层没有第三方锚点

`x.expect.json`（由 `--emit-fixture` 从被向量锁死的 fixture 里取出）能锚住
第 1、3 层与 contentHash / counts / recordCount —— 因为 fixture 记了这些值。
第 2 层（gzip 流）与第 4 层（规范化 JSON）没有第三方记录，它们**只**由
「Dart 与 Python 的 diff 为空」来绑定。这不是缺口，是分工：锚点来自 fixture 的地方
叫「与契约相符」，只由 diff 绑定的地方叫「两套实现相符」。

## 退出码

    0  四层全部相符（有 --expect 时，也全部等于期望值）
    1  业务结论为「否」：文件损坏、密码错、四层不符、与期望值不符
    2  用法错误或基础设施不可用（参数不对、文件读不到、缺依赖）
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import struct
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# 复用容器参考实现（不复制）
# ---------------------------------------------------------------------------

_HERE = Path(__file__).resolve()
_REPO_ROOT = _HERE.parents[2]
sys.path.insert(0, str(_REPO_ROOT / "tools" / "golden_vectors_gen"))

import container_pfb  # noqa: E402  —— 必须在上面的 sys.path 注入之后

DEFAULT_FIXTURE = _REPO_ROOT / "test_vectors" / "fixtures" / "import_samples.json"

#: 规范报告的首行。它同时是**格式版本**：将来若增删某一层，必须在这里改动，
#: 于是「两份文本的格式不同」会表现为 diff 的第一行就不一样 —— 而不是
#: 某一行对不上却看不出是「格式变了」还是「值错了」。
REPORT_HEADER = "pfb-cross-check format=1"

#: 头部里读 kdf / salt 所需的偏移（§3.3）。
#: 只读这两个值 —— 解密本身走 container_pfb.open_pfb。
_OFF_KDF_M_T = 16
_OFF_KDF_P_OUTLEN_SALTLEN = 24
_OFF_SALT = 48

EXIT_OK = 0
EXIT_NEGATIVE = 1
EXIT_TOOL_ERROR = 2


class Negative(Exception):
    """业务结论为「否」—— 文件读得懂结构但内容不成立（或期望值不符）。"""


class ToolError(Exception):
    """用法错误或基础设施不可用。"""


# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def split_lines(ndjson: bytes) -> tuple[list[bytes], list[int]]:
    """按 `\\n` 切行（并给出每行的起始偏移），丢掉**末尾那一个**空段。

    必须与 Dart 侧 `_splitLines` 逐字对应（`PayloadLineScanner` 的语义）：
    以换行结尾的文件切出来的是 N 行，不是 N+1 行；不以换行结尾时最后一行照常算一行。
    两者若不一致，第 3 层的行数与逐行摘要会整体错位 —— 而那正是它要拦的。

    偏移也要给出来，而不是回头用 `len(ndjson) - len(lines[-1])` 倒推：
    倒推的那个公式在「文件以换行结尾」时会差一个字节，而差一个字节的表现是
    contentHash 对不上 —— 会被误读成「文件被改过」。
    """
    lines: list[bytes] = []
    offsets: list[int] = []
    index = 0
    total = len(ndjson)
    while index < total:
        newline = ndjson.find(b"\n", index)
        end = total if newline == -1 else newline
        lines.append(ndjson[index:end])
        offsets.append(index)
        index = total if newline == -1 else newline + 1
    return lines, offsets


def canonical_json(line: bytes) -> str:
    """一行的规范 JSON：键递归排序、无多余空白、不转义非 ASCII。

    与 Dart 侧 `canonicalJsonBytes` 对应。JSON 里的**键序**不该有语义，
    但它是实现自由的产物（`jsonEncode` 与 `json.dumps` 的默认行为不同），
    所以第 4 层先把它归一，再比 —— 否则每个对象都会比出一处假差异。
    """
    try:
        obj = json.loads(line.decode("utf-8"))
    except UnicodeDecodeError as exc:
        raise Negative(f"记录行不是合法 UTF-8：{exc}") from exc
    except json.JSONDecodeError as exc:
        raise Negative(f"记录行不是合法 JSON：{exc}") from exc
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def load_password(path: Path) -> str:
    """读密码文件。

    剥离规则必须与 CLI 的 `decodePasswordBytes` 完全一致：UTF-8 BOM 与
    **末尾一个**换行（`echo secret > pw.txt` 会带上），**不做**整段 trim ——
    前后空格是密码的一部分。

    两者若不一致，两条路径喂给 KDF 的密码就不是同一个，四层会全红。
    这是刻意的：密码归一化规则本身也是跨实现的契约。
    """
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise ToolError(f"读不到密码文件 {path}：{exc}") from exc
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    if raw.endswith(b"\n"):
        raw = raw[:-1]
        if raw.endswith(b"\r"):
            raw = raw[:-1]
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ToolError(f"密码文件不是合法 UTF-8：{exc}") from exc


def read_kdf_and_salt(blob: bytes) -> tuple[dict[str, int], bytes]:
    """从头部取出 KDF 参数与盐 —— 只为满足 `open_pfb` 的调用约定。"""
    if len(blob) < 128:
        raise Negative(f"文件只有 {len(blob)} 字节，读不出头部")
    m, t = struct.unpack(">II", blob[_OFF_KDF_M_T : _OFF_KDF_M_T + 8])
    p, out_len, salt_len = struct.unpack(
        ">BBH", blob[_OFF_KDF_P_OUTLEN_SALTLEN : _OFF_KDF_P_OUTLEN_SALTLEN + 4]
    )
    salt = blob[_OFF_SALT : _OFF_SALT + salt_len]
    if len(salt) != salt_len:
        raise Negative("头部声明的盐长度超出了文件长度")
    kdf = {"m": m, "t": t, "p": p, "saltLength": salt_len, "outputLength": out_len}
    return kdf, salt


# ---------------------------------------------------------------------------
# 四层
# ---------------------------------------------------------------------------


def compute_layers(blob: bytes, password: str) -> dict[str, Any]:
    """走完整条路径并算出四层。任何一处不成立都抛 [Negative]。"""
    file_sha = sha256_hex(blob)

    kdf, salt = read_kdf_and_salt(blob)

    # ── 层 2：容器明文（gzip 流）────────────────────────────────────────
    try:
        plain = container_pfb.open_pfb(blob, password, kdf, salt)
    except AssertionError as exc:
        # open_pfb 的断言就是三道防线本身（头 CRC / contentDigest / nonce 顺序 /
        # 各块 GCM 认证）。把断言文本原样带出来，报告里才能看出是**哪一道**挡下的 ——
        # 这比「校验失败」四个字有用得多。
        raise Negative(f"容器层被拒（{exc or '断言失败'}）") from exc
    except Exception as exc:  # aes-gcm 认证失败等
        raise Negative(f"容器层被拒（{type(exc).__name__}: {exc}）") from exc

    plain_sha = sha256_hex(plain)

    # ── 层 3：解压后的 NDJSON 与逐行摘要 ────────────────────────────────
    try:
        ndjson = gzip.decompress(plain)
    except OSError as exc:
        raise Negative(f"GZIP 解压失败（{exc}）") from exc

    lines, offsets = split_lines(ndjson)
    if len(lines) < 2:
        raise Negative(f"记录行只有 {len(lines)} 行 —— manifest 与 end 行缺一不可")

    # ── 层 4：逐条清单 + 记录区摘要 ─────────────────────────────────────
    canonical = [canonical_json(line) for line in lines]

    # contentHash 覆盖「manifest 行之后、end 行之前」的全部字节（§4.1）。
    # 这里**按字节独立算一遍**，而不是读 manifest 里声明的那个值 ——
    # 读声明值等于让文件自己给自己出考卷。
    region_start = offsets[0] + len(lines[0]) + 1
    region_end = offsets[-1]
    if region_end < region_start:
        raise Negative("记录区边界异常（manifest 与 end 行之间不是合法区间）")
    region = ndjson[region_start:region_end]
    content_hash_hex = sha256_hex(region)

    manifest = json.loads(lines[0].decode("utf-8"))
    end_line = json.loads(lines[-1].decode("utf-8"))
    declared_content_hash = str(manifest.get("contentHash", "")).replace("sha256:", "")
    if declared_content_hash != content_hash_hex:
        raise Negative(
            "载荷 contentHash 不符："
            f"manifest 声明 {declared_content_hash}，按字节算出 {content_hash_hex}"
        )
    counts = manifest.get("counts")
    if not isinstance(counts, dict):
        raise Negative("manifest 缺少 counts 对象")

    return {
        "file_bytes": len(blob),
        "file_sha256": file_sha,
        "plain_bytes": len(plain),
        "plain_sha256": plain_sha,
        "ndjson_bytes": len(ndjson),
        "ndjson_sha256": sha256_hex(ndjson),
        "lines": lines,
        "canonical": canonical,
        "content_hash": f"sha256:{content_hash_hex}",
        "records_observed": len(lines) - 2,
        "records_declared": end_line.get("recordCount"),
        "counts": counts,
    }


def render(layers: dict[str, Any]) -> str:
    """把四层渲染成规范文本。**两套实现必须产出逐字节相同的这份文本。**"""
    out: list[str] = [REPORT_HEADER]

    out.append(f"layer1.file.bytes={layers['file_bytes']}")
    out.append(f"layer1.file.sha256={layers['file_sha256']}")

    out.append(f"layer2.plain.bytes={layers['plain_bytes']}")
    out.append(f"layer2.plain.sha256={layers['plain_sha256']}")

    out.append(f"layer3.ndjson.bytes={layers['ndjson_bytes']}")
    out.append(f"layer3.ndjson.sha256={layers['ndjson_sha256']}")
    out.append(f"layer3.lines={len(layers['lines'])}")
    for index, line in enumerate(layers["lines"]):
        out.append(f"layer3.line.{index:04d}.sha256={sha256_hex(line)}")

    for index, text in enumerate(layers["canonical"]):
        out.append(f"layer4.canonical.{index:04d}={text}")
    out.append(f"layer4.contentHash={layers['content_hash']}")
    out.append(f"layer4.recordCount.observed={layers['records_observed']}")
    out.append(f"layer4.recordCount.declared={layers['records_declared']}")
    for key in sorted(layers["counts"]):
        out.append(f"layer4.counts.{key}={layers['counts'][key]}")

    return "\n".join(out) + "\n"


# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------


def emit_fixture(sample_id: str, out_dir: Path, fixture_path: Path) -> int:
    """从被向量锁死的 fixture 里落出：`.pfb`、密码文件、期望值。

    **不碰密码学**：`.pfb` 的字节直接从 fixture 的 `fileHex` 取出，
    期望值直接取 fixture 记的 `fileSha256` / `payloadSha256` / `contentHash` /
    `recordCount` / `counts`。因此这一步不可能把「实现算出来的东西」当期望值 ——
    fixture 是由独立的 Python 生成器产出、并被导入器 A/B 的向量锁死的。
    """
    try:
        raw = json.loads(fixture_path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ToolError(f"读不到 fixture {fixture_path}：{exc}") from exc

    sample = next((s for s in raw["samples"] if s["id"] == sample_id), None)
    if sample is None:
        have = ", ".join(s["id"] for s in raw["samples"])
        raise ToolError(f"fixture 里没有样本 {sample_id}（有的是 {have}）")

    out_dir.mkdir(parents=True, exist_ok=True)

    pfb_path = out_dir / f"{sample_id}.pfb"
    pfb_path.write_bytes(bytes.fromhex(sample["fileHex"]))

    # 密码文件**带一个末尾换行**：`echo secret > pw.txt` 就是这样写的，
    # 是真实世界里最常见的那一种。让两条路径都必须剥掉它，才算真的验过这条契约。
    password_path = out_dir / "password.txt"
    password_path.write_bytes((raw["password"] + "\n").encode("utf-8"))

    manifest = sample["manifest"]
    expect = {
        "reportFormat": 1,
        "sample": sample_id,
        "source": fixture_path.relative_to(_REPO_ROOT).as_posix(),
        "file": {"bytes": sample["fileBytes"], "sha256": sample["fileSha256"]},
        "ndjson": {"bytes": sample["payloadBytes"], "sha256": sample["payloadSha256"]},
        "contentHash": sample["contentHash"],
        "recordCount": sample["recordCount"],
        "counts": manifest["counts"],
    }
    expect_path = out_dir / f"{sample_id}.expect.json"
    expect_path.write_text(
        json.dumps(expect, ensure_ascii=False, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
    )

    print(f"· {pfb_path}（{sample['fileBytes']} 字节 ⇐ {sample['id']}）")
    print(f"· {password_path}（1 行，带末尾换行）")
    print(f"· {expect_path}（期望值取自 fixture，未做任何解密）")
    return EXIT_OK


def tamper(src: Path, dst: Path, offset: int) -> int:
    """把第 [offset] 个字节翻一位（默认 60：固定头里的盐）。

    取 60 是有意的 —— 它在**头 CRC 的覆盖范围（0..43）之外**、
    但在 **contentDigest 的覆盖范围（48..长度-32）之内**。于是：

      · 头 CRC 仍然自洽 ⇒ 不落到「结构损坏」；
      · 内容摘要不符     ⇒ 落到「内容损坏」。

    这两个结论在导入器里是不同的用户动作，而反例要压的是后者。
    """
    try:
        blob = bytearray(src.read_bytes())
    except OSError as exc:
        raise ToolError(f"读不到 {src}：{exc}") from exc
    if offset >= len(blob):
        raise ToolError(f"偏移 {offset} 超出了文件长度 {len(blob)}")
    blob[offset] ^= 0x01
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(bytes(blob))
    print(f"· {dst}（{src.name} 的第 {offset} 字节翻转了 1 位）")
    return EXIT_OK


def check(
    pfb: Path,
    password_path: Path,
    expect_path: Path | None,
    out_path: Path | None,
) -> int:
    try:
        blob = pfb.read_bytes()
    except OSError as exc:
        raise ToolError(f"读不到 {pfb}：{exc}") from exc

    password = load_password(password_path)
    layers = compute_layers(blob, password)

    if expect_path is not None:
        verify_against_expect(layers, json.loads(expect_path.read_text(encoding="utf-8")), pfb)

    text = render(layers)
    if out_path is None:
        sys.stdout.write(text)
    else:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_bytes(text.encode("utf-8"))
        print(f"✓ 四层已写入 {out_path}（{len(text.encode('utf-8'))} 字节，UTF-8 无 BOM）")
    return EXIT_OK


def verify_against_expect(layers: dict[str, Any], expect: dict[str, Any], pfb: Path) -> None:
    """逐项对照 fixture 的期望值。**不符即 [Negative]，并说清是哪一项。**"""
    checks: list[tuple[str, Any, Any]] = [
        ("file.bytes", layers["file_bytes"], expect["file"]["bytes"]),
        ("file.sha256", layers["file_sha256"], expect["file"]["sha256"]),
        ("ndjson.bytes", layers["ndjson_bytes"], expect["ndjson"]["bytes"]),
        ("ndjson.sha256", layers["ndjson_sha256"], expect["ndjson"]["sha256"]),
        ("contentHash", layers["content_hash"], expect["contentHash"]),
        ("recordCount.observed", layers["records_observed"], expect["recordCount"]),
    ]
    for key in sorted(expect["counts"]):
        checks.append((f"counts.{key}", layers["counts"].get(key), expect["counts"][key]))

    bad = [(k, got, want) for k, got, want in checks if got != want]
    if bad:
        lines = [f"{pfb.name} 与期望值不符（期望值取自被向量锁死的 fixture）："]
        for key, got, want in bad:
            lines.append(f"  · {key}：实际 {got}，期望 {want}")
        raise Negative("\n".join(lines))

    print(f"✓ {pfb.name} 与期望值逐项相符（{len(checks)} 项，取自被向量锁死的 fixture）")


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pfb_cross_check.py",
        description="跨实现 PFB 校验（Dart 侧对应 pf info --records）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_emit = sub.add_parser("emit-fixture", help="从 fixture 落出 .pfb / 密码文件 / 期望值")
    p_emit.add_argument("--sample", required=True, help="样本 id，如 sample-full")
    p_emit.add_argument("--out-dir", required=True, type=Path)
    p_emit.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)

    p_check = sub.add_parser("check", help="解出四层并写出规范报告")
    p_check.add_argument("--file", required=True, type=Path, help=".pfb 文件")
    p_check.add_argument("--password-file", required=True, type=Path)
    p_check.add_argument("--expect", type=Path, default=None, help="期望值 JSON（可选）")
    p_check.add_argument("--out", type=Path, default=None, help="规范报告写到哪里；缺省写 stdout")

    p_tamper = sub.add_parser("tamper", help="造反例：翻转一个字节")
    p_tamper.add_argument("--file", required=True, type=Path)
    p_tamper.add_argument("--out", required=True, type=Path)
    p_tamper.add_argument("--offset", type=int, default=60)

    return parser


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "emit-fixture":
            return emit_fixture(args.sample, args.out_dir, args.fixture)
        if args.command == "check":
            return check(args.file, args.password_file, args.expect, args.out)
        if args.command == "tamper":
            return tamper(args.file, args.out, args.offset)
    except ToolError as exc:
        print(f"✗ {exc}", file=sys.stderr)
        return EXIT_TOOL_ERROR
    except Negative as exc:
        # 结论为「否」——注意它**不是**脚本崩了：这类结论需要调用方换一份文件，
        # 而不是去修这个脚本。退出码 1 与 2 的区分正是为了这件事。
        print(f"✗ {exc}", file=sys.stderr)
        return EXIT_NEGATIVE
    print(f"✗ 未知子命令：{args.command}", file=sys.stderr)
    return EXIT_TOOL_ERROR


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

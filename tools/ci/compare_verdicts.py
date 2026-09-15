#!/usr/bin/env python3
"""比对多个平台产出的黄金向量报告，判断「判定是否完全一致」。

为什么需要这个脚本，而不是直接 diff 三份 report.json：
    报告里天然包含时间戳、耗时、Dart 版本号、操作系统字符串 ——
    直接 diff 永远不等。因此报告被切成两半：

        判定部分（caseId + status）→ 排序后求 SHA-256，得到 verdictDigest
        诊断部分（时间 / 耗时 / 平台 / 实际值）→ 供人排查，不参与比对

    verdictDigest 相同 ⇔ 三个平台对每一条向量得出了同一个结论。

退出码：
    0  所有平台判定一致，且没有失败用例
    1  判定不一致，或存在失败用例
    2  输入本身有问题（报告缺失 / 字段缺失 / 只有一份报告）
"""

from __future__ import annotations

import glob
import json
import os
import sys


def load_reports(root: str) -> list[tuple[str, dict]]:
    paths = sorted(glob.glob(os.path.join(root, "**", "report.json"), recursive=True))
    reports = []
    for path in paths:
        with open(path, "r", encoding="utf-8") as handle:
            reports.append((path, json.load(handle)))
    return reports


def main(argv: list[str]) -> int:
    root = argv[1] if len(argv) > 1 else "reports"

    reports = load_reports(root)
    if not reports:
        print(f"✗ 在 {root} 下没有找到任何 report.json", file=sys.stderr)
        return 2

    print(f"找到 {len(reports)} 份报告：")
    for path, payload in reports:
        totals = payload.get("totals", {})
        print(
            f"  {path}\n"
            f"    OS      : {payload.get('operatingSystem', '?')}\n"
            f"    Dart    : {payload.get('dartVersion', '?')}\n"
            f"    合计    : {totals.get('total', '?')} 条，"
            f"通过 {totals.get('passed', '?')}，"
            f"失败 {totals.get('failed', '?')}，"
            f"待实现 {totals.get('pending', '?')}\n"
            f"    判定摘要: {payload.get('verdictDigest', '(缺失)')}"
        )

    # 少于两份报告说明工作流接线有问题，而不是「判定一致」。
    # 这是最容易静默通过的场景：pattern 写错 → 只下载到一个 artifact → 无差异可报。
    if len(reports) < 2:
        print(
            "✗ 只找到 1 份报告，无法做跨平台比对。"
            "这通常意味着 upload/download-artifact 的名字或路径写错了 —— "
            "「只跑了一个平台」不该被误判成「三个平台一致」。",
            file=sys.stderr,
        )
        return 2

    for path, payload in reports:
        if "verdictDigest" not in payload:
            print(f"✗ {path} 缺少 verdictDigest 字段", file=sys.stderr)
            return 2

    total_failed = sum(p.get("totals", {}).get("failed", 0) for _, p in reports)
    if total_failed:
        print()
        print(f"✗ 存在失败用例（各平台合计 {total_failed} 条），先修失败再看一致性。")
        for path, payload in reports:
            if payload.get("totals", {}).get("failed", 0) == 0:
                continue
            print(f"  {path}")
            for case in payload.get("results", []):
                if case.get("status") == "fail":
                    print(f"    ✗ {case.get('caseId')}: {case.get('message', '')}")
        return 1

    digests = {}
    for path, payload in reports:
        digests.setdefault(payload["verdictDigest"], []).append(path)

    if len(digests) == 1:
        digest = next(iter(digests))
        print()
        print(f"✓ {len(reports)} 个平台的判定完全一致（{digest[:16]}…）")
        return 0

    # 不一致：把每一方与大部队逐条对比，报出差异的用例。
    print()
    print("✗ 跨平台判定不一致。逐条对比：")
    baseline_digest, baseline_paths = max(digests.items(), key=lambda kv: len(kv[1]))
    baseline = next(p for path, p in reports if path == baseline_paths[0])
    baseline_status = {
        case["caseId"]: case["status"] for case in baseline.get("results", [])
    }

    for path, payload in reports:
        if payload["verdictDigest"] == baseline_digest:
            continue
        print(f"\n  {path}（摘要 {payload['verdictDigest'][:16]}…）")
        theirs = {case["caseId"]: case for case in payload.get("results", [])}
        differences = 0
        for case_id, status in baseline_status.items():
            other = theirs.get(case_id)
            if other is None:
                print(f"    - {case_id}: 本平台缺失该用例")
                differences += 1
            elif other["status"] != status:
                print(
                    f"    - {case_id}: {baseline_paths[0]}={status} "
                    f"vs {payload['operatingSystem']}={other['status']}"
                )
                differences += 1
        for case_id in theirs.keys() - baseline_status.keys():
            print(f"    + {case_id}: 仅在 {payload['operatingSystem']} 上存在")
            differences += 1
        if differences == 0:
            print("    （逐条状态相同，但摘要不同 —— 报告本身可能被手工改过）")

    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))

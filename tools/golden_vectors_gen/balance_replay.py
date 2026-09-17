#!/usr/bin/env python3
"""余额推演的黄金向量生成器（方案 §2.3 余额语义 + §7.2 验收口径）。

覆盖的 kind（对应 packages/pf_testkit/lib/src/drivers/m1_balance.dart）：
  - db.balance.replay   支出/收入/转账双腿/手续费/软删回退/信用卡/统计口径/day_key 派生

期望值的独立来源：**本脚本按 §2.3 语义独立实现的推演规则**（与 AES 的
NIST 锚点同理 —— 不与 Dart 侧共享任何代码）。规则逐条对照：
  - 支出：账户余额 -amount
  - 收入：账户余额 +amount
  - 转账：转出 -(amount+fee)，转入 +amount（fee 由转出承担，§2.3）
  - 软删：回退该笔影响；编辑：先回退旧值再施加新值
  - 信用卡：无特殊分支（负余额即负债，§2.3 注释原文）
  - 统计口径：转账本金不进收支合计；fee 计入支出（§2.3 fee_minor 注释）
  - day_key/month_key：occurred_at + tz_offset 的 UTC 日历拆解（§2.1）

用法：
  python balance_replay.py            # 自检 + 打印，不写文件
  python balance_replay.py --write    # 写入 ../../test_vectors/v1/balance_replay.json（LF 行尾）
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

LEDGER_ID = "01J8Z9K2M4P6Q8R0T2V4X6Z8B1"

# ---- 固定时间轴（全部写死，保证向量可复现） ----
# 2026-09-01 起的每日步进；T0 = 2026-09-01 08:00:00Z。
T0 = 1789000000000
DAY = 86400000
UTC8 = 8 * 60   # 录入时区 UTC+8
UTC_5 = -5 * 60  # 录入时区 UTC-5


def _ulid(seed: str) -> str:
    """与测试同源的确定性 26 字符 Crockford 串（首字符 0-7）。"""
    alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    chars = ["0"] * 26
    h = 0x9E3779B9
    for unit in seed.encode():
        h = ((h ^ unit) * 0x01000193) & 0x7FFFFFFF
        chars[h % 26] = alphabet[(h >> 5) % len(alphabet)]
    chars[0] = "0"
    for i in range(1, 26):
        if chars[i] == "0":
            chars[i] = alphabet[(h + i * 7) % len(alphabet)]
    return "".join(chars)


ACC_CASH = _ulid("acc-cash")
ACC_BANK = _ulid("acc-bank")
ACC_CARD = _ulid("acc-card")


def day_key(occurred_at: int, tz_offset_min: int) -> tuple[str, str]:
    """§2.1：occurred_at + tz_offset 的 UTC 日历拆解（独立于 Dart 实现）。"""
    local = datetime.fromtimestamp(occurred_at / 1000, tz=timezone.utc) + timedelta(minutes=tz_offset_min)
    return local.strftime("%Y-%m-%d"), local.strftime("%Y-%m")


# ---------------------------------------------------------------------------
# 独立实现的推演引擎（§2.3 语义；不得参考 Dart 代码 —— 口径以本文件为准）
# ---------------------------------------------------------------------------

class Engine:
    def __init__(self, accounts: list[dict]):
        self.openings: dict[str, int] = {a["id"]: a["openingMinor"] for a in accounts}
        self.balances: dict[str, int] = dict(self.openings)
        self.as_of: dict[str, int] = {a["id"]: 0 for a in accounts}
        self.live: dict[str, dict] = {}
        self.order: list[str] = []

    def _effect(self, txn: dict) -> tuple[int, str | None, int | None]:
        t, amount, fee = txn["type"], txn["amountMinor"], txn.get("feeMinor", 0)
        if t == 1:
            return -amount, None, None
        if t == 2:
            return amount, None, None
        assert t == 3 and txn.get("toAccountId"), "转账必须有转入账户"
        return -(amount + fee), txn["toAccountId"], amount

    def _recompute_as_of(self, acc_id: str) -> int:
        """as_of 全量口径：该账户所有生效交易的 MAX(occurred_at)。"""
        best = 0
        for txn in self.live.values():
            if txn["accountId"] == acc_id or txn.get("toAccountId") == acc_id:
                best = max(best, txn["occurredAt"])
        return best

    def _apply(self, txn: dict, sign: int) -> None:
        delta, to_id, to_delta = self._effect(txn)
        self.balances[txn["accountId"]] = self.balances.get(txn["accountId"], 0) + sign * delta
        self.as_of[txn["accountId"]] = self._recompute_as_of(txn["accountId"])
        if to_delta is not None:
            self.balances[to_id] = self.balances.get(to_id, 0) + sign * to_delta
            self.as_of[to_id] = self._recompute_as_of(to_id)

    def txn(self, txn: dict) -> None:
        if txn["id"] not in self.live:
            self.order.append(txn["id"])
        self.live[txn["id"]] = txn

    def replay_from_scratch(self) -> dict[str, tuple[int, int]]:
        """全量重算（事实标准）：不信任增量结果，从账目直接推。"""
        deltas: dict[str, int] = {}
        occ: dict[str, int] = {}
        for txn in self.live.values():
            delta, to_id, to_delta = self._effect(txn)
            deltas[txn["accountId"]] = deltas.get(txn["accountId"], 0) + delta
            occ[txn["accountId"]] = max(occ.get(txn["accountId"], 0), txn["occurredAt"])
            if to_delta is not None:
                deltas[to_id] = deltas.get(to_id, 0) + to_delta
                occ[to_id] = max(occ.get(to_id, 0), txn["occurredAt"])
        acc_ids = set(self.openings) | set(deltas)
        return {acc_id: (self.openings.get(acc_id, 0) + deltas.get(acc_id, 0), occ.get(acc_id, 0)) for acc_id in acc_ids}

    def summary(self) -> dict:
        """§7.2：转账本金不进收支合计；fee 计入支出。"""
        income = expense = transfer = fee = 0
        for txn in self.live.values():
            if txn.get("excludedFromStats"):
                continue
            if txn["type"] == 1:
                expense += txn["amountMinor"]
            elif txn["type"] == 2:
                income += txn["amountMinor"]
            else:
                transfer += txn["amountMinor"]
                expense += txn.get("feeMinor", 0)
                fee += txn.get("feeMinor", 0)
        return {"incomeMinor": income, "expenseMinor": expense, "transferMinor": transfer, "feeMinor": fee}


def run_ops(accounts: list[dict], ops: list[dict]) -> dict:
    """增量路径（回退旧值 + 施加新值）跑完后，与全量重算交叉校验。"""
    engine = Engine(accounts)
    for op in ops:
        name = op["op"]
        if name == "txn":
            engine.txn(op)
            engine._apply(op, sign=1)  # noqa: SLF001 —— 同文件内部使用
        elif name == "edit":
            old = engine.live[op["id"]]
            engine.txn(_edited(old, op))            # 行已更新为整条新值
            engine._apply(old, sign=-1)             # 回退旧腿（as_of 扫到的是新版本，与 SQL 一致）
            engine._apply(engine.live[op["id"]], sign=1)
        elif name == "delete":
            victim = engine.live.pop(op["id"])
            engine._apply(victim, sign=-1)
        else:
            raise AssertionError(f"未知操作 {name}")

    full = engine.replay_from_scratch()
    # 交叉校验：增量与全量必须一致（自身自检，不通过说明生成器写错了）。
    for acc_id, (balance, as_of) in full.items():
        assert engine.balances[acc_id] == balance, f"增量 != 全量：{acc_id}"
        assert engine.as_of[acc_id] == as_of, f"as_of != 全量：{acc_id}"

    day_keys = []
    for txn_id in engine.order:
        txn = engine.live.get(txn_id)
        if txn is None:
            continue
        dk, mk = day_key(txn["occurredAt"], txn.get("tzOffsetMin", 0))
        day_keys.append({"id": txn_id, "dayKey": dk, "monthKey": mk})
    return {
        "balances": {acc_id: {"balanceMinor": engine.balances[acc_id], "balanceAsOf": engine.as_of[acc_id]} for acc_id in engine.balances},
        "summary": engine.summary(),
        "dayKeys": day_keys,
    }


def _edited(old: dict, op: dict) -> dict:
    merged = dict(old)
    merged.update({k: v for k, v in op.items() if k not in ("op",)})
    return merged


def build_cases() -> list[dict]:
    cases: list[dict] = []

    def case(ref: str, title: str, accounts: list[dict], ops: list[dict], note: str, tags: list[str]) -> None:
        cases.append(
            {
                "id": f"db.balance.replay.{ref}",
                "kind": "db.balance.replay",
                "title": title,
                "milestone": "M1",
                "input": {"accounts": accounts, "ops": ops},
                "expect": {"ok": True, "value": run_ops(accounts, ops)},
                "notes": note,
                "tags": tags,
            }
        )

    # ---- 1. 收支基础 ----
    case(
        "expense-income",
        "支出与收入的单腿推演",
        [{"id": ACC_CASH, "openingMinor": 100000}],
        [
            {"op": "txn", "id": _ulid("t1"), "type": 1, "amountMinor": 3500, "accountId": ACC_CASH, "occurredAt": T0, "tzOffsetMin": UTC8},
            {"op": "txn", "id": _ulid("t2"), "type": 2, "amountMinor": 20000, "accountId": ACC_CASH, "occurredAt": T0 + DAY, "tzOffsetMin": UTC8},
        ],
        "§2.3：支出 -amount、收入 +amount；summary 只含收支。",
        ["db", "balance"],
    )

    # ---- 2. 转账双腿 + 手续费 ----
    case(
        "transfer-fee",
        "转账双腿：转出 -(amount+fee)，转入 +amount",
        [{"id": ACC_CASH, "openingMinor": 100000}, {"id": ACC_BANK, "openingMinor": 0}],
        [
            {"op": "txn", "id": _ulid("t3"), "type": 3, "amountMinor": 10000, "feeMinor": 200,
             "accountId": ACC_CASH, "toAccountId": ACC_BANK, "occurredAt": T0, "tzOffsetMin": UTC8},
        ],
        "§2.3 fee_minor 注释：手续费由转出账户额外承担；统计口径计入支出。",
        ["db", "balance", "transfer"],
    )

    # ---- 3. 信用卡负债语义 ----
    case(
        "credit-card",
        "信用卡消费使余额变小、还款（转入）使余额变大",
        [
            {"id": ACC_CASH, "openingMinor": 100000},
            {"id": ACC_CARD, "openingMinor": 0, "type": 3, "creditLimitMinor": 50000},
        ],
        [
            {"op": "txn", "id": _ulid("t4"), "type": 1, "amountMinor": 3500, "accountId": ACC_CARD, "occurredAt": T0, "tzOffsetMin": UTC8},
            {"op": "txn", "id": _ulid("t5"), "type": 3, "amountMinor": 1000, "accountId": ACC_CASH, "toAccountId": ACC_CARD, "occurredAt": T0 + DAY, "tzOffsetMin": UTC8},
        ],
        "§2.3：信用卡无特殊代码路径 —— 负余额即负债，净资产 = Σ cached_balance 统一成立。",
        ["db", "balance", "credit"],
    )

    # ---- 4. 编辑（支出改转账：三账户触达） ----
    t6 = _ulid("t6")
    case(
        "edit-retype",
        "编辑切换类型：旧值回退 + 新值施加",
        [
            {"id": ACC_CASH, "openingMinor": 0},
            {"id": ACC_BANK, "openingMinor": 0},
            {"id": ACC_CARD, "openingMinor": 0, "type": 3, "creditLimitMinor": 50000},
        ],
        [
            {"op": "txn", "id": t6, "type": 1, "amountMinor": 3000, "accountId": ACC_CASH, "occurredAt": T0, "tzOffsetMin": UTC8},
            {"op": "edit", "id": t6, "type": 3, "amountMinor": 3000, "accountId": ACC_BANK, "toAccountId": ACC_CARD, "occurredAt": T0 + DAY, "tzOffsetMin": UTC8},
        ],
        "编辑 = 先按旧值回退、再按新值施加；账户/类型变化全部覆盖。",
        ["db", "balance", "edit"],
    )

    # ---- 5. 软删回退 ----
    t7 = _ulid("t7")
    case(
        "delete-reverse",
        "软删回退该笔影响，缓存回到推演起点",
        [{"id": ACC_CASH, "openingMinor": 50000}],
        [
            {"op": "txn", "id": t7, "type": 1, "amountMinor": 12000, "accountId": ACC_CASH, "occurredAt": T0, "tzOffsetMin": UTC8},
            {"op": "delete", "id": t7},
        ],
        "软删 = 从推演中移除；全量重算对没有生效交易的账户归位到 opening。",
        ["db", "balance", "delete"],
    )

    # ---- 6. excluded_from_stats：统计豁免但余额照常 ----
    case(
        "excluded-stats",
        "excluded_from_stats 不进收支合计，但余额照常推演",
        [{"id": ACC_CASH, "openingMinor": 1000}],
        [
            {"op": "txn", "id": _ulid("t8"), "type": 1, "amountMinor": 700, "accountId": ACC_CASH, "occurredAt": T0, "tzOffsetMin": UTC8, "excludedFromStats": True},
        ],
        "钱确实动了、只是不计收支 —— 两个口径必须分开。",
        ["db", "balance", "stats"],
    )

    # ---- 7. day_key / month_key 派生（含跨日/跨月/负偏移） ----
    case(
        "day-key-tz",
        "day_key/month_key 按 (occurred_at, tz_offset) 拆解：跨日与负偏移",
        [{"id": ACC_CASH, "openingMinor": 0}],
        [
            # 2026-09-01 16:30Z = UTC+8 的 09-02（跨日）。
            {"op": "txn", "id": _ulid("t9"), "type": 1, "amountMinor": 100, "accountId": ACC_CASH,
             "occurredAt": 1789000000000 + 8 * 3600 * 1000, "tzOffsetMin": UTC8},
            # 2026-09-01 04:00Z = UTC-5 的 08-31（跨月）。
            {"op": "txn", "id": _ulid("t10"), "type": 1, "amountMinor": 100, "accountId": ACC_CASH,
             "occurredAt": 1789000000000 - 4 * 3600 * 1000, "tzOffsetMin": UTC_5},
        ],
        "§2.1 的关键设计：冗余列由录入设备时区决定，跨端统计结果恒定。",
        ["db", "balance", "tz"],
    )

    return cases


def self_check() -> None:
    """生成器自检：规则与 §2.3 逐条对得上。"""
    result = run_ops(
        [{"id": "A", "openingMinor": 1000}],
        [{"op": "txn", "id": "T1", "type": 3, "amountMinor": 100, "feeMinor": 10, "accountId": "A", "toAccountId": "B", "occurredAt": T0}],
    )
    # 上面 accounts 只有 A，B 通过 txns 出现：A = 1000 - 110, B = 0 + 100。
    assert result["balances"]["A"]["balanceMinor"] == 890
    assert result["balances"]["B"]["balanceMinor"] == 100
    assert result["summary"]["expenseMinor"] == 10, "fee 计入支出"
    assert result["summary"]["transferMinor"] == 100

    # 软删后回到 opening。
    result2 = run_ops(
        [{"id": "A", "openingMinor": 500}],
        [
            {"op": "txn", "id": "T2", "type": 1, "amountMinor": 100, "accountId": "A", "occurredAt": T0},
            {"op": "delete", "id": "T2"},
        ],
    )
    assert result2["balances"]["A"]["balanceMinor"] == 500
    assert result2["summary"]["expenseMinor"] == 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="写入向量文件（LF 行尾）")
    args = parser.parse_args()

    self_check()
    cases = build_cases()

    suite = {
        "schemaVersion": 1,
        "suite": "balance_replay",
        "title": "余额推演",
        "description": (
            "锁死 §2.3 余额语义（支出/收入/转账双腿/手续费/软删回退/信用卡/统计口径）"
            "与 §2.1 冗余列 day_key/month_key 的派生。"
            "期望值由本脚本按规格独立实现，与 Dart 侧 BalanceEngine / TxnTime 独立会合。"
        ),
        "cases": cases,
    }
    text = json.dumps(suite, ensure_ascii=False, indent=2) + "\n"

    if not args.write:
        print(f"[dry] {len(cases)} 条用例（未写文件，--write 落盘）")
        return

    out = Path("test_vectors/v1/balance_replay.json")
    out.write_bytes(text.encode("utf-8"))
    print(f"[ok] 写入 {out}（{len(cases)} 条用例）")


if __name__ == "__main__":
    main()

# test_vectors —— 黄金测试向量

这些 JSON 文件是**签入仓库的契约数据**，不是测试的附属物。

## 为什么用数据锁定行为，而不是多写几个单测

单测写的是「我认为这段代码应该怎样」，价值随作者记忆的消退而衰减 ——
半年后没人敢改，因为不知道哪条断言是刻意的、哪条只是当时实现的快照。

黄金向量写的是「这个格式/算法的输出**就是**这一串字节」，并附上原因。
它带来两个单测给不了的能力：

1. **跨实现可验证。** 同一批向量可以喂给 Kotlin / Swift / Rust 的实现，
   或喂给 OpenSSL / argon2 命令行。单测做不到这一点，
   而本项目迟早会有第二个平台。
2. **改动必须显式。** 想让文件头的输出变一个字节，就必须改这里的 JSON ——
   而它在 code review 里看得见、diff 里刺眼，
   「不小心改了加密格式」因此变成一件做不到的事。

## 目录

```
test_vectors/
  schema/vector.schema.json   格式的 JSON Schema（机器可读的规格说明）
  pending_baseline.json       允许处于 pending 的用例 ID，规则「只减不增」
  fixtures/import_samples.json  .pfb 样本字节（hex 表示），导入器向量的输入侧原料
  v1/*.json                   向量本体
```

`fixtures/` 之所以存在：`.pfb` 容器本体按 `tracked_paths.yaml` 的
`tracked-vault-file` 规则**不允许入库**（B1 决策，2026-09-18），
但导入器需要真实字节做输入。所以字节以 hex 落在 fixtures 里，
`v1/import_payload.json` 内联同一批 hex（**向量必须自包含**：驱动不读文件系统），
两者的逐字节一致由生成脚本的 `--check` 断言。

`v1/` 这一层是格式版本目录。将来格式演进到 2 时新建 `v2/`，
旧文件保持不动 —— 这样读方不需要同时理解两代格式。

向量本体的**生成脚本**在 `tools/golden_vectors_gen/`，每个套件一个，
与向量文件同名（`hkdf_sha256.py` → `v1/hkdf_sha256.json`）。
脚本是可以重跑的：它的第一件事是把自己和标准文档逐字节对齐
（例如 HKDF 的脚本会先验证标准库复算的结果等于 RFC 5869 附录 A 里抄下来的值），
对齐失败就直接退出。所以「这串十六进制是怎么来的」永远有可执行答案，
而不是一句「当时算的」。

## 一条期望值是怎么来的

**期望值必须能被独立推导，绝不能由被测实现自己生成。**

允许的来源：
- 标准文档（RFC 9106 / RFC 5869 / NIST SP 800-38D）里给出的测试向量
- 独立参考工具（`argon2` CLI、`openssl`、Python `hashlib` / `cryptography`）
- 手算的字节布局（本仓库的容器格式向量就是这种，见每个用例的 `notes`）

不允许的来源：
- 跑一遍本实现，把它吐出来的东西抄进 `expect`

`bin/vector_forge.dart` 就是为这条规则服务的：它把实现的实际输出写到
`build/vectors/forged/`，**并显式拒绝对 `test_vectors/` 写入**。
它产出的东西是给人看的对照表，不是可以被消费的期望值。

### 顺序：向量必须先于实现

这不是风格偏好，是让向量有意义的前提。先写实现再补向量，通常只是把实现的
偶然行为抄一遍，锁不住任何东西 —— 而且报告是**全绿**的，
没有任何迹象表明「这个原语从未与独立期望值比对过」。

顺序由机器守着，不靠自觉：

| 违反方式 | 谁拦住 |
| --- | --- |
| 有实现、没向量 | `melos run vectors:coverage`（未覆盖的 kind 直接判失败） |
| 有向量、kind 没注册 | `melos run vectors`（未注册 kind 记为 fail，不是跳过） |
| 新出现 pending 用例 | `melos run vectors`（pending 基线只减不增） |

`vectors:coverage` 只能查「有没有向量」，查不了「期望值是不是独立生成的」——
后者没有机器判据，只能由 review 与生成脚本的可重跑性共同保证。

## 当前覆盖范围

| 套件 | 覆盖 |
| --- | --- |
| `container_constants` | §3.3 容器格式发布常量快照（魔数 / 头部布局 / 长度约束 / flags 位 / 算法 ID；期望值为规格人工转录） |
| `container_header` | §3.3 128 字节分块容器的文件头：字节布局（48 固定 + 变量区）、CRC32、featureFlags 位语义、CRC 篡改 / 魔数错 / 版本过高 / 未知 flag 位四类错误分流 |
| `container_trailer`→`container_digest` | 40 字节文件尾已被 §3.3 的 32 字节 contentDigest **替换**：免密完整性、覆盖边界 [48..长度-32) 本身是契约、「损坏」vs「密码错」的可区分性 |
| `container_layout` | §3.3 密文区切分（chunkLen + chunkNonce + box）逐段指纹、截断与尾部私货拒绝 |
| `container_file` | 完整文件字节级断言（附录 B pfb-file 落地）：KDF + 分块 + 链式 AAD（首块 prevTag = 32 个 0x00）、三态错误分流 |
| `kdf_params` | Argon2id 参数范围（安全边界）与三套预设 |
| `ulid` | ULID 编码/解析/合法性/同毫秒单调性 |
| `money` | 定点金额的渲染、解析、求和与币种相等性 |
| `merge` | 记录版本裁决与收敛性（可交换 / 幂等 / 可结合） |
| `hkdf_sha256` | HKDF-SHA256 的提取/扩展两阶段、缺省语义、块边界（RFC 5869 + 真实用途 MK→DBKey） |
| `aes256gcm` | AES-256-GCM（NIST SP 800-38D）：96 位 nonce 主路径、非 96 位 nonce 边界（8 / 16 字节）、空明文 / 单字节明文 / AAD，以及三类认证失败（标签篡改 / 密文篡改 / AAD 不符）必须抛 `PFB_E_AUTH_FAILED` |
| `argon2id` | Argon2id（RFC 9106，version 0x13）派生：§3.2 三档（P_DEFAULT / P_STRONG / P_MIN）、盐长度边界（8 / 32 字节），以及 m/t/p 超上限（`PFB_E_KDF_PARAMS`）与输入契约破坏（密码空 / 盐长不符 → `PFB_E_HEADER_INVALID`） |
| `keyring` | §3.1 密钥层级编排：MK → DBKey（HKDF info="pf/db/1"）、keyCheck 生成/校验（固定明文 `PF:KEYCHECK:v1`、AAD `pf-keycheck-v1|cfgVersion|installId`）、恢复码包裹/解包（AAD `pf-recovery-v1|cfgVersion`），错误分支 `PFK_E_WRONG_PASSWORD` / `PFK_E_WRONG_RECOVERY_CODE` / `PFK_E_TAMPERED` |
| `db_open` | §3.4 SQLCipher 打开流程：有序 PRAGMA 脚本（key → cipher_compatibility=4 → cipher_page_size=4096 → cipher_memory_security → foreign_keys；iOS 变体把 `cipher_plaintext_header_size = 32` 放在 key 之前）与打开期错误分类（NOTADB 双分支：keyCheck 未过 → `PFK_E_WRONG_PASSWORD`、已过 → `PFD_E_OPEN`；malformed / 一般失败 → `PFD_E_OPEN`） |

AES-256-GCM 的驱动（`m1_aesgcm.dart`）与 Argon2id 的驱动
（`m2_crypto.dart`，历史位置，实为纯 Dart、里程碑 M1）均已实现并入库。
AES 向量由 `tools/golden_vectors_gen/aes256gcm.py` 生成
（NIST GCMVS 锚点 + `cryptography` / `pycryptodome` 双实现复算）；
Argon2id 向量由 `tools/golden_vectors_gen/argon2id.py` 生成
（Python `argon2-cffi` 独立复算，RFC 9106 §5.3 的带 K/AD 锚点由 Dart 单测验证）；
Keyring 向量由 `tools/golden_vectors_gen/keyring.py` 生成
（Python 标准库 hmac 手拼 HKDF × `cryptography` 交叉核对，AES-GCM 走
`cryptography` × `pycryptodome` 双实现）；
SQLCipher 打开流程向量由 `tools/golden_vectors_gen/db_open.py` 生成
（期望值为规格 §3.4 原文的人工转录 —— 与 NIST 锚点同理，来源是文档而非实现）；
余额推演向量由 `tools/golden_vectors_gen/balance_replay.py` 生成
（期望值由独立 Python 实现推演，与 Dart 的 `BalanceEngine` 无共享代码；
生成器内部自带「增量 == 全量重算」自检，自检不过则拒绝产文件）；
容器五套件由 `tools/golden_vectors_gen/container_pfb.py` 生成
（Python `cryptography` + `argon2-cffi` + 手工打包独立算出全部字节；
生成器内部自带 seal→open 往返与篡改拦截自检）；
导出载荷向量由 `tools/golden_vectors_gen/export_payload.py` 生成
（Python 标准库 json / hashlib 独立编码，自带解析回读与哈希重算自检）。

**2026-09-17 容器裁决**：M0 曾按简化占位实现锁了 76 字节 "PFB1" 单块容器的
三套向量。落实导出器时确认与规格 §3.3（128 字节分块格式：noncePrefix + 1 MiB
分块 + 链式 AAD + 32 字节 contentDigest）冲突，裁决 §3.3 为唯一 v1 —— 76B
版本从未发布过任何文件，旧三套向量整体替换为上表五套件，无迁移负担。
同日裁决：manifest `contentHash` 覆盖口径 = **记录行**（不含 end 行，否则自指）。

**全部 40 个驱动均已实现、均有向量引用，pending 为 0。**
有状态 Keyring 服务（初始化 / 解锁 / 失败计数 / 对接 flutter_secure_storage）
不在向量体系内 —— 它的本质是平台与 UI 编排，属于 M2；
其依赖的纯组合规则（本目录的 `keyring` 套件）已被锁死。

## 证据边界：哪些分支只有间接证据

**门禁回答的是「每条向量都通过了吗」，不回答「每条分支都被向量走过了吗」。**
后者没有机器判据，只能人写下来。本节记一处**明确接受的空洞**（2026-09-21）。

> 这段本来该写在提交 `9b897af`（导入器提交 A）的提交信息里，
> 但该提交推送后发现遗漏，**已推送的提交信息不再改写**（改写等于 force push，
> 代价大于收益）。所以正式记录落在本节 —— 它是这段话的权威位置，
> 不要在提交信息里找。

### 空洞：`import.apply` 的「查出孤儿 → 整体中止」只在 1 条规则上有独立证据

`import.apply.reference-rules-full` 让 **13 条引用完整性规则全部被执行过一次**，
但「**n>0**（真的查出孤儿）→ 抛 `PFI_E_INCOMPATIBLE` → 整体回滚」
这条**动作分支**只在 `txn.account_id` 上走过：

| 要证明的事 | 有独立向量证据吗 | 谁给的 |
| --- | --- | --- |
| 13 条规则的 SQL 存在且文本正确 | ✅ 有 | `unusedCannedKeys` 跨实现对证：Dart 侧罐头键取自 `ImportIntegrityCheck.referenceRules`，Python 侧取自自己的 `REFERENCE_RULES`，两侧逐条深比对 —— 任一表拼错 / 列名写错 / 少一条规则，必有一条 apply 向量变红 |
| n>0 的处置（抛码 + 整体回滚） | 只有 `txn.account_id` 这一路 | `import.apply.reference-missing`（`orphanViolations={'txn.account_id': 3}`） |
| 四张新表（category / tag / budget / attachment）的 n>0 | ❌ **无独立证据** | —— |

**为什么接受**：13 条规则产出的是同一个 `Map<String, int>`，由**同一个循环体**
判定、**同一处 throw**。`reference-missing` 走的正是这段逻辑的 n>0 路径，
新表与它走的是**同样的代码**，只有数据不同 —— 再补一条向量只是重复验证同一行。

**什么时候这个理由不再成立（届时要补）**：一旦 13 条规则的 n>0 处置**分化**
（例如某几张表改成软删、记台账、只警告不中止），「单点」这个前提就没了，
四张表的 n>0 会立刻变成真缺口。判据是：**n>0 的处置是否仍是单点**。

**自己核实这张矩阵**（不跑 Dart，几秒钟出结论；在 Git Bash 里执行）：

```bash
cd D:/workbuddy/pf-wallet
python - <<'PY'
import json, pathlib
d = json.loads(pathlib.Path("test_vectors/v1/import_payload.json").read_text(encoding="utf-8"))
for c in d["cases"]:
    if c["kind"] != "import.apply":
        continue
    sql = " ".join(str(s) for s in c["expect"]["value"].get("statements", []))
    print('%-24s 孤儿扫描=%2d  注入的孤儿=%s' % (
        c["id"].split(".")[-1], sql.count("NOT IN"), c["input"].get("orphanViolations")))
PY
```

2026-09-21 的实测输出（`孤儿扫描` 列 = 该用例真的跑了几条规则的 `NOT IN` 扫描）：

```
insert-new               孤儿扫描= 6  注入的孤儿={}
idempotent-skip          孤儿扫描= 6  注入的孤儿={}
file-sha256-short-circuit 孤儿扫描= 0  注入的孤儿={}
conflict-deferred        孤儿扫描= 0  注入的孤儿={}
backup-failed            孤儿扫描= 0  注入的孤儿={}
reference-missing        孤儿扫描= 6  注入的孤儿={'txn.account_id': 3}
reference-rules-full     孤儿扫描=13  注入的孤儿={}
write-failure-rollback   孤儿扫描= 0  注入的孤儿={}
quick-check-damaged      孤儿扫描= 0  注入的孤儿={}
```

「注入的孤儿」列只有一行非空 —— 这一行就是上表第三行「无独立证据」的全部含义。

## 未来约束：A 的样本 id 不是合法 ULID（**有意为之**）

**事实**：`fixtures/import_samples.json` 的 5 个样本共 26 条记录行（含跨样本重复），
其中 **19 处 `id` 不是合法 ULID**（去重后 8 个不同 id）；而 `deviceId` **26/26 全部合法**。
不合法分三类（2026-09-21 实测）：

| 原因 | 处数 | 样例 | 说明 |
| --- | --- | --- | --- |
| 长度 27 | 11 | `01J8TESTLEDGER0000000000001` | `01J8TEST` + 6 字母业务前缀（LEDGER / ACCNT…）+ 13 位序号 |
| 长度 25 | 7 | `01J8TESTTXN00000000000003` | 3 字母业务前缀（TXN） |
| 含表外字符 `U` | 1 | budget 行 | 前缀用了 `BUDGET` 字样，而 Crockford 表排除 `I/L/O/U` |

**为什么现在无害**：A（`import_payload.dart` / `import_apply.dart`）**不校验 id 格式** ——
id 只作为主键字符串透传。所以 A 的 44 条 import 向量全绿。

**为什么是有意的**：这些 id 是写给人看的可读样本（一眼能认出哪条是账户、哪条是交易）。
把它们改成合法 ULID 属于**实现倒逼向量** —— 让向量去迁就实现的新约束，
而不是让向量忠实反映规格行为。这是本目录的一条红线（见「为什么用数据锁定行为」）。

**未来约束（本节存在的真正目的）**：如果将来有人在 **A 的路径上**加 id 格式校验
（哪怕只是一句 `assert(Ulid.isValid(row.id))`），**A 的 44 条 import 向量会立刻全红**。
届时的正确做法**不是**删掉那条校验，也**不是**只手改 fixtures —— 而是**重算**：
重造样本字节（fixtures 的 hex）→ 重跑生成器 → `test_vectors/v1/import_payload.json`
全量重生成，判决摘要一并换成新值。这是一次跨文件联动改动，不是改一行。

**判据**：`import.triage.*` / `import.payload.decode.*` / `import.file.read.*` / `import.apply.*`
四组（共 44 条）里任一条突然变红且报错指向 id 格式，先回看本节再动手。

**自查（不跑 Dart，几秒出结论；若你的 shell 不支持 heredoc，把中间那段存成 `.py` 再跑）**：

```bash
cd D:/workbuddy/pf-wallet
python - <<'PY'
import json, pathlib
CROCK, FIRST = set("0123456789ABCDEFGHJKMNPQRSTVWXYZ"), "01234567"
bad = lambda s: (not isinstance(s, str)) or len(s) != 26 or any(c not in CROCK for c in s) or s[0] not in FIRST
fx = json.loads(pathlib.Path("test_vectors/fixtures/import_samples.json").read_text(encoding="utf-8"))
rows = [o for s in fx["samples"] if s.get("payloadNdjsonHex")
          for o in (json.loads(l) for l in bytes.fromhex(s["payloadNdjsonHex"]).decode("utf-8").split("\n") if l.strip())
          if isinstance(o, dict) and "id" in o]
print("记录行 %d  id 非法 %d（去重 %d）  deviceId 非法 %d"
      % (len(rows), sum(bad(o["id"]) for o in rows),
         len({o["id"] for o in rows if bad(o["id"])}), sum(bad(o.get("deviceId")) for o in rows)))
PY
```

## 怎么跑

```bash
# 全量
melos run vectors

# 看还剩多少没实现
melos run vectors:pending

# 只跑一个 kind
dart run packages/pf_testkit/bin/vector_report.dart --kind container.header.encode

# 用实现的实际输出做人工对照（不会改向量文件）
melos run vectors:forge
```

退出码：

| 码 | 含义 | 该改什么 |
| --- | --- | --- |
| 0 | 全部通过且 pending 与基线一致 | 什么都不用改 |
| 1 | 有向量失败，或 pending 集合与基线不符 | 改实现（或确认是有意变更后改向量） |
| 2 | 向量文件 / 参数 / 环境本身有问题 | 改向量文件 |

把 1 与 2 分开很关键：混在一起会让人对着正确的实现找半天 bug。

## 新增向量的检查清单

- [ ] `id` 全局唯一，命名符合 `<领域>.<对象>.<行为>.<变体>`
- [ ] `kind` 已在 `VectorRegistry` 里注册
- [ ] `input` 完全确定（没有随机、没有 `DateTime.now()`、不读环境）
- [ ] `expect.value` 非空，且每个键都能由独立来源推导
- [ ] `notes` 写清「不做这件事会出什么事故」，而不只是「测试参数校验」
- [ ] 打上合适的 `tags`（`security` 标签的用例会在 review 时被重点看）

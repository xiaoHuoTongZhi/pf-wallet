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
  v1/*.json                   向量本体
```

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

**全部 36 个驱动均已实现、均有向量引用，pending 为 0。**
有状态 Keyring 服务（初始化 / 解锁 / 失败计数 / 对接 flutter_secure_storage）
不在向量体系内 —— 它的本质是平台与 UI 编排，属于 M2；
其依赖的纯组合规则（本目录的 `keyring` 套件）已被锁死。

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

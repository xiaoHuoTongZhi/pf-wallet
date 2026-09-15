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

## 一条期望值是怎么来的

**期望值必须能被独立推导，绝不能由被测实现自己生成。**

允许的来源：
- 标准文档（RFC 9106 / NIST SP 800-38D）里给出的测试向量
- 独立参考工具（`argon2` CLI、`openssl`、Python `hashlib` / `cryptography`）
- 手算的字节布局（本仓库的容器格式向量就是这种，见每个用例的 `notes`）

不允许的来源：
- 跑一遍本实现，把它吐出来的东西抄进 `expect`

`bin/vector_forge.dart` 就是为这条规则服务的：它把实现的实际输出写到
`build/vectors/forged/`，**并显式拒绝对 `test_vectors/` 写入**。
它产出的东西是给人看的对照表，不是可以被消费的期望值。

## 当前覆盖范围

| 套件 | 覆盖 |
| --- | --- |
| `container_header` | 76 字节文件头的字节布局、魔数、算法 ID、取值约束 |
| `container_trailer` | 40 字节文件尾 + 密文摘要校验（「损坏」vs「密码错」的可区分性） |
| `container_layout` | 文件区段切分与严格长度校验 |
| `kdf_params` | Argon2id 参数范围（安全边界）与三套预设 |
| `ulid` | ULID 编码/解析/合法性/同毫秒单调性 |
| `money` | 定点金额的渲染、解析、求和与币种相等性 |
| `merge` | 记录版本裁决与收敛性（可交换 / 幂等 / 可结合） |

**M2 的加密向量（`kdf.argon2id.derive`、`aead.aes256gcm.seal` / `.open`、
`keyring.wrap-dek`）刻意尚未入库。** 原因不是没时间，而是：
它们的期望值必须由独立的参考实现生成（argon2 CLI / OpenSSL），
而 M0 阶段还没有可信的产出通道。先摆一个空壳占位会得到一个
「看起来覆盖了、实际什么都没测」的假绿灯 —— 那比缺覆盖危险得多。

对应的驱动已经注册（见 `packages/pf_testkit/lib/src/drivers/m2_crypto.dart`），
`kind` 契约已经固定，M2 落地时只需把 `isImplemented` 翻成 `true` 并补向量。

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

# M0 验收清单

> 本文件是 M0 阶段的**验收标准**，不是进度汇报。
> 判定标准只有一条：**下列命令全部按预期退出**，且结果与「期望」一列一致。
> 任何一条不满足，M0 就不算完成 —— 不允许用「剩下的下个阶段补」结账。
>
> 本文件同时是**关卡定义的事实来源（single source of truth）**：
> `.github/workflows/*.yml` 与 `melos.yaml` 里的脚本都应能在这里找到对应解释。
> 两边不一致时以本文件为准，并改代码。

---

## 0. M0 的目标与非目标

### 目标

把「以后改错了会很难查」的东西**在写业务代码之前**先钉死：

| # | 交付物 | 钉住的是什么 |
|---|---|---|
| 1 | monorepo 骨架（`melos.yaml` + 各包 `pubspec.yaml`） | 依赖方向。层与层之间只能单向引用，越界由静态分析当场发现 |
| 2 | CI 三关卡（`.github/workflows/`） | 「本地能跑」与「合并进主干」之间没有缝 |
| 3 | 黄金测试向量框架（`packages/pf_testkit` + `test_vectors/`） | 数据锁住行为。**代码变了要改数据，而不是改代码去迁就数据** |
| 4 | 依赖黑名单检查（`tools/guards`） | 隐私承诺不是文档里的一句话，是一条会失败的构建 |
| 5 | 本文件 | 上面四样到底算不算「完成」，由可执行的命令回答 |

### 非目标（M0 明确不做，做了就是越界）

- **不写任何记账业务逻辑**：没有账户、分类、账单、统计。
- **不实现加密**：`.pfb` 容器的**字节布局**已被向量钉死，但 KDF / AEAD / 密钥环
  的实现留到 M1。
  更正（2026-09-16）：这里原文写「相关向量现在处于 `pending` 状态，且被基线记录在案」，
  与事实不符。`test_vectors/pending_baseline.json` 的 M0 基线是**空数组**，
  且 M0 阶段本就没有加密原语的向量 —— 因为按方案 §7.6 的顺序原则，
  **期望值必须由独立参考实现生成**（Python `argon2-cffi` / `cryptography`），
  不能先摆一个空壳占位。加密向量与 M1 的原语实装同期落地。
- **不接 SQLite、不接平台能力**：`pf_data` 只有迁移编排的纯逻辑，没有真实库文件。
- **不出可发布产物**：`apps/pf_mobile` 是一个能跑起来的骨架页，不是 App。

**判定方式**：`apps/pf_mobile/test/smoke_test.dart` 里有一条**反向断言** ——
断言界面上**不存在**任何记账入口。M0 阶段这条测试必须持续通过与 M1 起必须被改写，
它是一道防止「顺手先把 UI 搭起来」的闸。

---

## 1. 交付物清单

```
pf-wallet/
├── .flutter-version                     # 3.29.0，CI 与本机共用的唯一版本来源
├── melos.yaml                           # 任务编排（不负责依赖解析）
├── pubspec.yaml                         # pub workspaces 根：workspace: 成员列表
├── analysis_options.yaml                # 全仓 lint 基线
├── .github/workflows/
│   ├── gate1-static.yml                 # 关卡 1 · 静态门禁（仅 ubuntu）
│   ├── gate2-test.yml                   # 关卡 2 · 测试门禁（三平台）
│   └── gate3-vectors.yml                # 关卡 3 · 向量门禁（三平台 + 跨平台一致性）
├── apps/pf_mobile/                      # 应用壳（M0 仅骨架页 + 冒烟测试）
├── packages/
│   ├── pf_core/                         # 零依赖底座：错误码 / ULID / Money / 版本常量
│   ├── pf_crypto/                       # 加密原语（M1 已实装 SHA-256 / HKDF-SHA256 / AES-256-GCM；Argon2id / 密钥环留到 M2）
│   ├── pf_data/                         # 存储与迁移编排
│   ├── pf_io/                          # 导入导出、记录版本与合并裁决
│   ├── pf_ui/                           # 主题与通用组件
│   └── pf_testkit/                      # 黄金向量框架（驱动 / 判定 / 报告 / 基线）
├── test_vectors/
│   ├── v1/*.json                        # 121 条黄金向量（含 M1 的 hkdf_sha256 12 条 + aes256gcm 12 条）
│   ├── schema/vector.schema.json        # 向量文件自身的 JSON Schema
│   ├── pending_baseline.json            # 尚未实现的向量的**基线**
│   └── README.md
├── tools/
│   ├── guards/                          # 依赖黑名单 / 禁用 API / 日志脱敏 / 平台清单 / 版本号
│   └── ci/compare_verdicts.py           # 跨平台判定摘要比对
└── docs/M0_ACCEPTANCE.md                # 本文件
```

### 依赖方向（单向，由 `dart analyze` 强制）

```
        pf_core
       ┌───┴───┬────────┐
   pf_crypto pf_data  pf_io
       └───────┴────┬──┘
                   pf_ui
                     │
                apps/pf_mobile
```

规则：**箭头只能向上指**。`pf_core` 不得出现在任何地方的反向依赖里 ——
它是唯一被所有包依赖、且自己不依赖任何包的层。
破坏这条规则的后果不是「编译不过」，而是「加密包里出现了 UI 概念」这类
半年后才会咬人的事情。

---

## 2. 三关卡的定义

### 关卡 1 · 静态门禁 —— 只在一台机器上跑

**为什么只跑 ubuntu**：这一关校验的是「源码文本」与「入库路径」是否合规（格式、lint、
依赖声明、禁用 API、日志脱敏、平台清单、版本号、被提交的路径、向量覆盖）。这些都是平台无关的判断，
在三台机器上重复跑只会把 CI 时间乘以 3，不会多发现一个 bug。

```bash
melos run ci:gate1      # = format → analyze → guards（6 项）→ vectors:coverage
```

| 步骤 | 命令 | 失败意味着 |
|---|---|---|
| 格式 | `dart format --output=none --set-exit-if-changed apps packages tools` | 有人提交了未格式化的代码（**不自动改写**，因为自动格式化会把 lint 失败的责任从作者挪走） |
| 静态分析 | `melos exec --fail-fast -- flutter analyze --fatal-infos --fatal-warnings` | 存在 lint / info 级问题。**info 也算失败**：`// ignore` 一旦能随手加，lint 就退化成建议 |
| 依赖门禁 | `guards deps` | 出现了遥测 SDK / 后端 SDK / 非白名单来源，或 review 分类依赖未登记、登记已过期 |
| 禁用 API | `guards banned-api` | 出现了动态执行、反射、网络客户端、设备指纹类调用 |
| 日志脱敏 | `guards logging` | 敏感值（密钥、主密码、金额）被写进日志或异常消息 |
| 平台清单 | `guards manifest` | Android `allowBackup` 未关、权限超集、iOS 备份排除缺失 |
| 版本一致性 | `guards version` | `PfBuildInfo.appVersion` 与各 `pubspec.yaml` 的 `version` 不一致 |
| 入库路径 | `guards tracked-paths` | **被提交的路径**里有禁止入库的文件（构建产物 / 本地状态 / 数据库 / 密钥 / 安装包 / 日志）、大小写折叠后重名的路径，或不在白名单内的新区域。它是唯一一条读 `git ls-files --cached` 的检查 —— 其余七条查的都是「内容」，只有它查「哪些路径进来了」（3ebe837 混进 `.flutter_tool_state` 时三关卡全绿，原因就是缺这一条） |
| 向量覆盖 | `vectors:coverage` | 有**已实现**的驱动没有任何向量引用它。这种状态下列表全绿 —— 没有用例被执行，自然没有用例失败 —— 于是「先写实现、后补向量」可以一路绿灯通过三关卡。它守的是方案 §7.6 的第一条顺序原则（见 `test_vectors/README.md`「顺序：向量必须先于实现」），且因为与被测平台无关，放在单平台关卡而不是三平台矩阵 |

### 关卡 2 · 测试门禁 —— 三个平台都跑

**为什么必须三平台**（这是本关卡存在的全部理由）：

- **Windows 与 POSIX 的路径语义不同**：分隔符、大小写敏感性、非法字符集、长路径。
  导出文件名拼接、临时目录清理这类逻辑只在其中一个平台上坏掉是常态。
- **`rename` 对已存在目标的语义不同**：本项目的「先写 `.tmp` 再 rename」原子写
  依赖这个语义，而 Windows 上的行为与 POSIX 不一致。
- **macOS 默认大小写不敏感，Linux 敏感**：把 `Ledger` 与 `ledger` 当两个文件的项目
  在两者上都「能跑」，但行为不一致。

```bash
melos run ci:gate2      # = test（含覆盖率）
```

`fail-fast: false` 是刻意的：**「只在 Windows 上失败」这个结论本身就是最有价值的信息**，
一旦 fail-fast，它就被压缩成一句含糊的「某处失败」。

覆盖率产出 `coverage/lcov.info` 并上传为 artifact，**但不设阈值门禁**。
阈值只会催生「为凑数而写的断言」；它的用途是 review 时看改动碰到的位置有没有测试。

### 关卡 3 · 向量门禁 —— 三个平台跑 + 跨平台一致性

```bash
melos run ci:gate3      # = vectors
melos run vectors:pending   # 只看尚未实现的（观察 M1/M2 待办）
```

分两步：

1. **三平台各跑一遍全部黄金向量**，各自产出一份报告（含 `verdictDigest`）。
2. **`tools/ci/compare_verdicts.py` 比对三份报告的 `verdictDigest`**。
   摘要是「`caseId|status` 行的 SHA-256」，因此只要有一条用例在某个平台上
   判定不同，摘要就不同。

**为什么第 2 步不是多余的**：向量在两台机器上都「通过」，但如果 A 平台把某条判成
`pending` 而 B 平台判成 `pass`，说明**实现按平台走了不同分支**——
这正是「Windows 上能用、iPhone 上算错」的成因。
只比「都通过了吗」永远发现不了这种差异，因为它不是失败，是**不一致**。

`compare_verdicts.py` 的退出码：`0` 一致、`1` 不一致、`2` 拿到的报告不足两份
（**`2` 不是「通过」** —— 拿不到三份报告说明上传/下载环节出了问题，
把它当通过等于让关卡在最需要它的时候闭嘴）。

---

## 3. 三条红线

以下三条不是风格约定，是**造这个项目的理由**。任何一条被突破，M0 就算白做。

### 红线一 · 数据锁住行为

`test_vectors/v1/*.json` 里的期望值，**只能靠改数据来变更，不能靠改断言来通过**。

- 向量是**独立计算**的（Python 的 `hashlib` + 手写的字节布局），
  不调用被它校验的那份 Dart 实现。否则实现错了、向量跟着错，测试全绿。
- 需要看当前实现到底产出什么时，用 `melos run vectors:forge`。
  它**只写 `build/vectors/forged/`，并显式拒绝 `--out` 指向 `test_vectors/`**
  —— 对照表是给人看的，不得被直接回写进向量文件。
- 修改向量必须在 PR 描述里写清「为什么是这个新值」。

### 红线二 · 不合法数据不许被「尽量解释」

遇到解不出的元数据（版本戳不是 ULID、指纹长度不对、容器头魔数不符），
**返回错误或 `null`，不许兜底**。具体地：

- 版本戳解不出时间 → `updatedAtMilliseconds` 是 `null`，**不是 0、不是当前时间**。
  兜底成「现在」会让一条损坏的记录在 LWW 里直接赢掉同组合法记录。
- 容器校验失败时，**先比尾部摘要再报错**，从而在不拿主密码的前提下区分
  「文件损坏」与「密码错误」—— 这两个提示对用户的意义完全不同。
- 宁可让用户看到一次明确的失败，也不要让他得到一个看似正常的错值。

### 红线三 · 隐私承诺必须是可执行的构建门禁

「不上传数据」这句话写在文档里等于没写。它必须是一条会失败的检查：

- 依赖黑名单**包含传递依赖** —— 遥测 SDK 最常见的进入方式不是直接依赖，
  而是「某个 UI 组件库顺手带进来的」。
- `banned-api` 覆盖动态执行与反射，它们是最常见的绕过编译期检查的手段。
- `logging` 检查覆盖**字符串插值**：`'key=$dek'` 和 `'key=${dek.value}'` 都在扫描范围内，
  密钥出现在日志调用实参里也在范围内。
- `manifest` 检查 `allowBackup` 与权限超集 —— 前者让 `adb backup` 拿到整个私有目录。

**例外只能显式登记，不能静默放行**。确需绕过时用 `// guards:ignore <rule-id>`，
且必须紧邻一行说明理由。CI 会把 ignore 的数量计入 warning 供 review 观察。

---

## 4. 两条只增不减的棘轮

### 4.1 pending 基线

`test_vectors/pending_baseline.json` 记录「哪些向量尚未实现」。规则：

| 情形 | 判定 | 为什么 |
|---|---|---|
| 出现基线里没有的 pending | **失败**（`added`） | 实现**倒退**了 —— 本来能算的东西现在算不出来了 |
| 基线里的 pending 已消失但基线没更新 | **失败**（`resolved`） | 基线**过期**。基线一旦允许「只是没更新」，它就会慢慢变成一张废纸 |
| 两者一致 | 通过（`clean`） | |

更新方式：`dart run packages/pf_testkit/bin/vector_report.dart --update-baseline`
—— **必须与实现改动同一个提交**，不允许「先合并实现，基线回头再补」。

M0 的基线是**空的**（`pending: []`）。这是有意的：M0 交付的每一条向量都已实现。
M2 引入加密实现的向量时，基线才会第一次出现内容。

### 4.2 向量数量地板

`packages/pf_testkit/test/real_vectors_test.dart` 断言向量总数 ≥ 90（当前 121）。
它拦的是**成批误删** —— 删掉一条向量不会让任何东西变红，只会让覆盖悄悄变薄。
**有意缩减向量集时必须连这个数字一起改**，那正是希望被看见的动作。

---

## 5. 版本号一致性

三条规则，由 `guards version` 强制：

1. `PfBuildInfo.appVersion`（`packages/pf_core/lib/src/version.dart`）
   == **所有**带 `version:` 字段的成员 `pubspec.yaml` 的 `version`（去掉 `+build` 后缀）。
2. `.flutter-version` 是 CI 与本机共用的唯一 Flutter 版本来源，
   两边都必须读它，不得各写一份。
3. `PfSchema.current == PfBuildInfo.schemaVersion`，且 `PfSchema.initial == 1`。

**为什么值得一条门禁**：本项目的核心风险之一是「两台设备上的 App 版本不同」。
版本号不一致时，最容易发生的不是崩溃，而是「A 导出的文件 B 读出来少了几条，
但没有任何报错」。

---

## 6. 验收执行

### 一次性复现全部三关卡（本机）

```bash
flutter pub get          # 注意：必须用 flutter 而非 dart —— 工作区含 Flutter 成员
melos run ci:all         # = gate1 → gate2 → gate3
```

`melos run pub:get` 等价于 `flutter pub get`（见 `melos.yaml`，脚本里已写死 `flutter`）。
用 `dart pub get` 会因为解析不到 Flutter SDK 内的包而失败。

### 逐项勾选

| # | 命令 | 期望 | 本次实测 |
|---|---|---|---|
| 1 | `melos run pub:get` | 成功，仓库根生成单一 `pubspec.lock`，成员无独立 lock | ✅ 8 个 workspace 成员解析通过（root `workspace:` 列表 8 项） |
| 2 | `melos run format` | `Formatted 76 files (0 changed)` | ✅ 0 changed |
| 3 | `melos run analyze` | 每个包 `No issues found!` | ✅ 全仓 0 issue |
| 4 | `melos run guards:deps` | `error=0`（warning 允许，见下） | ✅ error=0 warning=11 |
| 5 | `melos run guards:banned-api` | `error=0` | ✅ error=0 |
| 6 | `melos run guards:logging` | `error=0` | ✅ error=0 |
| 7 | `melos run guards:manifest` | `error=0` | ✅ error=0 warning=2 |
| 8 | `melos run guards:version` | `error=0` | ✅ error=0 |
| 9 | `melos run test` | 全包通过 | ⚠️ 纯 Dart 包全通过（pf_core 91 / pf_crypto 57 / pf_data 19 / pf_io 23 / pf_testkit 34 / guards 61）；`pf_mobile` 的 3 条 widget 测试需 `flutter test`，本机开发沙箱**阻断了 flutter_tester 子进程的启动**（`flutter test --verbose` 停在 artifacts 检查之后，无任何测试输出）。静态分析已覆盖其类型正确性，实际执行交给关卡 2 的三平台 CI<br>**CI 补充（提交 `36206c6`）**：三个平台的第 9 步断言全绿 ⇒ 3 条 widget 测试在 macOS / Windows / Ubuntu 上均真实执行并通过 |
| 10 | `melos run vectors` | `全部已实现向量通过`，失败 0、待实现 0 | ✅ M0 时 98 条通过，摘要 `f573cf9de746…`；M1 补入 `hkdf_sha256` 后 109 条通过，摘要 `aec08f7118a0…`；M1 再补入 `aes256gcm` 后 **121 条通过，摘要 `8d25210b3c4b…`**<br>**口径**：`verdictDigest` 是「`caseId\|status` 行」的 SHA-256（见 §2 关卡 3），因此**新增向量必然改变它**，这不是回归。真正的判据有两条且只此两条：① 失败与待实现均为 0（老用例一条都没坏）② 三平台摘要彼此相同（关卡 3 的 `跨平台判定一致性`）—— 拿摘要与上一个版本比对，在两版向量集合不同时是无意义的 |
| 11 | `melos run vectors:pending` | 与基线一致（M0 为空） | ✅ 无 pending |
| 12 | `python3 tools/ci/compare_verdicts.py <三份报告>` | 三平台摘要一致 | ✅ 关卡 3 的 `跨平台判定一致性` 作业通过（提交 `36206c6`，4 个作业全绿）<br>本机仍只能产出一份报告 —— 比对工具会以退出码 2 拒绝少于两份的输入，这是刻意的：一份报告的「一致」没有意义 |
| 13 | `melos run guards:tracked-paths` | `error=0` | 🆕 **M1 期间补入的门禁**（不是 M0 的交付物）。本机实测：`trackedFiles=118 deniedPaths=0 caseCollisions=0 unexpectedPaths=0` → PASS。反例已验证：把 `.flutter_tool_state`、`build/…/ledger.db`、`scripts/publish.sh` 依次 `git add` 进索引，三条规则各自命中、退出码 1（详见 `M0_CI_RUNBOOK.md` §3 的「P1 · 入库路径检查」）。<br>口径：`trackedFiles` 是**当时索引里的文件总数**，会随正常提交增长（115 → 118 是补入这道门禁自身的 3 个新文件所致）；判据是 `deniedPaths/caseCollisions/unexpectedPaths` 三项为 0，不是这个数字本身 |
| 14 | `melos run vectors:coverage` | `✓ 覆盖检查：N 个驱动全部有向量引用` | 🆕 **M1 期间补入的门禁**。本机实测：`27 个驱动全部有向量引用` → PASS。<br>反例已验证：用 `--vectors` 指向只含一个套件的临时目录时，退出码 1 并列出 21 个无人引用的 kind（详见 `M0_CI_RUNBOOK.md` §3 的「P1 · 向量覆盖检查」）。<br>它堵的是这样一条路径：**先写实现、再补向量** —— 这种状态下报告全绿（没有用例被执行，自然没有用例失败），三关卡都不响，而向量已经退化成「实现算出什么就接受什么」。<br>能力边界（明确，不夸大）：它只能查「有没有向量」，查不了「期望值是不是独立生成的」—— 后者没有机器判据 |

### 允许存在的 warning

warning **不失败**，但每次 review 都要看：

- `guards:deps` 的 warning：`deps_allowlist.yaml` 里**未被任何已解析依赖命中**的条目
  （例如 `device_info_plus` 这类「已评估并明确拒绝」的记录）。
  它们的存在是**故意的** —— 让后来者知道这个包已经被想过一次，不必重新捡起来。
- `guards:manifest` 的 warning：尚未创建的平台配置（iOS 的 `PrivacyInfo.xcprivacy`
  在 M0 还没有对应文件）。

> **上表里的文件数与用例数是 M0 当时的实测值，不是判定线。**
> 第 2 行的判定线是「`0 changed`」，第 9 行的判定线是「全部通过」——
> 新增文件后它们是 79 files / guards 80 项，依旧满足。
> 会变的数字写死进文档只会制造「文档错了」的错觉，所以改口径、不改结论。

---

## 7. M0 完成的判定

> **推进到 CI 的操作步骤、三关卡的预期行为、CI 特有失败的排查清单，
> 以及本次判定所依据的运行记录 —— 见 `docs/M0_CI_RUNBOOK.md`。**
> 本节只回答「算不算完成」，那本回答「怎么让它完成」。

> **状态：M0 已完成（依据：提交 `36206c6` 的 CI 运行，8 个作业全部 `success`）。**
> 下面是判定条目与证据。

同时满足以下全部条件，M0 视为完成：

- [x] 第 6 节 1–8、10、11 项全部符合期望（关卡 1 与关卡 3 的本地部分已全绿）
- [x] 第 6 节第 9 项：`pf_mobile` 的 3 条 widget 测试在能启动 `flutter_tester`
      的环境上通过 —— 由 CI 关卡 2 在**三个平台**上代跑并通过
      （依据：第 2 次运行的第 9 步「断言 widget 测试确实执行」为 `success`，
      该步骤只有在「执行并通过 ≥ 3 条」且「三个必需用例名全部出现」且
      「无任何跳过」时才返回 0，因此它的绿即为证据，不是仅凭测试进程退出码）
- [x] 第 6 节第 12 项在 CI 上跑通（三份报告均由对应作业产出并上传为 artifact）
- [x] 三关卡在 CI 上均为绿色 —— 第 2 次运行 `36206c6`：8 个作业全部 `success`
- [x] `test_vectors/pending_baseline.json` 与实现一致（M0：空）
- [x] 本文件无「待补」标记

### CI 运行记录（按时间追加，作为上面各项的证据）

| # | 提交 | 关卡 1 | 关卡 2 | 关卡 3 | 说明 |
|---|---|---|---|---|---|
| 1 | `a451c04` | ✅ 绿（15 步） | ❌ 第 9 步红 | ✅ 绿（4 作业） | 关卡 2 失败见 `M0_CI_RUNBOOK.md` §3 P0-5：`flutter test` 未加 `--no-pub`，隐式 pub get 的 37 行文本混进 JSON 报告，断言工具以退出码 2 拒绝。**这是设计生效的证据**：若只看测试进程退出码，第 8 步是绿的，M0 会带着「widget 测试从未真正执行」的空洞绿勾通过 |
| 2 | `36206c6` | ✅ 绿（15 步） | ✅ 绿（3 平台 × 11 步） | ✅ 绿（4 作业） | 修复后 8 个作业全部 `success`；关卡 2 的三个平台均通过第 9 步断言 |
| 3 | `b0de874` | ✅ 绿 | ✅ 绿 | ✅ 绿 | 本文件的收尾提交（仅文档变更）触发的第三次运行，8 个作业同样全部 `success` —— 记录在此是因为它验证了「收尾提交本身没有引入回归」 |

第 2 次运行（判定 M0 完成的依据）：

- 关卡 1：`https://github.com/xiaoHuoTongZhi/pf-wallet/actions/runs/34957692314`
- 关卡 2：`https://github.com/xiaoHuoTongZhi/pf-wallet/actions/runs/34957692352`
- 关卡 3：`https://github.com/xiaoHuoTongZhi/pf-wallet/actions/runs/34957692332`

第 3 次运行（收尾提交 `b0de874`，仅文档变更）：

- 关卡 1：`https://github.com/xiaoHuoTongZhi/pf-wallet/actions/runs/34958499329`
- 关卡 2：`https://github.com/xiaoHuoTongZhi/pf-wallet/actions/runs/34958499257`
- 关卡 3：`https://github.com/xiaoHuoTongZhi/pf-wallet/actions/runs/34958499327`

第 1 次运行（保留作为反例）：

- 关卡 1：`https://github.com/xiaoHuoTongZhi/pf-wallet/actions/runs/34956960094`
- 关卡 2：`https://github.com/xiaoHuoTongZhi/pf-wallet/actions/runs/34956960006`
- 关卡 3：`https://github.com/xiaoHuoTongZhi/pf-wallet/actions/runs/34956960108`

> 记录第 1 次失败的意义不在于「失败过一次」，而在于它验证了一个判断：
> 那条断言拦住了一个会让 M0 带着空洞绿勾通过的接线错误。
> 三条 widget 测试在**本机沙箱里从未被执行过**（`flutter_tester` 起不来），
> 也就是说它们的「通过」只可能来自 CI —— 这正是第 6 节第 9 项
> 必须由能跑 `flutter_tester` 的环境来判定的原因。

`docs/M0_CI_RUNBOOK.md` §5.2 记录了 M0 之后的第一件事，**已于提交 `3ebe837`
（`main` 现为 `ad90673`）执行**：`smoke_test.dart` 第 3 条用例的反向断言
从「MVP 阶段不得出现任何『记账』入口」升级为「未解锁时不得出现任何可写入账目的界面」，
第 2 个提交里同步改了关卡 2 里 `--require` 的第三个字面量 ——
改名绕过门禁必须是一次看得见的修改。三关卡于该提交全绿
（gate2 `https://github.com/xiaoHuoTongZhi/pf-wallet/actions/runs/35065249221`
的第 9 步断言为 `success`，而它要求的第三个用例名正是新名，
所以它的绿同时证明「新断言真的执行了」与「在新断言下确实通过」）。

### 明确不在 M0 判定范围内的

- 真实设备上的运行表现（M0 没有可安装产物）
- 加密实现（Argon2id / 密钥环仍在 M2；AES-256-GCM 已在 M1 实装并由向量锁定）
- 覆盖率数字（只上传，不判定）

---

## 8. 附录 · 本次验收实际抓到的三个问题

这三条都是**在跑第 6 节的命令时当场暴露的**，不是事后补记。
留在这里的理由：它们证明了这套门禁不是仪式 —— 如果 M0 结束时一条问题都没抓到，
更可能的解释是门禁没真正在跑。

### 8.1 ULID 解码表与编码表不一致（由关卡 3 抓到）

`packages/pf_core/lib/src/ulid.dart` 里「字符 → 5 位取值」曾写成 ASCII 算术：

```dart
if (codeUnit >= 0x41 && codeUnit <= 0x5A) return codeUnit - 0x41 + 10;
```

Crockford 字母表跳过了 `I / L / O / U`，因此 `'J'` 的真实取值是 **18** 而不是 19，
`'Z'` 是 **31** 而不是 **35**（35 已超出 5 位可表示范围）。

**故障表现**：不报错、不抛出，只是**静默解出另一个时间戳**。
实测 `01JGFJJZ00…` 被解成 `1770050391040`（巧合地接近「现在」），正确值是 `1735689600000`。
由于**版本戳的字典序就是合并算法的全序**，这个偏差的最终表现是
「多设备同步偶尔丢改动」——一个和 ID 看起来毫无关系的故障。

**修复**：唯一真相改为字母表本身（`_decodeTable` 查表），编码与解码因此互为逆运算；
`_isDecodable` 也改为查同一张表，不再各写一份判断。
测试侧补了 4 条回归用例，其中一条**逐个校验 32 个取值的往返**。

**顺带修的两处**：
- `pf_core/test/ulid_test.dart` 里的规范示例字符串抄错
  （`01ARZ3NDEK…` 应为 `01ARYZ6S41TSV4RRFFQ69G5FAV`），
  导致 2 条断言长期在验证一个错的常量。已改为规范原文并注明「必须用外部锚点」。
- `merge.version.validity` 的两条向量互相矛盾（同一条「按合法性给不给时间」的规则
  同时要求 `null` 与具体值）。已统一口径为**按版本戳能否解出来决定**，
  并补一条 `invalid-stamp` 用例专门守住「解不出来就给 `null`，不许猜」。

### 8.2 门禁测试依赖了被它保护的文件的「当前内容」（由关卡 2 抓到）

`tools/guards/test/guards_test.dart` 的「review 分类未登记 → 失败」用了一个真实存在的包名，
并假设它**恰好还没被登记**。给真实 `deps_allowlist.yaml` 补上该条目后，这个用例
悄无声息地变成了「已登记 → 通过」——**覆盖丢了，但测试仍然绿色**。

**修复**：用例改为自己写一份空的登记表（`writeEmptyAllowlist()`），
包名从真实 `deps.yaml` 的 review 列表里取。夹具自己控制前提，不再随真实规则漂移。

### 8.3 迁移测试把「生产护栏」当成了绊脚石（由关卡 2 抓到）

`MigrationPlan.build` 的 `maxSupportedVersion` 默认值是 `PfSchema.current`（M0 为 1）——
这是**生产安全性质**：用户手机上装的是旧版 App，却打开了新版写过的库，必须立刻停下。
但迁移链测试需要 4~5 个版本才谈得上「多步排序」「断裂检测」，
于是这些用例在默认值下全部被 `PFD_E_SCHEMA_TOO_NEW` 提前拦下。

**修复**：测试显式传递 `maxSupportedVersion`（参数本就是这个用途），
并**额外补一条用例专门守默认值**：不显式抬高时，目标超版一律拒绝。
否则「把默认值改大」这个危险动作将没有任何测试会发现。

---

## 9. 下一个阶段（M1）的入口条件

M1 只有在下面两件事都成立时才开始 —— **两条均已满足，M1 已开工**：

1. **M0 验收通过**，且三关卡在 CI 上为绿。
2. **`apps/pf_mobile/test/smoke_test.dart` 的反向断言被有意改写**
   —— 也就是「界面上还没有记账入口」这条断言必须先在代码里被删掉。
   这是刻意的仪式：M0 的护栏不能靠遗忘来拆除，只能靠一次**看得见的修改**。

   **已执行（`3ebe837`）**：断言升级为「入口存在但被锁住」，三条判据
   （入口存在且唯一 / 点击后落在 `UnlockPage` 且离开 `BuildStatusPage` /
   账目字段仍不得出现），并同步改了关卡 2 的 `--require`。
   注意这里没有「删掉」也没有「拆掉」：升级后覆盖面比原来更大 ——
   原来的断言只拦「入口存在」，现在还拦「入口做出来了但没上锁」和
   「点了没反应」。护栏的目的（别让用户把真实数据写进没保护的地方）没变。

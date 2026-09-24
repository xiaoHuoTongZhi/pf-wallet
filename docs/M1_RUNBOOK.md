# M1 收口手册

> 阅读对象：要按顺序把 M1 收口推完、并要自己复现每一节结论的人（也就是你自己）。
>
> 本文只写**已经落地**的三节：**命令行工具（`pf`）**、**跨实现验证**、
> **引擎适配**。M1 收口的其余步骤（`#1a` / `#5b` 的五条读写命令 / `#1b`）
> 在各自落地时再补进本文 ——
> 写在这里的规则只有一条：**每一节都必须给出「本机怎么复现」与「看到什么才算通过」**，
> 否则那一节就不该存在（结论无法复现的手册，读起来像承诺）。

> **本机执行环境的两个前提**（踩过，写下来免得再踩）：
>
>   1. 下面所有命令都在 **Git Bash** 里执行。`cmd.exe` 里没有 `grep` / `wc` /
>      `diff`，而 `&&` 链在 PowerShell 里也不是同一回事。
>   2. 跑 `dart` / `melos` 之前先设好 `FLUTTER_ROOT`，而且**必须是 Windows 风格路径**
>      （`C:/...`，不是 `/c/...`）。写成 POSIX 形式时，`dart pub get` 会因为
>      「Because pf_ui requires the Flutter SDK」而整体失败 ——
>      报错与路径写法看起来毫无关系，实质就是它。
>
>      ```bash
>      export FLUTTER_ROOT="C:/Users/huoyu/.workbuddy/binaries/flutter/flutter"
>      unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
>      ```
>
>      第二行同样不是可选的：本机的代理会劫持测试运行器的本地 WebSocket，
>      表现为 `dart test` 卡在 loading 上几分钟不返回。

---

## 1. 命令行工具 `pf`（`tools/pf_cli`）

### 1.1 它为什么存在

导入器的正确性在 M1 阶段是**由导入器自己**证明的（向量 + 单测）。CLI 提供的是
**另一条独立入口**：它不进应用、不碰数据库、不依赖 UI，因此它能回答一类
测试答不了的问题 ——「**用户手上这个具体文件，到底怎么了**」。

这条定位决定了它的两条设计约束：

| 约束 | 为什么 |
|---|---|
| 依赖方向只向下（`pf_cli → pf_io → pf_data → pf_crypto → pf_core`） | 工具包若被产品代码引用，发布产物里会多出一个 CLI。这条由 `guards:deps` 守 |
| **走与导入器同一条代码路径**，不复刻解密流程 | 复刻会让 CLI 验的是**另一个实现**，于是「`pf verify` 通过」不再等于「导入器能读」—— 而 CLI 作为独立验证工具的全部价值恰恰在这里 |

第二条不是口号，它在代码里有一个具体落点：`verify` 与 `info --records` 都调用
`PfbImportReader.read()`，而不是自己拼一条「读头部 → 派生密钥 → 开容器」的链。

### 1.2 命令与各自的定位

| 命令 | 需要密码 | 走到哪一层 | 回答的问题 |
|---|---|---|---|
| `pf info <file>` | 否 | 容器头部 + 免密完整性（§4.3 阶段 A+B） | 这是不是一份 PFB？结构是什么？字节有没有被动过？ |
| `pf info <file> --records` | **是** | 一直到载荷层（阶段 A–D） | 里面的**四层产物**分别长什么样（供跨实现 diff，见第 2 节） |
| `pf verify <file> --password-file <f>` | 是 | 一直到载荷层（阶段 A–D） | 这份文件能不能被完整读出来？逐表条数是多少？ |
| `pf engine [--engine-lib <so>]` | 否 | 只碰原生库，**不碰任何文件** | 这台机器上的库能不能打开？打开的是不是 SQLCipher？（见第 3 节） |
| `pf --version` | 否 | — | 版本与格式版本（容器 v1.x / 载荷 v1） |
| `init` / `seed` / `export` / `import` / `dump` | — | — | 需要 SQLCipher 的读写命令，在 `#5b` 落地 |

**`info` 默认不解密**是它的核心价值：用户说「这个文件打不开」而还没决定要不要
输密码时，它是唯一能给答案的命令。

**`--records` 是这条原则的唯一例外，而且是有意的**：逐条清单只存在于解密之后，
没有密码就没有它。它同时**换掉输出格式**（见 §1.4）。

### 1.3 退出码契约（三个值，不可合并）

| 码 | 含义 | 调用方该做什么 |
|---|---|---|
| `0` | 成功，且结论为「是」 | 继续 |
| `1` | **业务结论为「否」**：文件损坏 / 密码错 / 载荷违规 | 换文件或换密码。**不要去修工具** |
| `2` | **工具故障**：用法错误、文件读不到、环境缺依赖 | 修命令或修环境。CI 必须把它当成故障 |

把这三种混成「非零即失败」的最坏结果是：一次 `verify` 因为**路径写错**返回非零，
被解读成「备份文件损坏」。因此 CI 里的反例判定写的是 `!= 1` 而不是 `!= 0`。

三态分流在导入器里是 `triageImportFailure`（纯函数，见 `import_file.dart`），
CLI 的 `status` 词由 `status.dart` 从稳定错误码映射而来。

### 1.4 stdout 协议（三种模式，互不重叠）

| 模式 | 输出 | 用途 |
|---|---|---|
| 默认 | 人读的行，**结果行永远最后写** | 手工排查 |
| `--json` | NDJSON，每行一个 JSON 对象，**末行固定是 `{"type":"result",…}`** | 脚本 |
| `info --records` | **规范报告本体**（第 2 节的四层文本） | 跨实现 diff |

`--records` 与 `--json` **互斥**（同时给是用法错误，退出码 2）。不是懒得支持：
NDJSON 的契约是「末行是结果行」，而规范报告要逐字节 diff —— 两者共存会让
「报告不一致」与「协议不一致」混成同一处失败，而它们的排查方向完全不同。

`--records` 模式下**诊断一律走 stderr**，报告只走一个出口（`--out` 文件，或 stdout）。

### 1.5 密码来源（只有两条，且刻意没有第三条）

```
--password-file <f>      从文件读（推荐）
环境变量 PF_PASSWORD     直接给出密码
```

**刻意不提供 `--password <明文>`**：命令行参数会同时留在 shell 历史
（`~/.bash_history`、PSReadLine）与进程列表（`ps -ef`）里。备份密码出现在这两处
就等于泄露，而备份密码泄露等于整个账本泄露。把这条捷径直接堵掉，比写文档劝人别用有用。

读密码文件时会剥两样东西，**只剥这两样**：

* UTF-8 BOM（Windows 记事本「另存为 UTF-8」会加）；
* **末尾一个**换行（`echo secret > pw.txt` 会带）。

**不做整段 trim** —— 前后空格是密码的一部分。剥多一个换行同样算改密码：
`decodePasswordBytes` 只剥一个，末尾两个 `\n` 会剩一个，于是那份文件打不开 ——
这是对的，不是 bug。

### 1.6 本机自测（怎么跑、看到什么才算通过）

```bash
cd tools/pf_cli

# ① 静态门禁：格式 + 分析（infos 一律致命）
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos --fatal-warnings .
#   通过 = 「0 changed」与「No issues found!」

# ② 单测（含走真文件系统、真环境变量的那一组）
dart test
#   通过 = 「All tests passed!」

# ③ 覆盖率（同进程执行的行才计入，所以入口做成了函数而不是塞在 bin/ 里）
dart test --coverage=coverage
```

端到端手验（需要一份真 `.pfb`；样本可以从被向量锁死的 fixture 里现落，
见 §2.3，因为它本身不能入库）：

```bash
# 版本
dart run tools/pf_cli/bin/pf.dart --version          # → 0，打印容器/载荷版本
# 不解密诊断
dart run tools/pf_cli/bin/pf.dart info build/cross/sample-full.pfb          # → 0
dart run tools/pf_cli/bin/pf.dart --json info build/cross/sample-full.pfb   # → 0，末行 type=result
# 完整校验
dart run tools/pf_cli/bin/pf.dart verify build/cross/sample-full.pfb \
  --password-file build/cross/password.txt                                   # → 0，报出 8 类 counts
```

| 看到什么 | 说明 |
|---|---|
| `info` → 0，且 `integrity` 行里 `issued=false`（非 `--json` 时是 `intact=false`） | 文件被改过。**不要**再往下试密码 |
| `verify` → 1 且错误码是 `PFI_E_WRONG_PASSWORD` | 文件完好，只有密码不对 |
| `verify` → 2 且 stderr 有「读不到文件」 | 路径不对，属工具故障 |
| `--json` 的末行不是 `{"type":"result",…}` | **协议被破坏**，脚本会读错结论。这比功能缺陷更严重 |

---

## 2. 跨实现验证（`tools/ci/pfb_cross_check.py` + gate3 的 `cross-impl` 作业）

### 2.1 它补的是哪一类证据

黄金向量已经证明了「两套实现算出的**加密原语中间值**一致」：AES-GCM 的密文、
Argon2id 的密钥、链式 AAD 的三条快照 —— 但这些期望值全部由 `tools/golden_vectors_gen/`
里的那套 Python 独立实现算出，核的是**逐函数**的正确性。

逐函数正确**不蕴含**端到端一致。下面这些都可能在「每个函数都对」的前提下两边不同：

* 分块顺序、AAD 链的拼接；
* `contentHash` 的覆盖边界（`[48, 长度-32)` —— 少一字节就错）；
* 行切分（以换行结尾时是 N 行还是 N+1 行）；
* JSON 的键序与转义（`jsonEncode` 与 `json.dumps` 的默认行为不同）。

因此本节要验的是**同一个 `.pfb` 交给两套完整实现，沿途四层产物逐字节相同**。

### 2.2 四层绑定

| 层 | 绑定的对象 | 它能抓到、而别的层抓不到的差异 |
|---|---|---|
| 1 | 文件字节 | 输入本身。先钉住它，后面每一层的差异才有意义 |
| 2 | 压缩载荷（容器明文 = gzip 流） | 容器层解对了没有 —— 与「解压对不对」是两件事 |
| 3 | 记录行（解压后 NDJSON 的**逐行**字节摘要） | 行的切分与顺序。只给全区摘要时，「两行对调、字节数不变」会被掩盖 |
| 4 | 逐条清单（每行**键排序后**的紧凑 JSON）+ contentHash / 条数 / 逐表 counts | 含义。第 3 层绑字节，第 4 层绑语义，互为补充 |

第 4 层绑的是「行」而不是「库表列」（默认值、派生的 `dayKey`、被丢弃的缓存余额）：
那是 §4.1 的规范，且已由 `import.payload.decode.*` 向量核对过 —— 那边的期望值同样
来自同一套 Python 独立实现。在这里再抄一遍字段表，只会得到**第二张会与第一张分叉的表**，
而分叉那天不会有任何东西变红。

### 2.3 两侧各自的产出

```bash
# ① 从被向量锁死的 fixture 里落出样本（不碰密码学）
python3 tools/ci/pfb_cross_check.py emit-fixture \
  --sample sample-full --out-dir build/cross
#    → build/cross/sample-full.pfb          容器文件本体（hex 直接取自 fixture）
#    → build/cross/password.txt             密码，**带一个末尾换行**（echo 的写法）
#    → build/cross/sample-full.expect.json  期望值，取自 fixture（fileSha256 /
#                                           payloadSha256 / contentHash /
#                                           recordCount / counts）

# ② Dart 侧
dart run tools/pf_cli/bin/pf.dart info build/cross/sample-full.pfb \
  --records --password-file build/cross/password.txt \
  --out build/cross/sample-full.dart.txt

# ③ Python 侧（同时与自己那份期望值逐项比对）
python3 tools/ci/pfb_cross_check.py check \
  --file build/cross/sample-full.pfb \
  --password-file build/cross/password.txt \
  --expect build/cross/sample-full.expect.json \
  --out build/cross/sample-full.py.txt

# ④ 判据本体
diff -u build/cross/sample-full.dart.txt build/cross/sample-full.py.txt
```

**为什么 `.pfb` 与两份报告都落在 `build/` 下**：`.pfb` 在 `tracked_paths` 的 `deny`
名单上（它是用户数据，入库等于把某个人的真实账目放进公开仓库），`build/` 同样在
deny 名单上。因此样本只能现落、且只能落到不会被误提交的地方。

**复用而不是复制**：容器解密**只有一处实现** —— `tools/golden_vectors_gen/container_pfb.py`
的 `open_pfb`。本节的 Python 脚本 `import` 它而不复制。复制一份解密流程的代价不是
多几十行，而是「两份会分叉的 Argon2/AES 参数」，而分叉的表现是**校验通过但文件其实读不出来**。

**规范报告里刻意不含**：文件名、路径、实现名、版本号、时间戳。出现任何一样，
「同一份文件换个目录跑」或「换个版本跑」都会变成一次假失败。

### 2.4 为什么要用 `--require-hashes`

另一套实现的依赖是 `argon2-cffi` / `cryptography`。它们一旦浮动，红与绿的原因就
不再是「我们改坏了什么」，而是「上游改了实现」—— 而 Argon2 与 AES-GCM 的输出
**不因实现不同而不同**，所以那种红只会是「取到了一个改过算法或改过打包的上游」，
正是最需要拦下的一类变化。

只钉版本不够：版本号相同、内容被换掉（重新上传 / 镜像投毒）无法察觉。
`tools/ci/requirements.txt` 因此把**产物字节**也钉死：

```bash
python3 -m pip install --require-hashes -r tools/ci/requirements.txt
```

覆盖范围是 sdist + manylinux x86_64 轮子 + win_amd64 轮子（CI 与本机都在这三类里）。
**换平台或换 Python 次要版本时 pip 会报 `THESE PACKAGES DO NOT MATCH THE HASHES` ——
这是预期行为**，按报错里的期望哈希补一行 `--hash=` 即可；补哈希的动作会出现在 diff 里，
那是这份文件刻意要留下的摩擦。CI 用 `actions/setup-python` **显式钉住 Python 3.12**：
轮子标签含 Python 版本，不钉住解释器，上面那条报错就会看起来像投毒。

### 2.5 反例（必须，且两边都要拒绝）

```bash
python3 tools/ci/pfb_cross_check.py tamper \
  --file build/cross/sample-full.pfb --out build/cross/tampered.pfb --offset 60

dart run tools/pf_cli/bin/pf.dart verify build/cross/tampered.pfb \
  --password-file build/cross/password.txt ; echo "dart=$?（期望 1）"

python3 tools/ci/pfb_cross_check.py check \
  --file build/cross/tampered.pfb --password-file build/cross/password.txt \
  --out build/cross/tampered.py.txt ; echo "python=$?（期望 1）"
```

取偏移 **60** 是有意的：它在**头 CRC 的覆盖范围（`0..43`）之外**、
在 **contentDigest 的覆盖范围（`48..长度-32`）之内**。于是两边都应当落到同一个结论 ——
「内容损坏」，而不是「结构损坏」。这两个结论在导入器里对应不同的用户动作，
反例要压的是前者：

| 期望 | 实际含义 |
|---|---|
| `pf verify` → **1** | 免密摘要先挡，且**没有再试解密**（继续试只会把「文件坏了」报成「密码错」） |
| `pfb_cross_check.py` → **1** | 容器层断言失败（`open_pfb` 的 `content digest` 断言），不是脚本崩了 |
| 任一侧 → **2** | 工具故障。**这不算通过** —— 它会以「检查不通过」的样子掩盖真正的故障 |

### 2.6 CI 落点

落在 **gate3（`gate3-vectors.yml`）的 `cross-impl` 作业**，**单平台**（`ubuntu-latest`），
**不新建 gate4**：

* 它验的是「两套实现是否一致」，与被测平台无关 —— 放进三平台矩阵只是把同一个结论
  重复三遍，代价却是三倍的 Flutter 安装与 pip 安装；
* 它与 gate3 的其余作业同源（都在回答「容器与载荷的发布格式对不对」），
  多一个关卡名不会多一条判据。

作业步骤与上面的手验命令一一对应，另外把**四份产物一起 artifact 化**：
`sample-full.pfb` + `sample-full.expect.json` + `sample-full.dart.txt` + `sample-full.py.txt`。
只看「绿了」无法回答「当时两份文本长什么样」，而**失败现场才是真正需要看它们的时刻**
（因此上传步骤带 `if: always()`）。

唯一一处与手验不同的地方：CI 用 `diff` 的退出码判定，失败时把 diff 输出原样打进日志 ——
「第几层开始不同」是排查时唯一有用的第一条信息。

### 2.7 CI 实测记录（`697a0a1`，2026-09-24）

本节的价值在**怎么取到这些数**，而不是这些数本身 —— 数字会过期，取数的方法不会。

```
GET /repos/{owner}/{repo}/actions/runs?head_sha=<完整 40 位 SHA>
GET /repos/{owner}/{repo}/actions/runs/{run_id}/jobs        # 作业与逐步结论
GET /repos/{owner}/{repo}/actions/runs/{run_id}/artifacts   # 产物清单
```

三个必须知道的取数细节（都踩过）：

1. `head_sha` **只认完整 40 位**；给短 SHA 会**静默返回 `total_count=0`** ——
   看起来像「这个提交没跑 CI」，其实是查询写错了。
2. 产物下载（`archive_download_url`）会 302 到 CDN 签名 URL，而 **Python 的 `urllib`
   跟随重定向时会保留 `Authorization` 头** → CDN 拒绝 → `401`。
   解法：用一个 `HTTPRedirectHandler` 子类让 `redirect_request` 返回 `None`（拿到 302 的
   `Location` 而不跟随），再用**不带 auth 的 opener** 打开它。
3. 作业日志（`/actions/jobs/{id}/logs`）需要的权限比产物高，可能直接 403。
   **产物比日志好取**；只有「每包测试计数」这类信息必须读日志。

实测结果（run `35968515856` / `59` / `62`，三份均为 `completed / success`）：

| 项 | 实测 |
|---|---|
| gate3 `跨实现 PFB 校验` 作业 | 出现且绿；12 步全过，含「两份报告必须逐字节相同」「反例：翻转第 60 字节 ⇒ 两边都必须拒绝」 |
| gate3 三平台判定摘要 | 三份 `verdictDigest` **逐字符相同** = `c3ab29aab1d5687dacda7cdbeb499096adae4dcdca73721830a046a4afbe1df7`；`total/passed/failed/pending` = `242/242/0/0` |
| `cross-impl` 产物 | 四份齐全：`sample-full.pfb` 1564 B、`sample-full.expect.json` 611 B、两份报告各 7170 B；**两份报告的 SHA256 相同**（`76b06ba919cbfe58…`） |
| gate1 / gate2 步骤 | **未变** —— 本提交只改了 `gate3-vectors.yml` 一个 workflow 文件，另两个的步骤定义字节未动 |
| 附带 | gate1 覆盖报告 `ok:true`、`drivers=44/44`、`vectors=242`、orphan 全 0；`tools/pf_cli` 覆盖率 **294/295 = 99.66%**（三平台一致） |

> 上面第 2 行的「三平台摘要相同」在第 3 行的 compare 作业里被单独断言过一次
> （「跨平台判定一致性 → 比对判定摘要」）。两处都看，才知道**是摘要真的相同**，
> 而不是**比对步骤被跳过了**。

---

## 3. 引擎适配（SQLCipher 原生库 · 身份自检 · 两个适配器）

这一节回答的问题是：**在把任何 `PfDb` 交出去之前，怎么确认手里这个原生库真的会加密**。

它之所以值得单列一节，是因为它对付的是一类**不报错**的事故：
纯 SQLite 会静默接受全部 `cipher_*` PRAGMA，于是"打开流程全部成功、库文件也写出来了"，
而文件头是 `SQLite format 3\0`。这类事故不会让任何一条既有测试变红，
因为它没有失败，它只是悄悄地什么都没加密。

### 3.1 定版原生库：为什么自己取、取哪一份

移动端那条路（`sqflite_sqlcipher` + `sqlcipher_flutter_libs`）走 Flutter 插件机制，
在纯 Dart 的 `pf_cli` 与 Linux CI 上都拿不到句柄。所以桌面/CI 这条路必须自己带库 ——
而"自己带库"意味着必须回答"带的是哪一份、凭什么信它"。

| 来源 | 结论 |
|---|---|
| `sqlite.org` 官方 `sqlite3.dll` | **不是 SQLCipher**（纯 SQLite，没有加密层），已列为反例 |
| Windows 自带的 `winsqlite3.dll` | **不是 SQLCipher**，已列为反例 |
| `sqlcipher3-wheels` 的 `.pyd` | 拒绝：它是 CPython 扩展模块，只导出 `PyInit__sqlite3`，`ctypes` 试 17 个 `sqlite3_*` 符号命中 **0** |
| Zetetic 官方商业构建 | 拒绝：授权与可复现性都不可控 |
| vcpkg / msys2 / conda | 拒绝：版本与编译选项随包管理器漂移，钉不住 |
| **NuGet `SQLitePCLRaw.lib.e_sqlcipher` 2.1.11** | **采用**：六个平台的预编译 SQLCipher，包与成员都能被 sha256 钉死 |
| **NuGet `SQLitePCLRaw.lib.e_sqlite3` 2.1.11** | **采用（只作反例）**：纯 SQLite，用来证明"拦得住" |

实测（Windows x64，`ctypes` 直接调符号，不走 Dart）：

| 库 | 文件 | `sqlite3_libversion()` | `PRAGMA cipher_version` | 写出的库文件头 |
|---|---|---|---|---|
| `e_sqlcipher.dll` | 1852928 B，sha256 `895c0f52…` | `3.39.2` | **1 行** `4.5.2 community` | 密文 |
| `e_sqlite3.dll` | 1795072 B，sha256 `4dcbb2ad…` | `3.49.1` | **0 行** | `SQLite format 3\0`（明文） |
| `winsqlite3.dll`（系统） | — | `3.51.1` | **0 行** | `SQLite format 3\0`（明文） |

完整清单（六个平台 × 两个产物的路径 / 字节数 / sha256，外加整包 `.nupkg` 的 sha256）
与全部拒绝理由都在 **`tools/ci/native/engine_vendor.json`** —— 本节不复制那些哈希，
免得两处漂移。

取件是**两级校验**，缺一不可：

1. 整包 `.nupkg` 的 sha256 —— 网线对面给的东西对不对；
2. 解出的那个成员文件的 sha256 —— 我们的解压实现有没有解错。

只做第 1 级不够（解压 bug 会静默产出一份"包校验通过但内容不对"的文件），
只做第 2 级也不够（要先把整包下下来才能解，而整包本身也得被钉住）。

产物落在 `build/native/engine/<runtime>/`，**不入库**（`build/` 在 `.gitignore`
与 `tracked_paths` 的 deny 名单里）；库里只留下那份清单。
取件脚本 `tools/pf_cli/bin/fetch_engine.dart` 因此是**整条链上唯一需要联网的环节**，
而且它是幂等的：目标文件已存在且摘要相符就直接复用，CI 里第二次调用是纯本地操作。

### 3.2 探针：`pf engine`，以及"一个进程一个引擎"

`pf engine` 只做一件事：加载一个原生库，问它一句 `PRAGMA cipher_version`，然后裁决。

```
pf engine                          # 不给库 ⇒ 交给 package:sqlite3 的平台默认选择
pf engine --engine-lib <path>      # 显式指定
PF_SQLCIPHER_LIB=<path> pf engine  # 环境变量（优先级低于命令行）
```

**没有第三档默认值。** 缺省那条路故意留给 `package:sqlite3` 的平台默认选择，

| 平台 | 默认加载顺序 |
|---|---|
| Windows | `sqlite3.dll` → `winsqlite3.dll` |
| Linux | `libsqlite3.so`（`sqlite3_flutter_libs` 内嵌符号 → 系统库） |
| macOS | 进程内符号 → `/usr/lib/libsqlite3.dylib` |

——**这三条路上都没有 SQLCipher**。于是缺省必然以 `PFD_E_ENGINE_NOT_CIPHER` 失败，
而不是悄悄降级成明文。这正是我们要的行为：少给一个库，命令必须响。

`package:sqlite3` 把已加载的句柄缓存在模块级变量上，首次访问之后**无法更换**。
所以本仓把它显式化：

* `Sqlite3Engine.bind()` 是**进程单例**：同一个 isolate 里第二次用**不同**路径调用会抛
  `StateError`，而不是静默复用旧引擎 ——「我到底在测哪个引擎」必须永远有确定答案；
* 对比多个候选库只能**换进程**（`pf engine` 各跑一次）。测试文件也是按这条纪律切的：
  `engine_sqlcipher_test.dart` / `engine_plain_test.dart` /
  `engine_platform_default_test.dart` / `engine_unavailable_test.dart` 各占一个 isolate，
  因此每一条结论都能回答"它测的是哪个库"。

### 3.3 判据：为什么只有 `cipher_version`（两个被证伪的替代判据）

判定"这个库是不是 SQLCipher"的**唯一**可靠信号是 `PRAGMA cipher_version` 的**行数**。

两个看起来更直观的判据都试过，都当场被证伪：

| 被证伪的判据 | 为什么不行 |
|---|---|
| 「有没有报错」 | 纯 SQLite 对**全部** `cipher_*` PRAGMA 都返回成功：`PRAGMA key`、`cipher_compatibility`、`cipher_page_size`、`cipher_memory_security` 一个不报错，`CREATE TABLE` 也真的建了表。所以"命令跑通了"在这里**没有信息量** |
| `sqlite3_libversion()` | SQLCipher 报的是**它内嵌的 SQLite 版本**（`3.39.2`），与有没有加密层无关；而纯 SQLite 报 `3.51.1`，比它更"新"。按这个判据会把纯 SQLite 判成 SQLCipher |

判定规则落在 `packages/pf_data/lib/src/sqlite3/engine_verdict.dart`，
而且是**纯函数**（`judgeEngine` 的输入是字符串，输出是枚举，不碰 FFI）——
因为"打开一个库、读一条 PRAGMA"没法在任意平台上跑（CI 的 macOS 上没有
`winsqlite3.dll`），但**规则**必须处处一致、处处可测。切分之后：

* 「纯 SQLite 必须被拦下」这条最关键的规则有不依赖任何原生库的单元测试
  （`packages/pf_data/test/sqlite3/engine_verdict_test.dart`）；
* FFI 那一层只剩"采集事实"（`engine.dart` 的 `observeLibrary`），它不裁决。

两类失败**分开编码**，因为处置方向相反：

| 情况 | 错误码 | 命令行 status | 该做什么 |
|---|---|---|---|
| 库找不到 / 架构不符 / 缺符号 | `PFD_E_ENGINE_UNAVAILABLE` | `engine-unavailable` | 装库、修路径、换架构 |
| 库能加载但不是 SQLCipher | `PFD_E_ENGINE_NOT_CIPHER` | `engine-not-sqlcipher` | 换一个构建 |

合并成一个码，调用方就只能靠字符串猜 —— 而这两条路的动作没有交集。

### 3.4 适配器：`Sqlite3Session` / `Sqlite3Db`

打开流程（§3.4 的规格）对驱动的全部要求是一个方法：执行一条语句、取回首行首列。
`Sqlite3Session` 就是这十几行 —— 它唯一的难点是**必须用 `select` 而不是 `execute`**：
`execute` 在无参数时走 `sqlite3_exec`，它丢掉结果集，而流程要读的正是
`PRAGMA user_version` 的值。用错会让"新库"与"库头不可解析"变成同一件事。

仓储层要的是另外三件事（多行读、参数化写、事务边界），落在 `Sqlite3Db`：

* 参数一律走 `?` 占位符 —— 用户输入（`name` / `note`）不进 SQL 文本，注入面从根上关掉；
* 事务用 `BEGIN IMMEDIATE`：马上拿写锁，让并发冲突以"等"而不是"写了一半才发现拿不到锁"
  的形式出现；
* 嵌套调用**合并**进外层（内层不单独 `BEGIN`/`COMMIT`）—— 否则"外层回滚"会在
  内层已经提交之后变成一句空话。这条有专门的用例（外层插入 + 内层插入 + 外层抛错 ⇒
  两行都必须消失）；
* `close()` 先发收尾语句（`PRAGMA optimize`、`wal_checkpoint(TRUNCATE)`）再 `dispose`：
  `wal_checkpoint` 是为了把 WAL 并回主库，否则 `.db-wal` 会留着最后一次事务的尾巴。

### 3.5 已知偏差与取舍（写下来，免得被当成 bug）

| 事项 | 现状 | 说明 |
|---|---|---|
| 事务内 `PRAGMA foreign_keys` | **是空操作** | SQLite 明文规定该 PRAGMA 在事务内无效。`MigrationRunner` 现在是在事务内发 `PRAGMA foreign_keys = OFF` 的，也就是说那一句实际没生效。不致命（外键约束在 DDL 期不检查，只在 DML 期检查），但"写了却不生效"必须留痕。要让它生效只能在 `BEGIN` **之前**发 —— 属迁移编排的改动，不随引擎适配一起做 |
| `Sqlite3Db` 只实现 `PfDb` | 够用 | `PfDatabase`/`PfTransaction` 那套完整生命周期（打开/关闭/只读事务/rekey）是 M2 移动端的活；命令行只有"打开→干活→关掉"一条路径 |
| 缺省库**必须失败** | 有意 | 见 §3.2。若哪天有人为了"本机方便"给它加一档默认值，`engine_platform_default_test.dart` 会立刻变红 |
| 取件需要联网 | 唯一一环 | 公司网络里要接代理：脚本读 `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY`（只认 `http://host:port`；`socks5://` 认不出就当直连，让失败停在"连不上"这一个事实上） |

### 3.6 本机自测（怎么跑、看到什么才算通过）

下面全部在 **Git Bash** 里执行（`cmd.exe` 里没有 `$( )` 与 `tail`）。

```bash
# ① 取件 —— 唯一联网的一步；幂等，重跑只做本地校验
dart run tools/pf_cli/bin/fetch_engine.dart
#   通过 = 末行 「status=ok」，且 artifacts=plain,sqlcipher
#   产物 = build/native/engine/<runtime>/e_sqlcipher.* / e_sqlite3.*（不入库）
#   清单 = build/native/engine/engine_paths.json

SQLCIPHER="$(dart run tools/pf_cli/bin/fetch_engine.dart --artifact sqlcipher --print-path)"
PLAIN="$(dart run tools/pf_cli/bin/fetch_engine.dart --artifact plain --print-path)"

# ② 正例：定版 SQLCipher
dart run tools/pf_cli/bin/pf.dart engine --engine-lib "$SQLCIPHER"
#   通过 = exit 0，且 kind=sqlCipher、cipherVersion=4.5.2 community、sqliteVersion=3.39.2

# ③ 反例 A：定版的纯 SQLite（我们钉死的那一份）
dart run tools/pf_cli/bin/pf.dart engine --engine-lib "$PLAIN"
#   通过 = exit 2，status=engine-not-sqlcipher，reason 里有「0 行」

# ④ 反例 B：什么都不给 ⇒ 平台默认（三平台上也都不是 SQLCipher）
dart run tools/pf_cli/bin/pf.dart engine
#   通过 = exit 2，status=engine-not-sqlcipher

# ⑤ 三组单测（pf_data 的判据与适配器、pf_cli 的四条引擎用例 + zip + 取件）
cd packages/pf_data && flutter test && cd ../..
cd tools/pf_cli && flutter test && cd ../..
```

| 看到什么 | 说明 |
|---|---|
| 反例返回 **0** | 引擎身份这道门失效了。立刻停下 —— 继续跑会写出**明文**库文件，而"写成功了"的假象一直保持到有人去翻文件头 |
| 反例返回 **1** | 退出码语义被改坏了。「引擎不对」是**环境不可用**（该装库/换构建），不是关于某份数据的业务结论。归到 1 会让 CI 把环境故障读成"这份备份有问题" |
| 正例 `cipherVersion=` 是空的 | 加载到了纯 SQLite（或加载路径被 `sqlite3.dll` 抢了）。看 `pf engine` 打出的 `path=` 与 `label=` |
| 第二次 `bind` 不同路径时报 `StateError` | **正确行为**，不是 bug。换库必须换进程 |
| 取件报 `digest-mismatch` | 上游包变了，或我们的解压坏了。两者都要人工看一眼：`engine_vendor.json` 里的 sha256 是唯一的判据 |

CI 落点在 **gate2（`gate2-test.yml`）的 `unit-tests` 作业**，三个平台各跑一次，
且**排在 `melos run test:cov` 之前**（那一组用例需要已落盘的库）：

1. `dart run tools/pf_cli/bin/fetch_engine.dart` —— 取件；
2. `pf engine --engine-lib <定版 SQLCipher>` —— 正例，必须 exit 0；
3. `pf engine --engine-lib <定版纯 SQLite>` —— 反例，必须 exit 2（脚本里显式比对退出码，
   不符就 `::error::` 并失败）。

第 2、3 步刻意做成**独立的一步**而不是只靠测试的退出码：它把三平台各自的结论打成人能读的
一行（库路径、sqlite 版本、cipher 身份串），而出错现场只有一次机会。
完整的断言集在 `tools/pf_cli/test/engine_*_test.dart`。


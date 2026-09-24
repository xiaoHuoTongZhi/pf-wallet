# M1 收口手册

> 阅读对象：要按顺序把 M1 收口推完、并要自己复现每一节结论的人（也就是你自己）。
>
> 本文只写**已经落地**的两节：**命令行工具（`pf`）** 与 **跨实现验证**。
> M1 收口的其余步骤（`#1a` / `#5b` / `#1b`）在各自落地时再补进本文 ——
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

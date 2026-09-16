# M0 收尾手册 · 把三关卡推到 CI 上跑通

> 阅读对象：要按下第一次 push、并处理第一次 CI 失败的人（也就是你自己）。
> 本文只谈**到 CI 全绿为止**要做的事。M1 不在这里，也不该在这里。
>
> 配套文件：`docs/M0_ACCEPTANCE.md`（M0 验收清单，本文最后一节说明它怎么更新）。

---

## 0. 这一步实际动了什么

M0 的本地部分已经全绿，但「本地全绿」与「CI 全绿」之间隔着三类只会在
CI 上暴露的东西：**工具链在另外两台操作系统上的行为**、**仓库里没有的字节级约定**、
**必须在真实 flutter_tester 上才能跑的 widget 测试**。下面这些改动只为了解决这三类问题。

### 0.1 新文件

| 文件 | 为什么必须存在 |
|---|---|
| `.gitattributes` | 行尾规范。**没有它，关卡 1 的 `dart format` 会在 Linux 上莫名失败**（本机是 Windows，检出/入库会变成 CRLF）。同时把 `test_vectors/**` 标为不转换 —— 那是字节级契约 |
| `.editorconfig` | 上面那件事的编辑器侧。只做 `.gitattributes`，编辑器仍会把 CRLF 写回工作区，于是 git 每次都报「文件已修改」而 diff 为空 |
| `packages/pf_testkit/lib/src/test_report.dart` | 解析 `flutter test --reporter json` 的报告，回答「用例执行了，还是被跳过了」 |
| `packages/pf_testkit/bin/assert_test_report.dart` | 上面那件事的命令行入口（退出码 0/1/2） |
| `packages/pf_testkit/test/test_report_test.dart` | 上面那个解析器的自防测试（20 条，覆盖 skipped / hidden / metadata.skip 三种信号） |
| `docs/M0_CI_RUNBOOK.md` | 本文件 |

**没有其他缺失文件。** 特别确认过一处容易被误认为缺口的地方：
`build/_gen/gen_vectors.py`（黄金向量的生成脚本）**故意不入库**——
它的头部写明「期望值必须能被独立推导与人工审阅，不能变成跑一遍脚本让实现自己写答案」。
`build/` 被 `.gitignore` 忽略正好落实了这个决定，不需要改。

### 0.2 改动的既有文件

| 文件 | 改动 |
|---|---|
| `pubspec.yaml` | `dev_dependencies` 增加 `melos: 6.3.2` —— 见 §3 的 P0-2，不这样 melos 在任何机器上都跑不起来 |
| `pubspec.lock` | 随之上浮 18 个包（melos 及其依赖） |
| `melos.yaml` | ① 头部写明 melos 的版本区间（6.3.0 ≤ v ≤ 6.3.2）；② `guards` / `ci:gate1` / `ci:gate2` / `ci:gate3` / `ci:all` 由 `steps:` 改为 `&&` 链 —— 见 §3 的 P0-3 |
| `tools/guards/rules/deps_allowlist.yaml` | 增加 `http` 条目（melos 经 pub_updater 带上来的传递依赖；没有任何 shipping 代码引用它） |
| `.github/workflows/gate1-static.yml` | ① melos 版本 6.3.3 → 6.3.2；② 修正 melos 可执行目录的推导（Windows 上 $_HOME/.pub-cache/bin 不存在）；③ `melos bootstrap` → `flutter pub get` |
| `.github/workflows/gate2-test.yml` | 同上三条，另加 3 个步骤：以 JSON 协议重跑 pf_mobile 的 widget 测试 → 断言未被跳过 → 上传报告 |
| `.github/workflows/gate3-vectors.yml` | 同上三条（无新增步骤） |
| `packages/pf_testkit/lib/pf_testkit.dart` | 导出新的 `src/test_report.dart` |
| `docs/M0_ACCEPTANCE.md` | 第 6 节两处数字随本次改动校正；第 7 节加一行指向本文 |
| `docs/M0_CI_RUNBOOK.md` | 首次 `git add -A` 后补：§1.2 增加 shell 前提说明框 + PowerShell 版检查 + 行尾检查（④）；§3 开头声明其命令需在 Git Bash 执行 |
| `packages/pf_crypto/test/container_format_test.dart`<br>`packages/pf_crypto/test/params_test.dart` | **仅行尾** CRLF → LF（389 / 238 处）。`.gitattributes` 已保证索引存 LF，但工作区残留 CRLF 会让 `git status` 反复显示「已修改」而 diff 为空，并使按行读源码的门禁在 CRLF 下行为不同。内容零改动（转后 md5 与索引逐字节一致） |

> **上表之后的追加改动（2026-09-15，M0 判定完成之后）**：三份 workflow 的
> `push` / `pull_request` 增加了 `paths-ignore`，纯文档提交不再触发 CI。
> 动机、代价与将来的坑见 **§1.6**；连推两次会让前一次的运行变 `cancelled`
> 这条容易误判的行为见 **§1.7**。
>
> **M1 期间追加（2026-09-16）**：新增第四条门禁 **入库路径检查**
> （`tools/guards/lib/checks/tracked_paths.dart` +
> `tools/guards/rules/tracked_paths.yaml` + 测试，并给 gate1 加了一个步骤），
> 补上「没有任何一关在回答『哪些路径被提交了』」这个盲区。
> 规则、白名单与失败时怎么分诊见 **§3 的「P1 · 入库路径检查」**；
> 关卡 1 的步骤表见 **§2.1**。

### 0.3 本机复检结果（改动后）

```
format     Formatted 81 files (0 changed)        ← M0 当时 76；判定线是 0 changed
analyze    No issues found!                      （--fatal-infos --fatal-warnings）
guards     6 项检查，error=0 warning=13          （deps 11 / manifest 2，均为刻意保留）
test       340 项，全通过：
             pf_core 91 / pf_crypto 72 / pf_data 19 / pf_io 23 / pf_testkit 55 / guards 80
vectors    98 条通过，失败 0，待实现 0，判定摘要 f573cf9de746…（与上一版逐字符相同）
新增工具    assert_test_report.dart 三条分支（0/1/2）逐一实测通过
```

> 上面这些数字里，`76 → 79` 与 `guards 61 → 80`（`5 项 → 6 项`）是
> 2026-09-16 上午补入第四条门禁（入库路径检查）带来的；`+19` 项测试 =
> `tracked_paths_test.dart` 16 条 + `guards_test.dart` 的 3 条集成用例。
> `79 → 81` 与 `pf_crypto 57 → 72` 是同日下午落地第一个加密原语
> （`src/digest.dart`：摘要契约 + SHA-256）带来的，`+15` 项测试 = `digest_test.dart`。
> 记录它是因为数字会一直变，而**判定线不变** —— 追数字本身没有意义，
> 有意义的是知道「它为什么变了」。

只在本机做过一次、CI 上会重做的关键验证：`dart pub global activate melos 6.3.2`
在本机成功（6.3.3 失败，见 §3 P0-1）。

---

## 1. 从当前状态到 CI 全绿的完整操作步骤

### 1.1 先决条件（本机）

```bash
# 三个命令都必须在 PATH 里，且 flutter/dart 来自同一套 SDK（.flutter-version = 3.29.0）
flutter --version
dart --version          # 期望 Dart 3.7.0（Flutter 3.29.0 自带）
```

`melos` 不必装在 PATH 里 —— 本仓库把它声明为根 `dev_dependencies`，
统一用 `dart run melos ...` 调用。这样做的代价是每次多约 1 秒启动开销，
换来的是「全局 melos 版本」与「仓库要求的版本」不可能不一致。

想让它更好打，可以（可选，非必需）：

```bash
# Windows（新开一个终端生效）：把 pub 全局可执行目录加入用户 PATH
setx PATH "%PATH%;%LOCALAPPDATA%\Pub\Cache\bin"

# Linux / macOS
echo 'export PATH="$PATH:$HOME/.pub-cache/bin"' >> ~/.bashrc
```

### 1.2 推送前：确认入库内容（只读，先看再动）

> **先说清 shell —— 本节命令不能在 cmd.exe 里直接粘贴。**
>
> `grep` / `wc` / `awk` 是 POSIX 工具，cmd 和「没装 Git 的 PowerShell」都没有它们，
> 直接粘贴会得到 `'grep' 不是内部或外部命令`；而 `\` 续行与跟在续行后的 `&&` / `||`
> 在 cmd 里会报 `此时不应有 &&`。**这是 cmd 的语法，不是仓库或配置的问题。**
>
> 两条可行路径，任选其一：
>
> | 做法 | 操作 |
> |---|---|
> | **A. Git Bash（推荐，§3 的排查命令也全在这一侧）** | 运行 `"C:\Program Files\Git\git-bash.exe"`（本机已装），然后执行下方 §1.2-A |
> | **B. PowerShell** | 执行下方 §1.2-B。本机已实测，输出整齐且不含 PowerShell 7 独有语法（5.1 可用） |
>
> 下方 §3 的排查命令同理：**凡出现 `grep` / `awk` 的片段，都在 Git Bash 里跑。**

#### 1.2-A · Git Bash（POSIX）

```bash
cd /d/workbuddy/pf-wallet

git init -b main      # 已经 init 过，跳过这行
git add -A

# ① 必须出现的三样东西
git status --short | grep -cE "\.github/workflows/gate[123]"    # 期望 3
git status --short | grep -c  "test_vectors/v1/"                # 期望 7 个向量文件
git status --short | grep -c  "pubspec.lock"                    # 期望 1

# ② 绝不能出现的东西（否则立刻停下，先修 .gitignore）
git status --short | grep -E "\.dart_tool|/build/|\.pfb$|\.pfk$|pf_wallet\.db|coverage/|\.flutter_tool_state" \
  && echo "✗ 有构建产物或密钥文件被暂存，停下" \
  || echo "✓ 无构建产物 / 密钥文件被暂存"

# ③ 看一眼总规模，确认没有把什么大文件拖进来
git status --short | wc -l

# ④ 行尾：工作区不应残留 CRLF（期望**无输出**）
#    残留 CRLF 的表现很隐蔽：git status 反复显示「已修改」而 diff 为空；
#    门禁脚本按行读源码时，以 $ 结尾的匹配在 CRLF 下行为不同。
git ls-files --eol | grep "w/crlf"
```

> **② 这一条为什么值得单独写出来**：2026-09-16 的提交 `3ebe837` 里混进了
> `apps/pf_mobile/.flutter_tool_state`（内容只有 `{"is-bot": false}`）——
> 那是 flutter_tools 在本机跑过一次命令后写的运行时状态。当时的 `.gitignore`
> 里没有这条规则，而**三关卡没有一关会发现它**：门禁查的是代码、依赖与向量，
> 没有任何一关在回答「哪些文件被提交了」。
>
> 事后补了两层：`.gitignore` 加规则（`ea78aee`）、上面加 grep 模式；
> 以及**新增的第四条门禁** `melos run guards:tracked-paths`
> （读 `git ls-files --cached`，见 §3 的「P1 · 入库路径检查」）。
> 后者才是真正的答案：人记得看的次数永远少于机器自动看的次数，
> 而 `.gitignore` 也拦不住 `git add -f`。
> 手动的 ①②③④ 仍然值得跑一遍 —— 但它们的定位已经从「唯一防线」
> 变成「推送前的最后一次确认」。

#### 1.2-B · PowerShell（5.1 可用，本机实测）

```powershell
cd D:\workbuddy\pf-wallet
$n = @(git diff --cached --name-only)

'① 总条目          : {0}'  -f $n.Count
'② workflow        : {0}  (期望 3)'  -f @($n | Where-Object { $_ -match '\.github/workflows/gate[123]' }).Count
'③ test_vectors/v1 : {0}  (期望 7)'  -f @($n | Where-Object { $_ -match '^test_vectors/v1/' }).Count
'④ pubspec.lock    : {0}  (期望 1)'  -f @($n | Where-Object { $_ -eq 'pubspec.lock' }).Count

$bad = @($n | Where-Object { $_ -match '\.dart_tool|/build/|\.pfb$|\.pfk$|pf_wallet\.db|coverage/' })
if ($bad.Count -eq 0) { '⑤ 产物/密钥      : 0  OK' } else { '⑤ 产物/密钥      : ' + $bad.Count + '  FAIL'; $bad }

$crlf = @(git ls-files --eol | Select-String 'w/crlf')
if ($crlf.Count -eq 0) { '⑥ 工作区 CRLF    : 0  OK' } else { '⑥ 工作区 CRLF    : ' + $crlf.Count + '  FAIL'; $crlf }
```

本机 2026-09-15 实际输出（可直接对照）：

```
① 总条目          : 114
② workflow        : 3  (期望 3)
③ test_vectors/v1 : 7  (期望 7)
④ pubspec.lock    : 1  (期望 1)
⑤ 产物/密钥      : 0  OK
⑥ 工作区 CRLF    : 0  OK
```

若你人在 cmd 里不想切终端，可把逻辑压成一行（`$` 在 cmd 中不被展开，可直接内嵌）：

```
powershell -NoProfile -Command "$n=@(git diff --cached --name-only); 'total {0}' -f $n.Count; 'forbidden {0}' -f @($n|Where-Object{$_ -match '\.dart_tool|/build/|\.pfb|\.pfk|coverage/'}).Count"
```

第 ② 步是这次唯一值得花时间检查的东西：**这个仓库的第一条纪律是
「用户数据与密钥永不入库」**，而 `.gitignore` 是唯一一道人工防线。

### 1.3 首次提交与推送

```bash
cd D:/workbuddy/pf-wallet

git -c user.name="PF Wallet" -c user.email="dev@localhost" \
    commit -m "M0: monorepo 骨架 + CI 三关卡 + 黄金测试向量框架 + M0 验收清单"

# 远端二选一
git remote add origin git@github.com:<owner>/pf-wallet.git        # SSH
# git remote add origin https://github.com/<owner>/pf-wallet.git  # HTTPS

git branch -M main
git push -u origin main
```

如果远端仓库还不存在，用 `gh` 一步建好并推（可选）：

```bash
gh repo create pf-wallet --private --source=. --remote=origin --push
```

> **公开还是私有**：私有仓库的 Actions 会消耗额度，且 macOS runner 按 **10 倍**计费
> （一个完整 push ≈ Linux 1×2 + Windows 2×2 + macOS 10×2 ≈ 26 分钟等效）。
> 本仓库不含任何凭据（已由 `.gitignore` + `guards` 双重保证），
> 若额度紧张可考虑公开；决定权在你，本文不做推荐。

### 1.4 GitHub 仓库设置

按顺序做完，缺一项的表现都很隐蔽。

**① Settings → Actions → General**

| 项 | 取值 | 理由 |
|---|---|---|
| Actions permissions | *Allow all actions and reusable workflows* | 用到 `actions/checkout`、`actions/upload-artifact`、`subosito/flutter-action` |
| Workflow permissions | *Read repository contents permissions* | 三个 workflow 都已显式声明 `permissions: contents: read`，这里收紧不会影响它们；artifact 上传走运行时令牌，不需要额外权限 |
| Allow GitHub Actions to create and approve pull requests | **不勾** | 本仓没有自动化 PR |
| Fork pull request workflows | 保持默认（需要批准） | 避免外部 PR 消耗额度 |

**② Settings → General → Artifacts and logs**

| 项 | 建议 | 说明 |
|---|---|---|
| Actions artifact and log retention | 90 天（默认即可） | 各 workflow 内已分别声明 `retention-days: 14`（门禁报告 / 覆盖率 / widget 报告）与 `30`（向量报告）。**真正需要长期留的是向量报告** —— 它是跨平台一致性的唯一凭据 |

**③ Settings → Branches（或 Rulesets）→ 保护 `main`**

顺序很重要：**先让三关卡跑出一次成功记录，状态检查才会出现在候选列表里。**

首次 push 后回到 Actions 页面，等三关卡跑完，然后在
Settings → Branches → *Add branch protection rule*（或 Rulesets → New ruleset → Require status checks）配置：

| 设置 | 取值 |
|---|---|
| Branch name pattern | `main` |
| Require a pull request before merging | 勾（1 个审批可关，本仓单人开发） |
| Require status checks to pass before merging | 勾 |
| ↳ 勾选的状态检查 | `静态门禁（格式 / 分析 / 自定义检查）`<br>`单元测试 · ubuntu-latest` / `· macos-latest` / `· windows-latest`<br>`黄金向量 · ubuntu-latest` / `· macos-latest` / `· windows-latest`<br>`跨平台判定一致性` |
| Require branches to be up to date before merging | 勾 |
| Do not allow bypassing the above settings | **勾**（自己绕过自己，等于没有门禁） |

最后一个勾是本文最想强调的一条：**分支保护的价值来自「谁都绕不过」**。
单人仓库里最容易发生的事，就是某天赶进度点了一下 *Merge without waiting*。

### 1.5 首次运行的建议顺序

> **不需要 `gh`。** 三份 workflow 的触发条件里都有 `push: branches [main]`，
> 所以**首次推送本身就会同时拉起三个关卡**，`gh workflow run` 只是
> 「补跑某一个」时的便捷入口，不是必经步骤。
> 本机没装 `gh`（`where gh` 无结果）时，用网页手动触发：
> 仓库页 → **Actions** → 左侧选中 workflow → 右上 **Run workflow** → 选 `main` → Run
> （这一项依赖 workflow 里有 `workflow_dispatch:`，本仓三份都有）。

推荐顺序（手动补跑时）：

```bash
# ① 先手动触发关卡 1（最快、最不依赖平台差异）
gh workflow run gate1-static.yml
gh run watch

# ② 绿了再跑关卡 3（三平台 + 一致性比对，依赖最少：只要 Dart + 向量文件）
gh workflow run gate3-vectors.yml
gh run watch

# ③ 最后跑关卡 2（最重，含 flutter_tester 与覆盖率）
gh workflow run gate2-test.yml
gh run watch
```

顺序的道理：关卡 1 失败几乎总是**接线问题**（工具链、路径、版本），
一次性排查完；关卡 2 失败几乎总是**代码或平台行为问题**，最值得单独花时间。
两者一起跑，日志会互相淹没。

M0 首推的实测结果印证了这个分层：关卡 1 一次绿、关卡 3 四个作业一次绿，
唯一的失败落在关卡 2 的第 9 步（见 §3 P0-5）。

### 1.6 文档提交不触发 CI（`paths-ignore`，2026-09-15 起生效）

三份 workflow 的 `push` 与 `pull_request` 都加了：

```yaml
    paths-ignore:
      - 'docs/**'
      - '**.md'
```

**改它的原因**：M0 收尾时发现「只改一个文档里的错字」也要跑满 3 平台矩阵
（含 macOS，按 10 倍计费）。而门禁读的是代码、向量与 workflow 自身，
`.md` 的变化不可能让任何一项检查的结论改变 —— 这份成本买到的是零信息。

**明确接受的代价**（写在这里，避免以后有人把它当成 bug）：

| 场景 | 行为 | 后果 |
|---|---|---|
| 一次提交**只**动 `docs/**` 或 `*.md` | 三关卡均不运行 | 该提交没有门禁记录。**「这次提交被验过」对它是假命题** |
| 代码 + 文档混在同一提交 | 照常触发 | 无影响 —— 有代码文件变化就不匹配 `paths-ignore` |
| 需要强制验证某次纯文档提交 | `workflow_dispatch` / 网页 Run workflow | 手动补跑，不受路径过滤影响 |

**别忘了这一点**：`workflow_dispatch` 是逃生口，所以「跳过」永远是可逆的。
反过来说，**不要**用「文档提交不会跑 CI」当作省略本地自检的理由 ——
`dart format --set-exit-if-changed` 与 `dart analyze` 在本机是秒级的，仍然照跑。

**一个已知的未来坑**：过滤器同时作用在 `pull_request` 上。若日后开了分支保护
并把三关卡设为**必需检查**，纯文档 PR 会因为「没有检查项」而永远等不到
required check 通过。届时把 `pull_request` 段下的 `paths-ignore` 删掉即可
（`push` 段的保留）—— 那一刻起，正确性优先于成本。

### 1.7 连着推两次，前一次的运行会被取消（不是失败）

**本机实测**（2026-09-16，同一分支相隔 34 秒的两次推送）：

| 提交 | 运行创建 | 结束 | 结论 |
|---|---|---|---|
| `ea78aee` gate1 / gate2 / gate3 | 06:45:45 | 06:46:20 ~ 06:46:27 | `cancelled` ×3 |
| `ad90673` gate1 / gate2 / gate3 | 06:46:19 | 06:47:32 ~ 06:48:57 | `success` ×3 |

两次运行**同时在跑**的时候，新推送到达 → 旧的三个 run 在 40 秒内被置为
`cancelled`。所以：

- **`cancelled` 不等于失败**，它常常只是「你 30 秒后又推了一次」。
  以它为红点去排查，方向从一开始就是错的。
- **门禁记录挂在「最新提交的树」上，不挂在每一个提交上**。
  中间那次提交（这里是 `ea78aee`）可能一次完整的绿都没有过 ——
  它无害的前提是**它的改动被后一个提交的树完整包含**（本例成立：
  `ad90673` 是 `ea78aee` 的子提交，树是超集）。
  若两次推送的改动互不包含，`cancelled` 的那次就是真的没被验过。
- **判据要按 sha 去对 run**，不要用「最近一次运行」。查法：

```bash
# 列出指定提交的全部运行及其结论（本机没装 gh，用 API）
python - <<'PY'
import json, urllib.request
REPO = "xiaoHuoTongZhi/pf-wallet"
SHA = "ad90673"          # ← 换成要看的前 7 位
op = urllib.request.build_opener(urllib.request.ProxyHandler({}))   # 显式绕开环境代理
req = urllib.request.Request(
    f"https://api.github.com/repos/{REPO}/actions/runs?per_page=40",
    headers={"Accept": "application/vnd.github+json", "User-Agent": "ci-watch"})
for r in json.load(op.open(req, timeout=30))["workflow_runs"]:
    if r["head_sha"].startswith(SHA):
        print(f'{r["name"]:15s} {r["status"]:11s} {r["conclusion"]}')
PY
```

**推论（重要）**：既然「最新的树」才是被验对象，那么把无关紧要的文档微调
与代码改动**分成两次推送**是有代价的 —— 文档那次会白跑一轮 CI（若它含
非 `docs/**` 文件），或者干脆取消掉前一次的运行。要省 CI 也省事，
就把它们合成一次推送。

---

## 2. 三关卡在 GitHub Actions 上的预期行为

### 2.1 gate1-static.yml · 只在 ubuntu 跑

| 项 | 预期 |
|---|---|
| 作业数 | 1（`static-gate`） |
| 平台 | `ubuntu-latest` |
| 超时上限 | 25 分钟 |
| 预期耗时 | **3–5 分钟**（冷缓存 6–8 分钟：Flutter SDK 缓存未命中时下载约 700 MB） |
| 并发策略 | 同分支新提交作废上一次（`cancel-in-progress: true`） |

步骤级预期：

| 步骤 | 成功时的关键输出 |
|---|---|
| 读取 Flutter 版本 | `version=3.29.0`（来自 `.flutter-version`，不是写死在 YAML 里） |
| 安装 Flutter | 缓存命中时约 10 秒；`flutter --version` 显示 3.29.0 / Dart 3.7.0 |
| 安装 melos | `melos 可执行目录：/home/runner/.pub-cache/bin` 且 `ls` 列出 `melos` |
| 解析工作区依赖 | `flutter pub get` 成功；根目录生成唯一 `pubspec.lock` |
| 打印工具版本 | `melos --version` → **6.3.2**（见 §3 P0-1：写成 6.3.3 这一步就红） |
| 检查格式 | `Formatted 79 files (0 changed)`（M0 当时是 76；判定线是 `0 changed`，不是这个数字） |
| 静态分析 | 每个包 `No issues found!` |
| 六个 guards | 每项 `error=0`（`deps` / `banned-api` / `logging` / `manifest` / `version` / `tracked-paths`） |
| 上传门禁报告 | artifact `guards-report-<sha>`，内含 `deps/banned-api/logging/manifest/version/tracked-paths.json` |

失败时最常见的四条：格式不一致（本机没跑 `dart format` 就提交）、
`guards:version`（改了 `PfBuildInfo.appVersion` 忘了改 pubspec）、
`guards:deps`（加了新的传递依赖未登记）、
`guards:tracked-paths`（把不该入库的文件加进了索引，或新增了未登记的区域 ——
见 §3 的「P1 · 入库路径检查」）。

### 2.2 gate2-test.yml · 三平台矩阵

| 项 | 预期 |
|---|---|
| 作业数 | 1 个矩阵作业 × 3 平台 |
| 平台 | `ubuntu-latest` / `macos-latest` / `windows-latest` |
| `fail-fast` | **false** —— 三个平台都跑完再汇报。「只在 Windows 上失败」这个结论本身就是最有价值的信息，`fail-fast` 会把它变成一个含糊的「某处失败」 |
| 超时上限 | 40 分钟（每平台独立计时） |
| 预期耗时 | ubuntu **4–6 分钟** / macOS **6–9 分钟** / Windows **7–10 分钟** |

每平台的步骤与预期：

| 步骤 | 预期 |
|---|---|
| 运行单元测试（含覆盖率） | 305 条全过（其中 pf_mobile 3 条走 flutter_tester）；产出 `**/coverage/lcov.info` |
| 运行移动端 widget 测试（JSON 协议报告） | `apps/pf_mobile` 下产出 `build/test-reports/pf_mobile.jsonl`（JSON Lines，每行一个事件） |
| 断言 widget 测试确实执行 | 输出「执行并通过 3 / 失败 0 / 跳过 0 / 合成 1」+ 三条 `✓` |
| 上传移动端测试报告 | artifact `mobile-widget-report-<os>-<sha>` |
| 上传覆盖率 | artifact `coverage-<os>-<sha>` |

**三平台都应当是同样的结果。** 若某个平台单独失败，先去 §3 按症状找，
不要先怀疑代码 —— 三个平台上跑的是同一批源码，差异只可能来自环境。

### 2.3 gate3-vectors.yml · 三平台 + 跨平台一致性

两个作业，有依赖关系：

| 作业 | 平台 | 预期 |
|---|---|---|
| `golden-vectors` | 三平台矩阵，`fail-fast: false` | 每平台 `向量 98 条：通过 98，失败 0，待实现 0`，上传 artifact `vectors-report-<os>-<sha>`（保留 30 天） |
| `verdict-consistency` | ubuntu，`needs: [golden-vectors]` | 下载三个 artifact 到 `reports/`，跑 `python3 tools/ci/compare_verdicts.py reports` |

`verdict-consistency` 的三种结果，含义完全不同：

| 输出 | 退出码 | 含义 |
|---|---|---|
| `✓ 3 个平台的判定完全一致（xxxxxxxx…）` | 0 | 通过。括号里是 `verdictDigest` 前 16 位，应与本机一致（M0 为 `f573cf9de746`） |
| `✗ 只找到 1 份报告，无法做跨平台比对` | 2 | **接线问题**，不是代码问题：`upload-artifact` 的 `name` 与 `download-artifact` 的 `pattern` 对不上，或 matrix 少跑了一个平台。这条被刻意做成失败而不是跳过 —— 「只跑了一个平台」不该被当成「三个平台一致」 |
| `✗ 跨平台判定不一致。逐条对比：` | 1 | **真的有平台差异**。报告会逐条列出 `用例 ID: 平台A=pass vs 平台B=fail` |

`verdictDigest` 的定义：把每条用例的 `caseId|status` 排序后求 SHA-256。
它**不看**耗时、时间戳、Dart 版本号、操作系统字符串 —— 直接 diff 三份 `report.json`
永远不等，那四类字段正是差异的来源。

判定摘要一致 = 三个平台对每一条向量得出了同一个结论。

---

## 3. CI 上会出现、本机不会出现的失败 · 按可能性排序

每条格式：**症状 → 定位命令 → 修复方向**。
标 `[已修]` 的是已经修掉的，保留下来是因为它们随时可能以别的形式回来。

> **首次推送（`a451c04`）实际命中的只有 P0-5。** P0-1～P0-4 在推送前就已修掉，
> 因此没在 CI 上出现过；它们的价值在于「如果哪天动了工具链版本，会以同样的面孔回来」。
> P0-5 是唯一一个必须靠 CI 才能暴露的问题（本机沙箱跑不了 flutter_tester，
> 那份报告在本地从来没被生成过），也就是本文存在的理由。

> **本节所有「定位命令」都假设你在 Git Bash 里执行**（用到 `grep` / `awk` / `while read`）。
> 在 cmd.exe 里会报 `'grep' 不是内部或外部命令` —— 那不是命令写错了，
> 是 cmd 没有这些工具。启动方式见 §1.2 开头的说明框。
> 只想在 cmd / PowerShell 里做那几条「看一眼」的检查时，**优先用 `git` 自带子命令**
> （`git ls-files --eol`、`git diff --cached --name-status`），它们与 shell 无关。

### P0-1 `dart pub global activate melos` 直接失败（SDK 版本冲突）`[已修]`

**症状**（发生在**任何一行代码被检查之前**，看起来与项目毫无关系）：

```
Because pub global activate depends on melos >=6.3.3 <7.0.0-dev.1
which requires SDK version ^3.8.0, version solving failed.
```

**定位命令**（本机就能复现，不需要等 CI）：

```bash
dart --version                                  # Flutter 3.29.0 自带 Dart 3.7.0
dart pub global activate melos 6.3.3            # 复现失败
dart pub global activate melos 6.3.2            # 应当成功
curl -s https://pub.dev/api/packages/melos \
  | python3 -c "import sys,json;[print(v['version'],(v.get('pubspec') or {}).get('environment',{}).get('sdk')) for v in json.load(sys.stdin)['versions'] if v['version'].startswith('6.3')]"
```

**修复方向**：melos 版本区间是 `[6.3.0, 6.3.2]`。
下界因为 6.3.0 起才识别 pub workspaces；上界因为 6.3.3 起要求 Dart 3.8。
CI 里钉的是 `MELOS_VERSION: 6.3.2`，根 `pubspec.yaml` 里也是 `melos: 6.3.2`，两处必须同步。
想抬这个上界，唯一办法是把 `.flutter-version` 升到 Flutter 3.32+，
而那是**工具链变更**，要连同 `dart format` 的结果一起重新验证，不能顺手做。

### P0-2 `melos` 能找到，但一跑就说「没有本地安装」`[已修]`

**症状**：

```
Found a melos.yaml file in "..." but no local installation of Melos.
From version 3.0.0, the melos package must be installed in a pubspec.yaml file
next to the melos.yaml file.
```

**定位命令**：

```bash
cd D:/workbuddy/pf-wallet
grep -n "melos" pubspec.yaml                    # 必须在 dev_dependencies 里
grep -n '"name": "melos"' .dart_tool/package_config.json   # 必须能被解析到
dart run melos --version                        # 期望 6.3.2
```

**修复方向**：melos 3.0 起**全局安装不再够用**，它要求「与 `melos.yaml` 同级的
`pubspec.yaml` 里有本地安装」。本仓库已在根 `dev_dependencies` 声明 `melos: 6.3.2`。
若哪天有人把它删掉并只保留全局安装，这条会立刻复发 —— 而报错发生在检查代码之前。

### P0-3 Windows 上 melos 的复合脚本会**静默通过** `[已修]`

**症状**：`melos run guards` / `melos run ci:all` 在 Windows 上报了一串
`'melos' 不是内部或外部命令`，最后却打印 `SUCCESS`，退出码 0。
CI 上不会出现（CI 用的是逐条叶子脚本），但**本地「跑一遍 ci:all 全绿」这句话因此失去意义**。

**根因**：melos 的 `steps:` 在 Windows 上生成的是这段 cmd：

```bat
echo "step" && melos run X || VER>NUL && if %ERRORLEVEL% NEQ 0 (echo __FAILURE_COMMAND_END__) else (echo )
```

cmd 的 `||` 与 `&&` 左结合，而 `VER>NUL` 又把 ERRORLEVEL 归零 —— 中间某步失败后
**既不会中止，也不会被识别为失败**。

**定位命令**（验证任何链式脚本是否真的会失败）：

```bash
# 造一个必然失败的命令，看它是否被吞掉（下面的路径请按本机替换）
cd D:/workbuddy/pf-wallet
dart run melos run __definitely_not_a_script__ ; echo "exit=$?"   # 期望非 0
```

**修复方向**：复合脚本一律用 `&&` 串联，不用 `steps:`（本仓库已全部改为 `&&`，见 `melos.yaml`）。
`&&` 由 shell 自己短路，失败立刻中止且退出码非零。实测确认：
叶子脚本失败 → `exit=1`；`&&` 链前一步失败 → 后一步**不执行**且 `exit=1`。

### P0-4 Windows 上 `melos` 根本没装进 PATH `[已修]`

**症状**：

```
melos: command not found          （bash 步骤）
'melos' 不是内部或外部命令        （pwsh / cmd 步骤）
```

**根因**：pub 全局可执行目录在三个平台上不在同一个位置：

| 平台 | 目录 |
|---|---|
| Linux / macOS | `$HOME/.pub-cache/bin` |
| Windows | `%LOCALAPPDATA%\Pub\Cache\bin` |

原来三份 workflow 都写的 `echo "$HOME/.pub-cache/bin" >> "$GITHUB_PATH"` —— 在 Windows 上那个目录**不存在**。

**定位命令**（本机就可以验证这段推导逻辑）：

```bash
# 只有 Windows 会进第一个分支；两个方向都必须转：先转 POSIX 再拼，最后转回 Windows 形式
if [ -n "${LOCALAPPDATA:-}" ] && command -v cygpath >/dev/null 2>&1; then
  PUB_BIN_POSIX="$(cygpath -u "$LOCALAPPDATA")/Pub/Cache/bin"
  PUB_BIN="$(cygpath -w "$PUB_BIN_POSIX")"
else
  PUB_BIN_POSIX="$HOME/.pub-cache/bin"; PUB_BIN="$PUB_BIN_POSIX"
fi
echo "写进 GITHUB_PATH: $PUB_BIN"; ls -1 "$PUB_BIN_POSIX"
# 期望（Windows）：C:\Users\<你>\AppData\Local\Pub\Cache\bin 且目录里有 melos.bat
```

**修复方向**：三份 workflow 的「安装 melos」步骤已改用上面的推导。
两个方向的转换都不能少：bash 里 `%LOCALAPPDATA%` 是反斜杠形式，直接拼 `/Pub/Cache/bin`
会得到一个 MSYS 判不出来的路径；而写回 `$GITHUB_PATH` 时必须是反斜杠形式，
因为 Windows 上后续步骤默认走 pwsh。

**同一根因的第二种面孔（2026-09-16 实测）**：复合脚本里**每一个叶子**都会再调用
一次 `melos`（`melos run guards:deps && melos run guards:banned-api && …`）。
若你是用 `dart run melos run guards` 这种方式启动链（即 `melos` 本身不在 PATH 上），
链会在第一个叶子上以这样的形式失败：

```
melos run guards
  └> melos run guards:deps && … && melos run guards:tracked-paths
     └> RUNNING
ERROR: 'melos' 不是内部或外部命令
     └> FAILED
ScriptException: The script guards failed to execute.
```

**这不是门禁失败**，是「启动器能找到 melos、链里的子命令找不到」。
判据：如果**第一个**叶子（`guards:deps`）就报找不到 melos，那就是 PATH 问题；
如果前面的叶子都 SUCCESS、只有后面某个 FAILED，那才是真的检查不通过。
本机把 `%LOCALAPPDATA%\Pub\Cache\bin`（里面有 `melos.bat`）加进 PATH 之后，
链的失败传播就正常了：最后一个叶子 FAILED → `guards` FAILED → 退出码 1。

### P0-5 关卡 2 的「断言 widget 测试确实执行」在**三个平台同时**失败 `[已修 · 首次推送实际命中]`

这是 M0 首推（提交 `a451c04`）**唯一**的失败：关卡 1 全绿、关卡 3 四个作业全绿，
关卡 2 的 ubuntu 与 macOS 在第 9 步红，Windows 随后同样红。

**症状**（三个平台的日志完全一致）：

```
✗ 报告不可解析：TestReportFormatException @ build/test-reports/pf_mobile.jsonl:
  第 1 行不是合法 JSON：Unexpected character
Process completed with exit code 2.
```

注意第 8 步「运行移动端 widget 测试（JSON 协议报告）」是**绿的** —— 测试本身跑得好好的，
红的是第 9 步的断言，退出码 2（报告不可用），不是 1（用例失败）。

**根因**：`flutter test` 默认会先做一次**隐式 `pub get`**，并把解析进度写到 **stdout**：

```
Resolving dependencies in `D:\workbuddy\pf-wallet`...
Downloading packages...
  analyzer 7.7.1 (14.4.0 available)
  ...（共 35 行包版本清单）
Got dependencies in `D:\workbuddy\pf-wallet`!
32 packages have newer versions incompatible with dependency constraints.
```

而第 8 步用 `>` 把 stdout 重定向成报告文件 —— **写进 stdout 的东西都会进报告**。
本机实测：前 **37 行**都是这类文本，真正的 JSON 事件从第 **38** 行才开始
（第一行 `{"protocolVersion":"0.1.1",...}`）。于是解析器在第 1 行就停了。

**这不算误报**：报告确实被污染了，`assert_test_report.dart` 的判定是对的。
错的是产出报告的命令 —— 修在**生产端**，不是放宽解析器
（放宽了就会连「报告被截断」一起放过，那正是这个工具要防的静默归零）。

**定位命令**（本机就能完整复现，不需要等 CI）：

```bash
cd apps/pf_mobile

# ① 复现：报告头部 37 行不是 JSON
flutter test --reporter json > ../../build/test-reports/pf_mobile.jsonl
sed -n '1,3p'  ../../build/test-reports/pf_mobile.jsonl   # Resolving dependencies ...
grep -c '^Resolving dependencies' ../../build/test-reports/pf_mobile.jsonl   # 1

# ② 用断言工具复刻 CI 的失败（退出码 2，并且现在会把坏行开头打出来）
dart run packages/pf_testkit/bin/assert_test_report.dart \
  --report build/test-reports/pf_mobile.jsonl --label 复刻 --min-executed 3

# ③ 修法验证：加 --no-pub 后报告从第 1 行就是 JSON
flutter test --no-pub --reporter json > ../../build/test-reports/pf_mobile.nopub.jsonl
sed -n '1p' ../../build/test-reports/pf_mobile.nopub.jsonl   # {"protocolVersion":...
# 逐行 JSON 校验，期望 bad=0
python -c "
import json
bad=sum(1 for l in open(r'build/test-reports/pf_mobile.nopub.jsonl',encoding='utf-8') if l.strip() and not json.loads(l) or False)
print('bad=',bad)"
```

**修复方向**：`.github/workflows/gate2-test.yml` 第 8 步的命令改成

```bash
flutter test --no-pub --reporter json > ../../build/test-reports/pf_mobile.jsonl
```

`--no-pub` 是**必需参数，不是优化**：依赖已经在上一「解析工作区依赖」步骤解析完，
这里的隐式 `pub get` 纯属重复劳动，去掉后 stdout 只剩 JSON Lines。

**同一类陷阱的其它形态**（都靠「报告第一行必须是 JSON」这条硬约束兜住）：
`>` 写成 `>>` 导致两次运行混写、reporter 参数传成 `compact`、
shell 的启动横幅（`.bashrc` 里 `echo`）混进 stdout。

**顺带做的诊断增强**：`TestReportFormatException` 现在会带上坏行的开头（截断到 120 字符），
`assert_test_report.dart` 在退出码 2 时会列出三条常见成因。
这样下次同类问题在 CI 日志里就能自解释，不用再回本机复现一遍。

### P1 · 入库路径检查（`tracked-paths`）失败 —— 先分清「真的错了」与「读不到索引」

对应步骤：`入库路径检查（git 索引）` → `melos run guards:tracked-paths`。
它是唯一一条读 `git ls-files --cached` 的检查：**其他检查查「内容」，它查「哪些路径进来了」**。
出现红色时先看**退出码**，两种情形的处理完全不同。

**症状 A：`error=N`、退出码 1 —— 门禁在工作，索引里确实有不该入库的东西。**

```
ERROR   [tracked-local-state] apps/pf_mobile/.flutter_tool_state
        该路径禁止入库（命中规则 tracked-local-state）。
        → 这类文件记录的是「某一台机器上某一次运行」的状态……
   ✗ FAIL  error=2 warning=0 info=0
```

**症状 B：`✗ 门禁无法完成判定（退出码 2）` —— 环境读不到索引，不是代码问题。**

```
✗ 门禁无法完成判定（退出码 2）
  git ls-files 失败（退出码 128）：fatal: detected dubious ownership in repository at '...'
  → 按提示执行 `git config --global --add safe.directory ...` 后重试。
```

或 `无法执行 git —— 它不在 PATH 中，或本机没有安装。`

区分它们的意义：**退 1 去改代码，退 2 去修环境**。把 2 当 1 处理，
人会开始删规则或加豁免；反过来把 1 当 2 处理，就会把一个真问题当成环境抖动重跑。

**定位命令**（Git Bash，仓库根）：

```bash
# ① 先把「谁进来了」列出来 —— 这一步不依赖本项目的任何脚本
git ls-files --cached | wc -l
git ls-files --cached | grep -E "\.dart_tool/|/build/|/coverage/|\.db$|\.pfb$|\.pfk$|_state$|\.log$"

# ② 再让门禁告诉你它归哪条规则（它会打印 ruleId 与理由）
melos run guards:tracked-paths

# ③ 索引里有哪些「本次改动才加进来的」（误提交通常在暂存区里一眼可见）
git diff --cached --name-status
```

**修复方向**，按命中的规则分三类：

| 命中 | 该做什么 |
|---|---|
| `tracked-build-output` / `tracked-local-state` / `tracked-database` / `tracked-vault-file` / `tracked-secret-material` / `tracked-installer-artifact` / `tracked-log-file` | 这些**从来不该入库**：`git rm --cached <path>` 移出索引 → 补一条 `.gitignore` 规则 → 提交。**已经提交过的话**，历史里的副本不会因为后续删除而消失（对密钥来说意味着必须换密钥），所以这一步越早越好 |
| `tracked-unexpected`（不在白名单内的区域） | 判断它是不是「有意新增的一整块区域」：是 → 在 `tools/guards/rules/tracked_paths.yaml` 的 `allow` 下登记一条 glob（**这个动作会出现在 diff 里，这正是本条要的摩擦**：新增区域必须是一次看得见的决定）；否 → 同上一行处理 |
| `tracked-case-collision`（大小写折叠后重名） | 重命名其中一个。macOS / Windows 的文件系统默认不区分大小写，两个路径会互相覆盖；这不是风格问题，是「换台机器就坏」 |

**两件容易误判的事**：

1. **`.gitignore` 不是这道门禁的替代品，两者是互补的。** `.gitignore` 管的是
   「别自动加进来」；本检查管的是「已经加进来了」。
   `.flutter_tool_state` 那次之所以漏过去，正是因为 `.gitignore` 里没有这条规则；
   而反过来，`git add -f` 能无视任何 `.gitignore` —— 本检查无视不了。
2. **工作区里存在、但没有被追踪的文件不会让它变红。** 它读的是索引，
   不是磁盘。想验证这一点：`touch data/x.db` 之后直接跑门禁，仍然 PASS；
   `git add data/x.db` 之后立刻变红（含 `.gitignore` 已忽略的文件，用 `-f` 加）。

**本机复现（含反例）**：

```bash
cd D:/workbuddy/pf-wallet

# 正例：当前索引应当 PASS（trackedFiles=118 上下，deniedPaths=0）
#      这个数字是「索引里的文件总数」，只会随正常提交增长，不要拿它当判据 ——
#      判据是 deniedPaths / caseCollisions / unexpectedPaths 三项为 0。
melos run guards:tracked-paths

# 反例：造一个违规文件并入库 → 期望 exit 1 且报 tracked-local-state
printf '{"is-bot": false}' > apps/pf_mobile/.flutter_tool_state
git add -f apps/pf_mobile/.flutter_tool_state      # 已被 .gitignore 忽略，所以需要 -f
melos run guards:tracked-paths ; echo "exit=$?"     # 期望 exit=1

# 清理（务必做，否则它会跟着下一个提交进仓库）
git rm --cached apps/pf_mobile/.flutter_tool_state
rm -f apps/pf_mobile/.flutter_tool_state
git status --short                                  # 期望只剩你本来要提交的东西
```

**没有 git 时怎么办**：这条检查会以退出码 2 失败，这是刻意的 ——
一个「读不到索引就跳过」的门禁等于在最需要它的地方（CI 的干净 checkout）没有存在感。
若你确实在一个没有 `.git` 的源码快照里跑 `guards all`，单独跑其余五项即可。

### P1 · 行尾 CRLF 让关卡 1 在 Linux 上失败

**症状**：

```
Changed apps/pf_mobile/lib/main.dart           ← 本地跑格式检查却说「已修改」
```
或 CI 上 `dart format --set-exit-if-changed` 失败，而 `git diff` 里那一行看不出任何差别。
更隐蔽的一种：向量在 Windows 上全过、在 Linux/ macOS 上 `failed` 若干条，
且差异值看起来毫无规律。

**定位命令**：

```bash
cd D:/workbuddy/pf-wallet

# ① 有没有文件以 CRLF 入库
git ls-files --eol | grep -E "i/crlf|w/crlf" | head

# ② 直接看字节（有 \r 就是 CRLF）
file apps/pf_mobile/lib/main.dart
# 或无 file 命令时：
python3 -c "print(open('apps/pf_mobile/lib/main.dart','rb').read(200).count(b'\r\n'))"   # 期望 0

# ③ 本机 git 的自动转换设置（应被 .gitattributes 覆盖，但值得确认）
git config --get core.autocrlf
```

**修复方向**：`.gitattributes` 是唯一真相（`* text=auto eol=lf`，`test_vectors/** -text`）。
若已经以 CRLF 入库过，做一次重规范化：

```bash
git add --renormalize .
git status --short          # 确认只有行尾变化
git commit -m "chore: 按 .gitattributes 重规范化行尾"
```

编辑器侧由 `.editorconfig` 兜住；两者缺一不可。

### P2 路径分隔符：门禁脚本读到 `\` 而不是 `/`

**症状**：`guards` 在 Windows 上报「文件不在 scan 范围内」或命中数为 0（**报告成功但什么都没扫**）；
或 `manifest` 检查找不到 `android/app/src/main/AndroidManifest.xml`。

**定位命令**：

```bash
cd D:/workbuddy/pf-wallet

# 本机复现 CI 的调用（CI 用 bash；本机 bash 也是 MSYS，行为一致）
bash -c 'dart run tools/guards/bin/guards.dart all' | tail -20

# 对比扫描命中数：报告 JSON 里有扫描文件数
python3 -c "import json;d=json.load(open('build/guards/deps.json'));print(d.get('metrics'))"
```

**修复方向**：仓库内所有路径拼接必须走 `p.joinAll`（`package:path`），
禁止字符串拼 `/`。CI 侧已统一：**所有 `run:` 步骤凡涉及跨平台路径的一律显式 `shell: bash`**
（Windows runner 也带 git-bash）。判定标准很简单：
**只要 Git Bash 里能跑通，三个平台就都能跑通。**

### P3 `rename` 语义差异（Windows 与 POSIX 不同）

**症状**：`pf_io` 的原子写测试在 Windows 上失败，报 `FileSystemException: Cannot create a file when that file already exists`。
POSIX 的 `rename` 允许覆盖已存在的目标，Windows 的 `File.rename` 当年不允许（现在 Dart 实现里
已改为先删后改，但**语义仍有边界差异**）。

**定位命令**：

```bash
cd D:/workbuddy/pf-wallet/packages/pf_io
dart test 2>&1 | grep -A 6 "\[E\]"        # Windows 本机就能复现
git log --oneline -- test | head -5
```

**修复方向**：导出/原子写的实现应统一走「写 `.tmp` → 删除目标（若存在）→ rename」，
并把「目标已存在」这一分支写成显式测试。**不要用平台分支绕过** ——
平台分支本身就是需要被测试的东西。

### P4 大小写敏感性（macOS 默认不敏感，Linux 敏感）

**症状**：引入了一个与既有文件仅大小写不同的新文件（`Ledger.dart` vs `ledger.dart`），
macOS 上「能跑」，Linux 上报 `The name 'Ledger' isn't defined` 或直接编译失败。

**定位命令**：

```bash
cd D:/workbuddy/pf-wallet

# 列出仅大小写不同的重名文件（在 Windows/macOS 上你也可能是「无意间覆盖」的那个）
git ls-files | sort -f | uniq -Di

# 检查 import 语句的大小写是否与真实文件名逐字符一致
git ls-files "*.dart" | while read -r f; do b=$(basename "$f" .dart); \
  grep -rIl "import '.*/$b.dart'" --include="*.dart" . >/dev/null || true; done
```
（第二条只是粗筛；可靠的做法是靠 `dart analyze` —— 它在 Linux 上会直接报错。）

**修复方向**：文件名一律小写 + 下划线。这条只能靠约定与 Linux 关卡兜住，
没有本机可选的办法 —— 这也正是关卡 2 必须包含 Linux 的原因之一。

### P5 `flutter_tester` 起不来

**症状 A（本机开发沙箱）**：`flutter test` 停在 artifacts 检查之后、无任何输出。
**症状 B（CI）**：

```
Failed to load "/.../flutter_tester": No such file or directory
```

**定位命令**：

```bash
FL=$(dirname "$(dirname "$(command -v flutter)")")
ls -1 "$FL/bin/cache/artifacts/engine/"        # CI 上应当有 linux-x64 / darwin-x64 / windows-x64

# 直接确认测试步骤到底有没有产出报告（这是最关键的一条）
cat build/test-reports/pf_mobile.jsonl | head -3
wc -l build/test-reports/pf_mobile.jsonl       # 0 行 = 测试根本没跑起来
```

**修复方向**：
- 症状 A 是本机沙箱的限制，**不要修**，交给 CI（本文件 §4 就是这件事的完整交代）。
- 症状 B 通常是第一次运行时 `flutter test` 需要下载引擎产物，而缓存的
  `artifacts/engine` 不完整。处置：在 gate2 里 `flutter precache --universal` 前置一次，
  或直接**重跑该作业**（`gh run rerun <run-id>`）让下载补完。
- `pf_mobile` 没有 `android/` `ios/` 目录，**不影响** widget 测试 ——
  它们跑在 flutter_tester 上，不需要平台工程。

### P6 关卡 3 的一致性作业报「只找到 1 份报告」

**症状**：`✗ 只找到 1 份报告，无法做跨平台比对`（退出码 2）。

**定位命令**：

```bash
# 看矩阵到底产出了几个 artifact
gh run view <run-id> --json jobs \
  --jq '.jobs[] | select(.name|startswith("黄金向量")) | "\(.name) → \(.conclusion)"'

# 本地模拟这个比对（本机只有一份报告时，工具会以退出码 2 拒绝 —— 这是刻意的）
cd D:/workbuddy/pf-wallet
python3 tools/ci/compare_verdicts.py build/vectors   ; echo "exit=$?（期望 2）"

# 用三份真实报告本地比对（把三个 artifact 解压到 reports/ 之后）
python3 tools/ci/compare_verdicts.py reports ; echo "exit=$?（期望 0）"
```

**修复方向**：检查三处名字是否逐字符一致 ——
`upload-artifact` 的 `name: vectors-report-${{ matrix.os }}-${{ github.sha }}`、
下载时的 `pattern: vectors-report-*`、以及报告实际落在 `build/vectors/report.json`。
还有一处容易忽略：**`golden-vectors` 里某平台失败时，artifact 仍会上传**
（`if: always()` + `if-no-files-found: error`），但若 `report.json` 都没写出来，
上传步骤会跟着报错 —— 那时先修测试，别看一致性作业。

### P7 `flutter pub get` 失败 / pub 速率限制

**症状**：

```
Got socket error trying to find package ... at https://pub.dev
```
或 `Because ... depends on ... which requires SDK version ... , version solving failed.`

**定位命令**：

```bash
cd D:/workbuddy/pf-wallet
dart pub deps --style=compact | head -20
dart pub outdated --no-dev-dependencies
```

**修复方向**：
- 速率限制：三个 workflow 都已设 `PUB_MAX_CONCURRENT_DOWNLOADS: "4"`；
  再遇到就重跑该作业（pub 的 CDN 缓存起来后不会复发）。
- 求解失败：**方向是「改依赖」而不是「改约束」**，先看是哪一层的 SDK 约束被顶到。
- 用 `melos bootstrap` 会踩到一个额外坑（melos 需自行判断「这是不是 Flutter 工作区」，
  判断错就退回 `dart pub get`，于是 `pf_mobile` 的 Flutter SDK 依赖解析不到）——
  所以三个 workflow 里用的都是显式的 `flutter pub get`。

### P8 时间与时区相关的失败

**症状**：`Ulid` / `RecordVersion` 相关用例在某个平台上失败，值相差整数小时的偏移，
或「接近当前时间」这类断言偶发失败。

**定位命令**：

```bash
cd D:/workbuddy/pf-wallet
dart test packages/pf_core packages/pf_io -r expanded | grep -iE "ulid|timestamp"

# 看 runner 的时区（GitHub 的 runner 都是 UTC）
gh run view <run-id> --log | grep -i "TZ\|timezone" | head
```

**修复方向**：**任何时间都必须走 UTC**，且测试里不得依赖「本机时区」。
向量里出现的是绝对毫秒数（如 `1735689600000`），它在任何时区下都应当相同；
如果某个平台算出不同的值，问题不在时区，而在于是否用了 `DateTime.now()` ——
**向量里的期望值永远是「从数据里解出来的」，不是「现在几点」**。
（M0 验收时正是靠这一点抓到 ULID 解码表与编码表不一致，见 `docs/M0_ACCEPTANCE.md` §8.1。）

### P9 权限与 fork PR

**症状**：来自 fork 的 PR 上 workflow 不运行，或运行后在 `upload-artifact` 处失败。

**定位命令**：

```bash
gh run list --limit 10
gh api repos/:owner/:repo/actions/permissions
```

**修复方向**：本仓库是单人使用，不接外部 PR 是最省事的做法。
若确实要接，把 `pull_request` 触发改为 `pull_request_target`（**注意这会让 PR 拿到写权限，
是安全事件高发点**），或干脆要求先合并到内部分支再跑。**默认建议：不接 fork PR。**

---

## 4. pf_mobile 的 3 条 widget 测试：CI 上如何证明「真的执行了」

这是本文件里唯一需要新增机制的一节。

### 4.1 为什么只看退出码不够

`flutter test` 在下面三种情况下**同样返回 0**：

1. 用例全部执行并通过；
2. **一条用例都没有**（测试文件被删、文件名不匹配 `*_test.dart`、包配错）；
3. **用例全部被跳过**（有人加了 `@Skip(...)` 或 `skip: true`）。

而 pf_mobile 的这 3 条测试在本机开发沙箱里**跑不了**（flutter_tester 起不来），
也就是说它们在本地始终处于「未验证」状态。如果 CI 上也因为某种原因没跑，
`docs/M0_ACCEPTANCE.md` 第 7 节会带着一个**空洞的绿勾**通过 ——
这正是本项目最想避免的失败模式：**覆盖静默归零，而门禁全绿**。

### 4.2 机制：报告 + 断言（两层，互相兜底）

**第一层：把测试进程自己产出的报告留下来**

```yaml
- name: 运行移动端 widget 测试（JSON 协议报告）
  if: always()
  shell: bash
  working-directory: apps/pf_mobile
  run: |
    mkdir -p ../../build/test-reports
    flutter test --no-pub --reporter json > ../../build/test-reports/pf_mobile.jsonl
```

`--reporter json` 只往 stdout 写 JSON Lines，人读的输出仍由 `melos run test:cov`
那一步提供（compact reporter），两步互不干扰。

`--no-pub` 是**必需参数**：这一步用 `>` 把 stdout 重定向成报告，
而 `flutter test` 默认会先做一次隐式 `pub get` 并把解析进度写进 stdout ——
那会让报告前 37 行不是 JSON。完整推导见 §3 的 P0-5（首推时就是栽在这里）。

**第二层：核对报告里的三个信号**

```yaml
- name: 断言 widget 测试确实执行（而非被跳过）
  if: always()
  shell: bash
  run: |
    dart run packages/pf_testkit/bin/assert_test_report.dart \
      --report build/test-reports/pf_mobile.jsonl \
      --label "pf_mobile · ${{ matrix.os }}" \
      --min-executed 3 \
      --require '应用能构建并显示构建信息' \
      --require '深色模式下也能正常构建' \
      --require 'MVP 阶段不得出现任何「记账」入口'
```

报告协议里三个字段的语义差异就是这个机制的全部价值：

| 字段 | 语义 | 只看它会怎样 |
|---|---|---|
| `skipped` | 用例**没有执行**。但 `result` 仍被规范化为 `success`（test_core 为兼容旧消费方刻意如此） | **得出完全相反的结论**：被跳过的用例看起来是通过的 |
| `hidden` | 测试框架自己的合成用例（`loading /path/x_test.dart`） | 不计入的话，「执行了几条」永远比实际多 |
| `metadata.skip` | **源码里**声明了跳过 | 指向「有人写下了 @Skip」，与「这次没跑」的排查方向不同 |

`--min-executed 3` 用的是**下界**而不是等号：新增用例不该让门禁变红
（那只会让人删掉这条断言），但**减少**必须变红 ——
与 `pending_baseline.json` 的「只减不增」是同一个思路。

### 4.3 本机可以在没有 flutter 的情况下自测这套机制

```bash
cd D:/workbuddy/pf-wallet
mkdir -p build/test-reports

# ① 全过 → 退出码 0
printf '%s\n' \
 '{"type":"testStart","test":{"id":1,"name":"应用能构建并显示构建信息","metadata":{"skip":false,"skipReason":null}}}' \
 '{"type":"testDone","testID":1,"result":"success","skipped":false,"hidden":false}' \
 '{"type":"testStart","test":{"id":2,"name":"深色模式下也能正常构建","metadata":{"skip":false,"skipReason":null}}}' \
 '{"type":"testDone","testID":2,"result":"success","skipped":false,"hidden":false}' \
 '{"type":"testStart","test":{"id":3,"name":"MVP 阶段不得出现任何「记账」入口","metadata":{"skip":false,"skipReason":null}}}' \
 '{"type":"testDone","testID":3,"result":"success","skipped":false,"hidden":false}' \
 > build/test-reports/pf_mobile.jsonl

dart run packages/pf_testkit/bin/assert_test_report.dart \
  --report build/test-reports/pf_mobile.jsonl --min-executed 3 \
  --require '应用能构建并显示构建信息' ; echo "exit=$?（期望 0）"

# ② 有一条被跳过 → 退出码 1
sed -i 's/{"type":"testStart","test":{"id":2,"name":"深色模式下也能正常构建","metadata":{"skip":false/{"type":"testStart","test":{"id":2,"name":"深色模式下也能正常构建","metadata":{"skip":true/' build/test-reports/pf_mobile.jsonl
sed -i 's/{"type":"testDone","testID":2,"result":"success","skipped":false/{"type":"testDone","testID":2,"result":"success","skipped":true/' build/test-reports/pf_mobile.jsonl

dart run packages/pf_testkit/bin/assert_test_report.dart \
  --report build/test-reports/pf_mobile.jsonl --min-executed 3 \
  --require '深色模式下也能正常构建' ; echo "exit=$?（期望 1）"

# ③ 报告是空的 / 不存在 → 退出码 2
: > build/test-reports/_empty.jsonl
dart run packages/pf_testkit/bin/assert_test_report.dart --report build/test-reports/_empty.jsonl
echo "exit=$?（期望 2）"
rm -f build/test-reports/_empty.jsonl

# ④ 报告被工具输出污染（首推实际命中的那种）→ 退出码 2，并打出坏行开头
{ echo 'Resolving dependencies in `...`...'; echo 'Got dependencies!'; cat build/test-reports/pf_mobile.jsonl; } \
  > build/test-reports/_polluted.jsonl
dart run packages/pf_testkit/bin/assert_test_report.dart --report build/test-reports/_polluted.jsonl
echo "exit=$?（期望 2）"
rm -f build/test-reports/_polluted.jsonl
```

第 ③ 步很重要：**「报告没拿到」与「测试有失败」必须用不同退出码**，
否则「CI 接线断了」会伪装成「实现有 bug」，排查方向当场被带偏。
这与 `vector_report.dart` 的 0/1/2 约定一致。

第 ④ 步是首推事故的回放：它验证的是「污染不会被误判成用例失败」——
退出码必须是 2 而不是 1，且错误信息要指出**哪一行、长什么样**。

### 4.4 在 CI 上肉眼确认（第一次跑完必看）

```bash
# 网页路径（本机没装 gh 时用这条）：
#   https://github.com/<owner>/<repo>/actions  → 点进 gate2-test 的任一作业
#   → 展开「断言 widget 测试确实执行（而非被跳过）」这一步
#   → 日志里应当看到三条 ✓ 与「✓ 判定通过」

# 有 gh 时可以直接读日志
gh run view <run-id> --log | grep -A 12 "断言 widget 测试确实执行"

# 把报告拉下来自己看（三条 testDone，skipped 全为 false）
gh run download <run-id> -n mobile-widget-report-windows-latest-<sha> -D /tmp/mw
python3 -c "
import json,collections
c=collections.Counter()
for line in open('/tmp/mw/pf_mobile.jsonl',encoding='utf-8'):
    e=json.loads(line)
    if e.get('type')=='testDone': c[(e['result'],e['skipped'],e['hidden'])]+=1
print(dict(c))
"
# 期望：{('success', False, False): 3, ('success', False, True): 1}
```

那 1 条 `hidden` 的就是 `loading ..._test.dart` 合成用例 —— 它出现说明**测试文件确实被加载了**。

---

## 5. M0 完成后的收尾动作

### 5.1 三关卡全绿后，如何更新 `docs/M0_ACCEPTANCE.md` 第 7 节 `[已执行]`

**已于提交 `36206c6` 的 CI 运行全绿后执行。** 下面保留当时的操作清单，
因为同一个动作在 M1、M2 的收尾里会以同样的形式再来一次。

第 7 节当时的样子（三个未勾选项）：

```markdown
- [x] 第 6 节 1–8、10、11 项全部符合期望（关卡 1 与关卡 3 的本地部分已全绿）
- [ ] 第 6 节第 9 项：pf_mobile 的 3 条 widget 测试在能启动 flutter_tester
      的环境上通过（**本机开发沙箱不具备该条件，由此处的 CI 代替执行**）
- [ ] 第 6 节第 12 项在 CI 上跑通（需把仓库推到 GitHub 并产出三份报告）
- [ ] 三关卡在 CI 上均为绿色
- [x] test_vectors/pending_baseline.json 与实现一致（M0：空）
- [x] 本文件无「待补」标记
```

**全绿后按下面三条改**（改完 grep 一遍确认没有残留的 `- [ ]`）：

```bash
cd D:/workbuddy/pf-wallet

# ① 记下这次跑通的证据（run 链接与判定摘要要写进文件，否则无法复核）
gh run list --workflow=gate3-vectors.yml --limit 1 \
  --json databaseId,conclusion,headSha,url

# ② 三个方框改成打勾，并把「待 CI」改成「CI 实测值」
grep -n "^- \[ \]" docs/M0_ACCEPTANCE.md      # 改完后应当没有输出
```

替换文本（可直接套用，`<...>` 处填真实值）：

```markdown
- [x] 第 6 节 1–8、10、11 项全部符合期望（关卡 1 与关卡 3 的本地部分已全绿）
- [x] 第 6 节第 9 项：pf_mobile 的 3 条 widget 测试在 CI 三平台通过，
      且由 `tools/ci/assert_test_report.dart` 核对过「确实执行、未被跳过」
      （证据：artifact `mobile-widget-report-<os>-<sha>`，
      报告内 3 条 `testDone` 的 `skipped` 全部为 `false`）
- [x] 第 6 节第 12 项在 CI 上跑通：三平台 `verdictDigest` 一致
      （摘要 `<f573cf9de746…>`，作业 `跨平台判定一致性` 于
      <run 链接> 通过）
- [x] 三关卡在 CI 上均为绿色（gate1 `<run 链接>` /
      gate2 `<run 链接>` / gate3 `<run 链接>`，
      提交 `<sha>`）
- [x] test_vectors/pending_baseline.json 与实现一致（M0：空）
- [x] 本文件无「待补」标记
```

**同时把第 6 节表格里第 12 行的 `⏳ 需三平台 CI 产出` 换成实测的三份摘要值**
（全部应当等于 `<f573cf9de746…>`）。

三条纪律，别省：

1. **每个勾后面必须能点开看**（run 链接或 artifact 名）。没有证据的勾等于自欺。
2. **摘要值要逐字抄**，不要写「一致」—— 你下次比对时需要的是那个字符串。
3. **第 7 节末尾那段「上面未打勾的三项不是遗留工作」的文字要删掉** ——
   它描述的状态已经过去了，留着会让人以为还有事没做。

### 5.2 `smoke_test.dart` 反向断言的改写时机

> **[已执行 · M1 第一步]** 提交 `3ebe837`（`main` 上现为 `ad90673`）。
> 三关卡全绿，含关卡 2 三平台第 9 步断言 —— 该断言要求的第三个用例名
> 即新名 `未解锁时不得出现任何可写入账目的界面`，因此它的绿同时证明
> 「新断言真的执行了」与「在新断言下确实通过」。
>
> - 关卡 1：`https://github.com/xiaoHuoTongZhi/pf-wallet/actions/runs/35065249172`
> - 关卡 2：`https://github.com/xiaoHuoTongZhi/pf-wallet/actions/runs/35065249221`
> - 关卡 3：`https://github.com/xiaoHuoTongZhi/pf-wallet/actions/runs/35065249134`
>
> 实际落地的形态与本节的示意有两处出入，都以本节下方的「落地形态」为准：
> ① 入口位置定在**底部按钮**（`Scaffold.bottomNavigationBar`），不是 AppBar 动作；
> ② 判据由一条变三条 —— 只断言「进了解锁页」不够，得同时证明
> **入口存在且唯一**、**真的发生了跳转**（`BuildStatusPage` 对 finder 不可见）、
> **账目字段仍不出现**。少了第 ① 条，后两条可被 `if (entryExists)`
> 包成空断言，「把入口藏起来」就能伪装成通过。

**改写时机：M1 的第一件事，不是 M0 的收尾。**

`apps/pf_mobile/test/smoke_test.dart` 里那条负面断言是 M0 最刻意的护栏：

```dart
testWidgets('MVP 阶段不得出现任何「记账」入口', (WidgetTester tester) async {
  // 在加密数据库与解锁流程就绪之前，
  // 任何能写入账目的界面都意味着「用户把真实数据放进了没有保护的地方」。
  for (final label in <String>['记一笔', '新增', '收入', '支出', '账单']) {
    expect(find.text(label), findsNothing, reason: 'M0 阶段不应存在「$label」入口');
  }
});
```

它守的是 M0 阶段唯一真正危险的动作：**在加密落盘链路就绪之前把记账入口做出来**。

改写的正确做法（三件事一起做，缺一件就等于偷偷拆护栏）：

1. **不是删掉它，而是把它升级成「入口存在且被锁住」** ——
   改成断言「点击『记一笔』后进入的是解锁页，而不是记账页」。

   **落地形态（三条判据，不是一条）**，与上面的示意不同，照这个抄：

   ```dart
   testWidgets('未解锁时不得出现任何可写入账目的界面', (WidgetTester tester) async {
     await tester.pumpWidget(const PfWalletApp());

     // ① 入口必须在、且只能有一个。
     //    少了这条，后两条可被 `if (entryExists) { ... }` 包成空断言 ——
     //    「把入口藏起来」就成了一种通过方式。
     expect(find.text('记一笔'), findsOneWidget);

     await tester.tap(find.text('记一笔'));
     await tester.pumpAndSettle();

     // ② 既要「进了解锁页」，也要「真的离开了原页面」。
     //    只断言前者的话，「点了没反应」这种坏法看不见。
     expect(find.byType(UnlockPage), findsOneWidget);
     expect(find.byType(BuildStatusPage), findsNothing);

     // ③ 关键约束，与升级前一致：账目字段仍不得出现。
     for (final String label in <String>['收入', '支出', '账单', '余额', '金额']) {
       expect(find.text(label), findsNothing, reason: '未解锁界面上不得出现账目字段「$label」');
     }
   });
   ```

   ②里的 `findsNothing` 是可靠的，不需要 `find.byKey` 或 `skipOffstage: false`：
   遮挡路由仍在 element 树里，但 `_TheaterElement.debugVisitOnstageChildren`
   会 `children.skip(theater.skipCount)`（`flutter/lib/src/widgets/overlay.dart:1010`），
   而 finder 默认 `skipOffstage: true`。
2. **改完后把 `assert_test_report.dart` 的 `--require` 参数同步改掉**
   （CI 里那三个 `--require` 字面量）。这一步是刻意的摩擦：改名/改语义绕过门禁
   必须是**一次看得见的修改**，不能靠 CI 恰好看不见。
3. **在提交信息里写明这是 M1 的第一件事**，并附上 M0 验收全绿的 run 链接。

顺序不能颠倒：**先有 M0 全绿（含 CI），再动这条断言。**
否则「M1 开始了，所以把 M0 的护栏拆了」会变成一句无法反驳的话。

---

## 附：本次把 CI 路径「走通」时本机实测到的三件事

这三条都是**只有真的动手才会发现**的，全部已修，记录在此以免复用旧结论：

1. **melos 6.3.3 要求 Dart 3.8**，而 Flutter 3.29.0 只带 3.7.0 →
   `dart pub global activate melos 6.3.3` 当场失败。可用上界是 **6.3.2**。
2. **melos 3.0 起要求本地安装**（根 `pubspec.yaml` 的 `dev_dependencies`），
   全局安装不再够用。不写进去，`melos run anything` 在任何机器上都失败，
   而报错发生在检查代码之前。
3. **melos 的 `steps:` 在 Windows 上会吞掉失败**（cmd 模板里 `VER>NUL` 把
   ERRORLEVEL 归零），复合脚本报 `SUCCESS` 而退出码为 0。改为 `&&` 链后
   失败正确传播（实测：前一步失败 → 后一步不执行 → 退出码 1）。

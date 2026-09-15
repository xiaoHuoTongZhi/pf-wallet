# PF Wallet

本地优先、无后端、隐私至上的个人记账应用。移动端先行（Flutter），桌面端复用同一套领域层 / 数据层 / 加密层。

设计与约束的完整依据：`../pf-wallet-spec/personal-finance-app-tech-spec.md`。

---

## 当前阶段：M0（骨架与门禁）

M0 只交付「能开工并且踩不歪」的基础设施，不含业务功能。范围与验收标准见 `docs/M0_ACCEPTANCE.md`。

---

## 目录结构

```
pf-wallet/
├── pubspec.yaml                 工作区根（pub workspaces），全仓唯一 lock 文件
├── melos.yaml                   批量任务编排（scripts 是唯一命令入口）
├── analysis_options.yaml        全仓统一 lint（含安全相关规则）
├── .flutter-version             CI 与本机唯一的 Flutter 版本来源
├── .github/workflows/
│   ├── gate1-static.yml         关卡 1：格式 / 分析 / 自定义门禁
│   ├── gate2-test.yml           关卡 2：单元测试（三平台）
│   └── gate3-vectors.yml        关卡 3：黄金向量跨平台一致性
├── apps/
│   └── pf_mobile/               移动端 App（表现层）
├── packages/
│   ├── pf_core/                 领域层：实体值对象、错误码、时钟、ID
│   ├── pf_crypto/               加密层：KDF / AEAD / 容器格式（M0 交付真实现的头尾编解码）
│   ├── pf_data/                 数据层：SQLCipher 访问抽象、迁移骨架
│   ├── pf_io/                   导入导出与合并算法的接口契约
│   ├── pf_ui/                   双端共享的主题令牌（含自定义配色）
│   └── pf_testkit/              黄金测试向量框架（驱动接口 + 运行器 + 报告）
├── tools/
│   └── guards/                  自定义 CI 门禁脚本（依赖黑名单等）
├── test_vectors/
│   ├── schema/vector.schema.json  向量 JSON Schema（draft 2020-12）
│   ├── v1/*.json                  向量数据
│   └── skip_baseline.json         允许跳过的向量 kind 白名单
└── docs/
    └── M0_ACCEPTANCE.md         M0 验收清单
```

---

## 依赖方向（硬约束，由 lint + review 保证）

```
pf_mobile ──▶ pf_ui ──▶ pf_core
    │
    ├──▶ pf_io ──▶ pf_data ──▶ pf_core
    │                │
    └──▶ pf_crypto ──┴──▶ pf_core

pf_testkit ──▶ pf_core （仅测试期使用）
tools/guards  独立，不依赖任何 package
```

规则：**箭头只能单向，且任何 package 不得反向依赖 `apps/`**。`pf_core` 必须零三方依赖（除 `meta`）。

---

## 本机开工

```bash
# 0. 一次性：安装 Flutter（版本取自 .flutter-version）
#    任选其一：fvm install / 手动下载 SDK / 系统级安装

# 1. 解析工作区依赖（必须在根目录，且必须用 flutter 而非 dart）
flutter pub get

# 2. 激活 melos
dart pub global activate melos 6.3.2

# 3. 复现全部 CI 关卡
melos run ci:all
```

单独跑某一关：

```bash
melos run ci:gate1     # 格式 + 分析 + 自定义门禁
melos run ci:gate2     # 单元测试
melos run ci:gate3     # 黄金向量
```

---

## 常用命令

| 命令 | 作用 |
|---|---|
| `melos run format:fix` | 就地格式化 |
| `melos run analyze` | 全包静态分析 |
| `melos run test` | 全包单元测试 |
| `melos run vectors` | 跑黄金向量并输出 `build/vectors/report.json` |
| `melos run vectors:pending` | 列出尚未实现的向量（M1/M2 待办） |
| `melos run guards` | 全部自定义门禁 |
| `melos run guards:deps` | 只跑依赖黑名单检查 |

`pf_mobile` 的平台目录（android/ ios/）由 `flutter create` 生成，不入库：

```bash
cd apps/pf_mobile
flutter create --platforms=android,ios --org com.pfwallet --project-name pf_mobile .
```

---

## 三条不可违背的红线

1. **不联网。** 发布产物不得含任何网络客户端依赖或 INTERNET 权限（`guards:deps` + `guards:manifest` 强制）。
2. **不落明文。** 敏感数据不进日志、不进备份、不进临时文件（`guards:logging` + `guards:manifest` 强制）。
3. **加密只有一份实现。** 任何算法改动必须先改 `test_vectors/`，再改实现，CI 关卡 3 双向校验。

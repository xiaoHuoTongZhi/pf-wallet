/// PF Wallet 移动端入口。
///
/// ## M0 阶段这个文件刻意很空
///
/// 现在的它只做三件事：建主题、显示构建信息、说明「功能还没上线」。
/// 之所以先把它跑起来而不是留空目录，是因为「工程骨架能否构建」
/// 本身就是一条需要在 CI 上被持续验证的事实 ——
/// 等到 M3 才发现 Flutter 版本、analyze 规则或工作区依赖有问题，
/// 那时的排查成本要高一个数量级。
///
/// 明确不做的事（避免后来者以为漏了）：
///   - 不做任何初始化时序（解锁流程尚未设计定型，先写等于先写错）
///   - 不接任何平台插件
///   - 不做路由骨架（页面结构要等数据层定下来再定）
library;

import 'package:flutter/material.dart';
import 'package:pf_core/pf_core.dart';
import 'package:pf_ui/pf_ui.dart';

void main() {
  runApp(const PfWalletApp());
}

/// 应用根组件。
class PfWalletApp extends StatelessWidget {
  const PfWalletApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PF Wallet',
      debugShowCheckedModeBanner: false,
      // 主题跟随系统深浅模式。用户自定义配色在设置页落地后，
      // 这里会改为「先从加密数据库读用户配色，读不到再回落系统默认」。
      theme: buildPfTheme(PfPalette.lightDefault),
      darkTheme: buildPfTheme(PfPalette.darkDefault),
      home: const BuildStatusPage(),
    );
  }
}

/// 构建状态页。
///
/// 它在正式功能上线后会被替换掉，但保留价值很高：
/// 用户报「备份打不开」时，第一件要知道的事就是双方的应用版本与
/// 容器格式版本 —— 这一页把这些数字摆在眼前。
class BuildStatusPage extends StatelessWidget {
  const BuildStatusPage({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = PfPalette.defaultsFor(
      Theme.of(context).brightness == Brightness.dark ? PfBrightness.dark : PfBrightness.light,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('PF Wallet')),
      body: ListView(
        padding: const EdgeInsets.all(PfSpacing.lg),
        children: <Widget>[
          _Section(
            title: '构建信息',
            palette: palette,
            rows: <({String label, String value})>[
              (label: '应用版本', value: PfBuildInfo.appVersion),
              (label: '数据库 schema', value: 'v${PfBuildInfo.schemaVersion}'),
              (
                label: '容器格式',
                value:
                    'v${PfBuildInfo.containerFormatVersion}'
                    '.${PfBuildInfo.containerFormatMinorVersion}',
              ),
              (label: '载荷 schema', value: 'v${PfBuildInfo.payloadSchemaVersion}'),
            ],
          ),
          const SizedBox(height: PfSpacing.lg),
          _Section(
            title: '当前里程碑：M0（工程地基）',
            palette: palette,
            rows: const <({String label, String value})>[
              (label: '领域层 pf_core', value: '已就绪'),
              (label: '容器格式定义', value: '已就绪'),
              (label: '合并裁决算法', value: '已就绪'),
              (label: '依赖黑名单门禁', value: '已就绪'),
              (label: '黄金测试向量框架', value: '已就绪'),
              (label: 'Argon2id / AES-GCM 实现', value: 'M2'),
              (label: '加密数据库与解锁流程', value: 'M3'),
              (label: '记账功能与界面', value: 'M4+'),
            ],
          ),
          const SizedBox(height: PfSpacing.lg),
          Text(
            '这一页是 M0 的占位屏。真正的记账功能会在加密数据库与解锁流程'
            '落地后逐步替换它 —— 在那之前，任何「能记账」的界面都是在'
            '鼓励用户把真实的账目写进一个还没有加密保护的地方。',
            style: TextStyle(color: palette.onSurfaceVariant, height: 1.6),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.rows, required this.palette});

  final String title;
  final List<({String label, String value})> rows;
  final PfPalette palette;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: palette.onSurface),
        ),
        const SizedBox(height: PfSpacing.sm),
        DecoratedBox(
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(PfSpacing.cardRadius),
          ),
          child: Column(
            children: <Widget>[
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: PfSpacing.lg,
                    vertical: PfSpacing.md,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Text(row.label, style: TextStyle(color: palette.onSurfaceVariant)),
                      Text(
                        row.value,
                        style: TextStyle(
                          color: palette.onSurface,
                          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

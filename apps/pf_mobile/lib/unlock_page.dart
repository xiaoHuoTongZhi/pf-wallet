/// 解锁页 —— **占位实现**，不含任何解密能力。
///
/// ## 这个页面上为什么一个输入框都没有
///
/// 它现在只做一件事：证明「记账入口存在，但它被锁在解锁流程之后」。
///
/// 真正的解锁页要等两样东西：Argon2id 密钥派生 + AES-GCM 解密（M2），
/// 以及加密数据库本身（M3）。在那之前放一个密码框，制造的是
/// **「看起来能保护数据」的假象** —— 用户会以为输进去的密码真的在保护账本，
/// 而实际上没有任何东西被保护。这比没有解锁页更糟：
/// 没有解锁页时用户知道功能还没做；有一个假解锁页时，
/// 用户会放心地把真实账目录进去。
///
/// 所以本页刻意**只**有标题、说明文字和返回按钮，并且：
///
///   - 没有密码 / PIN / 生物识别输入控件
///   - 没有任何写入操作（连「创建账本」都没有）
///   - 不出现任何账目字段（金额、分类、账户、备注……）
///
/// 这三条由 `test/smoke_test.dart` 的第三条用例守着：它断言点击「记一笔」后
/// 到达的是本页，且页面上不存在账目字段。也就是说，
/// **这一页的「空」不是没做完，是被测试盯着的设计要求** ——
/// 谁要往里加输入框，CI 会先红。
library;

import 'package:flutter/material.dart';
import 'package:pf_ui/pf_ui.dart';

/// 解锁流程的占位页：说明「此处将来是解锁页」，不提供任何解锁手段。
class UnlockPage extends StatelessWidget {
  const UnlockPage({super.key});

  @override
  Widget build(BuildContext context) {
    final PfPalette palette = PfPalette.defaultsFor(
      Theme.of(context).brightness == Brightness.dark ? PfBrightness.dark : PfBrightness.light,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('解锁')),
      body: ListView(
        padding: const EdgeInsets.all(PfSpacing.lg),
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(PfSpacing.cardRadius),
            ),
            child: Padding(
              padding: const EdgeInsets.all(PfSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '这里将是解锁页',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: palette.onSurface,
                    ),
                  ),
                  const SizedBox(height: PfSpacing.sm),
                  Text(
                    '入口已经就位，但它现在锁着，而且连锁孔都还没装 —— '
                    '因为加密还没落地。'
                    '\n\n'
                    '真实的解锁流程需要先由口令派生出密钥（Argon2id），'
                    '再用它解密落盘的数据（AES-GCM），这条链路要到 M2 / M3 才就绪。'
                    '在那之前，一个能输口令的框只会让人误以为账本已经被保护。',
                    style: TextStyle(color: palette.onSurfaceVariant, height: 1.6),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: PfSpacing.lg),
          Text(
            '本页刻意不含：口令输入、任何写入操作、任何账目字段。'
            '要在本页加东西之前，先看一眼 test/smoke_test.dart 的第三条用例。',
            style: TextStyle(color: palette.onSurfaceVariant, height: 1.6),
          ),
        ],
      ),
      // 返回按钮放在底部，和「记一笔」入口同一个位置 ——
      // AppBar 的返回箭头是 Navigator 白送的，这里再放一个显式按钮是因为：
      // 底部单手可达，而用户是从底部按进来的，退回去也该在同一个位置。
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(PfSpacing.lg),
          child: SizedBox(
            height: PfSpacing.tapTarget,
            width: double.infinity,
            child: OutlinedButton(
              // maybePop 而不是 pop：本页若被当作首个路由直接展示，
              // pop 会抛错，maybePop 会静默地什么都不做。
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('返回'),
            ),
          ),
        ),
      ),
    );
  }
}

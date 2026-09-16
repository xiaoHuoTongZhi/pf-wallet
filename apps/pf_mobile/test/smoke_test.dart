/// 冒烟测试：应用能构建，构建信息与 [PfBuildInfo] 一致，
/// 且**未解锁前不存在任何可写入账目的界面**。
///
/// 前两条看起来价值不高，但它们守的是一个真实的失败模式：
/// 有人改了 `PfBuildInfo.appVersion` 却忘了改 `apps/pf_mobile/pubspec.yaml`
/// 的 `version`，于是「设置页显示的版本」与「应用包管理器里的版本」不一致 ——
/// 用户报障时给出的版本号是错的，排查直接走偏。
/// 版本一致性由 CI 关卡 1 做硬校验（见 docs/M0_ACCEPTANCE.md），
/// 这里只保证 UI 展示确实读的是同一份常量。
///
/// 第三条是 **M1 的第一件事**（改写依据见 docs/M0_CI_RUNBOOK.md §5.2）。
///
/// M0 阶段它是一条「**不得存在**任何记账入口」的负面断言，守的是
/// 「在加密落盘链路就绪之前，不要做出任何能写入账目的界面」。
/// M1 起它被**升级**而不是删除，判据从一个变成三个：
///
///   ① 入口**必须存在**；
///   ② 点进去必须落在**解锁页**，而不是记账页；
///   ③ 解锁页上**不得出现任何账目字段**（M0 护栏的实质，原样保留）。
///
/// 为什么是「升级」而不是「换一条新测试」：
/// 原来的断言只防「入口被提前做出来」，因此它在 M1 一开始就会红，
/// 而**红掉的护栏最常见的下场是被删掉**。改成三条之后覆盖面反而更大：
/// 它现在同时防「入口做出来了但没上锁」和「护栏被顺手删掉」。
/// 真正危险的动作从来不是「有一个叫『记一笔』的按钮」，
/// 而是「这个按钮点进去能写账」—— 断言必须盯着后者。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pf_core/pf_core.dart';
import 'package:pf_mobile/main.dart';
import 'package:pf_mobile/unlock_page.dart';

void main() {
  testWidgets('应用能构建并显示构建信息', (WidgetTester tester) async {
    await tester.pumpWidget(const PfWalletApp());

    expect(find.text('PF Wallet'), findsOneWidget);
    expect(find.text(PfBuildInfo.appVersion), findsOneWidget);
    expect(
      find.text(
        'v${PfBuildInfo.containerFormatVersion}'
        '.${PfBuildInfo.containerFormatMinorVersion}',
      ),
      findsOneWidget,
    );
  });

  testWidgets('深色模式下也能正常构建', (WidgetTester tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(const PfWalletApp());
    expect(find.byType(BuildStatusPage), findsOneWidget);
  });

  testWidgets('未解锁时不得出现任何可写入账目的界面', (WidgetTester tester) async {
    await tester.pumpWidget(const PfWalletApp());
    await tester.pumpAndSettle();

    // ① 入口必须存在，且唯一。
    //
    // 这一条不是「补充说明」，它同时是下面两条的**前提**：
    // 如果「记一笔」根本不存在，`tester.tap` 会因为找不到目标而抛错，
    // 但如果有人把这里改成 `if (find.text('记一笔').evaluate().isNotEmpty)`，
    // 下面两条就会退化成「什么都没检查的空断言」。
    // 显式断言存在性，是为了让「入口被藏起来」这件事**不能伪装成通过**。
    expect(find.text('记一笔'), findsOneWidget, reason: 'M1 起记账入口必须存在且只有一处 —— 藏起来不叫安全，只叫用户找不到');

    // ② 点进去必须落在解锁页，而不是记账页。
    await tester.tap(find.text('记一笔'));
    await tester.pumpAndSettle();

    expect(find.byType(UnlockPage), findsOneWidget, reason: '点击「记一笔」必须进入解锁页；进入记账页意味着护栏已经失效');
    // 断言「已经离开占位屏」是必要的：否则「点了但没反应」也会让上一条之外
    // 的检查全部落空，而这恰恰是最难发现的一种坏法 ——
    // 界面看着正常，只是某个按钮悄悄变成了摆设。
    expect(find.byType(BuildStatusPage), findsNothing, reason: '必须真的发生了页面跳转，而不是原地不动');

    // ③ 关键约束（M0 护栏的实质，原样保留）：解锁之前，屏幕上不得出现任何账目字段。
    //
    // 前两条防的是「护栏被拆」，这一条防的是「护栏形同虚设」：
    // 只要账目字段能出现在未解锁的界面上，
    // 「用户把真实数据写进了没有保护的地方」这个后果就已经成立了 ——
    // 加密落盘链路要到 M2/M3 才就绪（见构建信息页的里程碑表）。
    for (final label in <String>['收入', '支出', '账单', '余额', '金额']) {
      expect(find.text(label), findsNothing, reason: '解锁前不应出现账目字段「$label」');
    }
  });
}

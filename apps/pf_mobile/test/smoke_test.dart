/// 冒烟测试：应用能构建，且构建信息与 [PfBuildInfo] 一致。
///
/// 这条测试看起来价值不高，但它守的是一个真实的失败模式：
/// 有人改了 `PfBuildInfo.appVersion` 却忘了改 `apps/pf_mobile/pubspec.yaml`
/// 的 `version`，于是「设置页显示的版本」与「应用包管理器里的版本」不一致 ——
/// 用户报障时给出的版本号是错的，排查直接走偏。
///
/// 版本一致性由 CI 关卡 1 做硬校验（见 docs/M0_ACCEPTANCE.md），
/// 这里只保证 UI 展示确实读的是同一份常量。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pf_core/pf_core.dart';
import 'package:pf_mobile/main.dart';

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

  testWidgets('MVP 阶段不得出现任何「记账」入口', (WidgetTester tester) async {
    // 这是一个刻意的负面断言：在加密数据库与解锁流程就绪之前，
    // 任何能写入账目的界面都意味着「用户把真实数据放进了没有保护的地方」。
    // 若某天有人提前加了记账入口，这条测试会红 —— 那正是它存在的意义。
    await tester.pumpWidget(const PfWalletApp());
    await tester.pumpAndSettle();

    for (final label in <String>['记一笔', '新增', '收入', '支出', '账单']) {
      expect(find.text(label), findsNothing, reason: 'M0 阶段不应存在「$label」入口');
    }
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pf_core/pf_core.dart';
import 'package:pf_ui/pf_ui.dart';

void main() {
  group('默认配色', () {
    test('浅色与深色两套齐备，且模式标记正确', () {
      expect(PfPalette.lightDefault.brightness, PfBrightness.light);
      expect(PfPalette.darkDefault.brightness, PfBrightness.dark);
      expect(PfPalette.defaultsFor(PfBrightness.dark), PfPalette.darkDefault);
    });

    test('所有可调整槽位都有取值', () {
      for (final slot in PfPalette.adjustableSlots) {
        expect(PfPalette.lightDefault.slot(slot), isNotNull, reason: slot);
        expect(PfPalette.darkDefault.slot(slot), isNotNull, reason: slot);
      }
    });

    test('可调整槽位不重复', () {
      expect(PfPalette.adjustableSlots.toSet(), hasLength(PfPalette.adjustableSlots.length));
    });
  });

  group('收支语义色', () {
    test('默认：支出暖色，收入绿色（中文语境）', () {
      const palette = PfPalette.lightDefault;
      expect(palette.effectiveExpense, palette.expense);
      expect(palette.effectiveIncome, palette.income);
      // 色相检查：支出的红分量应高于绿分量；收入相反
      expect(palette.expense.r, greaterThan(palette.expense.g));
      expect(palette.income.g, greaterThan(palette.income.r));
    });

    test('转账色独立于收入与支出（转账不计入收支）', () {
      const palette = PfPalette.lightDefault;
      expect(palette.transfer, isNot(palette.expense));
      expect(palette.transfer, isNot(palette.income));
    });

    test('可反转收支配色', () {
      final inverted = PfPalette.lightDefault.copyWith(invertFlowColors: true);
      expect(inverted.effectiveExpense, PfPalette.lightDefault.income);
      expect(inverted.effectiveIncome, PfPalette.lightDefault.expense);
    });
  });

  group('自定义配色', () {
    test('withSlot 修改单个槽位', () {
      const custom = Color(0xFF123456);
      final palette = PfPalette.lightDefault.withSlot('accent', custom);
      expect(palette.accent, custom);
      expect(palette.background, PfPalette.lightDefault.background);
    });

    test('withSlot 对未知槽位抛 DomainError', () {
      expect(
        () => PfPalette.lightDefault.withSlot('nope', const Color(0xFF000000)),
        throwsA(isA<DomainError>().having((e) => e.code, 'code', PfErrorCode.validation)),
      );
    });

    test('copyWith 只改指定字段', () {
      final palette = PfPalette.lightDefault.copyWith(accent: const Color(0xFF00FF00));
      expect(palette.accent, const Color(0xFF00FF00));
      expect(palette.expense, PfPalette.lightDefault.expense);
    });
  });

  group('序列化（自定义配色要能存进加密库并跨端同步）', () {
    test('往返一致', () {
      final custom = PfPalette.darkDefault
          .withSlot('accent', const Color(0xFFABCDEF))
          .withSlot('expense', const Color(0xFF010203))
          .copyWith(invertFlowColors: true);

      expect(PfPalette.fromJson(custom.toJson()), custom);
      expect(PfPalette.fromJsonString(custom.toJsonString()), custom);
    });

    test('颜色编码为 #AARRGGBB 十六进制（避免 JSON 数值范围歧义）', () {
      final json = PfPalette.lightDefault.toJson();
      final colors = json['colors']! as Map<String, String>;
      expect(colors['accent'], '#FF2F6B5F');
      expect(RegExp(r'^#[0-9A-F]{8}$').hasMatch(colors['background']!), isTrue);
    });

    test('缺失槽位回落到同模式默认值（向前兼容新增槽位）', () {
      final partial = <String, Object?>{
        'brightness': 'dark',
        'colors': <String, String>{'accent': '#FF112233'},
      };
      final palette = PfPalette.fromJson(partial);
      expect(palette.brightness, PfBrightness.dark);
      expect(palette.accent, const Color(0xFF112233));
      expect(palette.expense, PfPalette.darkDefault.expense);
      expect(palette.invertFlowColors, isFalse);
    });

    test('未知 brightness 回落到浅色而不是抛错', () {
      final palette = PfPalette.fromJson(<String, Object?>{
        'brightness': 'something-new',
        'colors': <String, String>{},
      });
      expect(palette.brightness, PfBrightness.light);
    });

    test('非法颜色值抛 DomainError', () {
      expect(
        () => PfPalette.fromJson(<String, Object?>{
          'brightness': 'light',
          'colors': <String, String>{'accent': 'red'},
        }),
        throwsA(isA<DomainError>()),
      );
    });

    test('JSON 根节点不是对象时抛错', () {
      expect(() => PfPalette.fromJsonString('[1,2,3]'), throwsA(isA<DomainError>()));
    });

    test('相等性与 hashCode 一致', () {
      final a = PfPalette.lightDefault.copyWith(accent: const Color(0xFF00FF00));
      final b = PfPalette.fromJson(a.toJson());
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('主题装配', () {
    test('浅色主题的 ColorScheme 使用我们的语义色而非种子推导结果', () {
      final theme = buildPfTheme(PfPalette.lightDefault);
      expect(theme.colorScheme.primary, PfPalette.lightDefault.accent);
      expect(theme.colorScheme.error, PfPalette.lightDefault.danger);
      expect(theme.colorScheme.surface, PfPalette.lightDefault.surface);
      expect(theme.scaffoldBackgroundColor, PfPalette.lightDefault.background);
      expect(theme.colorScheme.brightness, Brightness.light);
    });

    test('深色主题的模式标记正确', () {
      final theme = buildPfTheme(PfPalette.darkDefault);
      expect(theme.colorScheme.brightness, Brightness.dark);
      expect(theme.colorScheme.onSurface, PfPalette.darkDefault.onSurface);
    });

    test('按钮最小高度满足无障碍点击区域', () {
      final theme = buildPfTheme(PfPalette.lightDefault);
      final minimumSize = theme.filledButtonTheme.style?.minimumSize?.resolve(<WidgetState>{});
      expect(minimumSize?.height, PfSpacing.tapTarget);
      expect(PfSpacing.tapTarget, greaterThanOrEqualTo(44));
    });
  });
}

/// 配色方案（含用户自定义配色）。
///
/// ## 为什么配色是「一组具名令牌」而不是「一个种子色」
///
/// Material 3 的 `ColorScheme.fromSeed` 很方便，但它把「记账应用需要区分的
/// 语义色」全部压平成了 tonal palette。结果就是：收入、支出、转账三个数字
/// 在色轮上离得很近，用户扫一眼账单列表根本分不清哪笔是支出。
///
/// 因此本项目显式定义每个语义槽位，种子色只用于生成中性色阶。
/// 这也让「自定义配色」变成一个可序列化的确定数据结构 ——
/// 用户改的是 12 个具体颜色值，而不是一个会被算法放大成不可预期结果的种子。
///
/// ## 收支配色遵循中文语境
///
/// 支出用暖色（红 / 橙），收入用绿色。这与欧美应用中「支出中性、收入绿色」
/// 的习惯不同，与 A 股「涨红」的视觉传统一致。
/// 用户在设置里可以反转（[invertFlowColors]），因为这不是对错问题。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:pf_core/pf_core.dart';

/// 深浅模式。
enum PfBrightness {
  light('light'),
  dark('dark');

  const PfBrightness(this.wireName);

  final String wireName;

  static PfBrightness parse(String raw) => raw == dark.wireName ? dark : light;
}

/// 一套配色令牌。
@immutable
final class PfPalette {
  const PfPalette({
    required this.brightness,
    required this.accent,
    required this.onAccent,
    required this.background,
    required this.surface,
    required this.surfaceVariant,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.outline,
    required this.expense,
    required this.income,
    required this.transfer,
    required this.warning,
    required this.danger,
    this.invertFlowColors = false,
  });

  /// 浅色默认配色。
  static const PfPalette lightDefault = PfPalette(
    brightness: PfBrightness.light,
    accent: Color(0xFF2F6B5F),
    onAccent: Color(0xFFFFFFFF),
    background: Color(0xFFF7F7F5),
    surface: Color(0xFFFFFFFF),
    surfaceVariant: Color(0xFFEDEDEA),
    onSurface: Color(0xFF1B1C1A),
    onSurfaceVariant: Color(0xFF5C5F5A),
    outline: Color(0xFFC9CBC5),
    expense: Color(0xFFC0392B),
    income: Color(0xFF2E7D46),
    transfer: Color(0xFF3A6EA5),
    warning: Color(0xFFB7791F),
    danger: Color(0xFFB3261E),
  );

  /// 深色默认配色。
  static const PfPalette darkDefault = PfPalette(
    brightness: PfBrightness.dark,
    accent: Color(0xFF6FBFAE),
    onAccent: Color(0xFF06231C),
    background: Color(0xFF111312),
    surface: Color(0xFF1A1D1B),
    surfaceVariant: Color(0xFF262A27),
    onSurface: Color(0xFFE6E8E4),
    onSurfaceVariant: Color(0xFFA8ADA6),
    outline: Color(0xFF3C413D),
    expense: Color(0xFFE57368),
    income: Color(0xFF7CC08F),
    transfer: Color(0xFF7BA9D8),
    warning: Color(0xFFD8A657),
    danger: Color(0xFFE58A84),
  );

  /// 所有可供用户调整的槽位名（顺序即设置页顺序）。
  static const List<String> adjustableSlots = <String>[
    'accent',
    'background',
    'surface',
    'surfaceVariant',
    'onSurface',
    'onSurfaceVariant',
    'outline',
    'expense',
    'income',
    'transfer',
    'warning',
    'danger',
  ];

  final PfBrightness brightness;
  final Color accent;
  final Color onAccent;
  final Color background;
  final Color surface;
  final Color surfaceVariant;
  final Color onSurface;
  final Color onSurfaceVariant;
  final Color outline;

  /// 支出色。
  final Color expense;

  /// 收入色。
  final Color income;

  /// 转账色（转账不算收入也不算支出，必须有独立配色）。
  final Color transfer;

  final Color warning;
  final Color danger;

  /// 是否反转收支配色（用户偏好，默认关闭）。
  final bool invertFlowColors;

  /// 实际用于支出的颜色。
  Color get effectiveExpense => invertFlowColors ? income : expense;

  /// 实际用于收入的颜色。
  Color get effectiveIncome => invertFlowColors ? expense : income;

  /// 按槽位名读取颜色。用于设置页与自定义配色的序列化。
  Color? slot(String name) => switch (name) {
    'accent' => accent,
    'onAccent' => onAccent,
    'background' => background,
    'surface' => surface,
    'surfaceVariant' => surfaceVariant,
    'onSurface' => onSurface,
    'onSurfaceVariant' => onSurfaceVariant,
    'outline' => outline,
    'expense' => expense,
    'income' => income,
    'transfer' => transfer,
    'warning' => warning,
    'danger' => danger,
    _ => null,
  };

  /// 按槽位名替换颜色。未知槽位抛 [DomainError.validation]。
  PfPalette withSlot(String name, Color color) {
    switch (name) {
      case 'accent':
        return copyWith(accent: color);
      case 'onAccent':
        return copyWith(onAccent: color);
      case 'background':
        return copyWith(background: color);
      case 'surface':
        return copyWith(surface: color);
      case 'surfaceVariant':
        return copyWith(surfaceVariant: color);
      case 'onSurface':
        return copyWith(onSurface: color);
      case 'onSurfaceVariant':
        return copyWith(onSurfaceVariant: color);
      case 'outline':
        return copyWith(outline: color);
      case 'expense':
        return copyWith(expense: color);
      case 'income':
        return copyWith(income: color);
      case 'transfer':
        return copyWith(transfer: color);
      case 'warning':
        return copyWith(warning: color);
      case 'danger':
        return copyWith(danger: color);
      default:
        throw DomainError.validation(detail: '未知的配色槽位 "$name"');
    }
  }

  PfPalette copyWith({
    PfBrightness? brightness,
    Color? accent,
    Color? onAccent,
    Color? background,
    Color? surface,
    Color? surfaceVariant,
    Color? onSurface,
    Color? onSurfaceVariant,
    Color? outline,
    Color? expense,
    Color? income,
    Color? transfer,
    Color? warning,
    Color? danger,
    bool? invertFlowColors,
  }) => PfPalette(
    brightness: brightness ?? this.brightness,
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    background: background ?? this.background,
    surface: surface ?? this.surface,
    surfaceVariant: surfaceVariant ?? this.surfaceVariant,
    onSurface: onSurface ?? this.onSurface,
    onSurfaceVariant: onSurfaceVariant ?? this.onSurfaceVariant,
    outline: outline ?? this.outline,
    expense: expense ?? this.expense,
    income: income ?? this.income,
    transfer: transfer ?? this.transfer,
    warning: warning ?? this.warning,
    danger: danger ?? this.danger,
    invertFlowColors: invertFlowColors ?? this.invertFlowColors,
  );

  /// 取该模式下的另一套默认配色（用于跟随系统切换深浅）。
  static PfPalette defaultsFor(PfBrightness brightness) =>
      brightness == PfBrightness.dark ? darkDefault : lightDefault;

  /// 序列化为 JSON。颜色存为 `#AARRGGBB` 十六进制字符串 ——
  /// 存 int 会在 JSON 与 Dart 之间的数值范围上产生歧义（ARGB 超过 2^31）。
  Map<String, Object?> toJson() => <String, Object?>{
    'brightness': brightness.wireName,
    'colors': <String, String>{
      for (final slot in adjustableSlots) slot: _encodeColor(this.slot(slot)!),
      'onAccent': _encodeColor(onAccent),
    },
    'invertFlowColors': invertFlowColors,
  };

  /// 从 JSON 恢复。
  ///
  /// 缺失槽位回落到同模式的默认值，而不是抛错 ——
  /// 这样将来新增槽位时，旧版本的配色设置仍然可以加载。
  static PfPalette fromJson(Map<String, Object?> json) {
    final brightness = PfBrightness.parse(
      json['brightness'] is String ? json['brightness']! as String : '',
    );
    final fallback = defaultsFor(brightness);
    final colors = json['colors'];
    var palette = fallback;
    if (colors is Map) {
      for (final entry in colors.entries) {
        final name = entry.key;
        final value = entry.value;
        if (name is! String || value is! String) continue;
        palette = palette.withSlot(name, _decodeColor(value));
      }
    }
    final invert = json['invertFlowColors'];
    return palette.copyWith(invertFlowColors: invert is bool ? invert : false);
  }

  String toJsonString() => jsonEncode(toJson());

  static PfPalette fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw DomainError.validation(detail: '配色 JSON 根节点必须是对象');
    }
    return fromJson(decoded.cast<String, Object?>());
  }

  @override
  bool operator ==(Object other) =>
      other is PfPalette &&
      other.brightness == brightness &&
      other.invertFlowColors == invertFlowColors &&
      // 参数名必须与 slot(...) 方法区分开：用 slot 当参数名时，
      // slot(slot) 里的 slot 是字符串，编译期就会报「表达式不是函数」。
      adjustableSlots.every((String name) => other.slot(name) == slot(name)) &&
      other.onAccent == onAccent;

  @override
  int get hashCode => Object.hash(
    brightness,
    invertFlowColors,
    onAccent,
    // 直接用方法引用（tearoff）而不是闭包：语义相同但更短，
    // 而且能保证「遍历用的名字」与「取值用的方法」不会再次同名相撞。
    Object.hashAll(adjustableSlots.map(slot)),
  );

  @override
  String toString() => 'PfPalette(${brightness.wireName}, ${adjustableSlots.length} slots)';
}

/// 由配色令牌构建 Flutter 主题。
///
/// 刻意手写 ColorScheme 而不是 `ColorScheme.fromSeed`：
/// 后者会用自己的算法覆盖我们精心选定的语义色，导致收入 / 支出在深色模式下
/// 对比度不足。这里每个值都是显式给定的。
ThemeData buildPfTheme(PfPalette palette, {String? fontFamily}) {
  final isDark = palette.brightness == PfBrightness.dark;
  final scheme = ColorScheme(
    brightness: isDark ? Brightness.dark : Brightness.light,
    primary: palette.accent,
    onPrimary: palette.onAccent,
    secondary: palette.transfer,
    onSecondary: palette.onAccent,
    error: palette.danger,
    onError: palette.onAccent,
    surface: palette.surface,
    onSurface: palette.onSurface,
    surfaceContainerHighest: palette.surfaceVariant,
    onSurfaceVariant: palette.onSurfaceVariant,
    outline: palette.outline,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.background,
    fontFamily: fontFamily,
    appBarTheme: AppBarTheme(
      backgroundColor: palette.background,
      foregroundColor: palette.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    dividerTheme: DividerThemeData(color: palette.outline, thickness: 0.5, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.surfaceVariant,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PfSpacing.fieldRadius),
        borderSide: BorderSide.none,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.accent,
        foregroundColor: palette.onAccent,
        minimumSize: const Size.fromHeight(PfSpacing.tapTarget),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(PfSpacing.fieldRadius)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: palette.accent),
    ),
  );
}

/// 间距与尺寸尺度。全部集中在这里，避免页面里散落魔法数字。
abstract final class PfSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// 最小可点区域（无障碍要求 44pt / 48dp，取较大者）。
  static const double tapTarget = 48;

  static const double fieldRadius = 10;
  static const double cardRadius = 12;
}

/// 颜色编解码：`#AARRGGBB`。
String _encodeColor(Color color) {
  final value = color.toARGB32();
  return '#${value.toRadixString(16).padLeft(8, '0').toUpperCase()}';
}

Color _decodeColor(String source) {
  final text = source.startsWith('#') ? source.substring(1) : source;
  final value = int.tryParse(text, radix: 16);
  if (value == null || text.length != 8) {
    throw DomainError.validation(detail: '配色值必须是 #AARRGGBB 形式，实际 "$source"');
  }
  return Color(value);
}

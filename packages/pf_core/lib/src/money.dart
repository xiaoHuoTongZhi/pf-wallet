/// 金额与币种。
///
/// ## 为什么不直接用 double
///
/// `0.1 + 0.2 == 0.30000000000000004`。在记账应用里，一分钱的差错会让用户
/// 对整个账本失去信任，而这类错误极难定位。因此金额一律以整数的最小货币单位表示
/// （人民币即「分」），只在渲染文本时转成小数形式。
///
/// ## 为什么不用 BigInt
///
/// BigInt 每次运算都堆分配，而账单列表渲染 10 万行时会做海量算术。
/// 用 `int` + 显式范围检查更划算：上限设为 2^53 - 1（JS 安全整数），
/// 即 9007 万亿元 —— 对个人记账没有任何实际约束，
/// 但保证了将来若出现 Web 端，行为与其他端完全一致。
library;

import 'errors.dart';

/// ISO-4217 币种。
final class Currency implements Comparable<Currency> {
  const Currency(this.code, this.minorScale);

  /// 人民币。本项目默认币种。
  static const Currency cny = Currency('CNY', 2);

  /// 欧元。
  static const Currency eur = Currency('EUR', 2);

  /// 日元（无小数位）。
  static const Currency jpy = Currency('JPY', 0);

  /// 韩元（无小数位）。
  static const Currency krw = Currency('KRW', 0);

  /// 美元。
  static const Currency usd = Currency('USD', 2);

  /// 三字母大写代码。
  final String code;

  /// 小数位数：人民币 / 美元为 2，日元 / 韩元为 0。
  final int minorScale;

  @override
  int compareTo(Currency other) => code.compareTo(other.code);

  @override
  bool operator ==(Object other) =>
      other is Currency && other.code == code && other.minorScale == minorScale;

  @override
  int get hashCode => Object.hash(code, minorScale);

  @override
  String toString() => code;
}

/// 金额。以最小货币单位的整数存储，绝不用浮点。
final class Money implements Comparable<Money> {
  const Money._(this.minorUnits, this.currency);

  /// 以最小货币单位构造（人民币：分）。**唯一无歧义的构造方式**。
  factory Money.fromMinorUnits(int minorUnits, {required Currency currency}) =>
      Money._(_checkRange(minorUnits), currency);

  /// 以主货币单位构造（12 元 → `Money.fromMajorUnits(12, currency: Currency.cny)`）。
  factory Money.fromMajorUnits(int majorUnits, {required Currency currency}) =>
      Money._(_checkRange(majorUnits * _pow10(currency.minorScale)), currency);

  /// 解析用户输入。
  ///
  /// 接受：`1234.56`、`-12`、`+3.5`、`¥1,234.56`、`1234.56 CNY`。
  /// 拒绝：小数位多于币种精度。**宁可报错也不静默四舍五入** ——
  /// 静默舍入会让账目对不上，而用户不会知道是哪一笔出的问题。
  /// 也拒绝全角数字与阿拉伯-印度数字，避免在不同输入法下产生难以复现的差异。
  factory Money.parse(String input, {required Currency currency}) {
    var text = input.trim();
    if (text.isEmpty) {
      throw DomainError.moneyFormat(input: input);
    }
    text = text.replaceAll(',', '').replaceAll(' ', '').replaceAll('_', '');

    for (final symbol in _currencySymbols) {
      if (text.startsWith(symbol)) {
        text = text.substring(symbol.length);
        break;
      }
    }
    if (text.length > currency.code.length && text.toUpperCase().endsWith(currency.code)) {
      text = text.substring(0, text.length - currency.code.length);
    }

    final match = RegExp(r'^([+-]?)(\d+)(?:\.(\d+))?$').firstMatch(text);
    if (match == null) {
      throw DomainError.moneyFormat(input: input);
    }

    final negative = match.group(1) == '-';
    final integerPart = match.group(2)!;
    final fractionPart = match.group(3) ?? '';

    if (fractionPart.length > currency.minorScale) {
      throw DomainError.moneyFormat(input: input);
    }

    final majorUnits = int.tryParse(integerPart);
    if (majorUnits == null || majorUnits > maxMinorUnits) {
      throw DomainError.moneyOverflow(value: maxMinorUnits);
    }

    final scale = _pow10(currency.minorScale);
    final paddedFraction = fractionPart.padRight(currency.minorScale, '0');
    final fractionUnits = paddedFraction.isEmpty ? 0 : int.parse(paddedFraction);
    final total = majorUnits * scale + fractionUnits;

    return Money._(_checkRange(negative ? -total : total), currency);
  }

  /// 零金额（人民币）。币种无关的零值请用 `Money.fromMinorUnits(0, currency: ...)`。
  static const Money zeroCny = Money._(0, Currency.cny);

  /// 可精确表示的上限：2^53 - 1。
  static const int maxMinorUnits = 9007199254740991;

  /// 最小货币单位的整数金额。
  final int minorUnits;

  /// 币种。
  final Currency currency;

  bool get isZero => minorUnits == 0;
  bool get isNegative => minorUnits < 0;
  bool get isPositive => minorUnits > 0;

  Money operator +(Money other) {
    _assertSameCurrency(other);
    return Money._(_checkRange(minorUnits + other.minorUnits), currency);
  }

  Money operator -(Money other) {
    _assertSameCurrency(other);
    return Money._(_checkRange(minorUnits - other.minorUnits), currency);
  }

  Money operator -() => Money._(-minorUnits, currency);

  Money operator *(int factor) => Money._(_checkRange(minorUnits * factor), currency);

  Money abs() => isNegative ? Money._(-minorUnits, currency) : this;

  /// 币种一致性硬检查。
  ///
  /// 刻意不做自动换算：汇率是外部数据，本项目不联网。
  /// 静默按 1:1 相加会让用户的多币种账目彻底错乱且无法追溯。
  void _assertSameCurrency(Money other) {
    if (other.currency != currency) {
      throw DomainError.currencyMismatch(left: currency.code, right: other.currency.code);
    }
  }

  /// 求和。空集合返回该币种的零值。
  static Money sum(Iterable<Money> items, {required Currency currency}) {
    var total = Money._(0, currency);
    for (final item in items) {
      total = total + item;
    }
    return total;
  }

  @override
  int compareTo(Money other) {
    _assertSameCurrency(other);
    return minorUnits.compareTo(other.minorUnits);
  }

  @override
  bool operator ==(Object other) =>
      other is Money && other.minorUnits == minorUnits && other.currency == currency;

  @override
  int get hashCode => Object.hash(minorUnits, currency);

  /// 渲染为可读文本。
  ///
  /// [grouping] 为 true 时插入千分位；[withCurrencyCode] 为 true 时追加币种代码。
  /// 刻意不追加货币符号（¥ 在多币种场景下有歧义：日元与人民币同符号）。
  String format({bool grouping = true, bool withCurrencyCode = false}) {
    final absolute = isNegative ? -minorUnits : minorUnits;
    final divisor = _pow10(currency.minorScale);
    final major = absolute ~/ divisor;
    final minor = absolute % divisor;

    final buffer = StringBuffer();
    if (isNegative) buffer.write('-');
    buffer.write(grouping ? _groupDigits(major.toString()) : major.toString());
    if (currency.minorScale > 0) {
      buffer
        ..write('.')
        ..write(minor.toString().padLeft(currency.minorScale, '0'));
    }
    if (withCurrencyCode) {
      buffer
        ..write(' ')
        ..write(currency.code);
    }
    return buffer.toString();
  }

  /// 序列化。币种精度一并写入，便于接收方做一致性校验。
  Map<String, Object?> toJson() => <String, Object?>{
    'minorUnits': minorUnits,
    'currency': currency.code,
    'scale': currency.minorScale,
  };

  /// 反序列化。**不信任输入**：精度不一致直接拒绝。
  static Money fromJson(Map<String, Object?> json) {
    final minorUnits = json['minorUnits'];
    final code = json['currency'];
    final scale = json['scale'];
    if (minorUnits is! int || code is! String || scale is! int) {
      throw DomainError.validation(detail: 'Money JSON 字段类型不正确: $json');
    }
    final currency = Currency(code, scale);
    return Money._(_checkRange(minorUnits), currency);
  }

  @override
  String toString() => format();
}

const List<String> _currencySymbols = <String>['¥', '￥', r'$', '€', '£'];

int _pow10(int exponent) {
  var result = 1;
  for (var i = 0; i < exponent; i++) {
    result *= 10;
  }
  return result;
}

int _checkRange(int value) {
  if (value > Money.maxMinorUnits || value < -Money.maxMinorUnits) {
    throw DomainError.moneyOverflow(value: value);
  }
  return value;
}

String _groupDigits(String digits) {
  if (digits.length <= 3) return digits;
  final buffer = StringBuffer();
  final leading = digits.length % 3;
  if (leading > 0) {
    buffer.write(digits.substring(0, leading));
  }
  for (var i = leading; i < digits.length; i += 3) {
    if (buffer.isNotEmpty) buffer.write(',');
    buffer.write(digits.substring(i, i + 3));
  }
  return buffer.toString();
}

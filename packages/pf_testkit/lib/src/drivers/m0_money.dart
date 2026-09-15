/// M0 驱动：金额与币种。
///
/// 记账软件最不能出的一类错误是「差一分钱」。金额一律以整数最小单位存储，
/// 因此这里的向量守两件事：
///
///   1. **解析绝不静默舍入**。`1.234` 这样的输入必须报错，
///      而不是变成 `1.23` —— 静默舍入会让账目对不上，且用户永远查不出是哪一笔。
///   2. **跨币种绝不隐式换算**。本项目不联网、拿不到汇率，
///      按 1:1 相加会让多币种账目彻底错乱且无法追溯。
library;

import 'package:pf_core/pf_core.dart';

import '../driver.dart';
import '../json_util.dart';
import '../outcome.dart';

/// 渲染为文本。
final class MoneyFormatDriver extends VectorDriver {
  const MoneyFormatDriver();

  @override
  String get kind => 'money.format';

  @override
  String get description => '把整数最小单位渲染为可读文本（千分位 / 币种代码可选）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'minorUnits': 'int，最小货币单位金额',
    'currency': '字符串，ISO-4217 代码',
    'scale': 'int，小数位数',
    'grouping': 'bool（可选，缺省 true），是否插入千分位',
    'withCurrencyCode': 'bool（可选，缺省 false），是否追加币种代码',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final money = Money.fromMinorUnits(
      requireInt(input, 'minorUnits', kind),
      currency: _currencyOf(input, kind),
    );
    return VectorOutcome.value(<String, Object?>{
      'text': money.format(
        grouping: optionalBool(input, 'grouping', true),
        withCurrencyCode: optionalBool(input, 'withCurrencyCode', false),
      ),
      'isNegative': money.isNegative,
      'isZero': money.isZero,
    });
  }
}

/// 解析用户输入。
final class MoneyParseDriver extends VectorDriver {
  const MoneyParseDriver();

  @override
  String get kind => 'money.parse';

  @override
  String get description => '解析用户输入为整数最小单位金额（精度不足即报错）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'text': '字符串，用户输入',
    'currency': '字符串，ISO-4217 代码',
    'scale': 'int，小数位数',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final money = Money.parse(
      requireString(input, 'text', kind),
      currency: _currencyOf(input, kind),
    );
    return VectorOutcome.value(<String, Object?>{
      'minorUnits': money.minorUnits,
      'formatted': money.format(),
    });
  }
}

/// 求和。
final class MoneySumDriver extends VectorDriver {
  const MoneySumDriver();

  @override
  String get kind => 'money.sum';

  @override
  String get description => '对同币种金额求和（跨币种抛 PFC_E_CURRENCY_MISMATCH）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'items': '数组，元素为 {minorUnits, currency, scale}',
    'currency': '字符串，结果币种',
    'scale': 'int，结果币种小数位',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final rawItems = requireList(input, 'items', kind);
    final items = <Money>[];
    for (var i = 0; i < rawItems.length; i++) {
      final Object? raw = rawItems[i];
      if (raw is! Map<String, Object?>) {
        throwVectorInput(kind, 'items[$i] 必须是对象');
      }
      items.add(
        Money.fromMinorUnits(
          requireInt(raw, 'minorUnits', '$kind items[$i]'),
          currency: _currencyOf(raw, '$kind items[$i]'),
        ),
      );
    }
    final total = Money.sum(items, currency: _currencyOf(input, kind));
    return VectorOutcome.value(<String, Object?>{
      'minorUnits': total.minorUnits,
      'formatted': total.format(),
    });
  }
}

/// 币种相等性（`scale` 是币种定义的一部分，必须一并比较）。
final class CurrencyEqualityDriver extends VectorDriver {
  const CurrencyEqualityDriver();

  @override
  String get kind => 'currency.equality';

  @override
  String get description => '币种相等性判定：代码相同但精度不同视为不同币种';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'leftCurrency': '字符串',
    'leftScale': 'int',
    'rightCurrency': '字符串',
    'rightScale': 'int',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final left = Currency(
      requireString(input, 'leftCurrency', kind),
      requireInt(input, 'leftScale', kind),
    );
    final right = Currency(
      requireString(input, 'rightCurrency', kind),
      requireInt(input, 'rightScale', kind),
    );
    return VectorOutcome.value(<String, Object?>{
      'equal': left == right,
      'hashEqual': left.hashCode == right.hashCode,
      'left': left.toString(),
      'right': right.toString(),
    });
  }
}

Currency _currencyOf(Map<String, Object?> input, String where) =>
    Currency(requireString(input, 'currency', where), requireInt(input, 'scale', where));

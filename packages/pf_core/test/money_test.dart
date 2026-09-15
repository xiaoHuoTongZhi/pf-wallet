import 'package:pf_core/pf_core.dart';
import 'package:test/test.dart';

void main() {
  group('浮点误差 —— 这套设计存在的核心理由', () {
    test('0.1 + 0.2 精确等于 0.3', () {
      final sum =
          Money.parse('0.1', currency: Currency.cny) + Money.parse('0.2', currency: Currency.cny);
      expect(sum, Money.parse('0.3', currency: Currency.cny));
      expect(sum.minorUnits, 30);
    });

    test('对照组：double 做不到', () {
      expect(0.1 + 0.2 == 0.3, isFalse);
    });

    test('累加 1000 次 0.01 精确等于 10.00', () {
      final cent = Money.parse('0.01', currency: Currency.cny);
      var total = Money.fromMinorUnits(0, currency: Currency.cny);
      for (var i = 0; i < 1000; i++) {
        total = total + cent;
      }
      expect(total, Money.parse('10', currency: Currency.cny));
      expect(total.format(), '10.00');
    });
  });

  group('构造', () {
    test('fromMinorUnits', () {
      expect(Money.fromMinorUnits(1234, currency: Currency.cny).minorUnits, 1234);
      expect(Money.fromMinorUnits(-1, currency: Currency.cny).format(), '-0.01');
    });

    test('fromMajorUnits 按币种精度缩放', () {
      expect(Money.fromMajorUnits(12, currency: Currency.cny).minorUnits, 1200);
      expect(Money.fromMajorUnits(12, currency: Currency.jpy).minorUnits, 12);
    });

    test('边界值 maxMinorUnits 可用，超出即抛错', () {
      expect(
        Money.fromMinorUnits(Money.maxMinorUnits, currency: Currency.cny).minorUnits,
        Money.maxMinorUnits,
      );
      expect(
        () => Money.fromMinorUnits(Money.maxMinorUnits + 1, currency: Currency.cny),
        throwsA(isA<DomainError>().having((e) => e.code, 'code', PfErrorCode.moneyOverflow)),
      );
    });

    test('fromMajorUnits 溢出同样抛错', () {
      expect(
        () => Money.fromMajorUnits(Money.maxMinorUnits, currency: Currency.cny),
        throwsA(isA<DomainError>()),
      );
    });
  });

  group('parse', () {
    test('接受常见写法', () {
      expect(Money.parse('1234.56', currency: Currency.cny).minorUnits, 123456);
      expect(Money.parse('-12', currency: Currency.cny).minorUnits, -1200);
      expect(Money.parse('+3.5', currency: Currency.cny).minorUnits, 350);
      expect(Money.parse('0', currency: Currency.cny).minorUnits, 0);
    });

    test('剥离千分位、空格与货币符号', () {
      expect(Money.parse('¥1,234.56', currency: Currency.cny).minorUnits, 123456);
      expect(Money.parse('￥1 234.56', currency: Currency.cny).minorUnits, 123456);
      expect(Money.parse(r'$9.99', currency: Currency.usd).minorUnits, 999);
      expect(Money.parse('1234.56 CNY', currency: Currency.cny).minorUnits, 123456);
      expect(Money.parse('1234.56cny', currency: Currency.cny).minorUnits, 123456);
    });

    test('无小数位币种不接受小数', () {
      expect(Money.parse('1200', currency: Currency.jpy).minorUnits, 1200);
      expect(
        () => Money.parse('1200.5', currency: Currency.jpy),
        throwsA(isA<DomainError>().having((e) => e.code, 'code', PfErrorCode.moneyFormat)),
      );
    });

    test('小数位超出币种精度一律报错，绝不静默四舍五入', () {
      expect(
        () => Money.parse('1.234', currency: Currency.cny),
        throwsA(isA<DomainError>().having((e) => e.code, 'code', PfErrorCode.moneyFormat)),
      );
    });

    test('拒绝非法输入', () {
      for (final input in <String>['', '   ', 'abc', '1.2.3', '1-2', '1.', '.5', '一万元']) {
        expect(
          () => Money.parse(input, currency: Currency.cny),
          throwsA(isA<DomainError>()),
          reason: '"$input" 应当被拒绝',
        );
      }
    });

    test('超长数字抛溢出而非静默截断', () {
      expect(
        () => Money.parse('99999999999999999999999999', currency: Currency.cny),
        throwsA(isA<DomainError>().having((e) => e.code, 'code', PfErrorCode.moneyOverflow)),
      );
    });
  });

  group('运算', () {
    test('加减法', () {
      final a = Money.parse('100', currency: Currency.cny);
      final b = Money.parse('23.45', currency: Currency.cny);
      expect((a - b).format(), '76.55');
      expect((b - a).format(), '-76.55');
    });

    test('取负与绝对值', () {
      final negative = Money.parse('-5.5', currency: Currency.cny);
      expect((-negative).format(), '5.50');
      expect(negative.abs().format(), '5.50');
      expect((-negative).isPositive, isTrue);
    });

    test('乘以整数因子', () {
      expect((Money.parse('12.34', currency: Currency.cny) * 3).format(), '37.02');
      expect((Money.parse('12.34', currency: Currency.cny) * 0).isZero, isTrue);
    });

    test('跨币种运算抛 DomainError（不做隐式换算）', () {
      final cny = Money.parse('100', currency: Currency.cny);
      final usd = Money.parse('100', currency: Currency.usd);
      expect(
        () => cny + usd,
        throwsA(
          isA<DomainError>().having((e) => e.code, 'code', PfErrorCode.moneyCurrencyMismatch),
        ),
      );
      expect(() => cny.compareTo(usd), throwsA(isA<DomainError>()));
    });

    test('sum 空集合返回该币种零值', () {
      final total = Money.sum(const <Money>[], currency: Currency.jpy);
      expect(total.minorUnits, 0);
      expect(total.currency, Currency.jpy);
    });

    test('sum 正常求和', () {
      final total = Money.sum(<Money>[
        Money.parse('1.11', currency: Currency.cny),
        Money.parse('2.22', currency: Currency.cny),
        Money.parse('3.33', currency: Currency.cny),
      ], currency: Currency.cny);
      expect(total.format(), '6.66');
    });
  });

  group('比较与相等', () {
    test('同币种可比较', () {
      // 刻意不用 `<`：Money 只实现 compareTo 而不重载比较运算符 ——
      // 跨币种比较必须抛错，而运算符重载没法在静态分析阶段表达这一点。
      expect(
        Money.parse(
          '1',
          currency: Currency.cny,
        ).compareTo(Money.parse('2', currency: Currency.cny)),
        lessThan(0),
      );
    });

    test('相等性与 hashCode 一致', () {
      final a = Money.parse('1.00', currency: Currency.cny);
      final b = Money.fromMinorUnits(100, currency: Currency.cny);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('金额相同但币种不同则不相等', () {
      expect(
        Money.fromMinorUnits(100, currency: Currency.cny),
        isNot(Money.fromMinorUnits(100, currency: Currency.usd)),
      );
    });

    test('币种精度不同也不相等（防止误判为同一币种）', () {
      expect(Currency('XYZ', 2), isNot(Currency('XYZ', 3)));
    });
  });

  group('格式化', () {
    test('千分位分组', () {
      expect(Money.fromMinorUnits(123456789, currency: Currency.cny).format(), '1,234,567.89');
      expect(Money.fromMinorUnits(1000, currency: Currency.cny).format(), '10.00');
      expect(Money.fromMinorUnits(99999, currency: Currency.cny).format(), '999.99');
      expect(Money.fromMinorUnits(100000, currency: Currency.cny).format(), '1,000.00');
    });

    test('可关闭分组', () {
      expect(
        Money.fromMinorUnits(123456789, currency: Currency.cny).format(grouping: false),
        '1234567.89',
      );
    });

    test('负数与零', () {
      expect(Money.fromMinorUnits(-1, currency: Currency.cny).format(), '-0.01');
      expect(Money.fromMinorUnits(0, currency: Currency.cny).format(), '0.00');
    });

    test('无小数位币种不输出小数点', () {
      expect(Money.fromMinorUnits(1234, currency: Currency.jpy).format(), '1,234');
    });

    test('可追加币种代码（不追加符号，¥ 有歧义）', () {
      expect(
        Money.fromMinorUnits(100, currency: Currency.cny).format(withCurrencyCode: true),
        '1.00 CNY',
      );
    });
  });

  group('序列化', () {
    test('JSON 往返一致', () {
      final original = Money.parse('-12345.67', currency: Currency.cny);
      expect(Money.fromJson(original.toJson()), original);
    });

    test('JSON 携带币种精度，便于接收方校验', () {
      expect(Money.fromMinorUnits(1, currency: Currency.cny).toJson(), <String, Object?>{
        'minorUnits': 1,
        'currency': 'CNY',
        'scale': 2,
      });
    });

    test('字段类型不对抛 DomainError', () {
      expect(
        () => Money.fromJson(<String, Object?>{'minorUnits': '1', 'currency': 'CNY', 'scale': 2}),
        throwsA(isA<DomainError>().having((e) => e.code, 'code', PfErrorCode.validation)),
      );
      expect(
        () => Money.fromJson(<String, Object?>{'minorUnits': 1, 'currency': 'CNY'}),
        throwsA(isA<DomainError>()),
      );
    });

    test('反序列化时同样做范围检查（不信任输入）', () {
      expect(
        () => Money.fromJson(<String, Object?>{
          'minorUnits': Money.maxMinorUnits + 1,
          'currency': 'CNY',
          'scale': 2,
        }),
        throwsA(isA<DomainError>().having((e) => e.code, 'code', PfErrorCode.moneyOverflow)),
      );
    });
  });
}

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:test/test.dart';

/// ULID 规范中的示例值：`ulid(1469918176385) === '01ARYZ6S41TSV4RRFFQ69G5FAV'`。
///
/// 这里刻意用**规范原文的字符串**而不是自己 encode 出来的结果：
/// 若两边都由同一份实现生成，编码与解码同时写错时测试依然全绿。
/// 外部锚点是唯一能挡住「编解码用了两套不一致映射」的东西。
const String canonicalUlid = '01ARYZ6S41TSV4RRFFQ69G5FAV';
const int canonicalMilliseconds = 1469918176385;

/// `'0' * n` 在 Dart 里不合法，用这个代替，顺便避免手数字符个数。
String zeros(int count) => List<String>.filled(count, '0').join();

void main() {
  group('encode 确定性', () {
    test('零时间戳 + 零随机 → 26 个 0', () {
      expect(UlidGenerator.encode(0, List<int>.filled(10, 0)), zeros(26));
    });

    test('时间戳 1 → 第 10 个字符为 1', () {
      expect(UlidGenerator.encode(1, List<int>.filled(10, 0)), '${zeros(9)}1${zeros(16)}');
    });

    test('全 1 随机位 → 16 个字母表末位字符 Z', () {
      final expected = '${zeros(10)}${List<String>.filled(16, 'Z').join()}';
      expect(UlidGenerator.encode(0, List<int>.filled(10, 0xFF)), expected);
    });

    test('长度恒为 26', () {
      for (var ms = 0; ms < 1000; ms += 137) {
        final id = UlidGenerator.encode(ms, List<int>.generate(10, (i) => (ms + i) % 256));
        expect(id.length, 26);
      }
    });

    test('时间戳越界抛 ArgumentError', () {
      expect(
        () => UlidGenerator.encode(maxUlidMilliseconds + 1, List<int>.filled(10, 0)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('随机字节数不对抛 ArgumentError', () {
      expect(() => UlidGenerator.encode(0, List<int>.filled(9, 0)), throwsA(isA<ArgumentError>()));
    });
  });

  group('decode', () {
    test('规范示例：时间戳可还原', () {
      final decoded = UlidGenerator.decode(canonicalUlid);
      expect(decoded.milliseconds, canonicalMilliseconds);
      expect(decoded.random, hasLength(10));
    });

    test('encode(decode(x)) == x（往返一致）', () {
      for (final sample in <String>[canonicalUlid, zeros(26), '01J8ZQK7V9X2M4N6P8R0T2V4X6']) {
        final decoded = UlidGenerator.decode(sample);
        expect(UlidGenerator.encode(decoded.milliseconds, decoded.random), sample);
      }
    });

    test('timestampOf 返回 UTC 时间', () {
      final instant = UlidGenerator.timestampOf(canonicalUlid);
      expect(instant.isUtc, isTrue);
      expect(instant.millisecondsSinceEpoch, canonicalMilliseconds);
      expect(instant.toIso8601String(), startsWith('2016-07-30'));
    });

    test('非法输入抛 FormatException', () {
      expect(() => UlidGenerator.decode('short'), throwsA(isA<FormatException>()));
      expect(() => UlidGenerator.decode('${zeros(25)}I'), throwsA(isA<FormatException>()));
    });
  });

  group('isValid', () {
    test('接受自己生成的 ID', () {
      final generator = UlidGenerator(nowMilliseconds: () => 1735689600000);
      for (var i = 0; i < 50; i++) {
        expect(UlidGenerator.isValid(generator.next()), isTrue);
      }
    });

    test('长度不为 26 一律拒绝', () {
      expect(UlidGenerator.isValid(''), isFalse);
      expect(UlidGenerator.isValid(zeros(25)), isFalse);
      expect(UlidGenerator.isValid(zeros(27)), isFalse);
    });

    test('首字符大于 7 视为时间戳溢出', () {
      expect(UlidGenerator.isValid('8${zeros(25)}'), isFalse);
      expect(UlidGenerator.isValid('Z${zeros(25)}'), isFalse);
      expect(UlidGenerator.isValid('7${zeros(25)}'), isTrue);
    });

    test('排除易混淆字符 I / L / O / U', () {
      for (final char in <String>['I', 'L', 'O', 'U']) {
        expect(UlidGenerator.isValid('0$char${zeros(24)}'), isFalse, reason: '不应当接受 $char');
      }
      for (final char in <String>['i', 'l', 'o', 'u']) {
        expect(UlidGenerator.isValid('0$char${zeros(24)}'), isFalse, reason: '不应当接受 $char');
      }
    });
  });

  group('单调性', () {
    test('同一毫秒内严格递增', () {
      final generator = UlidGenerator(
        random: math.Random(42),
        nowMilliseconds: () => 1735689600000,
      );
      final ids = List<String>.generate(5000, (_) => generator.next());
      final sorted = List<String>.of(ids)..sort();
      expect(ids, equals(sorted), reason: '同毫秒内生成的 ID 必须保持字典序递增');
      expect(ids.toSet(), hasLength(ids.length), reason: '不得重复');
    });

    test('时钟回拨时仍保持单调', () {
      var now = 1735689600000;
      final generator = UlidGenerator(random: math.Random(7), nowMilliseconds: () => now);
      final before = generator.next();
      now -= 5000; // NTP 校正 / 用户改系统时间
      final after = generator.next();
      expect(after.compareTo(before), greaterThan(0));
    });

    test('跨越毫秒边界后时间戳前进', () {
      var now = 1735689600000;
      final generator = UlidGenerator(random: math.Random(1), nowMilliseconds: () => now);
      final first = generator.next();
      now += 1;
      final second = generator.next();
      expect(UlidGenerator.timestampOf(second).isAfter(UlidGenerator.timestampOf(first)), isTrue);
    });

    test('大量生成不重复', () {
      final generator = UlidGenerator(nowMilliseconds: () => 1735689600000);
      final ids = List<String>.generate(20000, (_) => generator.next()).toSet();
      expect(ids, hasLength(20000));
    });

    test('默认生成器随机部分互不相同', () {
      final ids = List<String>.generate(200, (_) => Ulid.next());
      final randomSuffixes = ids.map((id) => id.substring(10)).toSet();
      expect(randomSuffixes, hasLength(200));
    });
  });

  group('Ulid 门面', () {
    test('next 产出合法 ID，且时间戳接近当前时间', () {
      final before = DateTime.now().toUtc();
      final id = Ulid.next();
      final after = DateTime.now().toUtc();

      expect(Ulid.isValid(id), isTrue);
      final stamp = Ulid.timestampOf(id);
      expect(stamp.isBefore(before.subtract(const Duration(seconds: 1))), isFalse);
      expect(stamp.isAfter(after.add(const Duration(seconds: 1))), isFalse);
    });
  });

  group('Crockford 字母表映射', () {
    // 回归测试：曾经把「字符 → 取值」写成 `codeUnit - 0x41 + 10` 的 ASCII 算术。
    // 字母表跳过了 I / L / O / U，于是从 'J' 开始每个字母都偏大 1，'Z' 算出 35。
    // 这类 bug 不报错、不抛出，只是**静默解码出另一个时间戳**，
    // 而版本戳的字典序就是合并算法的全序 —— 表现为「同步偶尔丢改动」。
    test('每个字母表字符都能原值往返（这是与编码表一致的唯一保证）', () {
      const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
      for (var value = 0; value < alphabet.length; value++) {
        final id = UlidGenerator.encode(value, List<int>.filled(10, 0));
        expect(id[9], alphabet[value], reason: '取值 $value 应编码为 ${alphabet[value]}');
        expect(
          UlidGenerator.decode(id).milliseconds,
          value,
          reason: '字符 ${alphabet[value]} 应解码回 $value',
        );
      }
    });

    test('跳过的字母取值不连续：J 是 18 而不是 19，Z 是 31 而不是 35', () {
      // 时间戳只占前 10 个字符，且第 10 个字符的权重是 1，
      // 因此「前 9 位为 0、第 10 位为该字符」的 ULID 解出来就是该字符的取值。
      expect(UlidGenerator.decode('${zeros(9)}J${zeros(16)}').milliseconds, 18);
      expect(UlidGenerator.decode('${zeros(9)}K${zeros(16)}').milliseconds, 19);
      expect(UlidGenerator.decode('${zeros(9)}Z${zeros(16)}').milliseconds, 31);
    });

    test('48 位时间戳上界可完整往返', () {
      const id = '7ZZZZZZZZZZZZZZZZZZZZZZZZZ';
      expect(UlidGenerator.decode(id).milliseconds, maxUlidMilliseconds);
      expect(UlidGenerator.decode(id).random, equals(List<int>.filled(10, 0xFF)));
      expect(UlidGenerator.encode(maxUlidMilliseconds, List<int>.filled(10, 0xFF)), id);
    });

    test('小写字母按字母表判定：j 合法，i / l / o / u 非法', () {
      expect(UlidGenerator.isValid('${zeros(9)}j${zeros(16)}'), isTrue);
      for (final char in <String>['i', 'l', 'o', 'u']) {
        expect(
          UlidGenerator.isValid('${zeros(9)}$char${zeros(16)}'),
          isFalse,
          reason: '不应当接受 $char',
        );
      }
    });
  });

  group('二进制承载（用于导出载荷）', () {
    test('随机部分可完整往返', () {
      final random = Uint8List.fromList(List<int>.generate(10, (i) => 255 - i));
      final id = UlidGenerator.encode(1735689600000, random);
      expect(UlidGenerator.decode(id).random, equals(random));
    });
  });
}

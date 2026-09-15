/// ULID 生成与解析。
///
/// ## 为什么用 ULID 而不是自增 ID 或 UUIDv4
///
/// 本项目没有后端，主键必须在每台设备上独立生成，同时要满足两个互相拉扯的要求：
///   1. **可排序**：账单按时间倒序分页时，若主键随机分布，SQLite 的 B-Tree
///      索引会退化为随机 I/O，10 万条记录的分页会明显卡顿。
///   2. **不可预测**：随机 ID 不能泄漏「用户当天记了几笔」这类信息。
///
/// ULID = 48 位毫秒时间戳 + 80 位随机数，恰好同时满足。
/// UUIDv7 也是同类方案，但 ULID 的 Crockford Base32 编码（26 字符、无连字符）
/// 在文件名与日志里更短、更易读。
///
/// ## 单调性
///
/// 同一毫秒内生成的 ULID，随机部分按大端整数递增，因此整体严格单调递增。
/// 这保证「先写的记录排在后写的记录之前」，让增量导出与合并的边界判定变得确定。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Crockford Base32 字母表：排除 I / L / O / U，避免人工抄写时的视觉歧义。
const String _crockfordAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// ULID 字符串长度。
const int ulidLength = 26;

/// 随机部分的字节数（80 位）。
const int ulidRandomBytes = 10;

/// 48 位毫秒时间戳上限。
const int maxUlidMilliseconds = 0xFFFFFFFFFFFF;

/// 带单调保证的 ULID 生成器。
final class UlidGenerator {
  UlidGenerator({math.Random? random, int Function()? nowMilliseconds})
    : _random = random ?? math.Random.secure(),
      _nowMilliseconds = nowMilliseconds ?? _systemNowMilliseconds;

  final math.Random _random;
  final int Function() _nowMilliseconds;
  final Uint8List _lastRandom = Uint8List(ulidRandomBytes);
  int _lastMilliseconds = -1;

  /// 生成下一个 ULID。
  ///
  /// 时钟回拨（NTP 校正、用户改系统时间）时沿用上一次的时间戳，
  /// 依赖随机部分递增来维持单调 —— 宁可时间戳略微偏大，也不能让新记录排到旧记录前面。
  String next() {
    var milliseconds = _nowMilliseconds();
    if (milliseconds < 0 || milliseconds > maxUlidMilliseconds) {
      throw StateError('毫秒时间戳 $milliseconds 超出 48 位可表示范围');
    }
    if (milliseconds < _lastMilliseconds) {
      milliseconds = _lastMilliseconds;
    }

    if (milliseconds == _lastMilliseconds) {
      milliseconds = _incrementRandom();
    } else {
      _lastMilliseconds = milliseconds;
      _fillRandom();
    }

    return encode(milliseconds, _lastRandom);
  }

  /// 由给定的时间戳与随机字节构造 ULID（确定性，供黄金向量使用）。
  static String encode(int milliseconds, List<int> randomBytes) {
    if (milliseconds < 0 || milliseconds > maxUlidMilliseconds) {
      throw ArgumentError.value(milliseconds, 'milliseconds', '必须在 0..$maxUlidMilliseconds 范围内');
    }
    if (randomBytes.length != ulidRandomBytes) {
      throw ArgumentError.value(randomBytes.length, 'randomBytes', '必须是 $ulidRandomBytes 字节');
    }

    // 48 位时间戳 → 10 个 5 位分组（首位仅用 3 位，高 2 位恒为 0）
    final values = List<int>.filled(ulidLength, 0);
    var remaining = milliseconds;
    for (var i = 9; i >= 0; i--) {
      values[i] = remaining & 0x1F;
      remaining >>= 5;
    }

    // 80 位随机数 → 16 个 5 位分组
    var buffer = 0;
    var bits = 0;
    var index = 10;
    for (final byte in randomBytes) {
      buffer = (buffer << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        values[index] = (buffer >> bits) & 0x1F;
        index += 1;
      }
    }

    final output = StringBuffer();
    for (final value in values) {
      output.write(_crockfordAlphabet[value]);
    }
    return output.toString();
  }

  /// 拆解 ULID 为时间戳与随机字节。
  static ({int milliseconds, Uint8List random}) decode(String ulid) {
    if (!isValid(ulid)) {
      throw FormatException('非法的 ULID', ulid);
    }
    var milliseconds = 0;
    for (var i = 0; i < 10; i++) {
      milliseconds = (milliseconds << 5) | _valueOf(ulid.codeUnitAt(i));
    }

    final random = Uint8List(ulidRandomBytes);
    var buffer = 0;
    var bits = 0;
    var index = 0;
    for (var i = 10; i < ulidLength; i++) {
      buffer = (buffer << 5) | _valueOf(ulid.codeUnitAt(i));
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        random[index] = (buffer >> bits) & 0xFF;
        index += 1;
      }
    }
    return (milliseconds: milliseconds, random: random);
  }

  /// 是否为合法 ULID。
  static bool isValid(String ulid) {
    if (ulid.length != ulidLength) return false;
    for (var i = 0; i < ulid.length; i++) {
      if (!_isDecodable(ulid.codeUnitAt(i))) return false;
    }
    // 首字符只用了低 3 位，取值必须 ≤ 7，否则说明时间戳溢出了 48 位
    return _valueOf(ulid.codeUnitAt(0)) <= 7;
  }

  /// ULID 中编码的时间戳（毫秒）。
  ///
  /// 与 [timestampOf] 的区别：非法输入返回 `null` 而不是抛异常。
  /// 合并对账路径上会遇到来路不明的元数据，那里需要的是「判定」而不是「崩溃」。
  static int? tryMillisecondsOf(String ulid) {
    if (!isValid(ulid)) return null;
    return decode(ulid).milliseconds;
  }

  /// ULID 中编码的 UTC 时间。
  static DateTime timestampOf(String ulid) =>
      DateTime.fromMillisecondsSinceEpoch(decode(ulid).milliseconds, isUtc: true);

  void _fillRandom() {
    for (var i = 0; i < ulidRandomBytes; i++) {
      _lastRandom[i] = _random.nextInt(256);
    }
  }

  /// 随机部分按大端整数 +1，返回本次实际使用的时间戳。
  int _incrementRandom() {
    for (var i = ulidRandomBytes - 1; i >= 0; i--) {
      if (_lastRandom[i] == 0xFF) {
        _lastRandom[i] = 0;
        continue;
      }
      _lastRandom[i] += 1;
      return _lastMilliseconds;
    }
    // 随机部分整体回绕（概率 2^-80）。把时间戳推进 1 毫秒后重新掷点，
    // 依然保持单调递增。
    _lastMilliseconds += 1;
    _fillRandom();
    return _lastMilliseconds;
  }

  static int _systemNowMilliseconds() => DateTime.now().toUtc().millisecondsSinceEpoch;
}

/// ULID 的无状态入口（使用进程内共享的单调生成器）。
abstract final class Ulid {
  static final UlidGenerator _generator = UlidGenerator();

  /// 生成下一个 ULID。
  static String next() => _generator.next();

  /// 是否为合法 ULID。
  static bool isValid(String value) => UlidGenerator.isValid(value);

  /// ULID 中编码的 UTC 时间。
  static DateTime timestampOf(String value) => UlidGenerator.timestampOf(value);

  /// ULID 中编码的时间戳（毫秒），非法输入返回 `null`。
  static int? tryMillisecondsOf(String value) => UlidGenerator.tryMillisecondsOf(value);
}

bool _isDecodable(int codeUnit) =>
    codeUnit >= 0 && codeUnit < _decodeTable.length && _decodeTable[codeUnit] >= 0;

/// 字符 → 5 位取值。
///
/// ## 必须查表，不能对 ASCII 做算术
///
/// Crockford 字母表跳过了 I / L / O / U，因此 `'J'` 的取值是 18 而不是 19。
/// 一旦写成 `codeUnit - 0x41 + 10` 这类算术映射，**从 'J' 开始每个字母都会偏大 1**，
/// 到 `'Z'` 时算出 35 —— 已经超出 5 位的可表示范围。
///
/// 后果不是「报错」，而是**静默解码出另一个数**：
/// 版本戳的字典序就是合并算法的全序（见 `pf_io` 的 `resolveRecordVersion`），
/// 编码与解码用了两套不一致的映射，同一个版本戳在两次运行里会解出不同的时间戳，
/// 表现为「多设备同步偶尔丢改动」—— 一个和 ID 看起来毫无关系的故障。
///
/// 所以这里的唯一真相是 [_crockfordAlphabet] 本身：查表保证了
/// 「编码用第 i 个字符」与「解码得 i」永远互为逆运算。
int _valueOf(int codeUnit) {
  if (codeUnit < 0 || codeUnit >= _decodeTable.length) {
    throw FormatException('非法的 ULID 字符（超出可表示范围）', codeUnit);
  }
  final value = _decodeTable[codeUnit];
  if (value < 0) {
    throw FormatException('非法的 ULID 字符: "${String.fromCharCode(codeUnit)}"');
  }
  return value;
}

/// 解码表：码元 → 取值，`-1` 表示非法。
///
/// 小写字母按「字母表中有对应大写」的规则登记，因此 `'j'` 合法而 `'i'` / `'l'` /
/// `'o'` / `'u'` 非法 —— 这一点与 [_isDecodable] 共用同一张表，不再各写一份判断。
final List<int> _decodeTable = _buildDecodeTable();

List<int> _buildDecodeTable() {
  final table = List<int>.filled(0x80, -1);
  for (var value = 0; value < _crockfordAlphabet.length; value++) {
    final upper = _crockfordAlphabet.codeUnitAt(value);
    table[upper] = value;
    if (upper >= 0x41 && upper <= 0x5A) {
      table[upper + 0x20] = value;
    }
  }
  return table;
}

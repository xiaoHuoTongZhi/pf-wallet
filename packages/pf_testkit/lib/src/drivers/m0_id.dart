/// M0 驱动：ULID 编码与解析。
///
/// ULID 在本项目里承担两个职责（主键 + 版本戳），而版本戳的**字典序就是合并算法的全序**。
/// 因此编码规则不是「格式细节」，而是合并正确性的地基：
/// 若某次改动让编码不再单调，表现是「多设备同步偶尔丢改动」——
/// 一个难以复现、且看起来与 ID 毫无关系的故障。
///
/// 所以这里必须有一条向量把「时间戳 + 随机字节 → 26 字符」的映射钉死。
library;

import 'dart:math' as math;

import 'package:pf_core/pf_core.dart';

import '../driver.dart';
import '../json_util.dart';
import '../outcome.dart';

/// 由时间戳与随机字节确定性编码。
final class UlidEncodeDriver extends VectorDriver {
  const UlidEncodeDriver();

  @override
  String get kind => 'id.ulid.encode';

  @override
  String get description => '由毫秒时间戳与 10 字节随机数确定性编码为 26 字符 ULID';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'milliseconds': 'int，48 位毫秒时间戳（0..281474976710655）',
    'randomHex': '20 个十六进制字符（10 字节）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final ulid = UlidGenerator.encode(
      requireInt(input, 'milliseconds', kind),
      requireHexBytes(input, 'randomHex', kind),
    );
    return VectorOutcome.value(<String, Object?>{
      'ulid': ulid,
      'length': ulid.length,
      'valid': UlidGenerator.isValid(ulid),
    });
  }
}

/// 解析回时间戳与随机字节。
final class UlidDecodeDriver extends VectorDriver {
  const UlidDecodeDriver();

  @override
  String get kind => 'id.ulid.decode';

  @override
  String get description => '把 ULID 拆回毫秒时间戳与 10 字节随机数';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{'ulid': '26 字符 ULID'};

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final ulid = requireString(input, 'ulid', kind);
    final decoded = UlidGenerator.decode(ulid);
    return VectorOutcome.value(<String, Object?>{
      'milliseconds': decoded.milliseconds,
      'randomHex': toHex(decoded.random),
      'timestampIso': UlidGenerator.timestampOf(ulid).toIso8601String(),
    });
  }
}

/// 合法性判定。
///
/// 这里刻意覆盖「看起来像但不是」的输入：长度对但含 I/L/O/U、
/// 首字符 > 7（时间戳溢出 48 位）、全角数字。
/// 宽松放过任意一个，都会让「用户手抄 ID 时写错一位」变成一次静默的数据错位。
final class UlidValidateDriver extends VectorDriver {
  const UlidValidateDriver();

  @override
  String get kind => 'id.ulid.validate';

  @override
  String get description => '判定字符串是否为合法 ULID';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{'value': '待判定的字符串'};

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final value = requireString(input, 'value', kind);
    return VectorOutcome.value(<String, Object?>{
      'valid': UlidGenerator.isValid(value),
      'length': value.length,
    });
  }
}

/// 单调性：同毫秒内连续生成必须严格递增。
///
/// 这条向量用**固定随机源**驱动生成器，因此结果是确定的。
/// 它守的是合并算法的全序前提：若同毫秒内的两次生成出现相等或倒退，
/// LWW 会退化成「随机选一个」，而用户看到的现象是「我改的金额变回去了」。
final class UlidMonotonicDriver extends VectorDriver {
  const UlidMonotonicDriver();

  @override
  String get kind => 'id.ulid.monotonic';

  @override
  String get description => '固定时钟与随机源下，连续生成的 ULID 严格递增';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'milliseconds': 'int，生成器始终读到的时钟值',
    'count': 'int，连续生成个数',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final fixed = requireInt(input, 'milliseconds', kind);
    final count = requireInt(input, 'count', kind);
    // 固定种子：math.Random 的序列在同一 Dart 版本内是确定的。
    // 这里只关心「单调」这一性质，不关心具体取值，因此不把序列写进期望里。
    final generator = UlidGenerator(random: _ZeroRandom(), nowMilliseconds: () => fixed);
    final generated = <String>[];
    for (var i = 0; i < count; i++) {
      generated.add(generator.next());
    }

    var strictlyIncreasing = true;
    for (var i = 1; i < generated.length; i++) {
      if (generated[i].compareTo(generated[i - 1]) <= 0) {
        strictlyIncreasing = false;
        break;
      }
    }

    return VectorOutcome.value(<String, Object?>{
      'count': generated.length,
      'strictlyIncreasing': strictlyIncreasing,
      'firstUlid': generated.first,
      'lastUlid': generated.last,
      'allSameTimestampPrefix': generated.map((String u) => u.substring(0, 10)).toSet().length == 1,
    });
  }
}

/// 全零随机源：让「随机部分递增」这条逻辑在**没有随机性干扰**的情况下被检验。
///
/// 若用真随机源，递增路径会被随机字节本身的变化掩盖 ——
/// 序列看起来在涨，但涨的原因可能是随机数恰好更大，
/// 于是 `_incrementRandom` 里的 off-by-one 永远不会被发现。
class _ZeroRandom implements math.Random {
  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;

  @override
  int nextInt(int max) => 0;
}

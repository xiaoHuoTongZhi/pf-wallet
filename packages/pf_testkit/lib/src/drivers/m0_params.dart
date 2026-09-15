/// M0 驱动：Argon2id 参数模型与安全边界。
///
/// 这一组向量守的是**两类完全不同的东西**，必须分开看：
///
///   1. **安全边界**（`kdf.params.bounds`）：`maxMemoryKiB` 之类的上限。
///      导入文件时 KDF 参数来自文件头，也就是来自攻击者可控的输入。
///      一个把 `m` 写成 16 GiB 的文件，会让受害设备在打开它的瞬间 OOM。
///      这类常量属于安全参数，不能在「优化启动速度」的名义下被调小。
///   2. **格式契约**（`kdf.params.roundtrip`）：JSON 字段名与语义。
///      它会被写进导出载荷，改字段名等于让旧备份失去可读性。
library;

import 'package:pf_crypto/pf_crypto.dart';

import '../driver.dart';
import '../outcome.dart';

/// 校验一组参数是否在允许范围内。
final class KdfParamsValidateDriver extends VectorDriver {
  const KdfParamsValidateDriver();

  @override
  String get kind => 'kdf.params.validate';

  @override
  String get description => '按范围约束校验 Argon2id 参数（越界抛 PFB_E_KDF_PARAMS）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'm': 'int，内存开销 KiB',
    't': 'int，迭代次数',
    'p': 'int，并行度',
    'saltLength': 'int，盐长度（可选，缺省 16）',
    'outputLength': 'int，输出长度（可选，缺省 32）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final params = Argon2Params.fromJson(input);
    return VectorOutcome.value(<String, Object?>{
      'valid': true,
      'describe': params.describe(),
      'outputLength': params.outputLength,
      'saltLength': params.saltLength,
    });
  }
}

/// 锁定参数范围常量。
final class KdfParamsBoundsDriver extends VectorDriver {
  const KdfParamsBoundsDriver();

  @override
  String get kind => 'kdf.params.bounds';

  @override
  String get description => '锁定 Argon2id 参数的上下界（安全参数，不得放宽）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{};

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async =>
      VectorOutcome.value(<String, Object?>{
        'minMemoryKiB': Argon2Params.minMemoryKiB,
        'maxMemoryKiB': Argon2Params.maxMemoryKiB,
        'minIterations': Argon2Params.minIterations,
        'maxIterations': Argon2Params.maxIterations,
        'minParallelism': Argon2Params.minParallelism,
        'maxParallelism': Argon2Params.maxParallelism,
        'minSaltLength': Argon2Params.minSaltLength,
        'maxSaltLength': Argon2Params.maxSaltLength,
        'defaultSaltLength': Argon2Params.defaultSaltLength,
        'defaultOutputLength': Argon2Params.defaultOutputLength,
      });
}

/// 锁定三套预设参数。
///
/// 预设是**产品决策的载体**：移动端 m=64MiB、桌面端 m=256MiB、
/// 导出统一用移动端参数（保证低端设备能在 1 秒内解开）。
/// 把预设写进向量，是为了让「顺手把移动端也调到 256MiB」这类改动
/// 必须显式改向量 —— 那一刻改动者会被迫面对「低端机会不会卡死」这个问题。
final class KdfParamsPresetsDriver extends VectorDriver {
  const KdfParamsPresetsDriver();

  @override
  String get kind => 'kdf.params.presets';

  @override
  String get description => '锁定移动端 / 桌面端 / 导出三套预设参数';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{};

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async =>
      VectorOutcome.value(<String, Object?>{
        'mobile': Argon2Params.mobileDefault.describe(),
        'desktop': Argon2Params.desktopDefault.describe(),
        'export': Argon2Params.exportDefault.describe(),
        'mobileMemoryKiB': Argon2Params.mobileDefault.memoryKiB,
        'desktopMemoryKiB': Argon2Params.desktopDefault.memoryKiB,
        // 导出与移动端必须是同一套参数 —— 这是「备份能被任何设备打开」的前提
        'exportEqualsMobile': Argon2Params.exportDefault == Argon2Params.mobileDefault,
      });
}

/// JSON 往返。
final class KdfParamsRoundtripDriver extends VectorDriver {
  const KdfParamsRoundtripDriver();

  @override
  String get kind => 'kdf.params.roundtrip';

  @override
  String get description => 'Argon2Params 的 JSON 序列化与反序列化往返一致';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M0';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'm': 'int',
    't': 'int',
    'p': 'int',
    'saltLength': 'int（可选）',
    'outputLength': 'int（可选）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final original = Argon2Params.fromJson(input);
    final restored = Argon2Params.fromJson(original.toJson());
    return VectorOutcome.value(<String, Object?>{
      'json': _sorted(original.toJson()),
      'roundtripEqual': restored == original,
      'describe': restored.describe(),
    });
  }
}

Map<String, Object?> _sorted(Map<String, Object?> json) {
  final keys = json.keys.toList()..sort();
  return <String, Object?>{for (final k in keys) k: json[k]};
}

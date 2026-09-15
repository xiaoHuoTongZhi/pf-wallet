/// Argon2id 参数与校验。
///
/// ## 参数怎么选的
///
/// RFC 9106 的「第二推荐」是 m=64 MiB, t=3, p=4。
/// 本项目采用 **p=1**，理由：
///   - 内存硬度由 m 决定（攻击者的并行成本来自内存带宽），p 主要影响
///     单次派生的墙钟时间在多少核上摊开。
///   - 手机端 p=4 会把 4 个核同时打满约 0.5～1 秒。结果是发热、降频，
///     并且在后台上被系统限流时耗时不可预测 —— 用户体验的代价换来的是
///     几乎为零的安全增益。
///   - p 会被完整写入文件头，因此桌面端用 p=4 导出的文件，手机端照样能打开。
///
/// 移动端 m=64 MiB、桌面端 m=256 MiB：桌面设备的可用内存更宽裕，
/// 而攻击者用 GPU/ASIC 爆破时，内存是唯一真正昂贵的维度。
library;

import 'package:pf_core/pf_core.dart';

/// Argon2id 派生参数。
final class Argon2Params {
  const Argon2Params({
    required this.memoryKiB,
    required this.iterations,
    required this.parallelism,
    this.saltLength = defaultSaltLength,
    this.outputLength = defaultOutputLength,
  });

  /// 移动端默认：64 MiB / t=3 / p=1。
  static const Argon2Params mobileDefault = Argon2Params(
    memoryKiB: 65536,
    iterations: 3,
    parallelism: 1,
  );

  /// 桌面端默认：256 MiB / t=3 / p=4。
  static const Argon2Params desktopDefault = Argon2Params(
    memoryKiB: 262144,
    iterations: 3,
    parallelism: 4,
  );

  /// 导出文件默认：与移动端一致，保证低端设备也能在 1 秒内解开。
  static const Argon2Params exportDefault = mobileDefault;

  static const int defaultSaltLength = 16;
  static const int defaultOutputLength = 32;

  /// 盐长度下限（8 字节是 Argon2 规范要求的最小值）。
  static const int minSaltLength = 8;

  /// 盐长度上限。
  static const int maxSaltLength = 64;

  /// 内存下限：OWASP 对 Argon2id 的建议下限 19 MiB。
  static const int minMemoryKiB = 19456;

  /// 内存上限：1 GiB。
  ///
  /// 这个上限是**安全参数**而非性能参数。
  /// 导入文件时，KDF 参数来自文件头 —— 一个精心构造的文件可以把
  /// `memoryKiB` 写成 16777216（16 GiB），让受害设备在打开它的瞬间
  /// 触发 OOM 崩溃或长时间无响应。因此上线必须在解析文件头时就卡死。
  static const int maxMemoryKiB = 1048576;

  static const int minIterations = 2;
  static const int maxIterations = 16;

  static const int minParallelism = 1;
  static const int maxParallelism = 8;

  /// 内存开销，单位 KiB。
  final int memoryKiB;

  /// 迭代次数 t。
  final int iterations;

  /// 并行度 p。
  final int parallelism;

  /// 盐长度（字节）。
  final int saltLength;

  /// 输出密钥长度（字节）。32 字节 = 256 位。
  final int outputLength;

  /// 校验参数是否在允许范围内。越界抛 [CryptoError.kdfParamsOutOfRange]。
  void validate() {
    if (memoryKiB < minMemoryKiB || memoryKiB > maxMemoryKiB) {
      throw CryptoError.kdfParamsOutOfRange(
        detail: 'memoryKiB=$memoryKiB 不在 $minMemoryKiB..$maxMemoryKiB 范围内',
      );
    }
    if (iterations < minIterations || iterations > maxIterations) {
      throw CryptoError.kdfParamsOutOfRange(
        detail: 'iterations=$iterations 不在 $minIterations..$maxIterations 范围内',
      );
    }
    if (parallelism < minParallelism || parallelism > maxParallelism) {
      throw CryptoError.kdfParamsOutOfRange(
        detail: 'parallelism=$parallelism 不在 $minParallelism..$maxParallelism 范围内',
      );
    }
    if (saltLength < minSaltLength || saltLength > maxSaltLength) {
      throw CryptoError.kdfParamsOutOfRange(
        detail: 'saltLength=$saltLength 不在 $minSaltLength..$maxSaltLength 范围内',
      );
    }
    if (outputLength != 32) {
      throw CryptoError.kdfParamsOutOfRange(detail: 'outputLength=$outputLength，本项目固定为 32');
    }
    // Argon2 规范要求 m >= 8 * p
    if (memoryKiB < 8 * parallelism) {
      throw CryptoError.kdfParamsOutOfRange(
        detail: 'memoryKiB=$memoryKiB 小于 8 * parallelism=${8 * parallelism}',
      );
    }
  }

  /// 参数是否在允许范围内。
  bool get isValid {
    try {
      validate();
      return true;
    } on CryptoError {
      return false;
    }
  }

  Argon2Params copyWith({
    int? memoryKiB,
    int? iterations,
    int? parallelism,
    int? saltLength,
    int? outputLength,
  }) => Argon2Params(
    memoryKiB: memoryKiB ?? this.memoryKiB,
    iterations: iterations ?? this.iterations,
    parallelism: parallelism ?? this.parallelism,
    saltLength: saltLength ?? this.saltLength,
    outputLength: outputLength ?? this.outputLength,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'm': memoryKiB,
    't': iterations,
    'p': parallelism,
    'saltLength': saltLength,
    'outputLength': outputLength,
  };

  /// 反序列化。**立即校验**，因为该输入通常来自文件头或导入载荷，属于不可信数据。
  static Argon2Params fromJson(Map<String, Object?> json) {
    final m = json['m'];
    final t = json['t'];
    final p = json['p'];
    if (m is! int || t is! int || p is! int) {
      throw DomainError.validation(detail: 'Argon2Params JSON 缺少 m/t/p 或类型不正确: $json');
    }
    final saltLength = json['saltLength'];
    final outputLength = json['outputLength'];
    final params = Argon2Params(
      memoryKiB: m,
      iterations: t,
      parallelism: p,
      saltLength: saltLength is int ? saltLength : defaultSaltLength,
      outputLength: outputLength is int ? outputLength : defaultOutputLength,
    );
    params.validate();
    return params;
  }

  /// 人类可读描述，用于设置页展示与日志。
  String describe() => 'm=${memoryKiB ~/ 1024}MiB t=$iterations p=$parallelism';

  @override
  bool operator ==(Object other) =>
      other is Argon2Params &&
      other.memoryKiB == memoryKiB &&
      other.iterations == iterations &&
      other.parallelism == parallelism &&
      other.saltLength == saltLength &&
      other.outputLength == outputLength;

  @override
  int get hashCode => Object.hash(memoryKiB, iterations, parallelism, saltLength, outputLength);

  @override
  String toString() => 'Argon2Params(${describe()})';
}

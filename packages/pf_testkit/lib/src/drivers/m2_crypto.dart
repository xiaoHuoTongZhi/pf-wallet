/// M2 驱动占位：需要原生加密库的部分。
///
/// ## 为什么「未实现」的驱动也要写出来
///
/// 因为向量必须先于实现存在。原因有两条，都是工程性的：
///
///   1. **向量是对外契约，实现是内部细节。** 先写向量，等于先决定
///      「这个函数对外承诺什么」；反过来（先写实现再补测试）通常只是
///      把实现的偶然行为抄一遍，锁不住任何东西。
///   2. **它把「还没做」变成可见的数字。** 报告里 pending 的条数是
///      对进度的诚实度量，而基线机制（见 baseline.dart）保证它只能减少。
///
/// 这些驱动目前 `isImplemented = false`，runner 会把它们的用例记为 pending。
/// 到 M2 时只需把标志翻成 true 并把 `run` 填上 —— 向量一行都不用改。
library;

import '../driver.dart';
import '../outcome.dart';

/// 未实现驱动的公共实现：声明契约，但拒绝假装能跑。
abstract class _PendingDriver extends VectorDriver {
  const _PendingDriver();

  @override
  bool get isImplemented => false;

  @override
  String get plannedMilestone => 'M2';

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async => VectorOutcome.pending(
    message:
        '$kind 的实现尚未落地。'
        '若这条消息出现在 M2 之后，说明有人把 isImplemented 打开了却没写实现 —— '
        '这正是 pending 基线机制要拦住的情况。',
  );
}

/// Argon2id 派生。
final class KdfArgon2idDeriveDriver extends _PendingDriver {
  const KdfArgon2idDeriveDriver();

  @override
  String get kind => 'kdf.argon2id.derive';

  @override
  String get description => 'Argon2id 派生密钥（密码 + 盐 + 参数 → 32 字节）';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'passwordUtf8Hex': '密码的 UTF-8 字节（十六进制）',
    'saltHex': '盐（十六进制）',
    'params': '{m, t, p, saltLength, outputLength}',
  };
}

/// AES-256-GCM 封装（加密 + 认证）。
final class AeadSealDriver extends _PendingDriver {
  const AeadSealDriver();

  @override
  String get kind => 'aead.aes256gcm.seal';

  @override
  String get description => 'AES-256-GCM 封装，产出密文与 16 字节认证标签';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'keyHex': '32 字节密钥',
    'nonceHex': '12 字节 nonce',
    'plaintextHex': '明文',
    'aadHex': '附加认证数据（可为空）',
  };
}

/// AES-256-GCM 解封。
///
/// 单独成一条 kind 而不是与 seal 合并，是因为**失败路径才是这里的重点**：
/// 「标签被改一个字节必须抛 PFB_E_AUTH_FAILED」比「正常加解密能往返」
/// 重要得多。合并成一个 kind 会让失败路径只能靠一个布尔开关来测。
final class AeadOpenDriver extends _PendingDriver {
  const AeadOpenDriver();

  @override
  String get kind => 'aead.aes256gcm.open';

  @override
  String get description => 'AES-256-GCM 解封并验签，失败抛 PFB_E_AUTH_FAILED';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'keyHex': '32 字节密钥',
    'nonceHex': '12 字节 nonce',
    'ciphertextHex': '密文',
    'tagHex': '16 字节认证标签',
    'aadHex': '附加认证数据（可为空）',
  };
}

/// 密钥环：用 KEK 包裹 DEK。
final class KeyringWrapDriver extends _PendingDriver {
  const KeyringWrapDriver();

  @override
  String get kind => 'keyring.wrap-dek';

  @override
  String get description => '用主密码派生的 KEK 包裹数据密钥 DEK（改密码只需重包，无需重加密数据库）';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'kekHex': '32 字节 KEK',
    'dekHex': '32 字节 DEK',
    'deviceIdHex': '16 字节设备 ID',
    'params': '{m, t, p, saltLength, outputLength}',
  };
}

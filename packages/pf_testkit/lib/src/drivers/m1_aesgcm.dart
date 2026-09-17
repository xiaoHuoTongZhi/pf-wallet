/// M1 驱动：AES-256-GCM 认证加密。
///
/// ## 为什么要两组（seal / open）而不是一个
///
/// 失败路径才是这里的重点：「标签被改一个字节必须抛 PFB_E_AUTH_FAILED」
/// 比「正常加解密能往返」重要得多。合并成一个 kind 会让失败路径只能靠
/// 一个布尔开关来测，于是「认证失败」这种最该守住的行为会退化成
/// 「没崩就算过」。所以 seal 与 open 分开，open 再单独扛三类失败
/// （标签篡改 / 密文篡改 / AAD 不符）。
///
/// ## 期望值从哪来
///
/// 不来自本仓实现。它们来自 `tools/golden_vectors_gen/aes256gcm.py`，
/// 用 Python 的 `cryptography`（并以 NIST GCMVS AES-256 Count=0 锚定、
/// 可选 pycryptodome 交叉核对）。seal 与 open 共享同一套密钥/nonce/明文，
/// open 的成功用例直接复用 seal 算出的密文与标签 —— 所以「能往返」和
/// 「与独立实现一致」是同一组数字的两面。
library;

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';

import '../driver.dart';
import '../json_util.dart';
import '../outcome.dart';

/// 默认使用的实装。驱动引用具体类型，因为 `sealDetached`（分离标签）是
/// [Aes256Gcm] 的公开方法，抽象 [Aead] 契约只承诺 [Aead.seal] / [Aead.open]
/// （见 `aead.dart` 注释：分开发送的调用方应使用具体实现的 `sealDetached`）。
const Aes256Gcm _defaultAead = Aes256Gcm.instance;

/// AES-256-GCM 封装（加密 + 认证）。
final class AeadSealDriver extends VectorDriver {
  const AeadSealDriver();

  @override
  String get kind => 'aead.aes256gcm.seal';

  @override
  String get description => 'AES-256-GCM 封装，产出密文与 16 字节认证标签';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'keyHex': '32 字节密钥',
    'nonceHex': 'nonce（12 字节为主路径，也含 8 / 16 字节边界）',
    'plaintextHex': '明文',
    'aadHex': '附加认证数据（可为空）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final detached = await _defaultAead.sealDetached(
      key: requireHexBytes(input, 'keyHex', kind),
      nonce: requireHexBytes(input, 'nonceHex', kind),
      plaintext: requireHexBytes(input, 'plaintextHex', kind),
      aad: requireHexBytes(input, 'aadHex', kind),
    );
    return VectorOutcome.value(<String, Object?>{
      'ciphertextHex': toHex(detached.ciphertext),
      'tagHex': toHex(detached.tag),
    });
  }
}

/// AES-256-GCM 解封并验签，失败抛 PFB_E_AUTH_FAILED。
final class AeadOpenDriver extends VectorDriver {
  const AeadOpenDriver();

  @override
  String get kind => 'aead.aes256gcm.open';

  @override
  String get description => 'AES-256-GCM 解封并验签；标签 / 密文 / AAD 任一不符均抛 PFB_E_AUTH_FAILED';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'keyHex': '32 字节密钥',
    'nonceHex': 'nonce（与封装时一致）',
    'ciphertextHex': '密文',
    'tagHex': '16 字节认证标签',
    'aadHex': '附加认证数据（可为空，必须与封装时一致）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    // 成功用例：返回明文。失败用例（标签 / 密文 / AAD 被改）：实装抛
    // ContainerError.authFailed，runner 会捕获并对照 expect.ok=false。
    final plaintext = await _defaultAead.open(
      key: requireHexBytes(input, 'keyHex', kind),
      nonce: requireHexBytes(input, 'nonceHex', kind),
      ciphertext: requireHexBytes(input, 'ciphertextHex', kind),
      tag: requireHexBytes(input, 'tagHex', kind),
      aad: requireHexBytes(input, 'aadHex', kind),
    );
    return VectorOutcome.value(<String, Object?>{'plaintextHex': toHex(plaintext)});
  }
}

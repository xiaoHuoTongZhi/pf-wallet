/// AES-256-GCM 实装（M1 原语层）。
///
/// ## 算法从哪来
///
/// 方案 §1.5 钉死：AES-256-GCM 走纯 Dart 的 `package:cryptography`。
/// 不手写分组密码，也不走 libsodium 的 `crypto_aead_aes256gcm` ——
/// 后者在 ARM 没有 AES 指令时 `is_available()` 返回 false，不能作唯一实现；
/// 纯 Dart 实装能在 6 个平台得到同一份行为，CI 也跑得起来。
///
/// ## 与 NIST SP 800-38D 的一致性点
///
///   - key = 32 字节，nonce = 12 字节（GCM 推荐长度，J0 直接取 nonce），
///     tag = 16 字节（全 128 位，不截断）。
///   - 计数器从固定值起、每 16 字节明文块递增 1 —— 这些都是 GCM 标准，
///     由 `package:cryptography` 保证，本文件只负责「调它」与「守输入输出契约」。
///   - AAD 走 GHASH 但不进密文；它只影响标签。向量里有「AAD 不符」一组，
///     专守「改一个 AAD 字节必须认证失败」。
///
/// ## 错误分支（必须各自独立、可被单测命中）
///
///   - key 长度 ≠ 32 → [ContainerError.headerInvalid]（输入契约破坏，不是认证问题）。
///   - tag 长度 ≠ 16 → [ContainerError.headerInvalid]。
///   - 认证失败（标签错 / 密文被改 / AAD 被改 / 密文短于标签导致无法凑出合法标签）
///     → [ContainerError.authFailed]，错误码 `PFB_E_AUTH_FAILED`。
///     这是「密码错」与「文件损坏」之间唯一的分流点，码必须稳定。
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pf_core/pf_core.dart';

import 'aead.dart';

/// AES-256-GCM 实装。
///
/// 单例 [instance] 供驱动与上层引用；实现本身无状态。
final class Aes256Gcm implements Aead {
  const Aes256Gcm();

  /// 默认实例。
  static const Aes256Gcm instance = Aes256Gcm();

  /// 密钥长度（字节）。
  static const int keyLengthBytes = 32;

  /// 标签长度（字节）。
  static const int tagLengthBytes = 16;

  /// 本项目主用 nonce 长度（字节）。
  static const int defaultNonceLength = 12;

  @override
  String get algorithm => 'AES-256-GCM';

  @override
  int get keyLength => keyLengthBytes;

  @override
  int get nonceLength => defaultNonceLength;

  @override
  int get tagLength => tagLengthBytes;

  @override
  Future<Uint8List> seal({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List plaintext,
    required Uint8List aad,
  }) async {
    final detached = await sealDetached(key: key, nonce: nonce, plaintext: plaintext, aad: aad);
    return detached.ciphertext;
  }

  /// 加密并认证，返回分离的密文与标签。
  ///
  /// 向量驱动与容器格式需要「密文 + 标签」分开，所以用这个方法而不是 [seal]。
  /// 两者底层完全相同，没有第二套逻辑。
  Future<({Uint8List ciphertext, Uint8List tag})> sealDetached({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List plaintext,
    required Uint8List aad,
  }) async {
    _checkKey(key);
    _checkNonce(nonce);
    final cipher = AesGcm.with256bits(nonceLength: nonce.length);
    final box = await cipher.encrypt(plaintext, secretKey: SecretKey(key), nonce: nonce, aad: aad);
    return (ciphertext: Uint8List.fromList(box.cipherText), tag: Uint8List.fromList(box.mac.bytes));
  }

  @override
  Future<Uint8List> open({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List ciphertext,
    required Uint8List tag,
    required Uint8List aad,
  }) async {
    _checkKey(key);
    _checkNonce(nonce);
    if (tag.length != tagLengthBytes) {
      throw ContainerError.headerInvalid(
        detail: 'AES-256-GCM 标签必须为 $tagLengthBytes 字节，实际 ${tag.length} 字节',
      );
    }
    final cipher = AesGcm.with256bits(nonceLength: nonce.length);
    final secretBox = SecretBox(ciphertext, nonce: nonce, mac: Mac(tag));
    try {
      final clear = await cipher.decrypt(secretBox, secretKey: SecretKey(key), aad: aad);
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      // 标签错 / 密文被改 / AAD 被改 / 密文太短凑不出合法标签 —— 都走这一条。
      throw ContainerError.authFailed();
    }
  }

  void _checkKey(Uint8List key) {
    if (key.length != keyLengthBytes) {
      throw ContainerError.headerInvalid(
        detail: 'AES-256 密钥必须为 $keyLengthBytes 字节，实际 ${key.length} 字节',
      );
    }
  }

  void _checkNonce(Uint8List nonce) {
    if (nonce.isEmpty) {
      throw ContainerError.headerInvalid(detail: 'nonce 不得为空');
    }
  }
}

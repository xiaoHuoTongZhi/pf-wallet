/// 认证加密契约。
library;

import 'dart:typed_data';

/// AEAD（带关联数据的认证加密）。
///
/// 本项目固定使用 AES-256-GCM：
///   key = 32 字节，nonce = 12 字节，tag = 16 字节。
///
/// ## nonce 复用的后果，必须写清楚
///
/// 同一个密钥下重复使用同一个 nonce，会让攻击者能恢复出明文的异或值
/// （GCM 的计数器流复用）。这不是「降低安全性」，而是**直接泄漏明文**。
///
/// 本项目对 nonce 的处理规则：
///   - 数据库密钥（DEK）由 SQLCipher 自己管理 nonce，我们不碰。
///   - 导出容器的 nonce 每次导出用 CSPRNG 重新生成 12 字节并写入文件头。
///     在 2^32 次导出内碰撞概率约 2^-33，对个人记账应用完全足够；
///     若将来出现自动增量导出，必须改为计数器 nonce。
///   - 保险箱包裹块每次改写都重新生成 nonce。
abstract interface class Aead {
  /// 算法标识，用于诊断。
  String get algorithm;

  /// 密钥长度（字节）。
  int get keyLength;

  /// nonce 长度（字节）。
  int get nonceLength;

  /// 认证标签长度（字节）。
  int get tagLength;

  /// 加密并认证。返回密文（与明文等长），标签单独返回。
  Uint8List seal({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List plaintext,
    required Uint8List aad,
  });

  /// 解密并验证。
  ///
  /// 认证失败时抛 [ContainerError.authFailed]（错误码 `PFB_E_AUTH_FAILED`）。
  /// **不允许**实现返回 null 或空数组来表示失败 —— 调用方必须处理异常，
  /// 因为「认证失败」和「解密出空数据」是完全不同的事。
  Uint8List open({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List ciphertext,
    required Uint8List tag,
    required Uint8List aad,
  });
}

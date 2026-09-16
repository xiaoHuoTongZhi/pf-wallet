/// PF Wallet 加密层。
///
/// ## 交付边界（说清楚，避免有人以为这里已经能加密了）
///
/// M0 已交付（纯字节运算，不含任何算法）：
///   - [Argon2Params]：参数模型、范围约束、JSON 往返
///   - [PfbFormat] / [PfbHeader] / [PfbTrailer] / [PfbLayout]：容器二进制格式
///   - [KeyDeriver] / [Aead] / [Keyring] / [KeyringStore]：契约
///
/// M1 交付（**原语层**，按 §7.6 的顺序推进）：
///   - [Digest] / [Sha256]：摘要原语（已落地）
///   - HKDF-SHA256、AES-256-GCM、Argon2id：契约的实装
///   - **不含**容器编解码器（编排 KDF → AEAD → 摘要 → 原子写盘）
///     与 [Keyring] 实装（对接 flutter_secure_storage）—— 那是 M1 后续与 M2 的事
///
/// ## 算法从哪来
///
/// 方案 §1.5 钉死了来源，本仓不手写密码学原语：
///   - SHA-256     → `package:crypto`
///   - HKDF-SHA256 / AES-256-GCM → `package:cryptography`（纯 Dart，6 端行为一致）
///   - Argon2id    → `package:sodium`（libsodium FFI）
///
/// 注：M0 的注释曾写「AES-256-GCM 走 libsodium 的 `crypto_aead_aes256gcm` 或平台 crypto」，
/// 与 §1.5 的 `cryptography` 不一致。以 §1.5 为准 —— 纯 Dart 实现能进 CI
/// （libsodium 走 FFI，需要在每个 runner 上额外准备原生库，见 §7.6 的顺序说明）。
///
/// ## 为什么先做格式、后做算法
///
/// 格式一旦发布就改不动了（用户已经导出的备份文件必须能被将来任何版本打开），
/// 而算法实现可以随时替换。把不可逆的东西先钉死、可逆的东西后补，是正确的顺序。
library;

export 'src/aead.dart';
export 'src/argon2_params.dart';
export 'src/byte_order.dart';
export 'src/container_format.dart';
export 'src/digest.dart';
export 'src/kdf.dart';
export 'src/keyring.dart';

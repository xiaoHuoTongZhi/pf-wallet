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
///   - [KeyExpander] / [HkdfSha256]：密钥扩展原语（已落地）
///   - [Aes256Gcm]：AES-256-GCM 实装（已落地）
///   - [Argon2idDeriver]：Argon2id 实装（已落地）
///   - **不含**容器编解码器（编排 KDF → AEAD → 摘要 → 原子写盘）
///     与 [Keyring] 实装（对接 flutter_secure_storage）—— 那是 M1 后续与 M2 的事
///
/// ## 算法从哪来
///
/// 方案 §1.5 钉死了来源，本仓不手写密码学原语：
///   - SHA-256     → `package:crypto`
///   - HKDF-SHA256 → 建在 `package:crypto` 的 HMAC-SHA256 之上（见 [HkdfSha256] 的文件注释：
///                   RFC 5869 是两行 HMAC 的构造，不是原语；且 `cryptography` 没有只做
///                   extract 的公开入口，用它反而要自己调 HMAC）
///   - AES-256-GCM → `package:cryptography`（纯 Dart，6 端行为一致；`package:crypto`
///                   不含任何分组密码，所以在这一步引入它无可替代）
///   - Argon2id    → `package:cryptography` 里的 `DartArgon2id`（纯 Dart，RFC 9106）
///
/// 注：M0 的注释曾写「Argon2id 走 libsodium / sodium」，与 §1.5 的纯 Dart 优先
/// 不一致。已改为 `DartArgon2id` —— sodium 是 Flutter 插件、需原生二进制与
/// `SodiumInit.init()`，无法在纯 Dart 的 `dart test` CI 上跑，也违背 §1.5。
/// 若某平台不可用，Plan B 是同样纯 Dart 的 `hashlib`（无原生依赖）。
///
/// ## 为什么先做格式、后做算法
///
/// 格式一旦发布就改不动了（用户已经导出的备份文件必须能被将来任何版本打开），
/// 而算法实现可以随时替换。把不可逆的东西先钉死、可逆的东西后补，是正确的顺序。
library;

export 'src/aead.dart';
export 'src/aesgcm.dart';
export 'src/argon2_params.dart';
export 'src/argon2id.dart';
export 'src/byte_order.dart';
export 'src/container_format.dart';
export 'src/digest.dart';
export 'src/hkdf.dart';
export 'src/kdf.dart';
export 'src/keyring.dart';

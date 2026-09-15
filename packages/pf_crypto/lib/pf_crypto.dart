/// PF Wallet 加密层。
///
/// ## M0 与 M2 的边界（说清楚，避免有人以为这里已经能加密了）
///
/// M0 已交付（纯字节运算，无需任何原生库，可离线验证）：
///   - [Argon2Params]：参数模型、范围约束、JSON 往返
///   - [PfbFormat] / [PfbHeader] / [PfbTrailer] / [PfbLayout]：容器二进制格式
///   - [KeyDeriver] / [Aead] / [Keyring] / [KeyringStore]：契约
///
/// M2 交付（需要原生库）：
///   - Argon2id 实现（libsodium 或 argon2 绑定）
///   - AES-256-GCM 实现（libsodium 的 `crypto_aead_aes256gcm` 或平台 crypto）
///   - 容器编解码器（编排 KDF → AEAD → 摘要 → 原子写盘）
///   - Keyring 实现（对接 flutter_secure_storage）
///
/// 之所以先做格式后做算法：格式一旦发布就改不动了（用户已经导出的备份文件
/// 必须能被将来任何版本打开），而算法实现可以随时替换。
/// 把不可逆的东西先钉死、可逆的东西后补，是正确的顺序。
library;

export 'src/aead.dart';
export 'src/argon2_params.dart';
export 'src/byte_order.dart';
export 'src/container_format.dart';
export 'src/kdf.dart';
export 'src/keyring.dart';

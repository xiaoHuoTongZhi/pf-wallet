/// 密钥层级与保险箱契约。
///
/// ## 两层密钥，两条互相独立的派生路径
///
/// ```
///                     主密码 ──UTF-8────┐
///                                       │  Argon2id(主密码盐, 主参数)
///                                       ▼
///                                      KEK（32 字节，仅内存）
///                                       │  AES-256-GCM 解开包裹块
///                                       ▼
///                                      DEK（32 字节数据库密钥）
///                                       │
///                                       └──▶ SQLCipher PRAGMA key
///
///   导出密码 ──UTF-8──▶ Argon2id(文件盐, 文件头参数) ──▶ 导出密钥 ──▶ AES-256-GCM 保护 .pfb
///   （与上面的链路完全无关，没有任何共享输入）
/// ```
///
/// ### 为什么导出密钥不走「主密钥 → 导出密钥」
///
/// 原始需求描述的是线性链路。但那条链路在数学上不成立：
/// **接收方设备没有你的主密钥**，所以它无法从主密钥推导出任何东西。
/// 若导出密钥由主密钥派生，那么跨设备导入就要求接收方先拿到主密钥 ——
/// 这既破坏了「导出密码可与主密码不同」，也让「把备份交给未来的自己」变得危险。
///
/// 因此导出密钥独立派生：导出密码 + 文件盐 + 文件头里的 Argon2id 参数。
/// 好处是接收方只需要文件和三样公开信息即可重放派生。
///
/// ### 顺带的好处：改主密码不需要重新加密数据库
///
/// DEK 不变，只需用新的 KEK 重新包裹一次包裹块（几十字节的写入）。
/// 若采用「主密码直接派生数据库密钥」的方案，改密码就得整库重加密 ——
/// 对一个可能在手机上存了几万条记录的应用来说，那是一个必须弹出进度条、
/// 中途断电就会损坏数据的操作。
///
/// ## 刻意不存「密码校验哈希」
///
/// 很多实现会额外存一个 `PBKDF2(password)` 用来判断密码对不对。
/// 本项目不这么做，因为那会引入第二个离线爆破目标，而且它通常用的参数
/// 比主 KDF 弱得多 —— 攻击者会去打那个较弱的。
///
/// 正确做法是：**包裹块本身就是校验器**。KEK 能否解开 DEK 的 AES-GCM 标签，
/// 就是密码是否正确的唯一判据。没有多余的哈希，就没有多余的攻击面。
library;

import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';

import 'argon2_params.dart';

/// 保险箱数据格式版本。
const int keyringFormatVersion = 1;

/// 被包裹的核心密钥。
///
/// 「包裹」= 用从密码派生的 KEK 对 DEK 做 AES-256-GCM 加密。
/// 解不开标签就意味着密码错（在文件完整性无问题的前提下）。
final class WrappedKey {
  WrappedKey({
    required this.params,
    required Uint8List salt,
    required Uint8List nonce,
    required Uint8List ciphertext,
    required Uint8List tag,
  }) : salt = Uint8List.fromList(salt),
       nonce = Uint8List.fromList(nonce),
       ciphertext = Uint8List.fromList(ciphertext),
       tag = Uint8List.fromList(tag) {
    params.validate();
    if (this.ciphertext.length != dekLength) {
      throw KeyringError.tampered();
    }
  }

  /// DEK 长度（32 字节 = 256 位，AES-256）。
  static const int dekLength = 32;

  /// 每次重新包裹都必须换新盐（防止相同密码在多设备间产生相同 KEK）。
  final Argon2Params params;

  final Uint8List salt;
  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List tag;

  Map<String, Object?> toJson() => <String, Object?>{
    'params': params.toJson(),
    'salt': toHex(salt),
    'nonce': toHex(nonce),
    'ciphertext': toHex(ciphertext),
    'tag': toHex(tag),
  };

  static WrappedKey fromJson(Map<String, Object?> json) {
    final params = json['params'];
    final salt = json['salt'];
    final nonce = json['nonce'];
    final ciphertext = json['ciphertext'];
    final tag = json['tag'];
    if (params is! Map ||
        salt is! String ||
        nonce is! String ||
        ciphertext is! String ||
        tag is! String) {
      throw KeyringError.tampered();
    }
    return WrappedKey(
      params: Argon2Params.fromJson(params.cast<String, Object?>()),
      salt: fromHex(salt),
      nonce: fromHex(nonce),
      ciphertext: fromHex(ciphertext),
      tag: fromHex(tag),
    );
  }

  @override
  String toString() =>
      'WrappedKey(${params.describe()}, salt=${salt.length}B, ciphertext=${ciphertext.length}B)';
}

/// 保险箱内容：两条互相独立的包裹记录。
///
/// 恢复码包裹块与主密码包裹块包裹的是**同一个 DEK**，
/// 因此两者可以独立地解开，也可以独立地作废。
final class KeyringData {
  const KeyringData({
    required this.version,
    required this.primary,
    required this.recovery,
    required this.createdAtMilliseconds,
    required this.updatedAtMilliseconds,
  });

  /// 恢复码的总字符数（含分隔符）。
  static const int recoveryCodeLength = 26;

  /// 恢复码的熵来源长度（字节）。
  static const int recoveryCodeEntropyBytes = 16;

  final int version;

  /// 主密码包裹块。
  final WrappedKey primary;

  /// 恢复码包裹块。用户未保存恢复码时允许为 null。
  final WrappedKey? recovery;

  final int createdAtMilliseconds;
  final int updatedAtMilliseconds;

  DateTime get createdAt => DateTime.fromMillisecondsSinceEpoch(createdAtMilliseconds, isUtc: true);

  DateTime get updatedAt => DateTime.fromMillisecondsSinceEpoch(updatedAtMilliseconds, isUtc: true);

  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'primary': primary.toJson(),
    'recovery': recovery?.toJson(),
    'createdAt': createdAtMilliseconds,
    'updatedAt': updatedAtMilliseconds,
  };

  static KeyringData fromJson(Map<String, Object?> json) {
    final version = json['version'];
    final primary = json['primary'];
    final createdAt = json['createdAt'];
    final updatedAt = json['updatedAt'];
    if (version is! int || primary is! Map || createdAt is! int || updatedAt is! int) {
      throw KeyringError.tampered();
    }
    if (version > keyringFormatVersion) {
      throw StorageError.schemaTooNew(found: version, supported: keyringFormatVersion);
    }
    final recovery = json['recovery'];
    return KeyringData(
      version: version,
      primary: WrappedKey.fromJson(primary.cast<String, Object?>()),
      recovery: recovery is Map ? WrappedKey.fromJson(recovery.cast<String, Object?>()) : null,
      createdAtMilliseconds: createdAt,
      updatedAtMilliseconds: updatedAt,
    );
  }
}

/// 保险箱持久化。
///
/// 实现必须把数据写入 iOS Keychain / Android Keystore，
/// **绝不能**落到明文文件或 shared_preferences。
abstract interface class KeyringStore {
  /// 读取保险箱。首次启动返回 null。
  Future<KeyringData?> read();

  /// 写入（覆盖）保险箱。
  Future<void> write(KeyringData data);

  /// 删除保险箱（「清除全部数据」时使用）。
  Future<void> delete();

  /// 生物识别包裹块是否已登记。
  Future<bool> hasBiometricWrappedKey();

  /// 读取生物识别包裹块。
  ///
  /// 实现必须让该读取**接受系统生物识别的门控**：
  ///   - iOS：Keychain 条目的 `kSecAccessControlBiometryCurrentSet`
  ///   - Android：Keystore 密钥的 `setUserAuthenticationRequired(true)`
  ///
  /// 仅靠 UI 层弹出识别框是无效的 —— 那只能拦住用户，拦不住代码。
  Future<Uint8List?> readBiometricWrappedKey();

  /// 写入生物识别包裹块。
  Future<void> writeBiometricWrappedKey(Uint8List wrappedDek);

  /// 删除生物识别包裹块（修改主密码、关闭生物解锁时使用）。
  Future<void> deleteBiometricWrappedKey();
}

/// 密钥保险箱。
abstract interface class Keyring {
  /// DEK 是否已在内存中。
  bool get isUnlocked;

  /// 首次初始化：生成 DEK，用主密码包裹，并返回可展示给用户的恢复码。
  ///
  /// 返回的恢复码必须以字符串形式返回给 UI 展示，**此后立即从内存中丢弃**。
  Future<String> initialize({required Uint8List password, required Argon2Params params});

  /// 用主密码解锁，返回 DEK。
  ///
  /// 密码错时抛 [KeyringError.wrongPassword]。
  /// 同时写入内部失败计数，达到阈值后触发指数退避。
  Future<Uint8List> unlock({required Uint8List password});

  /// 用恢复码解锁。
  Future<Uint8List> unlockWithRecoveryCode({required Uint8List recoveryCode});

  /// 用生物识别解锁（需已通过 [KeyringStore.readBiometricWrappedKey] 的门控）。
  Future<Uint8List> unlockWithBiometric();

  /// 把 DEK 从内存中清除并清零其缓冲区。
  ///
  /// 能力边界：能清零的是我们持有的 `Uint8List`；
  /// SQLCipher 内部持有的副本由它自己管理（`PRAGMA rekey` / 关闭连接可释放）。
  Future<void> lock();

  /// 修改主密码。DEK 不变，只重新包裹。
  ///
  /// 因此该操作是 O(1) 的，**不需要重新加密数据库**，也就没有中途断电的风险。
  Future<void> changeMasterPassword({required Uint8List current, required Uint8List next});

  /// 重新生成恢复码（旧恢复码随之作废）。
  Future<String> regenerateRecoveryCode({required Uint8List password});
}

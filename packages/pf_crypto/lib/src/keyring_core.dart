/// 密钥层级的编排核心（方案 §3.1 / §3.5.1）。
///
/// ## 它是什么、不是什么
///
/// [KeyringCore] 是**纯函数编排层**：把已落地的三个原语
/// （[KeyDeriver] / [KeyExpander] / [Aead]）按 §3.1 的层级串起来：
///
/// ```
///   主密码 ──Argon2id(salt_master, P_*)──▶ MK（32B，永不落盘）
///                                             │
///             ┌───────────────────────────────┤ HKDF-SHA256(info="pf/db/1")
///             ▼                               ▼
///          DBKey（32B → SQLCipher）      keyCheck = AES-GCM(DBKey,
///                                          pt="PF:KEYCHECK:v1",
///                                          aad="pf-keycheck-v1|cfgVersion|installId")
///
///   恢复码 ──Argon2id(salt_rec, P_*)──▶ RK（32B）
///             recovery.blob = AES-GCM(RK, nonce, pt=MK, aad="pf-recovery-v1|cfgVersion")
/// ```
///
/// 它**不是** `Keyring` 接口的实装。有状态的保险箱（初始化 / 解锁 / 失败计数
/// / 指数退避 / 对接 Keychain-Keystore 的 [KeyringStore]）属于 M2 ——
/// 那一半的本质是平台与 UI 编排，无法也不需要进黄金向量；
/// 而本文件的组合规则（AAD 怎么拼、info 用什么标签、哪个密钥包哪个秘密）
/// 恰恰是**必须被向量锁死**的部分：这些字段会写进 `wallet.cfg.json`，
/// 任何一处变动都等于让已导出的配置失去可读性。
///
/// ## 与 wallet.cfg.json 的对应关系（§3.5.1）
///
///   - `keyCheck.nonce / keyCheck.ct`  → [sealKeyCheck] 的输出
///   - `keyCheck.aad`                  → [keyCheckAad] 拼出的字符串
///   - `recovery.nonce / recovery.ct`  → [wrapMasterKeyForRecovery] 的输出
///   - `recovery.aad`                  → [recoveryAad] 拼出的字符串
///   - `kdf.salt` / `recovery.kdf.salt` → Argon2id 的盐，派生本身走
///     [Argon2idDeriver]（已有向量），不在本文件重复。
///
/// ## 一处规格内部矛盾的裁决（记录在案）
///
/// §3.1 规定 keyCheck 的明文是字符串 `"PF:KEYCHECK:v1"`（14 字节），
/// 但 §3.5.1 的 JSON 示例写着 `ct: 48B(32+16)` —— 按 32 字节明文算的。
/// 两处不可能同时成立。本实现采用 §3.1 的字符串明文（keyCheck 的语义就是
/// 「一个固定的已知答案」，长度本身没有安全含义），
/// 于是 `ct = 14 + 16 = 30` 字节。向量锁死这一裁决。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';

import 'aesgcm.dart';
import 'hkdf.dart';

/// wallet.cfg.json 的配置版本（§3.5.1 的 `cfgVersion`）。
///
/// 它进两个 AAD：keyCheck 与 recovery。**升级它等于作废全部已存配置**，
/// 必须伴随迁移设计，不能顺手改。
const int walletCfgVersion = 1;

/// DBKey 的 HKDF 用途标签（§7.4：`DBKey = HKDF(MK, info="pf/db/1")`）。
///
/// 改标签 = 所有已创建的数据库一个字节不动却再也打不开。
/// 它属于格式契约，与容器头的魔数同级。
final List<int> dbKeyInfo = utf8.encode('pf/db/1');

/// keyCheck 块的固定明文（§3.1）。
///
/// 解开后的明文**必须逐字节等于**这个串：密钥对但内容被换过的情况
/// （例如旧版本实现写入了别的串）要按「篡改」处理，而不是放行。
final Uint8List keyCheckPlaintext = Uint8List.fromList(utf8.encode('PF:KEYCHECK:v1'));

/// keyCheck 块的 AAD（§3.5.1：`pf-keycheck-v1|<cfgVersion>|<installId>`）。
///
/// AAD 把密钥校验块绑定到「这份配置的这一版、这一台安装」：
/// 换 installId 的配置文件（复制别人的 cfg 来碰运气）会在认证阶段直接失败。
String keyCheckAad({required int cfgVersion, required String installId}) =>
    'pf-keycheck-v1|$cfgVersion|$installId';

/// 恢复码包裹块的 AAD（§3.5.2：`pf-recovery-v1|$cfgVersion`）。
String recoveryAad({required int cfgVersion}) => 'pf-recovery-v1|$cfgVersion';

/// keyCheck 块（§3.5.1 的 `keyCheck` 对象）。
final class KeyCheckBlock {
  KeyCheckBlock({
    required Uint8List nonce,
    required Uint8List ciphertext,
    required Uint8List tag,
    required this.cfgVersion,
    required this.installId,
  }) : nonce = Uint8List.fromList(nonce),
       ciphertext = Uint8List.fromList(ciphertext),
       tag = Uint8List.fromList(tag) {
    if (this.nonce.length != Aes256Gcm.defaultNonceLength) {
      throw KeyringError.tampered();
    }
    if (this.ciphertext.length != keyCheckPlaintext.length) {
      // §3.5.1 的结构约束：ct 长度 = 明文长度。长度不对 = 被改过或写坏了。
      throw KeyringError.tampered();
    }
    if (this.tag.length != Aes256Gcm.tagLengthBytes) {
      throw KeyringError.tampered();
    }
  }

  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List tag;
  final int cfgVersion;
  final String installId;

  String get aad => keyCheckAad(cfgVersion: cfgVersion, installId: installId);

  Map<String, Object?> toJson() => <String, Object?>{
    'nonceHex': toHex(nonce),
    'ciphertextHex': toHex(ciphertext),
    'tagHex': toHex(tag),
    'aad': aad,
  };
}

/// 恢复码包裹块（§3.5.1 的 `recovery` 对象里属于本层的部分）。
final class RecoveryBlob {
  RecoveryBlob({
    required Uint8List nonce,
    required Uint8List ciphertext,
    required Uint8List tag,
    required this.cfgVersion,
  }) : nonce = Uint8List.fromList(nonce),
       ciphertext = Uint8List.fromList(ciphertext),
       tag = Uint8List.fromList(tag) {
    if (this.nonce.length != Aes256Gcm.defaultNonceLength) {
      throw KeyringError.tampered();
    }
    // 明文是 MK（32 字节），故密文必须是 32 字节；长度不对 = 被改过或写坏了。
    if (this.ciphertext.length != masterKeyLength) {
      throw KeyringError.tampered();
    }
    if (this.tag.length != Aes256Gcm.tagLengthBytes) {
      throw KeyringError.tampered();
    }
  }

  /// 主密钥长度（32 字节）。
  static const int masterKeyLength = 32;

  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List tag;
  final int cfgVersion;

  String get aad => recoveryAad(cfgVersion: cfgVersion);

  Map<String, Object?> toJson() => <String, Object?>{
    'nonceHex': toHex(nonce),
    'ciphertextHex': toHex(ciphertext),
    'tagHex': toHex(tag),
    'aad': aad,
  };
}

/// 密钥层级编排核心。
///
/// 无状态：所有方法都是纯组合，可以随意并发调用。
/// 运行成本标注在各方法的文档里 —— 调用方（有状态的 Keyring 实装）
/// 据此决定哪些调用能放在 UI 线程的「点击即回」路径上。
final class KeyringCore {
  const KeyringCore._();

  /// 单例。
  static const KeyringCore instance = KeyringCore._();

  /// MK → DBKey（§3.1：`DBKey = HKDF-SHA256(MK, info="pf/db/1")`）。
  ///
  /// extract 阶段的 salt 按方案省略（RFC 5869 语义：等于 HashLen 个 0x00）。
  /// MK 已经是 32 字节的高熵密钥，extract 不提供额外安全增益；
  /// 保留两段结构只是为了让 PRK 可以单独核对（见 [KeyExpander] 的文档）。
  ///
  /// 运行成本：微秒级（两次 HMAC），可在任意线程同步调用。
  Uint8List deriveDbKey({
    required Uint8List masterKey,
    KeyExpander expander = HkdfSha256.instance,
  }) {
    if (masterKey.length != RecoveryBlob.masterKeyLength) {
      // 调用方 bug，不是用户可见失败：MK 只能来自 Argon2id（输出恒 32 字节）。
      // 长度经局部变量进入消息 —— 日志守卫禁止密钥类标识符直接进插值。
      final mkLength = masterKey.length;
      throw DomainError.validation(detail: 'MK 必须是 32 字节，实际 $mkLength');
    }
    final prk = expander.extract(salt: const <int>[], ikm: masterKey);
    try {
      return expander.expand(prk: prk, info: dbKeyInfo, length: 32);
    } finally {
      zeroize(prk);
    }
  }

  /// 生成 keyCheck 块（§3.1）。
  ///
  /// 运行成本：毫秒级（一次 AES-GCM）。初始化与改主密码时各调用一次。
  Future<KeyCheckBlock> sealKeyCheck({
    required Uint8List dbKey,
    required Uint8List nonce,
    required String installId,
    int cfgVersion = walletCfgVersion,
    Aes256Gcm aead = Aes256Gcm.instance,
  }) async {
    final detached = await aead.sealDetached(
      key: dbKey,
      nonce: nonce,
      plaintext: keyCheckPlaintext,
      aad: Uint8List.fromList(
        utf8.encode(keyCheckAad(cfgVersion: cfgVersion, installId: installId)),
      ),
    );
    return KeyCheckBlock(
      nonce: nonce,
      ciphertext: detached.ciphertext,
      tag: detached.tag,
      cfgVersion: cfgVersion,
      installId: installId,
    );
  }

  /// 校验 keyCheck 块（§3.1：把「密码错」与「库损坏」分开的那一刀）。
  ///
  ///   - 认证标签对不上 → [KeyringError.wrongPassword]。
  ///     **加密层无法区分**「DBKey 错（密码错）」与「块被改（配置被换）」——
  ///     两者都是认证失败。App 层的消歧路径是恢复码：恢复码能解锁而主密码
  ///     不能，才说明配置被动过；首次失败一律先按密码错提示。
  ///   - 解开但明文不等于固定常量 → [KeyringError.tampered]：
  ///     密钥「对上了」内容却不对，只能是块本身被替换。
  ///
  /// 运行成本：毫秒级。每次解锁都会调用（先于打开数据库）。
  ///
  /// **消歧路径不在本层**（本层是纯函数编排，没有 App 状态、没有 UI）。
  /// App 层按 §3.4 / §3.5.1 的既定流程走：
  ///   ① keyCheck 失败 → 一律先按「密码错」提示（§3.5.1 UX：连续失败 5 次
  ///      才提示"可用恢复码解锁"，本地应用不锁定账号）；
  ///   ② 恢复码能解锁而主密码不能 → 说明 wallet.cfg 被换/被动过；
  ///   ③ 两条路都失败 → 按「库损坏或被替换」处理（§3.5.1 安全说明里
  ///      keyCheck 失败的另一种解释）。
  /// 另注意：§3.4 的 `_isCipherKeyError`（"file is not a database"）是
  /// SQLCipher 层的**第二道**区分点 —— 本块通过而数据库仍打不开时，
  /// 只可能是库文件本身损坏。该分类属于 M2 的打开流程，不在 pf_crypto。
  Future<void> verifyKeyCheck({
    required Uint8List dbKey,
    required KeyCheckBlock block,
    Aes256Gcm aead = Aes256Gcm.instance,
  }) async {
    final Uint8List plaintext;
    try {
      plaintext = await aead.open(
        key: dbKey,
        nonce: block.nonce,
        ciphertext: block.ciphertext,
        tag: block.tag,
        aad: Uint8List.fromList(utf8.encode(block.aad)),
      );
    } on ContainerError catch (error) {
      if (error.code == PfErrorCode.containerAuthFailed) {
        throw KeyringError.wrongPassword();
      }
      rethrow;
    }
    if (!_bytesEqual(plaintext, keyCheckPlaintext)) {
      throw KeyringError.tampered();
    }
  }

  /// 用恢复码派生密钥 RK 包裹 MK（§3.5.2 的 `recovery.blob`）。
  ///
  /// [recoveryKey] 是 RK —— 由恢复码经 [Argon2idDeriver] 派生（慢操作，
  /// 已有独立向量），本方法只做快的一次 AES-GCM。
  Future<RecoveryBlob> wrapMasterKeyForRecovery({
    required Uint8List recoveryKey,
    required Uint8List masterKey,
    required Uint8List nonce,
    int cfgVersion = walletCfgVersion,
    Aes256Gcm aead = Aes256Gcm.instance,
  }) async {
    if (masterKey.length != RecoveryBlob.masterKeyLength) {
      final mkLength = masterKey.length;
      throw DomainError.validation(detail: 'MK 必须是 32 字节，实际 $mkLength');
    }
    final detached = await aead.sealDetached(
      key: recoveryKey,
      nonce: nonce,
      plaintext: masterKey,
      aad: Uint8List.fromList(utf8.encode(recoveryAad(cfgVersion: cfgVersion))),
    );
    return RecoveryBlob(
      nonce: nonce,
      ciphertext: detached.ciphertext,
      tag: detached.tag,
      cfgVersion: cfgVersion,
    );
  }

  /// 解开恢复码包裹块，还原 MK（§3.1 恢复通路）。
  ///
  /// 认证失败 → [KeyringError.wrongRecoveryCode]：恢复码路径没有
  /// 「密码对但内容被换」的中间态 —— 能认证通过就等于 RK 正确。
  Future<Uint8List> unwrapMasterKeyFromRecovery({
    required Uint8List recoveryKey,
    required RecoveryBlob blob,
    Aes256Gcm aead = Aes256Gcm.instance,
  }) async {
    try {
      return await aead.open(
        key: recoveryKey,
        nonce: blob.nonce,
        ciphertext: blob.ciphertext,
        tag: blob.tag,
        aad: Uint8List.fromList(utf8.encode(blob.aad)),
      );
    } on ContainerError catch (error) {
      if (error.code == PfErrorCode.containerAuthFailed) {
        throw KeyringError.wrongRecoveryCode();
      }
      rethrow;
    }
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

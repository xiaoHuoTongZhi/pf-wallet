/// 驱动：Keyring 编排层（方案 §3.1 / §3.5.1，已实装，纯 Dart）。
///
/// ## 为什么这些规则值得向量
///
/// [KeyringCore] 本身不实现任何密码学原语 —— 它只是把 HKDF / AES-GCM
/// 按规格拼起来。但**拼法就是契约**：HKDF 的 info 标签、两个 AAD 的
/// 字节级拼法、keyCheck 的固定明文、错误码的分支，全部写进
/// `wallet.cfg.json`（§3.5.1）。任何一处变动都等于让已发布的配置
/// 失去可读性 —— 与容器头的魔数同级，必须被向量锁死。
///
/// 期望值来自 `tools/golden_vectors_gen/keyring.py`（Python 标准库 hmac
/// 手拼 HKDF + cryptography 的 AES-GCM，双路径交叉核对），与 Dart 侧
/// `HkdfSha256` + `Aes256Gcm` 是两套实现。
library;

import 'dart:convert';

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';

import '../driver.dart';
import '../json_util.dart';
import '../outcome.dart';

/// MK → DBKey。
final class KeyringDbKeyDeriveDriver extends VectorDriver {
  const KeyringDbKeyDeriveDriver();

  @override
  String get kind => 'keyring.dbkey.derive';

  @override
  String get description => 'MK 经 HKDF-SHA256（info="pf/db/1"）派生 DBKey';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'masterKeyHex': '32 字节主密钥 MK（Argon2id 的输出）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final dbKey = KeyringCore.instance.deriveDbKey(
      masterKey: requireHexBytes(input, 'masterKeyHex', kind),
    );
    return VectorOutcome.value(<String, Object?>{'dbKeyHex': toHex(dbKey)});
  }
}

/// 生成 keyCheck 块。
final class KeyringKeyCheckSealDriver extends VectorDriver {
  const KeyringKeyCheckSealDriver();

  @override
  String get kind => 'keyring.keycheck.seal';

  @override
  String get description => 'DBKey + installId + cfgVersion → keyCheck 块（§3.5.1）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'dbKeyHex': '32 字节 DBKey',
    'nonceHex': '12 字节 nonce',
    'installId': '本机安装标识（AAD 绑定用）',
    'cfgVersion': '配置版本号',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final block = await KeyringCore.instance.sealKeyCheck(
      dbKey: requireHexBytes(input, 'dbKeyHex', kind),
      nonce: requireHexBytes(input, 'nonceHex', kind),
      installId: requireString(input, 'installId', kind),
      cfgVersion: requireInt(input, 'cfgVersion', kind),
    );
    return VectorOutcome.value(block.toJson());
  }
}

/// 校验 keyCheck 块。
final class KeyringKeyCheckOpenDriver extends VectorDriver {
  const KeyringKeyCheckOpenDriver();

  @override
  String get kind => 'keyring.keycheck.open';

  @override
  String get description => '校验 keyCheck 块：把「密码错」与「块被改」分开（§3.1）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'dbKeyHex': '32 字节 DBKey',
    'nonceHex': '12 字节 nonce',
    'ciphertextHex': 'keyCheck 密文（14 字节）',
    'tagHex': '16 字节认证标签',
    'installId': '本机安装标识',
    'cfgVersion': '配置版本号',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final block = KeyCheckBlock(
      nonce: requireHexBytes(input, 'nonceHex', kind),
      ciphertext: requireHexBytes(input, 'ciphertextHex', kind),
      tag: requireHexBytes(input, 'tagHex', kind),
      cfgVersion: requireInt(input, 'cfgVersion', kind),
      installId: requireString(input, 'installId', kind),
    );
    await KeyringCore.instance.verifyKeyCheck(
      dbKey: requireHexBytes(input, 'dbKeyHex', kind),
      block: block,
    );
    return VectorOutcome.value(<String, Object?>{'plaintextUtf8': utf8.decode(keyCheckPlaintext)});
  }
}

/// RK 包裹 MK。
final class KeyringRecoveryWrapDriver extends VectorDriver {
  const KeyringRecoveryWrapDriver();

  @override
  String get kind => 'keyring.recovery.wrap';

  @override
  String get description => '恢复码派生密钥 RK 包裹 MK → recovery.blob（§3.5.2）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'recoveryKeyHex': '32 字节 RK（Argon2id(恢复码, salt_rec, P_*) 的输出）',
    'masterKeyHex': '32 字节 MK',
    'nonceHex': '12 字节 nonce',
    'cfgVersion': '配置版本号',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final blob = await KeyringCore.instance.wrapMasterKeyForRecovery(
      recoveryKey: requireHexBytes(input, 'recoveryKeyHex', kind),
      masterKey: requireHexBytes(input, 'masterKeyHex', kind),
      nonce: requireHexBytes(input, 'nonceHex', kind),
      cfgVersion: requireInt(input, 'cfgVersion', kind),
    );
    return VectorOutcome.value(blob.toJson());
  }
}

/// 解开 recovery.blob。
final class KeyringRecoveryUnwrapDriver extends VectorDriver {
  const KeyringRecoveryUnwrapDriver();

  @override
  String get kind => 'keyring.recovery.unwrap';

  @override
  String get description => '解开 recovery.blob 还原 MK（恢复通路）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'recoveryKeyHex': '32 字节 RK',
    'nonceHex': '12 字节 nonce',
    'ciphertextHex': '32 字节密文（= MK 等长）',
    'tagHex': '16 字节认证标签',
    'cfgVersion': '配置版本号',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final blob = RecoveryBlob(
      nonce: requireHexBytes(input, 'nonceHex', kind),
      ciphertext: requireHexBytes(input, 'ciphertextHex', kind),
      tag: requireHexBytes(input, 'tagHex', kind),
      cfgVersion: requireInt(input, 'cfgVersion', kind),
    );
    final mk = await KeyringCore.instance.unwrapMasterKeyFromRecovery(
      recoveryKey: requireHexBytes(input, 'recoveryKeyHex', kind),
      blob: blob,
    );
    return VectorOutcome.value(<String, Object?>{'masterKeyHex': toHex(mk)});
  }
}

// 覆盖检查里的其他用例（keyCheck / recovery）单次都是毫秒级 AES-GCM，
// 但整组里夹着 Argon2id 派生时仍可能慢 —— 文件级放宽，避免假超时。
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';
import 'package:test/test.dart';

/// KeyringCore 单元测试：§3.1 密钥层级的组合规则。
///
/// 与向量的分工：向量（test_vectors/v1/keyring.json）锁**数值** ——
/// 期望值由 Python 独立复算，Dart 实现必须逐字节命中。
/// 本文件锁**行为** —— 错误码分支、AAD 拼法、结构校验、与
/// Argon2idDeriver / HkdfSha256 / Aes256Gcm 三个已落地原语的端到端组合。
/// 两者重叠是刻意的：向量是锁，单测是说明书。
void main() {
  const core = KeyringCore.instance;

  // 与 golden 向量同一组固定输入，便于交叉定位。
  final mk = fromHex('3d7fa1c29b04e5f67a83c1d90b254e68f7a2c30958d16b4e92f0ad3716c8e45b');
  final nonce12 = fromHex('2122232425262728292a2b2c');
  const installId = '01J8Z9K2M4P6Q8R0T2V4X6Z8B1';

  Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));

  group('KeyringCore · MK → DBKey', () {
    test('DBKey = HKDF-SHA256(MK, info="pf/db/1")，与向量数值一致', () {
      final dbKey = core.deriveDbKey(masterKey: mk);
      expect(dbKey.length, 32);
      // 数值与 test_vectors/v1/keyring.json 的 keyring.dbkey.derive.default 同源
      // （Python 双路径独立复算），抄写于此作为第二道锁。
      expect(toHex(dbKey), _dbKeyHex);
    });

    test('MK 长度不是 32 ⇒ validation（调用方 bug，非用户可见失败）', () {
      expect(
        () => core.deriveDbKey(masterKey: Uint8List(31)),
        throwsA(isA<DomainError>().having((e) => e.code, 'code', PfErrorCode.validation)),
      );
    });
  });

  group('KeyringCore · keyCheck（§3.1 的「密码错 / 库损坏」分刀）', () {
    test('seal → verify 往返通过，AAD 拼法锁定', () async {
      final block = await core.sealKeyCheck(
        dbKey: core.deriveDbKey(masterKey: mk),
        nonce: nonce12,
        installId: installId,
      );
      expect(block.aad, 'pf-keycheck-v1|1|$installId');
      expect(block.ciphertext.length, keyCheckPlaintext.length);
      await core.verifyKeyCheck(dbKey: core.deriveDbKey(masterKey: mk), block: block);
    });

    test('DBKey 错（密码错）⇒ PFK_E_WRONG_PASSWORD', () async {
      final block = await core.sealKeyCheck(
        dbKey: core.deriveDbKey(masterKey: mk),
        nonce: nonce12,
        installId: installId,
      );
      final wrongDbKey = core.deriveDbKey(masterKey: fromHex(_mk2Hex));
      expect(
        () => core.verifyKeyCheck(dbKey: wrongDbKey, block: block),
        throwsA(
          isA<KeyringError>().having((e) => e.code, 'code', PfErrorCode.keyringWrongPassword),
        ),
      );
    });

    test('installId 不符（AAD 被换）同样认证失败 ⇒ PFK_E_WRONG_PASSWORD', () async {
      final block = await core.sealKeyCheck(
        dbKey: core.deriveDbKey(masterKey: mk),
        nonce: nonce12,
        installId: installId,
      );
      final forged = KeyCheckBlock(
        nonce: block.nonce,
        ciphertext: block.ciphertext,
        tag: block.tag,
        cfgVersion: block.cfgVersion,
        installId: '01J8ZOTHERDEVICE0000000000X',
      );
      await expectLater(
        core.verifyKeyCheck(dbKey: core.deriveDbKey(masterKey: mk), block: forged),
        throwsA(
          isA<KeyringError>().having((e) => e.code, 'code', PfErrorCode.keyringWrongPassword),
        ),
      );
    });

    test('密文被改 ⇒ 认证失败（不是放行）', () async {
      final block = await core.sealKeyCheck(
        dbKey: core.deriveDbKey(masterKey: mk),
        nonce: nonce12,
        installId: installId,
      );
      final tampered = KeyCheckBlock(
        nonce: block.nonce,
        ciphertext: Uint8List.fromList([...block.ciphertext]..[0] ^= 0xFF),
        tag: block.tag,
        cfgVersion: block.cfgVersion,
        installId: installId,
      );
      await expectLater(
        core.verifyKeyCheck(dbKey: core.deriveDbKey(masterKey: mk), block: tampered),
        throwsA(
          isA<KeyringError>().having((e) => e.code, 'code', PfErrorCode.keyringWrongPassword),
        ),
      );
    });

    test('块结构破坏（密文截断）⇒ PFK_E_TAMPERED，构造期就拦下', () {
      expect(
        () => KeyCheckBlock(
          nonce: nonce12,
          ciphertext: Uint8List(10),
          tag: Uint8List(16),
          cfgVersion: 1,
          installId: installId,
        ),
        throwsA(isA<KeyringError>().having((e) => e.code, 'code', PfErrorCode.keyringTampered)),
      );
    });
  });

  group('KeyringCore · 恢复码包裹（§3.5.2）', () {
    // RK 在向量里直接给定；这里用「快」的方式造一个稳定 RK（不跑 Argon2id，
    // 派生本身已有独立向量与单测）。
    final rk = HkdfSha256.instance.expand(
      prk: HkdfSha256.instance.extract(salt: const <int>[], ikm: mk),
      info: utf8Bytes('pf/recovery-test-rk'),
      length: 32,
    );

    test('wrap → unwrap 往返还原 MK，AAD 拼法锁定', () async {
      final blob = await core.wrapMasterKeyForRecovery(
        recoveryKey: rk,
        masterKey: mk,
        nonce: nonce12,
      );
      expect(blob.aad, 'pf-recovery-v1|1');
      expect(blob.ciphertext.length, 32);
      final restored = await core.unwrapMasterKeyFromRecovery(recoveryKey: rk, blob: blob);
      expect(toHex(restored), toHex(mk));
    });

    test('RK 错（恢复码错）⇒ PFK_E_WRONG_RECOVERY_CODE', () async {
      final blob = await core.wrapMasterKeyForRecovery(
        recoveryKey: rk,
        masterKey: mk,
        nonce: nonce12,
      );
      final wrongRk = Uint8List.fromList([...rk]..[0] ^= 1);
      await expectLater(
        core.unwrapMasterKeyFromRecovery(recoveryKey: wrongRk, blob: blob),
        throwsA(
          isA<KeyringError>().having((e) => e.code, 'code', PfErrorCode.keyringWrongRecoveryCode),
        ),
      );
    });

    test('标签被改 ⇒ PFK_E_WRONG_RECOVERY_CODE', () async {
      final blob = await core.wrapMasterKeyForRecovery(
        recoveryKey: rk,
        masterKey: mk,
        nonce: nonce12,
      );
      final tampered = RecoveryBlob(
        nonce: blob.nonce,
        ciphertext: blob.ciphertext,
        tag: Uint8List.fromList([...blob.tag]..[0] ^= 0xFF),
        cfgVersion: blob.cfgVersion,
      );
      await expectLater(
        core.unwrapMasterKeyFromRecovery(recoveryKey: rk, blob: tampered),
        throwsA(
          isA<KeyringError>().having((e) => e.code, 'code', PfErrorCode.keyringWrongRecoveryCode),
        ),
      );
    });

    test('RK 正确但 cfgVersion 被改 ⇒ 认证失败（版本进 AAD 的证据）', () async {
      final blob = await core.wrapMasterKeyForRecovery(
        recoveryKey: rk,
        masterKey: mk,
        nonce: nonce12,
        cfgVersion: 1,
      );
      final forged = RecoveryBlob(
        nonce: blob.nonce,
        ciphertext: blob.ciphertext,
        tag: blob.tag,
        cfgVersion: 2,
      );
      await expectLater(
        core.unwrapMasterKeyFromRecovery(recoveryKey: rk, blob: forged),
        throwsA(
          isA<KeyringError>().having((e) => e.code, 'code', PfErrorCode.keyringWrongRecoveryCode),
        ),
      );
    });
  });

  group('KeyringCore · 端到端组合（与三个原语真实串联）', () {
    test('Argon2id → MK → DBKey → keyCheck → verify 全链路（P_MIN 档控制耗时）', () async {
      final password = utf8Bytes('correct horse battery staple');
      final salt = fromHex('706677616c6c657473616c7430313233');
      final mkReal = await Argon2idDeriver.instance.derive(
        password: password,
        salt: salt,
        params: Argon2Params.presetMin,
      );
      final dbKey = core.deriveDbKey(masterKey: mkReal);
      final block = await core.sealKeyCheck(dbKey: dbKey, nonce: nonce12, installId: installId);
      await core.verifyKeyCheck(dbKey: dbKey, block: block);

      // 同密码同盐重新派生 ⇒ DBKey 相同 ⇒ keyCheck 仍通过（确定性，解锁的前提）。
      final mkAgain = await Argon2idDeriver.instance.derive(
        password: password,
        salt: salt,
        params: Argon2Params.presetMin,
      );
      await core.verifyKeyCheck(dbKey: core.deriveDbKey(masterKey: mkAgain), block: block);
    });
  });

  group('密钥层 · 块结构约束（长度不对 = 被改过或写坏了）', () {
    test('KeyCheckBlock：nonce 长度 ≠ 12 ⇒ PFK_E_TAMPERED', () {
      expect(
        () => KeyCheckBlock(
          nonce: Uint8List(Aes256Gcm.defaultNonceLength - 1),
          ciphertext: Uint8List(keyCheckPlaintext.length),
          tag: Uint8List(Aes256Gcm.tagLengthBytes),
          cfgVersion: walletCfgVersion,
          installId: installId,
        ),
        throwsA(_tampered),
      );
    });

    test('KeyCheckBlock：tag 长度 ≠ 16 ⇒ PFK_E_TAMPERED', () {
      expect(
        () => KeyCheckBlock(
          nonce: nonce12,
          ciphertext: Uint8List(keyCheckPlaintext.length),
          tag: Uint8List(Aes256Gcm.tagLengthBytes - 1),
          cfgVersion: walletCfgVersion,
          installId: installId,
        ),
        throwsA(_tampered),
      );
    });

    test('KeyCheckBlock.toJson：写进 wallet.cfg.json 的那四个字段', () async {
      final block = await core.sealKeyCheck(
        dbKey: core.deriveDbKey(masterKey: mk),
        nonce: nonce12,
        installId: installId,
      );
      expect(block.toJson(), <String, Object?>{
        'nonceHex': toHex(nonce12),
        'ciphertextHex': toHex(block.ciphertext),
        'tagHex': toHex(block.tag),
        'aad': block.aad,
      });
      // aad 是**明文**进 JSON 的：它必须能被读方独立重算出来，
      // 否则配置文件换台设备就打不开，而失败会伪装成「密码错」。
      expect(block.toJson()['aad'], 'pf-keycheck-v1|$walletCfgVersion|$installId');
    });

    test('RecoveryBlob：nonce / 密文 / 标签长度各自不对 ⇒ PFK_E_TAMPERED', () {
      expect(
        () => RecoveryBlob(
          nonce: Uint8List(Aes256Gcm.defaultNonceLength - 1),
          ciphertext: Uint8List(RecoveryBlob.masterKeyLength),
          tag: Uint8List(Aes256Gcm.tagLengthBytes),
          cfgVersion: walletCfgVersion,
        ),
        throwsA(_tampered),
      );
      // 明文是 MK（32 字节），故密文必须是 32 字节。
      expect(
        () => RecoveryBlob(
          nonce: nonce12,
          ciphertext: Uint8List(RecoveryBlob.masterKeyLength - 1),
          tag: Uint8List(Aes256Gcm.tagLengthBytes),
          cfgVersion: walletCfgVersion,
        ),
        throwsA(_tampered),
      );
      expect(
        () => RecoveryBlob(
          nonce: nonce12,
          ciphertext: Uint8List(RecoveryBlob.masterKeyLength),
          tag: Uint8List(Aes256Gcm.tagLengthBytes - 1),
          cfgVersion: walletCfgVersion,
        ),
        throwsA(_tampered),
      );
    });

    test('RecoveryBlob.toJson：aad 由 cfgVersion 拼出，与 keyCheck 的 AAD 不同源', () {
      final blob = RecoveryBlob(
        nonce: nonce12,
        ciphertext: Uint8List(RecoveryBlob.masterKeyLength),
        tag: Uint8List(Aes256Gcm.tagLengthBytes),
        cfgVersion: 7,
      );
      expect(blob.toJson(), <String, Object?>{
        'nonceHex': toHex(nonce12),
        'ciphertextHex': toHex(blob.ciphertext),
        'tagHex': toHex(blob.tag),
        'aad': 'pf-recovery-v1|7',
      });
    });
  });

  group('密钥层 · 认证通过但内容被换（唯一能落到的那条防线）', () {
    test('解开后明文 ≠ "PF:KEYCHECK:v1" ⇒ PFK_E_TAMPERED，而不是放行', () async {
      final dbKey = core.deriveDbKey(masterKey: mk);
      // 用**同一把密钥、同一个 nonce、同一个 AAD** 封一段等长的别的明文：
      // GCM 认证会通过，于是「密码错」那一层被完整绕过，
      // 只剩「解开后必须逐字节等于常量」这一条还站着。这正是它存在的理由 ——
      // 旧版本实现若写入过别的串，必须按篡改处理，不能当成登录成功。
      final forgedPlaintext = Uint8List.fromList(utf8.encode('PF:KEYCHECK:v2'));
      expect(forgedPlaintext.length, keyCheckPlaintext.length);

      final detached = await Aes256Gcm.instance.sealDetached(
        key: dbKey,
        nonce: nonce12,
        plaintext: forgedPlaintext,
        aad: Uint8List.fromList(
          utf8.encode(keyCheckAad(cfgVersion: walletCfgVersion, installId: installId)),
        ),
      );
      final forged = KeyCheckBlock(
        nonce: nonce12,
        ciphertext: detached.ciphertext,
        tag: detached.tag,
        cfgVersion: walletCfgVersion,
        installId: installId,
      );
      await expectLater(core.verifyKeyCheck(dbKey: dbKey, block: forged), throwsA(_tampered));
    });

    test('wrapMasterKeyForRecovery：MK 长度 ≠ 32 ⇒ validation（调用方 bug）', () async {
      await expectLater(
        core.wrapMasterKeyForRecovery(
          recoveryKey: Uint8List(32),
          masterKey: Uint8List(RecoveryBlob.masterKeyLength - 1),
          nonce: nonce12,
        ),
        throwsA(isA<DomainError>().having((e) => e.code, 'code', PfErrorCode.validation)),
      );
    });
  });
}

// ---- 向量数值（与 test_vectors/v1/keyring.json 同源，Python 独立复算） ----

const String _mk2Hex = '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';

const String _dbKeyHex = '30e0382aab4f7051e1ed5e9406a2fdfd9a372d63b58f1e9a74794dc2538e113d';

/// 结构损坏 / 内容被换的统一码。密钥层不需要把这两种再分开 ——
/// 对调用方而言「这个块不可信」是同一个动作：拒绝并走恢复通路。
final Matcher _tampered = isA<KeyringError>().having(
  (e) => e.code,
  'code',
  PfErrorCode.keyringTampered,
);

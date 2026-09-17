import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';
import 'package:test/test.dart';

/// AES-256-GCM 单元测试。
///
/// 期望值**逐条抄自 `test_vectors/v1/aes256gcm.json`**，不是从本实现打印出来的。
/// 抄完之后再用 Python `cryptography`（并以 NIST GCMVS AES-256 Count=0 锚定）
/// 复算核对过——见 `tools/golden_vectors_gen/aes256gcm.py`。
///
/// 为什么绕这一圈：`seal` 的输出完全没有冗余，错一位也是一串「看起来正常」的密文。
/// 用实现自己产出的值当期望值，等于用「和昨天一致」冒充「和标准一致」。
///
/// 本文件与向量框架是**两条独立的证据链**：
///   - 向量由 `pf_testkit` 的 `AeadSealDriver` / `AeadOpenDriver` 执行；
///   - 本文件证明「`pf_crypto` 的实现自己也能算出同样的字节、且错误分支各自独立」。

/// NIST GCMVS AES-256 Count=0 的密钥与 96 位 nonce（主路径）。
const String _key = 'b52c505a37d78eda5dd34f20c22540ea1b58963cf8e5bf8ffa85f9f2492505b4';
const String _nonce96 = '516c33929df5a3284ff463d7';

/// 与 `aes256gcm.json` 各 seal 用例一致的期望值（独立复算核对过）。
const String _nistTag = 'bdc1ac884d332457a1d2664f168c76f0';
const String _singleBlockCt = 'e69c8e689b8eb63863f5c32d01dcca1f';
const String _singleBlockTag = '5d8629be177ace8460f9d0d3cd00d9a8';
const String _emptyPtAadTag = '7df03a034192fc545dc1d76279a02b50';
const String _singleByteCt = 'a4';
const String _singleByteTag = 'f955d254cba1095f14cf5decee1dfd3e';
const String _aadAndPtTag = '23d8effe8354cb1cf8b419601118c616';
const String _nonce8Ct = '3b31a4ecffaa9ce7db84cd845d646790';
const String _nonce8Tag = 'f8c71c0a81b38f67c0be4572e978153a';
const String _nonce16Ct = '42f5db2de01b8ffc5446cbca2ecb66c9';
const String _nonce16Tag = '905a0132fd6e6cca7507d6599a4dd33b';

/// 三类认证失败的输入（标签 / 密文 / AAD 各改一处，必须抛 `PFB_E_AUTH_FAILED`）。
const String _tagTampered = 'a28629be177ace8460f9d0d3cd00d9a8';
const String _ctTampered = '199c8e689b8eb63863f5c32d01dcca1f';
const String _aadMismatch = 'df2122232425262728292a2b2c2d2e2f';

const Aes256Gcm _aes = Aes256Gcm.instance;

Future<({Uint8List ciphertext, Uint8List tag})> _seal({
  required String key,
  required String nonce,
  required String plaintext,
  required String aad,
}) async {
  return _aes.sealDetached(
    key: fromHex(key),
    nonce: fromHex(nonce),
    plaintext: fromHex(plaintext),
    aad: fromHex(aad),
  );
}

void main() {
  group('Aes256Gcm · 常量与契约', () {
    test('算法名与长度锁死（key=32 / nonce=12 / tag=16）', () {
      expect(_aes.algorithm, 'AES-256-GCM');
      expect(Aes256Gcm.keyLengthBytes, 32);
      expect(Aes256Gcm.tagLengthBytes, 16);
      expect(Aes256Gcm.defaultNonceLength, 12);
    });

    test('契约接口暴露同样的数字', () {
      // `implements Aead` 之后，这些 getter 必须对齐上面的常量。
      expect(_aes.keyLength, 32);
      expect(_aes.nonceLength, 12);
      expect(_aes.tagLength, 16);
    });

    test('instance 是 const 单例，无状态', () {
      expect(identical(Aes256Gcm.instance, Aes256Gcm.instance), isTrue);
      // 默认构造子也返回同一单例：验证「构造」与「instance」是同一个对象。
      // 用 const 构造验证「规范化为同一对象」：非 const 的 Aes256Gcm() 每次都是
      // 新实例，identical 必然为 false。这里刻意写出 const，若换成
      // Aes256Gcm.instance 就退化成同义反复，测不到 const 规范化。
      // ignore: use_named_constants
      expect(identical(const Aes256Gcm(), Aes256Gcm.instance), isTrue);
    });
  });

  group('Aes256Gcm · NIST GCMVS 已知答案', () {
    test('seal · nist-anchor-256（空明文 / 空 AAD / 96 位 nonce）', () async {
      final d = await _seal(key: _key, nonce: _nonce96, plaintext: '', aad: '');
      expect(toHex(d.ciphertext), '');
      expect(toHex(d.tag), _nistTag);
    });

    test('open · nist-anchor-256-open 还原为空明文', () async {
      final pt = await _aes.open(
        key: fromHex(_key),
        nonce: fromHex(_nonce96),
        ciphertext: fromHex(''),
        tag: fromHex(_nistTag),
        aad: fromHex(''),
      );
      expect(toHex(pt), '');
    });

    test('seal · plaintext-single-block', () async {
      final d = await _seal(
        key: _key,
        nonce: _nonce96,
        plaintext: '000102030405060708090a0b0c0d0e0f',
        aad: '',
      );
      expect(toHex(d.ciphertext), _singleBlockCt);
      expect(toHex(d.tag), _singleBlockTag);
    });

    test('seal · empty-pt-with-aad', () async {
      final d = await _seal(
        key: _key,
        nonce: _nonce96,
        plaintext: '',
        aad: '202122232425262728292a2b2c2d2e2f',
      );
      expect(toHex(d.ciphertext), '');
      expect(toHex(d.tag), _emptyPtAadTag);
    });

    test('seal · plaintext-single-byte', () async {
      final d = await _seal(key: _key, nonce: _nonce96, plaintext: '42', aad: '');
      expect(toHex(d.ciphertext), _singleByteCt);
      expect(toHex(d.tag), _singleByteTag);
    });

    test('seal · aad-and-pt', () async {
      final d = await _seal(
        key: _key,
        nonce: _nonce96,
        plaintext: '000102030405060708090a0b0c0d0e0f',
        aad: '202122232425262728292a2b2c2d2e2f',
      );
      expect(toHex(d.ciphertext), _singleBlockCt);
      expect(toHex(d.tag), _aadAndPtTag);
    });
  });

  group('Aes256Gcm · nonce 长度边界（含 96 位外的 GCM 路径）', () {
    test('seal · nonce-8-byte', () async {
      final d = await _seal(
        key: _key,
        nonce: '0011223344556677',
        plaintext: '000102030405060708090a0b0c0d0e0f',
        aad: '0011223344556677',
      );
      expect(toHex(d.ciphertext), _nonce8Ct);
      expect(toHex(d.tag), _nonce8Tag);
    });

    test('seal · nonce-16-byte', () async {
      final d = await _seal(
        key: _key,
        nonce: '00112233445566778899aabbccddeeff',
        plaintext: '000102030405060708090a0b0c0d0e0f',
        aad: '00112233445566778899aabbccddeeff',
      );
      expect(toHex(d.ciphertext), _nonce16Ct);
      expect(toHex(d.tag), _nonce16Tag);
    });

    test('roundtrip · 8 字节 nonce（先 seal 再 open 还原）', () async {
      final d = await _seal(
        key: _key,
        nonce: '0011223344556677',
        plaintext: '000102030405060708090a0b0c0d0e0f',
        aad: '0011223344556677',
      );
      final pt = await _aes.open(
        key: fromHex(_key),
        nonce: fromHex('0011223344556677'),
        ciphertext: d.ciphertext,
        tag: d.tag,
        aad: fromHex('0011223344556677'),
      );
      expect(toHex(pt), '000102030405060708090a0b0c0d0e0f');
    });

    test('roundtrip · 16 字节 nonce', () async {
      final d = await _seal(
        key: _key,
        nonce: '00112233445566778899aabbccddeeff',
        plaintext: '000102030405060708090a0b0c0d0e0f',
        aad: '00112233445566778899aabbccddeeff',
      );
      final pt = await _aes.open(
        key: fromHex(_key),
        nonce: fromHex('00112233445566778899aabbccddeeff'),
        ciphertext: d.ciphertext,
        tag: d.tag,
        aad: fromHex('00112233445566778899aabbccddeeff'),
      );
      expect(toHex(pt), '000102030405060708090a0b0c0d0e0f');
    });
  });

  group('Aes256Gcm · AAD 独立参与认证', () {
    test('相同明文 + 不同 AAD ⇒ 标签不同（AAD 进 GHASH 但不进密文）', () async {
      final noAad = await _seal(
        key: _key,
        nonce: _nonce96,
        plaintext: '000102030405060708090a0b0c0d0e0f',
        aad: '',
      );
      final withAad = await _seal(
        key: _key,
        nonce: _nonce96,
        plaintext: '000102030405060708090a0b0c0d0e0f',
        aad: '202122232425262728292a2b2c2d2e2f',
      );
      expect(toHex(noAad.ciphertext), toHex(withAad.ciphertext), reason: '密文不应随 AAD 改变');
      expect(toHex(noAad.tag), isNot(toHex(withAad.tag)), reason: '标签必须随 AAD 改变');
    });

    test('相同输入 ⇒ 相同输出（确定性，跨平台收敛的前提）', () async {
      final a = await _seal(
        key: _key,
        nonce: _nonce96,
        plaintext: '000102030405060708090a0b0c0d0e0f',
        aad: '',
      );
      final b = await _seal(
        key: _key,
        nonce: _nonce96,
        plaintext: '000102030405060708090a0b0c0d0e0f',
        aad: '',
      );
      expect(toHex(a.ciphertext), toHex(b.ciphertext));
      expect(toHex(a.tag), toHex(b.tag));
    });
  });

  group('Aes256Gcm · seal→open 往返', () {
    test('单块明文往返', () async {
      final d = await _seal(
        key: _key,
        nonce: _nonce96,
        plaintext: '000102030405060708090a0b0c0d0e0f',
        aad: '',
      );
      final pt = await _aes.open(
        key: fromHex(_key),
        nonce: fromHex(_nonce96),
        ciphertext: d.ciphertext,
        tag: d.tag,
        aad: fromHex(''),
      );
      expect(toHex(pt), '000102030405060708090a0b0c0d0e0f');
      expect(pt.length, 16);
    });

    test('空明文往返', () async {
      final d = await _seal(key: _key, nonce: _nonce96, plaintext: '', aad: '');
      final pt = await _aes.open(
        key: fromHex(_key),
        nonce: fromHex(_nonce96),
        ciphertext: d.ciphertext,
        tag: d.tag,
        aad: fromHex(''),
      );
      expect(toHex(pt), '');
    });

    test('单字节明文往返', () async {
      final d = await _seal(key: _key, nonce: _nonce96, plaintext: '42', aad: '');
      final pt = await _aes.open(
        key: fromHex(_key),
        nonce: fromHex(_nonce96),
        ciphertext: d.ciphertext,
        tag: d.tag,
        aad: fromHex(''),
      );
      expect(toHex(pt), '42');
    });

    test('open 输出长度恒等于密文长度（不为 0、也不多一个标签）', () async {
      for (final ptHex in const <String>['', '42', '000102030405060708090a0b0c0d0e0f']) {
        final d = await _seal(key: _key, nonce: _nonce96, plaintext: ptHex, aad: '');
        final pt = await _aes.open(
          key: fromHex(_key),
          nonce: fromHex(_nonce96),
          ciphertext: d.ciphertext,
          tag: d.tag,
          aad: fromHex(''),
        );
        expect(pt.length, d.ciphertext.length, reason: '明文长度应等于密文长度（pt=$ptHex）');
      }
    });
  });

  group('Aes256Gcm · 错误分支 · 密钥长度', () {
    test('key 不是 32 字节 ⇒ headerInvalid（输入契约破坏，不是认证问题）', () {
      // 最常见的触发方式：把错误长度的密钥 / 截断的密钥传进来。类型系统拦不住，
      // 结果会是一把整体偏移的密钥——解密能过、换设备导入时打不开。
      for (final badKey in <String>[
        '',
        '00',
        '42424242424242424242424242424242',
        '00' * 31,
        '00' * 33,
      ]) {
        expect(
          () => _seal(key: badKey, nonce: _nonce96, plaintext: '', aad: ''),
          throwsA(
            isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerHeaderInvalid),
          ),
          reason: '密钥长度 ${badKey.length ~/ 2} 应当被拒绝',
        );
      }
    });

    test('open 同样守密钥长度', () {
      expect(
        () => _aes.open(
          key: fromHex('00' * 31),
          nonce: fromHex(_nonce96),
          ciphertext: fromHex(''),
          tag: fromHex(_nistTag),
          aad: fromHex(''),
        ),
        throwsA(
          isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerHeaderInvalid),
        ),
      );
    });
  });

  group('Aes256Gcm · 错误分支 · 标签长度', () {
    test('tag 不是 16 字节 ⇒ headerInvalid（在解密前就拦下）', () {
      // 标签长度错了，根本没有「凑出合法标签」的可能，属于输入契约破坏。
      for (final badTag in <String>['', '5d86', '5d8629be177ace8460f9d0d3cd00d9', '00' * 17]) {
        expect(
          () => _aes.open(
            key: fromHex(_key),
            nonce: fromHex(_nonce96),
            ciphertext: fromHex(_singleBlockCt),
            tag: fromHex(badTag),
            aad: fromHex(''),
          ),
          throwsA(
            isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerHeaderInvalid),
          ),
          reason: '标签长度 ${badTag.length ~/ 2} 应当被拒绝',
        );
      }
    });
  });

  group('Aes256Gcm · 错误分支 · nonce 不得为空', () {
    test('seal 空 nonce ⇒ headerInvalid', () {
      expect(
        () => _seal(key: _key, nonce: '', plaintext: '', aad: ''),
        throwsA(
          isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerHeaderInvalid),
        ),
      );
    });

    test('open 空 nonce ⇒ headerInvalid', () {
      expect(
        () => _aes.open(
          key: fromHex(_key),
          nonce: fromHex(''),
          ciphertext: fromHex(''),
          tag: fromHex(_nistTag),
          aad: fromHex(''),
        ),
        throwsA(
          isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerHeaderInvalid),
        ),
      );
    });
  });

  group('Aes256Gcm · 认证失败三类（必须抛 PFB_E_AUTH_FAILED）', () {
    test('标签被篡改 ⇒ authFailed', () {
      expect(
        () => _aes.open(
          key: fromHex(_key),
          nonce: fromHex(_nonce96),
          ciphertext: fromHex(_singleBlockCt),
          tag: fromHex(_tagTampered),
          aad: fromHex(''),
        ),
        throwsA(
          isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerAuthFailed),
        ),
      );
    });

    test('密文被篡改 ⇒ authFailed', () {
      expect(
        () => _aes.open(
          key: fromHex(_key),
          nonce: fromHex(_nonce96),
          ciphertext: fromHex(_ctTampered),
          tag: fromHex(_singleBlockTag),
          aad: fromHex(''),
        ),
        throwsA(
          isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerAuthFailed),
        ),
      );
    });

    test('AAD 不符 ⇒ authFailed（AAD 参与认证但不进密文）', () {
      expect(
        () => _aes.open(
          key: fromHex(_key),
          nonce: fromHex(_nonce96),
          ciphertext: fromHex(_singleBlockCt),
          tag: fromHex(_aadAndPtTag),
          aad: fromHex(_aadMismatch),
        ),
        throwsA(
          isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerAuthFailed),
        ),
      );
    });
  });

  group('Aes256Gcm · 错误码稳定', () {
    test('authFailed 就是 PFB_E_AUTH_FAILED，且不同于 headerInvalid', () {
      final auth = ContainerError.authFailed();
      final header = ContainerError.headerInvalid(detail: 'x');
      expect(auth.code, PfErrorCode.containerAuthFailed);
      expect(auth.code, 'PFB_E_AUTH_FAILED');
      expect(header.code, PfErrorCode.containerHeaderInvalid);
      expect(auth.code, isNot(header.code));
    });

    test('headerInvalid 与 authFailed 是分流的两个出口（密码错 vs 文件坏）', () {
      // 「密钥长度错」是契约破坏（headerInvalid），「标签错」是密码/损坏（authFailed）。
      // 两者码不同，调用方才能把「密码不对」和「文件结构不对」区分开给不同提示。
      expect(
        () => _seal(key: '00' * 31, nonce: _nonce96, plaintext: '', aad: ''),
        throwsA(
          isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerHeaderInvalid),
        ),
      );
      expect(
        () => _aes.open(
          key: fromHex(_key),
          nonce: fromHex(_nonce96),
          ciphertext: fromHex(_singleBlockCt),
          tag: fromHex(_tagTampered),
          aad: fromHex(''),
        ),
        throwsA(
          isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerAuthFailed),
        ),
      );
    });
  });

  group('Aes256Gcm · 缓冲区语义', () {
    test('sealDetached 每次返回独立缓冲区：改返回值不污染后续调用', () async {
      final first = await _seal(key: _key, nonce: _nonce96, plaintext: '', aad: '');
      final tagBefore = Uint8List.fromList(first.tag);
      first.tag[0] ^= 0xff;
      final second = await _seal(key: _key, nonce: _nonce96, plaintext: '', aad: '');
      expect(toHex(second.tag), toHex(tagBefore));
    });

    test('open 不修改调用方传入的 key / nonce / ciphertext / tag / aad', () async {
      final key = fromHex(_key);
      final nonce = fromHex(_nonce96);
      final ct = fromHex(_singleBlockCt);
      final tag = fromHex(_singleBlockTag);
      final aad = fromHex('');
      // 备份快照
      final keyBefore = toHex(key);
      final nonceBefore = toHex(nonce);
      final ctBefore = toHex(ct);
      final tagBefore = toHex(tag);
      final aadBefore = toHex(aad);

      await _aes.open(key: key, nonce: nonce, ciphertext: ct, tag: tag, aad: aad);

      expect(toHex(key), keyBefore);
      expect(toHex(nonce), nonceBefore);
      expect(toHex(ct), ctBefore);
      expect(toHex(tag), tagBefore);
      expect(toHex(aad), aadBefore);
    });

    test('无状态：同一输入重复计算结果一致', () async {
      for (var i = 0; i < 3; i++) {
        final d = await _seal(
          key: _key,
          nonce: _nonce96,
          plaintext: '000102030405060708090a0b0c0d0e0f',
          aad: '',
        );
        expect(toHex(d.ciphertext), _singleBlockCt);
        expect(toHex(d.tag), _singleBlockTag);
      }
    });
  });
}

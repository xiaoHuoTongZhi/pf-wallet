import 'dart:convert';
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';
import 'package:test/test.dart';

/// RFC 5869 附录 A 的已知答案（SHA-256）。
///
/// 这些常量是**逐字抄自 RFC 原文**的，不是从本实现打印出来的。
/// 抄完之后又用两套独立实现复算核对过：
///   - Python 标准库 `hmac` + `hashlib`（见 `tools/golden_vectors_gen/hkdf_sha256.py`）
///   - Python `cryptography` 的 `HMAC` / `HKDFExpand`
///
/// 为什么非要绕这一圈：HKDF 的输出没有任何冗余，错一位也是一串「看起来正常」的
/// 密钥。用实现自己产出的值当期望值，等于用「和昨天一致」冒充「和标准一致」。
const String _rfc1Ikm = '0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b';
const String _rfc1Salt = '000102030405060708090a0b0c';
const String _rfc1Info = 'f0f1f2f3f4f5f6f7f8f9';
const int _rfc1Length = 42;
const String _rfc1Prk = '077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5';
const String _rfc1Okm =
    '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865';

const String _rfc2Ikm =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f'
    '404142434445464748494a4b4c4d4e4f';
const String _rfc2Salt =
    '606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f'
    '808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f'
    'a0a1a2a3a4a5a6a7a8a9aaabacadaeaf';
const String _rfc2Info =
    'b0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecf'
    'd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeef'
    'f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff';
const int _rfc2Length = 82;
const String _rfc2Prk = '06a6b88c5853361a06104c9ceb35b45cef760014904671014a193f40c15fc244';
const String _rfc2Okm =
    'b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c'
    '59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71'
    'cc30c58179ec3e87c14c01d5c1f3434f1d87';

/// Test Case 3 的 salt 与 info 都是**零长度**（RFC 原文写作 `(0 octets)`）。
const String _rfc3Prk = '19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04';
const String _rfc3Okm =
    '8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8';

/// 向量 `kdf.hkdf.*.db-key` 的输入与期望值。
///
/// 抄自 `test_vectors/v1/hkdf_sha256.json`。在这里复刻一份是刻意的：
/// 那些用例由 `pf_testkit` 的驱动执行，而本文件要证明的是
/// 「pf_crypto 的实现自己也能算出同样的值」—— 两条独立的证据链。
///
/// info 是 `pf/db/1` 的 UTF-8 字节。方案 §A 把它定为常量，
/// 因为改这个字符串等于让所有已导出的备份都打不开。
const String _dbKeyInfoHex = '70662f64622f31';
const String _dbKeyIkHex = '4242424242424242424242424242424242424242424242424242424242424242';
const String _dbKeyPrk = 'b8f58bb59550f5bd61aa8b38d441bb5b00c05ad8c0fafea9fb82d61e55911e8b';
const String _dbKeyOkm = 'a066fff5d232662a27af2fcca1cc6b5eb05f281ebfae180627cc65eda78df52a';

/// 其余边界用例的期望值（同来源）。
const String _singleByteOkm = 'b2';

/// expand(prk1, info="", L=32) —— 即 `exact-two-blocks` 那条向量的前一块。
const String _oneBlockEmptyInfo =
    'b2a3d45126d31fb6828ef00d76c6d54e9c2bd4785e49c6ad86e327d89d0de940';
const String _crossBlockOkm = '9f5b2c3e9bb47f9e0dcf5df63b56a87bffffc843527c15cbfbb17433ca7b4ddc3e';
const String _exactTwoBlocksOkm =
    'b2a3d45126d31fb6828ef00d76c6d54e9c2bd4785e49c6ad86e327d89d0de940'
    '8eeda1cbef2b03f30e053d5be784c2ab37f5a4de412baa10f01f456e9772aae7';

const KeyExpander _hkdf = HkdfSha256.instance;

void main() {
  group('HkdfSha256 · 常量与契约', () {
    test('算法名与长度锁死', () {
      expect(_hkdf.algorithm, 'HKDF-SHA256');
      expect(HkdfSha256.length, 32);
      expect(HkdfSha256.instance.maxOutputLength, HkdfSha256.maxLength);
    });

    test('输出上限就是 RFC 5869 §2.3 的 255*HashLen', () {
      // 这个数字不是性能参数，而是构造上的硬边界：块计数器只有 1 个字节，
      // 第 256 块会让计数器回绕到 0、重复第 1 块的内容。
      expect(HkdfSha256.maxLength, 255 * HkdfSha256.length);
      expect(HkdfSha256.maxLength, 8160);
    });

    test('PRK 长度等于 SHA-256 的输出长度（与摘要层共享同一个数）', () {
      expect(HkdfSha256.length, Sha256.length);
    });
  });

  group('HkdfSha256 · RFC 5869 附录 A 已知答案', () {
    test('Test Case 1 · extract', () {
      expect(toHex(_hkdf.extract(salt: fromHex(_rfc1Salt), ikm: fromHex(_rfc1Ikm))), _rfc1Prk);
    });

    test('Test Case 2 · extract（盐 80 字节，长于 HMAC 块长）', () {
      expect(toHex(_hkdf.extract(salt: fromHex(_rfc2Salt), ikm: fromHex(_rfc2Ikm))), _rfc2Prk);
    });

    test('Test Case 3 · extract（空盐）', () {
      expect(toHex(_hkdf.extract(salt: const <int>[], ikm: fromHex(_rfc1Ikm))), _rfc3Prk);
    });

    test('Test Case 1 · expand', () {
      expect(
        toHex(_hkdf.expand(prk: fromHex(_rfc1Prk), info: fromHex(_rfc1Info), length: _rfc1Length)),
        _rfc1Okm,
      );
    });

    test('Test Case 2 · expand（L=82，需要 3 个块）', () {
      expect(
        toHex(_hkdf.expand(prk: fromHex(_rfc2Prk), info: fromHex(_rfc2Info), length: _rfc2Length)),
        _rfc2Okm,
      );
    });

    test('Test Case 3 · expand（空 info）', () {
      expect(
        toHex(_hkdf.expand(prk: fromHex(_rfc3Prk), info: const <int>[], length: _rfc1Length)),
        _rfc3Okm,
      );
    });
  });

  group('HkdfSha256 · 缺省语义（salt 与 info 的规则相反）', () {
    test('空盐与「32 个 0x00 的盐」必然同值', () {
      // RFC 5869 §2.2 规定 salt 缺省为 HashLen 个 0x00。实现里显式做了这个替换，
      // 但即使不做，HMAC 也会把短于块长的密钥补零到块长（64），两种写法同值。
      //
      // 所以这条测试**不能**证明「我们处理了缺省盐」—— 它证明的是另一件事，
      // 而这件事同样重要：两种读法给出的 PRK 完全一致，因此没有歧义可吵。
      final withEmpty = _hkdf.extract(salt: const <int>[], ikm: fromHex(_rfc1Ikm));
      final withZeros = _hkdf.extract(salt: Uint8List(HkdfSha256.length), ikm: fromHex(_rfc1Ikm));
      expect(toHex(withEmpty), toHex(withZeros));
      expect(toHex(withEmpty), _rfc3Prk);
    });

    test('空 info 与「32 个 0x00 的 info」不同值', () {
      // 与 salt 相反：info 为空就是空，没有任何缺省替换。
      // 「两者都补零」是一条很自然的错误直觉，这条测试专门挡住它。
      final emptyInfo = _hkdf.expand(prk: fromHex(_rfc1Prk), info: const <int>[], length: 32);
      final zeroInfo = _hkdf.expand(prk: fromHex(_rfc1Prk), info: Uint8List(32), length: 32);
      expect(toHex(emptyInfo), isNot(toHex(zeroInfo)));
    });

    test('空 info 与「1 个 0x00 的 info」也不同值', () {
      final emptyInfo = _hkdf.expand(prk: fromHex(_rfc1Prk), info: const <int>[], length: 32);
      final oneZero = _hkdf.expand(prk: fromHex(_rfc1Prk), info: <int>[0], length: 32);
      expect(toHex(emptyInfo), isNot(toHex(oneZero)));
    });
  });

  group('HkdfSha256 · 长度边界', () {
    test('L=1 允许，且就是第 1 块的第 1 个字节', () {
      final okm = _hkdf.expand(prk: fromHex(_rfc1Prk), info: const <int>[], length: 1);
      expect(okm.length, 1);
      expect(toHex(okm), _singleByteOkm);
    });

    test('L=33 跨块：第 2 块必须算出来，且只取头 1 个字节', () {
      final okm = _hkdf.expand(prk: fromHex(_rfc1Prk), info: fromHex(_dbKeyInfoHex), length: 33);
      expect(okm.length, 33);
      expect(toHex(okm), _crossBlockOkm);
    });

    test('L=64 恰好两块，最后一块不截断', () {
      final okm = _hkdf.expand(prk: fromHex(_rfc1Prk), info: const <int>[], length: 64);
      expect(okm.length, 64);
      expect(toHex(okm), _exactTwoBlocksOkm);
    });

    test('L=255*HashLen（8160）是允许的上限', () {
      final okm = _hkdf.expand(prk: fromHex(_rfc1Prk), info: const <int>[], length: 8160);
      expect(okm.length, 8160);
    });

    test('L 超过上限抛 RangeError（而不是截断）', () {
      // 截断会产出「看起来对、其实不是你要的那把」的密钥，
      // 而错误只在解密失败时以「密码不对」的形式出现 —— 必须直接抛。
      expect(
        () => _hkdf.expand(prk: fromHex(_rfc1Prk), info: const <int>[], length: 8161),
        throwsRangeError,
      );
      expect(
        () => _hkdf.expand(prk: fromHex(_rfc1Prk), info: const <int>[], length: 100000),
        throwsRangeError,
      );
    });

    test('L=0 抛 RangeError（零长度密钥永远是 bug，不能静默返回空）', () {
      expect(
        () => _hkdf.expand(prk: fromHex(_rfc1Prk), info: const <int>[], length: 0),
        throwsRangeError,
      );
      expect(
        () => _hkdf.expand(prk: fromHex(_rfc1Prk), info: const <int>[], length: -1),
        throwsRangeError,
      );
    });
  });

  group('HkdfSha256 · PRK 长度校验', () {
    test('PRK 不是 32 字节时抛 ArgumentError', () {
      // 最常见的触发方式是「把 IKM 当 PRK 传进来」。这类错误类型系统拦不住，
      // 结果会是一把整体偏移的密钥 —— 加密能过，换设备导入时打不开。
      for (final badLength in <int>[0, 16, 31, 33, 64]) {
        expect(
          () => _hkdf.expand(prk: Uint8List(badLength), info: const <int>[], length: 32),
          throwsArgumentError,
          reason: 'PRK 长度 $badLength 应当被拒绝',
        );
      }
    });
  });

  group('HkdfSha256 · 块拼接的前缀性质', () {
    test('短输出必然是长输出的前缀（覆盖 1、跨块、整块、上限）', () {
      // HKDF 的定义决定了这一点：T(i) 只依赖 T(i-1)，与总长度无关。
      // 这条性质比任何单点期望值都更能定位「计数器」与「截断」的 bug：
      // 若计数器从 0 起、或最后一块没截断，某些长度组合下前缀关系会立刻破裂。
      const lengths = <int>[1, 31, 32, 33, 63, 64, 65, 96, 100, 255 * 32];
      final prk = fromHex(_rfc1Prk);
      final info = fromHex(_dbKeyInfoHex);
      final full = _hkdf.expand(prk: prk, info: info, length: lengths.last);
      for (final length in lengths) {
        final shorter = _hkdf.expand(prk: prk, info: info, length: length);
        expect(
          toHex(shorter),
          toHex(full.sublist(0, length)),
          reason: 'L=$length 的输出应当等于 L=${lengths.last} 输出的前缀',
        );
      }
    });
  });

  group('HkdfSha256 · 缓冲区语义', () {
    test('每次返回新缓冲区：改动返回值不会污染后续调用', () {
      final first = _hkdf.extract(salt: const <int>[], ikm: fromHex(_rfc1Ikm));
      zeroize(first);
      expect(toHex(_hkdf.extract(salt: const <int>[], ikm: fromHex(_rfc1Ikm))), _rfc3Prk);
    });

    test('expand 返回的缓冲区同样独立', () {
      final first = _hkdf.expand(prk: fromHex(_rfc1Prk), info: const <int>[], length: 32);
      zeroize(first);
      expect(
        toHex(_hkdf.expand(prk: fromHex(_rfc1Prk), info: const <int>[], length: 32)),
        _oneBlockEmptyInfo,
      );
    });

    test('不改动调用方传入的 prk / ikm / info', () {
      // 实现内部会清零自己那份中间块；如果哪一步写成了「就地清零入参」，
      // 调用方手里的主密钥会在一次派生之后变成全零 —— 且没有任何异常。
      final prk = fromHex(_rfc1Prk);
      final info = fromHex(_dbKeyInfoHex);
      final ikm = fromHex(_rfc1Ikm);
      final prkBefore = toHex(prk);
      final infoBefore = toHex(info);
      final ikmBefore = toHex(ikm);

      _hkdf.expand(prk: prk, info: info, length: 64);
      _hkdf.extract(salt: const <int>[], ikm: ikm);

      expect(toHex(prk), prkBefore);
      expect(toHex(info), infoBefore);
      expect(toHex(ikm), ikmBefore);
    });

    test('无状态：同一输入重复计算结果一致', () {
      for (var i = 0; i < 3; i++) {
        expect(
          toHex(_hkdf.expand(prk: fromHex(_rfc2Prk), info: fromHex(_rfc2Info), length: 82)),
          _rfc2Okm,
        );
      }
    });
  });

  group('HkdfSha256 · 真实用途：MK → DBKey', () {
    test('extract 与 expand 串起来得到向量里那一串字节', () {
      // 方案 §7.4：DBKey = HKDF-SHA256(MK, salt=空, info="pf/db/1")。
      // 这条链的字节必须两侧一致 —— 因为「改主密码不动数据库」这个承诺，
      // 前提正是「重算 MK 之后这一段仍得到同一个 DBKey」。
      final prk = _hkdf.extract(salt: const <int>[], ikm: fromHex(_dbKeyIkHex));
      expect(toHex(prk), _dbKeyPrk);

      final dbKey = _hkdf.expand(prk: prk, info: fromHex(_dbKeyInfoHex), length: 32);
      expect(toHex(dbKey), _dbKeyOkm);
      expect(dbKey.length, 32);
    });

    test('info 是 UTF-8 字节，不是字符串', () {
      // 传字节而不是 String 是刻意的：一旦按「字符串」处理，
      // 不同平台/版本对编码的处理差异会让同一句话派生出不同密钥，
      // 而错误只在跨设备导入时暴露。
      expect(toHex(fromHex(_dbKeyInfoHex)), toHex(utf8.encode('pf/db/1')));
    });
  });
}

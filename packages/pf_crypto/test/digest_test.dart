import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';
import 'package:test/test.dart';

/// 已知答案测试（KAT）的期望值。
///
/// 来源与「为什么这些值可信」：
///   - 空串 / `abc` / NIST 448 位（两个分组的边界样本）/ 一百万个 `a`
///     都取自公开的 SHA-2 测试向量集（FIPS 180-4 附录与 NIST CAVP）。
///   - 本文件里的每一条都在落地前用**另一套实现**（Python `hashlib`）复算过，
///     因此它们证明的是「我们的接线对不对」，而不是「我们和昨天的自己一致」。
///
/// 这与方案 §7.6 的第一条顺序原则一致：先有独立生成的期望值，再写实现。
/// 反过来的话，实现算出什么，测试就接受什么，测试失去意义。
const String _sha256Empty = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
const String _sha256Abc = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
const String _sha256Nist448Bit = '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1';
const String _sha256MillionA = 'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0';

/// 向量 `container.digest.verify.*` 的原始输入与期望值。
///
/// 直接抄自 `test_vectors/v1/container_trailer.json`。在这里复刻一份是刻意的：
/// 那三条向量由 `pf_testkit` 的驱动执行，而本文件要证明的是
/// 「pf_crypto 自己的实现也能算出同样的值」—— 两者是独立的证据链。
const String _vectorTrailerHex =
    '00010000630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd50464246';
const String _vectorCiphertextHex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
const String _vectorComputedHex =
    '630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd';
const String _vectorTamperedCiphertextHex =
    '000102030405067f08090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
const String _vectorTamperedComputedHex =
    '8ae18d67693672a956a6652470fa17125c167d2763072565f5c782e8fe3a8885';
const String _vectorZeroDigestHex =
    '0000000000000000000000000000000000000000000000000000000000000000';
const String _vectorZeroDigestTrailerHex =
    '00010000000000000000000000000000000000000000000000000000000000000000000050464246';

void main() {
  group('Sha256 · 常量', () {
    test('算法名与长度锁死', () {
      expect(Sha256.instance.algorithm, 'SHA-256');
      expect(Sha256.instance.digestLength, 32);
      expect(Sha256.length, 32);
    });

    test('摘要长度必须与容器文件尾声明的长度一致', () {
      // 这两个数字来自两个不同的地方（摘要实现 / 容器格式），
      // 不一致时的表现是「所有备份都被判成损坏」—— 必须由测试来挡。
      expect(Sha256.length, PfbFormat.trailerDigestLength);
    });

    test('无状态：同一输入重复计算结果一致（不残留上次的中间状态）', () {
      // 摘要实现若把分块缓冲挂在实例上（或复用了上次的尾部数据），
      // 这条会在连续调用之间暴露出来 —— 而单次调用永远看不出来。
      final data = Uint8List.fromList(List<int>.generate(200, (i) => i & 0xFF));
      final first = Sha256.instance.hash(data);
      expect(Sha256.instance.hash(data), first);
      expect(Sha256.instance.hashHex(data), toHex(first));
    });
  });

  group('Sha256 · 已知答案测试', () {
    test('空输入', () {
      expect(Sha256.instance.hashHex(const <int>[]), _sha256Empty);
    });

    test('"abc"', () {
      expect(Sha256.instance.hashHex('abc'.codeUnits), _sha256Abc);
    });

    test('NIST 448 位样本（跨分组边界）', () {
      const input = 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq';
      expect(Sha256.instance.hashHex(input.codeUnits), _sha256Nist448Bit);
    });

    test('一百万个 "a"（长输入，验证分块处理）', () {
      expect(Sha256.instance.hashHex(List<int>.filled(1000000, 0x61)), _sha256MillionA);
    });

    test('返回的是新缓冲区，改写它不会污染后续调用', () {
      final first = Sha256.instance.hash(const <int>[1, 2, 3]);
      final expectedHex = toHex(first);
      zeroize(first);
      expect(toHex(first), '0000000000000000000000000000000000000000000000000000000000000000');
      expect(Sha256.instance.hashHex(const <int>[1, 2, 3]), expectedHex);
    });

    test('接受任意 List<int>，不要求 Uint8List', () {
      expect(Sha256.instance.hashHex(const <int>[0x61, 0x62, 0x63]), _sha256Abc);
    });

    test('hashHex 与 toHex(hash(...)) 一致', () {
      final data = Uint8List.fromList(List<int>.generate(257, (i) => i & 0xFF));
      expect(Sha256.instance.hashHex(data), toHex(Sha256.instance.hash(data)));
    });
  });

  group('PfbDigest.verify · 复用向量 container.digest.verify', () {
    test('密文与文件尾摘要一致 → matches', () {
      final trailer = PfbTrailer.decode(fromHex(_vectorTrailerHex));
      final verdict = PfbDigest.verify(trailer: trailer, ciphertext: fromHex(_vectorCiphertextHex));
      expect(verdict.matches, isTrue);
      expect(verdict.computedHex, _vectorComputedHex);
      expect(verdict.declaredHex, _vectorComputedHex);
    });

    test('密文被改动一个字节 → 摘要不符，且算出的摘要与向量逐字节相同', () {
      final trailer = PfbTrailer.decode(fromHex(_vectorTrailerHex));
      final verdict = PfbDigest.verify(
        trailer: trailer,
        ciphertext: fromHex(_vectorTamperedCiphertextHex),
      );
      expect(verdict.matches, isFalse);
      expect(verdict.computedHex, _vectorTamperedComputedHex);
      expect(verdict.declaredHex, _vectorComputedHex);
    });

    test('文件尾记录的摘要被改 → 摘要不符，算出的仍是对密文的摘要', () {
      final trailer = PfbTrailer.decode(fromHex(_vectorZeroDigestTrailerHex));
      final verdict = PfbDigest.verify(trailer: trailer, ciphertext: fromHex(_vectorCiphertextHex));
      expect(verdict.matches, isFalse);
      expect(verdict.computedHex, _vectorComputedHex);
      expect(verdict.declaredHex, _vectorZeroDigestHex);
    });

    test('核对结果里的两个缓冲区是副本，改写它们不会动到文件尾', () {
      final trailer = PfbTrailer.decode(fromHex(_vectorTrailerHex));
      final declaredBefore = toHex(trailer.digest);
      final verdict = PfbDigest.verify(trailer: trailer, ciphertext: fromHex(_vectorCiphertextHex));
      zeroize(verdict.computed);
      zeroize(verdict.declared);
      expect(toHex(trailer.digest), declaredBefore);
    });

    test('长度不同时判为不符（不抛异常，也不误判为相符）', () {
      final trailer = PfbTrailer.decode(fromHex(_vectorTrailerHex));
      final verdict = PfbDigest.verify(
        trailer: trailer,
        ciphertext: fromHex(_vectorCiphertextHex).sublist(1),
      );
      expect(verdict.matches, isFalse);
    });
  });
}

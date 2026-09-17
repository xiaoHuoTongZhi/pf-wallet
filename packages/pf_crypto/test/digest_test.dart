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

  group('PfbContainer.verifyContentDigest · 免密完整性（§3.3）', () {
    // 覆盖范围由向量套件 container_digest（Python 独立实现生成）锁字节；
    // 这里守行为边界：覆盖从盐到密文区末尾，固定头由 CRC 负责。
    Future<Uint8List> buildFile() => PfbContainer.seal(
      payload: Uint8List.fromList(List.generate(64, (i) => i)),
      key: Uint8List.fromList(List.generate(32, (i) => i + 1)),
      salt: Uint8List.fromList(List.generate(16, (i) => 0x10 + i)),
      noncePrefix: Uint8List.fromList(List.generate(8, (i) => 0xA0 + i)),
      kdf: Argon2Params.presetMin,
    );

    test('未改动 → matches，且声明值就是文件尾 32 字节', () async {
      final file = await buildFile();
      final verdict = PfbContainer.verifyContentDigest(file);
      expect(verdict.matches, isTrue);
      expect(verdict.declaredHex, toHex(file.sublist(file.length - 32)));
      expect(verdict.computedHex, verdict.declaredHex);
    });

    test('密文区改一字节 → 摘要不符', () async {
      final file = await buildFile();
      final before = PfbContainer.verifyContentDigest(file).computedHex;
      file[200] ^= 0x01;
      final verdict = PfbContainer.verifyContentDigest(file);
      expect(verdict.matches, isFalse);
      expect(verdict.computedHex, isNot(before));
    });

    test('固定头改一字节 → 摘要仍相符（那不是它的辖区，CRC 的才是）', () async {
      final file = await buildFile();
      file[10] ^= 0x01; // minReaderVersion，位于 0..48，不在 contentDigest 覆盖内
      final verdict = PfbContainer.verifyContentDigest(file);
      expect(verdict.matches, isTrue);
    });

    test('文件尾声明值被改 → 不符，计算值不变', () async {
      final file = await buildFile();
      final computed = PfbContainer.verifyContentDigest(file).computedHex;
      file[file.length - 1] ^= 0x01;
      final verdict = PfbContainer.verifyContentDigest(file);
      expect(verdict.matches, isFalse);
      expect(verdict.computedHex, computed);
    });
  });
}

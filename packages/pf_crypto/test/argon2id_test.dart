/// Argon2id 单元测试。
///
/// ## 证据链（两条独立）
///
/// 1. **RFC 9106 §5.3 锚点**：直接用 `DartArgon2id` 复现 RFC 的已知答案。
///    这是第三方（RFC）给出的期望值，不是本仓算出来的 —— 它证明所用的
///    纯 Dart 实现确实符合 RFC 9106。
/// 2. **契约路径的三档值**：期望值逐条抄自 `test_vectors/v1/argon2id.json`，
///    而该文件由 `tools/golden_vectors_gen/argon2id.py` 用 Python `argon2-cffi`
///    （libargon2 绑定）独立复算。这一条证明「本仓实现 == 独立实现」。
///
/// 两条合起来才闭合：只有第 1 条，说明不了「结果与别的实现一致」；
/// 只有第 2 条，说不清「两边都错到一块去」的可能性。
///
/// ## 为什么 RFC 锚点不能放进向量文件
///
/// RFC 9106 §5.3 的锚点用到 secret(K)=0x03×8 与 associated data(AD)=0x04×12，
/// 而生成向量的 argon2-cffi 25.x 的 `hash_secret_raw` **没有 K/AD 参数**，
/// 无法复现它。因此该锚点只能在本文件用 `DartArgon2id` 直接验证，
/// 而不进入 `argon2id.json`。
///
/// ## 超时
///
/// Argon2id 内存硬度是刻意的：单次派生（尤其 P_STRONG 的 256 MiB / t=3 / p=4）
/// 在本机约 0.3～1 秒，CI 上更慢。默认 30 秒超时对整组用例不够宽裕，
/// 所以在文件级放宽到 3 分钟 —— 如果真超时，那本身就是性能回归。
@Timeout(Duration(minutes: 3))
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';
import 'package:test/test.dart';

const Argon2idDeriver _kdf = Argon2idDeriver.instance;

/// 与 `test_vectors/v1/argon2id.json` 一致的固定输入。
const String _passwordHex = '636f727265637420686f727365206261747465727920737461706c65';
const String _salt16Hex = '706677616c6c657473616c7430313233';
const String _salt16AltHex = '706677616c6c657473616c7430313232'; // 末字节不同，同为 16 字节
const String _salt8Hex = '1011121314151617';
const String _salt32Hex = '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';

/// 与 `argon2id.json` 各成功用例一致的期望值（由 argon2-cffi 独立复算核对过）。
const String _defaultKey = '87c35005ac1823ce375b183ce0d40ab135c02cb3ed1bf97a8f3045c57f29fd18';
const String _strongKey = '6dc4af5dd74bccde9f83ec9588c26a8745b2dcf5ee19a1ff5cfd4ad3be5ae040';
const String _minKey = '06ba803c1ec81a96fc419982b50a38518f2db012bc8605ea1a295f49ebcf97cc';
const String _salt8Key = 'e829ba7153d8b1924c183281916f172fa17bc1ea5e36d21c162b9e2faf490a00';
const String _salt32Key = '6ed12d7d594a6ae56c7ad1725982ae0d41317bd2b239dd1e0916d913d4da0757';

Future<String> _deriveHex({
  required Argon2Params params,
  String passwordHex = _passwordHex,
  required String saltHex,
}) async {
  final key = await _kdf.derive(
    password: fromHex(passwordHex),
    salt: fromHex(saltHex),
    params: params,
  );
  return toHex(key);
}

void main() {
  group('Argon2id · 契约与常量', () {
    test('算法名固定为 Argon2id', () {
      expect(_kdf.algorithm, 'Argon2id');
    });

    test('instance 是 const 单例，无状态', () {
      expect(identical(Argon2idDeriver.instance, Argon2idDeriver.instance), isTrue);
      // const 构造会规范化为同一对象；非 const 的 Argon2idDeriver() 每次都是新实例。
      // ignore: use_named_constants
      expect(identical(const Argon2idDeriver(), Argon2idDeriver.instance), isTrue);
    });

    test('§3.2 三档预设与既有 mobile/desktop 对齐', () {
      expect(Argon2Params.presetDefault, Argon2Params.mobileDefault);
      expect(Argon2Params.presetStrong, Argon2Params.desktopDefault);
      expect(Argon2Params.presetMin.memoryKiB, 19456);
      expect(Argon2Params.presetMin.iterations, 2);
      expect(Argon2Params.presetMin.parallelism, 1);
      expect(Argon2Params.presetMin.isValid, isTrue);
    });

    test('输出长度固定 32 字节（= 256 位）', () {
      expect(Argon2Params.defaultOutputLength, 32);
      expect(Argon2Params.presetDefault.outputLength, 32);
    });
  });

  group('Argon2id · RFC 9106 §5.3 已知答案（独立锚点）', () {
    test('RFC 9106 §5.3 Argon2id 锚点逐字节命中', () async {
      // 该向量参数刻意「不合本项目产品档」（m=32 KiB），因此绕过 Argon2Params 的
      // 范围校验，直接调用 DartArgon2id —— 我们验的是「实现是否符合 RFC」，
      // 不是「参数是否符合产品约束」。
      const argon2 = DartArgon2id(parallelism: 4, memory: 32, iterations: 3, hashLength: 32);
      final secretKey = await argon2.deriveKey(
        secretKey: SecretKey(fromHex('01' * 32)), // password = 0x01 × 32
        nonce: fromHex('02' * 16), // salt = 0x02 × 16
        optionalSecret: fromHex('03' * 8), // K = 0x03 × 8
        associatedData: fromHex('04' * 12), // AD = 0x04 × 12
      );
      final tag = toHex(await secretKey.extractBytes());
      // 期望值来源：RFC 9106 原文 §5.3「Argon2id Test Vectors」的 Tag 字段
      // （https://www.rfc-editor.org/rfc/rfc9106#section-5.3），独立于任何 Dart 实现。
      expect(
        tag,
        '0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659',
        reason: 'RFC 9106 §5.3 规定 version=0x13 / m=32 / t=3 / p=4 的 Argon2id 输出必须等于此值',
      );
    });
  });

  group('Argon2id · §3.2 三档（与独立实现 argon2-cffi 一致）', () {
    test('P_DEFAULT（64 MiB / t=3 / p=1）', () async {
      expect(
        await _deriveHex(params: Argon2Params.presetDefault, saltHex: _salt16Hex),
        _defaultKey,
      );
    });

    test('P_STRONG（256 MiB / t=4 / p=4）', () async {
      expect(await _deriveHex(params: Argon2Params.presetStrong, saltHex: _salt16Hex), _strongKey);
    });

    test('P_MIN（19 MiB / t=2 / p=1）', () async {
      expect(await _deriveHex(params: Argon2Params.presetMin, saltHex: _salt16Hex), _minKey);
    });
  });

  group('Argon2id · 盐长度边界', () {
    test('盐长 8 字节（minSaltLength）', () async {
      expect(
        await _deriveHex(
          params: Argon2Params.presetDefault.copyWith(saltLength: 8),
          saltHex: _salt8Hex,
        ),
        _salt8Key,
      );
    });

    test('盐长 32 字节（非默认）', () async {
      expect(
        await _deriveHex(
          params: Argon2Params.presetDefault.copyWith(saltLength: 32),
          saltHex: _salt32Hex,
        ),
        _salt32Key,
      );
    });

    test('不同参数 ⇒ 不同输出（同一密码与盐）', () async {
      final a = await _deriveHex(params: Argon2Params.presetDefault, saltHex: _salt16Hex);
      final b = await _deriveHex(params: Argon2Params.presetStrong, saltHex: _salt16Hex);
      expect(a, isNot(b), reason: '改 m/t/p 必须改变派生结果');
    });

    test('不同盐 ⇒ 不同输出（同一密码与参数）', () async {
      final a = await _deriveHex(params: Argon2Params.presetDefault, saltHex: _salt16Hex);
      final b = await _deriveHex(params: Argon2Params.presetDefault, saltHex: _salt16AltHex);
      expect(a, isNot(b), reason: '盐必须真正参与派生');
    });
  });

  group('Argon2id · 错误分支 · 参数越界（PFB_E_KDF_PARAMS）', () {
    test('内存超上限（构造文件声明 16 GiB）⇒ kdfParamsOutOfRange', () {
      // OOM 攻击场景：文件头声明 m=16 GiB，打开瞬间榨干内存。
      expect(
        () => _kdf.derive(
          password: fromHex(_passwordHex),
          salt: fromHex(_salt16Hex),
          params: Argon2Params.presetDefault.copyWith(memoryKiB: 16777216),
        ),
        throwsA(isA<CryptoError>().having((e) => e.code, 'code', PfErrorCode.kdfParamsOutOfRange)),
      );
    });

    test('内存低于下限 ⇒ kdfParamsOutOfRange', () {
      expect(
        () => _kdf.derive(
          password: fromHex(_passwordHex),
          salt: fromHex(_salt16Hex),
          params: Argon2Params.presetDefault.copyWith(memoryKiB: 1024),
        ),
        throwsA(isA<CryptoError>().having((e) => e.code, 'code', PfErrorCode.kdfParamsOutOfRange)),
      );
    });

    test('迭代次数超上限（t=17）⇒ kdfParamsOutOfRange', () {
      expect(
        () => _kdf.derive(
          password: fromHex(_passwordHex),
          salt: fromHex(_salt16Hex),
          params: Argon2Params.presetDefault.copyWith(iterations: 17),
        ),
        throwsA(isA<CryptoError>().having((e) => e.code, 'code', PfErrorCode.kdfParamsOutOfRange)),
      );
    });

    test('并行度超上限（p=9）⇒ kdfParamsOutOfRange', () {
      expect(
        () => _kdf.derive(
          password: fromHex(_passwordHex),
          salt: fromHex(_salt16Hex),
          params: Argon2Params.presetDefault.copyWith(parallelism: 9),
        ),
        throwsA(isA<CryptoError>().having((e) => e.code, 'code', PfErrorCode.kdfParamsOutOfRange)),
      );
    });
  });

  group('Argon2id · 错误分支 · 输入契约（PFB_E_HEADER_INVALID）', () {
    test('密码为空 ⇒ headerInvalid（不是 authFailed）', () {
      expect(
        () => _kdf.derive(
          password: Uint8List(0),
          salt: fromHex(_salt16Hex),
          params: Argon2Params.presetDefault,
        ),
        throwsA(
          isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerHeaderInvalid),
        ),
      );
    });

    test('盐长度与 params.saltLength 不符 ⇒ headerInvalid', () {
      expect(
        () => _kdf.derive(
          password: fromHex(_passwordHex),
          salt: fromHex(_salt8Hex), // 8 字节，但 params 说 16
          params: Argon2Params.presetDefault,
        ),
        throwsA(
          isA<ContainerError>().having((e) => e.code, 'code', PfErrorCode.containerHeaderInvalid),
        ),
      );
    });

    test('两类失败的码必须不同（输入非法 vs 参数越界）', () {
      expect(PfErrorCode.containerHeaderInvalid, isNot(PfErrorCode.kdfParamsOutOfRange));
      expect(PfErrorCode.kdfParamsOutOfRange, 'PFB_E_KDF_PARAMS');
      expect(PfErrorCode.containerHeaderInvalid, 'PFB_E_HEADER_INVALID');
    });
  });

  group('Argon2id · 缓冲区语义与确定性', () {
    test('输出长度恒为 32 字节', () async {
      for (final p in <Argon2Params>[Argon2Params.presetDefault, Argon2Params.presetMin]) {
        final key = await _kdf.derive(
          password: fromHex(_passwordHex),
          salt: fromHex(_salt16Hex),
          params: p,
        );
        expect(key.length, 32, reason: '${p.describe()} 的输出长度应为 32');
      }
    });

    test('确定性：同一输入重复计算结果一致', () async {
      for (var i = 0; i < 2; i++) {
        expect(await _deriveHex(params: Argon2Params.presetMin, saltHex: _salt16Hex), _minKey);
      }
    });

    test('不修改调用方传入的 password / salt', () async {
      final password = fromHex(_passwordHex);
      final salt = fromHex(_salt16Hex);
      final passwordBefore = toHex(password);
      final saltBefore = toHex(salt);

      await _kdf.derive(password: password, salt: salt, params: Argon2Params.presetMin);

      expect(toHex(password), passwordBefore);
      expect(toHex(salt), saltBefore);
    });

    test('返回独立缓冲区：改返回值不污染后续调用', () async {
      final first = await _kdf.derive(
        password: fromHex(_passwordHex),
        salt: fromHex(_salt16Hex),
        params: Argon2Params.presetMin,
      );
      final expected = toHex(first);
      first[0] ^= 0xff;
      final second = await _kdf.derive(
        password: fromHex(_passwordHex),
        salt: fromHex(_salt16Hex),
        params: Argon2Params.presetMin,
      );
      expect(toHex(second), expected);
    });
  });
}

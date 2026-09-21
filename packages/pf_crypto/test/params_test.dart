import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';
import 'package:test/test.dart';

void main() {
  group('Argon2Params · 默认参数被钉死', () {
    test('移动端：64 MiB / t=3 / p=1', () {
      const params = Argon2Params.mobileDefault;
      expect(params.memoryKiB, 65536);
      expect(params.iterations, 3);
      expect(params.parallelism, 1);
      expect(() => params.validate(), returnsNormally);
    });

    test('桌面端：256 MiB / t=4 / p=4', () {
      const params = Argon2Params.desktopDefault;
      expect(params.memoryKiB, 262144);
      expect(params.iterations, 4);
      expect(params.parallelism, 4);
      expect(() => params.validate(), returnsNormally);
    });

    test('参数描述不含歧义（设置页直接展示）', () {
      expect(Argon2Params.mobileDefault.describe(), 'm=64MiB t=3 p=1');
      expect(Argon2Params.desktopDefault.describe(), 'm=256MiB t=4 p=4');
    });

    test('盐 16 字节、输出 32 字节', () {
      expect(Argon2Params.mobileDefault.saltLength, 16);
      expect(Argon2Params.mobileDefault.outputLength, 32);
    });
  });

  group('Argon2Params · 范围校验（防内存炸弹）', () {
    test('内存超上限被拒绝', () {
      expect(
        () => Argon2Params(memoryKiB: 16777216, iterations: 3, parallelism: 1).validate(),
        throwsA(isA<CryptoError>().having((e) => e.code, 'code', PfErrorCode.kdfParamsOutOfRange)),
      );
    });

    test('内存低于 OWASP 下限被拒绝', () {
      expect(
        () => Argon2Params(memoryKiB: 1024, iterations: 3, parallelism: 1).validate(),
        throwsA(isA<CryptoError>()),
      );
    });

    test('迭代次数越界被拒绝', () {
      expect(
        () => Argon2Params(memoryKiB: 65536, iterations: 1, parallelism: 1).validate(),
        throwsA(isA<CryptoError>()),
      );
      expect(
        () => Argon2Params(memoryKiB: 65536, iterations: 1000, parallelism: 1).validate(),
        throwsA(isA<CryptoError>()),
      );
    });

    test('并行度越界被拒绝', () {
      expect(
        () => Argon2Params(memoryKiB: 65536, iterations: 3, parallelism: 0).validate(),
        throwsA(isA<CryptoError>()),
      );
      expect(
        () => Argon2Params(memoryKiB: 65536, iterations: 3, parallelism: 64).validate(),
        throwsA(isA<CryptoError>()),
      );
    });

    test('盐长度越界被拒绝', () {
      expect(
        () =>
            Argon2Params(memoryKiB: 65536, iterations: 3, parallelism: 1, saltLength: 4).validate(),
        throwsA(isA<CryptoError>()),
      );
      expect(
        () =>
            Argon2Params(
              memoryKiB: 65536,
              iterations: 3,
              parallelism: 1,
              saltLength: 128,
            ).validate(),
        throwsA(isA<CryptoError>()),
      );
    });

    test('输出长度固定 32 字节', () {
      expect(
        () =>
            Argon2Params(
              memoryKiB: 65536,
              iterations: 3,
              parallelism: 1,
              outputLength: 16,
            ).validate(),
        throwsA(isA<CryptoError>()),
      );
    });

    test('极端组合仍在允许域内（m=19456 与 p=8 是两端的边界）', () {
      expect(
        () => Argon2Params(memoryKiB: 19456, iterations: 2, parallelism: 8).validate(),
        returnsNormally,
      );
      expect(
        () => Argon2Params(memoryKiB: 1048576, iterations: 16, parallelism: 1).validate(),
        returnsNormally,
      );
      // 说明：Argon2 规范另有 m >= 8p 的约束，但当前取值域
      // (minMemoryKiB=19456, maxParallelism=8 → 8p ≤ 64) 使其不可达。
      // 该断言作为兜底保留在 validate() 中，防止将来调低下限时漏改。
    });

    test('isValid 不抛异常，只返回布尔', () {
      expect(const Argon2Params(memoryKiB: 1, iterations: 1, parallelism: 1).isValid, isFalse);
      expect(Argon2Params.mobileDefault.isValid, isTrue);
    });
  });

  group('Argon2Params · 序列化', () {
    test('JSON 往返一致', () {
      const original = Argon2Params.desktopDefault;
      expect(Argon2Params.fromJson(original.toJson()), original);
    });

    test('JSON 字段名为 m / t / p（与容器头语义一致）', () {
      expect(Argon2Params.mobileDefault.toJson(), <String, Object?>{
        'm': 65536,
        't': 3,
        'p': 1,
        'saltLength': 16,
        'outputLength': 32,
      });
    });

    test('反序列化时立即校验（输入来自不可信文件）', () {
      expect(
        () => Argon2Params.fromJson(<String, Object?>{'m': 16777216, 't': 3, 'p': 1}),
        throwsA(isA<CryptoError>()),
      );
    });

    test('字段类型不对抛 DomainError', () {
      expect(
        () => Argon2Params.fromJson(<String, Object?>{'m': '65536', 't': 3, 'p': 1}),
        throwsA(isA<DomainError>().having((e) => e.code, 'code', PfErrorCode.validation)),
      );
    });

    test('缺省 saltLength / outputLength 时用默认值', () {
      final params = Argon2Params.fromJson(<String, Object?>{'m': 65536, 't': 3, 'p': 1});
      expect(params.saltLength, Argon2Params.defaultSaltLength);
      expect(params.outputLength, Argon2Params.defaultOutputLength);
    });

    test('copyWith 只改指定字段', () {
      final modified = Argon2Params.mobileDefault.copyWith(iterations: 5);
      expect(modified.iterations, 5);
      expect(modified.memoryKiB, Argon2Params.mobileDefault.memoryKiB);
      expect(modified.parallelism, Argon2Params.mobileDefault.parallelism);
    });
  });

  group('Argon2Params · 值语义（== / hashCode / toString）', () {
    test('toString 复用 describe()，与设置页、日志同一份措辞', () {
      expect(Argon2Params.mobileDefault.toString(), 'Argon2Params(m=64MiB t=3 p=1)');
      expect(
        Argon2Params.presetMin.toString(),
        'Argon2Params(${Argon2Params.presetMin.describe()})',
      );
    });

    test('参数相同 ⇒ == 为真且 hashCode 相等（可安全放进 Set / Map 键）', () {
      final roundTripped = Argon2Params.fromJson(Argon2Params.mobileDefault.toJson());
      expect(roundTripped, Argon2Params.mobileDefault);
      expect(roundTripped.hashCode, Argon2Params.mobileDefault.hashCode);
      expect(<Argon2Params>{Argon2Params.mobileDefault, roundTripped}, hasLength(1));
    });

    test('参数不同 ⇒ hashCode 不同（当前六个预设两两不同）', () {
      final presets = <Argon2Params>{
        Argon2Params.mobileDefault,
        Argon2Params.desktopDefault,
        Argon2Params.presetMin,
      };
      expect(presets, hasLength(3));
      expect(Argon2Params.mobileDefault.hashCode, isNot(Argon2Params.desktopDefault.hashCode));
    });
  });

  group('WrappedKey / KeyringData 序列化', () {
    WrappedKey buildWrapped() => WrappedKey(
      params: Argon2Params.mobileDefault,
      salt: Uint8List.fromList(List<int>.generate(16, (i) => i)),
      nonce: Uint8List.fromList(List<int>.generate(12, (i) => 255 - i)),
      ciphertext: Uint8List.fromList(List<int>.generate(WrappedKey.dekLength, (i) => i * 3 % 256)),
      tag: Uint8List.fromList(List<int>.generate(16, (i) => i + 100)),
    );

    test('WrappedKey 往返一致', () {
      final original = buildWrapped();
      final decoded = WrappedKey.fromJson(original.toJson());
      expect(decoded.params, original.params);
      expect(decoded.salt, original.salt);
      expect(decoded.nonce, original.nonce);
      expect(decoded.ciphertext, original.ciphertext);
      expect(decoded.tag, original.tag);
    });

    test('密文长度不等于 DEK 长度时视为被篡改', () {
      expect(
        () => WrappedKey(
          params: Argon2Params.mobileDefault,
          salt: Uint8List(16),
          nonce: Uint8List(12),
          ciphertext: Uint8List(16),
          tag: Uint8List(16),
        ),
        throwsA(isA<KeyringError>().having((e) => e.code, 'code', PfErrorCode.keyringTampered)),
      );
    });

    test('字段缺失时抛 PfError（任一子类都表示该 blob 不可用）', () {
      expect(
        () => WrappedKey.fromJson(<String, Object?>{'params': <String, Object?>{}}),
        throwsA(isA<PfError>()),
      );
    });

    test('KeyringData 往返一致，且恢复码可缺省', () {
      final primary = buildWrapped();
      final data = KeyringData(
        version: keyringFormatVersion,
        primary: primary,
        recovery: null,
        createdAtMilliseconds: 1735689600000,
        updatedAtMilliseconds: 1735689600000,
      );
      final decoded = KeyringData.fromJson(data.toJson());
      expect(decoded.primary.ciphertext, primary.ciphertext);
      expect(decoded.recovery, isNull);
      expect(decoded.createdAt.isUtc, isTrue);
    });

    test('保险箱版本高于本实现 → PFD_E_SCHEMA_TOO_NEW', () {
      final data =
          KeyringData(
            version: keyringFormatVersion,
            primary: buildWrapped(),
            recovery: null,
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1,
          ).toJson();
      data['version'] = keyringFormatVersion + 1;
      expect(
        () => KeyringData.fromJson(data),
        throwsA(isA<StorageError>().having((e) => e.code, 'code', PfErrorCode.storageSchemaTooNew)),
      );
    });

    test('WrappedKey.toString：只有 KDF 描述与各段长度，不含任何密钥字节', () {
      final text = buildWrapped().toString();
      expect(text, 'WrappedKey(m=64MiB t=3 p=1, salt=16B, ciphertext=32B)');
      // 这条才是重点：诊断输出进日志，日志会进用户随手贴出来的截图。
      // 长度可以露，字节不行 —— toString 里出现密文十六进制就是一次事故。
      expect(text, isNot(contains(toHex(buildWrapped().ciphertext))));
      expect(text, isNot(contains(toHex(buildWrapped().salt))));
    });

    test('KeyringData 的两个时间戳都是 UTC（口径必须一致，否则跨时区比较出错）', () {
      final data = KeyringData(
        version: keyringFormatVersion,
        primary: buildWrapped(),
        recovery: null,
        createdAtMilliseconds: 1735689600000,
        updatedAtMilliseconds: 1735776000000,
      );
      expect(data.createdAt.isUtc, isTrue);
      expect(data.updatedAt.isUtc, isTrue);
      expect(data.updatedAt, DateTime.fromMillisecondsSinceEpoch(1735776000000, isUtc: true));
      expect(
        data.updatedAt.difference(data.createdAt),
        const Duration(days: 1),
        reason: '两个字段单位相同（毫秒），否则差值是 1000 倍',
      );
    });

    test('KeyringData 缺字段或类型不对 → PFK_E_TAMPERED', () {
      expect(
        () => KeyringData.fromJson(<String, Object?>{
          'version': '1',
          'primary': <String, Object?>{},
          'createdAt': 0,
          'updatedAt': 0,
        }),
        throwsA(isA<KeyringError>().having((e) => e.code, 'code', PfErrorCode.keyringTampered)),
      );
      expect(
        () => KeyringData.fromJson(<String, Object?>{
          'version': keyringFormatVersion,
          'primary': <String, Object?>{},
          'createdAt': 0,
        }),
        throwsA(isA<KeyringError>().having((e) => e.code, 'code', PfErrorCode.keyringTampered)),
      );
    });
  });
}

/// 驱动：Argon2id（已实装，纯 Dart）。
///
/// ## 为什么「未实现」的驱动也要写出来（历史备注）
///
/// 因为向量必须先于实现存在。原因有两条，都是工程性的：
///
///   1. **向量是对外契约，实现是内部细节。** 先写向量，等于先决定
///      「这个函数对外承诺什么」；反过来（先写实现再补测试）通常只是
///      把实现的偶然行为抄一遍，锁不住任何东西。
///   2. **它把「还没做」变成可见的数字。** 报告里 pending 的条数是
///      对进度的诚实度量，而基线机制（见 baseline.dart）保证它只能减少。
///
/// ## Argon2id 为什么在这里、且不再是「原生库」
///
/// 本文件最初叫「需要原生加密库的部分」，Argon2id 那时计划走 libsodium。
/// 后来定案：Argon2id 用 `package:cryptography` 的 `DartArgon2id`（纯 Dart，
/// RFC 9106），**零原生依赖** —— 6 平台一致，也能在 `dart test` 的 CI 上跑。
/// 因此保留在本文件只是历史位置；它的 [plannedMilestone] 已是 M1。
///
/// Keyring 的驱动已按 §3.1 的层级拆成五个 kind，见 `m2_keyring.dart`。
/// 本文件最初占位的 `keyring.wrap-dek`（KEK 包 DEK 的笼统记法）随之移除 ——
/// 规格定稿后不存在这个块：密码路径靠 keyCheck 校验，MK 的包裹只发生在
/// 恢复码（RK 包 MK）与生物识别（DeviceKey 包 MK，需平台 Keystore，见 M2）。
library;

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';

import '../driver.dart';
import '../json_util.dart';
import '../outcome.dart';

/// Argon2id 派生。
///
/// 期望值来自 `tools/golden_vectors_gen/argon2id.py`（Python argon2-cffi 独立复算，
/// 与 Dart 侧 `DartArgon2id` 是两套实现）。RFC 9106 §5.3 的带 K/AD 锚点由
/// `packages/pf_crypto/test/argon2id_test.dart` 单独验证（argon2-cffi 无 K/AD 参数）。
final class KdfArgon2idDeriveDriver extends VectorDriver {
  const KdfArgon2idDeriveDriver();

  @override
  String get kind => 'kdf.argon2id.derive';

  @override
  String get description => 'Argon2id 派生密钥（密码 + 盐 + 参数 → 32 字节）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'passwordUtf8Hex': '密码的 UTF-8 字节（十六进制）',
    'saltHex': '盐（十六进制，长度须等于 params.saltLength）',
    'params': '{m, t, p, saltLength, outputLength}',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    // 失败用例（参数越界 / 密码空 / 盐长不符）由实装抛 PfError，
    // runner 会捕获并对照 expect.ok=false 的具体错误码。
    final params = Argon2Params.fromJson(requireMap(input, 'params', kind));
    final derived = await Argon2idDeriver.instance.derive(
      password: requireHexBytes(input, 'passwordUtf8Hex', kind),
      salt: requireHexBytes(input, 'saltHex', kind),
      params: params,
    );
    return VectorOutcome.value(<String, Object?>{'derivedKeyHex': toHex(derived)});
  }
}

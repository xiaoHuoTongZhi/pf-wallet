/// Argon2id 实装（M1 原语层）。
///
/// ## 算法从哪来
///
/// 方案 §1.5 钉死：Argon2id 走纯 Dart 的 `package:cryptography`，具体是其中的
/// [DartArgon2id]。注意它**只在 `package:cryptography/dart.dart` 导出**，
/// 主库 `cryptography.dart` 不导出 —— 所以本文件要单独 import 那个库。
///
/// 不引入 `sodium` / `libsodium`：那是一个 Flutter 插件，需要每个端准备
/// 原生二进制并调用 `SodiumInit.init()`，既无法在纯 Dart 的 `dart test` CI
/// 上跑（gate2 三平台），也违背 §1.5「纯 Dart 优先、能进 CI」的原则。
/// [DartArgon2id] 是 RFC 9106 的纯 Dart 实现，6 个平台与 CI 三平台行为完全一致。
/// Plan B 若某平台不可用，同样纯 Dart 的 `hashlib` 可作替代（无原生依赖）。
///
/// ## 后台 isolate
///
/// 大内存参数下 [DartArgon2id] 会自动在后台 isolate 计算（见
/// `argon2_impl_default.dart` 的 `isolateCount`：内存够大时就 spawn worker
/// isolate，跑在 native 缓冲区上），满足 [KeyDeriver] 契约「绝不在 UI isolate
/// 跑派生」的要求；小内存（如 RFC 锚点 32 KiB）则原地算，同样确定。
/// 调用方仍应按契约在需要时用 `Future` 异步等待，不要阻塞 UI。
///
/// ## 与 RFC 9106 的一致性点
///
///   - 版本号固定 `0x13`（[DartArgon2State] 默认 19）。
///   - 内存单位 KiB：`memory` 直接透传 [Argon2Params.memoryKiB]，不改写。
///   - `m` / `t` / `p` 与输出长度全部来自 [Argon2Params]，本文件不做任何
///     重新解释或「按平台调整」。
///   - 盐即 Argon2 的 nonce；密码即 secretKey（Argon2 的命名反了：password
///     在它 API 里叫 `secretKey`，salt 叫 `nonce`）。本项目不使用 K / AD 字段。
///
/// ## 错误分支（必须各自独立、可被单测命中）
///
///   - 参数越界 → [CryptoError.kdfParamsOutOfRange]（[Argon2Params.validate] 抛，
///     码 `PFB_E_KDF_PARAMS`）。导入文件时这是不可信输入的第一道闸：一个把
///     `m` 写成 16 GiB 的文件，会让受害设备打开瞬间 OOM。
///   - 密码为空 → [ContainerError.headerInvalid]（码 `PFB_E_HEADER_INVALID`）。
///     输入契约破坏，不是派生失败。
///   - 盐长度与参数记录的 `saltLength` 不符 → 同上。salt 长度是文件头承诺的
///     契约，调用方传进来的盐必须对齐，否则属于调用错误而非密码错误。
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:pf_core/pf_core.dart';

import 'argon2_params.dart';
import 'kdf.dart';

/// Argon2id 实装。
///
/// 单例 [instance] 供驱动与上层引用；实现本身无状态。
final class Argon2idDeriver implements KeyDeriver {
  const Argon2idDeriver();

  /// 默认实例。
  static const Argon2idDeriver instance = Argon2idDeriver();

  @override
  String get algorithm => 'Argon2id';

  @override
  Future<Uint8List> derive({
    required Uint8List password,
    required Uint8List salt,
    required Argon2Params params,
  }) async {
    // 1) 参数越界先卡死（导入文件时这是不可信输入的第一道闸）。
    params.validate();
    // 2) 输入契约：密码不得为空。
    if (password.isEmpty) {
      throw ContainerError.headerInvalid(detail: 'Argon2id 密码不得为空');
    }
    // 3) 输入契约：盐长度必须与参数里记录的 saltLength 一致。
    if (salt.length != params.saltLength) {
      throw ContainerError.headerInvalid(
        detail: 'Argon2id 盐长度必须为 ${params.saltLength} 字节，实际 ${salt.length} 字节',
      );
    }

    final argon2 = DartArgon2id(
      parallelism: params.parallelism,
      memory: params.memoryKiB,
      iterations: params.iterations,
      hashLength: params.outputLength,
    );
    final secretKey = await argon2.deriveKey(secretKey: SecretKey(password), nonce: salt);
    return Uint8List.fromList(await secretKey.extractBytes());
  }
}

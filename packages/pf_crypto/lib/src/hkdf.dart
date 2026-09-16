/// 密钥扩展原语：HKDF-SHA256（RFC 5869）。
///
/// ## 它在本项目里解决什么
///
/// 主密码经 Argon2id 派生出的主密钥 MK，**不能**直接当数据库密钥用。
/// 一把钥匙开一把锁；MK 被用来开多把锁（DBKey、附件 KEK、生物识别包裹密钥），
/// 直接复用同一串字节意味着其中任何一处泄漏都等于全部泄漏，
/// 而且无法在不重加密数据库的前提下更换其中一把。
///
/// 方案 §7.4 据此定下 `DBKey = HKDF(MK, info = "pf/db/1")`：
/// 改主密码只需重算 MK 之后的这一段，DBKey 不变，
/// 数据库文件一个字节都不用动 —— 这正是「分用途派生」换来的可维护性。
///
/// ## 为什么可以自己拼，而 Argon2id 必须用现成实现
///
/// 本仓的红线是「不手写密码学**原语**」，不是因为手写丢人，
/// 而是因为原语（分组密码、置换、压缩函数）的正确性无法靠阅读代码判断：
/// 一个 S 盒写错一位，输出依然是均匀随机的，只有官方向量能发现。
///
/// HKDF 不属于这一类。RFC 5869 把它的全部内容写成了两行：
///
///     PRK = HMAC-Hash(salt, IKM)                                    … §2.2
///     T(i) = HMAC-Hash(PRK, T(i-1) | info | i)      OKM = T(1)|…|T(N) … §2.3
///
/// 真正的原语（HMAC-SHA256）仍然来自经过评审的 `package:crypto`，本文件没有
/// 实现任何压缩函数或轮函数，只是按 RFC 规定的顺序把两次 HMAC 调用串起来。
/// 换句话说：这里手写的是**构造**，不是原语。
///
/// 反过来说，选它作为 M1 的第二个原语还有一个更硬的理由 ——
/// **它现在就有独立期望值可依**。RFC 5869 附录 A 给了三组官方向量，
/// `tools/golden_vectors_gen/hkdf_sha256.py` 用 Python 标准库复算过，
/// 再与 `cryptography` 的实现交叉核对。先有期望值，再有实现。
///
/// ## 与 `package:cryptography` 的关系（读之前先看这段，免得重复讨论）
///
/// 方案 §1.5 把 `cryptography` 列为「AES-256-GCM / HKDF-SHA256」的来源。
/// 本文件**没有**用它，理由有两条，都是这次动手时才看清楚的：
///
///   1. `cryptography` 的 `HKDF` 是**一步到底**的（内部先 extract 再 expand），
///      公开 API 里没有「只做 extract」的入口。而本项目需要能分别调用两步 ——
///      `DBKey = expand(prk, info)` 里的 `prk` 必须能单独拿出来核对，
///      否则「PRK 错、expand 也一致地把错误传下去」这类 bug 无法定位。
///      要用它就得退回到自己调 HMAC，那还不如从一开始就走 HMAC。
///   2. `cryptography` 会引入 `ffi` 等传递依赖，而它真正不可替代的能力是
///      **AES-GCM**（`package:crypto` 没有任何分组密码）。
///      把它留到 AES-GCM 那一步再引入，可以让本次提交的依赖面变化为零：
///      一旦锁文件与代码同时变动，出问题时没人能一眼分辨是谁的错。
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pf_core/pf_core.dart';

/// 密钥扩展（HKDF）契约。
///
/// 与 [KeyDeriver] 分开定义，是因为两者回答的问题不同：
///   - [KeyDeriver]：**慢**派生，把低熵的密码变成高熵密钥（Argon2id）
///   - [KeyExpander]：**快**扩展，把高熵密钥拆成多个用途密钥（HKDF）
///
/// 合成一个接口会诱导出「用 Argon2id 做每次派生」这种既慢又无增益的写法。
abstract interface class KeyExpander {
  /// 算法标识，用于诊断与日志。
  ///
  /// **不用于序列化**：写进容器头的是数值 ID —— 与 [Digest.algorithm] 的理由相同，
  /// 名字给人看、数字给格式看。
  String get algorithm;

  /// 单次调用允许的最大输出长度（RFC 5869 §2.3 的 `255*HashLen`）。
  ///
  /// 超过它必须**抛错**而不是截断：截断会产生一把「看起来对、实际不是你要的那把」
  /// 的密钥，而这种错误只会在解密失败时以「密码不对」的形式出现。
  int get maxOutputLength;

  /// 提取阶段：把输入密钥材料压成固定长度的 [prk]。
  ///
  /// RFC 5869 §2.2 原文对 salt 的规定是：
  /// 「optional salt value (a non-secret random value);
  ///   if not provided, it is set to a string of HashLen zeros.」
  /// 因此 [salt] 传空表示「未提供」，实现必须按 HashLen 个 `0x00` 处理。
  ///
  /// [ikm] 是**秘密**，故用 [Uint8List]（可变缓冲区）：调用方在完成派生后
  /// 应当立刻 `zeroize`。签名刻意不接受 `String`，理由同 [KeyDeriver.derive] ——
  /// Dart 的 String 无法清零，不接受 String 就是不给「把密码复制进堆里」的机会。
  ///
  /// [salt] 不是秘密（RFC 明说不必随机），故用 `List<int>`：
  /// 让签名本身区分「需要清零的」与「不需要的」，比在注释里写清楚更可靠。
  Uint8List extract({required List<int> salt, required Uint8List ikm});

  /// 扩展阶段：把 [prk] 扩展成 [length] 字节的输出密钥材料。
  ///
  /// [info] 是用途标签（方案 §A 的 `pf/db/1` 等），**公开且必须确定**：
  /// 改标签 = 已导出的备份全部解不开，因此它属于格式契约而不是文案。
  ///
  /// 注意 [info] 为空就是**空**，不做任何填充 —— 这一点与 [salt] 的缺省语义相反。
  /// 把两者都按「补零」处理是一条很自然的错误直觉，故在 [HkdfSha256.extract]
  /// 与 [HkdfSha256.expand] 的文档里各写了一遍。
  ///
  /// 抛错（都是**编程错误**，不是用户可见的失败）：
  ///   - [length] <= 0 或 > [maxOutputLength] → [RangeError]
  ///   - [prk] 长度不等于 HashLen → [ArgumentError]
  ///
  /// 之所以用 Dart 核心错误而不是 [PfError]：这两个条件都不可能由用户输入触发
  /// （长度与 PRK 都由本仓代码决定），用户对它们也无从下手。
  /// 给它们编一个用户可读的提示语，只会让「错误码是契约」这条规则变松。
  Uint8List expand({required Uint8List prk, required List<int> info, required int length});
}

/// HKDF-SHA256。
final class HkdfSha256 implements KeyExpander {
  /// 无状态，复用同一实例即可。
  const HkdfSha256();

  /// 单例，便于在默认参数与注解里引用。
  static const HkdfSha256 instance = HkdfSha256();

  /// SHA-256 的输出长度（字节）。也是 PRK 的固定长度。
  static const int length = 32;

  /// RFC 5869 §2.3 的上限：`255 * HashLen` = 8160 字节。
  ///
  /// 这个数字不是「性能考虑」，而是构造上的硬边界：
  /// 块计数器只占 1 个字节，第 256 块会让计数器回绕到 0，
  /// 从而重复第 1 块的内容 —— 输出会变短一块的量而毫无征兆。
  static const int maxLength = 255 * length;

  @override
  String get algorithm => 'HKDF-SHA256';

  @override
  int get maxOutputLength => maxLength;

  /// RFC 5869 §2.2。
  @override
  Uint8List extract({required List<int> salt, required Uint8List ikm}) {
    // salt 为空 → 按 RFC 取 HashLen 个 0x00。
    //
    // 这里显式写出来，而不是依赖「HMAC 会把短密钥补零到块长」这个巧合：
    // 两者结果确实相同（32 与 0 都短于块长 64，补位后都是 64 个 0），
    // 但显式替换让读代码的人不必知道 HMAC 的补位规则就能确认语义正确。
    // 靠巧合正确的代码，会在有人换掉 HMAC 实现的那天悄悄出错。
    final effectiveSalt = salt.isEmpty ? Uint8List(length) : salt;
    return _hmac(effectiveSalt, ikm);
  }

  /// RFC 5869 §2.3。
  @override
  Uint8List expand({required Uint8List prk, required List<int> info, required int length}) {
    if (prk.length != HkdfSha256.length) {
      // 最常见的触发方式是「把 IKM 当 PRK 传进来」。这类错误不会被类型系统拦住，
      // 但会让派生结果整体偏移 —— 加密的库换个密码也打不开，且原因极难追查。
      throw ArgumentError.value(
        prk.length,
        'prk',
        'PRK 必须恰好 ${HkdfSha256.length} 字节（RFC 5869 §2.2：PRK 长度等于 HashLen）',
      );
    }
    if (length <= 0) {
      throw RangeError.range(length, 1, maxLength, 'length', 'HKDF 输出长度必须为正');
    }
    if (length > maxLength) {
      throw RangeError.range(
        length,
        1,
        maxLength,
        'length',
        'HKDF 输出长度不得超过 255*HashLen = $maxLength（RFC 5869 §2.3）',
      );
    }

    // 块计数从 1 起（不是 0），上一块初始为**空**（不是全零）。
    // 这两点是 HKDF 最常被写错的地方，且 L<=32 的用例都发现不了，
    // 所以 test_vectors/v1/hkdf_sha256.json 里特意放了 L=33 与 L=64 两条。
    final blockCount = (length + HkdfSha256.length - 1) ~/ HkdfSha256.length;
    final output = Uint8List(length);
    var previous = Uint8List(0);
    var written = 0;

    for (var counter = 1; counter <= blockCount; counter++) {
      final input =
          Uint8List(previous.length + info.length + 1)
            ..setRange(0, previous.length, previous)
            ..setRange(previous.length, previous.length + info.length, info)
            ..[previous.length + info.length] = counter;

      final block = _hmac(prk, input);
      zeroize(input); // 输入里含上一块（密钥材料），用完即清

      final take = block.length < length - written ? block.length : length - written;
      output.setRange(written, written + take, block);
      written += take;

      previous = block;
    }

    // 最后一块（若被截断则只有它的前缀进入 output）仍是密钥材料，尽力清零。
    // 能力边界与 pf_core 的 zeroize 一致：只对可变缓冲区有效，不夸大。
    if (written > 0) zeroize(previous);

    return output;
  }

  /// HMAC-SHA256。
  ///
  /// 原语来自 `package:crypto`（与 [Digest] 同源），本文件不实现任何轮函数。
  /// 返回值一律是新缓冲区：调用方（如 [expand] 的调用点）需要能安全地清零它，
  /// 而底层实现可能复用内部状态。
  static Uint8List _hmac(List<int> key, List<int> data) =>
      Uint8List.fromList(crypto.Hmac(crypto.sha256, key).convert(data).bytes);

  @override
  String toString() => 'HkdfSha256()';
}

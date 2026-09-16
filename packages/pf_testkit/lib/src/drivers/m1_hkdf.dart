/// M1 驱动：HKDF-SHA256 密钥扩展。
///
/// ## 这一组向量守的是「密钥不兼容」这种最难查的事故
///
/// HKDF 的输出没有冗余、没有结构，**错一位也依然是一串看起来完全正常的密钥**。
/// 因此它的错误不会在本地暴露，只会在「换一台设备导入备份」时表现为
/// 「密码明明是对的，却打不开」。到那时能提供的线索只有一个「打不开」。
///
/// 所以这里的期望值不能来自本仓实现 —— 它们来自 RFC 5869 附录 A 的官方向量，
/// 由 `tools/golden_vectors_gen/hkdf_sha256.py` 用 Python 标准库独立复算、
/// 再用 `cryptography` 交叉核对后落盘。
///
/// ## 为什么 extract 与 expand 分成两个 kind
///
/// 因为「PRK 错」与「expand 错」的排查路径完全不同，而只测端到端输出时两者
/// 会混成同一个现象。分开之后：extract 红 → 问题在 HMAC 那一步；
/// extract 绿而 expand 红 → 问题在计数器 / 块拼接 / 截断。
library;

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';

import '../driver.dart';
import '../json_util.dart';
import '../outcome.dart';

/// 默认使用的扩展器。驱动不构造实现，只引用契约 ——
/// 这样「换一个 HKDF 实现」不需要改向量，只需要改这里的默认值。
const KeyExpander _defaultExpander = HkdfSha256.instance;

/// RFC 5869 §2.2 · 提取阶段。
final class HkdfExtractDriver extends VectorDriver {
  const HkdfExtractDriver();

  @override
  String get kind => 'kdf.hkdf.extract';

  @override
  String get description => 'HKDF-SHA256 提取阶段：HMAC(salt, ikm) → 32 字节 PRK';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'saltHex': '盐（十六进制，允许空串表示「未提供」，此时按 RFC 取 32 个 0x00）',
    'ikmHex': '输入密钥材料（十六进制）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final prk = _defaultExpander.extract(
      salt: requireHexBytes(input, 'saltHex', kind),
      ikm: requireHexBytes(input, 'ikmHex', kind),
    );
    return VectorOutcome.value(<String, Object?>{
      'prkHex': toHex(prk),
      'prkLength': prk.length,
      'algorithm': _defaultExpander.algorithm,
    });
  }
}

/// RFC 5869 §2.3 · 扩展阶段。
final class HkdfExpandDriver extends VectorDriver {
  const HkdfExpandDriver();

  @override
  String get kind => 'kdf.hkdf.expand';

  @override
  String get description => 'HKDF-SHA256 扩展阶段：把 PRK 扩展成指定长度的输出';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'prkHex': '32 字节 PRK（十六进制）',
    'infoHex': '用途标签（十六进制，允许空串；空就是空，不补零）',
    'length': 'int，输出字节数（1 .. 255*32）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final length = requireInt(input, 'length', kind);
    final okm = _defaultExpander.expand(
      prk: requireHexBytes(input, 'prkHex', kind),
      info: requireHexBytes(input, 'infoHex', kind),
      length: length,
    );
    // `blocks` 是纯算术的诊断字段（不是语义分支）：它把「跨了几块」显式写进报告，
    // 否则 L=33 与 L=64 的差别只能靠人去数十六进制字符。
    final blocks = (length + HkdfSha256.length - 1) ~/ HkdfSha256.length;
    return VectorOutcome.value(<String, Object?>{
      'okmHex': toHex(okm),
      'okmLength': okm.length,
      'blocks': blocks,
    });
  }
}

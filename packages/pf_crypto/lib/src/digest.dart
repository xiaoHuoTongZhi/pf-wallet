/// 摘要算法原语。
///
/// ## 这一层解决什么问题
///
/// 「摘要」在本项目里出现在三处，而且必须是**同一个算法、同一份实现**：
///   - 容器文件尾：对**密文段**算摘要，用于在**没有密码**的情况下判断文件是否损坏
///   - 内容指纹：导入合并时比对内容版本（见 `pf_io`）
///   - 报告指纹：CI 关卡 3 的判定摘要（见 `pf_testkit`）
///
/// 如果每个调用点各自引入第三方库，那么「换一个摘要算法」就会退化成
/// 一次跨目录的文本搜索 —— 而漏掉的那一处不会有任何编译错误，
/// 它只会在某天以一个语义已经不对、但功能看起来仍然正常的摘要形式存在。
/// 这正是 README 第三条红线（**加密只有一份实现**）要防的东西。
///
/// 所以本层只回答两件事：**算法标识**与**输出长度**。
/// 算法本身来自经过评审的依赖（见 `pubspec.yaml`），不在本仓手写 ——
/// 手写密码学原语是本项目明确不做的取舍。
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pf_core/pf_core.dart';

/// 摘要算法契约。
///
/// 与 [Aead]、[KeyDeriver] 一样，接口在这里、实现独立成类。
/// 理由是同一个：将来「换摘要算法」必须是一次**看得见的**修改。
abstract interface class Digest {
  /// 人类可读的算法名，用于诊断与日志。
  ///
  /// **不用于序列化**：写进容器文件尾的是数值 ID（见 `PfbAlgorithm.digestSha256`）。
  /// 名字给人看、数字给格式看，混用会让二进制格式跟着文案一起漂移。
  String get algorithm;

  /// 摘要长度（字节）。
  int get digestLength;

  /// 计算摘要。返回长度恰为 [digestLength] 的新缓冲区。
  Uint8List hash(List<int> data);

  /// 计算摘要并编码为小写十六进制。
  String hashHex(List<int> data);
}

/// SHA-256。
///
/// ## 为什么是它
///
/// 不是因为「最安全」—— 抗长度扩展而言 SHA-512/256 更好；但长度扩展
/// 在本项目的用法里不构成威胁（摘要只用于完整性判断，从不当作 MAC 使用），
/// 而 SHA-256 **已经被容器格式钉死在文件尾那 32 个字节里**（`PFB1` 的
/// 摘要算法 ID = 1，已发布的备份文件改不动）。换算法只能追加新 ID。
final class Sha256 implements Digest {
  /// 无状态，复用同一实例即可。
  const Sha256();

  /// 单例，便于在默认参数与注解里引用。
  static const Sha256 instance = Sha256();

  /// 摘要长度：32 字节。与 `PfbFormat.trailerDigestLength` 必须一致。
  static const int length = 32;

  @override
  String get algorithm => 'SHA-256';

  @override
  int get digestLength => length;

  /// 每次都返回**新**缓冲区，而不是依赖底层实现复用内部状态。
  /// 调用方（例如 zeroize）需要能安全地改写返回值。
  @override
  Uint8List hash(List<int> data) => Uint8List.fromList(crypto.sha256.convert(data).bytes);

  @override
  String hashHex(List<int> data) => toHex(hash(data));

  @override
  String toString() => 'Sha256()';
}

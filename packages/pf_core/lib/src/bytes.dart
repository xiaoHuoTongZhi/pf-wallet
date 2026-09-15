/// 字节序列工具：十六进制编解码、恒定时间比较、缓冲区清零。
///
/// 为什么这些基础函数放在领域层而不是加密层：
/// 数据层（校验和、指纹）与测试工具（黄金向量的十六进制表示）都要用它们，
/// 而它们本身不含任何算法选择 —— 只是「怎么表示字节」。
library;

import 'dart:typed_data';

const String _hexAlphabet = '0123456789abcdef';

/// 编码为小写十六进制字符串。
///
/// 非法字节（不在 0..255）直接抛错，而不是静默截断 ——
/// 静默截断会让「密钥被改了」这种事故以「校验随机失败」的形式出现。
String toHex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    if (byte < 0 || byte > 0xFF) {
      throw ArgumentError.value(byte, 'bytes', '字节必须在 0..255 范围内');
    }
    buffer
      ..write(_hexAlphabet[(byte >> 4) & 0x0F])
      ..write(_hexAlphabet[byte & 0x0F]);
  }
  return buffer.toString();
}

/// 解码十六进制字符串（忽略大小写，允许 `0x` 前缀）。
Uint8List fromHex(String input) {
  var text = input;
  if (text.startsWith('0x') || text.startsWith('0X')) {
    text = text.substring(2);
  }
  if (text.length.isOdd) {
    throw FormatException('十六进制字符串长度必须为偶数', input);
  }
  final result = Uint8List(text.length ~/ 2);
  for (var i = 0; i < result.length; i++) {
    final high = _nibbleAt(text.codeUnitAt(i * 2));
    final low = _nibbleAt(text.codeUnitAt(i * 2 + 1));
    result[i] = ((high << 4) | low) & 0xFF;
  }
  return result;
}

/// 恒定时间比较。
///
/// 用于比较认证标签、校验值等秘密相关数据。
/// 普通的 `==` 会在第一个不同字节处提前返回，攻击者可通过计时差异逐字节还原。
///
/// 注意：长度不等时立即返回 false。长度的差异本身会泄漏信息，
/// 因此调用方不要把「长度」当作秘密 —— 在本项目中所有被比较对象长度固定。
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

/// 尽力清零。
///
/// 能力边界（必须明确，不夸大）：
///   - 只对 [Uint8List] 这类可变缓冲区有效。
///   - Dart 的 `String` 不可变，无法清零。因此密码一旦以 String 形式存在，
///     它的副本就会一直留在堆里，直到 GC 回收。这一点无法通过任何 Dart 层技巧绕开。
///     真正的缓解手段是：设置页/解锁页不做任何字符串拼接，密码直接进入
///     `utf8.encode` 并尽快丢弃原引用 —— 但**不能声称已经清零**。
void zeroize(List<int> buffer) {
  for (var i = 0; i < buffer.length; i++) {
    buffer[i] = 0;
  }
}

int _nibbleAt(int codeUnit) {
  // 0-9
  if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30;
  // a-f
  if (codeUnit >= 0x61 && codeUnit <= 0x66) return codeUnit - 0x61 + 10;
  // A-F
  if (codeUnit >= 0x41 && codeUnit <= 0x46) return codeUnit - 0x41 + 10;
  throw FormatException('非法的十六进制字符: "${String.fromCharCode(codeUnit)}"');
}

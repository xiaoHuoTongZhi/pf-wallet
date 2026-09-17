/// CRC-32（IEEE 802.3，与 zlib.crc32 一致）。
///
/// PFB 容器头部的 `headerCrc32` 用它计算。规格 §3.3 明确写
/// 「CRC32(偏移 0..43)」，附录 C 的 Python 参考实现用 `zlib.crc32` ——
/// 两者是同一个算法（反射输入/输出、多项式 0xEDB88320、初值与终值异或全 1），
/// 本实现只保证与 zlib 逐字节一致，用已知答案测试钉死：
/// `crc32("123456789") == 0xCBF43926`。
///
/// 为什么不引第三方包：CRC-32 不是密码学原语，20 行查表实现完全够用，
/// 为它加一个传递依赖（进而登记 allowlist、过依赖门禁）得不偿失。
library;

import 'dart:typed_data';

abstract final class Crc32 {
  static const int _poly = 0xEDB88320;

  static final List<int> _table = _buildTable();

  static List<int> _buildTable() {
    final table = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) == 1 ? (_poly ^ (c >>> 1)) : (c >>> 1);
      }
      table[i] = c;
    }
    return table;
  }

  /// 计算 [data] 的 CRC-32（zlib 兼容）。
  static int of(List<int> data, [int? start, int? end]) {
    final s = start ?? 0;
    final e = end ?? data.length;
    var crc = 0xFFFFFFFF;
    for (var i = s; i < e; i++) {
      crc = _table[(crc ^ data[i]) & 0xFF] ^ (crc >>> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  /// 计算 [data] 的 [start, end) 区间 CRC-32 并以 8 位大写十六进制返回。
  static String ofHex(List<int> data, [int? start, int? end]) =>
      of(data, start, end).toRadixString(16).padLeft(8, '0').toUpperCase();

  /// 便捷：直接把结果写进 [target] 的 [offset] 处（u32 BE）。
  static void writeInto(Uint8List target, int offset, List<int> data, [int? start, int? end]) {
    final bd = ByteData.sublistView(target);
    bd.setUint32(offset, of(data, start, end), Endian.big);
  }
}

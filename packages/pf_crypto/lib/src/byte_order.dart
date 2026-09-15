/// 大端序（网络字节序）读写。
///
/// PFB 容器格式全部使用大端序：这是二进制格式的通行做法，
/// 且与人肉对照十六进制转储的习惯一致（高位在前）。
library;

import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';

/// 大端序读写工具。
///
/// 所有方法都做边界检查并抛出 [RangeError] —— 这是编程错误，
/// 应当在开发期立刻暴露。文件层面的合法性问题由容器解析器先行校验，
/// 不依赖这里的兜底。
abstract final class BigEndian {
  static int readUint16(Uint8List bytes, int offset) {
    _require(bytes, offset, 2);
    return ByteData.sublistView(bytes, offset, offset + 2).getUint16(0, Endian.big);
  }

  static int readUint32(Uint8List bytes, int offset) {
    _require(bytes, offset, 4);
    return ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.big);
  }

  /// 读取 64 位无符号整数。
  ///
  /// Dart 的 `int` 是 64 位有符号，超过 2^63-1 的值会变成负数。
  /// 这里显式检测并拒绝，而不是把负数悄悄传给上层 ——
  /// 那个负数最终会变成一个越界偏移或一次荒谬的内存分配。
  static int readUint64(Uint8List bytes, int offset) {
    _require(bytes, offset, 8);
    final value = ByteData.sublistView(bytes, offset, offset + 8).getUint64(0, Endian.big);
    if (value < 0) {
      throw ContainerError.headerInvalid(detail: '偏移 $offset 处的 u64 超出可表示范围');
    }
    return value;
  }

  static void writeUint16(Uint8List bytes, int offset, int value) {
    _require(bytes, offset, 2);
    if (value < 0 || value > 0xFFFF) {
      throw RangeError.range(value, 0, 0xFFFF, 'value');
    }
    ByteData.sublistView(bytes, offset, offset + 2).setUint16(0, value, Endian.big);
  }

  static void writeUint32(Uint8List bytes, int offset, int value) {
    _require(bytes, offset, 4);
    if (value < 0 || value > 0xFFFFFFFF) {
      throw RangeError.range(value, 0, 0xFFFFFFFF, 'value');
    }
    ByteData.sublistView(bytes, offset, offset + 4).setUint32(0, value, Endian.big);
  }

  static void writeUint64(Uint8List bytes, int offset, int value) {
    _require(bytes, offset, 8);
    if (value < 0) {
      throw RangeError.range(value, 0, 0x7FFFFFFFFFFFFFFF, 'value');
    }
    ByteData.sublistView(bytes, offset, offset + 8).setUint64(0, value, Endian.big);
  }

  static Uint8List readBytes(Uint8List bytes, int offset, int length) {
    _require(bytes, offset, length);
    return Uint8List.sublistView(bytes, offset, offset + length);
  }

  static void writeBytes(Uint8List target, int offset, List<int> source) {
    _require(target, offset, source.length);
    target.setRange(offset, offset + source.length, source);
  }

  static void _require(Uint8List bytes, int offset, int length) {
    if (offset < 0 || length < 0 || offset + length > bytes.length) {
      throw RangeError('越界访问：offset=$offset length=$length 但缓冲区长度=${bytes.length}');
    }
  }
}

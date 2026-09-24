/// 造 ZIP 的测试夹具 —— `zip_test.dart` 与 `fetch_engine_test.dart` 共用。
///
/// 手写本地头 / 中央目录 / EOCD。它顺带充当"规范"的另一种表达：
/// 构造与解析是两套独立代码，任一处把偏移写错，另一处立刻对不上。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 压缩方法。
enum ZipMethod {
  stored(0),
  deflate(8);

  const ZipMethod(this.code);
  final int code;
}

/// 只支持本仓读取器认识的那一小块 ZIP 的构造器。
final class ZipBuilder {
  final List<Uint8List> _local = <Uint8List>[];
  final List<Uint8List> _central = <Uint8List>[];
  final List<String> _names = <String>[];
  int _offset = 0;

  /// 成员名（按追加顺序）。
  List<String> get names => List<String>.unmodifiable(_names);

  /// 追加一个成员。
  ///
  /// [methodOverride] 用来伪造"不认识的压缩方法"；[forceZip64Size] 把长度写成
  /// ZIP64 哨兵；[fakeUncompressedSize] 让中央目录声明一个假的解压后长度。
  ZipBuilder add(
    String name,
    Uint8List payload,
    ZipMethod method, {
    int flags = 0,
    int? methodOverride,
    bool forceZip64Size = false,
    int? fakeUncompressedSize,
  }) {
    final methodCode = methodOverride ?? method.code;
    final stored = switch (method) {
      ZipMethod.stored => payload,
      ZipMethod.deflate => Uint8List.fromList(ZLibCodec(raw: true).encode(payload)),
    };
    final nameBytes = Uint8List.fromList(utf8.encode(name));

    final local = Uint8List(30);
    final lv = ByteData.sublistView(local);
    lv.setUint32(0, 0x04034b50, Endian.little);
    lv.setUint16(4, 20, Endian.little); // version needed
    lv.setUint16(6, flags, Endian.little);
    lv.setUint16(8, methodCode, Endian.little);
    lv.setUint32(14, 0, Endian.little); // crc32：读取器不看
    lv.setUint32(18, forceZip64Size ? 0xFFFFFFFF : stored.length, Endian.little);
    lv.setUint32(22, forceZip64Size ? 0xFFFFFFFF : payload.length, Endian.little);
    lv.setUint16(26, nameBytes.length, Endian.little);
    lv.setUint16(28, 0, Endian.little); // extra length

    final central = Uint8List(46);
    final cv = ByteData.sublistView(central);
    cv.setUint32(0, 0x02014b50, Endian.little);
    cv.setUint16(4, 20, Endian.little); // version made by
    cv.setUint16(6, 20, Endian.little); // version needed
    cv.setUint16(8, flags, Endian.little);
    cv.setUint16(10, methodCode, Endian.little);
    cv.setUint32(16, 0, Endian.little); // crc32
    cv.setUint32(20, forceZip64Size ? 0xFFFFFFFF : stored.length, Endian.little);
    cv.setUint32(
      24,
      forceZip64Size ? 0xFFFFFFFF : (fakeUncompressedSize ?? payload.length),
      Endian.little,
    );
    cv.setUint16(28, nameBytes.length, Endian.little);
    cv.setUint16(30, 0, Endian.little); // extra
    cv.setUint16(32, 0, Endian.little); // comment
    cv.setUint32(42, _offset, Endian.little); // local header offset

    _local
      ..add(local)
      ..add(nameBytes)
      ..add(stored);
    _central
      ..add(central)
      ..add(nameBytes);
    _names.add(name);
    _offset += local.length + nameBytes.length + stored.length;
    return this;
  }

  Uint8List build() => buildWithComment('');

  /// 造出完整 ZIP；[comment] 附在 EOCD 之后（ZIP 允许，最长 64 KiB）。
  Uint8List buildWithComment(String comment) {
    final commentBytes = Uint8List.fromList(utf8.encode(comment));
    final builder = BytesBuilder(copy: false);
    for (final chunk in _local) {
      builder.add(chunk);
    }
    final centralOffset = builder.length;
    for (final chunk in _central) {
      builder.add(chunk);
    }
    final centralSize = builder.length - centralOffset;

    final eocd = Uint8List(22);
    final ev = ByteData.sublistView(eocd);
    ev.setUint32(0, 0x06054b50, Endian.little);
    ev.setUint16(4, 0, Endian.little); // disk number
    ev.setUint16(6, 0, Endian.little); // disk with central directory
    ev.setUint16(8, _names.length, Endian.little);
    ev.setUint16(10, _names.length, Endian.little);
    ev.setUint32(12, centralSize, Endian.little);
    ev.setUint32(16, centralOffset, Endian.little);
    ev.setUint16(20, commentBytes.length, Endian.little);

    builder
      ..add(eocd)
      ..add(commentBytes);
    return builder.takeBytes();
  }
}

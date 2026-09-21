import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';
import 'package:test/test.dart';

/// [BigEndian] 的**拒绝分支**单测。
///
/// 正常的读写路径已经由 `container_format_test` 的编解码往返覆盖，这里只守边界：
/// 越界偏移、u16/u32/u64 溢出、以及「u64 最高位为 1」这一条。
///
/// 为什么最后那条值得单独立一个测试：Dart 的 `int` 是 64 位**有符号**，
/// `ByteData.getUint64` 把 `0xFFFF…FF` 读回来会变成 `-1`。若直接放行，
/// 这个负数会流进 `plaintextLength`，再变成一个越界偏移或一次荒谬的内存分配 ——
/// 而它来自**文件头**，即攻击者可控的输入。所以读取侧必须显式拒绝，
/// 而不是指望调用方记得判负。
void main() {
  group('BigEndian · 越界与溢出必须显式失败', () {
    test('readUint64：最高位为 1 ⇒ 拒绝，而不是把负数交给上层', () {
      final bytes = Uint8List.fromList(List<int>.filled(8, 0xFF));
      expect(
        () => BigEndian.readUint64(bytes, 0),
        throwsA(isA<PfError>().having((e) => e.code, 'code', PfErrorCode.containerHeaderInvalid)),
      );
    });

    test('readUint64：最高位为 0 时可读（0x7FFF…FF 是合法上界）', () {
      final bytes = Uint8List.fromList(List<int>.filled(8, 0xFF))..[0] = 0x7F;
      expect(BigEndian.readUint64(bytes, 0), 0x7FFFFFFFFFFFFFFF);
    });

    test('readUint64：偏移越界 ⇒ RangeError（不是读到隔壁的字节）', () {
      expect(() => BigEndian.readUint64(Uint8List(7), 0), throwsRangeError);
      expect(() => BigEndian.readUint64(Uint8List(8), 1), throwsRangeError);
    });

    test('writeUint16：超出 0..0xFFFF ⇒ RangeError', () {
      expect(() => BigEndian.writeUint16(Uint8List(2), 0, 0x10000), throwsRangeError);
      expect(() => BigEndian.writeUint16(Uint8List(2), 0, -1), throwsRangeError);
    });

    test('writeUint32：超出 0..0xFFFFFFFF ⇒ RangeError', () {
      expect(() => BigEndian.writeUint32(Uint8List(4), 0, 0x100000000), throwsRangeError);
      expect(() => BigEndian.writeUint32(Uint8List(4), 0, -1), throwsRangeError);
    });

    test('writeUint64：负数 ⇒ RangeError（有符号 int 装不下无符号 u64 的上半区）', () {
      expect(() => BigEndian.writeUint64(Uint8List(8), 0, -1), throwsRangeError);
    });

    test('读写越界（offset + length > 缓冲区长度）⇒ RangeError', () {
      expect(() => BigEndian.readBytes(Uint8List(4), 0, 5), throwsRangeError);
      expect(() => BigEndian.readBytes(Uint8List(4), -1, 1), throwsRangeError);
      expect(() => BigEndian.writeBytes(Uint8List(2), 1, <int>[1, 2]), throwsRangeError);
    });

    test('writeBytes：长度以源为准（不是目标剩余长度）', () {
      final target = Uint8List(4);
      BigEndian.writeBytes(target, 0, <int>[0xAA, 0xBB, 0xCC, 0xDD]);
      expect(target, <int>[0xAA, 0xBB, 0xCC, 0xDD]);
    });
  });
}

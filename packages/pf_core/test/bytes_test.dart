import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:test/test.dart';

void main() {
  group('toHex / fromHex', () {
    test('往返一致（含全字节取值）', () {
      final bytes = Uint8List.fromList(List<int>.generate(256, (i) => i));
      expect(fromHex(toHex(bytes)), equals(bytes));
    });

    test('输出小写十六进制，每字节两位', () {
      expect(toHex(<int>[0x00, 0x0F, 0xF0, 0xFF]), '000ff0ff');
      expect(toHex(<int>[]), '');
    });

    test('拒绝越界字节（不静默截断）', () {
      expect(() => toHex(<int>[256]), throwsA(isA<ArgumentError>()));
      expect(() => toHex(<int>[-1]), throwsA(isA<ArgumentError>()));
    });

    test('解码忽略大小写并接受 0x 前缀', () {
      expect(fromHex('DEADBEEF'), equals(fromHex('deadbeef')));
      expect(fromHex('0xDEADBEEF'), equals(fromHex('deadbeef')));
    });

    test('奇长度输入被拒绝', () {
      expect(() => fromHex('abc'), throwsA(isA<FormatException>()));
    });

    test('非法字符被拒绝', () {
      expect(() => fromHex('zz'), throwsA(isA<FormatException>()));
    });
  });

  group('constantTimeEquals', () {
    test('相等返回 true', () {
      expect(constantTimeEquals(<int>[1, 2, 3], <int>[1, 2, 3]), isTrue);
      expect(constantTimeEquals(<int>[], <int>[]), isTrue);
    });

    test('首个字节就不同也返回 false', () {
      expect(constantTimeEquals(<int>[9, 2, 3], <int>[1, 2, 3]), isFalse);
    });

    test('末字节不同也返回 false', () {
      expect(constantTimeEquals(<int>[1, 2, 9], <int>[1, 2, 3]), isFalse);
    });

    test('长度不同返回 false', () {
      expect(constantTimeEquals(<int>[1, 2], <int>[1, 2, 3]), isFalse);
    });
  });

  group('zeroize', () {
    test('把缓冲区内容全部置零', () {
      final buffer = Uint8List.fromList(<int>[1, 2, 3, 4]);
      zeroize(buffer);
      expect(buffer, everyElement(0));
    });
  });
}

/// `zip.dart` —— 手写 ZIP 读取器的单元测试。
///
/// ## 为什么这个读取器值得一个专门的测试文件
///
/// 它解出来的是**原生动态库的字节**，而下游的判据是 sha256。这意味着
/// 「我们解错了」与「上游换了包」在下游看起来是同一个失败（摘要不符）——
/// 而排查方向完全不同。把每一类拒绝理由都钉一条用例，是为了让
/// "上游换包"与"解析器坏了"在第一时间就分开。
///
/// ## 夹具是现造的 ZIP，不读磁盘上任何东西
///
/// `ZipBuilder` 手写本地头 / 中央目录 / EOCD。它顺带充当"规范"的另一种
/// 表达：构造与解析是两套独立代码，任一处把偏移写错，另一处立刻对不上。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pf_cli/pf_cli.dart';
import 'package:test/test.dart';

import 'support/zip_builder.dart';

void main() {
  group('能取到成员', () {
    test('存储（method 0）：原样取回', () {
      final payload = Uint8List.fromList(utf8.encode('e_sqlcipher 的假字节'));
      final archive =
          ZipBuilder()
              .add('runtimes/win-x64/native/e_sqlcipher.dll', payload, ZipMethod.stored)
              .build();

      expect(readZipMember(archive, 'runtimes/win-x64/native/e_sqlcipher.dll'), payload);
    });

    test('deflate（method 8）：解压后取回（载荷没有 zlib 头）', () {
      // 用一段可压缩性很高的内容 —— 否则"解压没错"与"根本没压缩"分不开。
      final payload = Uint8List.fromList(utf8.encode('A' * 4096));
      final archive =
          ZipBuilder()
              .add('runtimes/linux-x64/native/e_sqlcipher.so', payload, ZipMethod.deflate)
              .build();

      expect(readZipMember(archive, 'runtimes/linux-x64/native/e_sqlcipher.so'), payload);
    });

    test('多成员：按名字取，不按顺序取', () {
      final first = Uint8List.fromList(utf8.encode('first'));
      final second = Uint8List.fromList(utf8.encode('second'));
      final archive =
          ZipBuilder()
              .add('a.txt', first, ZipMethod.stored)
              .add('nested/b.txt', second, ZipMethod.deflate)
              .add('c.txt', Uint8List.fromList(<int>[1, 2, 3]), ZipMethod.stored)
              .build();

      expect(readZipMember(archive, 'nested/b.txt'), second);
      expect(readZipMember(archive, 'a.txt'), first);
      expect(listZipMembers(archive), <String>['a.txt', 'nested/b.txt', 'c.txt']);
    });

    test('名字大小写敏感（nupkg 里的路径就是这个大小写）', () {
      final archive =
          ZipBuilder()
              .add('runtimes/Win-x64/native/e.dll', Uint8List.fromList(<int>[9]), ZipMethod.stored)
              .build();

      expect(readZipMember(archive, 'runtimes/Win-x64/native/e.dll'), <int>[9]);
      expect(() => readZipMember(archive, 'runtimes/win-x64/native/e.dll'), throwsFormatException);
    });
  });

  group('拒绝：一律抛 FormatException，不猜', () {
    test('没有这个成员', () {
      final archive =
          ZipBuilder().add('present.txt', Uint8List.fromList(<int>[1]), ZipMethod.stored).build();

      expect(() => readZipMember(archive, 'absent.txt'), throwsFormatException);
    });

    test('条目被加密（通用位第 0 位）', () {
      final archive =
          ZipBuilder()
              .add('secret.bin', Uint8List.fromList(<int>[1, 2]), ZipMethod.stored, flags: 1 << 0)
              .build();

      expect(() => readZipMember(archive, 'secret.bin'), throwsFormatException);
    });

    test('长度写在数据描述符里（通用位第 3 位）', () {
      final archive =
          ZipBuilder()
              .add('dd.bin', Uint8List.fromList(<int>[1, 2]), ZipMethod.stored, flags: 1 << 3)
              .build();

      expect(() => readZipMember(archive, 'dd.bin'), throwsFormatException);
    });

    test('ZIP64 长度哨兵值（0xFFFFFFFF）', () {
      final archive =
          ZipBuilder()
              .add('big.bin', Uint8List.fromList(<int>[1]), ZipMethod.stored, forceZip64Size: true)
              .build();

      expect(() => readZipMember(archive, 'big.bin'), throwsFormatException);
    });

    test('不认识的压缩方法（如 12 = bzip2）', () {
      final archive =
          ZipBuilder()
              .add(
                'weird.bin',
                Uint8List.fromList(<int>[1, 2, 3]),
                ZipMethod.stored,
                methodOverride: 12,
              )
              .build();

      expect(() => readZipMember(archive, 'weird.bin'), throwsFormatException);
    });

    test('中央目录声明的解压后长度与实际不符', () {
      final archive =
          ZipBuilder()
              .add(
                'liar.bin',
                Uint8List.fromList(<int>[1, 2, 3]),
                ZipMethod.stored,
                fakeUncompressedSize: 99,
              )
              .build();

      expect(() => readZipMember(archive, 'liar.bin'), throwsFormatException);
    });
  });

  group('拒绝：结构损坏', () {
    test('太短（连 EOCD 都放不下）', () {
      expect(() => readZipMember(Uint8List.fromList(<int>[1, 2, 3]), 'x'), throwsFormatException);
    });

    test('随机字节：找不到 EOCD 签名', () {
      final junk = Uint8List.fromList(List<int>.generate(512, (i) => i % 251));
      expect(() => readZipMember(junk, 'x'), throwsFormatException);
      expect(() => listZipMembers(junk), throwsFormatException);
    });

    test('本地头签名不对', () {
      final archive =
          ZipBuilder().add('x.bin', Uint8List.fromList(<int>[1, 2]), ZipMethod.stored).build();
      // 就地破坏本地头的前四字节（PK\x03\x04 → 变成别的）。
      archive[0] = 0x00;

      expect(() => readZipMember(archive, 'x.bin'), throwsFormatException);
    });

    test('正文里出现 EOCD 签名 + 尾部有注释：仍必须取到正确成员', () {
      // 两个坑一起造：
      //   1. 正文里放了 `PK\x05\x06` —— 从前往后扫会撞上它，算出一堆垃圾；
      //   2. EOCD 之后跟一段注释 —— 尾部扫描的起点因此不在文件最末尾。
      final trap = Uint8List.fromList(<int>[0x50, 0x4B, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00]);
      final archive = ZipBuilder()
          .add('trap.bin', trap, ZipMethod.stored)
          .add('x.bin', Uint8List.fromList(<int>[1, 2, 3]), ZipMethod.stored)
          .buildWithComment('尾部注释：EOCD 不在文件最末尾，但仍在扫描窗口内');

      expect(readZipMember(archive, 'x.bin'), <int>[1, 2, 3]);
      expect(readZipMember(archive, 'trap.bin'), trap);
      expect(listZipMembers(archive), <String>['trap.bin', 'x.bin']);
    });
  });
}

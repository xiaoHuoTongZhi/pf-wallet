import 'package:pf_guards/scan.dart';
// package:test 也导出了名为 collapseWhitespace 的 matcher，与被测函数同名。
// 显式 hide 掉 matcher 那个，避免 ambiguous_import ——
// 用 prefix 会污染整个测试文件的可读性，而这里只需要遮一个名字。
import 'package:test/test.dart' hide collapseWhitespace;

void main() {
  group('SourceProjection · 长度与行号不变量', () {
    const samples = <String>[
      '',
      'final a = 1;\n',
      'final s = \'a print(x) b\';\n',
      '// 注释里写 print( 不会命中\nfinal a = 1;\n',
      'final s = """\n多行\n字符串\n""";\n',
      r"final s = r'$notInterpolated';",
      "final s = 'a\\'b'; print(1);",
      '/* 块注释\n跨行 */\nfinal a = 1;',
      'final m = <String, int>{if (a) \'x\': 1};\n',
    ];

    for (var index = 0; index < samples.length; index++) {
      final source = samples[index];
      test('样本 $index：三种投影长度与换行位置一致', () {
        final projection = SourceProjection.of('sample.dart', source);
        expect(projection.noComments.length, source.length);
        expect(projection.masked.length, source.length);
        expect(
          _newlinePositions(projection.noComments),
          _newlinePositions(source),
          reason: 'noComments 必须保留原始换行位置',
        );
        expect(
          _newlinePositions(projection.masked),
          _newlinePositions(source),
          reason: 'masked 必须保留原始换行位置',
        );
      });
    }
  });

  group('SourceProjection · 掩码语义', () {
    test('注释被抹掉，字符串保留在 noComments', () {
      const source = "final a = 'keep me'; // print(1)\n";
      final projection = SourceProjection.of('a.dart', source);
      expect(projection.noComments.contains('keep me'), isTrue);
      expect(projection.noComments.contains('print(1)'), isFalse);
    });

    test('字符串内容在 masked 中被抹掉', () {
      const source = "final s = 'a print(x) b';\n";
      final projection = SourceProjection.of('a.dart', source);
      expect(projection.noComments.contains('print(x)'), isTrue);
      expect(projection.masked.contains('print(x)'), isFalse);
      // 引号本身保留，便于定位
      expect(projection.masked.contains("'"), isTrue);
    });

    test('插值表达式在 masked 中保留（否则日志规则会失效）', () {
      const source = r"logger.info('v=$password');";
      final projection = SourceProjection.of('a.dart', source);
      expect(projection.masked.contains(r'$password'), isTrue);
      expect(projection.masked.contains('v='), isFalse);
    });

    test(r'${...} 形式的插值同样保留', () {
      const source = r"log('v=${account.secretKey}');";
      final projection = SourceProjection.of('a.dart', source);
      expect(projection.masked.contains('secretKey'), isTrue);
    });

    test('raw 字符串不做插值，整体掩码', () {
      const source = r"final s = r'$password';";
      final projection = SourceProjection.of('a.dart', source);
      expect(projection.masked.contains(r'$password'), isFalse);
    });

    test('转义引号不会提前结束字符串', () {
      const source = r"final s = 'a\'b'; print(1);";
      final projection = SourceProjection.of('a.dart', source);
      final units = splitLogicalUnits(projection);
      expect(units.any((unit) => unit.masked.contains('print(')), isTrue);
    });

    test('未闭合字符串不会导致越界', () {
      const source = "final s = 'unterminated\nfinal a = 1;\n";
      expect(() => SourceProjection.of('a.dart', source), returnsNormally);
    });
  });

  group('splitLogicalUnits', () {
    test('跨行调用合并为一个逻辑语句', () {
      const source = "logger.error(\n  'msg',\n  context,\n);\n";
      final projection = SourceProjection.of('a.dart', source);
      final units = splitLogicalUnits(projection);
      final callUnits = units.where((unit) => unit.masked.contains('logger')).toList();
      expect(callUnits, hasLength(1));
      expect(callUnits.single.startLine, 1);
      expect(callUnits.single.endLine, 4);
    });

    test('相邻语句被切开', () {
      const source = 'final a = 1; final b = 2;\n';
      final units = splitLogicalUnits(SourceProjection.of('a.dart', source));
      expect(units, hasLength(2));
    });

    test('类体与函数体各自成块，不会把整文件并成一块', () {
      const source = 'class A {\n  void f() {}\n}\nclass B {\n  int x = 1;\n}\n';
      final units = splitLogicalUnits(SourceProjection.of('a.dart', source));
      expect(units.length, greaterThanOrEqualTo(2));
    });

    test('空行与纯注释段不产生语句', () {
      const source = '\n\n// 只有注释\n\n';
      final units = splitLogicalUnits(SourceProjection.of('a.dart', source));
      expect(units, isEmpty);
    });

    test('语句内的分号（字符串/插值）不会切断语句', () {
      const source = "log('a;b');\n";
      final units = splitLogicalUnits(SourceProjection.of('a.dart', source));
      expect(units, hasLength(1));
    });
  });

  group('hasIgnoreDirective', () {
    const source = '// guards:ignore no-x\nprint(1);\n';
    final lines = source.split('\n');

    test('上一行的抑制指令生效', () {
      expect(hasIgnoreDirective(lines, 2, 2, 'no-x'), isTrue);
    });

    test('规则 ID 必须精确匹配（前缀不算）', () {
      expect(hasIgnoreDirective(lines, 2, 2, 'no'), isFalse);
    });

    test('不同规则 ID 不生效', () {
      expect(hasIgnoreDirective(lines, 2, 2, 'no-y'), isFalse);
    });
  });

  group('collapseWhitespace', () {
    test('压缩空白并截断', () {
      expect(collapseWhitespace('  a\n   b\tc  '), 'a b c');
      final long = collapseWhitespace('x' * 500, maxLength: 10);
      expect(long.length, 11); // 10 个字符 + 省略号
      expect(long.endsWith('…'), isTrue);
    });
  });
}

List<int> _newlinePositions(String text) {
  final positions = <int>[];
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) positions.add(i);
  }
  return positions;
}

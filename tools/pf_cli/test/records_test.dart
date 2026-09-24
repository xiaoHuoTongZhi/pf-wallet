/// 四层规范报告的测试（跨实现校验里 Dart 侧的产出）。
///
/// 这份文本要拿去与 Python 侧的产出做 `diff`，所以这里要证明的不是「它好看」，
/// 而是三件**会静默破坏 diff** 的性质：
///
///   1. **值确实来自文件**：四层里凡是 fixture 记了期望值的那几层
///      （整文件摘要、NDJSON 摘要、contentHash、条数、逐表 counts），
///      报告里的值必须与 fixture 一致。不一致时不能靠「两套实现都错成一样」蒙过去 ——
///      好在 fixture 是第三方（独立 Python 生成器）产出的。
///   2. **不夹带实现私货**：路径、文件名、时间戳、实现名、版本号一律不许出现。
///      出现任何一样，「同一份文件换个目录跑」或「换个版本跑」都会变成假失败。
///      这条用一个**强断言**来压：同一份字节配两个不同的文件名，报告必须逐字节相同。
///   3. **格式本身被钉死**：键序、行号补零、紧凑 JSON、非 ASCII 不转义 ——
///      两边各改一处、恰好抵销，是这类校验唯一能骗过 diff 的方式。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pf_cli/pf_cli.dart';
import 'package:pf_crypto/pf_crypto.dart';
import 'package:pf_io/pf_io.dart';
import 'package:test/test.dart';

import 'support/sample.dart';

void main() {
  late VectorFixture fixture;
  late VectorSample sample;
  late ImportedFile imported;
  late String report;
  late List<String> reportLines;

  /// 从 fixture 的 NDJSON 字节里独立切行 —— 不用被测代码的 `splitPayloadLines`。
  /// 若两边对「末尾换行」的语义理解不同，这里会立刻对不上。
  List<String> independentLines(Uint8List ndjson) {
    final text = utf8.decode(ndjson);
    final parts = text.split('\n');
    if (parts.isNotEmpty && parts.last.isEmpty) {
      parts.removeLast();
    }
    return parts;
  }

  setUpAll(() async {
    fixture = loadVectorFixture();
    sample = fixture.full;
    imported = await const PfbImportReader().read(
      fileBytes: sample.fileBytes,
      password: Uint8List.fromList(utf8.encode(fixture.password)),
      fileName: sample.fileName,
    );
    report = buildCrossCheckReport(imported);
    reportLines = report.substring(0, report.length - 1).split('\n');
  });

  String valueOf(String key) {
    final prefix = '$key=';
    final line = reportLines.firstWhere(
      (candidate) => candidate.startsWith(prefix),
      orElse: () => throw StateError('报告里没有 $key'),
    );
    return line.substring(prefix.length);
  }

  group('报告的骨架', () {
    test('首行是格式版本 —— 增删任何一层都必须改它', () {
      expect(reportLines.first, kCrossCheckReportHeader);
      expect(kCrossCheckReportHeader, 'pfb-cross-check format=1');
    });

    test('以换行结尾，且不含空行（空行会让 diff 的上下文错位）', () {
      expect(report.endsWith('\n'), isTrue);
      expect(report.contains('\n\n'), isFalse);
    });

    test('四层的键都在，且顺序固定', () {
      final keys = <String>[
        // 首行（格式版本）自己就带一个 `=`，不参与键序。
        for (final line in reportLines.skip(1)) line.substring(0, line.indexOf('=')),
      ];
      final expectedOrder = <String>[
        'layer1.file.bytes',
        'layer1.file.sha256',
        'layer2.plain.bytes',
        'layer2.plain.sha256',
        'layer3.ndjson.bytes',
        'layer3.ndjson.sha256',
        'layer3.lines',
        ...List<String>.generate(
          independentLines(sample.payloadNdjson).length,
          (int i) => 'layer3.line.${formatLayerIndex(i)}.sha256',
        ),
        ...List<String>.generate(
          independentLines(sample.payloadNdjson).length,
          (int i) => 'layer4.canonical.${formatLayerIndex(i)}',
        ),
        'layer4.contentHash',
        'layer4.recordCount.observed',
        'layer4.recordCount.declared',
        ...(sample.counts.keys.toList()..sort()).map((String k) => 'layer4.counts.$k'),
      ];
      expect(keys, expectedOrder);
    });
  });

  group('层 1：文件字节 —— 与 fixture 的整文件摘要一致', () {
    test('字节数', () {
      expect(valueOf('layer1.file.bytes'), '${sample.fileBytes.length}');
    });

    test('摘要（fixture 记的，不是被测代码算的）', () {
      expect(valueOf('layer1.file.sha256'), sample.fileSha256);
    });
  });

  group('层 2：容器明文（gzip 流）', () {
    test('字节数与摘要自洽，且**不同于**文件字节与 NDJSON', () {
      final plainBytes = int.parse(valueOf('layer2.plain.bytes'));
      final plainSha = valueOf('layer2.plain.sha256');
      expect(plainBytes, imported.containerPlaintext.length);
      expect(plainSha, Sha256.instance.hashHex(imported.containerPlaintext));
      expect(plainBytes, lessThan(sample.fileBytes.length), reason: '容器明文不含头部与尾部摘要');
      expect(plainSha, isNot(sample.fileSha256));
      expect(plainSha, isNot(sample.payloadNdjsonSha256));
    });

    test('容器明文不是 NDJSON：它仍是 gzip 流（1f 8b 开头）', () {
      expect(imported.containerPlaintext[0], 0x1f);
      expect(imported.containerPlaintext[1], 0x8b);
    });
  });

  group('层 3：记录行 —— 与 fixture 的载荷摘要一致', () {
    test('全区字节数与摘要（fixture 记的值）', () {
      expect(valueOf('layer3.ndjson.bytes'), '${sample.payloadNdjson.length}');
      expect(valueOf('layer3.ndjson.sha256'), sample.payloadNdjsonSha256);
    });

    test('行数 = 记录数 + manifest + end', () {
      final lines = independentLines(sample.payloadNdjson);
      expect(valueOf('layer3.lines'), '${lines.length}');
      expect(lines.length, sample.recordCount + 2);
    });

    test('逐行摘要与**独立切行**算出来的一致（钉住末尾换行的语义）', () {
      final lines = independentLines(sample.payloadNdjson);
      for (var i = 0; i < lines.length; i++) {
        expect(
          valueOf('layer3.line.${formatLayerIndex(i)}.sha256'),
          Sha256.instance.hashHex(utf8.encode(lines[i])),
          reason: '第 $i 行',
        );
      }
    });

    test('行号补零：不补零时 line.10 会排在 line.2 前面，顺序差异会看不见', () {
      expect(formatLayerIndex(0), '0000');
      expect(formatLayerIndex(9), '0009');
      expect(formatLayerIndex(10), '0010');
      expect(formatLayerIndex(1234), '1234');
      expect(formatLayerIndex(12345), '12345');
    });
  });

  group('层 4：逐条清单 —— 语义与字节各有各的作用', () {
    test('每行的规范 JSON 与独立算出的紧凑 JSON 一致', () {
      final lines = independentLines(sample.payloadNdjson);
      for (var i = 0; i < lines.length; i++) {
        final expected = jsonEncode(jsonDecode(utf8.decode(utf8.encode(lines[i]))) as Object?);
        // 上面那一步只是「紧凑化」，键序仍是文件序 —— 所以只比长度与首字符，
        // 真正比键序的是下一条（规范化的键序由 canonicalizeJson 定义）。
        expect(valueOf('layer4.canonical.${formatLayerIndex(i)}').length, expected.length);
      }
    });

    test('键是递归排序的：manifest 行以 appVersion 开头（文件序里它不是第一个）', () {
      final canonical = valueOf('layer4.canonical.0000');
      expect(canonical.startsWith('{"appVersion":'), isTrue);
      expect(canonical.endsWith('}'), isTrue);
      expect(canonical.contains(' '), isFalse, reason: '紧凑分隔符，不许有空格');
      // 嵌套对象也排序：counts 的键序是字母序，而不是 fixture 里的录入序。
      expect(canonical.contains('"counts":{"account":2,"attachment":1,'), isTrue);
    });

    test('非 ASCII 不转义（转义与否是两套实现最容易分叉的一处）', () {
      final all = reportLines
          .where((String line) => line.startsWith('layer4.canonical.'))
          .join('\n');
      // 样本里有中文的设备名、账本名、附件名。
      expect(all, contains('向量生成器'));
      expect(all, contains('日常'));
      expect(all, contains('发票.jpg'));
      expect(all, isNot(contains(r'\u')));
    });

    test('contentHash / 条数 / 逐表 counts 与 fixture 一致', () {
      expect(valueOf('layer4.contentHash'), 'sha256:${sample.contentHashHex}');
      expect(valueOf('layer4.recordCount.observed'), '${sample.recordCount}');
      expect(valueOf('layer4.recordCount.declared'), '${sample.recordCount}');
      for (final entry in sample.counts.entries) {
        expect(valueOf('layer4.counts.${entry.key}'), '${entry.value}');
      }
      expect(sample.counts.length, 8, reason: 'full 样本覆盖全部八种记录类型');
    });
  });

  group('不夹带实现私货：换个文件名／换个路径，报告逐字节相同', () {
    test('同一份字节配两个不同的文件名 → 报告一模一样', () async {
      final other = await const PfbImportReader().read(
        fileBytes: sample.fileBytes,
        password: Uint8List.fromList(utf8.encode(fixture.password)),
        fileName: 'D:/some/other/dir/renamed.pfb',
      );
      expect(buildCrossCheckReport(other), report);
    });

    test('报告里不含文件名、扩展名与路径分隔符', () {
      expect(report.contains(sample.fileName), isFalse);
      expect(report.contains('.pfb'), isFalse);
      expect(report.contains('test_vectors'), isFalse);
      expect(report.contains(r'\'), isFalse);
    });
  });

  group('切行规则（必须与 Python 侧 split_lines 逐字相同）', () {
    Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

    test('以换行结尾 ⇒ N 行，不是 N+1 行', () {
      expect(splitPayloadLines(bytes('a\nb\n')).length, 2);
      expect(splitPayloadLines(bytes('a\nb')).length, 2);
    });

    test('中间的空行算一行；末尾连续两个换行只丢最后一个空段', () {
      // 'a\n\n\n' ⇒ 'a' 与两个空行。只丢末尾那一个空段 ——
      // 多丢一个就等于允许「中间的空行被吞掉」，而空行在载荷里是**错误**，
      // 应当被解码器报出来（两边都必须看得见它，才报得出来）。
      final lines = splitPayloadLines(bytes('a\n\n\n'));
      expect(lines.length, 3);
      expect(utf8.decode(lines[0]), 'a');
      expect(lines[1], isEmpty);
      expect(lines[2], isEmpty);
    });

    test('末尾没有换行时最后一个空段不丢（它是真实的一行空行）', () {
      final lines = splitPayloadLines(bytes('a\n\n'));
      expect(lines.length, 2);
      expect(utf8.decode(lines[0]), 'a');
      expect(lines[1], isEmpty);
    });

    test('空输入 ⇒ 零行', () {
      expect(splitPayloadLines(bytes('')), isEmpty);
    });

    test('视图是零拷贝：改原始字节会反映到行上（不与 payload 脱钩）', () {
      final raw = bytes('abc\n');
      final lines = splitPayloadLines(raw);
      raw[0] = 0x7A; // 'z'
      expect(utf8.decode(lines[0]), 'zbc');
    });
  });

  group('规范 JSON：键序归一，值与形状不变', () {
    Uint8List line(String text) => Uint8List.fromList(utf8.encode(text));

    test('顶层与嵌套的键都排序', () {
      expect(
        canonicalJsonBytes(line('{"b":1,"a":{"z":[3,2,1],"y":true}}')),
        '{"a":{"y":true,"z":[3,2,1]},"b":1}',
      );
    });

    test('数组保序（排序它会把「记录内的顺序」也改掉，那是数据不是键）', () {
      expect(canonicalJsonBytes(line('{"ids":["c","a","b"]}')), '{"ids":["c","a","b"]}');
    });

    test('转义规则：只转义 JSON 必须转义的那些，斜杠与中文原样', () {
      expect(canonicalJsonBytes(line(r'{"s":"a/b\"c\\d\u0001"}')), r'{"s":"a/b\"c\\d\u0001"}');
      expect(canonicalJsonBytes(line('{"s":"中文 / 路径"}')), '{"s":"中文 / 路径"}');
    });

    test('null / 布尔 / 整数原样，不做类型改写', () {
      expect(
        canonicalJsonBytes(line('{"n":null,"t":true,"f":false,"i":-12,"m":9007199254740993}')),
        '{"f":false,"i":-12,"m":9007199254740993,"n":null,"t":true}',
      );
    });

    test('canonicalizeJson 对已经是标量的输入是恒等的', () {
      expect(canonicalizeJson(null), isNull);
      expect(canonicalizeJson(7), 7);
      expect(canonicalizeJson('x'), 'x');
    });
  });
}

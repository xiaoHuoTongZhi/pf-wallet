/// 跨实现 PFB 校验里 **Dart 侧**的产出：四层规范报告。
///
/// ## 这份文本要做什么
///
/// 它会被 `pf info <file> --records --out <f>` 写到文件里，然后与 Python 侧
/// （`tools/ci/pfb_cross_check.py`）产出的同名文件做 **`diff`**。判定标准是
/// **逐字节相同** —— 所以这里的每一个字符都是接口：多一行注释、少一个空行、
/// 把 `layer1` 写成 `L1`，都会让关卡 3 的 `cross-impl` 作业变红。
///
/// 因此这份文本里**刻意不含**三样东西：
///
///   1. **文件名与路径** —— 路径是调用方的选择，不是被验对象的属性。
///      带上它，「同一份文件换个目录跑」就变成一次假失败。
///   2. **实现名 / 版本号 / 时间戳** —— 两份文本来自两套实现，
///      任何一方独有的元信息都必然对不上。
///   3. **人读的说明文字** —— 诊断走 stderr；stdout / 文件里只有数据。
///
/// ## 四层，以及为什么是这四层
///
/// | 层 | 绑定的对象 | 它能抓到、而别的层抓不到的差异 |
/// |---|---|---|
/// | 1 | 文件字节 | 输入本身。先钉住它，后面每一层的差异才有意义 |
/// | 2 | 容器明文（gzip 流） | 容器层解对了没有 —— 与「解压对不对」是两件事 |
/// | 3 | 记录行（逐行字节摘要） | 行的切分与顺序。只给全区摘要时，「两行对调」会被掩盖 |
/// | 4 | 逐条清单（键排序后的紧凑 JSON） | 含义。第 3 层绑字节，第 4 层绑语义，互为补充 |
///
/// 第 4 层绑的是「行」而不是「库表列」（默认值、派生的 `dayKey`、被丢弃的
/// 缓存余额）。那是 §4.1 的规范，且已由 `import.payload.decode.*` 向量核对过 ——
/// 那边的期望值同样来自 Python 独立实现。在这里再抄一遍字段表，只会得到
/// **第二张会与第一张分叉的表**，而分叉那天不会有任何东西变红。
///
/// ## 两处必须与 Python 侧逐字对应的地方
///
///   * [splitPayloadLines] —— 末行语义（以换行结尾时是 N 行而不是 N+1 行）。
///     错一个字节的表现是 contentHash 与逐行摘要整体错位。
///   * [canonicalJsonBytes] —— 键序归一（`jsonEncode` 与 `json.dumps` 的默认
///     行为不同，不归一的话每个对象都比出一处假差异）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pf_crypto/pf_crypto.dart';
import 'package:pf_io/pf_io.dart';

/// 规范报告的首行，同时是**报告格式版本**。
///
/// 将来若增删某一层，必须在这里改动：于是「格式不同」会表现为 diff 的第一行
/// 就不一样，而不是某一行对不上却看不出到底是格式变了还是值错了。
const String kCrossCheckReportHeader = 'pfb-cross-check format=1';

/// 把一次成功的读取渲染成四层规范报告。
///
/// 纯函数：不进不信 IO、不读时钟、不看环境变量 —— 同样的 [ImportedFile]
/// 永远产出同样的字符串。这是「两份文本可以被 diff」的前提。
String buildCrossCheckReport(ImportedFile imported) {
  final lines = splitPayloadLines(imported.payloadNdjson);
  final buffer = StringBuffer();

  buffer.writeln(kCrossCheckReportHeader);

  // ── 层 1：文件字节 ──────────────────────────────────────────────────
  buffer.writeln('layer1.file.bytes=${imported.fileBytes.length}');
  buffer.writeln('layer1.file.sha256=${imported.fileSha256Hex}');

  // ── 层 2：容器明文（gzip 流）────────────────────────────────────────
  buffer.writeln('layer2.plain.bytes=${imported.containerPlaintext.length}');
  buffer.writeln('layer2.plain.sha256=${imported.containerPlaintextSha256Hex}');

  // ── 层 3：记录行 ────────────────────────────────────────────────────
  buffer.writeln('layer3.ndjson.bytes=${imported.payloadNdjson.length}');
  buffer.writeln('layer3.ndjson.sha256=${imported.payloadNdjsonSha256Hex}');
  buffer.writeln('layer3.lines=${lines.length}');
  for (var index = 0; index < lines.length; index++) {
    buffer.writeln(
      'layer3.line.${formatLayerIndex(index)}.sha256=${Sha256.instance.hashHex(lines[index])}',
    );
  }

  // ── 层 4：逐条清单 ──────────────────────────────────────────────────
  for (var index = 0; index < lines.length; index++) {
    buffer.writeln(
      'layer4.canonical.${formatLayerIndex(index)}=${canonicalJsonBytes(lines[index])}',
    );
  }
  buffer.writeln('layer4.contentHash=sha256:${imported.payload.contentHashHex}');
  buffer.writeln('layer4.recordCount.observed=${imported.payload.observedRecordCount}');
  buffer.writeln('layer4.recordCount.declared=${imported.payload.declaredRecordCount}');

  // counts 的键序来自 JSON 解析顺序（实现自由），所以排序后再打 ——
  // 与 Python 侧 `for key in sorted(counts)` 对应。
  final counts = imported.manifestCounts;
  final keys = counts.keys.toList()..sort();
  for (final key in keys) {
    buffer.writeln('layer4.counts.$key=${counts[key]}');
  }

  return buffer.toString();
}

/// 行号在键里的写法：四位十进制、左补零。
///
/// 补零不是为了好看：不补零时 `line.10` 会排在 `line.2` 前面，于是
/// 「两套实现的行序不同」这件事在文本 diff 里看不出顺序 —— 而那正是第 3 层要拦的。
String formatLayerIndex(int index) => index.toString().padLeft(4, '0');

/// 按 `\n` 切行，丢掉末尾那一个空段。
///
/// 与 Python 侧 `split_lines` 对应，语义必须逐字相同：
///   * 以换行结尾 ⇒ N 行（不是 N+1 行）；
///   * 不以换行结尾 ⇒ 最后一行照常算一行；
///   * 空输入 ⇒ 零行。
///
/// 直接 `split('\n')` 会在第一种情况下多出一个空串元素，于是行数与逐行摘要
/// 整体错开一位 —— 而那看起来像「文件被改过」，排查方向会被彻底带偏。
List<Uint8List> splitPayloadLines(Uint8List bytes) {
  final lines = <Uint8List>[];
  var index = 0;
  while (index < bytes.length) {
    final newline = bytes.indexOf(0x0A, index);
    final end = newline == -1 ? bytes.length : newline;
    lines.add(Uint8List.sublistView(bytes, index, end));
    index = newline == -1 ? bytes.length : newline + 1;
  }
  return lines;
}

/// 一行的规范 JSON：键递归排序、紧凑分隔符、不转义非 ASCII。
///
/// 与 Python 侧 `canonical_json` 对应。JSON 里的键序没有语义，却是实现自由的
/// 产物（`jsonEncode` 保序且默认加空格，`json.dumps` 默认也保序）——
/// 不归一的话每个对象都会比出一处假差异。
///
/// 只处理 `Map` / `List` / 标量三种形状：载荷里不会出现别的东西
/// （`PfbPayloadDecoder` 的深度与类型校验已经把这一点钉死）。
String canonicalJsonBytes(Uint8List line) =>
    jsonEncode(canonicalizeJson(jsonDecode(utf8.decode(line))));

/// 递归排序所有对象的键（`List` 保序、标量原样返回）。
Object? canonicalizeJson(Object? value) {
  if (value is Map) {
    final keys = <String>[for (final key in value.keys) '$key']..sort();
    return <String, Object?>{for (final key in keys) key: canonicalizeJson(value[key])};
  }
  if (value is List) {
    return <Object?>[for (final item in value) canonicalizeJson(item)];
  }
  return value;
}

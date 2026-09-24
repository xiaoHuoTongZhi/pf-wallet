/// CLI 测试的公共夹具：内存输出流、内存文件系统、一次调用。
///
/// 三样都做成内存对象不是图快，而是为了**反例的可测性**：
/// 「文件不存在」「只给了密码文件没给数据文件」「环境变量设成空串」
/// 这类分支，用真磁盘与真环境变量要么造不出来（跑 root 时连权限错误
/// 都没有），要么会被本机已有的 `PF_PASSWORD` 污染 —— 那种测试在
/// 开发者机器上绿、在 CI 上红（或反过来），是最难查的一类。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pf_cli/pf_cli.dart';

/// 把 CLI 的输出收进内存 —— 这样测试不必起子进程，分支也进得了覆盖率。
final class Capture implements StringSink {
  final StringBuffer _buffer = StringBuffer();

  String get text => _buffer.toString();

  List<String> get lines =>
      text.isEmpty ? <String>[] : text.substring(0, text.length - 1).split('\n');

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _buffer.writeln(object);
}

/// 内存文件系统。路径 → 字节。
///
/// 读不到的路径抛 [FileSystemException]，与真实实现的行为一致 ——
/// 于是「读不到文件 ⇒ 退出码 2」这条契约测的是同一条代码路径。
final class MemoryFiles {
  MemoryFiles([Map<String, Uint8List>? files]) : _files = <String, Uint8List>{...?files};

  final Map<String, Uint8List> _files;

  /// 当前内容（只读视图）—— 用来断言「写出去的是什么」。
  Map<String, Uint8List> get entries => Map<String, Uint8List>.unmodifiable(_files);

  bool contains(String path) => _files.containsKey(path);

  /// 按 UTF-8 解码读回一个文本文件。
  String textAt(String path) {
    final bytes = _files[path];
    if (bytes == null) {
      throw StateError('内存文件系统里没有 $path（有的是 ${_files.keys.join(', ')}）');
    }
    return utf8.decode(bytes);
  }

  void putBytes(String path, Uint8List bytes) => _files[path] = bytes;

  void putText(String path, String text) => _files[path] = Uint8List.fromList(utf8.encode(text));

  Uint8List read(String path) {
    final bytes = _files[path];
    if (bytes == null) {
      throw FileSystemException('找不到文件', path);
    }
    return bytes;
  }
}

/// 一次 CLI 调用的结果。
final class CliResult {
  CliResult({required this.code, required this.out, required this.err, MemoryFiles? written})
    : written = written ?? MemoryFiles();

  final int code;
  final Capture out;
  final Capture err;

  /// `--out` 写下的文件（内存）。**文本与二进制都进这里**（`putText` /
  /// `putBytes`）—— 对调用方来说它们都只是「这次命令落到某个路径上的字节」，
  /// 而区分文本与二进制是**被测代码**的责任（两个 typedef），不是夹具的。
  final MemoryFiles written;

  /// 非 `--json` 模式的末行。
  String get lastLine => out.lines.last;

  /// NDJSON 模式下的全部行（已解析）。
  List<Map<String, Object?>> get jsonLines => <Map<String, Object?>>[
    for (final line in out.lines) (jsonDecode(line) as Map).cast<String, Object?>(),
  ];

  /// NDJSON 模式下的末行 —— 结果行。**契约要求它永远是最后一条输出。**
  Map<String, Object?> get result => jsonLines.last;
}

/// 跑一次 CLI。两个输出流、文件来源与文件写出都在内存里，
/// 环境变量只认显式传入的。
Future<CliResult> runCli(
  List<String> args, {
  MemoryFiles? files,
  MemoryFiles? written,
  Map<String, String> environment = const <String, String>{},
}) async {
  final out = Capture();
  final err = Capture();
  final fs = files ?? MemoryFiles();
  final sink = written ?? MemoryFiles();
  final code = await runPf(
    args,
    out: out,
    err: err,
    readBytes: fs.read,
    // `--out` 也走内存：否则「报告/导出产物写到了哪个路径」这件事在测试里
    // 只能靠**真磁盘**验证，而那条路径在只读工作区里会以权限错误的形式失败。
    writeText: sink.putText,
    writeBytes: sink.putBytes,
    environment: environment,
  );
  return CliResult(code: code, out: out, err: err, written: sink);
}

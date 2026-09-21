import 'dart:convert';

/// stdout 的对外协议。
///
/// `--json` 时输出 NDJSON（每行一个 JSON 对象），**末行固定是结果行**
/// `{"type":"result", …}`。不用「一个大 JSON 数组包住所有记录」，理由有两条：
///
///   1. 判定发生在流的末尾。过程记录可能先于判定产生（比如 5b 的 import
///      会边写边报），要么全缓冲要么就得等到最后 —— 而缓冲会把
///      「正在做什么」这对长任务是唯一有用的信息抹掉。
///   2. 末行固定 ⇒ 调用方可以**只读最后一行**拿到结论，不必解析整个流。
///      于是中间的过程行可以随实现增删而不破坏契约。
///
/// 非 `--json` 时输出人看的行，但**结果行仍然最后写**，两种模式的信息顺序一致。
final class CliReporter {
  CliReporter({required this.out, required this.json});

  /// 正常输出（stdout）。
  final StringSink out;

  /// 是否为 NDJSON 模式。
  final bool json;

  /// 一行过程记录。`type` 由调用方定（如 `header` / `integrity` / `payload`）。
  void record(String type, [Map<String, Object?> fields = const <String, Object?>{}]) {
    if (json) {
      // 键序是契约的一部分：`type` 必须在最前。
      out.writeln(jsonEncode(<String, Object?>{'type': type, ...fields}));
    } else {
      final details = fields.entries.map((e) => '${e.key}=${e.value}').join(' ');
      out.writeln(details.isEmpty ? type : '$type  $details');
    }
  }

  /// 末行结果。**必须恰好调用一次，且是最后一条输出。**
  void result({
    required int exitCode,
    required String status,
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    if (json) {
      out.writeln(
        jsonEncode(<String, Object?>{
          'type': 'result',
          'status': status,
          'exitCode': exitCode,
          ...fields,
        }),
      );
    } else {
      final details = fields.entries.map((e) => '${e.key}=${e.value}').join(' ');
      out.writeln(details.isEmpty ? '$status (exit $exitCode)' : '$status  $details');
    }
  }
}

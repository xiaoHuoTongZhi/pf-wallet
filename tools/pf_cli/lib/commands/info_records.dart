/// `pf info <file> --records`：把四层产物打成**规范报告**，供跨实现 diff。
///
/// ## 与 `pf info` 默认行为的关系（一处刻意的例外）
///
/// `pf info` 的默认行为是「不解密」，这是它最大的价值：用户说「这个文件打不开」
/// 而还没决定要不要输密码时，它是唯一能给出答案的命令。
///
/// `--records` 是这条原则的**唯一例外，而且是有意的**：逐条清单只存在于解密之后，
/// 没有密码就没有它。所以 `--records` 显式要求密码（与 `verify` 同源：
/// `--password-file` / 环境变量），并且**显式换掉输出格式** —— 它打的不是
/// 人读的行，也不是 NDJSON，而是给 `diff` 用的规范文本。
///
/// 三件事因此在这个模式下同时成立：
///
///   1. 报告本体只走**一个**出口（`--out` 文件，或 stdout）—— 若再往 stdout
///      补一行结果行，diff 就一定不为空，而那个失败看起来像「实现不一致」；
///   2. 诊断（读了哪个文件、密码从哪来、失败原因）一律走 **stderr**；
///   3. `--json` 与本模式**互斥**，同时给是用法错误（退出码 2）。
///      不是懒得支持，而是 NDJSON 的契约（末行固定为结果行）与「逐字节可 diff
///      的规范文本」互斥 —— 让它们共存只会得到一个谁都不敢改的输出。
///
/// ## 为什么复用 read() 而不是自己拼一条解密链
///
/// 与 `verify` 同一条理由：复刻会让这份报告验的是**另一个实现**，
/// 于是「报告一致」不再等于「导入器读得一样」，而跨实现校验的全部价值
/// 恰恰在于它比较的是两套**完整**实现的端到端产物。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_io/pf_io.dart';

import '../exit_codes.dart';
import '../file_source.dart';
import '../password.dart';
import '../records.dart';

/// 执行 `pf info --records`。返回 [ExitCodes] 之一。
///
/// 注意它**不接 [CliReporter]**：本模式的所有输出只有「规范报告」与 stderr 上的
/// 诊断，没有结果行（理由见库注释第 1、3 条）。
Future<int> runInfoRecords({
  required String? file,
  required String? passwordFile,
  required String? outPath,
  required bool json,
  required StringSink out,
  required StringSink err,
  required FileBytesReader readBytes,
  required FileTextWriter writeText,
  required Map<String, String> environment,
}) async {
  if (file == null) {
    err.writeln('用法错误：info --records 需要一个文件参数。');
    err.writeln('  pf info <file> --records [--password-file <f>] [--out <f>]');
    return ExitCodes.toolError;
  }
  if (json) {
    err.writeln('用法错误：--records 与 --json 互斥。');
    err.writeln('  规范报告要拿去与另一套实现逐字节 diff，而 NDJSON 的末行是结果行；');
    err.writeln('  两者共存会让「报告不一致」和「协议不一致」混成同一处失败。');
    err.writeln('  要机器可读的结果请用 pf verify --json。');
    return ExitCodes.toolError;
  }

  final resolution = resolvePassword(
    file: file,
    passwordFile: passwordFile,
    readBytes: readBytes,
    environment: environment,
    command: 'info',
  );
  final failure = resolution.failure;
  if (failure != null) {
    for (final line in failure.messages) {
      err.writeln(line);
    }
    return ExitCodes.toolError;
  }
  final password = resolution.value!.bytes;

  final Uint8List bytes;
  try {
    bytes = readBytes(file);
  } on FileSystemException catch (error) {
    err.writeln('读不到文件：$file —— ${error.message}');
    return ExitCodes.toolError;
  }

  final ImportedFile imported;
  try {
    // 文件名只作记录（`ImportedFile.fileName` 不参与任何路径构造），
    // 而且**不会进报告** —— 报告里出现路径，「同一份文件换个目录跑」就会
    // 变成一次假失败。
    imported = await const PfbImportReader().read(
      fileBytes: bytes,
      password: password,
      fileName: baseNameOf(file),
    );
  } on PfError catch (error) {
    err.writeln('${error.code}：${error.message}');
    return ExitCodes.negative;
  }

  final report = buildCrossCheckReport(imported);
  if (outPath == null) {
    out.write(report);
  } else {
    writeText(outPath, report);
    err.writeln('✓ 四层已写入 $outPath（${report.length} 字符，UTF-8 无 BOM）');
  }
  return ExitCodes.ok;
}

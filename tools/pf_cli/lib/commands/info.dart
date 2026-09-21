/// `pf info <file>`：**不解密**读出容器头部（§4.3 阶段 A+B）。
///
/// 这是 CLI 里唯一「不需要密码」的诊断命令，因此它也是唯一能在
/// **用户说「这个文件打不开」但还不想输密码**时给出答案的命令。
/// 它回答的问题按顺序是三个：
///
///   1. 这是不是一份 PFB 备份？（魔数 / 版本 / 头部 CRC）
///   2. 里面的结构是什么？（KDF 参数、块大小、块数、明文长度、卷信息）
///   3. 字节有没有被动过？（免密内容摘要）
///
/// 第 3 问的答案就是 [PfbFileInspection.isIntact]，它把后面的路一分为二：
/// 摘要不符时**任何密码都打不开**，所以这里返回 1 并就此为止 ——
/// 继续解密只会把「文件坏了」误报成「密码错」。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_io/pf_io.dart';

import '../exit_codes.dart';
import '../file_source.dart';
import '../reporter.dart';
import '../status.dart';

/// 执行 `pf info`。返回 [ExitCodes] 之一。
int runInfo({
  required String? file,
  required CliReporter reporter,
  required StringSink err,
  required FileBytesReader readBytes,
}) {
  if (file == null) {
    err.writeln('用法错误：info 需要一个文件参数。');
    err.writeln('  pf info <file>');
    reporter.result(
      exitCode: ExitCodes.toolError,
      status: 'usage-error',
      fields: const <String, Object?>{'command': 'info'},
    );
    return ExitCodes.toolError;
  }

  final Uint8List bytes;
  try {
    bytes = readBytes(file);
  } on FileSystemException catch (error) {
    // 读不到文件是**基础设施**问题，不是「这份备份不对劲」。
    // 归到 2 而不是 1：脚本据此知道该检查路径，而不是去换一份备份。
    err.writeln('读不到文件：$file —— ${error.message}');
    reporter.result(
      exitCode: ExitCodes.toolError,
      status: 'io-error',
      fields: <String, Object?>{'command': 'info', 'file': file, 'message': error.message},
    );
    return ExitCodes.toolError;
  }

  final PfbFileInspection inspection;
  try {
    inspection = const PfbImportReader().inspect(fileBytes: bytes);
  } on PfError catch (error) {
    // 文件是读到了，但结论为「否」—— 这是**业务结论**（1），不是工具故障。
    // `error.code` 已经过导入器的三态收敛（PFI_E_*），不再是低层码。
    err.writeln('${error.code}：${error.message}');
    reporter.result(
      exitCode: ExitCodes.negative,
      status: statusOfCode(error.code),
      fields: <String, Object?>{
        'command': 'info',
        'file': file,
        'code': error.code,
        'message': error.message,
        'userMessage': error.userMessage,
      },
    );
    return ExitCodes.negative;
  }

  final header = inspection.header;
  reporter.record('header', <String, Object?>{
    'formatVersion': header.formatVersion,
    'minReaderVersion': header.minReaderVersion,
    'featureFlags': '0x${header.featureFlags.toRadixString(16).padLeft(4, '0')}',
    'chunkPlainSizeKiB': header.chunkPlainSizeKiB,
    'chunkCount': header.chunkCount,
    'plaintextLength': header.plaintextLength,
    'volumeIndex': header.volumeIndex,
    'volumeTotal': header.volumeTotal,
    'gzip': header.flagGzip,
    'chunked': header.flagChunked,
    'incremental': inspection.isIncremental,
    'hasAttachments': inspection.hasAttachments,
    'multiVolume': inspection.isMultiVolume,
    // KDF 参数来自文件头，属于**不可信输入**（一个构造的文件可以让
    // memoryKiB 写成 16 GiB 触发 OOM，§3.2）。打出来是为了让
    // 「这个文件要 1 GiB 内存才解得开」这种事在运行前就看得见。
    'kdf': header.kdf.describe(),
    'kdfMemoryKiB': header.kdf.memoryKiB,
    'kdfIterations': header.kdf.iterations,
    'kdfParallelism': header.kdf.parallelism,
  });

  reporter.record('integrity', <String, Object?>{
    'intact': inspection.isIntact,
    'declaredDigest': inspection.verdict.declaredHex,
    'computedDigest': inspection.verdict.computedHex,
    'fileSha256': inspection.fileSha256Hex,
  });

  // info 只在「摘要不符」时返回 1。它**不**因为「文件看起来有点怪」而返回 1：
  // 每一处结构性判断都在 inspect() 里以抛错的形式给出，能走到这里就说明
  // 结构自洽；剩下的唯一一个「否」是内容被改过。
  final intact = inspection.isIntact;
  reporter.result(
    exitCode: intact ? ExitCodes.ok : ExitCodes.negative,
    status: intact ? 'ok' : 'corrupted',
    fields: <String, Object?>{
      'command': 'info',
      'file': file,
      'formatVersion': header.formatVersion,
      'chunkCount': header.chunkCount,
      'plaintextLength': header.plaintextLength,
      'intact': intact,
    },
  );
  return intact ? ExitCodes.ok : ExitCodes.negative;
}

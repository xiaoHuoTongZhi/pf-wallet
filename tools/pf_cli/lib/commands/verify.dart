/// `pf verify <file> --password-file <f>`：**完整**校验到载荷层（§4.3 阶段 A–D）。
///
/// 与 `info` 的分工是一条线：`info` 停在「字节对不对」，`verify` 继续走到
/// 「里面的记录长什么样」。因此它需要一个密码，也正因此它会把三种处境
/// 区分开 —— 这正是导入器的三态（重新输密码 / 换文件 / 升级应用）。
///
/// ## 为什么这里调用 `PfbImportReader.read` 而不是自己复刻一遍解密流程
///
/// 复刻的诱惑在于省一次工作：`read()` 内部会把 `inspect()` 再做一遍
/// （头部解析 + 整文件 SHA-256）。但那样做会让 CLI 验证的是**另一个实现**，
/// 于是「`pf verify` 通过」不再等于「导入器能读」—— 而 CLI 作为独立验证
/// 工具的全部价值，恰恰在于它走的是与导入器**同一条**代码路径。
/// 多算一次哈希是便宜的；一个只在 CLI 里存在的第二套解密流程，
/// 迟早会与导入器分叉，而分叉的那天没有任何测试会响。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_io/pf_io.dart';

import '../exit_codes.dart';
import '../file_source.dart';
import '../password.dart';
import '../reporter.dart';
import '../status.dart';

/// 执行 `pf verify`。返回 [ExitCodes] 之一。
Future<int> runVerify({
  required String? file,
  required String? passwordFile,
  required CliReporter reporter,
  required StringSink err,
  required FileBytesReader readBytes,
  required Map<String, String> environment,
}) async {
  if (file == null) {
    err.writeln('用法错误：verify 需要一个文件参数。');
    err.writeln('  pf verify <file> --password-file <f>');
    reporter.result(
      exitCode: ExitCodes.toolError,
      status: 'usage-error',
      fields: const <String, Object?>{'command': 'verify'},
    );
    return ExitCodes.toolError;
  }

  // ── 密码来源：文件优先，其次环境变量；两条都没有就是用法错误 ──────────
  // 解析逻辑与 `info --records` 共用同一处（`lib/password.dart`）：
  // 两条命令的处方相同，说法就必须相同。
  final resolution = resolvePassword(
    file: file,
    passwordFile: passwordFile,
    readBytes: readBytes,
    environment: environment,
    command: 'verify',
  );
  final failure = resolution.failure;
  if (failure != null) {
    for (final line in failure.messages) {
      err.writeln(line);
    }
    reporter.result(exitCode: ExitCodes.toolError, status: failure.status, fields: failure.fields);
    return ExitCodes.toolError;
  }
  final resolved = resolution.value!;
  final password = resolved.bytes;
  final passwordSource = resolved.source;

  final Uint8List bytes;
  try {
    bytes = readBytes(file);
  } on FileSystemException catch (error) {
    err.writeln('读不到文件：$file —— ${error.message}');
    reporter.result(
      exitCode: ExitCodes.toolError,
      status: 'io-error',
      fields: <String, Object?>{'command': 'verify', 'file': file, 'message': error.message},
    );
    return ExitCodes.toolError;
  }

  // ── 阶段 A+B：先「免密」再「解密」的顺序不能反（§4.3）──────────────
  final PfbFileInspection inspection;
  try {
    inspection = const PfbImportReader().inspect(fileBytes: bytes);
  } on PfError catch (error) {
    err.writeln('${error.code}：${error.message}');
    reporter.result(
      exitCode: ExitCodes.negative,
      status: statusOfCode(error.code),
      fields: <String, Object?>{
        'command': 'verify',
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
    'chunkCount': header.chunkCount,
    'plaintextLength': header.plaintextLength,
    'kdf': header.kdf.describe(),
  });
  reporter.record('integrity', <String, Object?>{
    'intact': inspection.isIntact,
    'declaredDigest': inspection.verdict.declaredHex,
    'computedDigest': inspection.verdict.computedHex,
  });

  if (!inspection.isIntact) {
    // 摘要不符 ⇒ 密文字节已经不是封包时的字节 ⇒ **任何密码都解不开**。
    // 在这里返回 1 而不是继续试解密：继续试只会把「文件坏了」报成
    // 「密码错」，把用户引向反复输密码的方向。
    err.writeln(
      '容器内容摘要不符：声明 ${inspection.verdict.declaredHex}，'
      '实际 ${inspection.verdict.computedHex}。文件已被改动或传输不完整。',
    );
    reporter.result(
      exitCode: ExitCodes.negative,
      status: 'corrupted',
      fields: <String, Object?>{
        'command': 'verify',
        'file': file,
        'code': PfErrorCode.ioCorrupt,
        'declaredDigest': inspection.verdict.declaredHex,
        'computedDigest': inspection.verdict.computedHex,
      },
    );
    return ExitCodes.negative;
  }

  // ── 阶段 C/D：派生密钥 → 解密 → 解压 → 解载荷 ────────────────────────
  final ImportedFile imported;
  try {
    imported = await const PfbImportReader().read(
      fileBytes: bytes,
      password: password,
      fileName: baseNameOf(file),
    );
  } on PfError catch (error) {
    err.writeln('${error.code}：${error.message}');
    reporter.result(
      exitCode: ExitCodes.negative,
      status: statusOfCode(error.code),
      fields: <String, Object?>{
        'command': 'verify',
        'file': file,
        'code': error.code,
        'message': error.message,
        'userMessage': error.userMessage,
      },
    );
    return ExitCodes.negative;
  }

  final payload = imported.payload;
  reporter.record('payload', <String, Object?>{
    'payloadVersion': imported.payloadVersion,
    'exportKind': payload.exportKind,
    'declaredRecordCount': payload.declaredRecordCount,
    'observedRecordCount': payload.observedRecordCount,
    'skippedUnknownRecordCount': payload.skippedUnknownRecordCount,
    'unknownTypes': payload.unknownTypes,
    'contentHash': payload.contentHashHex,
    'recordsRegionBytes': payload.recordsRegionBytes,
  });

  reporter.result(
    exitCode: ExitCodes.ok,
    status: 'ok',
    fields: <String, Object?>{
      'command': 'verify',
      'file': file,
      'passwordSource': passwordSource,
      // manifest 里的 counts 是导出方声明的逐表条数，用于与本地库比对
      // （§4.4 的导入报告）。原样透出，不做解释。
      'counts': imported.manifestCounts,
      'recordCount': payload.observedRecordCount,
      'contentHash': payload.contentHashHex,
    },
  );
  return ExitCodes.ok;
}

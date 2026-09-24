/// `pf export <db> --out <file.pfb>`：把本地库的**全部记录**导出成加密容器（§4.2）。
///
/// ## 它只做「组装」，不自己实现任何一层
///
/// ```
/// 读库 → 阶段行（PfPayloadExtractor，与导入侧共用一张字段表）
///   → NDJSON 载荷（PfbPayloadEncoder：行序、contentHash、manifest 注入）
///   → 先压缩后加密 + 封包 + 读回自校验（PfbExportAssembler）
///   → 落盘（唯一一处 IO）
/// ```
///
/// 三处都有既成实现，本命令一行密码学都不碰。这条纪律不是洁癖：
/// §4.2 的第 5 步是**读回自校验**（用与导入端同一条解包路径把文件读回来），
/// 若这里另走一条组装路径，「导出成功」就不再等于「导入器读得回来」——
/// 而那正是备份唯一的用途。
///
/// ## `verifiedByReadBack` 为 false 时不得报告成功
///
/// 契约原文（`ExportAssemblyResult`）："false 时调用方不得报告导出成功"。
/// 实现上 `assemble` 在任何自校验失败时都会抛 `PFI_E_SELF_CHECK`，
/// 所以返回值理论上恒为 true —— 这里仍然显式检查一次，
/// 因为它是**接口承诺**，而不是「按当前实现推出来的事实」：
/// 将来有人把自校验改成"记录结果但继续返回"，这一行是唯一会拦住
/// 「一份坏备份被报告为成功」的地方。
library;

import 'dart:io';

import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';
import 'package:pf_io/pf_io.dart';

import '../exit_codes.dart';
import '../file_source.dart';
import '../open_db.dart';
import '../password.dart';
import '../reporter.dart';
import '../status.dart';

/// 执行 `pf export`。返回 [ExitCodes] 之一。
Future<int> runExport({
  required String? databaseFile,
  required String? outPath,
  required String? passwordFile,
  required String? databaseKeyFile,
  required String? libraryPath,
  required int plaintextHeaderBytes,
  required CliReporter reporter,
  required StringSink err,
  required FileBytesReader readBytes,
  required FileBytesWriter writeBytes,
  required Map<String, String> environment,
}) async {
  if (databaseFile == null) {
    err.writeln('用法错误：export 需要一个数据库文件参数。');
    err.writeln(
      '  pf export <db> [--out <file.pfb>] [--password-file <f>] [--database-key-file <f>]',
    );
    reporter.result(
      exitCode: ExitCodes.toolError,
      status: 'usage-error',
      fields: const <String, Object?>{'command': 'export'},
    );
    return ExitCodes.toolError;
  }

  // 导出密码（`.pfb` 的口令，与数据库密钥无关，见 database_key.dart 的对照表）。
  final resolution = resolvePassword(
    file: databaseFile,
    passwordFile: passwordFile,
    readBytes: readBytes,
    environment: environment,
    command: 'export',
  );
  final passwordFailure = resolution.failure;
  if (passwordFailure != null) {
    for (final line in passwordFailure.messages) {
      err.writeln(line);
    }
    reporter.result(
      exitCode: ExitCodes.toolError,
      status: passwordFailure.status,
      fields: passwordFailure.fields,
    );
    return ExitCodes.toolError;
  }
  final exportPassword = resolution.value!.bytes;

  final opened = await openLocalDatabase(
    command: 'export',
    databaseFile: databaseFile,
    keyFile: databaseKeyFile,
    libraryPath: libraryPath,
    plaintextHeaderBytes: plaintextHeaderBytes,
    reporter: reporter,
    err: err,
    readBytes: readBytes,
    environment: environment,
  );
  if (!opened.isReady) {
    return opened.exitCode!;
  }
  final database = opened.database!;
  final target = outPath ?? _defaultOutPath(databaseFile);

  try {
    final db = database.db;
    final version = await database.schemaVersion();
    if (version < PfSchema.current) {
      err.writeln('库还没有初始化（schema v$version，期望 v${PfSchema.current}）：先跑 pf init。');
      reporter.result(
        exitCode: ExitCodes.toolError,
        status: 'schema-not-ready',
        fields: <String, Object?>{'command': 'export', 'db': databaseFile},
      );
      return ExitCodes.toolError;
    }

    // 设备标识：导出文件的 manifest 要写它。`readOrCreate` 而不是 `read`：
    // 一个由别的方式建起来的库也可能没有这个键，而 manifest 少一个设备标识
    // 会让接收端无法判断「这份文件来自哪台设备」—— 那是合并裁决的输入之一。
    final deviceId = await AppMetaStore.readOrCreateDeviceId(db);
    final stages = await PfPayloadExtractor.readStages(db);
    final counts = PfPayloadExtractor.countsOf(stages);
    final exportedAt = DateTime.now().millisecondsSinceEpoch;

    final payload = PfbPayloadEncoder.encode(
      manifest: buildPayloadManifest(
        counts: counts,
        deviceId: deviceId,
        deviceName: _deviceName(),
        platform: Platform.operatingSystem,
        exportedAtMilliseconds: exportedAt,
        // 附件标志**据实填写**：库里真有附件行时才置位。
        // 写死 false 会让接收端以为"这份文件不含附件"，而它其实带着
        // 一堆 Base64 数据 —— 一个不影响解密的谎，但会让「有没有附件」
        // 这个判断在上层永远错。
        includesAttachments: (counts['attachment'] ?? 0) > 0,
      ),
      stages: stages,
      generatedAtMilliseconds: exportedAt,
    );

    reporter.record('payload', <String, Object?>{
      'recordCount': payload.recordCount,
      'contentHash': 'sha256:${payload.contentHashHex}',
      'counts': counts,
    });

    final assembled = await PfbExportAssembler().assemble(
      payload: payload,
      password: exportPassword,
      includeAttachments: (counts['attachment'] ?? 0) > 0,
    );
    if (!assembled.verifiedByReadBack) {
      err.writeln('导出未通过读回自校验，已中止（不落盘）。');
      reporter.result(
        exitCode: ExitCodes.toolError,
        status: 'self-check-failed',
        fields: <String, Object?>{'command': 'export', 'db': databaseFile, 'out': target},
      );
      return ExitCodes.toolError;
    }

    writeBytes(target, assembled.fileBytes);

    reporter.record('file', <String, Object?>{
      'out': target,
      'bytes': assembled.fileBytes.length,
      'sha256': assembled.fileSha256Hex,
      'verifiedByReadBack': assembled.verifiedByReadBack,
    });
    reporter.result(
      exitCode: ExitCodes.ok,
      status: 'exported',
      fields: <String, Object?>{
        'command': 'export',
        'db': databaseFile,
        'out': target,
        'bytes': assembled.fileBytes.length,
        'recordCount': assembled.recordCount,
        'contentHash': 'sha256:${assembled.contentHashHex}',
        'fileSha256': assembled.fileSha256Hex,
        'counts': counts,
      },
    );
    return ExitCodes.ok;
  } on PfError catch (error) {
    err.writeln('${error.code}：${error.message}');
    reporter.result(
      exitCode: exitCodeForPfError(error),
      status: statusOfCode(error.code),
      fields: <String, Object?>{
        'command': 'export',
        'db': databaseFile,
        'code': error.code,
        'message': error.message,
        'userMessage': error.userMessage,
      },
    );
    return exitCodeForPfError(error);
  } finally {
    await closeQuietly(database, err);
  }
}

/// `--out` 的缺省值：与库同级的一个带时间戳的文件名。
///
/// 带时间戳是为了**不覆盖**上一次的导出：备份文件的价值在于「还有一份
/// 更早的」，而一个固定的默认名会让第二次导出把第一次抹掉 —— 那不是
/// 备份，那是「只有一份副本的当前状态」。
String _defaultOutPath(String databaseFile) {
  final separator = Platform.pathSeparator;
  final cut = databaseFile.lastIndexOf(RegExp(r'[/\\]'));
  final directory = cut < 0 ? '.' : databaseFile.substring(0, cut);
  final now = DateTime.now().toUtc();
  final stamp =
      '${now.year.toString().padLeft(4, '0')}'
      '${now.month.toString().padLeft(2, '0')}'
      '${now.day.toString().padLeft(2, '0')}'
      '-'
      '${now.hour.toString().padLeft(2, '0')}'
      '${now.minute.toString().padLeft(2, '0')}'
      '${now.second.toString().padLeft(2, '0')}';
  return '$directory$separator${PfBuildInfo.exportFilePrefix}-$stamp'
      '${PfBuildInfo.exportFileExtension}';
}

/// 设备名，进 manifest 供人辨认（`「这份备份是从我哪台机器上导的」`）。
///
/// 取不到时给 `unknown` 而不是抛错：设备名是**信息**而不是**校验项**，
/// 让一个取不到主机名的环境（某些容器）连导出都做不了，是把信息
/// 提升成了前提。
String _deviceName() {
  try {
    final name = Platform.localHostname;
    return name.isEmpty ? 'unknown' : name;
  } catch (_) {
    return 'unknown';
  }
}

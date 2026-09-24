/// `pf import <file.pfb> --db <db>`：把一份导出文件导入本地库（§4.3）。
///
/// ## 顺序：先读文件，再开库
///
/// ```
/// 密码来源 → 读 .pfb 字节 → 解容器/解压/解载荷（PfbImportReader，
/// 内部就是 verify 的那条路径）→ 打开本地库 → ImportApplier.apply
/// ```
///
/// 把「读文件」放在「开库」之前，是为了让**文件本身的问题**先被报出来：
/// 一份损坏的备份与一把错误的数据库密钥同时存在时，用户该先知道哪一件？
/// 显然是前者 —— 因为修好密钥之后他会立刻再撞上它，而那时他会以为
/// 自己的密钥又错了。
///
/// ## 冲突策略的缺省是「中止」，不是「收敛」
///
/// 引擎的缺省（`ImportApplyRequest.strategy`）就是 `abort`：只要有一条记录
/// 需要动本地已有行，整批中止并抛 `PFI_E_CONFLICT`（退出码 1 ——
/// 这是**业务结论**：「需要你裁决」，不是工具故障）。
/// 想让它自己收敛必须显式给 `--strategy converge`，此后冲突会被记录、
/// 导入成功返回 0。
///
/// 这不是保守，而是顺序：**没人显式要求裁决之前，引擎不擅自改用户已有的数据。**
/// 命令行没有冲突面板，`abort` 恰好就是「没有 UI 时的退化形态」——
/// 停下、不猜、不动。
///
/// ## 三条护栏
///
///   1. **备份失败就不导入**（§4.5）。备份在事务之前，因此失败时库里没有变化。
///   2. **覆盖模式的条数确认**（§4.4 护栏第 2 条）：会产生软删而没给
///      `--allow-overwrite-removal` → 在写任何东西之前抛 `StateError`，
///      映射成退出码 2（那是调用方的契约破坏，不是数据状况）。
///   3. **幂等**：整文件 sha256 命中 `imported_file` → 一条写语句都不发，
///      返回 0 并报出上次的 job id。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';
import 'package:pf_io/pf_io.dart';

import '../backup.dart';
import '../exit_codes.dart';
import '../file_source.dart';
import '../open_db.dart';
import '../password.dart';
import '../reporter.dart';
import '../status.dart';

/// 执行 `pf import`。返回 [ExitCodes] 之一。
Future<int> runImport({
  required String? file,
  required String? databaseFile,
  required String? passwordFile,
  required String? databaseKeyFile,
  required String? libraryPath,
  required int plaintextHeaderBytes,
  required String strategy,
  required String mode,
  required String? targetLedgerId,
  required bool allowOverwriteRemoval,
  required String? backupDirectory,
  required CliReporter reporter,
  required StringSink err,
  required FileBytesReader readBytes,
  required Map<String, String> environment,
}) async {
  if (file == null || databaseFile == null) {
    err.writeln('用法错误：import 需要「文件 + 目标库」两个参数。');
    err.writeln(
      '  pf import <file.pfb> --db <db> [--password-file <f>] [--strategy abort|converge]',
    );
    reporter.result(
      exitCode: ExitCodes.toolError,
      status: 'usage-error',
      fields: const <String, Object?>{'command': 'import'},
    );
    return ExitCodes.toolError;
  }

  final parsedStrategy = parseConflictStrategy(strategy);
  final parsedMode = parseImportMode(mode);
  if (parsedStrategy == null || parsedMode == null) {
    if (parsedStrategy == null) {
      err.writeln('用法错误：--strategy 只允许 abort 或 converge，实际「$strategy」。');
    }
    if (parsedMode == null) {
      err.writeln('用法错误：--mode 只允许 merge / replace / supplement-only，实际「$mode」。');
    }
    reporter.result(
      exitCode: ExitCodes.toolError,
      status: 'usage-error',
      fields: <String, Object?>{'command': 'import', 'db': databaseFile, 'file': file},
    );
    return ExitCodes.toolError;
  }

  // 导入密码 = 这份 .pfb 的口令（与本地库的数据库密钥无关）。
  final resolution = resolvePassword(
    file: file,
    passwordFile: passwordFile,
    readBytes: readBytes,
    environment: environment,
    command: 'import',
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
  final importPassword = resolution.value!.bytes;

  final Uint8List bytes;
  try {
    bytes = readBytes(file);
  } on FileSystemException catch (error) {
    err.writeln('读不到文件：$file —— ${error.message}');
    reporter.result(
      exitCode: ExitCodes.toolError,
      status: 'io-error',
      fields: <String, Object?>{'command': 'import', 'file': file, 'message': error.message},
    );
    return ExitCodes.toolError;
  }

  // 与 `pf verify` 同一条读取路径（同一个类、同一个方法）—— 这是
  // 「verify 通过 ⇒ 导入器读得回来」这句话能成立的全部原因。
  final ImportedFile imported;
  try {
    imported = await const PfbImportReader().read(
      fileBytes: bytes,
      password: importPassword,
      fileName: baseNameOf(file),
    );
  } on PfError catch (error) {
    err.writeln('${error.code}：${error.message}');
    reporter.result(
      exitCode: exitCodeForPfError(error),
      status: statusOfCode(error.code),
      fields: <String, Object?>{
        'command': 'import',
        'file': file,
        'db': databaseFile,
        'code': error.code,
        'message': error.message,
        'userMessage': error.userMessage,
      },
    );
    return exitCodeForPfError(error);
  }

  final opened = await openLocalDatabase(
    command: 'import',
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

  try {
    final db = database.db;
    final version = await database.schemaVersion();
    if (version < PfSchema.current) {
      err.writeln('目标库还没有初始化（schema v$version，期望 v${PfSchema.current}）：先跑 pf init。');
      reporter.result(
        exitCode: ExitCodes.toolError,
        status: 'schema-not-ready',
        fields: <String, Object?>{'command': 'import', 'db': databaseFile},
      );
      return ExitCodes.toolError;
    }

    // 本机设备标识：占位实体与覆盖模式的软删都要写它，而且它是版本戳的
    // 组成部分（`ImportRecord.versionStamp`）—— 执行器**不猜**自己是谁。
    final localDeviceId = await AppMetaStore.read(db, AppMetaStore.deviceIdKey);
    if (localDeviceId == null || localDeviceId.isEmpty) {
      err.writeln('目标库里没有设备标识（app_meta.${AppMetaStore.deviceIdKey}）：先跑 pf init 建库。');
      reporter.result(
        exitCode: ExitCodes.toolError,
        status: 'device-id-missing',
        fields: <String, Object?>{'command': 'import', 'db': databaseFile},
      );
      return ExitCodes.toolError;
    }

    final jobId = Ulid.next();
    final now = DateTime.now().millisecondsSinceEpoch;
    final backupDir = backupDirectory ?? FileCopyBackupGateway.defaultDirectoryFor(databaseFile);

    final result = await ImportApplier.apply(
      db: db,
      request: ImportApplyRequest(
        jobId: jobId,
        fileName: baseNameOf(file),
        fileSha256Hex: imported.fileSha256Hex,
        payload: imported.payload,
        nowMilliseconds: now,
        localDeviceId: localDeviceId,
        mode: parsedMode,
        strategy: parsedStrategy,
        targetLedgerId: targetLedgerId,
        allowOverwriteRemoval: allowOverwriteRemoval,
      ),
      backup: FileCopyBackupGateway(databasePath: databaseFile, backupDirectory: backupDir),
    );

    reporter.record('file', <String, Object?>{
      'file': file,
      'sha256': imported.fileSha256Hex,
      'bytes': bytes.length,
      'exportKind': imported.payload.exportKind,
      'declaredRecordCount': imported.payload.declaredRecordCount,
      'observedRecordCount': imported.payload.observedRecordCount,
    });
    reporter.record('apply', <String, Object?>{
      'inserted': result.insertedCount,
      'updated': result.updatedCount,
      'removed': result.removedCount,
      'skipped': result.skippedCount,
      'conflicts': result.conflictCount,
      'alreadyImported': result.alreadyImported,
    });
    if (result.backup != null) {
      // 备份路径进报告而不是日志：它是一次导入唯一的退路，
      // 用户需要在需要它的那一刻能立刻找到它。
      reporter.record('backup', <String, Object?>{'path': result.backup!.backupPath});
    }

    reporter.result(
      exitCode: ExitCodes.ok,
      status: result.alreadyImported ? 'already-imported' : 'imported',
      fields: <String, Object?>{
        'command': 'import',
        'file': file,
        'db': databaseFile,
        'jobId': jobId,
        'mode': parsedMode.wireName,
        'strategy': parsedStrategy.wireName,
        'inserted': result.insertedCount,
        'updated': result.updatedCount,
        'removed': result.removedCount,
        'skipped': result.skippedCount,
        'conflicts': result.conflictCount,
        'unknownTypes': result.unknownTypes,
        'referenceFixes': result.referenceFixes.length,
        'backupPath': result.backup?.backupPath,
        'previousJobId': result.previousJobId,
      },
    );
    return ExitCodes.ok;
  } on PfError catch (error) {
    err.writeln('${error.code}：${error.message}');
    reporter.result(
      exitCode: exitCodeForPfError(error),
      status: statusOfCode(error.code),
      fields: <String, Object?>{
        'command': 'import',
        'file': file,
        'db': databaseFile,
        'code': error.code,
        'message': error.message,
        'userMessage': error.userMessage,
      },
    );
    return exitCodeForPfError(error);
  } catch (error) {
    // 只剩「覆盖模式软删未确认」这条护栏（执行器刻意抛 StateError，
    // 不进错误码体系 —— 它是调用方的契约破坏，不是数据状况）。
    if (error is! StateError) {
      rethrow;
    }
    err.writeln('$error');
    reporter.result(
      exitCode: ExitCodes.toolError,
      status: 'usage-error',
      fields: <String, Object?>{
        'command': 'import',
        'file': file,
        'db': databaseFile,
        'message': '$error',
      },
    );
    return ExitCodes.toolError;
  } finally {
    await closeQuietly(database, err);
  }
}

/// `--strategy` 的取值解析。非法返回 null（调用方报用法错误）。
///
/// 缺省 `abort` —— 见文件头的说明。写成显式函数而不是 `values.byName`：
/// 命令行的稳定标识是 `wireName`（`supplement_only` 那种写法），
/// 用 Dart 枚举名去匹配会把「改个枚举名」变成一次破坏脚本的改动。
ConflictStrategy? parseConflictStrategy(String raw) {
  for (final value in ConflictStrategy.values) {
    if (value.wireName == raw) return value;
  }
  return null;
}

/// `--mode` 的取值解析。除 `wireName` 外额外接受 `supplement-only`
/// 这种「命令行友好」的连字符写法（两种写法的宽度差异只是手感，
/// 不构成两个模式）。
ImportMode? parseImportMode(String raw) {
  final normalized = raw.replaceAll('_', '-');
  for (final value in ImportMode.values) {
    if (value.wireName.replaceAll('_', '-') == normalized) return value;
  }
  return null;
}

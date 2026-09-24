/// 五条读写命令的公共前置：解析密钥 → 绑定引擎 → 打开库；
/// 以及全 CLI 统一的 `PfError` → 退出码映射。
///
/// ## 为什么把「打开」抽出来
///
/// 五条命令里这一步一模一样，而且是**唯一**会把「工具故障」与「业务结论」
/// 分开的地方 —— 忘了 `requireUsable()` 的后果不是一个少写的断言，
/// 而是一份明文库文件（纯 SQLite 会把 `cipher_*` PRAGMA 全部静默接受）。
/// 抄五遍的时候，第二遍就开始有概率漏；写一遍，就只可能漏一个地方，
/// 而那个地方有 `pf engine` 的用例与 gate2 的自检步骤共同守着。
///
/// ## 退出码怎么分（本笔的契约，见 docs/M1_RUNBOOK.md §4）
///
/// | 处境 | 码 | 为什么 |
/// |---|---|---|
/// | 引擎不可用 / 不是 SQLCipher | 2 | 环境缺东西（装库、换构建），不是数据的事 |
/// | 备份写不出来 | 2 | 磁盘/权限，基础设施故障 |
/// | 密钥错 / 库损坏 / 版本过高 / 载荷违规 / 冲突 / 引用悬空 | 1 | **业务结论**：换密钥、换文件、去裁决 |
/// | 参数不对 / 密钥没给 / 密钥格式不对 | 2 | 用法错误 |
///
/// 这条分界不是分类癖：CI 脚本要能区分「这次比对不一致」与「我这条命令
/// 根本没跑起来」。把两者混成一个非零码，最坏的结果是一次环境故障被读成
/// 「备份文件损坏」，然后有人去删一份其实完好的备份。
library;

import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';

import 'database_key.dart';
import 'exit_codes.dart';
import 'file_source.dart';
import 'reporter.dart';
import 'status.dart';

/// 打开库的结果：要么拿到库，要么已经报过错、带着退出码返回。
final class DbOpenOutcome {
  const DbOpenOutcome.ready(this.database) : exitCode = null;

  const DbOpenOutcome.failed(this.exitCode) : database = null;

  final Sqlite3Database? database;
  final int? exitCode;

  bool get isReady => database != null;
}

/// `PfError` → 退出码。判据见文件头那张表。
int exitCodeForPfError(PfError error) => switch (error.code) {
  PfErrorCode.storageEngineUnavailable ||
  PfErrorCode.storageEngineNotCipher ||
  PfErrorCode.ioBackupFailed => ExitCodes.toolError,
  _ => ExitCodes.negative,
};

/// 打开（不存在的文件会被创建）本地加密库，失败时已写好 stderr 与结果行。
///
/// 注意顺序：**先解析密钥，再绑定引擎，最后才碰文件**。三步里任何一步失败
/// 都发生在「文件被创建」之前 —— 于是「密钥没给对」不会留下一个半成品库文件。
///
/// [plaintextHeaderBytes] 是 **required** 而不是带默认值的可选参数，这是刻意的：
/// 它建库时定死、事后不可更改（见 [parsePlaintextHeaderBytes]），
/// 而默认值的存在恰好是「新增一条开库命令时忘了把命令行那个值接进来」的温床 ——
/// 那种写法的表现是命令在本机跑得好好的，只有 iOS 上建的库打不开，
/// 且那时已经无法补救。让编译器在每个调用点问一次，比让测试去追一次便宜得多。
Future<DbOpenOutcome> openLocalDatabase({
  required String command,
  required String databaseFile,
  required String? keyFile,
  required String? libraryPath,
  required CliReporter reporter,
  required StringSink err,
  required FileBytesReader readBytes,
  required Map<String, String> environment,
  required int plaintextHeaderBytes,
}) async {
  final resolution = resolveDatabaseKey(
    databaseFile: databaseFile,
    keyFile: keyFile,
    readBytes: readBytes,
    environment: environment,
    command: command,
  );
  final keyFailure = resolution.failure;
  if (keyFailure != null) {
    for (final line in keyFailure.messages) {
      err.writeln(line);
    }
    reporter.result(
      exitCode: ExitCodes.toolError,
      status: keyFailure.status,
      fields: keyFailure.fields,
    );
    return const DbOpenOutcome.failed(ExitCodes.toolError);
  }
  // 密钥只在这一次调用里活着：下面立刻交给打开流程，之后不再有引用。
  final Uint8List databaseKey = resolution.value!.bytes;

  try {
    // 绑定是进程级的一次性动作。第一次调用把库 dlopen 进来并做身份自检，
    // 之后重复调用返回同一个引擎；**换路径**会抛 StateError（见 engine.dart）。
    final engine = Sqlite3Engine.bind(
      libraryPath: libraryPath,
      libraryLabel: libraryPath ?? 'platform-default',
    );
    final database = await Sqlite3Database.open(
      engine: engine,
      path: databaseFile,
      databaseKey: databaseKey,
      plaintextHeaderBytes: plaintextHeaderBytes,
    );
    return DbOpenOutcome.ready(database);
  } on PfError catch (error) {
    err.writeln('${error.code}：${error.message}');
    reporter.result(
      exitCode: exitCodeForPfError(error),
      status: statusOfCode(error.code),
      fields: <String, Object?>{
        'command': command,
        'db': databaseFile,
        'code': error.code,
        'message': error.message,
        'userMessage': error.userMessage,
      },
    );
    return DbOpenOutcome.failed(exitCodeForPfError(error));
  } catch (error) {
    // 只剩 StateError（同进程内换引擎路径）。它是调用方的契约破坏，
    // 不是数据状况，因此刻意不进错误码体系 —— 报成业务结论会让人
    // 去查库文件，而真正的问题在这一行上面。
    if (error is! StateError) {
      rethrow;
    }
    err.writeln('$error');
    reporter.result(
      exitCode: ExitCodes.toolError,
      status: 'usage-error',
      fields: <String, Object?>{'command': command, 'db': databaseFile, 'message': '$error'},
    );
    return const DbOpenOutcome.failed(ExitCodes.toolError);
  }
}

/// 关库。**幂等**（`Sqlite3Database.close` 保证），失败会被吞掉并写一行 stderr。
///
/// 为什么把失败吞掉：走到这里命令**已经成功或已经失败**，关库只是收尾。
/// 让收尾的异常覆盖掉真正的结论，会出现「库已经写好了但命令报失败」——
/// 那时用户会重跑一遍，而重跑可能因为别的理由失败。
Future<void> closeQuietly(Sqlite3Database database, StringSink err) async {
  try {
    await database.close();
  } catch (error) {
    err.writeln('警告：关闭数据库时出错（结论不受影响）：$error');
  }
}

/// 把 `PlaintextHeaderBytes` 的取值挡在入口处。
///
/// 允许值只有 0（Android/桌面，完全加密头）与 32（iOS）。
/// 在这里挡一次的原因：这个值**建库时定死、之后不可更改**，
/// 而它写错的表现是「库文件在另一台设备上完全打不开」——
/// 那时已经没有任何补救手段。宁可让它在命令行上直接失败。
int? parsePlaintextHeaderBytes(String? raw, StringSink err) {
  if (raw == null) return 0;
  final parsed = int.tryParse(raw);
  if (parsed == null || (parsed != 0 && parsed != PfSqlitePragma.iosPlaintextHeaderBytes)) {
    err.writeln(
      '用法错误：--plaintext-header-bytes 只允许 0（Android/桌面）'
      '或 ${PfSqlitePragma.iosPlaintextHeaderBytes}（iOS），实际「$raw」。',
    );
    err.writeln('这个值建库时定死、之后无法更改：写错的表现是库文件在目标平台上完全打不开。');
    return null;
  }
  return parsed;
}

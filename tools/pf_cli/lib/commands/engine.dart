/// `pf engine`：原生数据库引擎的身份自检。
///
/// 这是所有需要 SQLCipher 的命令（`init` / `seed` / `export` / `import` / `dump`）
/// 的**前置条件**，也是唯一能把「本机的库不是 SQLCipher」这件事在写盘之前
/// 捅出来的地方。
///
/// ## 它为什么不能只是"看一眼版本号"
///
/// 纯 SQLite 对全部 `cipher_*` PRAGMA 都返回成功 —— 不报错、不警告。
/// 也就是说「命令跑通了」这个信号在这里**没有信息量**：
/// 一个没有加密层的库会让 `init` 顺利跑完，然后留下一份明文账本。
/// 因此本命令的判据不是"有没有报错"，而是引擎的身份串
/// （`PRAGMA cipher_version`，见 `pf_data` 的 `engine_verdict.dart`）。
///
/// ## 退出码
///
/// [ExitCodes.ok] / [ExitCodes.toolError]，**不用 1**。
/// 「引擎不对」不是关于某份数据的业务结论，而是**环境不可用** ——
/// 脚本该做的动作是装库/换路径/换构建，不是去换一份备份文件。
/// 把它归到 1 会让 CI 把环境故障读成业务结论（见 exit_codes.dart 的说明）。
library;

import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';

import '../exit_codes.dart';
import '../reporter.dart';
import '../status.dart';

/// 执行 `pf engine`。返回 [ExitCodes] 之一。
int runEngine({
  required String? libraryPath,
  required CliReporter reporter,
  required StringSink err,
}) {
  final EngineObservation observation;
  try {
    observation = Sqlite3Engine.observeLibrary(
      libraryPath: libraryPath,
      libraryLabel: libraryPath == null ? 'platform-default' : 'explicit',
    );
  } catch (error) {
    // 同进程内换库 → StateError，这是**编程错误**（`pf` 是跑一次就退出的
    // 进程，正常走不到这里）。但真走到时必须响，不能默默拿旧引擎的身份
    // 去回答新路径的问题。其余异常原样上抛。
    // 不写 `on StateError`：avoid_catching_errors 禁止按 Error 类型捕获。
    if (error is! StateError) rethrow;
    err.writeln('$error');
    reporter.result(
      exitCode: ExitCodes.toolError,
      status: 'engine-rebind-refused',
      fields: <String, Object?>{'command': 'engine', 'message': '$error'},
    );
    return ExitCodes.toolError;
  }

  reporter.record('engine', <String, Object?>{
    'label': observation.libraryLabel,
    // 平台默认加载时路径是空的 —— 那时路径由 package:sqlite3 决定，
    // 我们**看不到**它。打出 null 而不是猜一个，正是这条记录的意义。
    'path': observation.libraryPath.isEmpty ? null : observation.libraryPath,
    'loaded': observation.loaded,
    'sqliteVersion': observation.sqliteVersion,
    'cipherVersion': observation.cipherVersion,
  });

  final verdict = judgeEngine(observation);
  reporter.record('verdict', <String, Object?>{
    'kind': verdict.kind.name,
    'reason': verdict.reason,
  });

  try {
    requireSqlCipher(verdict);
  } on PfError catch (error) {
    err.writeln('${error.code}：${error.message}');
    reporter.result(
      exitCode: ExitCodes.toolError,
      status: statusOfCode(error.code),
      fields: <String, Object?>{
        'command': 'engine',
        'code': error.code,
        'kind': verdict.kind.name,
        'message': error.message,
        'userMessage': error.userMessage,
      },
    );
    return ExitCodes.toolError;
  }

  reporter.result(
    exitCode: ExitCodes.ok,
    status: 'ok',
    fields: <String, Object?>{
      'command': 'engine',
      'kind': verdict.kind.name,
      'sqliteVersion': observation.sqliteVersion,
      'cipherVersion': observation.cipherVersion,
    },
  );
  return ExitCodes.ok;
}

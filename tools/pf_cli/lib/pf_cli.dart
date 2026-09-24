/// PF Wallet 命令行工具（`pf`）的库入口。
///
/// 把「可测的部分」与「进程的壳」分开：
///   - `bin/pf.dart` 只做一件事：把 `main` 的 argv 交给 [runPf]，把返回值交给
///     `exitCode`。它不含任何分支，因此不需要测。
///   - [runPf] 收 argv、两个输出流、文件读取器与环境变量，返回退出码 ——
///     它是可注入的，测试直接调用，CLI 的每条分支都进得了单测与覆盖率。
///
/// 依赖方向只向下：`pf_cli → pf_io → pf_data → pf_crypto → pf_core`。
/// **不允许反向依赖**（工具包被产品代码引用会让发布的产物里多出一个 CLI）。
library;

export 'backup.dart';
export 'commands/dump.dart';
export 'commands/engine.dart';
export 'commands/export.dart';
export 'commands/import.dart';
export 'commands/info.dart';
export 'commands/info_records.dart';
export 'commands/init.dart';
export 'commands/seed.dart';
export 'commands/verify.dart';
export 'database_key.dart';
export 'engine_fetch.dart';
export 'engine_paths.dart';
export 'exit_codes.dart';
export 'file_source.dart';
export 'open_db.dart';
export 'password.dart';
export 'records.dart';
export 'reporter.dart';
export 'runner.dart';
export 'status.dart';
export 'zip.dart';

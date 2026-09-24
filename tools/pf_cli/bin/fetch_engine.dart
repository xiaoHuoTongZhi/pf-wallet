import 'dart:io';

import 'package:pf_cli/engine_fetch.dart';
import 'package:pf_cli/exit_codes.dart';

/// `fetch_engine` 的进程壳。
///
/// 与 `bin/pf.dart` 同一条纪律：这里**只**取 argv、调 [runFetchEngine]、
/// 把退出码交给 `exitCode`。判断全在 [runFetchEngine] 里 ——
/// 写在 main 里的分支测不到（要起子进程），于是会永远停在 0% 覆盖率上。
///
/// 外面这层 `try` 是有用的：取件是整条链上**唯一联网**的环节，
/// 网络异常的类型比业务异常杂得多，兜住它们并把退出码钉成 2，
/// 比让一个未捕获异常把栈打满屏幕更接近"调用方需要知道的事"。
Future<void> main(List<String> arguments) async {
  try {
    exitCode = await runFetchEngine(arguments, out: stdout, err: stderr);
  } catch (error) {
    stderr.writeln('engine-vendor  status=tool-error  message=$error');
    exitCode = ExitCodes.toolError;
  }
}

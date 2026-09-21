import 'dart:io';

import 'package:pf_cli/pf_cli.dart';

/// `pf` 的进程壳。
///
/// 这里**只**做三件事：取 argv、调用 [runPf]、把退出码交给 `exitCode`。
/// 任何判断都必须在 [runPf] 里 —— 写在 main 里的分支测不到（要起子进程），
/// 于是它们会永远停在 0% 覆盖率上，慢慢变成没人敢改的死角。
///
/// `main` 是 async 的，因为 `verify` 要派生 Argon2id（`read()` 是异步的）。
/// 退出码必须在 `await` **之后**再写：否则进程会以 0 退出，
/// 而调用方看到的「成功」是假的。
Future<void> main(List<String> arguments) async {
  exitCode = await runPf(arguments, out: stdout, err: stderr);
}

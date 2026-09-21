/// 错误码 → CLI `status` 词的映射。
///
/// 为什么要有这一层，而不是把 `PfError.code` 直接放进结果行：
/// 错误码是**给程序看的稳定标识**（`PFI_E_CORRUPT`），而 `status` 是
/// **给人看的处境**（`corrupted`）。两者不能合并 —— 一旦把码当词用，
/// 未来调整码的命名就会变成破坏脚本的改动；而反过来，若只给 `status`
/// 不给码，排查的人就失去了去代码里检索的锚点。所以结果行两个都给。
///
/// 做成纯函数（而非拼接字符串）是为了能被逐条锁死：这张表的每一行
/// 都对应「脚本该做什么」的一个分支，判错一次就会让 CI 把工具故障
/// 读成业务结论。
library;

import 'package:pf_core/pf_core.dart';

/// 把稳定错误码映射成结果行里的 `status`。
///
/// 映射的是**导入侧三态及其邻近处境**（§4.3）—— 它们才是 CLI 会遇到的：
/// 低层码（`PFB_E_*`）在导入器里已经收敛成 `PFI_E_*`，不会到达这一层。
/// 兜底为 `rejected` 而不是抛异常：一个没见过的码不该让 CLI 崩在
/// 「报错」这件事上。
String statusOfCode(String code) => switch (code) {
  PfErrorCode.ioWrongPassword => 'wrong-password',
  PfErrorCode.ioCorrupt => 'corrupted',
  PfErrorCode.ioVersionIncompatible => 'version-incompatible',
  PfErrorCode.ioIncompatible => 'reference-missing',
  PfErrorCode.ioConflict => 'record-conflict',
  PfErrorCode.ioVolumeIncomplete => 'volume-incomplete',
  PfErrorCode.ioBackupFailed => 'backup-failed',
  PfErrorCode.validation => 'payload-invalid',
  _ => 'rejected',
};

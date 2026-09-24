/// 导入前的整库快照：文件级拷贝（§4.5 的 M1 落点）。
///
/// ## 为什么「拷贝文件」在这里是**正确**的快照，而不是偷懒
///
/// 规格 §4.5 描述的是 `ATTACH` + `sqlcipher_export` 的逻辑快照，那是 M3 的
/// 文件网关要做的（它要能处理「多卷、附件、迁移中途」这些情况）。
/// 但 M1 的这个场景有一个很强的额外前提：**库是整库加密的**，
/// 而且快照发生在执行器的写事务之前（§4.3 阶段 H 在阶段 I 之前）。
///
/// 于是：
///   - 整库加密 ⇒ 文件是一块密文整体，拷贝它不会产出「一半明文」的东西，
///     拷贝产物本身就是一个可用的加密库（同一把密钥能打开）；
///   - 写事务尚未开始 ⇒ 没有并发写者，拷贝出来的页集合是自洽的。
///
/// 后者有一个不能忽略的细节：**`-wal` / `-shm` 必须一起拷**。
/// WAL 模式下最新的若干次事务只在 `-wal` 里，只拷主库文件会得到一份
/// 「看起来完好、但少了最后几次写」的备份 —— 而它恰好在恢复时才会被发现，
/// 也就是最需要它准确的那一刻。
///
/// ## 为什么实现里必须让「拷贝不出文件」变成异常
///
/// `ImportApplier` 的契约是「没有备份就不导入」（§4.5）。这里如果静默地
/// 返回一个指向不存在文件的句柄，执行器会照常导入，而用户在失败时
/// 去恢复那个路径 —— 拿到的是 `FileNotFound`。因此拷贝完**要回查文件在不在**，
/// 不在就抛。这不是防御性编程，那是把「退路存在」从假设变成事实的唯一方式。
///
/// ## `commit()` 为什么在本笔里没人调用
///
/// 接口注释说 `commit()` = 「确认导入成功，丢弃备份」。§4.5 的完整语义是
/// **24 小时撤销窗口**：窗口内备份必须留着。M1 里没有撤销命令，
/// 因此命令行**不调用** `commit()` —— 备份留着，用户随时可以手工回滚。
/// 删掉它是 M3 加入撤销窗口时与 UI 一起做的决定，不是这里顺手做的清理。
library;

import 'dart:io';

import 'package:pf_io/pf_io.dart';

/// 把库文件（连同 WAL）拷到一个目录里当快照。
final class FileCopyBackupGateway implements ImportBackupGateway {
  FileCopyBackupGateway({required this.databasePath, required this.backupDirectory});

  /// 被备份的库路径。
  final String databasePath;

  /// 备份目录。不存在会被创建（含父目录）。
  final String backupDirectory;

  /// 目录名后缀 —— 用来把「这是导入前的自动备份」与用户的其它文件分开。
  static const String directorySuffix = 'pf-import-backups';

  /// 按库路径推一个默认备份目录：与库同级的 `pf-import-backups/`。
  ///
  /// 放在库旁边而不是系统的临时目录：备份的意义是「库坏了还能回来」，
  /// 而临时目录会被清理策略删掉（重启、磁盘压力）—— 一个可能已经不在的
  /// 退路，比没有退路更危险，因为它让人以为有。
  static String defaultDirectoryFor(String databasePath) {
    final separator = Platform.pathSeparator;
    final cut = databasePath.lastIndexOf(RegExp(r'[/\\]'));
    if (cut < 0) return directorySuffix;
    return '${databasePath.substring(0, cut)}$separator$directorySuffix';
  }

  @override
  Future<RollbackHandle> snapshot({required String jobId}) async {
    final directory = Directory(backupDirectory);
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    final target = '$backupDirectory${Platform.pathSeparator}pf-pre-import-$jobId.db';

    _copyIfExists(databasePath, target);
    // WAL 与共享内存文件：见文件头第 2 段。缺了它们，备份会静默地
    // 少掉最后一次（或几次）checkpoint 之前的写。
    _copyIfExists('$databasePath-wal', '$target-wal');
    _copyIfExists('$databasePath-shm', '$target-shm');

    if (!File(target).existsSync()) {
      throw StateError('备份失败：没有产出快照文件 $target');
    }
    return FileCopyRollbackHandle(
      backupPath: target,
      databasePath: databasePath,
      copiedSidecars: <String>[
        if (File('$target-wal').existsSync()) '$target-wal',
        if (File('$target-shm').existsSync()) '$target-shm',
      ],
    );
  }

  static void _copyIfExists(String source, String target) {
    final file = File(source);
    if (!file.existsSync()) return;
    file.copySync(target);
  }
}

/// 文件级回滚句柄。
///
/// [rollback] 把备份拷回原位（主库 + 两个 sidecar）；[commit] 删掉备份。
final class FileCopyRollbackHandle implements RollbackHandle {
  FileCopyRollbackHandle({
    required this.backupPath,
    required this.databasePath,
    required this.copiedSidecars,
  });

  @override
  final String backupPath;

  /// 原库路径。
  final String databasePath;

  /// 备份里实际存在的 sidecar 文件（回滚时照这份清单拷回去）。
  final List<String> copiedSidecars;

  @override
  Future<void> rollback() async {
    File(backupPath).copySync(databasePath);
    for (final sidecar in copiedSidecars) {
      // `…/pf-pre-import-<job>.db-wal` → `…/app.db-wal`
      final suffix = sidecar.substring(backupPath.length);
      File(sidecar).copySync('$databasePath$suffix');
    }
  }

  @override
  Future<void> commit() async {
    // 先删 sidecar 再删主库：中途失败时留下主库仍然是一份可用的快照，
    // 反过来则会留下一个「主库没了、sidecar 还在」的目录。
    for (final sidecar in copiedSidecars) {
      final file = File(sidecar);
      if (file.existsSync()) file.deleteSync();
    }
    final main = File(backupPath);
    if (main.existsSync()) main.deleteSync();
  }
}

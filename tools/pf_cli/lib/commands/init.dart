/// `pf init <db>`：建库并把 schema 升到当前版本。
///
/// ## 它的顺序就是 §3.4 的顺序，一步都不省
///
/// ```
/// 绑定引擎 + 身份自检   （纯 SQLite 在这里被拦下，一次写盘都没发生）
///   → openEncrypted     （openSetup ①–⑤ → user_version 验证 ⑥ → postOpen ⑦）
///   → MigrationRunner   （v0 空库 → 执行全部注册迁移；重复调用是空操作）
///   → device.id         （生成并落库；后续命令与导出 manifest 都读它）
/// ```
///
/// 「幂等」不是顺手加的性质，而是**必须**有：这个命令会在
/// 「备份 → 删库 → 重建 → 导入」这条路径上被跑第二次，也会被用户在
/// 怀疑库有问题时反复跑。因此它不检查「库是否已存在」然后拒绝，
/// 而是走同一条路：`user_version` 已经到位时 `run()` 返回 0 步，
/// 设备标识已存在时 `readOrCreateDeviceId` 返回原值。
///
/// ## 为什么不提供 `--force` 去清库
///
/// 「重新初始化」在一个记账应用里等于**删掉全部账目**。
/// 这个动作若被做成一条命令的开关，迟到的一次误敲就没有任何补救；
/// 而它真正的形式是「删除文件」，那一步用户做得出来、也知道自己在做什么。
/// 于是这里只建、不清。
///
/// ## `--seed` 挂在这里，而不是让脚本写两条命令
///
/// 「重建之后要有一个可对照的库」是 §4.5 验收路径的一部分（见
/// docs/M1_RUNBOOK.md §4.2）：`pf init <db> --seed` 一步得到「已初始化
/// + 有样本」的库。拆成 `init` 加 `seed` 两条命令，就会存在一个中间状态
/// ——「建好了但空着」—— 而它只会在两条命令之间的那次失败里出现，
/// 事后表现为「导入之后 dump 对不上」，把排查引向导入那一侧。
library;

import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';

import '../exit_codes.dart';
import '../file_source.dart';
import '../open_db.dart';
import '../reporter.dart';
import '../status.dart';
import 'seed.dart';

/// 执行 `pf init`。返回 [ExitCodes] 之一。
///
/// [seed] 为真时，在**同一个已打开的库**上接着灌样本（[applySeed]）——
/// 不开第二次连接，理由见 `seed.dart` 的文件头。之所以把样本挂到 `init`
/// 上而不是要求脚本写两条命令：验收路径「重建 → 灌样本」必须是一个原子步骤，
/// 否则有人在两条命令之间失败，会得到一个「建好了但空着」的库，
/// 而后续的 dump 对照会把它报成一次数据缺失。
Future<int> runInit({
  required String? databaseFile,
  required String? databaseKeyFile,
  required String? libraryPath,
  required int plaintextHeaderBytes,
  required bool seed,
  required CliReporter reporter,
  required StringSink err,
  required FileBytesReader readBytes,
  required Map<String, String> environment,
}) async {
  if (databaseFile == null) {
    err.writeln('用法错误：init 需要一个数据库文件参数（不存在则创建）。');
    err.writeln('  pf init <db> [--seed] [--database-key-file <f>] [--engine-lib <so>]');
    reporter.result(
      exitCode: ExitCodes.toolError,
      status: 'usage-error',
      fields: const <String, Object?>{'command': 'init'},
    );
    return ExitCodes.toolError;
  }

  final opened = await openLocalDatabase(
    command: 'init',
    databaseFile: databaseFile,
    keyFile: databaseKeyFile,
    libraryPath: libraryPath,
    reporter: reporter,
    err: err,
    readBytes: readBytes,
    environment: environment,
    plaintextHeaderBytes: plaintextHeaderBytes,
  );
  if (!opened.isReady) {
    return opened.exitCode!;
  }
  final database = opened.database!;

  try {
    final db = database.db;
    final applied = await MigrationRunner(db: db).run(registered: kRegisteredMigrations);
    // 设备标识在迁移之后：它要写进 app_meta，而那张表由 v1 迁移创建。
    final deviceId = await AppMetaStore.readOrCreateDeviceId(db);
    final schemaVersion = await database.schemaVersion();

    // 样本在设备标识之后：样本行要带 `device_id`，而它取自刚读出来的这个值
    // （`applySeed` 内部读的是同一个键）。顺序反过来会得到一个
    // 「样本行声称来自一台还不存在的设备」的库。
    final seeded = seed ? await applySeed(db) : null;

    reporter.record('db', <String, Object?>{
      'path': databaseFile,
      'schemaVersion': schemaVersion,
      'appliedSteps': applied,
      'deviceId': deviceId,
      'plaintextHeaderBytes': plaintextHeaderBytes,
      if (seeded != null) 'counts': seeded.counts,
    });
    reporter.result(
      exitCode: ExitCodes.ok,
      // 两个词都是 0：脚本若要区分「刚建好」与「本来就建好了」，
      // 看状态词比看退出码更直接（而它们对调用方的动作没有区别）。
      status: applied == 0 ? 'already-initialized' : 'initialized',
      fields: <String, Object?>{
        'command': 'init',
        'db': databaseFile,
        'schemaVersion': schemaVersion,
        'appliedSteps': applied,
        'deviceId': deviceId,
        // 样本是**附加动作**的结果，用独立的键报出来：`inserted=false`
        // 时库里的既有样本一条都没动，脚本据此可以判断「这次是重建还是复跑」。
        'seeded': seeded?.inserted ?? false,
        if (seeded != null) 'counts': seeded.counts,
      },
    );
    return ExitCodes.ok;
  } on PfError catch (error) {
    err.writeln('${error.code}：${error.message}');
    reporter.result(
      exitCode: exitCodeForPfError(error),
      status: statusOfCode(error.code),
      fields: <String, Object?>{
        'command': 'init',
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

import 'dart:io';

import 'package:args/args.dart';
import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';

import 'backup.dart';
import 'commands/dump.dart';
import 'commands/engine.dart';
import 'commands/export.dart';
import 'commands/import.dart';
import 'commands/info.dart';
import 'commands/info_records.dart';
import 'commands/init.dart';
import 'commands/seed.dart';
import 'commands/verify.dart';
import 'database_key.dart';
import 'exit_codes.dart';
import 'file_source.dart';
import 'open_db.dart';
import 'reporter.dart';

/// 可测试的入口：argv、两个输出流、文件读取/写入与环境变量都从参数进，
/// 退出码从返回值出。
///
/// 不把逻辑写在 `bin/pf.dart` 里，是因为那会迫使测试去起子进程 ——
/// 而覆盖率统计的是**同进程**执行过的行，子进程跑的代码不计入本包。
/// 把入口做成函数，`bin/` 就只剩一行 `exitCode = await runPf(...)`，
/// 于是 CLI 的每一条分支都进得了单测。
///
/// [readBytes] / [writeText] / [writeBytes] 与 [environment] 之所以可注入，
/// 是为了让「文件不存在」「密码从环境变量来」这类分支**不依赖运行环境**
/// 就能测 —— 依赖真磁盘的测试在 CI 上会因为权限模型不同而给出不同结论。
///
/// 读写分成两个口（文本 / 二进制）而不是一个：导出产物 `.pfb` 是**二进制**
/// 容器，任何经由 `String` 的路径都会先做一次编码转换 —— 那正是把一份好备份
/// 写坏的经典方式，而它在小规模测试里通常不会暴露（明文头恰好是 ASCII）。
Future<int> runPf(
  List<String> arguments, {
  required StringSink out,
  required StringSink err,
  FileBytesReader? readBytes,
  FileTextWriter? writeText,
  FileBytesWriter? writeBytes,
  Map<String, String>? environment,
}) async {
  final parser = _buildParser();

  final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (error) {
    err.writeln('用法错误：${error.message}');
    err.writeln();
    err.writeln(usageOf(parser));
    return ExitCodes.toolError;
  }

  if (results.flag('version')) {
    out.writeln(
      'pf ${PfBuildInfo.appVersion}  '
      '(container v${PfBuildInfo.containerFormatVersion}.'
      '${PfBuildInfo.containerFormatMinorVersion}, '
      'payload v${PfBuildInfo.payloadSchemaVersion})',
    );
    return ExitCodes.ok;
  }

  final command = results.command;
  if (command == null) {
    if (results.flag('help')) {
      out.writeln(usageOf(parser));
      return ExitCodes.ok;
    }
    err.writeln('缺少子命令。');
    err.writeln();
    err.writeln(usageOf(parser));
    return ExitCodes.toolError;
  }

  // `pf <命令> --help` 打的是**子命令**的用法。全局帮助里只列命令名，
  // 选项细节留给这一层 —— 否则总帮助会长到没人读。
  if (command.flag('help')) {
    out.writeln(usageOf(parser));
    out.writeln('${command.name} 用法：');
    out.writeln(parser.commands[command.name]?.usage ?? '');
    return ExitCodes.ok;
  }

  final jsonMode = results.flag('json') || command.flag('json');
  final reporter = CliReporter(out: out, json: jsonMode);
  final file = command.rest.isEmpty ? null : command.rest.first;
  final reader = readBytes ?? readFileBytes;
  final env = environment ?? Platform.environment;

  // `ArgResults.name` 是可空的（只有根结果没有名字），而走到这里一定是子命令。
  final name = command.name!;
  final subParser = parser.commands[name];

  // 需要 SQLCipher 的命令共用同一组「怎么打开库」的选项。取法写在**一处**：
  // 五条命令里若有一条自己另取一遍（比如忘了 `?? _envOrNull(...)`），
  // 表现是「同一条命令在 CI 上能跑、在本机不能」，而这类分叉只在
  // 恰好用到那条命令时才暴露 —— 也就是在最不该出问题的时候。
  //
  // 但「写在一处」的前提是**这里能容忍缺失**。八条命令的选项集并不相同
  // （`info` / `verify` 只读 `.pfb`，`engine` 只认原生库），而
  // `ArgResults.option` 对未定义的选项名是**抛** —— 集中取值的代价必须是
  // 「这条命令没有它就取到 null」，不是「另一条命令跟着崩」。
  final engineLib = _engineLibraryPath(_optionIfDefined(subParser, command, 'engine-lib'), env);
  final keyFile = _optionIfDefined(subParser, command, 'database-key-file');

  // 这个值的**坏值必须在任何命令上当场失败**。它建库时定死、之后无法更改，
  // 写错的表现是库在目标平台上完全打不开 —— 因此不允许存在
  // 「某条命令把它当 0 悄悄用掉」的路径（曾经的形状：只有 init 检查它，
  // `pf export --plaintext-header-bytes abc` 于是静默按 0 开库）。
  final headerError = StringBuffer();
  final headerBytes = parsePlaintextHeaderBytes(
    _optionIfDefined(subParser, command, 'plaintext-header-bytes'),
    headerError,
  );
  if (headerBytes == null) {
    for (final line in headerError.toString().trimRight().split('\n')) {
      err.writeln(line);
    }
    reporter.result(
      exitCode: ExitCodes.toolError,
      status: 'usage-error',
      fields: <String, Object?>{'command': name, 'db': file},
    );
    return ExitCodes.toolError;
  }

  switch (name) {
    case 'engine':
      return runEngine(libraryPath: engineLib, reporter: reporter, err: err);
    case 'info':
      // `--records` 走另一条路径，且**不经 reporter**：它产出的是给 diff 用的
      // 规范文本，不是人读行、也不是 NDJSON（理由见 commands/info_records.dart）。
      if (command.flag('records')) {
        return runInfoRecords(
          file: file,
          passwordFile: command.option('password-file'),
          outPath: command.option('out'),
          json: jsonMode,
          out: out,
          err: err,
          readBytes: reader,
          writeText: writeText ?? writeTextFile,
          environment: env,
        );
      }
      return runInfo(file: file, reporter: reporter, err: err, readBytes: reader);
    case 'verify':
      return runVerify(
        file: file,
        // 只在 verify 的子解析器上取这个选项：对 info 取会抛 ArgumentError。
        passwordFile: command.option('password-file'),
        reporter: reporter,
        err: err,
        readBytes: reader,
        environment: env,
      );

    // ── 五条读写命令（#5b）────────────────────────────────────────────────
    case 'init':
      return runInit(
        databaseFile: file,
        databaseKeyFile: keyFile,
        libraryPath: engineLib,
        plaintextHeaderBytes: headerBytes,
        seed: command.flag('seed'),
        reporter: reporter,
        err: err,
        readBytes: reader,
        environment: env,
      );
    case 'seed':
      return runSeed(
        databaseFile: file,
        databaseKeyFile: keyFile,
        libraryPath: engineLib,
        plaintextHeaderBytes: headerBytes,
        reporter: reporter,
        err: err,
        readBytes: reader,
        environment: env,
      );
    case 'export':
      return runExport(
        databaseFile: file,
        outPath: command.option('out'),
        passwordFile: command.option('password-file'),
        databaseKeyFile: keyFile,
        libraryPath: engineLib,
        plaintextHeaderBytes: headerBytes,
        reporter: reporter,
        err: err,
        readBytes: reader,
        // 缺省走**真磁盘**的二进制写入口：`.pfb` 不能经由 String。
        writeBytes: writeBytes ?? writeFileBytes,
        environment: env,
      );
    case 'import':
      return runImport(
        // 位置参数是**导入文件**，目标库在 `--db` —— 这条命令有两个文件参数，
        // 让其中一个当选项比让脚本去数位置更不容易写错。
        file: file,
        databaseFile: command.option('db'),
        passwordFile: command.option('password-file'),
        databaseKeyFile: keyFile,
        libraryPath: engineLib,
        plaintextHeaderBytes: headerBytes,
        strategy: command.option('strategy') ?? 'abort',
        mode: command.option('mode') ?? 'merge',
        targetLedgerId: command.option('target-ledger'),
        allowOverwriteRemoval: command.flag('allow-overwrite-removal'),
        backupDirectory: command.option('backup-dir'),
        reporter: reporter,
        err: err,
        readBytes: reader,
        environment: env,
      );
    case 'dump':
      return runDump(
        databaseFile: file,
        outPath: command.option('out'),
        databaseKeyFile: keyFile,
        libraryPath: engineLib,
        plaintextHeaderBytes: headerBytes,
        json: jsonMode,
        out: out,
        err: err,
        readBytes: reader,
        writeText: writeText ?? writeTextFile,
        environment: env,
      );
  }

  // 够不到：ArgParser 只会派发已注册的子命令。留着是为了让「新增子命令
  // 却忘了加进 switch」表现为一个明确的错误码，而不是静默返回 0。
  err.writeln('未知子命令：$name');
  return ExitCodes.toolError;
}

/// 原生库路径：命令行优先，其次环境变量，**没有第三档默认值**。
///
/// 缺省时交给 `package:sqlite3` 的平台默认选择（那是纯 SQLite），
/// 而自检会因此以 `PFD_E_ENGINE_NOT_CIPHER` 失败。这正是我们要的行为：
/// 少给一个库，命令必须响，而不是悄悄写明文。
///
/// [fromCli] 由 [_optionIfDefined] 取 —— 只读 `.pfb` 的命令没有这个选项，
/// 那时它是 null，于是这条命令仍然能拿到环境变量里那个值（不会用到，
/// 但取值本身不该是崩溃点）。
String? _engineLibraryPath(String? fromCli, Map<String, String> env) =>
    fromCli ?? _envOrNull(env, kSqlCipherLibraryEnvVar);

/// 取子命令的选项 —— **只在该子命令确实定义了这个选项时**。
///
/// `ArgResults.option(name)` 对未定义的选项名抛 `ArgumentError`，而八条
/// 命令的选项集并不相同（`info` / `verify` 只读 `.pfb`，`engine` 只认原生库，
/// 读写五条共用 [_addDatabaseOptions]）。所有「提到 switch 之前统一取一遍」
/// 的选项都必须过这个函数：否则 `pf info` 会因为 `init` 才有的选项而崩，
/// 而报错信息指向 `package:args` 内部 —— 与真正的原因（取值点写早了）无关。
String? _optionIfDefined(ArgParser? subParser, ArgResults command, String name) {
  if (subParser == null || !subParser.options.containsKey(name)) return null;
  return command.option(name);
}

/// 取环境变量的值，缺失或空串都算「没给」。
///
/// 空串要被当成"没给"：`PF_SQLCIPHER_LIB=` 这种写法（例如 CI 里某个变量
/// 展开成了空）如果被当作有效路径传下去，`DynamicLibrary.open('')` 会给出
/// 一个与"没配"完全不同的报错，把排查引向错误方向。
String? _envOrNull(Map<String, String> environment, String name) {
  final value = environment[name];
  if (value == null || value.isEmpty) return null;
  return value;
}

/// 五条命令共用的「怎么打开库」选项。
///
/// 抽成一个函数而不是复制五遍：这三个选项的**文案**是接口的一部分
/// （密钥从哪来、iOS 头长度为什么不能事后改），抄五遍时第二遍就开始漂。
void _addDatabaseOptions(ArgParser parser) {
  parser
    ..addOption(
      'database-key-file',
      abbr: 'k',
      help:
          '数据库密钥的存放文件（推荐）。内容是 64 个十六进制字符（32 字节原始密钥），'
          '末尾的一个换行与 UTF-8 BOM 会被忽略。'
          '注意它与 --password-file 不是同一个东西：后者是 .pfb 的口令。',
    )
    ..addOption(
      'engine-lib',
      help:
          'SQLCipher 动态库的完整路径。缺省读环境变量 $kSqlCipherLibraryEnvVar；'
          '两者都没有时交给 package:sqlite3 的平台默认选择 —— '
          '那是**纯 SQLite**，命令会因此在写盘之前失败。',
    )
    ..addOption(
      'plaintext-header-bytes',
      help:
          '明文头长度：0（Android/桌面，默认）或 ${PfSqlitePragma.iosPlaintextHeaderBytes}（iOS）。'
          '这个值建库时定死、之后无法更改，写错的表现是库在目标平台上完全打不开。',
    );
}

ArgParser _buildParser() {
  final parser =
      ArgParser()
        ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助')
        ..addFlag('version', negatable: false, help: '显示版本与格式版本')
        ..addFlag('json', negatable: false, help: 'stdout 输出 NDJSON，末行固定为结果行');

  parser
    ..addCommand(
      'engine',
      ArgParser()
        ..addFlag('json', negatable: false, help: '同全局 --json')
        ..addFlag('help', abbr: 'h', negatable: false, help: '显示本子命令的帮助')
        ..addOption(
          'engine-lib',
          help:
              'SQLCipher 动态库的完整路径。缺省读环境变量 $kSqlCipherLibraryEnvVar；'
              '两者都没有时交给 package:sqlite3 的平台默认选择 —— '
              '那是**纯 SQLite**，自检会因此在写盘之前失败。',
        ),
    )
    ..addCommand(
      'info',
      ArgParser()
        ..addFlag('json', negatable: false, help: '同全局 --json')
        ..addFlag('help', abbr: 'h', negatable: false, help: '显示本子命令的帮助')
        ..addFlag(
          'records',
          negatable: false,
          help:
              '打出四层规范报告（需密码，与 verify 同源）。'
              '报告给跨实现 diff 用，因此不含文件名/路径/时间戳，也不与 --json 共存。',
        )
        ..addOption(
          'password-file',
          abbr: 'p',
          help: '--records 的密码来源（推荐）。文件末尾的一个换行与 UTF-8 BOM 会被忽略。',
        )
        ..addOption(
          'out',
          help:
              '把报告写到文件（UTF-8，无 BOM）。缺省写 stdout。'
              '跨实现校验必须用它：Windows 上 stdout 的默认编码不是 UTF-8，'
              '靠重定向取字节会得到随机器而变的报告。',
        ),
    )
    ..addCommand(
      'verify',
      ArgParser()
        ..addFlag('json', negatable: false, help: '同全局 --json')
        ..addFlag('help', abbr: 'h', negatable: false, help: '显示本子命令的帮助')
        ..addOption(
          'password-file',
          abbr: 'p',
          help:
              '从文件读主密码（**不要**用命令行参数传密码：'
              '它会进 shell 历史与进程列表）。文件末尾的一个换行与 UTF-8 BOM 会被忽略。',
        ),
    );

  // ── 五条读写命令 ──────────────────────────────────────────────────────
  final init =
      ArgParser()
        ..addFlag('json', negatable: false, help: '同全局 --json')
        ..addFlag('help', abbr: 'h', negatable: false, help: '显示本子命令的帮助')
        ..addFlag('seed', negatable: false, help: '建库之后在同一次调用里灌入样本数据（幂等：库里已有账本则不动）。');
  _addDatabaseOptions(init);
  parser.addCommand('init', init);

  final seed =
      ArgParser()
        ..addFlag('json', negatable: false, help: '同全局 --json')
        ..addFlag('help', abbr: 'h', negatable: false, help: '显示本子命令的帮助');
  _addDatabaseOptions(seed);
  parser.addCommand('seed', seed);

  final export =
      ArgParser()
        ..addFlag('json', negatable: false, help: '同全局 --json')
        ..addFlag('help', abbr: 'h', negatable: false, help: '显示本子命令的帮助')
        ..addOption(
          'out',
          abbr: 'o',
          help:
              '导出文件路径。缺省与库同级、文件名带 UTC 时间戳 —— '
              '带时间戳是为了**不覆盖**上一次的导出（只有一份副本的当前状态不算备份）。',
        )
        ..addOption(
          'password-file',
          abbr: 'p',
          help:
              '导出密码（`.pfb` 的口令）的来源（推荐）。'
              '它与 --database-key-file 不是同一个东西：那个是打开本地库的原始密钥。',
        );
  _addDatabaseOptions(export);
  parser.addCommand('export', export);

  final import =
      ArgParser()
        ..addFlag('json', negatable: false, help: '同全局 --json')
        ..addFlag('help', abbr: 'h', negatable: false, help: '显示本子命令的帮助')
        ..addOption('db', help: '目标数据库路径（不存在则报错，不会创建）。**必需。**')
        ..addOption('password-file', abbr: 'p', help: '导入文件（`.pfb`）的口令来源（推荐）。')
        ..addOption(
          'strategy',
          allowed: <String>['abort', 'converge'],
          defaultsTo: 'abort',
          help:
              '冲突策略。缺省 abort：只要有一条记录需要动本地已有行，整批中止（退出码 1 —— '
              '那是**业务结论**，需要你裁决）。converge 则自行收敛并返回 0。',
        )
        ..addOption(
          'mode',
          allowed: <String>['merge', 'replace', 'supplement-only', 'supplement_only'],
          defaultsTo: 'merge',
          help: '导入模式（§4.4 模式表）：merge / replace / supplement-only。',
        )
        ..addOption(
          'target-ledger',
          help:
              '覆盖模式（--mode replace）的软删范围：只在这个账本下判定「文件没提到」。'
              '不给 ⇒ **不产生任何软删**（范围不确定时宁可少删）。',
        )
        ..addFlag(
          'allow-overwrite-removal',
          negatable: false,
          help:
              '确认「将有 M 条被软删」（§4.4 护栏第 2 条）。'
              '不给而覆盖模式又会产生软删时，命令在写任何东西之前失败。',
        )
        ..addOption(
          'backup-dir',
          help: '导入前整库快照的存放目录。缺省是库同级的 ${FileCopyBackupGateway.directorySuffix}。',
        );
  _addDatabaseOptions(import);
  parser.addCommand('import', import);

  final dump =
      ArgParser()
        ..addFlag('json', negatable: false, help: '同全局 --json（与 dump 互斥）')
        ..addFlag('help', abbr: 'h', negatable: false, help: '显示本子命令的帮助')
        ..addOption(
          'out',
          abbr: 'o',
          help:
              '把库快照写到文件（UTF-8，无 BOM）。缺省写 stdout。'
              '**要 diff 就用它** —— Windows 控制台的默认编码不是 UTF-8，'
              '样本里有中文，靠重定向取字节会得到随机器而变的文本。',
        );
  _addDatabaseOptions(dump);
  parser.addCommand('dump', dump);

  return parser;
}

/// 帮助文本。
String usageOf(ArgParser parser) {
  return '''
pf —— PF Wallet 命令行工具

用法：
  pf <命令> <文件> [选项]

只读命令（不需要 SQLCipher，也不需要数据库密钥）：
  engine  [--engine-lib <so>]  原生数据库引擎的身份自检：能不能打开、
                              打开的是不是 SQLCipher。**不需要任何文件。**
                              所有需要 SQLCipher 的命令都应当先过这一关 ——
                              纯 SQLite 会把 cipher_* PRAGMA 静默接受，
                              然后写出一份明文库文件。
  info    <file>              不解密读出容器头部：格式版本、KDF 参数、块数、
                              明文长度、内容摘要判定。**不需要密码。**
  info    <file> --records    四层规范报告（文件字节 / 压缩载荷 / 记录行 /
                              逐条清单），给跨实现 diff 用。**需要密码** ——
                              逐条清单只存在于解密之后；这是 info 唯一需要
                              密码的模式，也是唯一不按人读格式输出的模式。
  verify  <file> --password-file <f>
                              完整校验：读头部 → 免密完整性 → 派生密钥 →
                              开容器 → 解载荷，报出 manifest 计数。

读写命令（需要 SQLCipher 与数据库密钥）：
  init    <db> [--seed]       建库并把 schema 升到当前版本（幂等：已建好则不动）。
                              --seed 在同一次调用里灌入样本数据（幂等：有账本则不动）。
  seed    <db>                单独灌样本数据。库里已有账本时什么都不做。
  export  <db> [--out <f.pfb>]
                              把库里全部记录导出成加密容器（§4.2）。默认先在内存里
                              读回自校验，通过之后才落盘。
  import  <file.pfb> --db <db>
                              把导出文件导入本地库（§4.3）。缺省 --strategy abort：
                              有冲突就整批中止并返回 1（业务结论，需你裁决）。
  dump    <db> [--out <f>]    把库的**载荷视图**打成规范文本，给两次 dump 之间
                              做 diff（往返验收用它，见 docs/M1_RUNBOOK.md §4）。
                              与 --json 互斥，也不含路径/时间戳/设备标识。

密码与密钥（**刻意都不提供明文命令行参数**：命令行参数会留在 shell 历史与进程列表里）：
  --password-file <f>         导出/导入密码（`.pfb` 口令）。环境变量 $kPasswordEnvVar 亦可。
  --database-key-file <f>     数据库密钥（32 字节原始密钥，64 个十六进制字符）。
                              环境变量 $kDatabaseKeyEnvVar 亦可。**与上面那个不是同一个东西。**

退出码：
  0  成功且结论为「是」
  1  结论为「否」（文件损坏 / 密码错 / 载荷违规 / 导入冲突）—— 业务结论
  2  用法错误或基础设施不可用 —— 工具故障；CI 必须把它当成故障

${parser.usage}
''';
}

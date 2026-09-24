import 'dart:io';

import 'package:args/args.dart';
import 'package:pf_core/pf_core.dart';

import 'commands/info.dart';
import 'commands/info_records.dart';
import 'commands/verify.dart';
import 'exit_codes.dart';
import 'file_source.dart';
import 'reporter.dart';

/// 可测试的入口：argv、两个输出流、文件读取/写入与环境变量都从参数进，
/// 退出码从返回值出。
///
/// 不把逻辑写在 `bin/pf.dart` 里，是因为那会迫使测试去起子进程 ——
/// 而覆盖率统计的是**同进程**执行过的行，子进程跑的代码不计入本包。
/// 把入口做成函数，`bin/` 就只剩一行 `exitCode = await runPf(...)`，
/// 于是 CLI 的每一条分支都进得了单测。
///
/// [readBytes] / [writeText] 与 [environment] 之所以可注入，是为了让
/// 「文件不存在」「密码从环境变量来」这类分支**不依赖运行环境**就能测 ——
/// 依赖真磁盘的测试在 CI 上会因为权限模型不同而给出不同结论。
Future<int> runPf(
  List<String> arguments, {
  required StringSink out,
  required StringSink err,
  FileBytesReader? readBytes,
  FileTextWriter? writeText,
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

  final reporter = CliReporter(out: out, json: results.flag('json') || command.flag('json'));
  final file = command.rest.isEmpty ? null : command.rest.first;
  final reader = readBytes ?? readFileBytes;

  // `ArgResults.name` 是可空的（只有根结果没有名字），而走到这里一定是子命令。
  final name = command.name!;

  switch (name) {
    case 'info':
      // `--records` 走另一条路径，且**不经 reporter**：它产出的是给 diff 用的
      // 规范文本，不是人读行、也不是 NDJSON（理由见 commands/info_records.dart）。
      if (command.flag('records')) {
        return runInfoRecords(
          file: file,
          passwordFile: command.option('password-file'),
          outPath: command.option('out'),
          json: results.flag('json') || command.flag('json'),
          out: out,
          err: err,
          readBytes: reader,
          writeText: writeText ?? writeTextFile,
          environment: environment ?? Platform.environment,
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
        environment: environment ?? Platform.environment,
      );
  }

  // 够不到：ArgParser 只会派发已注册的子命令。留着是为了让「新增子命令
  // 却忘了加进 switch」表现为一个明确的错误码，而不是静默返回 0。
  err.writeln('未知子命令：$name');
  return ExitCodes.toolError;
}

ArgParser _buildParser() {
  final parser =
      ArgParser()
        ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助')
        ..addFlag('version', negatable: false, help: '显示版本与格式版本')
        ..addFlag('json', negatable: false, help: 'stdout 输出 NDJSON，末行固定为结果行');

  parser
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

  return parser;
}

/// 帮助文本。
String usageOf(ArgParser parser) {
  return '''
pf —— PF Wallet 命令行工具

用法：
  pf <命令> <文件> [选项]

命令：
  info    <file>              不解密读出容器头部：格式版本、KDF 参数、块数、
                              明文长度、内容摘要判定。**不需要密码。**
  info    <file> --records    四层规范报告（文件字节 / 压缩载荷 / 记录行 /
                              逐条清单），给跨实现 diff 用。**需要密码** ——
                              逐条清单只存在于解密之后；这是 info 唯一需要
                              密码的模式，也是唯一不按人读格式输出的模式。
  verify  <file> --password-file <f>
                              完整校验：读头部 → 免密完整性 → 派生密钥 →
                              开容器 → 解载荷，报出 manifest 计数。
  init | seed | export | import | dump
                              需要 SQLCipher 的读写命令，在 #5b 落地。

密码来源（verify、info --records）：
  --password-file <f>         从文件读（推荐）
  环境变量 PF_PASSWORD        直接给出密码
  刻意不提供 --password <明文>：命令行参数会留在 shell 历史与进程列表里。

退出码：
  0  成功且结论为「是」
  1  结论为「否」（文件损坏 / 密码错 / 载荷违规）—— 业务结论
  2  用法错误或基础设施不可用 —— 工具故障；CI 必须把它当成故障

${parser.usage}
''';
}

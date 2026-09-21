import 'package:args/args.dart';
import 'package:pf_core/pf_core.dart';

import 'exit_codes.dart';
import 'reporter.dart';

/// 可测试的入口：argv 与两个输出流都从参数进，退出码从返回值出。
///
/// 不把逻辑写在 `bin/pf.dart` 里，是因为那会迫使测试去起子进程 ——
/// 而覆盖率统计的是**同进程**执行过的行，子进程跑的代码不计入本包。
/// 把入口做成函数，`bin/` 就只剩一行 `exitCode = runPf(...)`，
/// 于是 CLI 的每一条分支都进得了单测。
int runPf(List<String> arguments, {required StringSink out, required StringSink err}) {
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

  // `ArgResults.name` 是可空的（只有根结果没有名字），而走到这里一定是子命令。
  final name = command.name!;

  switch (name) {
    case 'info':
    case 'verify':
      return _notYetImplemented(name, reporter, err, file: file);
  }

  // 够不到：ArgParser 只会派发已注册的子命令。留着是为了让「新增子命令
  // 却忘了加进 switch」表现为一个明确的错误码，而不是静默返回 0。
  err.writeln('未知子命令：$name');
  return ExitCodes.toolError;
}

/// 骨架阶段的统一落点。
///
/// 命令的**选项面已经定死**（`info <file>` / `verify <file> [--password-file]`），
/// 实现未落地 —— 这样 5a 要做的只剩填两个函数体，接口不必再动。
///
/// 返回 [ExitCodes.toolError] 而不是 [ExitCodes.negative] 是刻意的：
/// 「还没实现」不是「结论为否」。
/// 若这里返回 1，端到端验收脚本会把「命令还没写完」读成「文件校验不通过」——
/// 而区分这两件事正是本工具存在的意义。
int _notYetImplemented(String name, CliReporter reporter, StringSink err, {String? file}) {
  err.writeln('pf $name：尚未实现（#5a 待落地）。');
  reporter.result(
    exitCode: ExitCodes.toolError,
    status: 'not-implemented',
    fields: <String, Object?>{'command': name, if (file != null) 'file': file},
  );
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
        ..addFlag('help', abbr: 'h', negatable: false, help: '显示本子命令的帮助'),
    )
    ..addCommand(
      'verify',
      ArgParser()
        ..addFlag('json', negatable: false, help: '同全局 --json')
        ..addFlag('help', abbr: 'h', negatable: false, help: '显示本子命令的帮助')
        ..addOption('password-file', abbr: 'p', help: '从文件读主密码（**不要**用命令行参数传密码：它会进 shell 历史与进程列表）'),
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
  verify  <file> --password-file <f>
                              完整校验：读头部 → 免密完整性 → 派生密钥 →
                              开容器 → 解载荷，报出 manifest 计数。
                              （以上两条在 #5a 落地）
  init | seed | export | import | dump
                              需要 SQLCipher 的读写命令，在 #5b 落地。

退出码：
  0  成功且结论为「是」
  1  结论为「否」（文件损坏 / 密码错 / 载荷违规）—— 业务结论
  2  用法错误或基础设施不可用 —— 工具故障；CI 必须把它当成故障

${parser.usage}
''';
}

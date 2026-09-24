/// 五条读写命令的**命令面**契约：用法错误、互斥选项、退出码分流。
///
/// ## 为什么这些用例一条都不需要 SQLCipher
///
/// 它们全部**故意**卡在「打开库之前」：缺参数、缺密钥、选项非法、文件读不到、
/// `--json` 与 `dump` 互斥。于是这个文件在任何机器上都能跑 ——
/// 而「参数写错时给出退出码 2」这件事本来就不该依赖本机装没装引擎。
///
/// 与之对应的另一半（真的建库、真的导出）在 `roundtrip_test.dart` 里，
/// 那个文件需要定版 SQLCipher，缺库时会以带补救命令的异常失败（不跳过）。
///
/// ## 为什么「打开库之前」这个边界值得单独测
///
/// 退出码 2 与 1 的分界是本 CLI 的核心契约（见 `exit_codes.dart`）：
/// **2 = 工具故障，1 = 业务结论**。若「密钥没给」被报成 1，
/// 一次用法错误会被读成「这个库打不开」，然后有人去删一份其实完好的库。
/// 而这些分支**恰好全都发生在打开库之前** —— 它们是这条分界上最容易被
/// 「顺手返回 1」改坏的地方，且改坏之后（在装了引擎的机器上）很难被发现。
library;

import 'package:pf_cli/pf_cli.dart';
import 'package:pf_core/pf_core.dart';
import 'package:test/test.dart';

import 'support/harness.dart';
import 'support/sample.dart';

/// 一份合法的 32 字节密钥（64 个十六进制字符）。**只是密钥**，不参与真实加密。
const String _keyHex =
    '404142434445464748494a4b4c4d4e4f'
    '505152535455565758595a5b5c5d5e5f';

void main() {
  group('缺参数 ⇒ 2（用法错误，不是「结论为否」）', () {
    test('init / seed / export / dump 缺数据库参数', () async {
      for (final name in <String>['init', 'seed', 'export', 'dump']) {
        final r = await runCli(<String>[name]);
        expect(r.code, ExitCodes.toolError, reason: name);
        expect(r.err.text, contains('用法错误'), reason: name);
      }
    });

    test('import 缺文件、或缺 --db，都是 2', () async {
      final noFile = await runCli(<String>['import', '--db', 'x.db']);
      expect(noFile.code, ExitCodes.toolError);
      expect(noFile.err.text, contains('用法错误'));

      final noDb = await runCli(<String>['import', 'x.pfb']);
      expect(noDb.code, ExitCodes.toolError);
      expect(noDb.err.text, contains('用法错误'));
    });

    test('五个子命令的未知选项都是 2', () async {
      for (final name in <String>['init', 'seed', 'export', 'import', 'dump']) {
        final r = await runCli(<String>[name, '--nope']);
        expect(r.code, ExitCodes.toolError, reason: name);
        expect(r.err.text, contains('用法错误'), reason: name);
      }
    });

    test('import 的 --strategy / --mode 取值被 args 挡下', () async {
      for (final args in <List<String>>[
        <String>['import', 'x.pfb', '--db', 'd', '--strategy', 'nope'],
        <String>['import', 'x.pfb', '--db', 'd', '--mode', 'nope'],
      ]) {
        final r = await runCli(args, files: MemoryFiles()..putText('k.txt', _keyHex));
        expect(r.code, ExitCodes.toolError, reason: args.join(' '));
        expect(r.err.text, contains('用法错误'));
      }
    });

    test('--plaintext-header-bytes 只允许 0 或 32', () async {
      final bad = await runCli(<String>['init', 'x.db', '--plaintext-header-bytes', '64']);
      expect(bad.code, ExitCodes.toolError);
      expect(bad.err.text, contains('只允许'));
      // 这个值建库时定死、事后无法更改 —— 所以它在命令行上就该失败，
      // 而不是等到「库在目标平台上打不开」的时候。
      expect(bad.err.text, contains('无法更改'));

      // 64 被挡下，0 / 32 放行（放行之后会因为缺密钥而失败，但那是另一条分支）
      for (final ok in <String>['0', '32']) {
        final r = await runCli(<String>['init', 'x.db', '--plaintext-header-bytes', ok]);
        expect(r.err.text, isNot(contains('只允许')), reason: ok);
      }
    });
  });

  group('缺密钥 / 缺密码 ⇒ 2（用法错误）', () {
    test('init 没有数据库密钥时给出两条来源，且不含明文选项', () async {
      final r = await runCli(<String>['init', 'x.db']);
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains(kDatabaseKeyEnvVar));
      expect(r.err.text, contains('--database-key-file'));
      // 「刻意不提供 --database-key <hex>」这句必须在文案里：它是这个接口
      // 唯一一处会让用户去猜「是不是我参数名写错了」的地方。
      expect(r.err.text, contains('刻意不提供'));
    });

    test('四条先解密钥的命令：缺密钥时都是 2（而不是 1）', () async {
      final files = MemoryFiles()..putText('pw.txt', 'p');
      for (final args in <List<String>>[
        <String>['init', 'x.db'],
        <String>['seed', 'x.db'],
        <String>['export', 'x.db', '--password-file', 'pw.txt'],
        <String>['dump', 'x.db'],
      ]) {
        final r = await runCli(args, files: files);
        expect(r.code, ExitCodes.toolError, reason: args.join(' '));
        expect(
          r.err.text,
          contains(kDatabaseKeyEnvVar),
          reason: '${args.first}：缺密钥必须报成用法错误（2），不是业务结论（1）',
        );
      }
    });

    test('import 的次序：先读 .pfb，再解密钥 —— 两种缺都不是 1', () async {
      // import 是唯一**先碰文件**的命令（见 import.dart 文件头：读不到的文件
      // 是最可能的用户错误，先说出来比先抱怨密钥更指向真正的问题）。
      // 因此「缺密钥」这条分支要在**文件能读、密码对**的前提下才够得着 ——
      // 这里用向量锁死的那份 .pfb，而不是自造一份。
      final fixture = loadVectorFixture();
      final sample = fixture.full;
      final files =
          MemoryFiles()
            ..putBytes(sample.fileName, sample.fileBytes)
            ..putText('pw.txt', fixture.password);

      // 文件读不到：报文件，不是密钥。
      final missingPfb = await runCli(<String>[
        'import',
        'not-here.pfb',
        '--db',
        'x.db',
        '--password-file',
        'pw.txt',
      ], files: files);
      expect(missingPfb.code, ExitCodes.toolError);
      expect(missingPfb.err.text, contains('not-here.pfb'));

      // 文件能读、密码对、目标库密钥没给：这时才轮到密钥那条分支。
      final missingKey = await runCli(<String>[
        'import',
        sample.fileName,
        '--db',
        'x.db',
        '--password-file',
        'pw.txt',
      ], files: files);
      expect(missingKey.code, ExitCodes.toolError);
      expect(missingKey.err.text, contains(kDatabaseKeyEnvVar));
    });

    test('密钥文件不存在 ⇒ 2，且报的是 io-error', () async {
      // 不读 `r.result`：dump 的结果行**刻意不走 stdout**（那份文本要逐字节
      // diff，多一行结果行会让「数据不一致」与「命令没跑起来」混在一起），
      // 于是它落在 stderr 上 —— 断言也得落在那里。
      final r = await runCli(<String>['dump', 'x.db', '--database-key-file', 'missing.txt']);
      expect(r.code, ExitCodes.toolError);
      expect(r.out.text, isEmpty, reason: 'dump 失败时 stdout 必须一个字节都没有');
      expect(r.err.text, contains('io-error'));
      expect(r.err.text, contains('missing.txt'));
    });

    test('export 缺导出密码 ⇒ 2（与缺数据库密钥是两件事）', () async {
      final files = MemoryFiles()..putText('k.txt', _keyHex);
      final r = await runCli(<String>[
        '--json',
        'export',
        'x.db',
        '--database-key-file',
        'k.txt',
      ], files: files);
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains(kPasswordEnvVar));
      expect(r.result['status'], 'usage-error');
    });

    test('export 的密码文件读不到 ⇒ 2', () async {
      final files = MemoryFiles()..putText('k.txt', _keyHex);
      final r = await runCli(<String>[
        '--json',
        'export',
        'x.db',
        '--database-key-file',
        'k.txt',
        '--password-file',
        'nope.txt',
      ], files: files);
      expect(r.code, ExitCodes.toolError);
      expect(r.result['status'], 'io-error');
    });
  });

  group('import：先读文件，再开库', () {
    test('导入文件读不到 ⇒ 2，且**在开库之前**就返回', () async {
      final files =
          MemoryFiles()
            ..putText('k.txt', _keyHex)
            ..putText('pw.txt', 'password');
      final r = await runCli(<String>[
        '--json',
        'import',
        'missing.pfb',
        '--db',
        'x.db',
        '--database-key-file',
        'k.txt',
        '--password-file',
        'pw.txt',
      ], files: files);
      expect(r.code, ExitCodes.toolError);
      expect(r.result['status'], 'io-error');
      expect(r.err.text, contains('读不到文件'));
    });
  });

  group('dump：与 --json 互斥，且 stdout 上只有规范文本', () {
    test('同时给 --json 与 dump ⇒ 2，并说明为什么', () async {
      final r = await runCli(<String>[
        'dump',
        'x.db',
        '--json',
      ], files: MemoryFiles()..putText('k.txt', _keyHex));
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('互斥'));
      // 这条互斥不是洁癖：规范文本要拿去逐字节 diff，而 NDJSON 的末行是结果行。
      expect(r.err.text, contains('结果行'));
    });

    test('全局 --json 放在子命令之前同样被挡下', () async {
      final r = await runCli(<String>[
        '--json',
        'dump',
        'x.db',
      ], files: MemoryFiles()..putText('k.txt', _keyHex));
      expect(r.code, ExitCodes.toolError);
      expect(r.err.text, contains('互斥'));
    });

    test('dump 失败时 stdout 保持干净（诊断只走 stderr）', () async {
      final r = await runCli(<String>[
        'dump',
        'x.db',
      ], files: MemoryFiles()..putText('k.txt', _keyHex));
      expect(r.code, ExitCodes.toolError);
      expect(r.out.text, isEmpty, reason: 'stdout 上一次污染都会让下游 diff 不为空，而那个失败看起来像「数据不一致」');
    });
  });

  group('帮助文本：五条命令的选项都要能查到', () {
    test('每条命令的 --help 都列出它自己的选项', () async {
      const expected = <String, List<String>>{
        'init': <String>[
          '--seed',
          '--database-key-file',
          '--engine-lib',
          '--plaintext-header-bytes',
        ],
        'seed': <String>['--database-key-file'],
        'export': <String>['--out', '--password-file', '--database-key-file'],
        'import': <String>[
          '--db',
          '--strategy',
          '--mode',
          '--target-ledger',
          '--allow-overwrite-removal',
          '--backup-dir',
        ],
        'dump': <String>['--out', '--database-key-file'],
      };
      for (final entry in expected.entries) {
        final r = await runCli(<String>[entry.key, '--help']);
        expect(r.code, ExitCodes.ok, reason: entry.key);
        for (final option in entry.value) {
          expect(r.out.text, contains(option), reason: '${entry.key} 的帮助里缺 $option');
        }
      }
    });

    test('总帮助里说明了两套秘密不是同一个东西', () async {
      final r = await runCli(<String>['--help']);
      expect(r.code, ExitCodes.ok);
      expect(r.out.text, contains('不是同一个东西'));
    });
  });

  group('退出码常量', () {
    test('三条分界与 exit_codes.dart 的契约一致', () {
      expect(ExitCodes.ok, 0);
      expect(ExitCodes.negative, 1);
      expect(ExitCodes.toolError, 2);
      // 「引擎不可用 / 备份失败 ⇒ 2」的映射单独锁一次：它在下层（open_db.dart），
      // 但它的取值决定了上面那组用例的期望值。
      expect(exitCodeForPfError(DomainError.validation(detail: 'x')), ExitCodes.negative);
      expect(exitCodeForPfError(StorageError.engineUnavailable(detail: '缺库')), ExitCodes.toolError);
      expect(
        exitCodeForPfError(ImportExportError.backupFailed(detail: '写不出备份')),
        ExitCodes.toolError,
      );
      expect(
        exitCodeForPfError(ImportExportError.conflict(count: 2)),
        ExitCodes.negative,
        reason: '「需要你裁决」是业务结论 —— CI 要能把它与「命令没跑起来」分开',
      );
    });
  });

  // ── 以下两组锁的是本笔**自己造出来又修掉**的两个回归。────────────────
  //
  // 两个都不是「某个函数写错了」，而是**接口形状**错了 —— 这类改动不会在
  // 它被引入的那次测试里失败，只在某条恰好走到那条分支的命令上失败。
  // 因此锁也必须锁在「形状」这一层，而不是锁某一个被修过的行。

  group('回归 ①：共用选项的取值不能因命令而异', () {
    test('八条命令都调用得起来 —— 没有哪条会因「别条命令的选项」而崩', () async {
      // 曾经的形状：`--engine-lib` / `--database-key-file` /
      // `--plaintext-header-bytes` 三处取值被**提到 dispatch 之前**统一取
      // （本意是「取法写在一处」），但八条命令的选项集并不相同 ——
      // `ArgResults.option` 对未定义的选项名是**抛** `ArgumentError`，
      // 于是 `pf info` 直接崩，205 条测试红了 96 条（整个包的一半）。
      //
      // 这里每条命令都用一个不存在的文件名来跑：断言的不是它的结论，
      // 而是「它走到了一条能给出退出码的路径上」——崩溃会在这里被抓住。
      for (final name in <String>[
        'engine',
        'info',
        'verify',
        'init',
        'seed',
        'export',
        'import',
        'dump',
      ]) {
        final r = await runCli(<String>[name, 'nothing-here'], files: MemoryFiles());
        expect(
          r.code,
          isIn(<int>[ExitCodes.ok, ExitCodes.negative, ExitCodes.toolError]),
          reason: '$name：必须给出退出码，而不是把异常抛到调用方',
        );
        expect(
          r.err.text,
          isNot(contains('Could not find an option')),
          reason: '$name：报这句就说明有选项取值点写在了不认识它的命令上',
        );
      }
    });

    test('不读本地库的命令**不得**多出一个 --engine-lib', () async {
      // 上一条留了个后门：给所有子解析器都加上 `--engine-lib` 也能让它变绿，
      // 但那样 `pf info` 的帮助里就会出现一个它根本不用的选项，
      // 而「多一个看起来能用的选项」比崩溃更难查 —— 你会以为它生效了。
      //
      // 断言必须落在**子命令自己那段 usage** 上：`pf <cmd> --help` 会先打总帮助，
      // 而总帮助里 `engine` 那条本来就写着 `--engine-lib`（那是它的合法用法），
      // 对着整段输出断言会恒定失败 —— 一个永远红的测试等于没有测试。
      for (final name in <String>['info', 'verify']) {
        final r = await runCli(<String>[name, '--help']);
        expect(r.code, ExitCodes.ok, reason: name);
        final marker = '$name 用法：';
        expect(r.out.text, contains(marker), reason: '$name：子命令用法块没打出来');
        final ownUsage = r.out.text.substring(r.out.text.indexOf(marker) + marker.length);
        expect(
          ownUsage,
          isNot(contains('--engine-lib')),
          reason: '$name 不解密、不开本地库，不该有这个选项（这正是取值必须容忍缺失的原因）',
        );
      }
    });
  });

  group('回归 ②：--plaintext-header-bytes 的坏值必须在**每条**命令上当场失败', () {
    test('五条命令都拒绝「不是 0 也不是 32」的值', () async {
      // 曾经的形状：解析上提之后只有 `init` 检查结果，`dump` 写成
      // `headerBytes ?? 0`，`seed` / `export` / `import` 干脆没往后传 ——
      // 于是 `pf export --plaintext-header-bytes abc` 会**静默按 0 开库**。
      // 而 0 与 32 的区别是「库在 iOS 上完全打不开」，且建库时定死、无法更改。
      final files =
          MemoryFiles()
            ..putText('k.txt', _keyHex)
            ..putText('pw.txt', 'password');
      for (final args in <List<String>>[
        <String>['init', 'x.db', '--plaintext-header-bytes', 'abc'],
        <String>['seed', 'x.db', '--plaintext-header-bytes', 'abc'],
        <String>['export', 'x.db', '--plaintext-header-bytes', 'abc'],
        <String>['import', 'x.pfb', '--db', 'x.db', '--plaintext-header-bytes', 'abc'],
        <String>['dump', 'x.db', '--plaintext-header-bytes', 'abc'],
      ]) {
        final r = await runCli(args, files: files);
        expect(r.code, ExitCodes.toolError, reason: args.join(' '));
        expect(r.err.text, contains('只允许'), reason: args.first);
        expect(r.err.text, contains('无法更改'), reason: '${args.first}：要让它失败的理由可读，而不只是语法错');
      }
    });

    test('五条命令都放行 0 与 32（拒绝要只针对坏值）', () async {
      // 防的是「一刀切」式的修法：把整条分支砍掉也能让上一条变绿。
      final files =
          MemoryFiles()
            ..putText('k.txt', _keyHex)
            ..putText('pw.txt', 'password');
      for (final value in <String>['0', '32']) {
        for (final args in <List<String>>[
          <String>['init', 'x.db', '--plaintext-header-bytes', value],
          <String>['seed', 'x.db', '--plaintext-header-bytes', value],
          <String>['export', 'x.db', '--plaintext-header-bytes', value],
          <String>['import', 'x.pfb', '--db', 'x.db', '--plaintext-header-bytes', value],
          <String>['dump', 'x.db', '--plaintext-header-bytes', value],
        ]) {
          final r = await runCli(args, files: files);
          expect(r.err.text, isNot(contains('只允许')), reason: '${args.join(' ')}：$value 是合法值，不该被挡');
        }
      }
    });
  });
}

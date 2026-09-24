/// §4.5 的端到端往返验收 —— 本笔的最终判据。
///
/// ```
/// pf init --seed → pf dump before → pf export → pf verify
///   → 删库 → pf init → pf import → pf dump after → diff 必须为空
/// ```
///
/// ## 为什么这个文件必须走真磁盘、真引擎
///
/// 其余 CLI 测试都把 `readBytes` / `writeBytes` 与环境变量注入了内存夹具，
/// 那是为了让反例可测。但往返验收要回答的问题恰恰是**真实那一遍**：
/// 库真的落在盘上了吗、`.pfb` 真的写成了二进制吗、重新打开一个**新库**
/// 真的能把数据收回去吗。注入之后这些问题都会被夹具悄悄答成「是」。
///
/// 因此这里不注入任何东西：真 `dart:io`、真 `PF_DATABASE_KEY` 文件、
/// 真 SQLCipher 动态库。目录用 `Directory.systemTemp`，跑完删掉 ——
/// 产物（`*.db` / `*.pfb`）都在 `tracked_paths` 的 deny 名单上，
/// 一步都不能落进仓库。
///
/// ## 为什么它需要定版原生库，以及缺库时为什么必须「响」
///
/// 走真库就必须有 SQLCipher。清单不在时 [loadVendoredEnginePaths] 会抛，
/// 且异常里带着补救命令（`melos run engine:fetch`）—— **不跳过**：
/// 「一条都没跑」与「全部通过」在报告里长得一模一样，而这个文件是本笔
/// 唯一的端到端证据。
///
/// ## 判据为什么是「逐字节」而不是「看起来差不多」
///
/// `dump` 的输出是规范文本（键序归一、无路径、无时间戳、无设备标识），
/// 因此**一次正确的往返必须产出完全相同的字节**。改成「包含主要字段」
/// 之类的软断言，就等于放弃了「没有任何一段在悄悄改写数据」这个结论。
library;

import 'dart:io';

import 'package:pf_cli/pf_cli.dart';
import 'package:test/test.dart';

import 'support/engine_support.dart';
import 'support/harness.dart';

/// 固定密钥（32 字节 → 64 个十六进制字符）。写进文件，不走命令行明文。
const String _keyHex =
    '404142434445464748494a4b4c4d4e4f'
    '505152535455565758595a5b5c5d5e5f';

/// 导出密码（`.pfb` 的口令）。与上面的数据库密钥**不是同一个东西**。
const String _exportPassword = 'roundtrip-password';

void main() {
  late String libraryPath;
  late Directory tmp;

  setUpAll(() {
    libraryPath = loadVendoredEnginePaths().require('sqlcipher').path;
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pf_cli_roundtrip_');
  });

  tearDown(() {
    if (tmp.existsSync()) {
      tmp.deleteSync(recursive: true);
    }
  });

  String path(String name) => '${tmp.path}${Platform.pathSeparator}$name';

  /// 写一个密钥文件（末尾带一个换行 —— 真实用户就是这么存的）。
  String writeKeyFile() {
    final file = File(path('db.key'));
    file.writeAsStringSync('$_keyHex\n');
    return file.path;
  }

  String writePasswordFile() {
    final file = File(path('export.pw'));
    file.writeAsStringSync('$_exportPassword\n');
    return file.path;
  }

  /// 跑一次 CLI，**走真的磁盘与真的环境变量**，并把 stdout/stderr 收进内存。
  ///
  /// 与 `runCli` 的区别只有一处：这里不传 `readBytes` / `writeBytes` /
  /// `environment`，于是 `runPf` 里那几个 `?? 默认实现` 的右侧第一次被执行到。
  Future<CliResult> run(List<String> args) async {
    final out = Capture();
    final err = Capture();
    final code = await runPf(args, out: out, err: err);
    return CliResult(code: code, out: out, err: err);
  }

  /// 五条命令共用的「怎么拿到库」三个选项。
  List<String> dbOptions(String keyFile) => <String>[
    '--database-key-file',
    keyFile,
    '--engine-lib',
    libraryPath,
  ];

  /// 删掉一个库连同它的 WAL / 共享内存 sidecar。
  void deleteDatabase(String dbPath) {
    for (final suffix in <String>['', '-wal', '-shm']) {
      final file = File('$dbPath$suffix');
      if (file.existsSync()) {
        file.deleteSync();
      }
    }
  }

  test('往返：init --seed → dump → export → verify → 删库 → init → import → dump，逐字节一致', () async {
    final keyFile = writeKeyFile();
    final passwordFile = writePasswordFile();

    // ── 1. 建库 + 灌样本（一次调用，同一个已打开的库）────────────────────
    final initA = await run(<String>[
      '--json',
      'init',
      path('a.db'),
      '--seed',
      ...dbOptions(keyFile),
    ]);
    expect(initA.code, ExitCodes.ok, reason: initA.err.text);
    expect(initA.result['status'], 'initialized');
    expect(initA.result['seeded'], isTrue, reason: '空库上第一次灌样本必须真的写入');
    final countsA = (initA.result['counts']! as Map).cast<String, Object?>();
    expect(countsA['ledger'], 1);
    expect(countsA['account'], 2);
    expect(countsA['category'], 2);
    expect(countsA['txn'], 3);

    // 幂等：再跑一次不该重复记账（重复灌样本会把同一笔消费记两次）。
    final initAgain = await run(<String>[
      '--json',
      'init',
      path('a.db'),
      '--seed',
      ...dbOptions(keyFile),
    ]);
    expect(initAgain.code, ExitCodes.ok);
    expect(initAgain.result['status'], 'already-initialized');
    expect(initAgain.result['seeded'], isFalse);

    // ── 2. dump before ────────────────────────────────────────────────────
    final beforePath = path('before.txt');
    final dumpBefore = await run(<String>[
      'dump',
      path('a.db'),
      '--out',
      beforePath,
      ...dbOptions(keyFile),
    ]);
    expect(dumpBefore.code, ExitCodes.ok, reason: dumpBefore.err.text);
    final before = File(beforePath).readAsBytesSync();
    expect(before, isNotEmpty);

    // ── 3. export（自带读回自校验，通过才落盘）────────────────────────────
    final pfbPath = path('backup.pfb');
    final export = await run(<String>[
      '--json',
      'export',
      path('a.db'),
      '--out',
      pfbPath,
      '--password-file',
      passwordFile,
      ...dbOptions(keyFile),
    ]);
    expect(export.code, ExitCodes.ok, reason: export.err.text);
    expect(export.result['status'], 'exported');
    expect(export.result['recordCount'], 8, reason: '1 账本 + 2 分类 + 2 账户 + 3 交易');
    expect(export.err.text, isNot(contains('警告')));

    final pfbBytes = File(pfbPath).readAsBytesSync();
    expect(pfbBytes.length, export.result['bytes']);
    // 二进制落盘口没有被 String 编码污染过 —— 明文头恰好是 ASCII 时
    // 「写坏了」在测试里通常不会暴露，所以这里直接比对字节数而非文本内容。
    expect(pfbBytes.length, greaterThan(100));

    // ── 4. verify：与导入器同一条读取路径 ─────────────────────────────────
    final verify = await run(<String>[
      '--json',
      'verify',
      pfbPath,
      '--password-file',
      passwordFile,
    ]);
    expect(verify.code, ExitCodes.ok, reason: verify.err.text);
    expect(verify.result['status'], 'ok');
    expect(verify.result['counts'], isA<Map<String, Object?>>());

    // ── 5. 删库，重建一个**新的**库（设备标识与上一个不同）────────────────
    deleteDatabase(path('a.db'));
    expect(File(path('a.db')).existsSync(), isFalse);

    final initB = await run(<String>['--json', 'init', path('b.db'), ...dbOptions(keyFile)]);
    expect(initB.code, ExitCodes.ok, reason: initB.err.text);
    expect(initB.result['seeded'], isFalse, reason: '重建时不灌样本 —— 数据必须**全部来自导入**');
    final deviceA = '${initA.result['deviceId']}';
    final deviceB = '${initB.result['deviceId']}';
    expect(deviceB, isNot(deviceA), reason: '两个库的设备标识本来就不同 —— dump 不含它，正是为了让这次往返能被逐字节比较');

    // ── 6. import ─────────────────────────────────────────────────────────
    final import = await run(<String>[
      '--json',
      'import',
      pfbPath,
      '--db',
      path('b.db'),
      '--password-file',
      passwordFile,
      ...dbOptions(keyFile),
    ]);
    expect(import.code, ExitCodes.ok, reason: import.err.text);
    expect(import.result['status'], 'imported');
    expect(import.result['strategy'], 'abort', reason: '缺省策略是 abort');
    expect(import.result['inserted'], 8);
    expect(import.result['updated'], 0);
    expect(import.result['removed'], 0);
    expect(import.result['conflicts'], 0);
    // 备份在导入之前就落好了（「没有备份就不导入」）。
    final backupPath = '${import.result['backupPath']}';
    expect(File(backupPath).existsSync(), isTrue, reason: '导入的退路必须真的存在');

    // ── 7. dump after + 逐字节比对 ────────────────────────────────────────
    final afterPath = path('after.txt');
    final dumpAfter = await run(<String>[
      'dump',
      path('b.db'),
      '--out',
      afterPath,
      ...dbOptions(keyFile),
    ]);
    expect(dumpAfter.code, ExitCodes.ok, reason: dumpAfter.err.text);
    final after = File(afterPath).readAsBytesSync();

    expect(
      after,
      before,
      reason:
          '往返后库的载荷视图必须逐字节相同。若这里红了，先用两份文本的 row.* 明细定位'
          '是哪一列变了：stage.*.sha256 只告诉你「哪张表变了」。',
    );

    // 顺带确认这份「一致」不是「两边都是空的」——
    // 空对空也能逐字节相等，而那说明不了任何事。
    final text = String.fromCharCodes(after);
    expect(text, contains('stage.txn.count=3'));
    expect(text, contains('stage.account.count=2'));
    expect(text, contains('row.ledger.0000='));
  });

  test('往返：重复导入同一个文件走幂等短路，不改动任何数据', () async {
    final keyFile = writeKeyFile();
    final passwordFile = writePasswordFile();

    expect(
      (await run(<String>['init', path('a.db'), '--seed', ...dbOptions(keyFile)])).code,
      ExitCodes.ok,
    );
    final pfbPath = path('backup.pfb');
    expect(
      (await run(<String>[
        'export',
        path('a.db'),
        '--out',
        pfbPath,
        '--password-file',
        passwordFile,
        ...dbOptions(keyFile),
      ])).code,
      ExitCodes.ok,
    );

    final dbB = path('b.db');
    expect((await run(<String>['init', dbB, ...dbOptions(keyFile)])).code, ExitCodes.ok);

    Future<int> importOnce() => run(<String>[
      'import',
      pfbPath,
      '--db',
      dbB,
      '--password-file',
      passwordFile,
      ...dbOptions(keyFile),
    ]).then((CliResult r) => r.code);

    expect(await importOnce(), ExitCodes.ok);

    final dumpPath = path('after-first.txt');
    expect(
      (await run(<String>['dump', dbB, '--out', dumpPath, ...dbOptions(keyFile)])).code,
      ExitCodes.ok,
    );
    final afterFirst = File(dumpPath).readAsBytesSync();

    final second = await run(<String>[
      '--json',
      'import',
      pfbPath,
      '--db',
      dbB,
      '--password-file',
      passwordFile,
      ...dbOptions(keyFile),
    ]);
    expect(second.code, ExitCodes.ok, reason: second.err.text);
    expect(second.result['status'], 'already-imported');
    expect(second.result['inserted'], 0);
    expect(second.result['previousJobId'], isNotNull);

    final dumpPath2 = path('after-second.txt');
    expect(
      (await run(<String>['dump', dbB, '--out', dumpPath2, ...dbOptions(keyFile)])).code,
      ExitCodes.ok,
    );
    expect(
      File(dumpPath2).readAsBytesSync(),
      afterFirst,
      reason: '第二次导入一条写语句都不该发 —— 幂等的判据是「库没有变化」',
    );
  });

  test('dump 的失败路径：密钥错 ⇒ 退出码 2，stdout 一个字节都没有', () async {
    final keyFile = writeKeyFile();
    expect(
      (await run(<String>['init', path('a.db'), '--seed', ...dbOptions(keyFile)])).code,
      ExitCodes.ok,
    );

    // 换一把密钥去开同一个库：SQLCipher 的表现是「文件不是一个数据库」。
    final wrongKeyFile = path('wrong.key');
    File(wrongKeyFile).writeAsStringSync('${List<String>.filled(64, 'ab').join()}\n');

    final r = await run(<String>[
      'dump',
      path('a.db'),
      '--database-key-file',
      wrongKeyFile,
      '--engine-lib',
      libraryPath,
    ]);
    expect(r.code, ExitCodes.toolError, reason: '业务结论是 1；而这里连引擎都用不了/库打不开属基础设施');
    expect(r.out.text, isEmpty, reason: 'dump 的 stdout 只能有规范文本');
    expect(r.err.text, isNotEmpty);
  });

  test('回归 ②：--plaintext-header-bytes 真的交到了命令手里（不是被当成 0 吃掉）', () async {
    // 曾经这一处只在 `init` 里解析：`dump` 写成 `headerBytes ?? 0`，
    // `seed` / `export` / `import` 根本没往后传 —— 于是「命令跑得起来」
    // 与「命令用的是你要的那个值」被混成了一件看起来正常的事。
    //
    // 判据落在 `init` 打出的 `{"type":"db",…,"plaintextHeaderBytes":N}` 那一行
    // （**不是** result 行 —— result 行没有这个字段，别去那里找；第一版就是这么写红的）。
    // 它记的是 `runInit` 真正交给 openEncrypted 的那个值，所以这条断言覆盖
    // 「命令行 → 报告」整段，而不是某个中间变量。
    //
    // ## 为什么不在这里断言「32 建的库打不开」
    //
    // 那是最直觉的写法，也是错的 —— 本定版引擎（SQLCipher 4.5.2 / SQLite 3.39.2）
    // 上 `PRAGMA cipher_plaintext_header_size = 32` 在 key 之前声明是**惰性的**
    // （实测见 `build/probe/plaintext_header_order.py`：pragma 被 rc=0 收下，
    // 生成的文件前 16 字节仍不是 SQLite 魔数，事后不带该选项照样打开，
    // 与不声明它**没有可区分的差别**）。
    // 也就是说在本机根本造不出「0 与 32 可观测地不同」的场景 ——
    // 谁要是在这里写那种断言，它测的是引擎的当前实现，不是我们的传递。
    // 剩下的那条缝由两处 `required` 兜住（见 open_db.dart 的注释）：
    // 编译器在每个开库调用点问一次，而不是让运行时默认成 0。
    final keyFile = writeKeyFile();

    final dflt = await run(<String>['--json', 'init', path('default.db'), ...dbOptions(keyFile)]);
    expect(dflt.code, ExitCodes.ok, reason: dflt.err.text);
    expect(dbLine(dflt)['plaintextHeaderBytes'], 0, reason: '不给就该是 0（Android/桌面）');

    final ios = await run(<String>[
      '--json',
      'init',
      path('ios.db'),
      '--plaintext-header-bytes',
      '32',
      ...dbOptions(keyFile),
    ]);
    expect(ios.code, ExitCodes.ok, reason: ios.err.text);
    expect(
      dbLine(ios)['plaintextHeaderBytes'],
      32,
      reason: '给了 32 就必须是 32；被当成 0 吃掉的后果是库在 iOS 上完全打不开',
    );

    // 另外几条命令同样接受这个选项（选项集共用，但取值点是各自的，见 runner.dart）。
    // 这里只断言「32 没被自己的校验挡下」—— 用的是上面那个**按 32 建的库**，
    // 所以即使将来引擎开始真的生效，结论也不变。
    for (final args in <List<String>>[
      <String>['dump', path('ios.db'), '--out', path('ios.dump.txt')],
      <String>['seed', path('ios.db')],
    ]) {
      final r = await run(<String>[
        ...args,
        '--plaintext-header-bytes',
        '32',
        ...dbOptions(keyFile),
      ]);
      expect(r.err.text, isNot(contains('只允许')), reason: '${args.first}：32 是合法值');
    }
  });
}

/// 取 NDJSON 里 `{"type":"db",…}` 那一行（`init` 用它报「这个库是怎么建的」）。
Map<String, Object?> dbLine(CliResult result) => result.jsonLines.firstWhere(
  (Map<String, Object?> line) => line['type'] == 'db',
  orElse: () => throw StateError('这次调用里没有 type=db 那一行：${result.out.text}'),
);

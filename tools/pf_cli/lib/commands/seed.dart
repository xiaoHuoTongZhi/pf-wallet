/// `pf seed <db>`：灌入一份**确定的**样本数据，供往返验收与人工点检使用。
///
/// ## 它为什么不是「测试夹具」
///
/// 夹具住在测试里，而这份数据要被**命令行本身**产生出来 ——
/// §4.5 的端到端验收（`init --seed → dump → export → 删库 → init → import
/// → dump → diff`）的前提是：导出那一端的数据来自一次真实的、走出了
/// 仓储层校验与触发器兜底的写入。用夹具直接塞 SQL 会绕开这些校验，
/// 于是「往返一致」证明的东西会少一大截 —— 它只证明了编解码自洽。
///
/// ## 为什么每条写入都走既有仓储，而不是一段 INSERT
///
/// 仓储层带着业务校验（账户类型与额度的一致性、分类的两级限制、
/// 交易对账户/分类的引用、转账必须有对方账户），而 DDL 另有一层
/// CHECK 与触发器。样本数据若绕过仓储直接写表，就会漏掉第一层 ——
/// 而往返验收要验的正是「一套完整实现产生的数据能不能被另一套读回」，
/// 从旁路插入的数据开始验，验的是一个不存在的场景。
///
/// ## 余额的权威来源
///
/// 仓储的写入会**增量**更新账户缓存余额，最后再跑一次
/// [BalanceRecalculator] 全量重算。为什么要多这一步：增量与全量是两条
/// 实现路径（`SqlTxnRepository._applyEffect` 与 `balance_recalc.dart`），
/// 而「Σ余额 == 期初 + Σ交易影响」这条式子的权威口径是**全量**那一条。
/// 让样本最后落在全量口径上，往返验收里的余额差异才有意义 ——
/// 否则一次导入的等价性会被两条增量路径的细微不同掩盖掉。
///
/// ## 幂等
///
/// 库里已有账本时**什么都不做**（返回 0，状态词 `sample-present`）。
/// 不做「补一条」也不做「覆盖」：重复灌样本会把同一笔消费记两次，
/// 而那是一个用户很难自己发现的数据错误。
///
/// ## 两个入口，一个实现
///
/// 样本既可以由 `pf seed <db>` 灌，也可以在 `pf init <db> --seed` 里
/// 与建库一次做完 —— 验收脚本走的是后者（见 docs/M1_RUNBOOK.md §4.2）。
/// 两条路共用 [applySeed]，且 `init --seed` 复用的是**同一个**已打开的库
/// （不再开第二次）：SQLite 的写锁在进程内是独占的，同进程里开两次
/// 会以 `database is locked` 的形式失败，而那个报错会把排查方向引向
/// 「并发写」，与真正的原因（重复打开）完全无关。
library;

import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';
import 'package:pf_io/pf_io.dart';

import '../exit_codes.dart';
import '../file_source.dart';
import '../open_db.dart';
import '../reporter.dart';
import '../status.dart';

/// 样本的时间基准（epoch 毫秒）。
///
/// 固定值而不是 `DateTime.now()`：`pf dump` 的输出要能被 diff，
/// 而任何一处读时钟都会让「同一份数据两次导出得到同一份文本」不成立。
/// 取这个具体时刻没有含义，它只是与 `export_payload` 向量同一量级的
/// 一个稳定值。
const int kSeedBaseMilliseconds = 1758000000000;

/// 样本账本的短码。
const String kSeedLedgerCode = 'MAIN01';

/// 一次样本注入的结果。
///
/// [inserted] 与 [counts] 是两件事：库是刚灌好的（`inserted=true`），
/// 还是本来就有一份样本（`inserted=false`，本次一条写语句都没发）——
/// 它们的退出码相同（0），但报告里必须分得清。这个区分是 `pf init --seed`
/// 与 `pf seed` 共用一个实现的前提：两个入口的处境不同（前者刚建完库，
/// 后者是对着既有库跑），而「这次到底动了没有」的答案必须一致。
final class SeedOutcome {
  const SeedOutcome({required this.counts, required this.inserted, required this.ledgerCount});

  /// 逐阶段条数（走导出侧同一个读取器，见 [applySeed]）。
  final Map<String, int> counts;

  /// 本次是否真的写入了样本。
  final bool inserted;

  /// 库里的账本数。
  final int ledgerCount;
}

/// 在**一个已打开、且 schema 已到位**的库上灌样本。
///
/// 抽出来给两个入口共用（`pf seed` 与 `pf init --seed`），理由不只是省几行：
/// 幂等判据（「有账本就不动」）如果各写一份，两个入口迟早会分叉 ——
/// 而分叉的表现是「`pf seed` 认为已经灌过、`pf init --seed` 认为没有」，
/// 于是同一条命令序列跑两次得到不同的库。
Future<SeedOutcome> applySeed(PfDb db) async {
  final existing = await SqlLedgerRepository(db).listAll();
  final int ledgerCount;
  final bool inserted;
  if (existing.isNotEmpty) {
    ledgerCount = existing.length;
    inserted = false;
  } else {
    await _insertSample(db);
    ledgerCount = 1;
    inserted = true;
  }

  // 报告里的条数走**导出侧同一个读取器**，而不是另写几条 COUNT：
  // 两条统计路径会给出两个可能不一致的数字，而这个报告的作用正是
  // 让人对「库里有什么」有一个可对照的答案。
  final stages = await PfPayloadExtractor.readStages(db);
  return SeedOutcome(
    counts: PfPayloadExtractor.countsOf(stages),
    inserted: inserted,
    ledgerCount: ledgerCount,
  );
}

/// 执行 `pf seed`。返回 [ExitCodes] 之一。
Future<int> runSeed({
  required String? databaseFile,
  required String? databaseKeyFile,
  required String? libraryPath,
  required int plaintextHeaderBytes,
  required CliReporter reporter,
  required StringSink err,
  required FileBytesReader readBytes,
  required Map<String, String> environment,
}) async {
  if (databaseFile == null) {
    err.writeln('用法错误：seed 需要一个数据库文件参数。');
    err.writeln('  pf seed <db> [--database-key-file <f>] [--engine-lib <so>]');
    reporter.result(
      exitCode: ExitCodes.toolError,
      status: 'usage-error',
      fields: const <String, Object?>{'command': 'seed'},
    );
    return ExitCodes.toolError;
  }

  final opened = await openLocalDatabase(
    command: 'seed',
    databaseFile: databaseFile,
    keyFile: databaseKeyFile,
    libraryPath: libraryPath,
    plaintextHeaderBytes: plaintextHeaderBytes,
    reporter: reporter,
    err: err,
    readBytes: readBytes,
    environment: environment,
  );
  if (!opened.isReady) {
    return opened.exitCode!;
  }
  final database = opened.database!;

  try {
    final db = database.db;
    final version = await database.schemaVersion();
    if (version < PfSchema.current) {
      err.writeln('库还没有初始化（schema v$version，期望 v${PfSchema.current}）：先跑 pf init。');
      reporter.result(
        exitCode: ExitCodes.toolError,
        status: 'schema-not-ready',
        fields: <String, Object?>{'command': 'seed', 'db': databaseFile, 'schemaVersion': version},
      );
      return ExitCodes.toolError;
    }

    final seeded = await applySeed(db);

    reporter.record('db', <String, Object?>{
      'path': databaseFile,
      'schemaVersion': version,
      'ledgerCount': seeded.ledgerCount,
      'counts': seeded.counts,
    });
    reporter.result(
      exitCode: ExitCodes.ok,
      status: seeded.inserted ? 'seeded' : 'sample-present',
      fields: <String, Object?>{
        'command': 'seed',
        'db': databaseFile,
        'counts': seeded.counts,
        'inserted': seeded.inserted,
      },
    );
    return ExitCodes.ok;
  } on PfError catch (error) {
    err.writeln('${error.code}：${error.message}');
    reporter.result(
      exitCode: exitCodeForPfError(error),
      status: statusOfCode(error.code),
      fields: <String, Object?>{
        'command': 'seed',
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

/// 灌入样本。全部写入在一个事务里：任何一条失败都不留下半个样本 ——
/// 半个样本比没有样本更坏，因为它会让「往返一致」的失败看起来像
/// 编解码问题，而真正的原因是数据本身不完整。
Future<void> _insertSample(PfDb db) async {
  final deviceId = await AppMetaStore.readOrCreateDeviceId(db);
  const base = kSeedBaseMilliseconds;

  await db.transaction<void>((tx) async {
    final ledgerRepo = SqlLedgerRepository(tx);
    final accountRepo = SqlAccountRepository(tx);
    final categoryRepo = SqlCategoryRepository(tx);
    final txnRepo = SqlTxnRepository(tx);

    final ledgerId = Ulid.next();
    await ledgerRepo.create(
      LedgerRecord(
        id: ledgerId,
        name: '日常记账',
        code: kSeedLedgerCode,
        currency: 'CNY',
        // 默认账本：`ux_ledger_default` 保证至多一个（本表为空时必然可用）。
        isDefault: true,
        createdAt: base,
        updatedAt: base,
        deviceId: deviceId,
      ),
    );

    final diningId = Ulid.next();
    final salaryId = Ulid.next();
    await categoryRepo.create(
      CategoryRecord(
        id: diningId,
        ledgerId: ledgerId,
        kind: CategoryKind.expense,
        name: '餐饮',
        icon: 'restaurant',
        color: '#F97316',
        sortOrder: 1,
        createdAt: base,
        updatedAt: base,
        deviceId: deviceId,
      ),
    );
    await categoryRepo.create(
      CategoryRecord(
        id: salaryId,
        ledgerId: ledgerId,
        kind: CategoryKind.income,
        name: '工资',
        icon: 'payments',
        color: '#22C55E',
        sortOrder: 2,
        createdAt: base,
        updatedAt: base,
        deviceId: deviceId,
      ),
    );

    final savingsId = Ulid.next();
    final creditCardId = Ulid.next();
    await accountRepo.create(
      AccountRecord(
        id: savingsId,
        ledgerId: ledgerId,
        name: '招商银行储蓄卡',
        type: AccountType.savingsCard,
        currency: 'CNY',
        openingBalanceMinor: 100000,
        cachedBalanceMinor: 100000,
        balanceAsOf: 0,
        icon: 'card',
        color: '#3B82F6',
        sortOrder: 1,
        createdAt: base,
        updatedAt: base,
        deviceId: deviceId,
      ),
    );
    await accountRepo.create(
      AccountRecord(
        id: creditCardId,
        ledgerId: ledgerId,
        name: '招商银行信用卡',
        type: AccountType.creditCard,
        currency: 'CNY',
        openingBalanceMinor: 0,
        cachedBalanceMinor: 0,
        balanceAsOf: 0,
        // 信用卡必须有额度（DDL 的 CHECK 与仓储的前置校验都要求）。
        creditLimitMinor: 500000,
        statementDay: 5,
        dueDay: 25,
        icon: 'credit_card',
        color: '#A855F7',
        sortOrder: 2,
        createdAt: base,
        updatedAt: base,
        deviceId: deviceId,
      ),
    );

    // 三种交易类型各一笔：支出（有分类）、收入（有分类）、转账（有对方账户、
    // 无分类 —— DDL 的 `CHECK (type = 3 OR category_id IS NOT NULL)` 与
    // 仓储的转账语义都要求这样）。
    await txnRepo.create(
      TxnRecord(
        id: Ulid.next(),
        ledgerId: ledgerId,
        type: TxnType.expense,
        amountMinor: 12850,
        currency: 'CNY',
        occurredAt: base - 2 * 24 * 3600 * 1000,
        tzOffsetMin: 480,
        accountId: savingsId,
        categoryId: diningId,
        merchant: '楼下咖啡',
        createdAt: base,
        updatedAt: base,
        deviceId: deviceId,
        originDeviceId: deviceId,
      ),
    );
    await txnRepo.create(
      TxnRecord(
        id: Ulid.next(),
        ledgerId: ledgerId,
        type: TxnType.income,
        amountMinor: 300000,
        currency: 'CNY',
        occurredAt: base - 24 * 3600 * 1000,
        tzOffsetMin: 480,
        accountId: savingsId,
        categoryId: salaryId,
        note: '九月工资',
        createdAt: base,
        updatedAt: base,
        deviceId: deviceId,
        originDeviceId: deviceId,
      ),
    );
    await txnRepo.create(
      TxnRecord(
        id: Ulid.next(),
        ledgerId: ledgerId,
        type: TxnType.transfer,
        amountMinor: 50000,
        currency: 'CNY',
        occurredAt: base - 3600 * 1000,
        tzOffsetMin: 480,
        accountId: savingsId,
        toAccountId: creditCardId,
        createdAt: base,
        updatedAt: base,
        deviceId: deviceId,
        originDeviceId: deviceId,
      ),
    );
  });

  // 全量重算，把余额钉在权威口径上（见文件头）。
  await BalanceRecalculator.run(db);
}

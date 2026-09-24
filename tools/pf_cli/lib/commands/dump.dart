/// `pf dump <db> [--out <f>]`：把一个**本地库**的载荷视图打成规范文本，供 diff。
///
/// ## 它在往返验收里扮演什么角色
///
/// §4.5 的端到端验收是：
///
/// ```
/// init --seed → dump before → export → verify → 删库 → init → import
///   → dump after → diff before after   （必须为空）
/// ```
///
/// 其中 `export` / `import` 回答的是「**文件**这一路对不对」，而两次 `dump`
/// 回答的是「**库**这一路对不对」：`dump before` 读的是原始库，
/// `dump after` 读的是「重建之后、只有导入写过」的库。两者逐字节相同，
/// 才说明这条链上没有哪一段在悄悄改写数据。
///
/// 它刻意**不复用 `.pfb` 文件本身**来对照：拿两份导出文件互比，
/// 只能证明「同一段编码器代码对同一份输入给出同一份输出」，
/// 而中间那次删库 + 重建 + 导入整段没有参与比较。
///
/// ## 它读的是哪一层：**载荷视图**，不是表的全部列
///
/// 读库走 [PfPayloadExtractor.readStages] —— 与 `pf export` **同一个**读取器，
/// 也就是同一张字段表（[kPayloadRecordSpecs]）。于是 dump 的每一行
/// 都恰好是「这份库里、会被装进导出文件的那部分」。
///
/// 三条边界因此是**定义**，不是省略：
///
///   1. **只在字段表里的列**。表里还有若干列（`txn.source_import_job`、
///      `account.cached_balance_minor` ……）不在载荷里，它们不参与往返契约 ——
///      `cached_balance_minor` 这类派生态由全量重算（[BalanceRecalculator]）
///      在导入之后重新算出，本来就**不承诺**与导出时逐字节相同。
///   2. **不读 `app_meta`**。设备标识是每台安装各自的（`pf init` 生成一次），
///      重建之后的库里必然是一个**新的** deviceId —— 把它放进 dump，
///      一次正确的往返会表现为 diff 不为空，而那是最难查的一类假失败。
///      同理不含库路径、不含时间戳、不含导出文件名。
///   3. **不含本地台账**（`import_job` / `imported_file` / `conflict` /
///      `change_log`）。它们记的是「本机做过什么」，不是「用户有哪些账」，
///      两边必然不同。
///
/// ## 为什么与 `pf export` 共用读取器，而不是自己拼 SQL
///
/// 共用的理由与「导入侧改走 `payloadTableOf`」是同一条：**表→阶段的映射
/// 只能有一张**。若 dump 自己写一份「ledger 表读 ledger 表」，
/// 某天 v2 新增一列时，导出会带上、dump 看不到，于是「dump 一致」
/// 就不再意味着「导出也一致」—— 而 dump 在验收里的全部价值，
/// 恰恰是它代表导出那一侧。
///
/// ## 为什么输出与 `--json` 互斥
///
/// 与 `pf info --records` 同一条理由：这份文本要拿去与另一份**逐字节** diff，
/// 而 NDJSON 的契约是「末行固定为结果行」—— 多一行结果行，diff 就一定不为空，
/// 且那个失败看起来像「数据不一致」。诊断（读了哪个库、失败原因）一律走 stderr。
///
/// ## `--out` 是推荐用法，Windows 上几乎是必需的
///
/// 样本里有中文（账本名「日常记账」、分类名「餐饮」）。Windows 控制台的
/// 默认编码不是 UTF-8，从 stdout 重定向取字节会得到随机器而变的文本 ——
/// 而 `--out` 走 [FileTextWriter]，编码写死 UTF-8、无 BOM。
library;

import 'dart:convert';

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';
import 'package:pf_io/pf_io.dart';

import '../exit_codes.dart';
import '../file_source.dart';
import '../open_db.dart';
import '../records.dart';
import '../reporter.dart';

/// 规范文本的首行，同时是**报告格式版本**（与 `pfb-cross-check` 同一手法）。
///
/// 将来若改变某一层的写法（例如给阶段加一段摘要），必须在这里 +1：
/// 于是「格式变了」表现为 diff 的第一行就不同，而不是某一行对不上、
/// 却看不出到底是格式变了还是数据错了。
const String kDatabaseDumpHeader = 'pf-dump format=1';

/// 执行 `pf dump`。返回 [ExitCodes] 之一。
///
/// 与 `info --records` 一样**不接 CliReporter**（理由见文件头末段）。
Future<int> runDump({
  required String? databaseFile,
  required String? outPath,
  required String? databaseKeyFile,
  required String? libraryPath,
  required int plaintextHeaderBytes,
  required bool json,
  required StringSink out,
  required StringSink err,
  required FileBytesReader readBytes,
  required FileTextWriter writeText,
  required Map<String, String> environment,
}) async {
  if (databaseFile == null) {
    err.writeln('用法错误：dump 需要一个数据库文件参数。');
    err.writeln('  pf dump <db> [--out <f>] [--database-key-file <f>]');
    return ExitCodes.toolError;
  }
  if (json) {
    err.writeln('用法错误：dump 与 --json 互斥。');
    err.writeln('  这份文本要拿去与另一份逐字节 diff，而 NDJSON 的末行是结果行；');
    err.writeln('  多出那一行会让「数据不一致」和「命令没跑起来」混成同一处失败。');
    return ExitCodes.toolError;
  }

  final opened = await openLocalDatabase(
    command: 'dump',
    databaseFile: databaseFile,
    keyFile: databaseKeyFile,
    libraryPath: libraryPath,
    reporter: _silentReporter(err),
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
    final version = await database.schemaVersion();
    final stages = await PfPayloadExtractor.readStages(db);
    final report = buildDatabaseDump(schemaVersion: version, stages: stages);

    if (outPath == null) {
      out.write(report);
    } else {
      writeText(outPath, report);
      err.writeln('✓ 库快照已写入 $outPath（${report.length} 字符，UTF-8 无 BOM）');
    }
    return ExitCodes.ok;
  } on PfError catch (error) {
    err.writeln('${error.code}：${error.message}');
    return exitCodeForPfError(error);
  } finally {
    await closeQuietly(database, err);
  }
}

/// 把一次读库的结果渲染成规范文本。**纯函数**：不进不信 IO、不读时钟、
/// 不看环境变量 —— 同样的库内容永远产出同样的字符串。这是两次 dump
/// 可以被 diff 的前提（也是「重建库之后 deviceId 变了但文本不变」的原因）。
///
/// 结构：
///
/// ```
/// pf-dump format=1
/// schema.version=1
/// stage.<阶段>.count=<n>           ← 逐表条数
/// stage.<阶段>.sha256=<hex>        ← 逐表内容摘要
/// row.<阶段>.<四位行号>=<规范 JSON>  ← 逐条明细（摘要对不上时用来定位）
/// ```
///
/// 先出「条数 + 摘要」，再出明细：条数/摘要这一段是**判定用**的，
/// 人一眼就能看出是哪张表不对；明细是**排查用**的，只在需要时往下翻。
///
/// 摘要与条数之所以两个都给：条数相同而内容不同（改了金额、换了分类）
/// 是往返里最常见的失败，只给条数会漏掉它；只给摘要则「多了三条」这件事
/// 要从一堆十六进制里反推。
String buildDatabaseDump({
  required int schemaVersion,
  required Map<String, List<Map<String, Object?>>> stages,
}) {
  final buffer = StringBuffer();
  buffer.writeln(kDatabaseDumpHeader);
  buffer.writeln('schema.version=$schemaVersion');

  for (final stage in kPayloadStageOrder) {
    final rows = stages[stage] ?? const <Map<String, Object?>>[];
    buffer.writeln('stage.$stage.count=${rows.length}');
    buffer.writeln('stage.$stage.sha256=${stageDigest(rows)}');
  }

  for (final stage in kPayloadStageOrder) {
    final rows = stages[stage] ?? const <Map<String, Object?>>[];
    for (var index = 0; index < rows.length; index++) {
      buffer.writeln('row.$stage.${formatLayerIndex(index)}=${canonicalRowJson(rows[index])}');
    }
  }

  return buffer.toString();
}

/// 一个阶段的内容摘要：对**逐条规范 JSON + 换行**的拼接求 SHA-256。
///
/// 三个细节都是刻意的：
///
///   * 每条之后补 `\n` —— 否则 `["ab","c"]` 与 `["a","bc"]` 会拼成同一串字节，
///     「一条记录被拆成两条」这种失败会从摘要里逃掉；
///   * 逐条**规范** JSON（键排序）—— 行内键序是实现产物，不归一会让
///     「改了字段表的书写顺序」变成一次假的 diff（见 [canonicalRowJson]）；
///   * 零行 ⇒ `sha256('')`（e3b0c442…）。空表也走同一个公式，不做特例：
///     特例（比如打 `-`）会让「空」与「漏了这一层」在文本上长得一样。
String stageDigest(List<Map<String, Object?>> rows) {
  final buffer = StringBuffer();
  for (final row in rows) {
    buffer.write(canonicalRowJson(row));
    buffer.write('\n');
  }
  return Sha256.instance.hashHex(utf8.encode(buffer.toString()));
}

/// 一条记录的规范 JSON：键递归排序、紧凑分隔符、不转义非 ASCII。
///
/// 与 `pfb-cross-check` 的报告（`records.dart` 的 [canonicalJsonBytes]）
/// **同一口径、同一份实现**（[canonicalizeJson]）：两份规范文本将来若要
/// 交叉比对，口径不同会让每个对象都比出一处差异。
String canonicalRowJson(Map<String, Object?> row) => jsonEncode(canonicalizeJson(row));

/// 给「打开库」这一步用的空 reporter。
///
/// `openLocalDatabase` 失败时会把结果行写进 reporter —— 但 dump 模式的
/// stdout 就是规范文本本身，写一行结果行进去会让 diff 必然非空。
/// 于是这里把它接到 **stderr**：诊断信息一个字都不丢，
/// 而 stdout 上永远只有规范文本（或什么都没有）。
CliReporter _silentReporter(StringSink err) => CliReporter(out: err, json: false);

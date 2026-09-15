/// 向量「锻造」工具：用**当前实现**跑一遍全部向量，把实际输出落盘，
/// 并与签入的期望值做差异对照。
///
/// ## 它为什么不能写回 test_vectors/
///
/// 这是本工具最重要的设计约束。把实现的实际输出直接写回黄金向量，
/// 等于让实现自己给自己出考卷：某个改动把 SHA-256 换成 MD5，
/// 跑一次 forge 之后所有向量都会「通过」—— 而它们本来唯一的职责就是
/// 阻止这件事发生。
///
/// 因此本工具**只写 build/vectors/forged/**，并且显式拒绝 `--out` 指向
/// `test_vectors/`。它产出的东西是给人看的对照表，不是可以被消费的期望值。
///
/// 典型用法：
///   dart run packages/pf_testkit/bin/vector_forge.dart
///   # 然后人工看 build/vectors/forged/*.forged.json，
///   # 逐个判断「这个差异是我想要的，还是我改坏了」，再**手写**改向量文件。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:pf_core/pf_core.dart';
import 'package:pf_testkit/pf_testkit.dart';

Future<void> main(List<String> argv) async {
  exitCode = await _run(argv);
}

Future<int> _run(List<String> argv) async {
  final parser =
      ArgParser()
        ..addOption('vectors', abbr: 'v', help: '向量目录（缺省 test_vectors/v1）')
        ..addOption('out', abbr: 'o', help: '输出目录（缺省 build/vectors/forged）')
        ..addFlag('quiet', abbr: 'q', negatable: false, help: '只输出差异汇总')
        ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助');

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (error) {
    stderr.writeln('参数错误：${error.message}');
    return 2;
  }
  if (args.flag('help')) {
    stdout.writeln(parser.usage);
    return 0;
  }

  final Directory repoRoot;
  final List<PfVectorSuite> suites;
  final Directory outDir;
  try {
    repoRoot = findRepoRoot();
    suites = loadVectorSuites(
      Directory(p.join(repoRoot.path, args.option('vectors') ?? VectorSchema.vectorsDirectory)),
    );
    outDir = _resolveOutDir(repoRoot, args);
  } on VectorFormatException catch (error) {
    stderr.writeln('✗ $error');
    return 2;
  }

  outDir.createSync(recursive: true);
  final registry = buildDefaultRegistry();

  var driftCount = 0;
  var pendingCount = 0;
  var checkedCount = 0;

  for (final suite
      in suites..sort((PfVectorSuite a, PfVectorSuite b) => a.suite.compareTo(b.suite))) {
    final forged = <Map<String, Object?>>[];

    for (final c in suite.cases) {
      final driver = registry.lookup(c.kind);
      if (driver == null || !driver.isImplemented) {
        pendingCount += 1;
        forged.add(<String, Object?>{
          'id': c.id,
          'kind': c.kind,
          'status': 'pending',
          'reason': driver == null ? 'kind 未注册' : '实现未就绪（${driver.plannedMilestone}）',
        });
        continue;
      }

      checkedCount += 1;
      Map<String, Object?>? actual;
      String? errorCode;
      try {
        final outcome = await driver.run(c.input);
        if (outcome.isError) {
          errorCode = outcome.errorCode;
        } else {
          actual = outcome.actual;
        }
      } on PfError catch (error) {
        errorCode = error.code;
      }

      final drifted = _hasDrift(c, actual, errorCode);
      if (drifted) driftCount += 1;

      forged.add(<String, Object?>{
        'id': c.id,
        'kind': c.kind,
        'status': drifted ? 'drift' : 'match',
        if (actual != null) 'actual': actual,
        if (errorCode != null) 'actualErrorCode': errorCode,
        if (drifted) 'checkedInExpect': c.expect.toJson(),
      });
    }

    final target = File(p.join(outDir.path, '${suite.suite}.forged.json'));
    target.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{'suite': suite.suite, 'title': suite.title, 'note': '本文件是当前实现的实际输出快照，用于人工对照；'
      '它不是黄金向量，也不得被直接回写进 test_vectors/。', 'cases': forged})}\n',
      encoding: utf8,
    );
    if (!args.flag('quiet')) {
      stdout.writeln(
        '  写入 ${p.relative(target.path, from: repoRoot.path)} '
        '（${forged.length} 条）',
      );
    }
  }

  stdout
    ..writeln()
    ..writeln('已核对 $checkedCount 条，pending $pendingCount 条。');
  if (driftCount == 0) {
    stdout.writeln('✓ 当前实现与签入向量完全一致，无需人工介入。');
    return 0;
  }
  stdout
    ..writeln('! 有 $driftCount 条与签入向量不一致。')
    ..writeln('逐个判断后再**手工**修改 test_vectors/v1/*.json：')
    ..writeln('  - 若差异是刻意的格式/算法变更 → 改向量，并在 notes 里写清原因')
    ..writeln('  - 若差异不是你要的 → 改实现')
    ..writeln('本工具不会替你改，也不应该改。');
  return 0;
}

Directory _resolveOutDir(Directory repoRoot, ArgResults args) {
  final raw = args.option('out');
  final Directory dir;
  if (raw == null) {
    dir = Directory(p.join(repoRoot.path, VectorSchema.forgedDirectory));
  } else {
    dir = Directory(p.isAbsolute(raw) ? raw : p.join(repoRoot.path, raw));
  }

  final normalized = p.normalize(dir.absolute.path).replaceAll('\\', '/');
  final protected = p.normalize(p.join(repoRoot.path, 'test_vectors')).replaceAll('\\', '/');
  if (normalized == protected || normalized.startsWith('$protected/')) {
    throw VectorFormatException(
      '拒绝对 $protected 写入：'
      '用实现的实际输出覆盖黄金向量，等于让实现自己给自己出考卷。'
      '请改用默认的 build/vectors/forged/，然后手工修改向量文件。',
    );
  }
  return dir;
}

/// 判定当前输出与签入期望是否不一致。
bool _hasDrift(PfVectorCase c, Map<String, Object?>? actual, String? errorCode) {
  final expect = c.expect;
  if (expect.expectsError) {
    if (errorCode == null) return true;
    if (expect.acceptsAnyError) return false;
    return errorCode != expect.errorCode;
  }
  if (errorCode != null) return true;
  final got = actual ?? const <String, Object?>{};
  for (final key in (expect.value ?? const <String, Object?>{}).keys) {
    if (!got.containsKey(key)) return true;
    if (!jsonEquals(expect.value![key], got[key])) return true;
  }
  return false;
}

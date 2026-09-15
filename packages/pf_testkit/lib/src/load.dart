/// 向量文件的定位与加载。
///
/// ## 为什么在代码里向上找仓库根，而不是依赖当前工作目录
///
/// `dart run packages/pf_testkit/bin/vector_report.dart` 会以仓库根为
/// 工作目录运行；但同一份代码在单测里、在 IDE 里、在 `melos exec` 里
/// 运行时的当前目录各不相同。依赖 CWD 会让「本地跑得通、CI 跑不通」
/// 变成常态，而且报错信息是「目录不存在」这种毫无指向性的废话。
///
/// 因此统一用「向上找 melos.yaml」定位仓库根，找不到就明确报错。
library;

import 'dart:convert';
import 'dart:io';

import 'baseline.dart';
import 'json_util.dart';
import 'schema.dart';
import 'vector.dart';

/// 仓库根标记文件。
const List<String> repoRootMarkers = <String>['melos.yaml', 'pubspec.yaml'];

/// 从 [start] 向上查找仓库根。
Directory findRepoRoot([Directory? start]) {
  var current = (start ?? Directory.current).absolute;
  while (true) {
    final hasAll = repoRootMarkers.every(
      (String name) => File('${current.path}${Platform.pathSeparator}$name').existsSync(),
    );
    if (hasAll) return current;

    final parent = current.parent;
    if (parent.path == current.path) {
      throw VectorFormatException(
        '从 ${(start ?? Directory.current).absolute.path} 向上未找到含 '
        '${repoRootMarkers.join(" + ")} 的仓库根',
      );
    }
    current = parent;
  }
}

/// 加载目录下全部向量文件（按文件名排序，保证报告确定性）。
List<PfVectorSuite> loadVectorSuites(Directory directory) {
  if (!directory.existsSync()) {
    throw VectorFormatException('向量目录不存在：${directory.path}');
  }

  final files =
      directory
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith(VectorSchema.fileSuffix))
          // JSON Schema 本体也放在 test_vectors 下，但不在 v1/ 里；
          // 这里再兜一层，避免将来有人把 schema 挪进 v1/。
          .where((File f) => !f.path.contains('schema'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));

  if (files.isEmpty) {
    throw VectorFormatException('向量目录 ${directory.path} 下没有任何 .json 文件');
  }

  final suites = <PfVectorSuite>[];
  final seenCaseIds = <String, String>{};

  for (final file in files) {
    final name = file.uri.pathSegments.last;
    final Map<String, Object?> json;
    try {
      json = decodeJsonObject(file.readAsStringSync(encoding: utf8), name);
    } on FormatException catch (error) {
      throw VectorFormatException('JSON 解析失败：${error.message}', path: name);
    }

    final suite = PfVectorSuite.fromJson(json, name);
    for (final c in suite.cases) {
      final previous = seenCaseIds[c.id];
      if (previous != null) {
        throw VectorFormatException(
          '用例 ID "${c.id}" 在 $previous 与 $name 中重复。'
          'ID 是失败报告与基线文件的唯一索引，必须全局唯一',
          path: name,
        );
      }
      seenCaseIds[c.id] = name;
    }
    suites.add(suite);
  }

  return suites;
}

/// 加载 pending 基线。文件不存在时返回空基线（首次引入该机制时的行为）。
PendingBaselineLoad loadPendingBaseline(Directory repoRoot) {
  final file = File(
    '${repoRoot.path}${Platform.pathSeparator}'
    '${VectorSchema.pendingBaselineFile.replaceAll("/", Platform.pathSeparator)}',
  );
  if (!file.existsSync()) {
    return const PendingBaselineLoad(PendingBaseline.empty, existed: false);
  }
  final json = decodeJsonObject(
    file.readAsStringSync(encoding: utf8),
    VectorSchema.pendingBaselineFile,
  );
  return PendingBaselineLoad(
    PendingBaseline.fromJson(json, VectorSchema.pendingBaselineFile),
    existed: true,
  );
}

/// 基线及其是否存在。
final class PendingBaselineLoad {
  const PendingBaselineLoad(this.baseline, {required this.existed});

  final PendingBaseline baseline;
  final bool existed;
}

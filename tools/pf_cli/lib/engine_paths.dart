/// 定版原生库的**落盘清单**：写它的与读它的都在这里。
///
/// ## 为什么需要这份清单
///
/// 「本机/CI 该用哪个库」这件事依赖两层映射：
///   1. `Platform.operatingSystem` + `Abi.current()` → 清单条目名（`win-x64` / `osx-arm64` …）；
///   2. 条目名 → 上游包里的成员路径 + 期望 sha256 → 落盘后的绝对路径。
///
/// 这两层如果让每个消费方（测试、探针、CI 脚本）各实现一遍，就会有第二份真相，
/// 而它暴露的时机恰好是最难查的那种：**CI 绿、本机红**。
/// 因此取用脚本把结果写成一个文件，消费方只读不算。
///
/// 文件落在 `<仓库根>/build/native/engine/engine_paths.json`（`build/` 不入库）。
library;

import 'dart:convert';
import 'dart:io';

/// 清单文件名。
const String kEnginePathsFileName = 'engine_paths.json';

/// 产物目录（相对仓库根）。
const String kEngineOutputRoot = 'build/native/engine';

/// 一条已落盘的产物。
final class EnginePathEntry {
  const EnginePathEntry({
    required this.kind,
    required this.path,
    required this.bytes,
    required this.sha256,
  });

  /// `sqlcipher` 或 `plain-sqlite`（来自定版清单的 `kind`）。
  final String kind;

  /// 绝对路径。
  final String path;

  final int bytes;
  final String sha256;

  /// 是 `tools/ci/native/engine_vendor.json` 里的 `artifact` 名（如 `sqlcipher`）。
  File get file => File(path);
}

/// 一份落盘清单。
final class EnginePaths {
  const EnginePaths({
    required this.runtime,
    required this.repoRoot,
    required this.artifacts,
    required this.source,
  });

  final String runtime;
  final String repoRoot;
  final Map<String, EnginePathEntry> artifacts;

  /// 写下它的那个文件路径（报错时要说清"这份清单是谁写的"）。
  final String source;

  /// 取一条产物。**找不到就抛** —— 不存在"缺了就当没有"这条路。
  EnginePathEntry require(String artifact) {
    final entry = artifacts[artifact];
    if (entry == null) {
      throw FormatException('落盘清单 $source 里没有产物 "$artifact"（有的是 ${artifacts.keys.join(', ')}）');
    }
    return entry;
  }

  String encode() =>
      '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'runtime': runtime,
        'repoRoot': repoRoot,
        'artifacts': <String, Object?>{
          for (final entry in artifacts.entries) entry.key: <String, Object?>{'kind': entry.value.kind, 'path': entry.value.path, 'bytes': entry.value.bytes, 'sha256': entry.value.sha256},
        },
      })}\n';

  static EnginePaths decode(String text, {required String source}) {
    final root = jsonDecode(text);
    if (root is! Map<String, Object?>) {
      throw FormatException('$source 的根必须是一个 JSON 对象');
    }
    final rawArtifacts = root['artifacts'];
    if (rawArtifacts is! Map<String, Object?>) {
      throw FormatException('$source 缺少 artifacts');
    }
    final artifacts = <String, EnginePathEntry>{};
    rawArtifacts.forEach((name, value) {
      if (value is! Map<String, Object?>) {
        throw FormatException('$source 的产物 "$name" 不是一个对象');
      }
      final bytes = value['bytes'];
      if (bytes is! int) {
        throw FormatException('$source 的产物 "$name" 缺少整数 bytes');
      }
      artifacts[name] = EnginePathEntry(
        kind: '${value['kind']}',
        path: '${value['path']}',
        bytes: bytes,
        sha256: '${value['sha256']}',
      );
    });
    return EnginePaths(
      runtime: '${root['runtime']}',
      repoRoot: '${root['repoRoot']}',
      artifacts: artifacts,
      source: source,
    );
  }
}

/// 从 [start] 向上找仓库根（同时含 `melos.yaml` 与 `pubspec.yaml` 的那一层）。
///
/// 用"特征文件"而不是"往上数几层"：测试可能从包目录跑（`melos exec`），
/// 也可能从仓库根跑（手敲命令），数层数在两种情形下答案不同。
String? findRepoRoot({Directory? start}) {
  var dir = start ?? Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/melos.yaml').existsSync() &&
        File('${dir.path}/pubspec.yaml').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
  return null;
}

/// 读落盘的引擎清单。缺失或损坏都抛 [StateError]，并给出补救命令。
///
/// 这里**刻意不返回 null 让调用方"跳过"**：缺引擎就意味着"用真实数据库的
/// 那些用例一条都没跑"，而那种状态的报告是全绿的 —— 与"全部通过"看起来一模一样。
StateError missingEnginePathsError(String? repoRoot) => StateError(
  '找不到已落盘的定版原生库清单。\n'
  '  期望位置：${repoRoot ?? '<仓库根>'}/$kEngineOutputRoot/$kEnginePathsFileName\n'
  '  补救命令（在仓库根执行）：dart run tools/pf_cli/bin/fetch_engine.dart\n'
  '不自动跳过是刻意的：静默跳过会让"引擎相关用例一条都没跑"呈现为全绿。',
);

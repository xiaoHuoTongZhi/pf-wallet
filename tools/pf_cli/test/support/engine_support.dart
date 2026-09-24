/// 引擎用例的公共夹具：定位**定版原生库**的落盘清单。
///
/// 「哪个库在哪个路径」这件事只有一份真相 —— `fetch_engine.dart` 写下的
/// `build/native/engine/engine_paths.json`。测试只读它，不自己按平台拼路径
/// （拼出来的那份会在「CI 绿、本机红」时暴露，而那是最难查的一类）。
///
/// 清单不在时**抛**（[missingEnginePathsError] 里带着补救命令），不跳过：
/// 「一条都没跑」与「全部通过」在报告里长得一模一样。
library;

import 'dart:io';

import 'package:pf_cli/engine_paths.dart';

/// 读定版原生库的落盘清单。
EnginePaths loadVendoredEnginePaths() {
  final root = findRepoRoot();
  if (root == null) {
    throw StateError(
      '找不到仓库根（向上找不到同时含 melos.yaml 与 pubspec.yaml 的目录）。\n'
      '  当前目录：${Directory.current.path}',
    );
  }
  final file = File('$root/$kEngineOutputRoot/$kEnginePathsFileName');
  if (!file.existsSync()) {
    throw missingEnginePathsError(root);
  }
  return EnginePaths.decode(file.readAsStringSync(), source: file.path);
}

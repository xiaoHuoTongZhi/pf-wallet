/// 仓库定位与文件遍历。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'model.dart';
import 'yaml_util.dart';

/// 仓库根定位与文件枚举。
final class Repo {
  Repo(this.root);

  /// 仓库根绝对路径（无尾部分隔符）。
  final String root;

  /// 遍历时永远跳过的目录名。
  ///
  /// 注意 `build` 在列表里：本工具自己的产物写在 `build/guards/`，
  /// 如果不跳过，第二次运行就会去扫描上一次的报告文件。
  static const Set<String> skippedDirectories = <String>{
    '.dart_tool',
    '.git',
    '.idea',
    '.plugin_symlinks',
    '.symlinks',
    '.vscode',
    'DerivedData',
    'Pods',
    'build',
    'ephemeral',
    'node_modules',
    'obj',
  };

  /// 从 [from]（默认当前目录）向上查找含 `melos.yaml` 的目录。
  static Repo locate({String? from}) {
    var current = p.normalize(p.absolute(from ?? Directory.current.path));
    while (true) {
      if (File(p.join(current, 'melos.yaml')).existsSync() &&
          File(p.join(current, 'pubspec.yaml')).existsSync()) {
        return Repo(current);
      }
      final parent = p.dirname(current);
      if (parent == current) {
        throw GuardException(
          '未找到仓库根：从 $from 向上未发现同时包含 melos.yaml 与 pubspec.yaml 的目录',
          hint: '请用 --repo <path> 显式指定仓库根',
        );
      }
      current = parent;
    }
  }

  /// 相对 POSIX 路径 → 绝对路径。
  ///
  /// 用 `joinAll` 而不是 `join` + 展开：Dart 的 `...` 只在集合字面量里有效，
  /// 参数列表里写展开是语法错误（而且很容易在 review 时被看漏）。
  String absolute(String relativePosix) => p.joinAll(<String>[root, ...relativePosix.split('/')]);

  /// 绝对路径 → 相对 POSIX 路径。
  String toRelative(String absolutePath) =>
      p.relative(absolutePath, from: root).replaceAll(r'\', '/');

  /// 枚举仓库内所有文件，返回相对 POSIX 路径（已排序，保证输出可 diff）。
  List<String> walkAllFiles() {
    final results = <String>[];
    final dir = Directory(root);
    if (!dir.existsSync()) {
      throw GuardException('仓库根不存在: $root');
    }
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = toRelative(entity.path);
      if (_isInSkippedDirectory(relative)) continue;
      results.add(relative);
    }
    results.sort();
    return results;
  }

  bool _isInSkippedDirectory(String relativePosix) {
    final segments = relativePosix.split('/');
    // 最后一段是文件名，不参与判断
    for (var i = 0; i < segments.length - 1; i++) {
      if (skippedDirectories.contains(segments[i])) return true;
    }
    return false;
  }

  /// 枚举 git 索引中的全部路径（等价于 `git ls-files --cached`）。
  ///
  /// 返回相对仓库根的 POSIX 路径（已排序、已去重）。
  ///
  /// 两个参数都不是随手加的：
  ///   · `-z` 让 git 用 NUL 分隔输出，**同时关闭 `core.quotepath` 的路径转义**。
  ///     不加它，含中文或空格的文件名会被输出成 `"\350\257\264..."` 这种转义序列，
  ///     规则里的 glob 一条都匹配不上 —— 而那会表现成「检查通过」。
  ///   · `--cached` 明确读索引（而不是工作区）。这就是本方法的语义：
  ///     「哪些路径将被提交」，而不是「磁盘上有什么文件」。
  ///
  /// 任何失败都抛 [GuardException]（退出码 2）：读不到索引是基础设施故障，
  /// 不能与「代码有问题」（退出码 1）混为一谈。
  List<String> trackedFiles() {
    final ProcessResult result;
    try {
      result = Process.runSync(
        'git',
        <String>['-C', root, 'ls-files', '--cached', '-z'],
        stdoutEncoding: const Utf8Codec(allowMalformed: true),
        stderrEncoding: const Utf8Codec(allowMalformed: true),
      );
    } on ProcessException {
      throw GuardException(
        '无法执行 git —— 它不在 PATH 中，或本机没有安装。',
        hint:
            '本检查读的是 git 索引，没有 git 就无法判定。'
            '若这是在一个没有 .git 的源码快照里运行，请跳过本项（CI 必须保留它）。',
      );
    }

    if (result.exitCode != 0) {
      final message = result.stderr.toString().trim();
      throw GuardException(
        'git ls-files 失败（退出码 ${result.exitCode}）：$message',
        hint:
            message.contains('dubious ownership')
                ? 'git 认为仓库属主与当前用户不一致（常见于挂载盘 / 容器）。'
                    '按提示执行 `git config --global --add safe.directory $root` 后重试。'
                : '若提示不是 git 仓库，说明 $root 下没有 .git —— 本检查无法在该环境完成判定。',
      );
    }

    final raw = result.stdout.toString();
    final paths = raw
      .split('\u0000')
      .map((entry) => entry.trim())
      .where((entry) => entry.isNotEmpty)
      .map((entry) => entry.replaceAll(r'\', '/'))
      .toList(growable: false)..sort();

    return List<String>.unmodifiable(paths);
  }

  /// 读取文件（UTF-8），不存在时抛 [GuardException]。
  String readFile(String relativePosix) {
    final file = File(absolute(relativePosix));
    if (!file.existsSync()) {
      throw GuardException('文件不存在: $relativePosix');
    }
    return file.readAsStringSync();
  }

  /// 读取文件（UTF-8），不存在时返回 null。
  String? tryReadFile(String relativePosix) {
    final file = File(absolute(relativePosix));
    if (!file.existsSync()) return null;
    return file.readAsStringSync();
  }

  /// 写出文件，自动创建父目录。
  void writeFile(String relativePosix, String content) {
    final file = File(absolute(relativePosix));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  /// 加载 YAML 文件为 Map；解析失败或根不是 Map 时抛 [GuardException]。
  Map<String, Object?> loadYamlMap(String relativePosix) {
    final raw = readFile(relativePosix);
    return parseYamlMap(raw, sourceName: relativePosix);
  }

  @override
  String toString() => 'Repo($root)';
}

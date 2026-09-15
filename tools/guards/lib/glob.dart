/// 极简 glob 实现。
///
/// 为什么不用 package:glob：本工具是 CI 门禁，它的正确性直接影响「能不能发布」。
/// 引入第三方 glob 会让规则的语义依赖外部包版本。这里 30 行代码把语义钉死，
/// 并由 test/glob_test.dart 覆盖边界情况。
///
/// 支持的语法（仅这些，多余的一律当字面量）：
///   `*`   匹配除 `/` 外的任意字符（含空）
///   `**`  匹配任意字符（含 `/`）
///   `**/` 匹配零个或多个目录层级
///   `?`   匹配除 `/` 外的单个字符
///
/// 路径一律使用 POSIX 分隔符（`/`），调用方负责归一化。
library;

/// 把 glob 编译为正则。
RegExp globToRegExp(String glob) {
  final buffer = StringBuffer('^');
  var i = 0;
  while (i < glob.length) {
    final ch = glob[i];
    if (ch == '*') {
      final isDouble = i + 1 < glob.length && glob[i + 1] == '*';
      if (isDouble) {
        final followedBySlash = i + 2 < glob.length && glob[i + 2] == '/';
        if (followedBySlash) {
          // `**/` 应当能匹配零层目录，因此整体可选
          buffer.write('(?:.*/)?');
          i += 3;
        } else {
          buffer.write('.*');
          i += 2;
        }
      } else {
        buffer.write('[^/]*');
        i += 1;
      }
      continue;
    }
    if (ch == '?') {
      buffer.write('[^/]');
      i += 1;
      continue;
    }
    buffer.write(RegExp.escape(ch));
    i += 1;
  }
  buffer.write(r'$');
  return RegExp(buffer.toString());
}

/// 一组 glob 的匹配器。空集合表示「永不匹配」。
final class PathMatcher {
  PathMatcher([Iterable<String> globs = const <String>[]])
    : globs = List<String>.unmodifiable(globs),
      _regexes = List<RegExp>.unmodifiable(globs.map(globToRegExp));

  final List<String> globs;
  final List<RegExp> _regexes;

  bool get isEmpty => _regexes.isEmpty;
  bool get isNotEmpty => _regexes.isNotEmpty;

  /// [path] 必须是相对仓库根的 POSIX 路径。
  bool matches(String path) {
    for (final regex in _regexes) {
      if (regex.hasMatch(path)) return true;
    }
    return false;
  }

  /// 在 [path] 中任一位置命中的模式（用于报错时说明是哪条规则命中的）。
  String? matchedPattern(String path) {
    for (var i = 0; i < _regexes.length; i++) {
      if (_regexes[i].hasMatch(path)) return globs[i];
    }
    return null;
  }

  @override
  String toString() => 'PathMatcher(${globs.join(', ')})';
}

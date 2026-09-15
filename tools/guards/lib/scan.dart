/// 源码扫描基础设施：注释剥离、字符串掩码、逻辑语句切分、抑制指令识别。
///
/// 为什么不用逐行正则：
///   1. 多行函数调用会被漏掉。
///   2. `// 这里不要用 print(` 这种注释会误报。
///   3. 字符串里的 `password` 与变量 `password` 需要区别对待。
///
/// 核心设计：**三种同长度投影**
///   raw         —— 原始内容
///   noComments  —— 注释替换为空格，字符串字面量保留（用于「找字符串里的秘密」）
///   masked      —— 注释与字符串字面量内容都替换为空格，`${}` 插值表达式保留
///                  （用于「找代码里的调用」，避免字符串内容造成误报）
///
/// 三者长度完全相同、换行位置完全相同，因此任一投影中发现的偏移量
/// 可以直接映射到另外两个与行号上 —— 这是整个实现能保持简单的原因。
library;

/// 单字符常量（避免到处写 codeUnitAt 字面量）。
const int _slash = 0x2F; // /
const int _star = 0x2A; // *
const int _singleQuote = 0x27; // '
const int _doubleQuote = 0x22; // "
const int _backslash = 0x5C; // \
const int _dollar = 0x24; // $
const int _openBrace = 0x7B; // {
const int _closeBrace = 0x7D; // }
const int _newline = 0x0A;
const int _carriageReturn = 0x0D;
const int _space = 0x20;
const int _lowerR = 0x72; // r
const int _upperR = 0x52; // R

/// 源码的三重投影。
final class SourceProjection {
  SourceProjection._({
    required this.path,
    required this.raw,
    required this.rawLines,
    required this.noComments,
    required this.masked,
    required this.lineStarts,
  });

  /// 解析源码。失败不会抛异常 —— 扫描器必须能处理残缺代码（例如未闭合的字符串）。
  factory SourceProjection.of(String path, String source) {
    final length = source.length;
    final noComments = List<int>.of(source.codeUnits);
    final masked = List<int>.of(source.codeUnits);

    var i = 0;
    while (i < length) {
      final c = source.codeUnitAt(i);

      // 行注释
      if (c == _slash && i + 1 < length && source.codeUnitAt(i + 1) == _slash) {
        final end = _endOfLine(source, i);
        _blank(noComments, i, end);
        _blank(masked, i, end);
        i = end;
        continue;
      }

      // 块注释
      if (c == _slash && i + 1 < length && source.codeUnitAt(i + 1) == _star) {
        final end = _endOfBlockComment(source, i);
        _blank(noComments, i, end);
        _blank(masked, i, end);
        i = end;
        continue;
      }

      // raw 字符串前缀：r'...' / R"..."
      if ((c == _lowerR || c == _upperR) && _isIdentifierBoundary(source, i - 1)) {
        final quote = i + 1 < length ? source.codeUnitAt(i + 1) : -1;
        if (quote == _singleQuote || quote == _doubleQuote) {
          final end = _endOfString(source, i + 1, isRaw: true);
          _maskString(masked, source, i + 1, end, isRaw: true);
          i = end;
          continue;
        }
      }

      // 普通字符串
      if (c == _singleQuote || c == _doubleQuote) {
        final end = _endOfString(source, i, isRaw: false);
        _maskString(masked, source, i, end, isRaw: false);
        i = end;
        continue;
      }

      i += 1;
    }

    return SourceProjection._(
      path: path,
      raw: source,
      rawLines: const LineSplitterShim().convert(source),
      noComments: String.fromCharCodes(noComments),
      masked: String.fromCharCodes(masked),
      lineStarts: _computeLineStarts(source),
    );
  }

  /// 相对仓库根的 POSIX 路径。
  final String path;
  final String raw;
  final List<String> rawLines;
  final String noComments;
  final String masked;
  final List<int> lineStarts;

  /// 1-based 行号。
  int lineOf(int offset) {
    var low = 0;
    var high = lineStarts.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (lineStarts[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low + 1;
  }

  /// 1-based 列号。
  int columnOf(int offset) => offset - lineStarts[lineOf(offset) - 1] + 1;

  /// 生成适合写进报告的片段：单行化 + 截断。
  String snippetAt(int offset, {int radius = 50}) {
    final start = (offset - radius).clamp(0, raw.length);
    final end = (offset + radius).clamp(0, raw.length);
    return collapseWhitespace(raw.substring(start, end));
  }
}

/// 逻辑语句：一段可能跨行、但语义上完整的代码片段。
final class LogicalUnit {
  const LogicalUnit({
    required this.startLine,
    required this.endLine,
    required this.startOffset,
    required this.noComments,
    required this.masked,
  });

  final int startLine;
  final int endLine;
  final int startOffset;

  /// 已剥离注释、保留字符串的文本。
  final String noComments;

  /// 已剥离注释并将字符串字面量内容掩码后的文本。
  final String masked;

  bool get isBlank => masked.trim().isEmpty;

  @override
  String toString() => 'LogicalUnit($startLine-$endLine)';
}

/// 把源码切成逻辑语句。
///
/// 切分规则（刻意保守，宁可切碎也不要把整个文件并成一块）：
///   - 在括号深度 0 处遇到 `;` 结束
///   - `}` 让深度回到 0 时结束（覆盖 class / 顶层块）
List<LogicalUnit> splitLogicalUnits(SourceProjection projection) {
  final units = <LogicalUnit>[];
  final masked = projection.masked;
  final length = masked.length;

  var start = 0;
  var depth = 0;

  void emit(int end) {
    if (end <= start) {
      start = end;
      return;
    }
    final unit = LogicalUnit(
      startLine: projection.lineOf(start),
      endLine: projection.lineOf(end - 1),
      startOffset: start,
      noComments: projection.noComments.substring(start, end),
      masked: masked.substring(start, end),
    );
    if (!unit.isBlank) units.add(unit);
    start = end;
  }

  for (var i = 0; i < length; i++) {
    final c = masked.codeUnitAt(i);
    switch (c) {
      case 0x28 || 0x5B || 0x7B: // ( [ {
        depth += 1;
      case 0x29 || 0x5D: // ) ]
        if (depth > 0) depth -= 1;
      case _closeBrace:
        if (depth > 0) depth -= 1;
        if (depth == 0) emit(i + 1);
      case 0x3B: // ;
        if (depth == 0) emit(i + 1);
      default:
        break;
    }
  }
  emit(length);
  return units;
}

/// 检查 [fromLine]..[toLine] 范围内（含两端）是否存在针对 [ruleId] 的抑制指令。
///
/// 抑制语法：`// guards:ignore <rule-id>`，写法必须显式，避免误伤。
bool hasIgnoreDirective(List<String> rawLines, int fromLine, int toLine, String ruleId) {
  final pattern = RegExp('guards:ignore\\s+${RegExp.escape(ruleId)}(?![\\w-])');
  final first = (fromLine - 2).clamp(0, rawLines.length);
  final last = toLine.clamp(0, rawLines.length);
  for (var index = first; index < last; index++) {
    if (pattern.hasMatch(rawLines[index])) return true;
  }
  return false;
}

/// 把多行文本压成单行，便于写进报告。
String collapseWhitespace(String input, {int maxLength = 160}) {
  final collapsed = input.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.length <= maxLength) return collapsed;
  return '${collapsed.substring(0, maxLength)}…';
}

// ---------------------------------------------------------------------------
// 以下为纯字符扫描内部工具
// ---------------------------------------------------------------------------

void _blank(List<int> buffer, int start, int end) {
  for (var i = start; i < end; i++) {
    final c = buffer[i];
    if (c == _newline || c == _carriageReturn) continue;
    buffer[i] = _space;
  }
}

int _endOfLine(String source, int start) {
  final index = source.indexOf('\n', start);
  return index == -1 ? source.length : index;
}

int _endOfBlockComment(String source, int start) {
  final index = source.indexOf('*/', start + 2);
  return index == -1 ? source.length : index + 2;
}

bool _isIdentifierBoundary(String source, int index) {
  if (index < 0) return true;
  final c = source.codeUnitAt(index);
  final isLower = c >= 0x61 && c <= 0x7A;
  final isUpper = c >= 0x41 && c <= 0x5A;
  final isDigit = c >= 0x30 && c <= 0x39;
  return !(isLower || isUpper || isDigit || c == 0x5F || c == _dollar);
}

/// 返回字符串字面量结束后的偏移（含尾部引号）。未闭合时返回源码长度。
int _endOfString(String source, int quoteStart, {required bool isRaw}) {
  final quote = source.codeUnitAt(quoteStart);
  final isTriple =
      quoteStart + 2 < source.length &&
      source.codeUnitAt(quoteStart + 1) == quote &&
      source.codeUnitAt(quoteStart + 2) == quote;
  final quoteLength = isTriple ? 3 : 1;

  var i = quoteStart + quoteLength;
  while (i < source.length) {
    final c = source.codeUnitAt(i);
    if (!isRaw && c == _backslash) {
      i += 2;
      continue;
    }
    if (c == quote) {
      if (!isTriple) return i + 1;
      if (i + 2 < source.length &&
          source.codeUnitAt(i + 1) == quote &&
          source.codeUnitAt(i + 2) == quote) {
        return i + 3;
      }
      i += 1;
      continue;
    }
    if (!isTriple && c == _newline) return i; // 未闭合的单行字符串，容错退出
    i += 1;
  }
  return source.length;
}

/// 把字符串字面量的「文本部分」在 [masked] 中抹掉，但保留插值表达式。
///
/// 保留插值的意义：`logger.info('amount=$amount')` 中的 `$amount` 必须是可见代码，
/// 否则日志敏感信息规则会失效。
void _maskString(List<int> masked, String source, int quoteStart, int end, {required bool isRaw}) {
  final quote = source.codeUnitAt(quoteStart);
  final isTriple =
      quoteStart + 2 < source.length &&
      source.codeUnitAt(quoteStart + 1) == quote &&
      source.codeUnitAt(quoteStart + 2) == quote;
  final quoteLength = isTriple ? 3 : 1;

  final bodyStart = quoteStart + quoteLength;
  // 只有确认尾部就是结束引号时才把它排除在正文之外，
  // 否则（例如文件末尾未闭合的字符串）会把正文最后几个字符误当作引号。
  final hasClosingQuote =
      end >= bodyStart + quoteLength && _endsWithQuote(source, end, quote, isTriple);
  final bodyEnd = hasClosingQuote ? end - quoteLength : end;
  if (bodyEnd <= bodyStart) return;

  // raw 字符串不做插值，整体掩码
  if (isRaw) {
    _blank(masked, bodyStart, bodyEnd);
    return;
  }

  var i = bodyStart;
  while (i < bodyEnd) {
    final c = source.codeUnitAt(i);
    if (c == _backslash) {
      masked[i] = _space;
      if (i + 1 < bodyEnd) masked[i + 1] = _space;
      i += 2;
      continue;
    }
    if (c == _dollar) {
      if (i + 1 < bodyEnd && source.codeUnitAt(i + 1) == _openBrace) {
        final close = _matchingBrace(source, i + 1, bodyEnd);
        // 保留 `${ ... }` 整段
        i = close + 1;
        continue;
      }
      // $identifier
      var j = i + 1;
      while (j < bodyEnd && !_isIdentifierBoundary(source, j) && source.codeUnitAt(j) != _dollar) {
        j += 1;
      }
      if (j > i + 1) {
        i = j;
        continue;
      }
      masked[i] = _space;
      i += 1;
      continue;
    }
    if (c != _newline && c != _carriageReturn) {
      masked[i] = _space;
    }
    i += 1;
  }
}

bool _endsWithQuote(String source, int end, int quote, bool isTriple) {
  final quoteLength = isTriple ? 3 : 1;
  if (end - quoteLength < 0) return false;
  for (var k = 0; k < quoteLength; k++) {
    if (source.codeUnitAt(end - quoteLength + k) != quote) return false;
  }
  return true;
}

/// 从 `{`（位于 [openIndex]）出发，返回配对 `}` 的下标；找不到返回 [limit] - 1。
int _matchingBrace(String source, int openIndex, int limit) {
  var depth = 0;
  var i = openIndex;
  while (i < limit) {
    final c = source.codeUnitAt(i);
    if (c == _openBrace) {
      depth += 1;
    } else if (c == _closeBrace) {
      depth -= 1;
      if (depth == 0) return i;
    } else if (c == _singleQuote || c == _doubleQuote) {
      i = _endOfString(source, i, isRaw: false);
      continue;
    }
    i += 1;
  }
  return limit - 1;
}

List<int> _computeLineStarts(String source) {
  final starts = <int>[0];
  for (var i = 0; i < source.length; i++) {
    if (source.codeUnitAt(i) == _newline) starts.add(i + 1);
  }
  return starts;
}

/// 用 `\n` 切分，保留空行（不使用 `LineSplitter` 以避免引入 dart:convert 依赖面）。
final class LineSplitterShim {
  const LineSplitterShim();

  List<String> convert(String source) {
    final result = <String>[];
    var start = 0;
    for (var i = 0; i < source.length; i++) {
      final c = source.codeUnitAt(i);
      if (c == _newline) {
        var end = i;
        if (end > start && source.codeUnitAt(end - 1) == _carriageReturn) end -= 1;
        result.add(source.substring(start, end));
        start = i + 1;
      }
    }
    result.add(source.substring(start));
    return result;
  }
}

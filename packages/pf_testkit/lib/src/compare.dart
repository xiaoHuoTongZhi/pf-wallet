/// 期望值与实际值的比对。
///
/// 判定标准只有一条：**期望里写到的每一个键都必须与实际完全一致**。
/// 实际值里多出来的键被忽略 —— 这是刻意的，
/// 它让驱动可以输出诊断用的附加信息（如 `describe`、`length`），
/// 而不必为了通过校验去删减信息。
library;

/// 深度比较两个 JSON 值。
///
/// 数字刻意做 int / double 归一化比较（`1` 与 `1.0` 视为相等）：
/// 这是表示差异，不是行为差异。
bool jsonEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is num && b is num) return a == b;
  if (a is String && b is String) return a == b;
  if (a is bool && b is bool) return a == b;
  if (a == null || b == null) return false;
  if (a is List<Object?> && b is List<Object?>) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map<String, Object?> && b is Map<String, Object?>) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!jsonEquals(a[key], b[key])) return false;
    }
    return true;
  }
  return false;
}

/// 生成可读的差异说明。只在判定失败时调用。
String describeMismatch(Object? expected, Object? actual) =>
    '期望 ${_preview(expected)}，实际 ${_preview(actual)}';

String _preview(Object? value) {
  if (value is String) return '"$value"';
  if (value is List<Object?>) {
    if (value.length > 6) {
      final head = value.take(6).map(_preview).join(', ');
      return '[$head, …共 ${value.length} 项]';
    }
    return '[${value.map(_preview).join(', ')}]';
  }
  return '$value';
}

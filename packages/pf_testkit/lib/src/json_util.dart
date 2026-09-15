/// 向量文件的严格 JSON 读取。
///
/// 「严格」的含义：字段缺失、类型不符、十六进制串长度不对，一律抛
/// [VectorFormatException]，**绝不返回 null 让调用方猜**。
///
/// 向量文件是手写与生成混合的产物，宽松解析会把拼写错误变成
/// 「看起来通过了但什么都没测」的假绿灯 —— 那比直接报错危险得多。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 向量文件本身写错了。
///
/// 与「向量失败」严格区分：本异常一律映射为进程退出码 2（配置错误），
/// 而不是 1（实现不符）。把两者混在一起，会让「向量文件里有个错别字」
/// 看起来像「加密实现有 bug」，排查方向当场被带偏。
final class VectorFormatException implements Exception {
  VectorFormatException(this.message, {this.path});

  final String message;

  /// 出错位置的 JSON 路径，如 `container_header.json cases[3].input.saltHex`。
  final String? path;

  @override
  String toString() =>
      path == null ? 'VectorFormatException: $message' : 'VectorFormatException @ $path: $message';
}

Never _fail(String message, String path) => throw VectorFormatException(message, path: path);

/// 供驱动在输入字段结构不符时使用。
///
/// 驱动自己发现输入写错时也必须抛 [VectorFormatException]（退出码 2），
/// 而不是 `ArgumentError`（会被 runner 记为 fail、退出码 1）——
/// 「向量写错了」和「实现错了」是两件必须分开看的事。
Never throwVectorInput(String path, String message) =>
    throw VectorFormatException(message, path: path);

/// 解析 JSON 文本。顶层必须是对象。
Map<String, Object?> decodeJsonObject(String text, String path) {
  final Object? decoded = jsonDecode(text);
  if (decoded is! Map<String, Object?>) {
    _fail('顶层必须是 JSON 对象，实际 ${decoded.runtimeType}', path);
  }
  return decoded;
}

/// 必需的对象字段。
Map<String, Object?> requireMap(Map<String, Object?> parent, String key, String path) {
  final Object? value = parent[key];
  if (value is! Map<String, Object?>) {
    _fail('字段 "$key" 缺失或不是对象（实际 ${value.runtimeType}）', '$path.$key');
  }
  return value;
}

/// 可选的对象字段。
Map<String, Object?>? optionalMap(Map<String, Object?> parent, String key, String path) {
  if (!parent.containsKey(key) || parent[key] == null) return null;
  return requireMap(parent, key, path);
}

/// 必需的字符串字段。
String requireString(Map<String, Object?> parent, String key, String path) {
  final Object? value = parent[key];
  if (value is! String) {
    _fail('字段 "$key" 缺失或不是字符串（实际 ${value.runtimeType}）', '$path.$key');
  }
  return value;
}

/// 可选的字符串字段。
String optionalString(Map<String, Object?> parent, String key, String fallback) {
  final Object? value = parent[key];
  return value is String ? value : fallback;
}

/// 必需的整数字段。
int requireInt(Map<String, Object?> parent, String key, String path) {
  final Object? value = parent[key];
  if (value is! int) {
    _fail('字段 "$key" 缺失或不是整数（实际 ${value.runtimeType}）', '$path.$key');
  }
  return value;
}

/// 可选的整数字段。
int optionalInt(Map<String, Object?> parent, String key, int fallback) {
  final Object? value = parent[key];
  return value is int ? value : fallback;
}

/// 必需的布尔字段。
bool requireBool(Map<String, Object?> parent, String key, String path) {
  final Object? value = parent[key];
  if (value is! bool) {
    _fail('字段 "$key" 缺失或不是布尔（实际 ${value.runtimeType}）', '$path.$key');
  }
  return value;
}

/// 可选的布尔字段。
bool optionalBool(Map<String, Object?> parent, String key, bool fallback) {
  final Object? value = parent[key];
  return value is bool ? value : fallback;
}

/// 必需的数组字段。
List<Object?> requireList(Map<String, Object?> parent, String key, String path) {
  final Object? value = parent[key];
  if (value is! List<Object?>) {
    _fail('字段 "$key" 缺失或不是数组（实际 ${value.runtimeType}）', '$path.$key');
  }
  return value;
}

/// 可选的数组字段。
List<Object?> optionalList(Map<String, Object?> parent, String key) {
  final Object? value = parent[key];
  return value is List<Object?> ? value : const <Object?>[];
}

/// 字符串数组字段。
List<String> stringList(Map<String, Object?> parent, String key, String path) {
  final items = optionalList(parent, key);
  final result = <String>[];
  for (var i = 0; i < items.length; i++) {
    final Object? item = items[i];
    if (item is! String) {
      _fail('数组元素必须是字符串（实际 ${item.runtimeType}）', '$path.$key[$i]');
    }
    result.add(item);
  }
  return result;
}

/// 解析十六进制串为字节。
///
/// **严格要求偶数长度与合法字符** —— 一个多余的字符会让整个向量静默偏移
/// 一位，而这类错误在密文比较里表现为「完全不匹配」，极难定位。
Uint8List parseHex(String text, String path) {
  final normalized = text.trim().toLowerCase();
  if (normalized.length.isOdd) {
    _fail('十六进制长度必须为偶数，实际 ${normalized.length}', path);
  }
  final bytes = Uint8List(normalized.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    final high = _hexValue(normalized.codeUnitAt(i * 2));
    final low = _hexValue(normalized.codeUnitAt(i * 2 + 1));
    if (high < 0 || low < 0) {
      _fail('非法十六进制字符（位置 ${i * 2}）', path);
    }
    bytes[i] = (high << 4) | low;
  }
  return bytes;
}

/// 十六进制字符串字段 → 字节。
Uint8List requireHexBytes(Map<String, Object?> parent, String key, String path) =>
    parseHex(requireString(parent, key, path), '$path.$key');

int _hexValue(int codeUnit) {
  if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30;
  if (codeUnit >= 0x61 && codeUnit <= 0x66) return codeUnit - 0x61 + 10;
  return -1;
}

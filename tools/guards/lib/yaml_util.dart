/// YAML 载入与安全取值。
///
/// 所有取值失败都必须抛 [GuardException]（退出码 2），而不是静默用默认值兜底。
/// 理由：规则文件写错却静默通过，等于门禁失效而无人察觉 —— 这是最坏的结果。
library;

import 'package:yaml/yaml.dart';

import 'model.dart';

/// 解析 YAML 文本为普通 `Map<String, Object?>`。
Map<String, Object?> parseYamlMap(String raw, {required String sourceName}) {
  Object? document;
  try {
    document = loadYaml(raw);
  } on YamlException catch (error) {
    throw GuardException('YAML 解析失败: $sourceName', hint: error.message);
  }
  if (document == null) return <String, Object?>{};
  if (document is! Map) {
    throw GuardException('YAML 根节点必须是映射（mapping）: $sourceName');
  }
  return normalizeMap(document.cast<Object?, Object?>(), path: r'$');
}

/// 递归把 `YamlMap` / `YamlList` 转成普通集合，并强制键为 String。
Map<String, Object?> normalizeMap(Map<Object?, Object?> input, {String path = r'$'}) {
  final result = <String, Object?>{};
  for (final entry in input.entries) {
    final key = entry.key;
    if (key is! String) {
      throw GuardException('$path 下出现非字符串键: ${key.runtimeType}');
    }
    result[key] = normalizeValue(entry.value, path: '$path.$key');
  }
  return result;
}

/// 递归归一化任意 YAML 值。
Object? normalizeValue(Object? value, {String path = r'$'}) {
  if (value is Map) {
    return normalizeMap(value.cast<Object?, Object?>(), path: path);
  }
  if (value is List) {
    return List<Object?>.unmodifiable(
      value.indexed.map((e) => normalizeValue(e.$2, path: '$path[${e.$1}]')),
    );
  }
  return value;
}

/// 读取必填 map 字段。
Map<String, Object?> requireMap(Map<String, Object?> source, String key, {required String path}) {
  final value = source[key];
  if (value == null) {
    throw GuardException('缺少必填字段: $path.$key');
  }
  if (value is! Map) {
    throw GuardException('$path.$key 必须是映射，实际是 ${value.runtimeType}');
  }
  return value.cast<String, Object?>();
}

/// 读取可选 map 字段，缺失或为 null 时返回 null。
Map<String, Object?>? optionalMap(Map<String, Object?> source, String key, {required String path}) {
  final value = source[key];
  if (value == null) return null;
  if (value is! Map) {
    throw GuardException('$path.$key 必须是映射，实际是 ${value.runtimeType}');
  }
  return value.cast<String, Object?>();
}

/// 读取必填字符串字段。
String requireString(Map<String, Object?> source, String key, {required String path}) {
  final value = source[key];
  if (value is! String || value.isEmpty) {
    throw GuardException('$path.$key 必须是非空字符串，实际是 ${value.runtimeType}');
  }
  return value;
}

/// 读取可选字符串字段。
String? optionalString(Map<String, Object?> source, String key, {required String path}) {
  final value = source[key];
  if (value == null) return null;
  if (value is! String) {
    throw GuardException('$path.$key 必须是字符串，实际是 ${value.runtimeType}');
  }
  return value;
}

/// 读取字符串列表字段，缺失时返回空列表。
List<String> stringList(Map<String, Object?> source, String key, {required String path}) {
  final value = source[key];
  if (value == null) return const <String>[];
  if (value is! List) {
    throw GuardException('$path.$key 必须是列表，实际是 ${value.runtimeType}');
  }
  return value.indexed
      .map((entry) {
        final item = entry.$2;
        if (item is! String) {
          throw GuardException('$path.$key[${entry.$1}] 必须是字符串，实际是 ${item.runtimeType}');
        }
        return item;
      })
      .toList(growable: false);
}

/// 读取必填整数。
int requireInt(Map<String, Object?> source, String key, {required String path}) {
  final value = source[key];
  if (value is! int) {
    throw GuardException('$path.$key 必须是整数，实际是 ${value.runtimeType}');
  }
  return value;
}

/// 读取可选整数，缺失时返回 [fallback]。
int optionalInt(Map<String, Object?> source, String key, {required String path, int fallback = 0}) {
  final value = source[key];
  if (value == null) return fallback;
  if (value is! int) {
    throw GuardException('$path.$key 必须是整数，实际是 ${value.runtimeType}');
  }
  return value;
}

/// 读取可选布尔，缺失时用 [fallback]。
bool optionalBool(
  Map<String, Object?> source,
  String key, {
  required String path,
  bool fallback = false,
}) {
  final value = source[key];
  if (value == null) return fallback;
  if (value is! bool) {
    throw GuardException('$path.$key 必须是布尔，实际是 ${value.runtimeType}');
  }
  return value;
}

/// 驱动注册表。
///
/// 注册表的存在让「向量里写了一个没人认领的 kind」变成**启动即失败**，
/// 而不是跑完一大圈后静默跳过一批用例。
/// 静默跳过是这类框架最常见的失效模式：半年后没人知道
/// 有 37 条向量其实从来没有被执行过。
library;

import 'driver.dart';

/// 驱动集合。
final class VectorRegistry {
  VectorRegistry(Iterable<VectorDriver> drivers) {
    for (final driver in drivers) {
      final existing = _byKind[driver.kind];
      if (existing != null) {
        throw ArgumentError(
          'kind 重复注册："${driver.kind}" 同时被 ${existing.runtimeType} '
          '与 ${driver.runtimeType} 声明',
        );
      }
      _byKind[driver.kind] = driver;
    }
  }

  final Map<String, VectorDriver> _byKind = <String, VectorDriver>{};

  /// 查找驱动。
  VectorDriver? lookup(String kind) => _byKind[kind];

  /// 全部 kind（排序，保证报告确定性）。
  List<String> get kinds => _byKind.keys.toList()..sort();

  /// 全部驱动（按 kind 排序）。
  List<VectorDriver> get drivers => kinds.map((String k) => _byKind[k]!).toList();

  int get length => _byKind.length;

  @override
  String toString() => 'VectorRegistry($length 个驱动)';
}

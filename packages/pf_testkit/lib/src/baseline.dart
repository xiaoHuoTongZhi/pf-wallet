/// pending 基线。
///
/// ## 为什么 pending 需要一个基线文件，而不是简单「允许 pending」
///
/// M0 阶段大量向量必然处于 pending（实现还没写）。若门禁直接放过 pending，
/// 就会出现一个隐蔽的退化路径：某天某个 `kind` 的驱动被误标成
/// `isImplemented = false`，或者向量引用了一个根本不存在的实现，
/// 门禁**依然全绿** —— 而它本来该测的东西一条都没测。
///
/// 所以规则收紧为：**pending 只能减，不能增**。
/// 基线文件明确写下「此刻允许 pending 的用例 ID」，于是：
///
///   - 新增 pending → 失败（有东西从「已实现」退回了「未实现」）
///   - 减少 pending → 也失败（不是坏事，但基线过期了，必须同步更新）
///
/// 后一条同样重要：只允许减少而不强制更新基线，基线就会慢慢腐烂成
/// 一份「历史待办清单」，再也没人知道里面哪些项其实已经完成。
library;

import 'dart:convert';

import 'json_util.dart';
import 'schema.dart';

/// 基线比对结果。
final class BaselineDelta {
  const BaselineDelta({required this.added, required this.resolved});

  /// 新增的 pending 用例（实际有、基线没有）。**这是失败信号**。
  final List<String> added;

  /// 已消除的 pending 用例（基线有、实际没有）。**也是失败信号**（基线需更新）。
  final List<String> resolved;

  bool get isClean => added.isEmpty && resolved.isEmpty;

  /// 生成给人看的说明。
  String describe() {
    if (isClean) return 'pending 基线与实际一致';
    final buffer = StringBuffer();
    if (added.isNotEmpty) {
      buffer.writeln('新增 pending ${added.length} 条（实现倒退了，或向量引用了不存在的实现）：');
      for (final id in added) {
        buffer.writeln('  - $id');
      }
    }
    if (resolved.isNotEmpty) {
      buffer.writeln('已消除 pending ${resolved.length} 条（基线过期，需更新）：');
      for (final id in resolved) {
        buffer.writeln('  - $id');
      }
    }
    return buffer.toString().trimRight();
  }
}

/// pending 基线。
final class PendingBaseline {
  const PendingBaseline({required this.entries, this.schemaVersion = VectorSchema.current});

  /// 空基线：什么项目前都不允许 pending。
  static const PendingBaseline empty = PendingBaseline(entries: <String>{});

  /// 允许处于 pending 的用例 ID。
  final Set<String> entries;

  final int schemaVersion;

  static PendingBaseline fromJson(Map<String, Object?> json, String source) {
    final schemaVersion = requireInt(json, 'schemaVersion', source);
    VectorSchema.requireSupported(schemaVersion, source);
    final entries = stringList(json, 'pending', source).toSet();
    return PendingBaseline(schemaVersion: schemaVersion, entries: entries);
  }

  Map<String, Object?> toJson() {
    final sorted = entries.toList()..sort();
    return <String, Object?>{
      'schemaVersion': schemaVersion,
      'description':
          '允许处于 pending 的向量用例 ID。规则：只减不增。'
          '新增 pending 视为实现倒退；消除 pending 后必须同步更新本文件。',
      'pending': sorted,
    };
  }

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// 与实际 pending 集合比对。
  BaselineDelta diff(Iterable<String> actualPending) {
    final actual = actualPending.toSet();
    final added = actual.difference(entries).toList()..sort();
    final resolved = entries.difference(actual).toList()..sort();
    return BaselineDelta(added: added, resolved: resolved);
  }
}

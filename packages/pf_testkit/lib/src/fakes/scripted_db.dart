/// 向量用的记录型假 `PfDb`。
///
/// ## 它守的是什么
///
/// 不是 SQL 语义，而是**编排契约**：语句内容、参数、事务边界、调用顺序。
/// 「导入把 `cached_balance_minor` 写进去了吗」「余额重算在写入之后跑了吗」
/// 「备份失败时是不是一条写语句都没发」—— 这些问题全部只依赖语句序列，
/// 不需要一个能真正执行 SQL 的引擎。
///
/// ## 为什么不在 CI 上装真 SQLCipher
///
/// 原生库要靠 `sqlcipher_flutter_libs`（Flutter 插件）或自备 DLL，
/// 而 `deps.yaml` 的依赖洁净门禁与本仓的纯 Dart 测试纪律都不允许为了
/// 一条向量把它拉进来。真正的 SQL 语义由 M2 的真库首开测试接力 ——
/// 层与层各守一段，是这套向量设计的前提。
///
/// ## 罐头结果按「前缀」匹配
///
/// 键是 SQL 前缀（优先精确匹配，其次最长的匹配前缀）。前缀匹配是必须的：
/// `INSERT INTO account (…) VALUES (…)` 的列名由字段表决定，而
/// **占位符个数**由数据条数决定 —— 拿完整 SQL 当键会让向量在数据一变就失配。
/// 代价是「键写错 → 静默返回空结果」，因此本类会把**从未命中的键**
/// 记进 [unusedCannedKeys]，驱动把它放进实际值里比对 ——
/// 一个拼错的键会让向量变红，而不是变成一次静默的假通过。
library;

import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';

/// 记录型假驱动。
final class ScriptedDb implements PfDb {
  ScriptedDb({
    Map<String, List<Map<String, Object?>>> canned = const <String, List<Map<String, Object?>>>{},
    Set<String> failures = const <String>{},
  }) : _canned = canned,
       _failures = failures;

  final Map<String, List<Map<String, Object?>>> _canned;

  /// 命中任一前缀即抛 `PFD_E_OPEN`（模拟写入途中底层失败）。
  final Set<String> _failures;

  final List<String> statements = <String>[];
  final List<List<Object?>> argumentLog = <List<Object?>>[];
  final List<String> transactionLog = <String>[];
  final Set<String> _hitCannedKeys = <String>{};

  int openTransactions = 0;

  bool get inTransaction => openTransactions > 0;

  /// 从未被命中过的罐头键 —— 拼错的键必须被发现，否则假通过。
  List<String> get unusedCannedKeys {
    final unused =
        _canned.keys.where((String key) => !_hitCannedKeys.contains(key)).toList()..sort();
    return unused;
  }

  /// 第 [index] 条语句的参数（越界返回空列表）。
  List<Object?> argumentsOf(int index) =>
      index < argumentLog.length ? argumentLog[index] : const <Object?>[];

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, {
    List<Object?> arguments = const <Object?>[],
  }) async {
    _record(sql, arguments);
    _maybeFail(sql);
    for (final entry in _canned.entries) {
      if (sql.startsWith(entry.key)) {
        _hitCannedKeys.add(entry.key);
        return entry.value;
      }
    }
    return const <Map<String, Object?>>[];
  }

  @override
  Future<void> run(String sql, {List<Object?> arguments = const <Object?>[]}) async {
    _record(sql, arguments);
    _maybeFail(sql);
  }

  @override
  Future<T> transaction<T>(Future<T> Function(PfDb db) action) async {
    transactionLog.add('BEGIN');
    openTransactions++;
    try {
      final result = await action(this);
      transactionLog.add('COMMIT');
      return result;
    } catch (_) {
      transactionLog.add('ROLLBACK');
      rethrow;
    } finally {
      openTransactions--;
    }
  }

  void _record(String sql, List<Object?> arguments) {
    statements.add(sql);
    argumentLog.add(List<Object?>.of(arguments));
  }

  void _maybeFail(String sql) {
    for (final prefix in _failures) {
      if (sql.startsWith(prefix)) {
        throw StorageError.openFailed(cause: '假驱动按向量要求在「$prefix」处失败');
      }
    }
  }
}

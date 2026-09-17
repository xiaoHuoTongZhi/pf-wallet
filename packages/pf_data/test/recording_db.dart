import 'package:pf_data/pf_data.dart';

/// 记录型假 PfDb：不执行 SQL，只记录语句并按需回放罐头结果。
///
/// 它守的是**编排契约**（语句内容、参数、事务边界、调用顺序），
/// 不是 SQL 语义 —— 后者由 schema_v1_test 的结构断言与 M2 真库
/// 首开测试接力（本机与 CI 的 Windows runner 都没有原生 sqlite3 库，
/// 引入 DLL 又会撞上依赖洁净与 tracked-paths 门禁）。
class RecordingDb implements PfDb {
  RecordingDb({
    Map<String, List<Map<String, Object?>>> canned = const <String, List<Map<String, Object?>>>{},
  }) : _canned = canned;

  /// 按 SQL 前缀匹配的罐头结果。
  final Map<String, List<Map<String, Object?>>> _canned;

  final List<String> statements = <String>[];
  final List<List<Object?>> argumentLog = <List<Object?>>[];
  final List<String> transactionLog = <String>[];
  int openTransactions = 0;

  /// 第 [index] 条语句的参数（无参数返回空列表）。
  List<Object?> argumentsOf(int index) =>
      index < argumentLog.length ? argumentLog[index] : const <Object?>[];

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, {
    List<Object?> arguments = const <Object?>[],
  }) async {
    _record(sql, arguments);
    for (final entry in _canned.entries) {
      if (sql.startsWith(entry.key)) {
        return entry.value;
      }
    }
    return const <Map<String, Object?>>[];
  }

  @override
  Future<void> run(String sql, {List<Object?> arguments = const <Object?>[]}) async {
    _record(sql, arguments);
  }

  void _record(String sql, List<Object?> arguments) {
    statements.add(sql);
    argumentLog.add(List<Object?>.of(arguments));
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

  bool get inTransaction => openTransactions > 0;
}

/// 测试专用确定性 ID：26 字符、Crockford 字母表、不与生产 ULID 生成器
/// 共享状态。种子相同 → 结果相同（向量与随机回放的可复现前提）。
String testUlid(String seed) {
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  final chars = List<String>.filled(26, '0');
  var hash = 0x9E3779B9;
  for (final unit in seed.codeUnits) {
    hash = (hash ^ unit) * 0x01000193 & 0x7FFFFFFF;
    chars[hash % 26] = alphabet[(hash >> 5) % alphabet.length];
  }
  // 首字符限定 0-7（48 位时间戳的最高 3 位取值），保证 Ulid.isValid 通过。
  chars[0] = '0';
  for (var i = 1; i < 26; i++) {
    if (chars[i] == '0' && i > 0) {
      chars[i] = alphabet[(hash + i * 7) % alphabet.length];
    }
  }
  return chars.join();
}

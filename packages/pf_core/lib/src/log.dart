/// 日志契约。
///
/// ## 这条约束是怎么被结构化的，而不是靠自觉
///
/// 「不记录任何敏感信息到日志」用正则只能拦住明显错误（见 tools/guards 的 logging 规则）。
/// 真正可靠的保证是结构性的：
///
///   **日志入口只接受「字段名 + 标量值」，且字段名必须来自白名单。**
///
/// 于是 `logger.info('用户 ${note} 在 ${merchant} 花了 ${amount}')` 这种写法
/// 在类型层面就不可能通过 —— 没有接受自由字符串的入口。
/// 想记录金额，就必须先到 [pfAllowedLogFields] 里登记 `amount`，
/// 而那个动作会在代码评审里被明确看见并质疑。
///
/// 这不是「过滤敏感信息」，而是「敏感信息没有进入日志的通道」。
/// 两者的区别很重要：过滤器会被绕过，通道不会。
library;

/// 日志级别。
enum PfLogLevel { trace, debug, info, warn, error }

/// 字段名未登记，或字段值类型不被接受。
final class PfLogFieldRejected implements Exception {
  const PfLogFieldRejected(this.field, {this.reason});

  /// 被拒绝的字段名或值描述。
  final String field;
  final String? reason;

  @override
  String toString() =>
      'PfLogFieldRejected: 不允许写入日志的字段 "$field"'
      '${reason == null ? '' : '（$reason）'}';
}

/// 允许写入日志的字段名白名单。
///
/// 登记原则：
///   - 只登记**枚举值、计数、版本号、耗时、错误码**这类无隐私含义的量。
///   - 绝不登记：密码、密钥、盐、随机数、恢复码、金额、备注、商家、账户名、日期。
///   - 若确实需要区分「哪条记录」，用不可逆的短哈希（[deviceIdHash] 这类），
///     且哈希输入必须包含一个只存在于本机的随机盐。
const Set<String> pfAllowedLogFields = <String>{
  'attemptsRemaining',
  'bytesRead',
  'code',
  'containerVersion',
  'count',
  'deviceIdHash',
  'durationMs',
  'entityCount',
  'errorCode',
  'exitCode',
  'kdfIterations',
  'kdfMemoryKiB',
  'migrationFrom',
  'migrationTo',
  'mode',
  'phase',
  'schemaVersion',
  'source',
  'target',
  'volumeIndex',
  'volumeTotal',
};

/// 字段白名单与取值形式的校验器。
abstract final class PfLogGuard {
  /// 字段值（字符串）的最大长度。超过基本可判定为自由文本。
  static const int maxFieldValueLength = 64;

  /// 校验字段名集合。
  static void validateFields(Map<String, Object> fields) {
    for (final key in fields.keys) {
      if (!pfAllowedLogFields.contains(key)) {
        throw PfLogFieldRejected(key, reason: '未在 pfAllowedLogFields 中登记');
      }
    }
  }

  /// 校验单个字段取值。
  static void validateValue(String field, Object value) {
    if (value is int || value is bool) return;
    if (value is String) {
      if (value.length > maxFieldValueLength) {
        throw PfLogFieldRejected(
          field,
          reason: '字符串长度 ${value.length} 超过 $maxFieldValueLength，疑似自由文本',
        );
      }
      if (_controlCharacterPattern.hasMatch(value)) {
        throw PfLogFieldRejected(field, reason: '包含控制字符或换行');
      }
      return;
    }
    throw PfLogFieldRejected(field, reason: '字段值只允许 int / bool / 短字符串，实际是 ${value.runtimeType}');
  }

  /// 校验整组字段。
  static void validate(Map<String, Object> fields) {
    validateFields(fields);
    for (final entry in fields.entries) {
      validateValue(entry.key, entry.value);
    }
  }
}

/// 日志出口。实现方必须遵守 [PfLogGuard] 的约束。
abstract interface class PfLogger {
  /// 写入一条日志。
  ///
  /// [code] 是稳定的短标识（如 `import.merge.done`），不是给人看的句子。
  /// [fields] 的键必须来自 [pfAllowedLogFields]。
  void emit(PfLogLevel level, String code, {Map<String, Object> fields = const <String, Object>{}});
}

/// 丢弃全部输出。生产构建默认实现。
///
/// 即便丢弃，仍然执行校验 —— 字段违规是编码错误，必须在测试期就炸出来，
/// 而不是因为「反正不输出」而被静默吞掉。
final class NullLogger implements PfLogger {
  const NullLogger();

  @override
  void emit(
    PfLogLevel level,
    String code, {
    Map<String, Object> fields = const <String, Object>{},
  }) {
    PfLogGuard.validate(fields);
  }
}

/// 一条已通过校验的日志记录。
final class PfLogRecord {
  const PfLogRecord({required this.level, required this.code, required this.fields});

  final PfLogLevel level;
  final String code;
  final Map<String, Object> fields;

  @override
  String toString() => '[${level.name}] $code $fields';
}

/// 内存日志。测试断言专用。
final class InMemoryLogger implements PfLogger {
  final List<PfLogRecord> records = <PfLogRecord>[];

  @override
  void emit(
    PfLogLevel level,
    String code, {
    Map<String, Object> fields = const <String, Object>{},
  }) {
    PfLogGuard.validate(fields);
    records.add(
      PfLogRecord(level: level, code: code, fields: Map<String, Object>.unmodifiable(fields)),
    );
  }

  /// 清空记录。
  void clear() => records.clear();
}

final RegExp _controlCharacterPattern = RegExp(r'[\x00-\x1F\x7F]');

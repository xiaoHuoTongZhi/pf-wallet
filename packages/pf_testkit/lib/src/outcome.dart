/// 驱动对一条向量用例的执行结果。
///
/// 驱动**不做期望比对** —— 它只负责「跑出实际值」，比对由 [VectorRunner]
/// 统一完成。把比对收归框架而不是下放给各驱动，是为了保证所有向量的
/// 判定标准完全一致：否则每个驱动都会慢慢长出自己那套
/// 「差不多就算过」的宽松规则，而那种松动的门禁比没有门禁更糟。
library;

/// 用例的执行状态。
enum VectorStatus {
  /// 实际值与期望一致。
  pass('pass'),

  /// 实际值与期望不一致，或执行过程中抛出了非预期异常。
  fail('fail'),

  /// 该用例对应的实现尚未就绪（见 [VectorDriver.isImplemented]）。
  ///
  /// 刻意与 fail 区分：M0 阶段大量向量必然处于 pending，
  /// 把它们记成 fail 会让门禁从第一天起就是红的，从而失去信号价值。
  pending('pending');

  const VectorStatus(this.wireName);

  final String wireName;

  static VectorStatus parse(String raw) => VectorStatus.values.firstWhere(
    (VectorStatus s) => s.wireName == raw,
    orElse: () => throw ArgumentError.value(raw, 'raw', '未知的状态'),
  );
}

/// 一次执行的实际输出。
final class VectorOutcome {
  /// 正常返回。`actual` 是驱动产出的实际值。
  const VectorOutcome.value(Map<String, Object?> this.actual)
    : errorCode = null,
      message = null,
      pending = false;

  /// 抛出 `PfError`。`errorCode` 取自 [PfError.code]，是**稳定契约**。
  const VectorOutcome.errored(String this.errorCode, {this.message})
    : actual = null,
      pending = false;

  /// 该 kind 尚未实现。
  const VectorOutcome.pending({this.message}) : actual = null, errorCode = null, pending = true;

  /// 正常返回值。仅当 [errorCode] 与 [pending] 均为 null 时非空。
  final Map<String, Object?>? actual;

  /// 抛出的错误码。
  final String? errorCode;

  /// 附加说明（诊断信息 / pending 原因）。
  final String? message;

  /// 是否为「尚未实现」。
  final bool pending;

  /// 是否抛出了 `PfError`。
  bool get isError => errorCode != null;

  @override
  String toString() =>
      pending
          ? 'VectorOutcome.pending(${message ?? ''})'
          : isError
          ? 'VectorOutcome.errored($errorCode)'
          : 'VectorOutcome.value($actual)';
}

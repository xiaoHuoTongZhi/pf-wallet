/// 导入导出契约。
///
/// 只定契约与数据模型，不含实现 —— 具体流程属 M3。
/// 但其中几项**产品级约束**必须在 M0 写死，因为它们会影响数据模型与
/// 加密容器的设计，改起来代价很大：
///
///   1. **导入前必须自动备份，且备份句柄必须可回滚。**
///      不是「建议备份」，而是流程的强制步骤。
///   2. **导入只解析数据，不执行任何代码。**
///      因此载荷格式只能是「结构化数据 + 手写解析」，不允许出现脚本。
///   3. **导出密码与主密码相互独立。**
///      导出密钥由导出密码 + 文件盐独立派生，与主密钥链无关。
///   4. **导出结果必须做完整性校验（读回验证）后才算成功。**
///      写完就报成功，等于把「介质坏道」这类问题留给用户在未来某天发现。
library;

import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';

import 'record_version.dart';

/// 导出使用的 Argon2id 参数。
///
/// 与移动端默认一致（m=64MiB / t=3 / p=1），而不是桌面端的 256 MiB。
/// 理由：接收方可能是一台低端手机，导出文件必须能被它在 1 秒内解开。
/// 参数会完整写入文件头，因此**不要求**接收方具备同样的配置 ——
/// 桌面端用更高参数导出的文件，手机端照样能打开，只是会慢一些。
const Argon2Params exportKdfParams = Argon2Params.exportDefault;

/// 导出范围。
enum ExportScope {
  /// 全部数据。
  all('all'),

  /// 指定时间区间。
  timeRange('time_range'),

  /// 指定账本。
  ledger('ledger'),

  /// 增量：只导出指定时刻之后变更的记录。
  incremental('incremental');

  const ExportScope(this.wireName);

  /// 稳定标识（会出现在导出元数据里，改动即破坏兼容）。
  final String wireName;
}

/// 导入模式。
enum ImportMode {
  /// 合并：逐条按版本戳取最新，保证收敛。
  merge('merge'),

  /// 覆盖：清空后重建。导入前的自动备份是唯一的退路。
  replace('replace'),

  /// 仅补充：只插入本地不存在的记录，绝不修改已有记录。
  supplementOnly('supplement_only');

  const ImportMode(this.wireName);

  final String wireName;

  /// 该模式是否会修改已有记录。
  bool get mutatesExistingRecords => this != ImportMode.supplementOnly;
}

/// 导出请求。
final class ExportRequest {
  const ExportRequest({
    required this.scope,
    this.fromMilliseconds,
    this.toMilliseconds,
    this.ledgerIds = const <String>[],
    this.includeAttachments = false,
    this.incrementalSinceMilliseconds,
    this.volumeSizeBytes = defaultVolumeSizeBytes,
  });

  /// 单个分卷的目标大小：64 MiB。
  ///
  /// 选择理由：留出余量避开 100 MB 这个常见的云盘单文件门槛，
  /// 同时小到即使一片分卷丢失，用户重传的代价也可接受。
  static const int defaultVolumeSizeBytes = 64 * 1024 * 1024;

  /// 分卷下限 1 MiB（再小就只是在制造麻烦）。
  static const int minimumVolumeSizeBytes = 1024 * 1024;

  final ExportScope scope;
  final int? fromMilliseconds;
  final int? toMilliseconds;
  final List<String> ledgerIds;
  final bool includeAttachments;
  final int? incrementalSinceMilliseconds;
  final int volumeSizeBytes;

  /// 请求是否自洽。不自洽的请求应当在做任何 I/O 之前就被拒绝。
  void validate() {
    switch (scope) {
      case ExportScope.all:
        break;
      case ExportScope.timeRange:
        if (fromMilliseconds == null || toMilliseconds == null) {
          throw _invalid('时间区间导出必须同时提供起止时刻');
        }
        if (fromMilliseconds! > toMilliseconds!) {
          throw _invalid('时间区间的起始时刻晚于结束时刻');
        }
      case ExportScope.ledger:
        if (ledgerIds.isEmpty) {
          throw _invalid('按账本导出必须至少指定一个账本');
        }
      case ExportScope.incremental:
        if (incrementalSinceMilliseconds == null) {
          throw _invalid('增量导出必须提供基准时刻');
        }
    }
    if (volumeSizeBytes < minimumVolumeSizeBytes) {
      throw _invalid('分卷大小不得小于 $minimumVolumeSizeBytes 字节');
    }
  }
}

/// 导出结果。
final class ExportResult {
  const ExportResult({
    required this.filePaths,
    required this.recordCount,
    required this.totalBytes,
    required this.sha256OfPayload,
    required this.verifiedByReadBack,
  });

  /// 产出的文件（单文件时长度为 1，分卷时按卷序排列）。
  final List<String> filePaths;

  /// 导出的记录条数。
  final int recordCount;

  /// 产出的总字节数。
  final int totalBytes;

  /// 明文载荷的 SHA-256（在加密前计算，写入文件头之外的元数据中，
  /// 供接收方在解密后比对）。
  final String sha256OfPayload;

  /// 是否已通过「读回并重新解密校验」。
  ///
  /// **该项为 false 时不得向用户报告导出成功。**
  final bool verifiedByReadBack;
}

/// 一条需要用户复核的冲突。
final class ImportConflict {
  const ImportConflict({
    required this.entityKind,
    required this.recordId,
    required this.local,
    required this.remote,
    required this.decision,
  });

  /// 实体种类名（如 `transaction` / `account`）。
  final String entityKind;

  final String recordId;

  /// 本地版本。本地不存在时为 null（表示这是一条纯新增记录）。
  final RecordVersion? local;

  /// 导入文件中的版本。
  final RecordVersion remote;

  /// 裁决结果。
  final MergeDecision decision;

  @override
  String toString() => 'ImportConflict($entityKind/$recordId, ${decision.reason.wireName})';
}

/// 导入报告。
final class ImportReport {
  const ImportReport({
    required this.mode,
    required this.inserted,
    required this.updated,
    required this.skipped,
    required this.deleted,
    required this.conflicts,
    required this.rolledBack,
    this.rollbackBackupPath,
  });

  final ImportMode mode;
  final int inserted;
  final int updated;
  final int skipped;
  final int deleted;

  /// 需要用户复核的条目。空列表表示没有任何可疑分歧。
  final List<ImportConflict> conflicts;

  /// 是否已回滚（导入失败时）。
  final bool rolledBack;

  /// 导入前自动备份的路径（回滚依据）。
  final String? rollbackBackupPath;

  int get totalTouched => inserted + updated + deleted;
}

/// 回滚句柄。
///
/// 导入流程必须持有它直到导入确认成功。
/// [commit] 会删除备份 —— 一旦删除，就没有任何办法回到导入前的状态。
abstract interface class RollbackHandle {
  /// 自动备份的位置。
  String get backupPath;

  /// 回滚到导入前状态。
  Future<void> rollback();

  /// 确认导入成功，丢弃备份。
  Future<void> commit();
}

/// 导出服务。
abstract interface class ExportService {
  /// 执行导出。
  ///
  /// [exportPassword] 是 UTF-8 字节，与主密码无关。
  /// 实现必须：
  ///   - 每次导出生成新的随机盐与 nonce（写入文件头）；
  ///   - 使用 [Argon2Params.exportDefault] 或更强的参数；
  ///   - 先写临时文件、fsync、再 rename，绝不直接写目标文件；
  ///   - 完成后读回并重新解密校验，把结果填入 [ExportResult.verifiedByReadBack]。
  Future<ExportResult> export({
    required ExportRequest request,
    required Uint8List exportPassword,
    required String outputDirectory,
  });

  /// 预估导出规模（用于在开始前告知用户耗时与分卷数量）。
  Future<int> estimateRecordCount({required ExportRequest request});
}

/// 导入服务。
abstract interface class ImportService {
  /// 预演：只解析文件并计算冲突，**不修改任何数据**。
  ///
  /// 这是导入流程的第一步，用于在确定模式之前把情况告诉用户。
  Future<List<ImportConflict>> preview({
    required List<String> filePaths,
    required Uint8List exportPassword,
  });

  /// 执行导入。
  ///
  /// 实现必须：
  ///   - 在任何写入之前完成解密与完整性校验；
  ///   - 写入前自动备份并返回 [RollbackHandle]；
  ///   - 全程在单个事务内完成，异常时回滚；
  ///   - 把变更写入 `change_log`，且记录**原始 deviceId**（不是本机 deviceId）——
  ///     写错会让三设备场景下的增量导出链式断裂。
  Future<ImportReport> import({
    required List<String> filePaths,
    required Uint8List exportPassword,
    required ImportMode mode,
    bool allowReviewRequired = false,
  });
}

PfError _invalid(String detail) => ImportExportError.incompatible(detail: detail);

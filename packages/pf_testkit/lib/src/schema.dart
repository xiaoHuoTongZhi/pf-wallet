/// 向量文件格式的版本与目录约定。
///
/// ## 为什么向量文件也要版本号
///
/// 向量文件是**签入仓库的契约数据**，不是测试的附属物。
/// 它迟早会演进（新增 `expect` 维度、新增 `tags` 语义）。
/// 没有版本号，演进时只能靠「读方猜」，而读方猜错的后果是
/// 门禁静默放行一批本该失败的向量。
///
/// 因此规则是：**读到一个不认识的 schemaVersion 立刻拒绝**，
/// 由人决定是升级读方还是新建目录。
library;

import 'json_util.dart';

/// 向量格式的全局约定。
abstract final class VectorSchema {
  /// 当前读方支持的向量文件格式版本。
  static const int current = 1;

  /// 向量文件目录（相对仓库根）。
  static const String vectorsDirectory = 'test_vectors/v1';

  /// JSON Schema 文件目录（相对仓库根）。
  static const String schemaDirectory = 'test_vectors/schema';

  /// 基线文件（相对仓库根）。
  ///
  /// 记「当前允许处于 pending 的用例 ID」。规则是**只减不增**：
  /// 新增 pending 视为实现倒退，已消除 pending 视为基线未更新，两者都失败。
  static const String pendingBaselineFile = 'test_vectors/pending_baseline.json';

  /// 运行报告输出路径（相对仓库根，被 .gitignore 忽略）。
  static const String reportFile = 'build/vectors/report.json';

  /// 漂移对照输出目录（相对仓库根，被 .gitignore 忽略）。
  static const String forgedDirectory = 'build/vectors/forged';

  /// 向量文件命名后缀。
  static const String fileSuffix = '.json';

  /// 校验版本号，不匹配即抛。
  static void requireSupported(int schemaVersion, String source) {
    if (schemaVersion == current) return;
    throw VectorFormatException(
      '不支持的向量格式版本 $schemaVersion（本读方支持 $current）。'
      '请升级读方，或把向量放入 test_vectors/v<schemaVersion>/',
      path: source,
    );
  }
}

/// 里程碑标识的校验。
///
/// 刻意**不做成 enum**：里程碑是排期概念，会随项目推进增删，
/// 把它固化进代码会让「往向量里写 M7」变成一次编译改动。
/// 这里只校验形状，语义由文档（docs/M0_ACCEPTANCE.md 与路线图）承担。
final class MilestoneTag {
  const MilestoneTag._(this.value);

  /// 解析并校验。合法形状：`M` + 数字，如 `M0`、`M12`。
  static MilestoneTag parse(String raw, String path) {
    if (!_pattern.hasMatch(raw)) {
      throw VectorFormatException('里程碑标识形状非法："$raw"，应为 M0 / M1 / M12 形式', path: path);
    }
    return MilestoneTag._(raw);
  }

  final String value;

  static final RegExp _pattern = RegExp(r'^M\d{1,2}$');

  /// 里程碑序号（M0 → 0）。
  int get ordinal => int.parse(value.substring(1));

  @override
  String toString() => value;
}

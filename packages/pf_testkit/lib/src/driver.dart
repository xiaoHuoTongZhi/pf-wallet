/// 向量驱动：把「一条向量的输入」变成「实际输出」。
///
/// ## 驱动是向量与被测代码之间唯一的桥
///
/// `kind` 是桥的名字。向量文件不认识 Dart 类，只认识 `kind`；
/// 被测代码也不认识向量文件，只认识自己的 API。
/// 驱动把两者接起来，因此**驱动本身必须足够无聊**：
/// 读字段、调 API、把结果摆成 Map。一旦驱动里出现分支判断
/// （「如果是 X 就跳过校验」），向量锁定的就不再是被测代码，而是驱动作者的心情。
///
/// ## 确定性是硬要求
///
/// 同一个 `input` 必须永远得到同一个 `actual`。因此驱动里
/// **不得调用 `DateTime.now()`、`Random()`，不得读文件系统或环境变量**。
/// 所有不确定源都必须作为 `input` 字段显式传入（如时间戳、随机字节）。
/// 这条规则不靠自觉 —— `tools/guards` 的 `no-insecure-random-in-crypto`
/// 与日志门禁会扫到裸 `Random()`；时钟则由评审守。
library;

import 'outcome.dart';

/// 一个向量驱动。
abstract class VectorDriver {
  const VectorDriver();

  /// 处理的 `kind`。全局唯一，重复注册会直接抛错。
  String get kind;

  /// 一句话说明这个 kind 测什么。
  String get description;

  /// 该 kind 对应实现在当前里程碑是否已就绪。
  ///
  /// 返回 false 时，本 kind 下的用例一律记为 `pending`。
  /// 这是「先写向量、后写实现」工作流的关键开关：
  /// 它让「还没写」与「写错了」在报告里是两种颜色。
  bool get isImplemented;

  /// 输入契约：字段名 → 类型说明。用于文档与输入自检。
  Map<String, String> get inputContract;

  /// 就绪后由哪个里程碑补齐。仅用于 pending 报告文案。
  String get plannedMilestone;

  /// 执行一条用例。
  ///
  /// 实现约定：
  ///   - 用 [VectorOutcome.value] 返回正常结果；
  ///   - 捕获 `PfError` 并用 [VectorOutcome.errored] 返回其 `code`；
  ///   - **不要**捕获其他异常 —— 让它们冒泡，由 runner 记为 fail
  ///     （`ArgumentError` 之类说明向量文件写错了或是真 bug，两者都该被看见）。
  Future<VectorOutcome> run(Map<String, Object?> input);

  @override
  String toString() => 'VectorDriver($kind)';
}

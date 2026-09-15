/// 黄金测试向量框架。
///
/// ## 为什么需要「用数据锁定行为」而不是多写几个单测
///
/// 单测写的是「我认为这段代码应该怎样」，它的价值随作者记忆的消退而衰减 ——
/// 半年后没人敢改，因为不知道哪条断言是刻意的、哪条只是当时实现的快照。
///
/// 黄金向量写的是「这个格式/算法的输出**就是**这一串字节」，并附上原因。
/// 它有两个好处：
///
///   1. **跨实现可验证。** 同一批向量可以喂给 Kotlin / Swift / Rust 的实现，
///      或者喂给 OpenSSL 命令行。单测做不到这一点。
///   2. **改动必须显式。** 想让 `header.encode` 的输出变一个字节，
///      就必须改向量文件 —— 而向量文件在 code review 里看得见，diff 里刺眼。
///      「不小心改了加密格式」因此变成一件做不到的事。
///
/// ## 三层结构
///
/// ```
///   test_vectors/v1/*.json   数据   签入仓库，是契约
///   VectorDriver             桥梁   把数据接到被测代码，一个 kind 一个驱动
///   VectorRunner             判定   统一比对 → VectorReport
/// ```
///
/// ## 三个退出码
///
///   - `0` 全部通过且 pending 与基线一致
///   - `1` 有向量失败，或 pending 集合与基线不符
///   - `2` 向量文件本身有问题（格式错、kind 未注册）
///
/// 把 `2` 与 `1` 分开很关键：前者要改向量文件，后者要改实现，
/// 混在一起会让人对着正确的实现找半天 bug。
library;

export 'src/baseline.dart';
export 'src/compare.dart';
export 'src/driver.dart';
export 'src/drivers/all.dart';
export 'src/json_util.dart';
export 'src/load.dart';
export 'src/outcome.dart';
export 'src/registry.dart';
export 'src/report.dart';
export 'src/runner.dart';
export 'src/schema.dart';
export 'src/test_report.dart';
export 'src/vector.dart';

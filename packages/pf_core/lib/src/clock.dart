/// 时间来源抽象。
///
/// 为什么领域层要管「现在几点」：
///   导出文件命名、记录创建时间、预算周期判定都依赖当前时间。
///   如果这些地方直接调 `DateTime.now()`，就没有任何办法对它们写确定性测试 ——
///   只能靠「跑的时候恰好不是月末」这种运气。
///
/// 因此：**所有需要当前时间的地方都必须注入 [Clock]**。
/// 这条约束由 review 保证（无法用正则可靠检测，见 docs/M0_ACCEPTANCE.md 的说明）。
library;

/// 时间来源。
abstract class Clock {
  const Clock();

  /// 当前 UTC 时间。
  DateTime nowUtc();

  /// 当前本地时间。
  DateTime nowLocal() => nowUtc().toLocal();
}

/// 系统时钟。生产环境使用。
final class SystemClock extends Clock {
  const SystemClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}

/// 固定时钟。测试与黄金向量使用。
///
/// 不走时间会前进，必须显式 [advance] —— 这让「跨天/跨月的边界行为」
/// 可以被精确构造出来，而不是靠等。
final class FixedClock extends Clock {
  FixedClock(DateTime instant) : _current = instant.toUtc();

  DateTime _current;

  /// 当前时刻（UTC）。
  DateTime get instant => _current;

  /// 直接跳到某个时刻。
  set instant(DateTime value) => _current = value.toUtc();

  /// 前进指定时长（可为负，用于测试时钟回拨）。
  void advance(Duration delta) => _current = _current.add(delta);

  @override
  DateTime nowUtc() => _current;
}

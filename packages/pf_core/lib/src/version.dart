/// 构建期常量与版本号。
///
/// 为什么不用 `package_info_plus`：
///   运行时读取应用包信息会引入一个「可读取设备/安装身份」的调用点，
///   而这里真正需要的只是几个编译期就已知的数字。
///   一个 review 分类的依赖，换来的是零收益 —— 这笔账不划算。
///   见 tools/guards/rules/deps_allowlist.yaml 中该包的「已明确拒绝」记录。
library;

/// 构建期常量。
///
/// 发布新版本时，这几个数字必须与 apps/pf_mobile/pubspec.yaml 的 `version` 同步更新，
/// 且由 CI 关卡 1 校验一致性。
abstract final class PfBuildInfo {
  /// 应用语义版本（不含构建号）。
  static const String appVersion = '0.1.0';

  /// 数据库 schema 版本。每次结构变更 +1。
  static const int schemaVersion = 1;

  /// 加密容器（.pfb）格式主版本。写入文件头偏移 4。
  static const int containerFormatVersion = 1;

  /// 加密容器格式次版本。向后兼容的扩展位，写入文件头偏移 6。
  static const int containerFormatMinorVersion = 0;

  /// 导出数据载荷的 schema 版本（与数据库 schema 解耦，允许跨版本互导）。
  static const int payloadSchemaVersion = 1;

  /// 设备随机标识在 app_setting 表中的键名。
  ///
  /// 首次启动时生成一个 ULID 存入**加密数据库**，用于导出文件命名与
  /// 合并时的来源标记。刻意不读取任何硬件标识（IMEI / Android ID / IDFV）——
  /// 那些是多应用共享的指纹，而本值只在本次安装内唯一。
  static const String deviceIdSettingKey = 'device.id';

  /// 导出的默认文件前缀。
  static const String exportFilePrefix = 'pfwallet';

  /// 导出的文件扩展名。
  static const String exportFileExtension = '.pfb';
}

/// 数据库 schema 版本相关常量（供迁移使用）。
abstract final class PfSchema {
  /// 当前支持的 schema 版本。
  static const int current = PfBuildInfo.schemaVersion;

  /// 首个 schema 版本。
  static const int initial = 1;
}

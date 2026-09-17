/// 稳定错误码与错误类型。
///
/// ## 为什么错误码要独立成一类
///
/// 导入流程必须明确区分三种失败：
///   - 密码错误
///   - 文件损坏
///   - 版本不兼容
///
/// 这三种情况对用户的下一步动作完全不同（重输密码 / 重新获取文件 / 升级应用）。
/// 如果靠 `message` 字符串分支，任何一次文案调整都会静默破坏这个判断 ——
/// 而且这个 bug 只会在用户最需要帮助的时候才暴露出来。
///
/// 因此：**码是契约，文案只是表现**。码一旦发布不得修改。
library;

/// 稳定错误码常量。命名规则：`<模块>_E_<情形>`。
///
/// 模块前缀：
///   PFB —— 加密容器（二进制格式）
///   PFK —— 密钥与主密码
///   PFD —— 数据存储
///   PFI —— 导入导出与合并
///   PFC —— 领域层（core）
abstract final class PfErrorCode {
  // ---- PFB：加密容器 ----
  /// 文件头魔数不匹配。
  static const String containerMagic = 'PFB_E_MAGIC';

  /// 格式版本高于本实现支持的上限。
  static const String containerVersionUnsupported = 'PFB_E_VERSION_UNSUPPORTED';

  /// 文件长度不足以容纳声明的结构。
  static const String containerTruncated = 'PFB_E_TRUNCATED';

  /// 文件尾部明文摘要与密文不符 → 文件损坏（与密码无关）。
  static const String containerDigestMismatch = 'PFB_E_DIGEST_MISMATCH';

  /// AES-GCM 认证标签校验失败 → 密码错误（在摘要校验通过的前提下）。
  static const String containerAuthFailed = 'PFB_E_AUTH_FAILED';

  /// 头部字段自相矛盾（如盐长度为 0）。
  static const String containerHeaderInvalid = 'PFB_E_HEADER_INVALID';

  // ---- PFB：密钥派生 ----
  /// KDF 参数超出允许范围（可能是构造的恶意文件）。
  static const String kdfParamsOutOfRange = 'PFB_E_KDF_PARAMS';

  /// 派生本身失败（内存不足等）。
  static const String kdfFailed = 'PFB_E_KDF_FAILED';

  // ---- PFK：主密码与密钥 ----
  /// 主密码校验失败。
  static const String keyringWrongPassword = 'PFK_E_WRONG_PASSWORD';

  /// 恢复码校验失败（recovery.blob 的认证标签对不上）。
  static const String keyringWrongRecoveryCode = 'PFK_E_WRONG_RECOVERY_CODE';

  /// 尚未初始化主密码（首次启动）。
  static const String keyringAbsent = 'PFK_E_NO_KEYRING';

  /// 已锁定，密钥不在内存中。
  static const String keyringLocked = 'PFK_E_LOCKED';

  /// 生物识别不可用或未录入。
  static const String keyringBiometricUnavailable = 'PFK_E_BIOMETRIC_UNAVAILABLE';

  /// 保险箱数据被篡改（包裹块认证失败）。
  static const String keyringTampered = 'PFK_E_TAMPERED';

  // ---- PFD：存储 ----
  /// 数据库打开失败。
  static const String storageOpenFailed = 'PFD_E_OPEN';

  /// 迁移失败（已回滚）。
  static const String storageMigrationFailed = 'PFD_E_MIGRATION';

  /// 数据库 schema 版本高于本实现。
  static const String storageSchemaTooNew = 'PFD_E_SCHEMA_TOO_NEW';

  // ---- PFI：导入导出 ----
  /// 合并时存在需要用户裁决的冲突。
  static const String ioConflict = 'PFI_E_CONFLICT';

  /// 回滚失败（数据可能处于中间状态）。
  static const String ioRollbackFailed = 'PFI_E_ROLLBACK';

  /// 导入文件与当前库不兼容（如同一 ID 但实体种类不同）。
  static const String ioIncompatible = 'PFI_E_INCOMPATIBLE';

  /// 分卷缺失或不完整。
  static const String ioVolumeIncomplete = 'PFI_E_VOLUME';

  // ---- PFC：领域层 ----
  /// 跨币种运算。
  static const String moneyCurrencyMismatch = 'PFC_E_CURRENCY_MISMATCH';

  /// 金额超出可精确表示范围。
  static const String moneyOverflow = 'PFC_E_OVERFLOW';

  /// 金额字符串无法解析。
  static const String moneyFormat = 'PFC_E_FORMAT';

  /// 一般性校验失败。
  static const String validation = 'PFC_E_VALIDATION';
}

/// 所有 PF Wallet 错误的基类。
///
/// [message] 是给开发者看的（可含技术细节，但**绝不含敏感数据**）；
/// [userMessage] 是给用户看的（必须是完整、可执行的建议句）。
/// 两者的分离是刻意的：把技术细节暴露给用户只会让「无法找回密码」这类
/// 提示变成一句没人看得懂的废话。
sealed class PfError implements Exception {
  const PfError({required this.code, required this.message, required this.userMessage, this.cause});

  /// 稳定错误码。分支判断只能用它，不能用 [message]。
  final String code;

  /// 面向开发者的描述，不得包含密钥、密码、账目等敏感数据。
  final String message;

  /// 面向用户的完整提示句。
  final String userMessage;

  /// 底层原因（如平台异常），仅用于诊断。
  final Object? cause;

  @override
  String toString() => cause == null ? '$code: $message' : '$code: $message | cause=$cause';
}

/// 加密容器（.pfb 文件）相关错误。
final class ContainerError extends PfError {
  const ContainerError({
    required super.code,
    required super.message,
    required super.userMessage,
    super.cause,
  });

  /// 魔数不匹配：选错了文件。
  static ContainerError magicMismatch() => const ContainerError(
    code: PfErrorCode.containerMagic,
    message: '文件头魔数不匹配，不是 PFB 容器',
    userMessage: '这个文件不是 PF Wallet 的备份。请确认选择的是以 .pfb 结尾的备份文件。',
  );

  /// 版本过高：对方是更新版本的应用导出的。
  static ContainerError versionUnsupported({required int found, required int supported}) =>
      ContainerError(
        code: PfErrorCode.containerVersionUnsupported,
        message: '容器格式版本 v$found 高于本实现支持的上限 v$supported',
        userMessage: '这份备份来自更新版本的 PF Wallet。请先把当前应用升级到最新版，再重新导入。',
      );

  /// 长度不足：文件被截断（传输中断、网盘同步未完成）。
  static ContainerError truncated({required int expected, required int actual}) => ContainerError(
    code: PfErrorCode.containerTruncated,
    message: '文件长度 $actual 小于结构声明的最小长度 $expected',
    userMessage: '备份文件不完整，可能在传输或同步过程中被截断。请重新获取完整文件后重试。',
  );

  /// 明文摘要不符 → 损坏。
  static ContainerError digestMismatch({String? detail}) => ContainerError(
    code: PfErrorCode.containerDigestMismatch,
    message: detail ?? '文件尾部密文摘要与重新计算结果不一致',
    userMessage: '备份文件已损坏。请重新获取一份完整备份；若多份文件均如此，说明存储介质可能有问题。',
  );

  /// 认证标签失败 → 密码错误。
  static ContainerError authFailed() => const ContainerError(
    code: PfErrorCode.containerAuthFailed,
    message: 'AES-256-GCM 认证标签校验失败（文件完整性已确认为良好）',
    userMessage:
        '密码不正确。请注意：密码无法找回、无法重置，也没有任何后门可以绕过。'
        '请确认大小写与输入法状态后重试，或使用当初保存的恢复码。',
  );

  /// 头部字段非法。
  static ContainerError headerInvalid({required String detail}) => ContainerError(
    code: PfErrorCode.containerHeaderInvalid,
    message: '容器头部字段非法：$detail',
    userMessage: '备份文件的结构不正确，无法解析。请确认文件来源可靠后重新导出。',
  );
}

/// 密钥派生相关错误。
final class CryptoError extends PfError {
  const CryptoError({
    required super.code,
    required super.message,
    required super.userMessage,
    super.cause,
  });

  /// KDF 参数越界（恶意构造的文件会试图让受害设备分配 16 GiB 内存）。
  static CryptoError kdfParamsOutOfRange({required String detail}) => CryptoError(
    code: PfErrorCode.kdfParamsOutOfRange,
    message: 'KDF 参数越界：$detail',
    userMessage: '备份文件声明的加密参数超出安全范围，已拒绝处理。该文件可能被篡改。',
  );

  /// 派生失败。
  static CryptoError kdfFailed({Object? cause}) => CryptoError(
    code: PfErrorCode.kdfFailed,
    message: '密钥派生失败',
    userMessage: '解锁失败，设备可能内存不足。请关闭其他应用后重试。',
    cause: cause,
  );
}

/// 主密码 / 密钥保险箱相关错误。
final class KeyringError extends PfError {
  const KeyringError({
    required super.code,
    required super.message,
    required super.userMessage,
    super.cause,
  });

  /// 主密码错误。
  static KeyringError wrongPassword({int remainingAttempts = -1}) => KeyringError(
    code: PfErrorCode.keyringWrongPassword,
    message: '主密码校验失败（剩余尝试次数：$remainingAttempts）',
    userMessage:
        remainingAttempts >= 0
            ? '主密码不正确，还可以再试 $remainingAttempts 次。'
                '密码无法找回，请确认后重试。'
            : '主密码不正确。密码无法找回、无法重置，请使用恢复码或仔细核对后重试。',
  );

  /// 恢复码错误。
  ///
  /// 与 [wrongPassword] 分开编码：两者对用户的下一步动作不同
  /// （核对抄写 / 重输密码），App 层按码分支，不能靠 message 字符串猜。
  static KeyringError wrongRecoveryCode() => const KeyringError(
    code: PfErrorCode.keyringWrongRecoveryCode,
    message: '恢复码包裹块认证失败',
    userMessage:
        '恢复码不正确。请逐组核对大小写（大小写不敏感）与易混字符后重试；'
        '若恢复码已重新生成过，旧码会立即失效。',
  );

  /// 尚未设置主密码。
  static KeyringError absent() => const KeyringError(
    code: PfErrorCode.keyringAbsent,
    message: '尚未初始化密钥保险箱',
    userMessage: '这是首次使用，请先设置主密码。请务必同时保存好恢复码 —— 它是唯一的备用解锁方式。',
  );

  /// 已锁定。
  static KeyringError locked() => const KeyringError(
    code: PfErrorCode.keyringLocked,
    message: '密钥不在内存中，保险箱已锁定',
    userMessage: '应用已锁定，请重新解锁。',
  );

  /// 生物识别不可用。
  static KeyringError biometricUnavailable() => const KeyringError(
    code: PfErrorCode.keyringBiometricUnavailable,
    message: '生物识别不可用或未录入',
    userMessage: '当前设备无法使用指纹或面容解锁。请改用主密码或恢复码。',
  );

  /// 保险箱被篡改。
  static KeyringError tampered() => const KeyringError(
    code: PfErrorCode.keyringTampered,
    message: '密钥包裹块认证失败',
    userMessage: '安全数据校验失败，可能已被外部修改。请用恢复码重新建立密钥，并检查设备是否存在风险。',
  );
}

/// 存储层错误。
final class StorageError extends PfError {
  const StorageError({
    required super.code,
    required super.message,
    required super.userMessage,
    super.cause,
  });

  /// 数据库打开失败。
  static StorageError openFailed({Object? cause}) => StorageError(
    code: PfErrorCode.storageOpenFailed,
    message: 'SQLCipher 数据库打开失败',
    userMessage: '无法打开本地账本。请确认设备存储空间充足后重试；若问题持续，请从备份恢复。',
    cause: cause,
  );

  /// 迁移失败。
  static StorageError migrationFailed({required int from, required int to, Object? cause}) =>
      StorageError(
        code: PfErrorCode.storageMigrationFailed,
        message: 'schema 迁移失败：v$from → v$to（已回滚）',
        userMessage: '数据升级失败，已完成回滚，原有数据未受影响。请升级应用后重试。',
        cause: cause,
      );

  /// schema 版本过新。
  static StorageError schemaTooNew({required int found, required int supported}) => StorageError(
    code: PfErrorCode.storageSchemaTooNew,
    message: '数据库 schema v$found 高于本实现支持的 v$supported',
    userMessage: '本地数据由更新版本的应用创建。请先升级应用，不要降级使用。',
  );
}

/// 导入导出与合并错误。
final class ImportExportError extends PfError {
  const ImportExportError({
    required super.code,
    required super.message,
    required super.userMessage,
    super.cause,
  });

  /// 存在待裁决冲突。
  static ImportExportError conflict({required int count}) => ImportExportError(
    code: PfErrorCode.ioConflict,
    message: '存在 $count 条需要用户裁决的冲突记录',
    userMessage: '发现 $count 处同一笔记录在两台设备上被分别修改过，需要你确认保留哪一份。',
  );

  /// 回滚失败。
  static ImportExportError rollbackFailed({Object? cause}) => ImportExportError(
    code: PfErrorCode.ioRollbackFailed,
    message: '导入失败且回滚未完成，数据库可能处于中间状态',
    userMessage: '导入未能完成，且自动回滚也失败了。请立即从导入前自动备份恢复，不要继续操作。',
    cause: cause,
  );

  /// 数据不兼容。
  static ImportExportError incompatible({required String detail}) => ImportExportError(
    code: PfErrorCode.ioIncompatible,
    message: '导入数据与当前库不兼容：$detail',
    userMessage: '这份备份与当前账本无法合并，已停止导入且未修改任何数据。',
  );

  /// 分卷不完整。
  static ImportExportError volumeIncomplete({required int expected, required int found}) =>
      ImportExportError(
        code: PfErrorCode.ioVolumeIncomplete,
        message: '分卷不完整：期望 $expected 卷，实际 $found 卷',
        userMessage: '分卷备份不完整，缺少部分分卷文件。请把所有分卷放在同一目录后重试。',
      );
}

/// 领域层校验错误。
final class DomainError extends PfError {
  const DomainError({
    required super.code,
    required super.message,
    required super.userMessage,
    super.cause,
  });

  /// 跨币种运算。
  static DomainError currencyMismatch({required String left, required String right}) => DomainError(
    code: PfErrorCode.moneyCurrencyMismatch,
    message: '币种不一致：$left 与 $right',
    userMessage: '这两笔金额的币种不同，不能直接相加减。请先换算为同一种币种。',
  );

  /// 金额溢出。
  static DomainError moneyOverflow({required int value}) => DomainError(
    code: PfErrorCode.moneyOverflow,
    message: '金额 $value 超出可精确表示范围',
    userMessage: '金额数值过大，已超出安全范围。请检查输入。',
  );

  /// 金额格式错误。
  static DomainError moneyFormat({required String input}) => DomainError(
    code: PfErrorCode.moneyFormat,
    message: '无法解析金额字符串："$input"',
    userMessage: '金额格式不正确，请输入数字，最多两位小数。',
  );

  /// 一般校验失败。
  static DomainError validation({required String detail, String? userMessage}) => DomainError(
    code: PfErrorCode.validation,
    message: detail,
    userMessage: userMessage ?? '输入内容不合法，请检查后重试。',
  );
}

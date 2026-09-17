/// 默认驱动集合。
///
/// 注册顺序不重要（Registry 会按 kind 排序），但**分组要清楚**：
/// 一眼能看出「M0/M1 已实现」与「M2 待补齐」各占多少。
library;

import '../driver.dart';
import '../registry.dart';
import 'm0_id.dart';
import 'm0_merge.dart';
import 'm0_money.dart';
import 'm0_params.dart';
import 'm1_aesgcm.dart';
import 'm1_balance.dart';
import 'm1_container.dart';
import 'm1_hkdf.dart';
import 'm2_crypto.dart';
import 'm2_db.dart';
import 'm2_keyring.dart';

/// 全部内置驱动。
List<VectorDriver> defaultVectorDrivers() => const <VectorDriver>[
  // ---- M0：纯字节运算与值对象，无需原生库 ----
  KdfParamsValidateDriver(),
  KdfParamsBoundsDriver(),
  KdfParamsPresetsDriver(),
  KdfParamsRoundtripDriver(),
  UlidEncodeDriver(),
  UlidDecodeDriver(),
  UlidValidateDriver(),
  UlidMonotonicDriver(),
  MoneyFormatDriver(),
  MoneyParseDriver(),
  MoneySumDriver(),
  CurrencyEqualityDriver(),
  MergeResolveDriver(),
  MergeReduceDriver(),
  MergeVersionValidityDriver(),
  // ---- M1：原语层与编排层（纯 Dart，含第三方实现但不需要原生库）----
  HkdfExtractDriver(),
  HkdfExpandDriver(),
  AeadSealDriver(),
  AeadOpenDriver(),
  KdfArgon2idDeriveDriver(),
  KeyringDbKeyDeriveDriver(),
  KeyringKeyCheckSealDriver(),
  KeyringKeyCheckOpenDriver(),
  KeyringRecoveryWrapDriver(),
  KeyringRecoveryUnwrapDriver(),
  // ---- M1 容器：§3.3 分块格式（2026-09-17 裁决的唯一 v1，76B 旧版废除）----
  ContainerHeaderEncodeDriver(),
  ContainerHeaderDecodeDriver(),
  ContainerLayoutSliceDriver(),
  ContainerDigestVerifyDriver(),
  ContainerFileSealDriver(),
  ContainerFileOpenDriver(),
  ContainerFormatConstantsDriver(),
  // ---- 数据层（纯 Dart 编排，真实 SQLCipher 驱动在 M2 对接）----
  DbOpenPlanDriver(),
  DbOpenClassifyDriver(),
  DbBalanceReplayDriver(),
];

/// 标准注册表。
VectorRegistry buildDefaultRegistry() => VectorRegistry(defaultVectorDrivers());

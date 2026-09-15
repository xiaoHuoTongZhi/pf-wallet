/// 默认驱动集合。
///
/// 注册顺序不重要（Registry 会按 kind 排序），但**分组要清楚**：
/// 一眼能看出「M0 已实现」与「M2 待补齐」各占多少。
library;

import '../driver.dart';
import '../registry.dart';
import 'm0_container.dart';
import 'm0_id.dart';
import 'm0_merge.dart';
import 'm0_money.dart';
import 'm0_params.dart';
import 'm2_crypto.dart';

/// 全部内置驱动。
List<VectorDriver> defaultVectorDrivers() => const <VectorDriver>[
  // ---- M0：纯字节运算与值对象，无需原生库 ----
  ContainerHeaderEncodeDriver(),
  ContainerHeaderDecodeDriver(),
  ContainerTrailerDecodeDriver(),
  ContainerDigestVerifyDriver(),
  ContainerLayoutSliceDriver(),
  ContainerFormatConstantsDriver(),
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
  // ---- M2：需要原生加密库 ----
  KdfArgon2idDeriveDriver(),
  AeadSealDriver(),
  AeadOpenDriver(),
  KeyringWrapDriver(),
];

/// 标准注册表。
VectorRegistry buildDefaultRegistry() => VectorRegistry(defaultVectorDrivers());

/// 密钥派生契约。
library;

import 'dart:typed_data';

import 'argon2_params.dart';

/// 密钥派生函数。
///
/// ## 为什么参数是「传入」而不是「属性」
///
/// 同一个应用里同时存在三套派生参数：移动端默认、桌面端默认、以及
/// **文件头里记录的那一套**（导入时必须用文件自己的参数，否则解不开）。
/// 把参数做成派生器的属性，就等于逼着调用方在每次导入时构造一个新的派生器 ——
/// 那正是 bug 的温床。
///
/// ## 执行位置
///
/// 派生一次要占用几十到几百 MiB 内存、耗时数百毫秒。
/// 实现必须在后台 isolate 中执行，绝不能在 UI isolate 上跑：
/// 在主线程上跑 Argon2id 会让解锁页冻结，而用户的第一反应是「应用卡死了，
/// 我再点几次」—— 于是排队执行好几次派生。
abstract interface class KeyDeriver {
  /// 算法标识，用于诊断。序列化用的是容器头里的数值 ID，不是这个。
  String get algorithm;

  /// 由密码与盐派生密钥。
  ///
  /// [password] 必须是 UTF-8 字节，**不接受 String**：
  /// Dart 的 String 无法清零，传字节至少让调用方有机会在派生完成后立刻 zeroize。
  /// 这个签名是刻意「难用」的，目的是让每个调用点都必须显式考虑清零。
  Future<Uint8List> derive({
    required Uint8List password,
    required Uint8List salt,
    required Argon2Params params,
  });
}

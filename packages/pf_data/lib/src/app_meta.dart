/// `app_meta` 表的访问（§2.3 的元信息表，不含敏感数据）。
///
/// ## 为什么值得单独一个文件
///
/// 这张表是全库**唯一一张「键值对 + 无业务语义」**的表，因此它的读写最容易被
/// 顺手写成一句 `SELECT value FROM app_meta WHERE key = '...'` —— 而那句 SQL
/// 一旦散落在 CLI、迁移与测试里，「这张表里到底有哪些键」就没有任何
/// 可枚举的答案，改键名时也不会有人知道该改几处。
///
/// 集中到这里的收益是具体的：键名是一个常量（且设备标识的键名来自
/// `pf_core` 的 [PfBuildInfo.deviceIdSettingKey]，不在这里重抄一遍），
/// 于是新增一个键必然出现在本文件的 diff 里。
library;

import 'package:pf_core/pf_core.dart';

import 'db.dart';

/// `app_meta` 的读写。全部是静态方法：它没有状态，也不需要被继承。
abstract final class AppMetaStore {
  /// 本机设备标识的键名。
  ///
  /// 取 `pf_core` 的常量而不是在本地写一个字符串：那个键同时被导出文件命名、
  /// 合并来源标记与本节用到，一旦两处写歪，表现是「设备标识忽然变成了另一个值」——
  /// 而它进的是每一条记录的 `device_id`，改了等于全库记录都被视为来自新设备。
  static const String deviceIdKey = PfBuildInfo.deviceIdSettingKey;

  /// 读一个键。不存在返回 null（**不抛错**：查不到是正常处境，
  /// 首次启动时每个键都不存在）。
  static Future<String?> read(PfDb db, String key) async {
    final rows = await db.query(
      'SELECT value FROM app_meta WHERE key = ?',
      arguments: <Object?>[key],
    );
    if (rows.isEmpty) {
      return null;
    }
    final value = rows.first['value'];
    return value == null ? null : '$value';
  }

  /// 写入一个键，**已存在则不动**。
  ///
  /// 「不动」而不是「覆盖」是刻意的：设备标识一旦生成就必须稳定 ——
  /// 每次启动都重新生成的话，同一个人的同一个库会在几天内积累出十几个
  /// `device_id`，而合并裁决（§4.4）里 `device_id` 是版本戳的组成部分，
  /// 于是「同一台设备上的两条记录」会被判成两条不同来源的记录。
  static Future<void> writeIfAbsent(PfDb db, String key, String value) async {
    await db.run(
      'INSERT OR IGNORE INTO app_meta (key, value) VALUES (?, ?)',
      arguments: <Object?>[key, value],
    );
  }

  /// 读出全部键值（调试与 `pf info` 类命令用）。
  static Future<Map<String, String>> readAll(PfDb db) async {
    final rows = await db.query('SELECT key, value FROM app_meta ORDER BY key');
    return <String, String>{
      for (final row in rows)
        if (row['key'] != null) '${row['key']}': '${row['value']}',
    };
  }

  /// 取设备标识；没有就生成一个并存下来。
  ///
  /// [generate] 只为测试注入确定性标识而存在 —— 生产路径上不传，
  /// 用 [Ulid.next]。之所以要给这个口子：导出文件的 manifest 里带
  /// `deviceId`，若测试无法固定它，任何「导出的字节应当确定」的断言
  /// 都只能退化成「大概一致」。
  static Future<String> readOrCreateDeviceId(PfDb db, {String Function()? generate}) async {
    final existing = await read(db, deviceIdKey);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final created = (generate ?? Ulid.next)();
    if (!Ulid.isValid(created)) {
      throw DomainError.validation(detail: '生成的设备标识不是合法 ULID：$created');
    }
    await writeIfAbsent(db, deviceIdKey, created);
    // 再读一次而不是直接返回 created：`INSERT OR IGNORE` 在并发下可能
    // 被别人抢先写入，此时库里的值才是事实。返回一个没写进去的标识，
    // 会让「导出文件的 deviceId」与「库里记录带的 device_id」不一致。
    return (await read(db, deviceIdKey)) ?? created;
  }
}

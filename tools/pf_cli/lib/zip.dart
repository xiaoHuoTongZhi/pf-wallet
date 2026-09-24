/// 最小 ZIP 读取器 —— **只做一件事**：从一个 ZIP 里取出一个成员。
///
/// ## 为什么手写而不是引依赖
///
/// 本仓的依赖纪律是「每个新增包都要能回答它为什么不可替代」。为了
/// 从一个 NuGet 包（本质是 ZIP）里取一个文件而引入 unzip 库，
/// 代价是一串传递依赖（压缩库、加密、权限位），收益只是省下这一百行。
/// 而这一百行**没有算法**：全是按偏移量读固定宽度整数，
/// 与 `pf_io` 里手写的容器头部读取是同一类代码。
///
/// ## 刻意不支持的 ZIP 特性
///
/// ZIP 是个要塞车库里都能塞进飞机的格式。这里**有意**只支持
/// `SQLitePCLRaw` 的 nupkg 实际用到的那一小块，其余一律**报错而不是猜**：
///
///   | 特性 | 处理 |
///   |---|---|
///   | 存储（method 0）与 deflate（method 8） | 支持 |
///   | 加密、分卷、ZIP64、数据描述符 | **抛 [FormatException]** |
///   | 其他压缩方法 | **抛 [FormatException]** |
///
/// 这四条都不是"以后再补"，是"**遇到了必须停下来看**"：nupkg 的构造方式
/// 一旦变化，我们希望它表现为一次明确的失败，而不是解出一份错误的字节
/// —— 后者会被下游的 sha256 拦下，但那时的报错离根因已经很远了。
///
/// 校验交给调用方：本文件只负责「解出字节」，而**判据是 sha256**
/// （比 ZIP 自带的 CRC32 强得多，且要钉的就是它）。
library;

import 'dart:io';
import 'dart:typed_data';

/// ZIP 结构的魔数与固定宽度。
abstract final class _Zip {
  /// 中央目录末记录（EOCD）签名：`PK\x05\x06`。
  static const int eocdSignature = 0x06054b50;

  /// 中央目录文件头签名：`PK\x01\x02`。
  static const int centralHeaderSignature = 0x02014b50;

  /// 本地文件头签名：`PK\x03\x04`。
  static const int localHeaderSignature = 0x04034b50;

  /// EOCD 的固定长度（不含可变长的注释）。
  static const int eocdLength = 22;

  /// 中央目录文件头的固定长度（不含名字/扩展区/注释）。
  static const int centralHeaderLength = 46;

  /// 本地文件头的固定长度（不含名字/扩展区）。
  static const int localHeaderLength = 30;

  /// 压缩方法：不压缩。
  static const int methodStored = 0;

  /// 压缩方法：deflate。
  static const int methodDeflate = 8;

  /// 32 位字段里的「见 ZIP64 扩展区」哨兵值。
  static const int zip64Sentinel = 0xFFFFFFFF;

  /// 通用位标记：第 3 位表示长度写在数据描述符里（我们拒绝）。
  static const int flagDataDescriptor = 1 << 3;

  /// 通用位标记：第 0 位表示条目被加密（我们拒绝）。
  static const int flagEncrypted = 1 << 0;
}

/// 从 [archive] 里取出 [memberPath] 成员的**解压后**字节。
///
/// [memberPath] 用的是 ZIP 内部的 POSIX 路径（如 `runtimes/win-x64/native/e_sqlcipher.dll`），
/// 大小写敏感。
Uint8List readZipMember(Uint8List archive, String memberPath) {
  final entry = _findCentralEntry(archive, memberPath);
  final dataStart = _localDataOffset(archive, entry);

  final compressed = Uint8List.sublistView(archive, dataStart, dataStart + entry.compressedSize);
  final Uint8List raw;
  switch (entry.method) {
    case _Zip.methodStored:
      raw = Uint8List.fromList(compressed);
    case _Zip.methodDeflate:
      raw = _inflateRaw(compressed);
    default:
      throw FormatException('ZIP 条目 "$memberPath" 用了不支持的压缩方法 ${entry.method}');
  }

  if (raw.length != entry.uncompressedSize) {
    throw FormatException(
      'ZIP 条目 "$memberPath" 解压后长度不符：头部声明 ${entry.uncompressedSize}，实际 ${raw.length}',
    );
  }
  return raw;
}

/// 列出 ZIP 里全部成员的名字（供诊断与测试用）。
List<String> listZipMembers(Uint8List archive) {
  final eocd = _findEocd(archive);
  final members = <String>[];
  var cursor = eocd.centralDirectoryOffset;
  for (var i = 0; i < eocd.entryCount; i++) {
    final nameLength = _u16(archive, cursor + 28);
    final extraLength = _u16(archive, cursor + 30);
    final commentLength = _u16(archive, cursor + 32);
    members.add(_utf8(archive, cursor + _Zip.centralHeaderLength, nameLength));
    cursor += _Zip.centralHeaderLength + nameLength + extraLength + commentLength;
  }
  return members;
}

// -----------------------------------------------------------------------------
// 内部
// -----------------------------------------------------------------------------

final class _Eocd {
  const _Eocd({
    required this.entryCount,
    required this.centralDirectoryOffset,
    required this.centralDirectorySize,
  });

  final int entryCount;
  final int centralDirectoryOffset;
  final int centralDirectorySize;
}

final class _CentralEntry {
  const _CentralEntry({
    required this.name,
    required this.method,
    required this.flags,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
  });

  final String name;
  final int method;
  final int flags;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
}

/// 从文件尾部向前找 EOCD。
///
/// 必须**从后往前**扫：EOCD 之后只有一段可选注释（最长 65535 字节），
/// 而文件正文里完全可能出现和签名相同的四字节 —— 从前往后扫会撞上它。
_Eocd _findEocd(Uint8List archive) {
  if (archive.length < _Zip.eocdLength) {
    throw const FormatException('文件太短，不是 ZIP（连 EOCD 都放不下）');
  }
  final lowest = archive.length - _Zip.eocdLength - 0xFFFF;
  final start = lowest < 0 ? 0 : lowest;
  for (var i = archive.length - _Zip.eocdLength; i >= start; i--) {
    if (_u32(archive, i) != _Zip.eocdSignature) continue;
    final entryCount = _u16(archive, i + 10);
    final cdSize = _u32(archive, i + 12);
    final cdOffset = _u32(archive, i + 16);
    if (cdOffset == _Zip.zip64Sentinel || cdSize == _Zip.zip64Sentinel || entryCount == 0xFFFF) {
      throw const FormatException('这个 ZIP 用了 ZIP64 结构，本读取器刻意不支持（请人工确认来源）');
    }
    return _Eocd(
      entryCount: entryCount,
      centralDirectoryOffset: cdOffset,
      centralDirectorySize: cdSize,
    );
  }
  throw const FormatException('找不到 EOCD 签名，不是 ZIP');
}

_CentralEntry _findCentralEntry(Uint8List archive, String memberPath) {
  final eocd = _findEocd(archive);
  final cdEnd = eocd.centralDirectoryOffset + eocd.centralDirectorySize;
  if (cdEnd > archive.length) {
    throw const FormatException('中央目录越界：ZIP 被截断');
  }

  var cursor = eocd.centralDirectoryOffset;
  for (var i = 0; i < eocd.entryCount; i++) {
    if (_u32(archive, cursor) != _Zip.centralHeaderSignature) {
      throw FormatException('中央目录第 $i 条的签名不对（偏移 $cursor）');
    }
    final flags = _u16(archive, cursor + 8);
    final method = _u16(archive, cursor + 10);
    final compressedSize = _u32(archive, cursor + 20);
    final uncompressedSize = _u32(archive, cursor + 24);
    final nameLength = _u16(archive, cursor + 28);
    final extraLength = _u16(archive, cursor + 30);
    final commentLength = _u16(archive, cursor + 32);
    final localHeaderOffset = _u32(archive, cursor + 42);
    final name = _utf8(archive, cursor + _Zip.centralHeaderLength, nameLength);

    if (name == memberPath) {
      if (flags & _Zip.flagEncrypted != 0) {
        throw FormatException('ZIP 条目 "$name" 被加密，拒绝解出');
      }
      if (flags & _Zip.flagDataDescriptor != 0) {
        throw FormatException('ZIP 条目 "$name" 用了数据描述符（长度写在数据之后），本读取器刻意不支持');
      }
      if (compressedSize == _Zip.zip64Sentinel || uncompressedSize == _Zip.zip64Sentinel) {
        throw FormatException('ZIP 条目 "$name" 使用了 ZIP64 长度字段，本读取器刻意不支持');
      }
      return _CentralEntry(
        name: name,
        method: method,
        flags: flags,
        compressedSize: compressedSize,
        uncompressedSize: uncompressedSize,
        localHeaderOffset: localHeaderOffset,
      );
    }

    cursor += _Zip.centralHeaderLength + nameLength + extraLength + commentLength;
  }
  throw FormatException('ZIP 里没有条目 "$memberPath"');
}

/// 本地文件头 → 数据起始偏移。长度以**中央目录**为准（本地头里可能是 0）。
int _localDataOffset(Uint8List archive, _CentralEntry entry) {
  final at = entry.localHeaderOffset;
  if (_u32(archive, at) != _Zip.localHeaderSignature) {
    throw FormatException('条目 "${entry.name}" 的本地头签名不对（偏移 $at）');
  }
  final nameLength = _u16(archive, at + 26);
  final extraLength = _u16(archive, at + 28);
  final start = at + _Zip.localHeaderLength + nameLength + extraLength;
  if (start + entry.compressedSize > archive.length) {
    throw FormatException('条目 "${entry.name}" 的数据越界：ZIP 被截断');
  }
  return start;
}

/// raw deflate 解压（ZIP 里 method 8 的载荷**没有** zlib 头）。
///
/// 用 `dart:io` 自带的 zlib（`RawZLibFilter`），不引第三方压缩库 ——
/// 也避免了"两份压缩实现给出不同结果"的可能。
Uint8List _inflateRaw(Uint8List compressed) {
  final filter = RawZLibFilter.inflateFilter(raw: true);
  final builder = BytesBuilder(copy: false);

  filter.process(compressed, 0, compressed.length);

  // 第一轮：非最终调用，让 zlib 自己决定什么时候吐数据。
  while (true) {
    final data = filter.processed(flush: false);
    if (data == null) break;
    builder.add(data);
  }
  // 收尾：最后一段可能还压在 zlib 的内部缓冲里，用 end 逼出来。
  // 退出条件是「没有再吐数据」而不是「返回 null」—— 一个空的非 null 块
  // 如果被无脑 add，两轮之间就可能转不出循环。
  while (true) {
    final data = filter.processed(flush: true, end: true);
    if (data == null || data.isEmpty) break;
    builder.add(data);
  }
  return builder.takeBytes();
}

int _u16(Uint8List bytes, int at) {
  _require(bytes, at, 2);
  return ByteData.sublistView(bytes, at, at + 2).getUint16(0, Endian.little);
}

int _u32(Uint8List bytes, int at) {
  _require(bytes, at, 4);
  return ByteData.sublistView(bytes, at, at + 4).getUint32(0, Endian.little);
}

String _utf8(Uint8List bytes, int at, int length) {
  _require(bytes, at, length);
  return String.fromCharCodes(bytes, at, at + length);
}

void _require(Uint8List bytes, int at, int length) {
  if (at < 0 || at + length > bytes.length) {
    throw FormatException('读越界：偏移 $at 长度 $length，总长 ${bytes.length}');
  }
}

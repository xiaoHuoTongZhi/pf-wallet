/// 数据库密钥（DEK）的解析：`--database-key-file` 优先，其次环境变量。
///
/// ## 它为什么与「密码」（`password.dart`）不是同一个东西
///
/// 这个 CLI 里同时存在两处秘密，而它们**不能合并成一个参数**：
///
/// | 秘密 | 用在哪 | 是什么 |
/// |---|---|---|
/// | 数据库密钥（32 字节） | 打开本地 SQLCipher 库 | **原始密钥**，不经任何 KDF |
/// | 导出密码 | `.pfb` 容器 | 交给 Argon2id 派生的**口令** |
///
/// 数据库密钥是原始密钥（见 `PfSqlitePragma.key` 的长注释：DEK 已是 32 字节
/// 高熵随机数，再跑一遍口令模式的 KDF 只增加解锁耗时、不增加任何安全性），
/// 而导出密码是口令 —— 一个 300 毫秒的 Argon2id 就是为了让「猜」变慢。
///
/// 合并成一个 `--password` 会立刻制造一个错误的心智模型：
/// 「我改了导出密码，本地库的密钥会不会变？」—— 正确答案是不会。
/// 分成两个参数，这个问题在接口层就没有歧义了。
///
/// ## 为什么没有 `--database-key <hex>`
///
/// 与 `password.dart` 同一条理由，但更严重：命令行参数会同时留在 shell 历史
/// 与进程列表里。那 32 字节**就是**库的加密密钥，不是用来派生密钥的口令 ——
/// 拿到它的人不需要爆破任何东西，`PRAGMA key` 之后直接读全库。
/// 最安全的是文件；环境变量次之（不进历史，但 `/proc/<pid>/environ` 可见）。
///
/// ## 为什么这里没有 `--if-missing` 之类的兜底
///
/// 没有密钥就**不开库**，也不去猜一个。缺密钥时唯一正确的行为是停下并说明
/// 该给什么 —— 任何「先用某个默认值跑起来」的设计都会在某台机器上
/// 以「库文件看起来是空的」的形式暴露，而那时用户已经在上面记了半年账。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';

import 'file_source.dart';

/// 环境变量：直接给出数据库密钥（64 个十六进制字符）。
const String kDatabaseKeyEnvVar = 'PF_DATABASE_KEY';

/// 密钥的十六进制长度（32 字节 × 2）。
const int _hexLength = PfSqlitePragma.databaseKeyLength * 2;

/// 解析成功的结果。
final class ResolvedDatabaseKey {
  const ResolvedDatabaseKey(this.bytes, this.source);

  /// 32 字节原始密钥。**不进任何日志、不参与任何插值。**
  final Uint8List bytes;

  /// 来源：`database-key-file` 或 `env`。进结果行 —— 排查「他说给了密钥
  /// 但没给对地方」时，这一个字段就够定位。
  final String source;
}

/// 解析失败：文案与结果行字段都已定好，调用方只负责写出去。
final class DatabaseKeyFailure {
  const DatabaseKeyFailure({required this.messages, required this.status, required this.fields});

  final List<String> messages;
  final String status;
  final Map<String, Object?> fields;
}

/// 二选一，**不会两者都为空**，也不会两者都有值。
typedef DatabaseKeyResolution = ({ResolvedDatabaseKey? value, DatabaseKeyFailure? failure});

/// 解析数据库密钥来源。
///
/// [command] 只用于结果行的 `command` 字段。
DatabaseKeyResolution resolveDatabaseKey({
  required String? databaseFile,
  required String? keyFile,
  required FileBytesReader readBytes,
  required Map<String, String> environment,
  required String command,
}) {
  final String text;
  final String source;
  if (keyFile != null) {
    final Uint8List raw;
    try {
      raw = readBytes(keyFile);
    } on FileSystemException catch (error) {
      return (
        value: null,
        failure: DatabaseKeyFailure(
          messages: <String>['读不到密钥文件：$keyFile —— ${error.message}'],
          status: 'io-error',
          fields: <String, Object?>{
            'command': command,
            'db': databaseFile,
            'databaseKeyFile': keyFile,
            'message': error.message,
          },
        ),
      );
    }
    // 复用密码文件的字节规范化：剥掉 UTF-8 BOM 与末尾**一个**换行。
    // 这两个剥离对密钥文件同样必需（记事本另存为 UTF-8 会加 BOM；
    // `echo … > key.txt` 会带一个换行），而理由与实现只有这一份 ——
    // 在这里再写一遍就是两份会分叉的剥离逻辑。
    text = utf8.decode(decodePasswordBytes(raw), allowMalformed: true);
    source = 'database-key-file';
  } else {
    final fromEnv = environment[kDatabaseKeyEnvVar];
    if (fromEnv == null || fromEnv.isEmpty) {
      return (
        value: null,
        failure: DatabaseKeyFailure(
          messages: <String>[
            '缺少数据库密钥（32 字节，64 个十六进制字符）。二选一：',
            '  --database-key-file <f>        从文件读（推荐）',
            '  环境变量 $kDatabaseKeyEnvVar    直接给出（64 个十六进制字符）',
            '刻意不提供 --database-key <hex>：命令行参数会留在 shell 历史与进程列表里，',
            '而那串字符本身就是库的加密密钥 —— 拿到它不需要爆破任何东西。',
            '注意：它不是导出密码（.pfb 的口令），两者互不替代。',
          ],
          status: 'usage-error',
          fields: <String, Object?>{'command': command, 'db': databaseFile},
        ),
      );
    }
    text = fromEnv;
    source = 'env';
  }

  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return (
      value: null,
      failure: DatabaseKeyFailure(
        messages: <String>['数据库密钥为空。这通常意味着密钥文件是空文件，或环境变量设成了空串。'],
        status: 'usage-error',
        fields: <String, Object?>{
          'command': command,
          'db': databaseFile,
          'databaseKeySource': source,
        },
      ),
    );
  }

  // 长度与字符集各自给出一条文案，且**都不回显内容**。
  // 尤其不能把 `fromHex` 的 FormatException 原文接上去：它的消息里带着
  // 那个非法字符（`非法的十六进制字符: "g"`）—— 那是密钥的一个字节，
  // 而 stderr 会被 CI 日志、终端回滚与工单一起带走。
  final body =
      (trimmed.startsWith('0x') || trimmed.startsWith('0X')) ? trimmed.substring(2) : trimmed;
  if (body.length != _hexLength) {
    // 长度不是秘密，可以说出来 —— 它是最常见的错因（复制少了一段）。
    return (
      value: null,
      failure: DatabaseKeyFailure(
        messages: <String>['数据库密钥必须是 $_hexLength 个十六进制字符（32 字节），实际 ${body.length} 个字符。'],
        status: 'usage-error',
        fields: <String, Object?>{
          'command': command,
          'db': databaseFile,
          'databaseKeySource': source,
        },
      ),
    );
  }
  if (!_isHex(body)) {
    return (
      value: null,
      failure: DatabaseKeyFailure(
        messages: <String>['数据库密钥含非十六进制字符（不回显内容：它是密钥）。'],
        status: 'usage-error',
        fields: <String, Object?>{
          'command': command,
          'db': databaseFile,
          'databaseKeySource': source,
        },
      ),
    );
  }

  final bytes = fromHex(body);
  if (bytes.length != PfSqlitePragma.databaseKeyLength) {
    // 不可达（长度已校验），留着是为了让「换一种十六进制写法」时
    // 这里仍然是一道显式的闸，而不是靠上面那条长度检查顺带成立。
    return (
      value: null,
      failure: DatabaseKeyFailure(
        messages: <String>[
          '数据库密钥解析出 ${bytes.length} 字节，期望 ${PfSqlitePragma.databaseKeyLength} 字节。',
        ],
        status: 'usage-error',
        fields: <String, Object?>{'command': command, 'db': databaseFile},
      ),
    );
  }
  return (value: ResolvedDatabaseKey(bytes, source), failure: null);
}

final RegExp _hexPattern = RegExp(r'^[0-9a-fA-F]+$');

bool _isHex(String input) => _hexPattern.hasMatch(input);

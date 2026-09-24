/// 主密码的解析：`--password-file` 优先，其次环境变量 [kPasswordEnvVar]。
///
/// ## 为什么单独一个文件，而不是在两个命令里各写一遍
///
/// `info --records` 与 `verify` 都需要密码，而「密码从哪来」这件事有三条
/// 容易写歪的分支：文件读不到、两条来源都没有、解析出来是空串。
/// 两条命令各写一份的代价不是多二十行，而是**两份会分叉**：
/// 某天 `verify` 改成 `--password-file` 读空文件也算用法错误，而 `info --records`
/// 静默地把它当成「密码错」——于是同一份密码文件在两条命令下得到相反的指引。
///
/// ## 为什么给出的是「已经写好的错误文案」而不是一个错误码
///
/// 因为这三条分支的文案**每一行都是用户照着做就能自己解决的**（换成环境变量、
/// 检查密码文件是否为空、先看文件路径）。把它们留在这一层，调用方只剩下
/// 「写 stderr + 写结果行 + 返回 2」这一个动作，也就不存在「同一种失败
/// 在两条命令里说法不同」的可能。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'file_source.dart';

/// 解析成功的结果。
final class ResolvedPassword {
  const ResolvedPassword(this.bytes, this.source);

  /// 密码字节（已按 [decodePasswordBytes] 剥离 BOM 与末尾一个换行）。
  final Uint8List bytes;

  /// 来源：`password-file` 或 `env`。进结果行 —— 排查「他说给了密码但没给对地方」
  /// 时，这一个字段就够定位。
  final String source;
}

/// 解析失败：**输出文案与结果行字段都已经定好**，调用方只负责写出去。
final class PasswordFailure {
  const PasswordFailure({required this.messages, required this.status, required this.fields});

  /// 逐行写进 stderr 的文案。
  final List<String> messages;

  /// 结果行的 `status` 词。
  final String status;

  /// 结果行的附加字段（`message` / `passwordFile` / `passwordSource` 之类）。
  final Map<String, Object?> fields;
}

/// 解析结果：二选一，**不会两者都为空**，也不会两者都有值。
typedef PasswordResolution = ({ResolvedPassword? value, PasswordFailure? failure});

/// 解析密码来源。
///
/// [command] 只用于结果行的 `command` 字段（`info` / `verify`），
/// 文案本身两条命令完全一致 —— 处境相同，说法就该相同。
PasswordResolution resolvePassword({
  required String? file,
  required String? passwordFile,
  required FileBytesReader readBytes,
  required Map<String, String> environment,
  required String command,
}) {
  if (passwordFile != null) {
    final Uint8List raw;
    try {
      raw = readBytes(passwordFile);
    } on FileSystemException catch (error) {
      return (
        value: null,
        failure: PasswordFailure(
          messages: <String>['读不到密码文件：$passwordFile —— ${error.message}'],
          status: 'io-error',
          fields: <String, Object?>{
            'command': command,
            'file': file,
            'passwordFile': passwordFile,
            'message': error.message,
          },
        ),
      );
    }
    final bytes = decodePasswordBytes(raw);
    if (bytes.isEmpty) {
      return (
        value: null,
        failure: _emptyFailure(command: command, file: file, source: 'password-file'),
      );
    }
    return (value: ResolvedPassword(bytes, 'password-file'), failure: null);
  }

  final fromEnv = environment[kPasswordEnvVar];
  if (fromEnv == null || fromEnv.isEmpty) {
    return (
      value: null,
      failure: PasswordFailure(
        messages: <String>[
          '缺少密码。二选一：',
          '  --password-file <f>    从文件读（推荐）',
          '  环境变量 $kPasswordEnvVar      直接给出密码',
          '刻意不提供 --password <明文>：命令行参数会留在 shell 历史与进程列表里。',
        ],
        status: 'usage-error',
        fields: <String, Object?>{'command': command, 'file': file},
      ),
    );
  }
  return (value: ResolvedPassword(Uint8List.fromList(utf8.encode(fromEnv)), 'env'), failure: null);
}

/// 空密码**不是**「密码错」—— 前者该让用户去看自己的命令或那个空文件，
/// 后者才该让他再试一次密码。判成 `wrong-password` 会把他引向错的方向。
PasswordFailure _emptyFailure({
  required String command,
  required String? file,
  required String source,
}) => PasswordFailure(
  messages: <String>['密码为空。这通常意味着密码文件是空文件，或环境变量设成了空串。'],
  status: 'usage-error',
  fields: <String, Object?>{'command': command, 'file': file, 'passwordSource': source},
);

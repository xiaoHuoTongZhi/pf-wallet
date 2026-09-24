/// 数据库密钥（DEK）解析的契约测试。
///
/// ## 两组要点，各自都容易写错
///
/// **① 它与「密码」不是同一个东西**（`database_key.dart` 的文件头有对照表）：
/// 数据库密钥是 32 字节**原始密钥**（不经 KDF），导出密码是交给 Argon2id 的口令。
/// 合并成一个参数会让用户以为「改了导出密码，本地库的密钥也变了」——
/// 而正确答案是不会。因此这里逐条锁死「两条来源、与密码文件互不替代」。
///
/// **② 失败文案里不得回显密钥内容**。这条比看上去重要：`fromHex` 的
/// `FormatException` 消息里带着那个非法字符（`非法的十六进制字符: "g"`），
/// 而 stderr 会被 CI 日志、终端回滚与工单一起带走。密钥泄露不需要完整 ——
/// 一个字符就足以把搜索空间砍掉一半。所以每一条反例都额外断言
/// 「消息里不出现那段秘密」。
library;

import 'dart:typed_data';

import 'package:pf_cli/pf_cli.dart';
import 'package:pf_data/pf_data.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// 一段**可辨认**的密钥文本：任何一次回显都会让下面的断言立刻命中。
const String _secretHex =
    'a1b2c3d4e5f60718293a4b5c6d7e8f90'
    '11223344556677889900aabbccddeeff';

const String _otherHex =
    '000102030405060708090a0b0c0d0e0f'
    '101112131415161718191a1b1c1d1e1f';

/// 用一段文本当密钥文件的字节。
DatabaseKeyResolution _resolveFile(
  String text, {
  Map<String, String> env = const <String, String>{},
}) {
  final files = MemoryFiles()..putText('key.txt', text);
  return resolveDatabaseKey(
    databaseFile: 'x.db',
    keyFile: 'key.txt',
    readBytes: files.read,
    environment: env,
    command: 'init',
  );
}

/// 用一段原始字节当密钥文件的字节（BOM / CRLF 这类形状必须按字节构造）。
DatabaseKeyResolution _resolveBytes(
  Uint8List raw, {
  Map<String, String> env = const <String, String>{},
}) {
  return resolveDatabaseKey(
    databaseFile: 'x.db',
    keyFile: 'key.txt',
    readBytes: (String _) => raw,
    environment: env,
    command: 'init',
  );
}

DatabaseKeyResolution _resolveEnv(String? value) => resolveDatabaseKey(
  databaseFile: 'x.db',
  keyFile: null,
  readBytes: (String _) => Uint8List(0),
  environment:
      value == null ? const <String, String>{} : <String, String>{kDatabaseKeyEnvVar: value},
  command: 'init',
);

void main() {
  group('两条来源：密钥文件优先，其次环境变量', () {
    test('从密钥文件读：BOM 与末尾换行都被剥掉', () {
      // 记事本「另存为 UTF-8」会加 BOM；`echo … > key.txt` 会带一个换行。
      // 两者都会让「密钥明明是对的，却报打不开库」—— 最难排查的一类失败。
      final raw = Uint8List.fromList(<int>[0xEF, 0xBB, 0xBF, ...'$_secretHex\r\n'.codeUnits]);
      final resolution = _resolveBytes(raw);

      expect(resolution.failure, isNull);
      expect(resolution.value!.bytes, hasLength(PfSqlitePragma.databaseKeyLength));
      expect(resolution.value!.source, 'database-key-file');
      // 逐字节验一次：BOM 若没剥掉，解出来的是另一段密钥 ——
      // 而它的表现只是「库打不开」，看不出是编码问题。
      expect(resolution.value!.bytes.first, 0xA1);
      expect(resolution.value!.bytes.last, 0xFF);
    });

    test('从环境变量读：source 是 env', () {
      final resolution = _resolveEnv(_secretHex);
      expect(resolution.failure, isNull);
      expect(resolution.value!.source, 'env');
      expect(resolution.value!.bytes.first, 0xA1);
    });

    test('两者都给时文件优先（环境变量只是后备）', () {
      final resolution = _resolveFile(
        _secretHex,
        env: const <String, String>{kDatabaseKeyEnvVar: _otherHex},
      );
      expect(resolution.value!.source, 'database-key-file');
      expect(resolution.value!.bytes.first, 0xA1, reason: '拿到的是文件里那一段，不是环境变量那一段');
    });

    test('空串环境变量算「没给」（与路径类选项同一条纪律）', () {
      final resolution = _resolveEnv('');
      expect(resolution.failure, isNotNull);
      expect(resolution.failure!.status, 'usage-error');
      expect(resolution.failure!.messages.join('\n'), contains(kDatabaseKeyEnvVar));
    });
  });

  group('反例一律是 2（用法错误），且不回显密钥', () {
    test('两条来源都没有', () {
      final failure = _resolveEnv(null).failure!;
      expect(failure.status, 'usage-error');
      final text = failure.messages.join('\n');
      expect(text, contains('--database-key-file'));
      expect(text, contains(kDatabaseKeyEnvVar));
      expect(text, contains('刻意不提供 --database-key <hex>'));
      // 「注意：它不是导出密码」这句要在，否则用户会试着拿 .pfb 的口令来开库。
      expect(text, contains('不是导出密码'));
    });

    test('密钥文件读不到 ⇒ io-error', () {
      final resolution = resolveDatabaseKey(
        databaseFile: 'x.db',
        keyFile: 'missing.txt',
        readBytes: MemoryFiles().read,
        environment: const <String, String>{},
        command: 'init',
      );
      expect(resolution.failure!.status, 'io-error');
      expect(resolution.failure!.messages.join('\n'), contains('读不到密钥文件'));
    });

    test('长度不对：说出实际长度（不是秘密），但不说内容', () {
      final resolution = _resolveFile(_secretHex.substring(0, 60));
      expect(resolution.failure!.status, 'usage-error');
      final text = resolution.failure!.messages.join('\n');
      expect(text, contains('60 个字符'), reason: '长度是最常见的错因（复制少了一段）');
      expect(text, isNot(contains(_secretHex.substring(0, 20))), reason: '失败文案里不得出现密钥内容');
    });

    test('含非十六进制字符：不回显那一段', () {
      final resolution = _resolveFile('${_secretHex.substring(0, 62)}zz');
      expect(resolution.failure!.status, 'usage-error');
      final text = resolution.failure!.messages.join('\n');
      expect(text, contains('非十六进制'));
      expect(text, isNot(contains('zz')), reason: 'fromHex 的 FormatException 会把非法字符带出来');
      expect(text, isNot(contains(_secretHex.substring(0, 20))));
    });

    test('空密钥文件', () {
      final resolution = _resolveFile('\n');
      expect(resolution.failure!.status, 'usage-error');
      expect(resolution.failure!.messages.join('\n'), contains('为空'));
    });
  });

  group('接受的写法', () {
    test('0x 前缀、大写十六进制都接受', () {
      for (final text in <String>['0x$_secretHex', '0X$_secretHex', _secretHex.toUpperCase()]) {
        final resolution = _resolveFile(text);
        expect(resolution.failure, isNull, reason: text.substring(0, 8));
        expect(resolution.value!.bytes, hasLength(32));
        expect(resolution.value!.bytes.first, 0xA1);
      }
    });

    test('成功结果只带回来源，不带回原文', () {
      final resolution = _resolveFile(_secretHex);
      // 结果对象里只有 bytes 与 source。这条断言的价值在于它是**结构性**的：
      // 将来有人为了排查方便往 ResolvedDatabaseKey 里加一个 `hex` 字段，
      // 这里不会响，但 review 时 diff 里看得见。
      expect(resolution.value!.toString(), isNot(contains(_secretHex)));
      expect(resolution.value!.source, 'database-key-file');
    });
  });
}

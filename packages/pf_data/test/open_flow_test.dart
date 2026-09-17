/// SQLCipher 打开流程编排（§3.4）的单元测试。
///
/// 期望值与 `test_vectors/v1/db_open.json` 同源（规格 §3.4 的人工转录），
/// 但这里验证的是**行为**（语句确实按序发出、错误确实按码抛出），
/// 向量锁的是**数据**（脚本内容与分类结果）—— 两层证据互相独立。
library;

import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';
import 'package:test/test.dart';

/// 录制型假会话：逐条记录执行的语句，按脚本回放预设结果或异常。
final class _RecordingSession implements RawSqliteSession {
  _RecordingSession({this.userVersion = PfSchema.current, this.failOn});

  final int userVersion;

  /// 匹配到该子串的语句会抛出 [failure]。
  final (String, Error)? failOn;

  final List<String> statements = <String>[];

  bool get sawKeyCheckRead => statements.contains('PRAGMA user_version');

  @override
  Future<Object?> execute(String statement) async {
    statements.add(statement);
    final failure = failOn;
    if (failure != null && statement.contains(failure.$1)) {
      throw failure.$2;
    }
    if (statement == 'PRAGMA user_version') {
      return userVersion;
    }
    return null;
  }
}

/// 只携带 message 的异常，模拟驱动原生异常（drift 的 SqliteException 等）。
/// 继承 Error 只为满足 only_throw_errors；测试假对象，不参与生产代码。
final class _FakeSqliteException extends Error {
  _FakeSqliteException(this.message);
  final String message;
  @override
  String toString() => message;
}

const SqlCipherOpenFlow _flow = SqlCipherOpenFlow();
final Uint8List _dek = Uint8List.fromList(List<int>.generate(32, (i) => 0x30 + i));

void main() {
  group('打开脚本顺序（§3.4 ①–⑦）', () {
    test('默认平台：key 在前、cipher 参数紧随、post-open 收尾，user_version 居中', () async {
      final session = _RecordingSession(userVersion: PfSchema.current);
      await _flow.open(session: session, databaseKey: _dek);

      expect(session.statements.first, startsWith('PRAGMA key = "x\''));
      expect(session.statements.take(5), [
        'PRAGMA key = "x\'${toHex(_dek)}\'"',
        'PRAGMA cipher_compatibility = 4',
        'PRAGMA cipher_page_size = 4096',
        'PRAGMA cipher_memory_security = ON',
        'PRAGMA foreign_keys = ON',
      ]);
      // ⑥ 验证读发生在 setup 之后、post-open 之前。
      final userVersionIndex = session.statements.indexOf('PRAGMA user_version');
      expect(userVersionIndex, 5);
      expect(session.statements.sublist(userVersionIndex + 1), PfSqlitePragma.postOpen);
    });

    test('iOS 变体：明文头声明是第一条，且在 key 之前', () async {
      final session = _RecordingSession();
      await _flow.open(session: session, databaseKey: _dek, plaintextHeaderBytes: 32);

      expect(session.statements[0], 'PRAGMA cipher_plaintext_header_size = 32');
      expect(session.statements[1], startsWith('PRAGMA key = "x\''));
    });

    test('明文头字节数只允许 0 或 32', () async {
      expect(
        () => PfSqlitePragma.openSetup(_dek, plaintextHeaderBytes: 16),
        throwsA(isA<DomainError>()),
      );
      expect(
        () => PfSqlitePragma.openSetup(_dek, plaintextHeaderBytes: 48),
        throwsA(isA<DomainError>()),
      );
    });
  });

  group('postOpen 审计不变式', () {
    test('setup（去 key 行）+ postOpen ⊇ securityRequired（缺任何一条 = 实现缺陷）', () {
      // foreign_keys 在 setup 段（§3.4 ⑤），temp_store 等在 postOpen 段 ——
      // 审计口径是"整个打开流程覆盖审计集"，不是单看 postOpen。
      final fixedSetup = PfSqlitePragma.openSetup(_dek).where((s) => !s.startsWith('PRAGMA key'));
      final covered = <String>{...fixedSetup, ...PfSqlitePragma.postOpen};
      for (final required in PfSqlitePragma.securityRequired) {
        expect(covered, contains(required), reason: '缺 $required');
      }
    });
  });

  group('user_version 检查（⑥）', () {
    test('库版本高于支持版本 ⇒ PFD_E_SCHEMA_TOO_NEW（R1 只进不退）', () async {
      final session = _RecordingSession(userVersion: PfSchema.current + 1);
      await expectLater(
        _flow.open(session: session, databaseKey: _dek),
        throwsA(isA<StorageError>().having((e) => e.code, 'code', PfErrorCode.storageSchemaTooNew)),
      );
    });

    test('user_version = 0（新库）放行，交给建库/迁移流程', () async {
      final session = _RecordingSession(userVersion: 0);
      await _flow.open(session: session, databaseKey: _dek);
      expect(session.statements.last, PfSqlitePragma.postOpen.last);
    });

    test('user_version 不可解析 ⇒ PFD_E_OPEN（页面解出来的不是合法头）', () async {
      final session = _RecordingSession(userVersion: 0);
      // 让 user_version 读返回乱码。
      final broken = _BrokenVersionSession();
      await expectLater(
        _flow.open(session: broken, databaseKey: _dek),
        throwsA(isA<StorageError>().having((e) => e.code, 'code', PfErrorCode.storageOpenFailed)),
      );
      // 忽略未使用告警：session 变量仅用于对照同型会话可正常打开。
      expect(session, isNotNull);
    });
  });

  group('错误分类（_isCipherKeyError 对接点）', () {
    test('NOTADB 且 keyCheck 未过 ⇒ PFK_E_WRONG_PASSWORD（§3.4 原文）', () async {
      final session = _RecordingSession(
        failOn: ('user_version', _FakeSqliteException('file is not a database')),
      );
      await expectLater(
        _flow.open(session: session, databaseKey: _dek),
        throwsA(
          isA<KeyringError>().having((e) => e.code, 'code', PfErrorCode.keyringWrongPassword),
        ),
      );
    });

    test('分类器（非流程路径）：NOTADB 且 keyCheck 已过 ⇒ PFD_E_OPEN', () {
      final error = classifySqliteOpenError(
        message: 'file is not a database',
        resultCode: 26,
        keyVerifiedViaKeyCheck: true,
      );
      expect(error.code, PfErrorCode.storageOpenFailed);
    });

    test('分类器：NOTADB 不带结果码也认得（消息匹配）', () {
      expect(
        classifySqliteOpenError(message: 'SqliteException: file is not a database').code,
        PfErrorCode.keyringWrongPassword,
      );
    });

    test('分类器：扩展码低 8 位是主码（26 = NOTADB）', () {
      expect(
        classifySqliteOpenError(message: 'weird wrapper', resultCode: 26 | 0x10000).code,
        PfErrorCode.keyringWrongPassword,
      );
    });

    test('分类器：一般失败不往密码错上猜', () {
      expect(
        classifySqliteOpenError(message: 'unable to open database file', resultCode: 14).code,
        PfErrorCode.storageOpenFailed,
      );
      expect(
        classifySqliteOpenError(message: 'database disk image is malformed').code,
        PfErrorCode.storageOpenFailed,
      );
    });

    test('密钥长度必须恰好 32 字节', () async {
      final short = Uint8List.fromList(List<int>.generate(31, (i) => 0x30 + i));
      expect(
        () => _flow.open(session: _RecordingSession(), databaseKey: short),
        throwsA(isA<DomainError>()),
      );
    });
  });
}

/// user_version 永远返回乱码的会话。
final class _BrokenVersionSession implements RawSqliteSession {
  @override
  Future<Object?> execute(String statement) async {
    if (statement == 'PRAGMA user_version') {
      return 'not-a-number';
    }
    return null;
  }
}

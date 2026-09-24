/// `Sqlite3Session` / `Sqlite3Db` 两个适配器的单元测试 —— **走真 FFI**。
///
/// 与 `engine_verdict_test.dart` 分工明确：那边只验规则（不碰任何动态库），
/// 这边只验「把 FFI 调用的结果翻译成契约要求的东西」这一步。
/// 加密层不参与，因此宿主自带的 SQLite 就够（见 `host_sqlite.dart`）。
///
/// 三条被钉住的取舍，每一条在本文件里都有对应的用例：
///
///   1. [Sqlite3Session.execute] 取的是**首行首列**，且必须是
///      `select` 而不是 `execute` —— 后者丢掉结果集，`PRAGMA user_version`
///      会读成"没有行"，打开流程就会把每一个库都判成"头不可解析"。
///   2. [Sqlite3Db] 的参数一律走 `?` 占位符，用户输入不进 SQL 文本。
///   3. [Sqlite3Db.transaction] 的嵌套是**合并**（内层不单独提交），
///      否则"外层回滚"会在内层已经提交之后变成一句空话。
library;

import 'dart:io';

import 'package:pf_data/pf_data.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

import 'host_sqlite.dart';

/// 建一张两列的表，作为大部分用例的底板。
Future<void> _createTable(PfDb db) => db.run('CREATE TABLE t (id INTEGER, note TEXT)');

Future<int> _countOf(PfDb db, String table) async {
  final rows = await db.query('SELECT COUNT(*) AS n FROM $table');
  return rows.first['n']! as int;
}

void main() {
  late sqlite.Sqlite3 handle;

  setUpAll(() {
    handle = openHostSqlite();
  });

  group('Sqlite3Session：打开流程要的"首行首列"', () {
    test('有行有值时返回首行首列（不是整行、不是整集）', () async {
      final db = handle.openInMemory();
      addTearDown(db.dispose);
      final session = Sqlite3Session(db);

      expect(await session.execute('SELECT 1, 2'), 1);
      expect(await session.execute("SELECT 'a', 'b'"), 'a');
    });

    test('PRAGMA user_version 读得回值（用 select 而非 execute 的唯一理由）', () async {
      final db = handle.openInMemory();
      addTearDown(db.dispose);
      final session = Sqlite3Session(db);

      // 新库是 0；写进去再读回来必须还是它。
      // 若实现改成 `execute`（走 sqlite3_exec，丢结果集），这里会读成 null，
      // 打开流程随后会把"新库"与"库头不可解析"混成同一件事。
      expect(await session.execute('PRAGMA user_version'), 0);
      expect(await session.execute('PRAGMA user_version = 7'), isNull);
      expect(await session.execute('PRAGMA user_version'), 7);
    });

    test('没有结果集的语句返回 null，而不是抛错', () async {
      final db = handle.openInMemory();
      addTearDown(db.dispose);
      final session = Sqlite3Session(db);

      expect(await session.execute('CREATE TABLE t (a)'), isNull);
      expect(await session.execute('PRAGMA key = "x\'00\'"'), isNull);
    });

    test('有行但值是 SQL NULL 时也是 null', () async {
      final db = handle.openInMemory();
      addTearDown(db.dispose);
      final session = Sqlite3Session(db);

      expect(await session.execute('SELECT NULL'), isNull);
    });

    test('语句本身报错时原样抛出（分类由打开流程负责，本层不吞）', () async {
      final db = handle.openInMemory();
      addTearDown(db.dispose);
      final session = Sqlite3Session(db);

      await expectLater(session.execute('SELECT * FROM no_such_table'), throwsA(anything));
    });
  });

  group('Sqlite3Db.query：结果集 → 行映射', () {
    test('多行多列按列名映射，空结果集是空列表', () async {
      final db = Sqlite3Db(handle.openInMemory());
      addTearDown(db.close);
      await _createTable(db);
      await db.run("INSERT INTO t VALUES (1, 'a'), (2, 'b')");

      expect(await db.query('SELECT id, note FROM t ORDER BY id'), <PfRow>[
        <String, Object?>{'id': 1, 'note': 'a'},
        <String, Object?>{'id': 2, 'note': 'b'},
      ]);
      expect(await db.query('SELECT id FROM t WHERE id > 99'), isEmpty);
    });

    test('SQL NULL 在行里是 null（不是缺键）', () async {
      final db = Sqlite3Db(handle.openInMemory());
      addTearDown(db.close);
      await _createTable(db);
      await db.run('INSERT INTO t VALUES (?, ?)', arguments: <Object?>[1, null]);

      final row = (await db.query('SELECT id, note FROM t')).single;
      expect(row.keys, containsAll(<String>['id', 'note']));
      expect(row['note'], isNull);
    });

    test('参数走占位符：引号、分号、注释都进不了 SQL 文本', () async {
      final db = Sqlite3Db(handle.openInMemory());
      addTearDown(db.close);
      await _createTable(db);

      const hostile = "o'brien'); DROP TABLE t; --";
      await db.run('INSERT INTO t VALUES (?, ?)', arguments: <Object?>[1, hostile]);

      // 表还在（注入没生效），值原样存下来了（绑定没被转义坏）。
      expect(await _countOf(db, 't'), 1);
      expect((await db.query('SELECT note FROM t')).single['note'], hostile);
    });
  });

  group('Sqlite3Db.run', () {
    test('DDL / DML / PRAGMA 都能执行，且可带参数', () async {
      final db = Sqlite3Db(handle.openInMemory());
      addTearDown(db.close);

      await _createTable(db);
      await db.run('INSERT INTO t VALUES (?, ?)', arguments: <Object?>[1, 'x']);
      await db.run('PRAGMA user_version = 3');

      expect(await _countOf(db, 't'), 1);
      expect(await db.query('PRAGMA user_version'), <PfRow>[
        <String, Object?>{'user_version': 3},
      ]);
    });
  });

  group('Sqlite3Db.transaction：提交、回滚与嵌套合并', () {
    test('正常结束 ⇒ 提交（事务里写的东西在外面看得见）', () async {
      final db = Sqlite3Db(handle.openInMemory());
      addTearDown(db.close);
      await _createTable(db);

      final result = await db.transaction<int>((txn) async {
        await txn.run('INSERT INTO t VALUES (?, ?)', arguments: <Object?>[1, 'a']);
        return 42;
      });

      expect(result, 42);
      expect(await _countOf(db, 't'), 1);
    });

    test('抛异常 ⇒ 回滚，并原样重抛', () async {
      final db = Sqlite3Db(handle.openInMemory());
      addTearDown(db.close);
      await _createTable(db);

      await expectLater(
        db.transaction<void>((txn) async {
          await txn.run('INSERT INTO t VALUES (?, ?)', arguments: <Object?>[1, 'a']);
          throw StateError('boom');
        }),
        throwsA(isA<StateError>()),
      );

      expect(await _countOf(db, 't'), 0, reason: '事务里的写必须一起消失');
    });

    test('嵌套是"合并"：内层不单独提交，外层回滚时两层一起消失', () async {
      final db = Sqlite3Db(handle.openInMemory());
      addTearDown(db.close);
      await _createTable(db);

      await expectLater(
        db.transaction<void>((outer) async {
          await outer.run('INSERT INTO t VALUES (?, ?)', arguments: <Object?>[1, 'outer']);
          await outer.transaction<void>((inner) async {
            await inner.run('INSERT INTO t VALUES (?, ?)', arguments: <Object?>[2, 'inner']);
          });
          throw StateError('boom');
        }),
        throwsA(isA<StateError>()),
      );

      // 内层若擅自 COMMIT，外层事务已被它结束 —— 于是外层的 ROLLBACK
      // 变成一句空话，两行都会留下来。这里必须是 0。
      expect(await _countOf(db, 't'), 0);
    });

    test('上一次事务失败后，下一次仍然真的开事务（状态没卡住）', () async {
      final db = Sqlite3Db(handle.openInMemory());
      addTearDown(db.close);
      await _createTable(db);

      await expectLater(
        db.transaction<void>((txn) async {
          await txn.run('INSERT INTO t VALUES (?, ?)', arguments: <Object?>[1, 'first']);
          throw StateError('first');
        }),
        throwsA(isA<StateError>()),
      );

      await expectLater(
        db.transaction<void>((txn) async {
          await txn.run('INSERT INTO t VALUES (?, ?)', arguments: <Object?>[2, 'second']);
          throw StateError('second');
        }),
        throwsA(isA<StateError>()),
      );

      // 若 `_inTransaction` 在第一次失败后没有复位，第二次会跳过 BEGIN 与
      // ROLLBACK，那行 INSERT 会被自动提交留下来 —— 于是这里是 1。
      expect(await _countOf(db, 't'), 0);
    });
  });

  group('Sqlite3Db.close：收尾语句 + 关句柄', () {
    test('关掉之后再操作会失败（不是"静默无效"）', () async {
      final db = Sqlite3Db(handle.openInMemory());
      await _createTable(db);
      db.close();

      await expectLater(db.query('SELECT id FROM t'), throwsA(anything));
    });

    test('落盘库：close 会把 WAL 收干净，数据留在主库里', () async {
      final tmp = Directory.systemTemp.createTempSync('pf_data_adapter_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final path = '${tmp.path}${Platform.pathSeparator}plain.db';

      final first = Sqlite3Db(handle.open(path));
      await first.run('PRAGMA journal_mode = WAL');
      await _createTable(first);
      await first.run('INSERT INTO t VALUES (?, ?)', arguments: <Object?>[1, 'kept']);
      first.close();

      // close 里那句 wal_checkpoint(TRUNCATE) 的可见结果：要么没有 -wal 文件，
      // 要么它被截成 0 字节。留着尾巴就等于"最后一次写入还挂在旁边"。
      final wal = File('$path-wal');
      expect(!wal.existsSync() || wal.lengthSync() == 0, isTrue, reason: '-wal 没有被收干净');

      // 换一个句柄读回来 —— 数据在文件里，不在内存里。
      final second = Sqlite3Db(handle.open(path));
      addTearDown(second.close);
      expect((await second.query('SELECT note FROM t')).single['note'], 'kept');
    });
  });
}

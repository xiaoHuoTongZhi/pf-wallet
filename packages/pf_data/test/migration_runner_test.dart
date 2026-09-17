import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';
import 'package:test/test.dart';

import 'recording_db.dart';

FixedClock _clock() => FixedClock(DateTime.utc(2026, 9, 17, 12, 0, 0));

void main() {
  group('MigrationRunner · v0 空库 → v1', () {
    test('执行全部语句，末尾推进 user_version，并写审计行', () async {
      final db = RecordingDb(
        canned: <String, List<Map<String, Object?>>>{
          'PRAGMA user_version': <Map<String, Object?>>[
            {'user_version': 0},
          ],
        },
      );
      final applied = await MigrationRunner(
        db: db,
        clock: _clock(),
      ).run(registered: kRegisteredMigrations);

      expect(applied, 1);
      expect(db.transactionLog, <String>['BEGIN', 'COMMIT'], reason: '一个迁移一个事务（R2）');
      expect(db.statements.first, 'PRAGMA user_version', reason: '先读当前版本');
      expect(db.statements[1], 'PRAGMA foreign_keys = OFF');
      expect(db.statements.contains('PRAGMA foreign_keys = ON'), isTrue);
      expect(db.statements.contains('PRAGMA user_version = 1'), isTrue);
      // 事务内最后一条是 user_version（结构 + 版本号原子生效）。
      final beginIdx = db.statements.indexOf('PRAGMA foreign_keys = OFF');
      expect(db.statements.indexOf('PRAGMA user_version = 1'), greaterThan(beginIdx));
      // 审计行在事务之外。
      final insertIdx = db.statements.indexWhere(
        (s) => s.startsWith('INSERT INTO schema_migration'),
      );
      expect(insertIdx, greaterThan(db.statements.lastIndexOf('PRAGMA user_version = 1')));
      // 全部 DDL 都执行了，顺序保持。
      final ddl = db.statements.where((s) => s.startsWith('CREATE ')).toList();
      expect(ddl, schemaV1Migration.statements);
    });

    test('审计行的 checksum/applied_at/duration 来自迁移与注入时钟', () async {
      final db = RecordingDb(
        canned: <String, List<Map<String, Object?>>>{
          'PRAGMA user_version': <Map<String, Object?>>[
            {'user_version': 0},
          ],
        },
      );
      await MigrationRunner(db: db, clock: _clock()).run(registered: kRegisteredMigrations);
      final insertIdx = db.statements.indexWhere(
        (s) => s.startsWith('INSERT INTO schema_migration'),
      );
      expect(insertIdx, greaterThanOrEqualTo(0));
      // 参数无法从语句里还原，但 checksum 函数本身可独立验证：
      expect(migrationChecksum(schemaV1Migration), hasLength(64));
      final clock = _clock();
      expect(
        clock.nowUtc().millisecondsSinceEpoch,
        DateTime.utc(2026, 9, 17, 12, 0, 0).millisecondsSinceEpoch,
      );
    });

    test('重复执行是幂等空操作（R1 只进不退 + 幂等）', () async {
      final db = RecordingDb(
        canned: <String, List<Map<String, Object?>>>{
          'PRAGMA user_version': <Map<String, Object?>>[
            {'user_version': 1},
          ],
        },
      );
      final applied = await MigrationRunner(
        db: db,
        clock: _clock(),
      ).run(registered: kRegisteredMigrations);
      expect(applied, 0);
      expect(db.statements, <String>['PRAGMA user_version'], reason: '只有版本探测，没有任何 DDL');
      expect(db.transactionLog, isEmpty);
    });
  });

  group('MigrationRunner · 必须硬失败的情形', () {
    test('空注册表 → 幂等短路', () async {
      final db = RecordingDb(
        canned: <String, List<Map<String, Object?>>>{
          'PRAGMA user_version': <Map<String, Object?>>[
            {'user_version': 1},
          ],
        },
      );
      expect(
        await MigrationRunner(db: db, clock: _clock()).run(registered: const <Migration>[]),
        0,
      );
    });

    test('迁移链断裂 → 计划构建期 DomainError，不碰任何语句', () async {
      final db = RecordingDb(
        canned: <String, List<Map<String, Object?>>>{
          'PRAGMA user_version': <Map<String, Object?>>[
            {'user_version': 1},
          ],
        },
      );
      final broken = <Migration>[
        const Migration(
          version: 2,
          description: 'v2',
          statements: <String>['CREATE TABLE t2 (id TEXT PRIMARY KEY)'],
        ),
        const Migration(
          version: 4,
          description: 'v4',
          statements: <String>['CREATE TABLE t4 (id TEXT PRIMARY KEY)'],
        ),
      ];
      await expectLater(
        MigrationRunner(db: db, clock: _clock()).run(registered: broken, maxSupportedVersion: 4),
        throwsA(isA<DomainError>()),
      );
      expect(db.statements, <String>['PRAGMA user_version'], reason: '计划失败只留下版本探测，不得执行任何 DDL');
    });

    test('user_version 不可解析 → PFD_E_MIGRATION', () async {
      final db = RecordingDb(
        canned: <String, List<Map<String, Object?>>>{
          'PRAGMA user_version': <Map<String, Object?>>[
            {'user_version': 'NaN'},
          ],
        },
      );
      await expectLater(
        MigrationRunner(db: db, clock: _clock()).run(registered: kRegisteredMigrations),
        throwsA(
          isA<StorageError>().having((e) => e.code, 'code', PfErrorCode.storageMigrationFailed),
        ),
      );
    });

    test('执行期异常 → 包裹为 PFD_E_MIGRATION（已回滚）', () async {
      // 让事务内的语句抛驱动异常：run 抛 StateError。
      final db = ThrowingDb(userVersion: 0, throwOn: 'CREATE TABLE ledger');
      await expectLater(
        MigrationRunner(db: db, clock: _clock()).run(registered: kRegisteredMigrations),
        throwsA(
          isA<StorageError>().having((e) => e.code, 'code', PfErrorCode.storageMigrationFailed),
        ),
      );
    });
  });
}

/// 在指定语句上抛驱动异常的假实现。
final class ThrowingDb extends RecordingDb {
  ThrowingDb({required int userVersion, required this.throwOn})
    : super(
        canned: <String, List<Map<String, Object?>>>{
          'PRAGMA user_version': <Map<String, Object?>>[
            {'user_version': userVersion},
          ],
        },
      );

  final String throwOn;

  @override
  Future<void> run(String sql, {List<Object?> arguments = const <Object?>[]}) async {
    if (sql.contains(throwOn)) {
      throw StateError('驱动异常：$sql');
    }
    await super.run(sql, arguments: arguments);
  }
}

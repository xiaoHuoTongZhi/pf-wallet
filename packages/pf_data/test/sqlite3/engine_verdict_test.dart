/// 引擎身份判据（`engine_verdict.dart`）的单元测试 —— **不碰 FFI**。
///
/// 这些用例在任何平台上都能跑，包括一个没有任何 SQLite 可加载的机器。
/// 它们锁的是**规则本身**：给定一组"观察到的事实"，结论必须是什么。
///
/// 判据只有一条：`PRAGMA cipher_version` 的**行数**。下面三组用例分别对应
/// 这条规则的三种输入，其中第二组是本文件的重点 ——
/// **纯 SQLite 对全部 `cipher_*` PRAGMA 都返回成功**，所以"没有报错"
/// 是一个没有信息量的信号。把它钉在这里，是为了让后续任何一次
/// "顺手改成看错误码 / 看 libversion" 的改动在测试上立刻翻红。
library;

import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';
import 'package:test/test.dart';

/// 一个"加载成功"的观察：`loadError == null`。
EngineObservation _loaded({
  String? cipherVersion,
  String sqliteVersion = '3.49.1',
  String label = 'explicit',
  String path = 'D:/tmp/lib.dll',
}) => EngineObservation(
  libraryLabel: label,
  libraryPath: path,
  sqliteVersion: sqliteVersion,
  cipherVersion: cipherVersion,
);

void main() {
  group('判据一：库加载不出来 ⇒ unavailable', () {
    test('loadError 非空就是"没跑起来"，与库能不能执行 SQL 无关', () {
      const observation = EngineObservation(
        libraryLabel: 'explicit',
        libraryPath: 'D:/nowhere/nope.dll',
        loadError: 'Invalid argument(s): Failed to load dynamic library',
      );

      final verdict = judgeEngine(observation);

      expect(verdict.kind, EngineKind.unavailable);
      expect(verdict.isSqlCipher, isFalse);
      // 原始报错必须原样带进判定依据 —— 排查时要看的就是 dlopen 的那句话。
      expect(verdict.reason, contains('Failed to load dynamic library'));
      expect(observation.loaded, isFalse);
    });
  });

  group('判据二：能跑但没有身份串 ⇒ plainSqlite（本文件最重要的一组）', () {
    test('cipher_version 返回 0 行 ⇒ 判为纯 SQLite', () {
      // 这就是 `e_sqlite3.dll` / `winsqlite3.dll` 实测出来的形状：
      // loadError 为 null（key 与全部 cipher 参数都"成功"了），
      // 只是 cipher_version 一行都没有。
      final verdict = judgeEngine(_loaded(cipherVersion: ''));

      expect(verdict.kind, EngineKind.plainSqlite);
      expect(verdict.isSqlCipher, isFalse);
      // 判定依据必须点出"0 行"这件事，否则日志里看不出为什么被拦。
      expect(verdict.reason, contains('0 行'));
      // 也要带上它自报的 SQLite 版本 —— 报告里唯一的正向信息。
      expect(verdict.reason, contains('3.49.1'));
    });

    test('cipher_version 是 SQL NULL（null）与空串同义，同样是纯 SQLite', () {
      // 驱动把"没有行"读成 ''、把"有行但值是 NULL"读成 null，
      // 两条路都不得被判成 SQLCipher。
      expect(judgeEngine(_loaded(cipherVersion: null)).kind, EngineKind.plainSqlite);
      expect(judgeEngine(_loaded(cipherVersion: '')).kind, EngineKind.plainSqlite);
      expect(_loaded(cipherVersion: null).hasCipherVersion, isFalse);
      expect(_loaded(cipherVersion: '').hasCipherVersion, isFalse);
    });

    test('"全部 cipher_* PRAGMA 都没报错"这件事本身不构成证据', () {
      // 这一条是对上面两条的**反例断言**：纯 SQLite 的观察里
      // loadError 一定是 null —— 也就是说，
      // 「没报错」在这组事实与上一组事实之间没有任何区分力。
      // 判据若建在"有没有报错"上，会把这个纯 SQLite 放行。
      final plain = _loaded(cipherVersion: '');
      expect(plain.loaded, isTrue, reason: '纯 SQLite 确实"加载成功"—— 这正是危险所在');
      expect(judgeEngine(plain).isSqlCipher, isFalse);

      // 反过来：只有拿到身份串才是 SQLCipher。
      final cipher = _loaded(cipherVersion: '4.5.2 community');
      expect(cipher.loaded, isTrue);
      expect(judgeEngine(cipher).isSqlCipher, isTrue);
    });
  });

  group('判据三：有身份串 ⇒ sqlCipher', () {
    test('cipher_version 非空即判为 SQLCipher，依据里带版本串', () {
      final verdict = judgeEngine(_loaded(cipherVersion: '4.5.2 community'));

      expect(verdict.kind, EngineKind.sqlCipher);
      expect(verdict.isSqlCipher, isTrue);
      expect(verdict.reason, contains('4.5.2 community'));
      // sqliteVersion 不参与判定 —— SQLCipher 报的是它内嵌的 SQLite 版本。
      expect(verdict.reason, isNot(contains('3.49.1')));
    });
  });

  group('requireSqlCipher：把判定落成"必须拦住"', () {
    test('SQLCipher 直接放行', () {
      expect(
        () => requireSqlCipher(judgeEngine(_loaded(cipherVersion: '4.5.2 community'))),
        returnsNormally,
      );
    });

    test('纯 SQLite ⇒ PFD_E_ENGINE_NOT_CIPHER（拿错了库）', () {
      expect(
        () => requireSqlCipher(judgeEngine(_loaded(cipherVersion: ''))),
        throwsA(
          isA<StorageError>()
              .having((e) => e.code, 'code', PfErrorCode.storageEngineNotCipher)
              .having((e) => e.message, 'message', contains('0 行')),
        ),
      );
    });

    test('库加载不出来 ⇒ PFD_E_ENGINE_UNAVAILABLE（环境缺东西）', () {
      const observation = EngineObservation(
        libraryLabel: 'explicit',
        libraryPath: 'D:/nowhere/nope.dll',
        loadError: 'dlopen failed',
      );
      expect(
        () => requireSqlCipher(judgeEngine(observation)),
        throwsA(
          isA<StorageError>()
              .having((e) => e.code, 'code', PfErrorCode.storageEngineUnavailable)
              .having((e) => e.message, 'message', contains('dlopen failed')),
        ),
      );
    });

    test('两个错误码必须不同：处置方向不同（换库 vs 装库）', () {
      // 合并成一个码会让调用方只能靠字符串猜 —— 而这两条路的
      // 处置方向相反：一个是"你给的库不对"，一个是"这个环境没有库"。
      expect(PfErrorCode.storageEngineUnavailable, isNot(PfErrorCode.storageEngineNotCipher));
    });
  });
}

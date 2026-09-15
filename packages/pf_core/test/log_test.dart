import 'package:pf_core/pf_core.dart';
import 'package:test/test.dart';

String repeat(String unit, int count) => List<String>.filled(count, unit).join();

void main() {
  group('白名单是结构性的，不是事后过滤', () {
    test('未登记的字段名被拒绝', () {
      expect(
        () => const NullLogger().emit(
          PfLogLevel.info,
          'x',
          fields: const <String, Object>{'note': '午饭'},
        ),
        throwsA(isA<PfLogFieldRejected>()),
      );
    });

    test('金额 / 备注 / 商家 / 密钥类字段名不在白名单里', () {
      for (final forbidden in <String>[
        'amount',
        'note',
        'merchant',
        'memo',
        'password',
        'masterPassword',
        'dbKey',
        'salt',
        'nonce',
        'recoveryCode',
        'accountName',
      ]) {
        expect(
          pfAllowedLogFields.contains(forbidden),
          isFalse,
          reason: '"$forbidden" 绝不能出现在日志白名单里',
        );
      }
    });

    test('已登记的字段被接受', () {
      const NullLogger().emit(
        PfLogLevel.info,
        'import.merge.done',
        fields: const <String, Object>{'entityCount': 42, 'mode': 'merge', 'durationMs': 120},
      );
    });

    test('过长字符串被拒绝（疑似自由文本）', () {
      expect(
        () => const NullLogger().emit(
          PfLogLevel.info,
          'x',
          fields: <String, Object>{'mode': repeat('a', 100)},
        ),
        throwsA(isA<PfLogFieldRejected>()),
      );
    });

    test('刚好到上限的字符串被接受', () {
      const NullLogger().emit(PfLogLevel.info, 'x', fields: <String, Object>{'mode': 'm'});
    });

    test('含换行或控制字符的值被拒绝（防止日志注入）', () {
      for (final value in <String>['line1\nline2', 'a\tb', 'a\u0000b']) {
        expect(
          () => const NullLogger().emit(
            PfLogLevel.info,
            'x',
            fields: <String, Object>{'mode': value},
          ),
          throwsA(isA<PfLogFieldRejected>()),
          reason: '值 "$value" 应当被拒绝',
        );
      }
    });

    test('非标量值被拒绝', () {
      expect(
        () => const NullLogger().emit(
          PfLogLevel.info,
          'x',
          fields: const <String, Object>{
            'count': <int>[1, 2],
          },
        ),
        throwsA(isA<PfLogFieldRejected>()),
      );
      expect(
        () => const NullLogger().emit(
          PfLogLevel.info,
          'x',
          fields: const <String, Object>{'count': 1.5},
        ),
        throwsA(isA<PfLogFieldRejected>()),
      );
    });

    test('拒绝信息里包含字段名，便于定位违规调用点', () {
      try {
        const NullLogger().emit(PfLogLevel.info, 'x', fields: const <String, Object>{'note': 'x'});
        fail('应当抛出 PfLogFieldRejected');
      } on PfLogFieldRejected catch (error) {
        expect(error.field, 'note');
        expect(error.toString(), contains('note'));
      }
    });
  });

  group('NullLogger', () {
    test('丢弃输出但仍然校验', () {
      const logger = NullLogger();
      logger.emit(PfLogLevel.error, 'ok');
      expect(
        () => logger.emit(PfLogLevel.error, 'bad', fields: const <String, Object>{'nope': 1}),
        throwsA(isA<PfLogFieldRejected>()),
      );
    });
  });

  group('InMemoryLogger', () {
    test('记录已校验的条目', () {
      final logger = InMemoryLogger();
      logger.emit(PfLogLevel.warn, 'kdf.slow', fields: const <String, Object>{'durationMs': 800});

      expect(logger.records, hasLength(1));
      expect(logger.records.single.code, 'kdf.slow');
      expect(logger.records.single.level, PfLogLevel.warn);
      expect(logger.records.single.fields['durationMs'], 800);

      logger.clear();
      expect(logger.records, isEmpty);
    });

    test('记录中的字段映射不可变（防止事后篡改日志）', () {
      final logger = InMemoryLogger();
      logger.emit(PfLogLevel.info, 'x', fields: const <String, Object>{'count': 1});
      expect(() => logger.records.single.fields['count'] = 2, throwsUnsupportedError);
    });

    test('无字段调用也可用', () {
      final logger = InMemoryLogger();
      logger.emit(PfLogLevel.trace, 'x');
      expect(logger.records.single.fields, isEmpty);
    });
  });
}

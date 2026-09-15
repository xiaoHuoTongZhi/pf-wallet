/// 向量文件格式与语料自洽性测试。
///
/// 这些测试跑的是**真实的 test_vectors/v1/**，而不是内存构造的样本。
/// 因此它们同时也是「向量语料本身没有写错」的守门人 ——
/// 一条期望值写错的向量如果没人检查，会在实现改动时以「实现有 bug」的形式报警，
/// 把排查方向彻底带偏。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pf_testkit/pf_testkit.dart';
import 'package:test/test.dart';

void main() {
  late Directory repoRoot;
  late List<PfVectorSuite> suites;

  setUpAll(() {
    repoRoot = findRepoRoot();
    suites = loadVectorSuites(Directory(p.join(repoRoot.path, VectorSchema.vectorsDirectory)));
  });

  test('向量目录能被加载，且至少有一个套件', () {
    expect(suites, isNotEmpty);
    for (final suite in suites) {
      suite.validateUniqueIds();
      expect(suite.cases, isNotEmpty, reason: '套件 ${suite.suite} 没有用例');
    }
  });

  test('用例 ID 全局唯一', () {
    final seen = <String, String>{};
    for (final suite in suites) {
      for (final c in suite.cases) {
        final previous = seen[c.id];
        expect(previous, isNull, reason: '用例 ID "${c.id}" 在 $previous 与 ${suite.suite} 中重复');
        seen[c.id] = suite.suite;
      }
    }
  });

  test('用例 ID 命名符合 <领域>.<对象>.<行为> 约定', () {
    final pattern = RegExp(r'^[a-z][a-zA-Z0-9]*(\.[a-z][a-zA-Z0-9-]*)+$');
    for (final suite in suites) {
      for (final c in suite.cases) {
        expect(pattern.hasMatch(c.id), isTrue, reason: '用例 ID "${c.id}" 不符合命名约定');
      }
    }
  });

  test('所有 kind 都已在注册表中登记', () {
    final registry = buildDefaultRegistry();
    for (final suite in suites) {
      for (final c in suite.cases) {
        expect(
          registry.lookup(c.kind),
          isNotNull,
          reason:
              '用例 "${c.id}" 引用了未注册的 kind "${c.kind}"。'
              '未注册的 kind 在运行时会被记为 fail，因此必须在这里提前暴露。'
              '已注册：${registry.kinds.join(", ")}',
        );
      }
    }
  });

  test('每个「已实现」的驱动都至少有一条向量', () {
    final registry = buildDefaultRegistry();
    final used = <String>{
      for (final suite in suites)
        for (final c in suite.cases) c.kind,
    };

    final missing = <String>[
      for (final driver in registry.drivers)
        if (driver.isImplemented && !used.contains(driver.kind)) driver.kind,
    ];

    expect(
      missing,
      isEmpty,
      reason:
          '以下驱动声称已实现，却没有任何向量引用它：$missing。'
          '「已实现但没被向量锁定」等价于「改了不会被发现」。',
    );
  });

  test('带 security 标签的用例必须写明「不做会出什么事故」', () {
    for (final suite in suites) {
      for (final c in suite.cases) {
        if (!c.tags.contains('security')) continue;
        expect(c.notes, isNotNull, reason: '安全用例 "${c.id}" 缺少 notes');
        expect(
          (c.notes ?? '').length,
          greaterThanOrEqualTo(20),
          reason: '安全用例 "${c.id}" 的 notes 太短，无法说明风险',
        );
      }
    }
  });

  test('输入不得含随机或时钟依赖（通过字段名启发式检查）', () {
    // 这是启发式而非证明：真正的保证来自驱动自身不调用 DateTime.now() / Random()。
    // 但它能拦住最常见的手滑 —— 把 "now" 当成输入字段传进去。
    final forbidden = RegExp(r'(^|_)(now|random|seed|uuid|time)$');
    for (final suite in suites) {
      for (final c in suite.cases) {
        for (final key in _allKeys(c.input)) {
          expect(
            forbidden.hasMatch(key),
            isFalse,
            reason:
                '用例 "${c.id}" 的输入字段 "$key" 看起来依赖不确定源。'
                '所有不确定源都必须以显式、固定的值传入。',
          );
        }
      }
    }
  });

  test('基线文件中的用例 ID 都真实存在', () {
    final load = loadPendingBaseline(repoRoot);
    final allIds = <String>{
      for (final suite in suites)
        for (final c in suite.cases) c.id,
    };

    for (final id in load.baseline.entries) {
      expect(
        allIds,
        contains(id),
        reason:
            '基线中的 "$id" 不存在于任何向量文件。'
            '基线里残留已删除的 ID，会让「pending 只减不增」这条规则失去基准。',
      );
    }
  });

  group('格式的自我防御', () {
    test('成功形态的 value 为空对象时必须拒绝', () {
      expect(
        () => PfVectorSuite.fromJson(<String, Object?>{
          'schemaVersion': 1,
          'suite': 'demo',
          'title': 'demo',
          'cases': <Object?>[
            <String, Object?>{
              'id': 'demo.thing.run',
              'kind': 'container.format.constants',
              'title': '空期望',
              'milestone': 'M0',
              'input': <String, Object?>{},
              'expect': <String, Object?>{'ok': true, 'value': <String, Object?>{}},
            },
          ],
        }, 'inline'),
        throwsA(isA<VectorFormatException>()),
      );
    });

    test('不支持的 schemaVersion 必须拒绝', () {
      expect(
        () => PfVectorSuite.fromJson(<String, Object?>{
          'schemaVersion': 99,
          'suite': 'demo',
          'title': 'demo',
          'cases': <Object?>[
            <String, Object?>{
              'id': 'demo.thing.run',
              'kind': 'container.format.constants',
              'title': 'x',
              'milestone': 'M0',
              'input': <String, Object?>{},
              'expect': <String, Object?>{
                'ok': true,
                'value': <String, Object?>{'a': 1},
              },
            },
          ],
        }, 'inline'),
        throwsA(isA<VectorFormatException>()),
      );
    });

    test('非法里程碑标识必须拒绝', () {
      expect(
        () => MilestoneTag.parse('MILESTONE_0', 'inline'),
        throwsA(isA<VectorFormatException>()),
      );
      expect(MilestoneTag.parse('M12', 'inline').ordinal, 12);
    });

    test('非法十六进制必须拒绝（奇数长度）', () {
      expect(() => parseHex('abc', 'inline'), throwsA(isA<VectorFormatException>()));
    });

    test('非法十六进制必须拒绝（非十六进制字符）', () {
      expect(() => parseHex('zz', 'inline'), throwsA(isA<VectorFormatException>()));
    });
  });
}

Iterable<String> _allKeys(Object? value) sync* {
  if (value is Map<String, Object?>) {
    for (final entry in value.entries) {
      yield entry.key;
      yield* _allKeys(entry.value);
    }
  } else if (value is List<Object?>) {
    for (final item in value) {
      yield* _allKeys(item);
    }
  }
}

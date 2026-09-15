/// 让 `melos run test` 直接覆盖「签入向量与当前实现一致」这件事。
///
/// 关卡 3 已经做了同样的事，这里再做一遍不是冗余：
///   - 开发者在本地跑 `melos run test` 时就该发现向量飘了，
///     而不是推上去等 CI 告诉他一分钟前就能知道的事
///   - 关卡 3 的失败信息在 CI 日志里，这一条的失败信息在他自己的终端里
///
/// 代价是同一批断言跑两遍 —— 近百条纯计算用例，几毫秒。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pf_testkit/pf_testkit.dart';
import 'package:test/test.dart';

void main() {
  test('签入的全部黄金向量与当前实现一致，且无未登记的 kind', () async {
    final repoRoot = findRepoRoot();
    final suites = loadVectorSuites(
      Directory(p.join(repoRoot.path, VectorSchema.vectorsDirectory)),
    );

    final run = await VectorRunner(registry: buildDefaultRegistry()).run(suites);
    final report = run.report;

    expect(
      report.failures,
      isEmpty,
      reason: report.failures
          .map((VectorCaseResult f) => '${f.caseId} [${f.kind}]\n  ${f.title}\n  ${f.message}')
          .join('\n\n'),
    );

    expect(run.warnings, isEmpty, reason: run.warnings.join('\n'));

    // 「签入的向量 = 全部通过」而不是「通过数 > 某个魔数」：
    // 期望值从向量语料本身算出来，因此加一条向量不用改测试，
    // 删一条向量也不会被魔数放过。
    final declared = suites.fold<int>(0, (int sum, PfVectorSuite s) => sum + s.cases.length);
    expect(
      report.passed,
      declared,
      reason: '共载入 $declared 条向量，通过 ${report.passed} 条、失败 ${report.failures.length} 条',
    );

    // 下界守卫：拦「向量被成批误删」。删向量不会让任何东西变红，
    // 只会让覆盖悄悄变薄，因此这里钉一个只增不减的地板。
    // 有意缩减向量集时，必须连这个数字一起改 —— 那正是希望被看见的动作。
    expect(declared, greaterThanOrEqualTo(90), reason: '向量语料只剩 $declared 条，疑似被误删');

    // pending 必须与基线一致：新增 pending = 实现倒退，
    // 消除 pending 后未更新基线 = 基线过期。两者都算失败。
    final delta = loadPendingBaseline(repoRoot).baseline.diff(report.pendingCaseIds);
    expect(delta.isClean, isTrue, reason: delta.describe());
  });
}

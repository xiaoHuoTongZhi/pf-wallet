/// `import_merge.dart` 的单元测试（§4.4）。
///
/// ## 与向量测试的分工
///
/// `import.merge.record` / `import.merge.plan` / `import.merge.converge` 三套向量
/// 已经逐条锁死了**期望值**。这里测的是向量不方便覆盖的那一半：
///
///   - **坏输入**：本地行缺 `device_id`、`updated_at` 为 0 —— 向量里的输入都是
///     良构的，而真实库里这些情况会出现。它们该报什么错、该不该报错，只有这里能钉。
///   - **语句文本**：向量把 SQL 当不透明字符串比对，这里读它，确认「值一律走 `?`」
///     这条（§4.3 的「100% 参数化」）不是一句口号。
///   - **派生关系**：冲突主键必须**只**由 (job, 实体, id, 种类) 决定；改动其中
///     任何一项都必须改变主键。向量只钉住了一个具体值，钉不住这条关系。
library;

import 'package:pf_core/pf_core.dart';
import 'package:pf_io/pf_io.dart';
import 'package:test/test.dart';
// ─────────────────────────── 夹具 ───────────────────────────

/// 固定的合法 ULID（由生成器派生后写死：断言里要能一眼看清是哪一个）。
const String _devA = '01M2HTD6R0WVJSAWGVG1WNVWS0';
const String _devB = '01M2HTD6R0AQMKKA06S2Y3ST74';
const String _acctA = '01M2HTD6R0Q8VA9VES5MVWCVAE';
const String _acctB = '01M2HTD6R0W6AQD0KTMGJSST7J';
const String _led1 = '01M2HTD6R0A6JA10DA0X6K195N';

const int _t0 = 1789452000000;

/// 宽限窗口的两种越界方式。写成与常量同源而不是硬编码数字：
/// 窗口值一改，这两条测试的语义（「窗口内」/「窗口外」）必须跟着一起动。
const int _outsideSkew = kSkewConflictWindowMs * 10;
const int _insideSkew = kSkewConflictWindowMs ~/ 2;

const String _job = '01J8TESTJOB000000000000001';

Map<String, Object?> _accountColumns(String name) => <String, Object?>{
  'ledger_id': _led1,
  'name': name,
  'type': 1,
  'currency': 'CNY',
  'opening_balance_minor': 0,
  'is_archived': 0,
};

/// 造一条「文件里那一行」。
///
/// 列集合刻意对齐解码器的实际产出：**每个类型都以 `…_common` 收尾**，
/// 因此 `deleted_at` 这一列**总是存在**（活记录是 null，不是「没有这个键」）。
/// 这一点不是细节 —— `ImportRecord.matchesLocal` 比的是 `columns` 的键集，
/// 少一个 `deleted_at` 就会让「一边删除、一边编辑」被判成「内容相同」。
/// 夹具必须比实现更苛刻，不能比它更宽松。
ImportRecord _remote({
  String type = 'account',
  required String id,
  required Map<String, Object?> columns,
  int updatedAt = _t0,
  String deviceId = _devA,
  int? deletedAt,
  int recordIndex = 0,
}) {
  final cols = <String, Object?>{
    'id': id,
    ...columns,
    'updated_at': updatedAt,
    'deleted_at': deletedAt,
    'device_id': deviceId,
  };
  return ImportRecord(
    type: type,
    table: kPayloadRecordSpecs[type]!.table,
    id: id,
    columns: cols,
    updatedAt: updatedAt,
    deviceId: deviceId,
    isTombstone: deletedAt != null,
    recordIndex: recordIndex,
  );
}

/// 造一条「库里那一行」。`deviceId` 传 null 表示那一行缺 `device_id` 列。
Map<String, Object?> _local({
  required String id,
  required Map<String, Object?> columns,
  int updatedAt = _t0,
  String? deviceId = _devB,
  int? deletedAt,
}) => <String, Object?>{
  'id': id,
  ...columns,
  'updated_at': updatedAt,
  'deleted_at': deletedAt,
  'rev': 1,
  if (deviceId != null) 'device_id': deviceId,
};

MergeRecordDecision _decide(
  ImportRecord remote, {
  Map<String, Object?>? local,
  ImportMode mode = ImportMode.merge,
  ConflictStrategy strategy = ConflictStrategy.converge,
  DeleteEditPolicy deleteEdit = DeleteEditPolicy.deleteWinsBySkew,
}) => mergeRecord(
  remote: remote,
  local: local,
  mode: mode,
  strategy: strategy,
  deleteEdit: deleteEdit,
);

void main() {
  group('模式表：仅补充 / 覆盖在版本比较之前就定完', () {
    test('仅补充模式：本地不存在 → insert，依据是 fillOnlyNew', () {
      final remote = _remote(id: _acctA, columns: _accountColumns('现金'));
      final decision = _decide(remote, mode: ImportMode.supplementOnly);

      expect(decision.outcome, MergeOutcome.insert);
      expect(decision.rule, MergeRule.fillOnlyNew);
      expect(decision.side, MergeSide.remote);
      expect(decision.write!.replace, isFalse);
      expect(decision.needsUserReview, isFalse);
    });

    test('仅补充模式：本地已存在（含墓碑）→ skip，且一条语句都不发', () {
      final remote = _remote(id: _acctA, columns: _accountColumns('现金'));
      final live = _local(id: _acctA, columns: _accountColumns('现金'));

      final kept = _decide(remote, local: live, mode: ImportMode.supplementOnly);
      expect(kept.outcome, MergeOutcome.skip);
      expect(kept.rule, MergeRule.fillOnlyExisting);
      expect(kept.side, MergeSide.local);
      expect(kept.write, isNull, reason: '「绝不修改已有记录」要落到「不发任何语句」上');

      // 墓碑同样不动：仅补充模式连「复活」都不做。
      final tombstoned = _local(id: _acctA, columns: _accountColumns('现金'), deletedAt: _t0);
      expect(
        _decide(remote, local: tombstoned, mode: ImportMode.supplementOnly).outcome,
        MergeOutcome.skip,
      );
    });

    test('覆盖模式：文件为准 —— 本地不存在 → insert，文件是墓碑 → markDeleted', () {
      final fresh = _decide(
        _remote(id: _acctA, columns: _accountColumns('现金')),
        mode: ImportMode.replace,
      );
      expect(fresh.outcome, MergeOutcome.insert);
      expect(fresh.rule, MergeRule.overwriteByFile);

      final removed = _decide(
        _remote(id: _acctA, columns: _accountColumns('现金'), deletedAt: _t0),
        local: _local(id: _acctA, columns: _accountColumns('现金')),
        mode: ImportMode.replace,
      );
      expect(removed.outcome, MergeOutcome.markDeleted);
      expect(removed.rule, MergeRule.overwriteTombstone);
      expect(removed.write!.replace, isTrue);
    });
  });

  group('本地缺失的两种落点', () {
    test('正文 → insert（localMissing）；墓碑 → insertTombstone（防复活）', () {
      final insert = _decide(_remote(id: _acctA, columns: _accountColumns('现金')));
      expect(insert.outcome, MergeOutcome.insert);
      expect(insert.rule, MergeRule.localMissing);

      final tombstone = _decide(
        _remote(id: _acctA, columns: _accountColumns('现金'), deletedAt: _t0),
      );
      expect(tombstone.outcome, MergeOutcome.insertTombstone);
      expect(tombstone.rule, MergeRule.localMissingTombstone);
    });
  });
  group('abort 策略：提交 A 的行为一字不改', () {
    test('同内容 → skip（identicalContent），不产生待复核', () {
      final decision = _decide(
        _remote(id: _acctA, columns: _accountColumns('现金')),
        local: _local(id: _acctA, columns: _accountColumns('现金')),
        strategy: ConflictStrategy.abort,
      );

      expect(decision.outcome, MergeOutcome.skip);
      expect(decision.rule, MergeRule.identicalContent);
      expect(decision.needsUserReview, isFalse);
      expect(decision.conflictKind, isNull);
    });

    test('有分歧 → conflict（abortOnDivergence），不写语句但两侧版本齐备', () {
      final decision = _decide(
        _remote(id: _acctA, columns: _accountColumns('现金')),
        local: _local(id: _acctA, columns: _accountColumns('招行卡')),
        strategy: ConflictStrategy.abort,
      );

      expect(decision.outcome, MergeOutcome.conflict);
      expect(decision.rule, MergeRule.abortOnDivergence);
      expect(decision.conflictKind, ConflictKind.content);
      expect(decision.write, isNull, reason: 'abort 的含义就是「不动本地已有的行」');
      // 冲突登记要写 local_json / remote_json，因此两个版本都必须算出来 ——
      // 即使这个分支不做任何大小比较。
      expect(decision.localVersion, isNotNull);
      expect(decision.remoteVersion, isNotNull);
      expect(decision.localVersion!.deviceId, _devB);
      expect(decision.remoteVersion!.deviceId, _devA);
    });

    test('一边删除一边编辑 → 冲突种类是 deleteVsEdit', () {
      // 内容一字不差、只有删除状态不同 —— 这正是 abort 必须**看见**的那种分歧。
      // 夹具里 `deleted_at: null` 是「活记录的列值是 null」而不是「没有这一列」，
      // 与解码器的实际产出一致；少了它，这一条会被判成 identicalContent 而跳过。
      final decision = _decide(
        _remote(id: _acctA, columns: _accountColumns('现金')),
        local: _local(id: _acctA, columns: _accountColumns('现金'), deletedAt: _t0),
        strategy: ConflictStrategy.abort,
      );

      expect(decision.outcome, MergeOutcome.conflict);
      expect(decision.conflictKind, ConflictKind.deleteVsEdit);
    });

    test('本地行缺 device_id → 仍然报冲突，而不是升级成 incompatible', () {
      // 这一条守的是**报错方向**：缺版本元数据的坏行，不该让用户看到
      // 「这份备份与当前账本无法合并」，而该看到「有 1 处冲突要确认」。
      // abort 分支不需要比大小，因此它没有理由抛错 —— 抛了就是把
      // 「停下、不猜」错报成「数据不兼容」。
      final decision = _decide(
        _remote(id: _acctA, columns: _accountColumns('现金')),
        local: _local(id: _acctA, columns: _accountColumns('招行卡'), deviceId: null),
        strategy: ConflictStrategy.abort,
      );

      expect(decision.outcome, MergeOutcome.conflict);
      expect(decision.localVersion, isNull, reason: '算不出来就给 null，不要编一个');
      expect(decision.remoteVersion, isNotNull);
    });
  });

  group('幂等与宽限窗口', () {
    test('同内容而元数据不同 → skip（幂等就落在这里）', () {
      // 两台设备把同一个字段改成同样的值：版本戳必然不同，业务上却没有分歧。
      // 若先比版本戳，远端较大就会产生一次 update —— 「同一份备份导入两次
      // 结果不变」当场失效。
      final decision = _decide(
        _remote(id: _acctA, columns: _accountColumns('现金'), updatedAt: _t0 + _outsideSkew),
        local: _local(id: _acctA, columns: _accountColumns('现金'), updatedAt: _t0),
      );

      expect(decision.outcome, MergeOutcome.skip);
      expect(decision.rule, MergeRule.identicalContent);
      expect(decision.write, isNull);
    });

    test('远端严格更新且超出宽限窗口 → update（remoteNewer）', () {
      final decision = _decide(
        _remote(id: _acctA, columns: _accountColumns('招行卡'), updatedAt: _t0 + _outsideSkew),
        local: _local(id: _acctA, columns: _accountColumns('现金'), updatedAt: _t0),
      );

      expect(decision.outcome, MergeOutcome.update);
      expect(decision.rule, MergeRule.remoteNewer);
      expect(decision.side, MergeSide.remote);
      expect(decision.write!.replace, isTrue);
      expect(decision.conflictKind, isNull, reason: '窗口之外的 LWW 是确定性的，不该打扰用户');
    });

    test('本地严格更新且超出宽限窗口 → skip（localNewer）', () {
      final decision = _decide(
        _remote(id: _acctA, columns: _accountColumns('招行卡'), updatedAt: _t0),
        local: _local(id: _acctA, columns: _accountColumns('现金'), updatedAt: _t0 + _outsideSkew),
      );

      expect(decision.outcome, MergeOutcome.skip);
      expect(decision.rule, MergeRule.localNewer);
      expect(decision.side, MergeSide.local);
      expect(decision.write, isNull);
    });

    test('时间差落在宽限窗口内 → conflict（ambiguousWindow），但取值仍然确定', () {
      // 「转人工」不等于「这次先不写」：取值照样按版本戳选定。
      // 否则同一批记录换个顺序导入就会得到不同结果（可交换性当场失效）。
      final decision = _decide(
        _remote(id: _acctA, columns: _accountColumns('招行卡'), updatedAt: _t0 + _insideSkew),
        local: _local(id: _acctA, columns: _accountColumns('现金'), updatedAt: _t0),
      );

      expect(decision.outcome, MergeOutcome.conflict);
      expect(decision.rule, MergeRule.ambiguousWindow);
      expect(decision.conflictKind, ConflictKind.content);
      expect(decision.side, MergeSide.remote);
      expect(decision.write, isNotNull, reason: '取值照写，只是另外记一条待复核');
      expect(decision.needsUserReview, isTrue);
    });

    test('版本戳相同而内容不同 → conflict（stampCollision）', () {
      // 同设备同毫秒却内容不同：正常流程不可能产生（同一次写入只有一个内容）。
      // 出现即说明版本戳生成被破坏或数据被外部改过 —— 必须留证据，不能悄悄选一个。
      final decision = _decide(
        _remote(id: _acctA, columns: _accountColumns('招行卡'), updatedAt: _t0, deviceId: _devB),
        local: _local(id: _acctA, columns: _accountColumns('现金'), updatedAt: _t0, deviceId: _devB),
      );

      expect(decision.outcome, MergeOutcome.conflict);
      expect(decision.rule, MergeRule.stampCollision);
      expect(decision.conflictKind, ConflictKind.content);
    });
  });

  group('删除 / 编辑分歧', () {
    test('默认策略：编辑晚于墓碑 → conflict，绝不静默复活', () {
      final decision = _decide(
        _remote(id: _acctA, columns: _accountColumns('招行卡'), updatedAt: _t0 + _outsideSkew),
        local: _local(id: _acctA, columns: _accountColumns('现金'), updatedAt: _t0, deletedAt: _t0),
      );

      expect(decision.outcome, MergeOutcome.conflict);
      expect(decision.rule, MergeRule.deleteVsEdit);
      expect(decision.conflictKind, ConflictKind.deleteVsEdit);
      expect(decision.write, isNotNull, reason: '编辑胜出 ⇒ 取值是编辑那一份');
    });

    test('默认策略：远端墓碑 + 本地编辑更晚 → conflict，且这一侧不写', () {
      final decision = _decide(
        _remote(id: _acctA, columns: _accountColumns('现金'), updatedAt: _t0, deletedAt: _t0),
        local: _local(id: _acctA, columns: _accountColumns('招行卡'), updatedAt: _t0 + _outsideSkew),
      );

      expect(decision.outcome, MergeOutcome.conflict);
      expect(decision.rule, MergeRule.deleteVsEdit);
      expect(decision.side, MergeSide.local);
      expect(decision.write, isNull, reason: '本地胜出 ⇒ 一个字都不用改');
    });

    test('纯 LWW 策略（edit_wins_by_lww）：编辑晚于墓碑 → resurrect，且不打扰用户', () {
      final decision = _decide(
        _remote(id: _acctA, columns: _accountColumns('招行卡'), updatedAt: _t0 + _outsideSkew),
        local: _local(id: _acctA, columns: _accountColumns('现金'), updatedAt: _t0, deletedAt: _t0),
        deleteEdit: DeleteEditPolicy.editWinsByLww,
      );

      expect(decision.outcome, MergeOutcome.resurrect);
      expect(decision.rule, MergeRule.deleteVsEditLww);
      expect(decision.needsUserReview, isFalse);
      expect(decision.conflictKind, isNull);
    });

    test('编辑不晚于墓碑 → tombstoneWins（远端墓碑落成 markDeleted）', () {
      final decision = _decide(
        _remote(
          id: _acctA,
          columns: _accountColumns('现金'),
          updatedAt: _t0 + _outsideSkew,
          deletedAt: _t0 + _outsideSkew,
        ),
        local: _local(id: _acctA, columns: _accountColumns('招行卡'), updatedAt: _t0),
      );

      expect(decision.outcome, MergeOutcome.markDeleted);
      expect(decision.rule, MergeRule.tombstoneWins);
      expect(decision.write!.replace, isTrue);
      expect(decision.needsUserReview, isFalse, reason: '迟到的编辑被墓碑挡住是规则，不是分歧');
    });

    test('双方都是墓碑且内容不同 → skip（bothDeleted），不打扰用户', () {
      const localDeletedAt = _t0;
      const remoteDeletedAt = _t0 + _outsideSkew;
      final decision = _decide(
        _remote(
          id: _acctA,
          columns: <String, Object?>{..._accountColumns('现金'), 'note': '先删的那一台'},
          updatedAt: remoteDeletedAt,
          deletedAt: remoteDeletedAt,
        ),
        local: _local(
          id: _acctA,
          columns: <String, Object?>{..._accountColumns('现金'), 'note': '另一台'},
          updatedAt: _t0,
          deletedAt: localDeletedAt,
        ),
      );

      expect(decision.outcome, MergeOutcome.skip);
      expect(decision.rule, MergeRule.bothDeleted);
      expect(decision.write, isNull);
    });
  });

  group('MergeWrite：语句文本与「值一律走占位符」', () {
    test('INSERT 与 UPDATE 的列序、占位符数量、参数顺序逐一对应', () {
      final insert = MergeWrite(
        table: 'account',
        id: _acctA,
        columns: <String, Object?>{'id': _acctA, 'name': '现金', 'is_archived': 0},
        replace: false,
      );
      expect(insert.sql, 'INSERT INTO account (id, name, is_archived) VALUES (?, ?, ?)');
      expect(insert.arguments, <Object?>[_acctA, '现金', 0]);

      final update = MergeWrite(
        table: 'account',
        id: _acctA,
        columns: <String, Object?>{'id': _acctA, 'name': '招行卡', 'is_archived': 0},
        replace: true,
      );
      expect(update.sql, 'UPDATE account SET id = ?, name = ?, is_archived = ? WHERE id = ?');
      // 主键放在参数末位 —— 与 SQL 里 `WHERE id = ?` 的位置一致。
      expect(update.arguments, <Object?>[_acctA, '招行卡', 0, _acctA]);

      // 值不许出现在语句文本里：这是「100% 参数化」这条门禁在单元层的对照。
      for (final write in <MergeWrite>[insert, update]) {
        expect(write.sql.contains('现金'), isFalse);
        expect(write.sql.contains('招行卡'), isFalse);
        final placeholders = RegExp(r'\?').allMatches(write.sql).length;
        expect(placeholders, write.arguments.length);
      }
    });
  });

  group('ImportMergePlanner', () {
    test('abort 策略下不登记冲突行，但冲突计数仍然算出来', () {
      final plan = ImportMergePlanner.plan(
        MergePlanRequest(
          records: <ImportRecord>[_remote(id: _acctA, columns: _accountColumns('现金'))],
          localRows: <String, List<Map<String, Object?>>>{
            'account': <Map<String, Object?>>[_local(id: _acctA, columns: _accountColumns('招行卡'))],
          },
          mode: ImportMode.merge,
          strategy: ConflictStrategy.abort,
          jobId: _job,
          nowMilliseconds: _t0,
          localDeviceId: _devB,
        ),
      );

      // 冲突计数是执行器算 `PFI_E_CONFLICT` 条数的依据，必须留着；
      // 而冲突**行**不能落库 —— 那条 conflict.job_id 会指向一个 failed 的 job，
      // 用户在冲突面板里永远处理不掉它。
      expect(plan.countOf(MergeOutcome.conflict), 1);
      expect(plan.conflicts, isEmpty);
      expect(plan.conflictWrites, isEmpty);
      expect(plan.writes, isEmpty);
    });

    test('阶段序：父表先于子表，占位实体先于引用它的记录', () {
      final plan = ImportMergePlanner.plan(
        MergePlanRequest(
          records: <ImportRecord>[
            _remote(
              type: 'txn',
              id: '01M2HTD6R0TAJM5PHJJR0038YF',
              columns: <String, Object?>{
                'ledger_id': _led1,
                'type': 1,
                'amount_minor': 12345,
                'currency': 'CNY',
                'occurred_at': _t0,
                // 指向一个文件里没有、本地也没有的账户 ⇒ 修出占位账户。
                'account_id': _acctB,
                'note': null,
              },
            ),
            _remote(id: _acctA, columns: _accountColumns('现金'), recordIndex: 1),
          ],
          localRows: const <String, List<Map<String, Object?>>>{},
          mode: ImportMode.merge,
          strategy: ConflictStrategy.converge,
          jobId: _job,
          nowMilliseconds: _t0,
          localDeviceId: _devB,
        ),
      );

      final tables = <String>[for (final write in plan.writes) write.table];
      expect(tables, <String>['account', 'account', 'txn']);
      expect(plan.placeholderWrites.single.id, _acctB);
      expect(plan.recordWrites.map((MergeWrite w) => w.id), <String>[
        _acctA,
        '01M2HTD6R0TAJM5PHJJR0038YF',
      ]);
      expect(plan.referenceFixes.single.reason, 'missing');
    });

    test('覆盖模式：没有目标账本 ⇒ 一条也不软删（失败方向指向「少删」）', () {
      final localRows = <String, List<Map<String, Object?>>>{
        'txn': <Map<String, Object?>>[
          <String, Object?>{
            'id': '01M2HTD6R0TAJM5PHJJR0038YF',
            'ledger_id': _led1,
            'deleted_at': null,
            'rev': 1,
            'device_id': _devB,
            'updated_at': _t0,
          },
        ],
      };
      MergePlan planWith(String? target) => ImportMergePlanner.plan(
        MergePlanRequest(
          records: <ImportRecord>[_remote(id: _acctA, columns: _accountColumns('现金'))],
          localRows: localRows,
          mode: ImportMode.replace,
          strategy: ConflictStrategy.converge,
          jobId: _job,
          nowMilliseconds: _t0,
          localDeviceId: _devB,
          targetLedgerId: target,
        ),
      );

      final unScoped = planWith(null);
      expect(unScoped.removedCandidates, isEmpty);
      expect(unScoped.removalWrites, isEmpty);
      expect(unScoped.requiresCountConfirmation, isFalse);

      final scoped = planWith(_led1);
      expect(scoped.removedCandidates, <String>['01M2HTD6R0TAJM5PHJJR0038YF']);
      expect(scoped.requiresCountConfirmation, isTrue, reason: '条数确认是软删前的唯一护栏');
      final removal = scoped.removalWrites.single;
      expect(removal.replace, isTrue);
      expect(removal.columns['deleted_at'], _t0);
      expect(removal.columns['rev'], 2, reason: '本地 rev 加一，用来让合并端认出这是一次新写入');
      expect(removal.columns['device_id'], _devB);
    });

    test('冲突主键只由 (job, 实体, id, 种类) 决定 —— 换任何一项都必须换主键', () {
      String idFor({
        String job = _job,
        String entity = 'account',
        String entityId = _acctA,
        ConflictKind kind = ConflictKind.content,
      }) => ImportMergePlanner.conflictIdOf(
        jobId: job,
        entity: entity,
        entityId: entityId,
        kind: kind,
        nowMilliseconds: _t0,
      );

      final base = idFor();
      expect(Ulid.isValid(base), isTrue);
      // 同输入必须同结果：否则同一次导入里同一处分歧可能被记两次。
      expect(idFor(), base);
      expect(idFor(kind: ConflictKind.content), base);

      expect(idFor(entity: 'txn'), isNot(base));
      expect(idFor(entityId: _acctB), isNot(base));
      expect(idFor(kind: ConflictKind.deleteVsEdit), isNot(base));
      expect(idFor(job: '01J8TESTJOB000000000000002'), isNot(base));
    });
  });
}

/// `import_reference_fix.dart` 的单元测试（§4.4 S11–S14）。
///
/// `import.merge.reference` 向量逐字锁住了八组场景的输出。这里补的是向量之外
/// 那几件「性质」：
///
///   - **记录不许丢**：归一化后的记录必须按原行序、原条数归还。修复器一旦漏还
///     某类记录，表现是「导入之后少了几个分类」—— 用户要过很久才发现。
///   - **`ledger_id` 不造占位**：它不在修复表里，而这条边界是「悬空的 ledger_id
///     仍然整体回滚」的前提。
///   - **占位实体的必要性**：名字必须带 id 后缀（`ux_category_name` 是唯一索引）、
///     必须归档/隐藏（不该出现在记账界面里）。这些是「一次修复把导入炸掉」的防线。
library;

import 'package:pf_io/pf_io.dart';
import 'package:test/test.dart';

const String _devLocal = '01M2HTD6R0WVJSAWGVG1WNVWS0';
const String _devFile = '01M2HTD6R0AQMKKA06S2Y3ST74';
const String _led1 = '01M2HTD6R0A6JA10DA0X6K195N';
const String _acctA = '01M2HTD6R0Q8VA9VES5MVWCVAE';
const String _acctMissing = '01M2HTD6R0W6AQD0KTMGJSST7J';
const String _catA = '01M2HTD6R0VSY6T68H17T2Q03Z';
const String _catB = '01M2HTD6R0RJX4PGJ8DTWM3J2V';
const String _catMissing = '01M2HTD6R0W6QVYZT6HTS637VF';
const String _txnA = '01M2HTD6R0TAJM5PHJJR0038YF';
const String _txnB = '01M2HTD6R0JGVXNESKTBQM7QT3';
const String _ledMissing = '01M2HTD6R0B89J1PCN8VX7NWMG';

const int _t0 = 1789452000000;

ImportRecord _rec({
  required String type,
  required String id,
  required Map<String, Object?> columns,
  int? deletedAt,
  int recordIndex = 0,
}) {
  final cols = <String, Object?>{
    'id': id,
    ...columns,
    'deleted_at': deletedAt,
    'updated_at': _t0,
    'device_id': _devFile,
  };
  return ImportRecord(
    type: type,
    table: kPayloadRecordSpecs[type]!.table,
    id: id,
    columns: cols,
    updatedAt: _t0,
    deviceId: _devFile,
    isTombstone: deletedAt != null,
    recordIndex: recordIndex,
  );
}

Map<String, Object?> _category(String name, {String? parent}) => <String, Object?>{
  'ledger_id': _led1,
  'parent_id': parent,
  'kind': 1,
  'name': name,
  'icon': null,
  'color': null,
  'is_system': 0,
  'is_hidden': 0,
  'sort_order': 0,
};

Map<String, Object?> _txn({String? account, String? toAccount, String? category, int type = 1}) =>
    <String, Object?>{
      'ledger_id': _led1,
      'type': type,
      'amount_minor': 12345,
      'currency': 'CNY',
      'occurred_at': _t0,
      'account_id': account,
      'to_account_id': toAccount,
      'category_id': category,
      'note': null,
    };

/// 库里的一行（只带修复器会读的列）。
Map<String, Object?> _localRow(String id, {int? deletedAt, String? parentId}) => <String, Object?>{
  'id': id,
  'ledger_id': _led1,
  'parent_id': parentId,
  'kind': 1,
  'name': '本地分类',
  'deleted_at': deletedAt,
  'updated_at': _t0,
  'device_id': _devLocal,
  'rev': 1,
};

ReferenceFixResult _fix(
  List<ImportRecord> records, {
  Map<String, List<Map<String, Object?>>> localRows = const <String, List<Map<String, Object?>>>{},
}) => ImportReferenceFixer.apply(
  records: records,
  localRows: localRows,
  placeholderDeviceId: _devLocal,
  placeholderAtMilliseconds: _t0,
);

void main() {
  group('S11 / S12：缺失父实体 → 造占位实体', () {
    test('S11 交易引用本机没有的账户 → 占位账户保留被引用的 id，且已归档', () {
      final result = _fix(<ImportRecord>[
        _rec(type: 'txn', id: _txnA, columns: _txn(account: _acctMissing, category: _catA)),
        _rec(type: 'category', id: _catA, columns: _category('餐饮'), recordIndex: 1),
      ]);

      final placeholder = result.placeholders.single;
      expect(placeholder.table, 'account');
      expect(placeholder.id, _acctMissing, reason: '占位必须保留被引用的 id，否则交易仍指向虚空');
      expect(placeholder.columns['is_archived'], 1, reason: '占位账户不该出现在记账时的账户列表里');
      expect(placeholder.columns['name'], ImportReferenceFixer.placeholderAccountName);
      expect(placeholder.columns['opening_balance_minor'], 0);
      expect(placeholder.columns['created_at'], _t0);
      expect(placeholder.columns['rev'], 1);
      expect(placeholder.isTombstone, isFalse);

      final fix = result.fixes.single;
      expect(fix.kind, ReferenceFixKind.placeholderAccount);
      expect(fix.reason, 'missing');
      expect(fix.column, 'account_id');
      expect(fix.entity, 'txn');
      expect(fix.recordId, _txnA);
      expect(fix.referencedId, _acctMissing);
    });

    test('S12 引用本机没有的分类 → 占位分类名字带 id 后缀，且已隐藏', () {
      final result = _fix(
        <ImportRecord>[
          _rec(type: 'txn', id: _txnA, columns: _txn(account: _acctA, category: _catMissing)),
        ],
        localRows: <String, List<Map<String, Object?>>>{
          'account': <Map<String, Object?>>[_localRow(_acctA)],
        },
      );

      final placeholder = result.placeholders.single;
      expect(placeholder.table, 'category');
      expect(placeholder.id, _catMissing);
      expect(placeholder.columns['is_hidden'], 1, reason: '占位分类不该出现在记账时的分类选择器里');
      expect(placeholder.columns['parent_id'], isNull);
      expect(
        placeholder.columns['name'],
        ImportReferenceFixer.placeholderCategoryName(_catMissing),
      );
      // 名字必须**逐 id 唯一**：`ux_category_name` 是 (ledger,kind,parent,name) 上的
      // 唯一索引，两个占位分类同名就是一次 UNIQUE 冲突 —— 一次「修复」把导入炸掉。
      expect(
        ImportReferenceFixer.placeholderCategoryName(_catMissing),
        isNot(ImportReferenceFixer.placeholderCategoryName(_catB)),
      );
    });

    test('两个引用者指向同一个缺失账户 ⇒ 只造一个占位（putIfAbsent）', () {
      final result = _fix(<ImportRecord>[
        _rec(type: 'txn', id: _txnA, columns: _txn(account: _acctMissing, category: _catA)),
        _rec(type: 'txn', id: _txnB, columns: _txn(account: _acctMissing, category: _catA)),
        _rec(type: 'category', id: _catA, columns: _category('餐饮'), recordIndex: 2),
      ]);

      expect(result.placeholders.length, 1, reason: '同一个 id 造两次是主键冲突');
      expect(result.fixes.length, 2, reason: '两处引用都要各自报告，用户才知道影响面');
    });

    test('占位分类的 kind 由引用方的交易方向推出（收入交易 ⇒ 收入分类）', () {
      final localRows = <String, List<Map<String, Object?>>>{
        'account': <Map<String, Object?>>[_localRow(_acctA)],
      };

      final expense = _fix(<ImportRecord>[
        _rec(
          type: 'txn',
          id: _txnA,
          columns: _txn(account: _acctA, category: _catMissing, type: 1),
        ),
      ], localRows: localRows);
      expect(expense.placeholders.single.columns['kind'], 1);

      final income = _fix(<ImportRecord>[
        _rec(
          type: 'txn',
          id: _txnA,
          columns: _txn(account: _acctA, category: _catMissing, type: 2),
        ),
      ], localRows: localRows);
      expect(income.placeholders.single.columns['kind'], 2);
    });
  });

  group('S13 / S14：只报告、升级为一级', () {
    test('S13 同名同父同类型的本地活分类 → 两个并存，只报告', () {
      final result = _fix(
        <ImportRecord>[_rec(type: 'category', id: _catB, columns: _category('餐饮', parent: _catA))],
        localRows: <String, List<Map<String, Object?>>>{
          'category': <Map<String, Object?>>[
            <String, Object?>{..._localRow(_catMissing, parentId: _catA), 'name': '餐饮'},
            _localRow(_catA),
          ],
        },
      );

      expect(result.placeholders, isEmpty, reason: '同名不等于同一条：绝不能替用户合并');
      final fix = result.fixes.single;
      expect(fix.kind, ReferenceFixKind.duplicateName);
      expect(fix.reason, 'duplicate_name');
      expect(fix.referencedId, _catMissing, reason: '报告要指出与哪一条重名');
      expect(fix.column, 'name');
      // 记录本身一个字都不改。
      expect(result.records.single.columns['parent_id'], _catA);
    });

    test('S14 父分类被删 → 升级为一级（deleted）；父分类从没存在过 → （missing）', () {
      final deleted = _fix(
        <ImportRecord>[_rec(type: 'category', id: _catB, columns: _category('午饭', parent: _catA))],
        localRows: <String, List<Map<String, Object?>>>{
          'category': <Map<String, Object?>>[_localRow(_catA, deletedAt: _t0)],
        },
      );
      expect(deleted.fixes.single.kind, ReferenceFixKind.promoteToRoot);
      expect(deleted.fixes.single.reason, 'deleted');
      expect(deleted.records.single.columns['parent_id'], isNull);

      final missing = _fix(<ImportRecord>[
        _rec(type: 'category', id: _catB, columns: _category('午饭', parent: _catA)),
      ]);
      expect(missing.fixes.single.reason, 'missing');
      expect(missing.records.single.columns['parent_id'], isNull);
    });

    test('parent 链成环 / 自指 ⇒ 全部升级为一级（cycle），不会无界遍历', () {
      final result = _fix(<ImportRecord>[
        _rec(type: 'category', id: _catA, columns: _category('环 A', parent: _catB)),
        _rec(type: 'category', id: _catB, columns: _category('环 B', parent: _catA), recordIndex: 1),
        _rec(
          type: 'category',
          id: _catMissing,
          columns: _category('自指', parent: _catMissing),
          recordIndex: 2,
        ),
      ]);

      expect(result.fixes.length, 3);
      for (final fix in result.fixes) {
        expect(fix.kind, ReferenceFixKind.promoteToRoot);
        expect(fix.reason, 'cycle');
      }
      for (final record in result.records) {
        expect(record.columns['parent_id'], isNull);
      }
    });

    test('parent 链超过深度上限 ⇒ 只有越过上限的那一条升级（too_deep）', () {
      // 深度是**遍历的边界**，不是产品语义：构造出来的超长链不该让修复变成
      // 一次无界遍历。这里钉住的是「恰好越界的那一条被升级、其余原样」。
      final chain = <String>[
        for (var i = 0; i <= ImportReferenceFixer.maxCategoryDepth + 2; i++)
          '${_catA.substring(0, 24)}${i.toString().padLeft(2, '0')}',
      ];
      final records = <ImportRecord>[
        _rec(type: 'category', id: chain.first, columns: _category('第 0 层')),
        for (var i = 1; i < chain.length; i++)
          _rec(
            type: 'category',
            id: chain[i],
            columns: _category('第 $i 层', parent: chain[i - 1]),
            recordIndex: i,
          ),
      ];

      final result = _fix(records);
      final tooDeep = <String>[
        for (final fix in result.fixes)
          if (fix.reason == 'too_deep') fix.recordId,
      ];
      expect(tooDeep, isNotEmpty);
      expect(tooDeep, contains(chain.last));
      // 浅的那些不动：链根（第 0 层）与它的直接子级必须保持原样。
      final shallow = <String, ImportRecord>{for (final r in result.records) r.id: r};
      expect(shallow[chain[0]]!.columns['parent_id'], isNull);
      expect(shallow[chain[1]]!.columns['parent_id'], chain[0]);
    });
  });

  group('输出形状：记录不许丢', () {
    test('一级分类必须原样归还（回归：修复器曾经把它们静默丢掉）', () {
      // 修复器只处理「有父」的记录，输出若按「处理过的那几条」重排，
      // 表现就是「导入之后少了几个分类」—— 用户要过很久才发现。
      final records = <ImportRecord>[
        _rec(type: 'category', id: _catA, columns: _category('一级分类')),
        _rec(
          type: 'category',
          id: _catB,
          columns: _category('孤儿', parent: _catMissing),
          recordIndex: 1,
        ),
      ];

      final result = _fix(records);

      expect(result.records.length, 2);
      expect(
        result.records.map((ImportRecord r) => r.id),
        <String>[_catA, _catB],
        reason: '原行序归还：计划按 recordIndex 排语句，修复器重排会让行序变成第三个变量',
      );
      final root = result.records.first;
      expect(root.columns['id'], _catA);
      expect(root.columns['parent_id'], isNull);
      expect(root.columns['name'], '一级分类');
      expect(root.recordIndex, 0);
      expect(result.records.last.columns['parent_id'], isNull, reason: '孤儿被升级');
    });

    test('悬空的 ledger_id 不造占位账本（这条边界是「整体回滚」的前提）', () {
      // §2.3 的 ledger.code 是 NOT NULL UNIQUE 的 6 字符 Base32 ——
      // 凭空编一个「唯一」的 code 只能靠猜，而猜的结果不确定，进不了向量。
      // 因此悬空的 ledger_id 不走修复，仍然由完整性检查整批回滚。
      final result = _fix(<ImportRecord>[
        _rec(
          type: 'account',
          id: _acctA,
          columns: <String, Object?>{
            'ledger_id': _ledMissing, // 指向一个不存在的账本
            'name': '现金',
            'type': 1,
            'currency': 'CNY',
            'opening_balance_minor': 0,
            'is_archived': 0,
          },
        ),
      ]);

      expect(ImportReferenceFixer.repairTargets.containsKey('ledger'), isFalse);
      expect(result.placeholders, isEmpty);
      expect(result.fixes, isEmpty);
      expect(result.records.single.columns['ledger_id'], _ledMissing, reason: '不改数据，留给完整性检查去报');
    });
  });
}

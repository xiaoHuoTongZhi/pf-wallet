/// 导出侧读库器（`pf_io` 的 `export_extract.dart`）的契约测试。
///
/// ## 这个文件守的是什么
///
/// 它守的不是「SQL 跑得通」——那件事由 `roundtrip_test`（真 SQLCipher）与
/// 导入导出向量接力。这里守的是**两张表不分叉**：
///
///   * **表→阶段**：`payloadTableOf` 必须与 `kPayloadRecordSpecs` 同源
///     （导出侧读哪个表、导入侧认得哪个表，只能有一个答案）；
///   * **列→字段**：`readStage` 取出的列集合必须**逐列等于**字段表登记的列
///     （顺序也一致）—— 少了就是「导出的文件缺一列」，多了就是
///     「导出带上了库里多出的列，于是往返产物与原件不等」；
///   * **取值还原**：`idList` / `jsonObject` / `base64Blob` 三种
///     「形状不同」的列必须被还原成载荷键该有的形态，其余原样透传。
///
/// 为什么用「罐头行」的假驱动而不是真库：上面这三条都是**映射规则**，
/// 与 SQLite 的语义无关。用真库测它们会引入一个与规则无关的失败源
/// （引擎在不在、SQLCipher 装没装），而那正是「本机绿、CI 红」的温床。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_data/pf_data.dart';
import 'package:pf_io/pf_io.dart';
import 'package:test/test.dart';

/// 只回答「这张表有哪些行」，并记录发出的 SQL。
///
/// 按 ` FROM <表名> ` 匹配而不是按前缀：`SELECT a, b FROM txn ORDER BY id`
/// 与 `SELECT * FROM txn WHERE …` 都能命中，而「匹配不上就返回空表」这件事
/// 恰好是我们要的 —— 表名写错会表现为「那一阶段是空的」，用例里看得见。
final class CannedDb implements PfDb {
  CannedDb(this.rows);

  /// 表名 → 行。
  final Map<String, List<Map<String, Object?>>> rows;

  final List<String> queries = <String>[];

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, {
    List<Object?> arguments = const <Object?>[],
  }) async {
    queries.add(sql);
    for (final entry in rows.entries) {
      if (sql.contains(' FROM ${entry.key} ')) {
        return entry.value;
      }
    }
    return const <Map<String, Object?>>[];
  }

  @override
  Future<void> run(String sql, {List<Object?> arguments = const <Object?>[]}) async {}

  @override
  Future<T> transaction<T>(Future<T> Function(PfDb db) action) => action(this);
}

/// 一条「各行都齐」的最小 txn 行（只有被断言到的列有意义）。
Map<String, Object?> _txnRow(String id) => <String, Object?>{
  'id': id,
  'ledger_id': 'L1',
  'type': 1,
  'amount_minor': 100,
  'currency': 'CNY',
  'occurred_at': 1758000000000,
  'day_key': '2026-09-16',
  'month_key': '2026-09',
  'tz_offset_min': 480,
  'account_id': 'A1',
  'to_account_id': null,
  'category_id': 'C1',
  'merchant': null,
  'note': null,
  'tags': '[]',
  'fee_minor': 0,
  'is_reimbursable': 0,
  'excluded_from_stats': 0,
  'created_at': 1758000000000,
  'updated_at': 1758000000000,
  'deleted_at': null,
  'device_id': 'D1',
  'origin_device_id': 'D1',
  'rev': 1,
};

void main() {
  group('表→阶段：唯一访问器', () {
    test('每个阶段返回的表名与字段表逐字相同', () {
      for (final stage in kPayloadStageOrder) {
        expect(payloadTableOf(stage), kPayloadRecordSpecs[stage]!.table, reason: '$stage 的表名有两个答案');
      }
    });

    test('八个阶段一个不少，且没有多余', () {
      expect(kPayloadStageOrder.length, 8);
      expect(kPayloadStageOrder.toSet().length, 8, reason: '阶段名不能重复');
      for (final stage in kPayloadStageOrder) {
        expect(kPayloadRecordSpecs.containsKey(stage), isTrue, reason: stage);
      }
    });

    test('未知阶段抛 DomainError（而不是回一份空表）', () {
      // 返回空集的话，表现是「导出了一份缺整张表的备份」，而导出方会报成功 ——
      // 这个错误必须在这里响。
      expect(() => payloadTableOf('ledgers'), throwsA(isA<DomainError>()));
      expect(() => payloadTableOf(''), throwsA(isA<DomainError>()));
    });
  });

  group('列→字段：只取字段表登记的列，且顺序一致', () {
    test('每个阶段的 SELECT 列集合与顺序都等于字段表', () async {
      final db = CannedDb(<String, List<Map<String, Object?>>>{});
      for (final stage in kPayloadStageOrder) {
        final spec = kPayloadRecordSpecs[stage]!;
        await PfPayloadExtractor.readStage(db, stage);
        final sql = db.queries.last;
        final columns = sql.substring('SELECT '.length, sql.indexOf(' FROM '));
        expect(
          columns,
          spec.fields.map((PayloadField f) => f.column).join(', '),
          reason:
              '$stage 的列与字段表不一致 —— 少一列是「备份缺一列」，'
              '多一列是「往返产物与原件不等」',
        );
      }
    });

    test('每个阶段都以 ORDER BY id 结尾（行序即 contentHash 的输入）', () async {
      final db = CannedDb(<String, List<Map<String, Object?>>>{});
      for (final stage in kPayloadStageOrder) {
        await PfPayloadExtractor.readStage(db, stage);
        expect(
          db.queries.last,
          endsWith(' ORDER BY id'),
          reason: '$stage 的行序不确定 ⇒ 同一份数据两次导出会得到不同的字节',
        );
      }
    });

    test('readStages 一定包含全部 8 个阶段（空阶段是空列表，不是缺键）', () async {
      final stages = await PfPayloadExtractor.readStages(
        CannedDb(<String, List<Map<String, Object?>>>{}),
      );
      expect(stages.keys.toSet(), kPayloadStageOrder.toSet());
      for (final stage in kPayloadStageOrder) {
        expect(stages[stage], isEmpty, reason: stage);
      }
    });
  });

  group('取值还原：只在形状不同的地方动手', () {
    test('txn 行：普通列原样透传，null 保持 null', () async {
      final db = CannedDb(<String, List<Map<String, Object?>>>{
        'txn': <Map<String, Object?>>[_txnRow('T1')],
      });
      final rows = await PfPayloadExtractor.readStage(db, 'txn');
      expect(rows, hasLength(1));
      final row = rows.single;
      expect(row['id'], 'T1');
      expect(row['txnType'], 1, reason: '载荷键是 txnType（判别键 type 独占）');
      expect(row['amountMinor'], 100);
      expect(row['merchant'], isNull);
      expect(row['dayKey'], '2026-09-16');
      expect(row['rev'], 1);
    });

    test('idList：TEXT 里的 JSON 数组还原成数组；NULL 还原成空数组', () async {
      final row = _txnRow('T')..['tags'] = '["tag-1","tag-2"]';
      final db = CannedDb(<String, List<Map<String, Object?>>>{
        'txn': <Map<String, Object?>>[row],
      });
      expect((await PfPayloadExtractor.readStage(db, 'txn')).single['tags'], <Object?>[
        'tag-1',
        'tag-2',
      ]);

      final nullRow = _txnRow('T2')..['tags'] = null;
      final db2 = CannedDb(<String, List<Map<String, Object?>>>{
        'txn': <Map<String, Object?>>[nullRow],
      });
      expect(
        (await PfPayloadExtractor.readStage(db2, 'txn')).single['tags'],
        isEmpty,
        reason: 'idList 的缺省是空数组（§4.1 C3），不是 null',
      );
    });

    test('jsonObject：TEXT 里的对象还原成 Map；非法 JSON 抛 DomainError', () async {
      final ok = CannedDb(<String, List<Map<String, Object?>>>{
        'theme_profile': <Map<String, Object?>>[
          <String, Object?>{
            'id': 'TH1',
            'name': '默认',
            'spec_json': '{"a":1}',
            'is_active': 0,
            'created_at': 1,
            'updated_at': 1,
            'deleted_at': null,
            'device_id': 'D1',
            'rev': 1,
          },
        ],
      });
      expect(
        (await PfPayloadExtractor.readStage(ok, 'theme')).single['specJson'],
        <String, Object?>{'a': 1},
      );

      final bad = CannedDb(<String, List<Map<String, Object?>>>{
        'theme_profile': <Map<String, Object?>>[
          <String, Object?>{
            'id': 'TH1',
            'name': '默认',
            'spec_json': '{oops',
            'is_active': 0,
            'created_at': 1,
            'updated_at': 1,
            'deleted_at': null,
            'device_id': 'D1',
            'rev': 1,
          },
        ],
      });
      // 「库里存了半截 JSON」是写坏了库，导出时必须响 —— 静默通过会让这个
      // 问题随着备份传播到另一台设备。
      expect(() => PfPayloadExtractor.readStage(bad, 'theme'), throwsA(isA<DomainError>()));
    });

    test('base64Blob：BLOB 还原成 Base64 字符串', () async {
      final bytes = Uint8List.fromList(<int>[1, 2, 3, 250]);
      final db = CannedDb(<String, List<Map<String, Object?>>>{
        'attachment': <Map<String, Object?>>[
          <String, Object?>{
            'id': 'AT1',
            'ledger_id': 'L1',
            'txn_id': null,
            'file_name': 'a.png',
            'mime': 'image/png',
            'size_bytes': 4,
            'sha256': 'x',
            'storage': 1,
            'data': bytes,
            'ext_rel_path': null,
            'wrapped_dek': null,
            'dek_nonce': null,
            'width': null,
            'height': null,
            'created_at': 1,
            'updated_at': 1,
            'deleted_at': null,
            'device_id': 'D1',
            'rev': 1,
          },
        ],
      });
      final row = (await PfPayloadExtractor.readStage(db, 'attachment')).single;
      expect(row['dataB64'], base64Encode(bytes));
      expect(row['wrappedDek'], isNull, reason: 'base64Blob 为 NULL 时保持 null');
    });
  });

  group('条数：从结果数出来，不另发 COUNT', () {
    test('countsOf 按阶段给条数，缺键按 0 计', () {
      final counts = PfPayloadExtractor.countsOf(<String, List<Map<String, Object?>>>{
        'ledger': <Map<String, Object?>>[<String, Object?>{}, <String, Object?>{}],
        'txn': <Map<String, Object?>>[<String, Object?>{}],
      });
      expect(counts['ledger'], 2);
      expect(counts['txn'], 1);
      expect(counts.keys.toSet(), kPayloadStageOrder.toSet());
      for (final stage in kPayloadStageOrder) {
        expect(counts[stage], isNotNull, reason: stage);
      }
      expect(counts['attachment'], 0);
    });

    test('counts 与实测行数一致（manifest 的 counts 是逐阶段强核对的）', () async {
      final db = CannedDb(<String, List<Map<String, Object?>>>{
        'txn': <Map<String, Object?>>[_txnRow('T1'), _txnRow('T2'), _txnRow('T3')],
      });
      final stages = await PfPayloadExtractor.readStages(db);
      final counts = PfPayloadExtractor.countsOf(stages);
      // 这条不是同义反复：counts 若改走一条独立的 COUNT 查询，
      // 「查询结果与读到的行数不一致」就会在真库上出现（并发写、视图差异）。
      expect(counts['txn'], stages['txn']!.length);
      expect(counts['txn'], 3);
    });
  });

  group('manifest 组装', () {
    test('键序与 §3.2 一致，且不带 contentHash', () {
      final manifest = buildPayloadManifest(
        counts: <String, int>{'ledger': 1},
        deviceId: 'D1',
        deviceName: 'dev',
        platform: 'windows',
        exportedAtMilliseconds: 1758000000000,
        includesAttachments: false,
      );
      expect(manifest[kPayloadDiscriminatorKey], 'manifest');
      expect(
        manifest.containsKey('payloadVersion'),
        isFalse,
        reason: '载荷版本由编码器注入，组装函数不越权（两处都写就会出现两个版本号）',
      );
      expect(
        manifest.containsKey('contentHash'),
        isFalse,
        reason: 'contentHash 由编码器算 —— 允许调用方传入等于允许伪造',
      );
      expect(manifest['exportKind'], 'full');
      expect(manifest['includesAttachments'], isFalse);
    });

    test('scope 专属字段按需带上（range / ledgerIds / incremental）', () {
      expect(
        buildPayloadManifest(
          counts: <String, int>{},
          deviceId: 'D1',
          deviceName: 'dev',
          platform: 'linux',
          exportedAtMilliseconds: 1,
          includesAttachments: false,
          exportKind: 'range',
          range: <String, Object?>{'from': 1},
        )['range'],
        <String, Object?>{'from': 1},
      );
      expect(
        buildPayloadManifest(
          counts: <String, int>{},
          deviceId: 'D1',
          deviceName: 'dev',
          platform: 'linux',
          exportedAtMilliseconds: 1,
          includesAttachments: false,
          exportKind: 'ledger',
          ledgerIds: <String>['L1'],
        )['ledgerIds'],
        <String>['L1'],
      );
      final incremental = buildPayloadManifest(
        counts: <String, int>{},
        deviceId: 'D1',
        deviceName: 'dev',
        platform: 'linux',
        exportedAtMilliseconds: 1,
        includesAttachments: false,
        exportKind: 'incremental',
        changeLogRange: <String, Object?>{'since': 1},
        sinceExportAt: 1,
      );
      expect(incremental['changeLogRange'], <String, Object?>{'since': 1});
      expect(incremental['sinceExportAt'], 1);
    });
  });
}

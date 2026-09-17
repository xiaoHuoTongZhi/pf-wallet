/// `PfbPayloadEncoder` 的行为测试。
///
/// 字节级断言由 `export_payload` 向量（Python 独立实现）负责；
/// 这里守行为边界：行序契约、contentHash 注入与防伪造、
/// scope 校验、以及不可序列化值的拒绝。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pf_core/pf_core.dart';
import 'package:pf_crypto/pf_crypto.dart';
import 'package:pf_io/pf_io.dart';
import 'package:test/test.dart';

Map<String, Object?> _manifest({String kind = 'full'}) => <String, Object?>{
  'type': 'manifest',
  'appVersion': '1.0.0',
  'deviceId': '01J8Z9K2M4P6Q8R0T2V4X6Z8B1',
  'exportedAt': 1757922436789,
  'exportKind': kind,
  'includesAttachments': false,
  if (kind == 'range')
    'range': <String, Object?>{'fromDayKey': '2026-01-01', 'toDayKey': '2026-09-15'},
  if (kind == 'ledger') 'ledgerIds': <Object?>['01J8TESTLEDGER0000000000001'],
  if (kind == 'incremental') ...<String, Object?>{
    'changeLogRange': <String, Object?>{'minSeq': 1, 'maxSeq': 2},
    'sinceExportAt': 1757000000000,
  },
};

List<Map<String, Object?>> _parseLines(Uint8List bytes) => <Map<String, Object?>>[
  for (final line in utf8.decode(bytes).split('\n'))
    if (line.isNotEmpty) jsonDecode(line) as Map<String, Object?>,
];

void main() {
  group('PfbPayloadEncoder.encode · 行序契约', () {
    test('记录行按 kPayloadStageOrder 输出，与传入键序无关', () {
      final result = PfbPayloadEncoder.encode(
        manifest: _manifest(),
        stages: <String, List<Map<String, Object?>>>{
          'txn': const <Map<String, Object?>>[
            {'id': 'txn-1'},
          ],
          'ledger': const <Map<String, Object?>>[
            {'id': 'ledger-1'},
          ],
          'budget': const <Map<String, Object?>>[
            {'id': 'budget-1'},
          ],
        },
        generatedAtMilliseconds: 1757922437000,
      );
      final lines = _parseLines(result.ndjsonBytes);
      expect(lines.first['type'], 'manifest');
      expect(lines.last['type'], 'end');
      final types = <String>[for (final line in lines) line['type']! as String];
      // ledger（父）必须先于 txn/budget；整体相对序符合契约。
      expect(types.indexOf('ledger'), lessThan(types.indexOf('txn')));
      expect(types.indexOf('txn'), lessThan(types.indexOf('budget')));
      expect(result.recordCount, 3);
    });

    test('未知阶段名 → PFC_E_VALIDATION', () {
      expect(
        () => PfbPayloadEncoder.encode(
          manifest: _manifest(),
          stages: const <String, List<Map<String, Object?>>>{
            'statement': <Map<String, Object?>>[{}],
          },
          generatedAtMilliseconds: 0,
        ),
        throwsA(isA<DomainError>().having((e) => e.code, 'code', PfErrorCode.validation)),
      );
    });
  });

  group('PfbPayloadEncoder.encode · contentHash 注入与防伪造', () {
    test('manifest 被注入 payloadVersion 与 contentHash；end 行携带同一哈希', () {
      final result = PfbPayloadEncoder.encode(
        manifest: _manifest(),
        stages: const <String, List<Map<String, Object?>>>{},
        generatedAtMilliseconds: 1757922437000,
      );
      final lines = _parseLines(result.ndjsonBytes);
      final manifest = lines.first;
      expect(manifest['payloadVersion'], kPayloadVersion);
      expect(manifest['contentHash'], 'sha256:${result.contentHashHex}');
      final end = lines.last;
      expect(end['recordCount'], 0);
      expect(end['contentHash'], 'sha256:${result.contentHashHex}');
      expect(end['generatedAt'], 1757922437000);
    });

    test('contentHash 等于全部记录行的 SHA-256（手工重算交叉验证，不含 manifest 与 end）', () {
      final result = PfbPayloadEncoder.encode(
        manifest: _manifest(),
        stages: const <String, List<Map<String, Object?>>>{
          'ledger': <Map<String, Object?>>[
            {'id': 'l1'},
          ],
          'txn': <Map<String, Object?>>[
            {'id': 't1'},
            {'id': 't2'},
          ],
        },
        generatedAtMilliseconds: 1,
      );
      final lines = utf8.decode(result.ndjsonBytes).split('\n')..removeLast();
      final recordLines = lines.sublist(1, lines.length - 1); // 去掉首行 manifest 与末行 end
      final manual = Sha256.instance.hashHex(utf8.encode('${recordLines.join('\n')}\n'));
      expect(result.contentHashHex, manual);
    });

    test('调用方自带 contentHash → 拒绝（防伪造）', () {
      expect(
        () => PfbPayloadEncoder.encode(
          manifest: <String, Object?>{..._manifest(), 'contentHash': 'sha256:deadbeef'},
          stages: const <String, List<Map<String, Object?>>>{},
          generatedAtMilliseconds: 0,
        ),
        throwsA(isA<DomainError>().having((e) => e.code, 'code', PfErrorCode.validation)),
      );
    });
  });

  group('PfbPayloadEncoder.encode · manifest 校验', () {
    test('exportKind 缺失 / 非法 → PFC_E_VALIDATION', () {
      expect(
        () => PfbPayloadEncoder.encode(
          manifest: <String, Object?>{'type': 'manifest'},
          stages: const <String, List<Map<String, Object?>>>{},
          generatedAtMilliseconds: 0,
        ),
        throwsA(isA<DomainError>()),
      );
      expect(
        () => PfbPayloadEncoder.encode(
          manifest: <String, Object?>{..._manifest(), 'exportKind': 'everything'},
          stages: const <String, List<Map<String, Object?>>>{},
          generatedAtMilliseconds: 0,
        ),
        throwsA(isA<DomainError>()),
      );
    });

    test('range 缺 range、ledger 缺 ledgerIds、incremental 缺 changeLogRange → 拒绝', () {
      for (final kind in <String>['range', 'ledger', 'incremental']) {
        expect(
          () => PfbPayloadEncoder.encode(
            // _manifest() 缺省不含任何 scope 专属字段 —— 换上 exportKind
            // 就构成「kind 声明了范围却没给范围」的非法请求。
            manifest: <String, Object?>{..._manifest(), 'exportKind': kind},
            stages: const <String, List<Map<String, Object?>>>{},
            generatedAtMilliseconds: 0,
          ),
          throwsA(isA<DomainError>()),
          reason: 'kind=$kind 缺 scope 专属字段必须被拦',
        );
      }
    });

    test('type 不是 manifest → 拒绝', () {
      expect(
        () => PfbPayloadEncoder.encode(
          manifest: <String, Object?>{..._manifest(), 'type': 'meta'},
          stages: const <String, List<Map<String, Object?>>>{},
          generatedAtMilliseconds: 0,
        ),
        throwsA(isA<DomainError>()),
      );
    });
  });
}

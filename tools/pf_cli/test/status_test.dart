/// `statusOfCode` 的表测试。
///
/// 这张表是「脚本据此决定下一步做什么」的依据，所以逐行锁死：
/// 尤其要防「几种处境塌成同一个词」—— 若 `PFI_E_CONFLICT` 与 `PFI_E_CORRUPT`
/// 都映射成 `corrupted`，一次需要人工裁决的冲突就会被自动化流程当成
/// 「文件坏了，重导一次」。
library;

import 'package:pf_cli/pf_cli.dart';
import 'package:pf_core/pf_core.dart';
import 'package:test/test.dart';

void main() {
  group('statusOfCode', () {
    test('导入侧三态各有各的词', () {
      expect(statusOfCode(PfErrorCode.ioWrongPassword), 'wrong-password');
      expect(statusOfCode(PfErrorCode.ioCorrupt), 'corrupted');
      expect(statusOfCode(PfErrorCode.ioVersionIncompatible), 'version-incompatible');
    });

    test('邻近处境不被吞进三态', () {
      expect(statusOfCode(PfErrorCode.ioIncompatible), 'reference-missing');
      expect(statusOfCode(PfErrorCode.ioConflict), 'record-conflict');
      expect(statusOfCode(PfErrorCode.ioVolumeIncomplete), 'volume-incomplete');
      expect(statusOfCode(PfErrorCode.ioBackupFailed), 'backup-failed');
      expect(statusOfCode(PfErrorCode.validation), 'payload-invalid');
    });

    test('没见过的码兜底为 rejected，不抛异常（报错的路不能自己崩）', () {
      expect(statusOfCode('PFX_E_WHATEVER'), 'rejected');
      expect(statusOfCode(''), 'rejected');
      expect(statusOfCode(PfErrorCode.storageOpenFailed), 'rejected');
    });

    test('词与码一一对应，不存在两个码共用一个词', () {
      const codes = <String>[
        PfErrorCode.ioWrongPassword,
        PfErrorCode.ioCorrupt,
        PfErrorCode.ioVersionIncompatible,
        PfErrorCode.ioIncompatible,
        PfErrorCode.ioConflict,
        PfErrorCode.ioVolumeIncomplete,
        PfErrorCode.ioBackupFailed,
        PfErrorCode.validation,
      ];
      final words = codes.map(statusOfCode).toList();
      expect(words.toSet().length, codes.length, reason: '共用一个词会让脚本无法区分处境');
      expect(words, isNot(contains('rejected')));
    });
  });
}

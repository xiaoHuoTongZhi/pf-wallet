import 'package:pf_core/pf_core.dart';
import 'package:test/test.dart';

void main() {
  group('错误码字面值被钉死（改动即破坏跨端兼容）', () {
    test('容器类', () {
      expect(PfErrorCode.containerMagic, 'PFB_E_MAGIC');
      expect(PfErrorCode.containerVersionUnsupported, 'PFB_E_VERSION_UNSUPPORTED');
      expect(PfErrorCode.containerTruncated, 'PFB_E_TRUNCATED');
      expect(PfErrorCode.containerDigestMismatch, 'PFB_E_DIGEST_MISMATCH');
      expect(PfErrorCode.containerAuthFailed, 'PFB_E_AUTH_FAILED');
    });

    test('密钥与领域类', () {
      expect(PfErrorCode.keyringWrongPassword, 'PFK_E_WRONG_PASSWORD');
      expect(PfErrorCode.keyringTampered, 'PFK_E_TAMPERED');
      expect(PfErrorCode.moneyCurrencyMismatch, 'PFC_E_CURRENCY_MISMATCH');
      expect(PfErrorCode.moneyOverflow, 'PFC_E_OVERFLOW');
      expect(PfErrorCode.ioRollbackFailed, 'PFI_E_ROLLBACK');
    });
  });

  group('导入失败的「三态区分」—— 本项目最关键的错误契约', () {
    test('损坏与密码错误的码必须不同', () {
      final corrupted = ContainerError.digestMismatch();
      final wrongPassword = ContainerError.authFailed();
      expect(corrupted.code, isNot(wrongPassword.code));
    });

    test('三态各自的用户提示互不相同，且指向不同动作', () {
      final wrongPassword = ContainerError.authFailed();
      final corrupted = ContainerError.digestMismatch();
      final versionTooNew = ContainerError.versionUnsupported(found: 2, supported: 1);

      final messages = <String>{
        wrongPassword.userMessage,
        corrupted.userMessage,
        versionTooNew.userMessage,
      };
      expect(messages, hasLength(3), reason: '三种情形的提示不能重复');

      expect(wrongPassword.userMessage, contains('密码'));
      expect(corrupted.userMessage, contains('损坏'));
      expect(versionTooNew.userMessage, contains('升级'));
    });

    test('密码错误的提示必须明确说明无法找回', () {
      expect(ContainerError.authFailed().userMessage, contains('无法找回'));
    });

    test('分卷不完整与文件截断是两个不同的码', () {
      expect(
        ContainerError.truncated(expected: 100, actual: 20).code,
        isNot(ImportExportError.volumeIncomplete(expected: 3, found: 2).code),
      );
    });
  });

  group('sealed 层次结构完备（编译器强制穷尽分支）', () {
    test('六类错误都能被 switch 穷尽匹配', () {
      final samples = <PfError>[
        ContainerError.authFailed(),
        CryptoError.kdfFailed(),
        KeyringError.locked(),
        StorageError.openFailed(),
        ImportExportError.conflict(count: 3),
        DomainError.moneyFormat(input: 'abc'),
      ];

      for (final error in samples) {
        final label = switch (error) {
          ContainerError() => 'container',
          CryptoError() => 'crypto',
          KeyringError() => 'keyring',
          StorageError() => 'storage',
          ImportExportError() => 'io',
          DomainError() => 'domain',
        };
        expect(label, isNotEmpty);
      }
    });
  });

  group('错误对象的通用契约', () {
    final samples = <PfError>[
      ContainerError.magicMismatch(),
      ContainerError.versionUnsupported(found: 9, supported: 1),
      ContainerError.truncated(expected: 100, actual: 4),
      ContainerError.digestMismatch(),
      ContainerError.authFailed(),
      ContainerError.headerInvalid(detail: 'saltLength=0'),
      CryptoError.kdfParamsOutOfRange(detail: 'memoryKiB=1048576'),
      CryptoError.kdfFailed(cause: StateError('oom')),
      KeyringError.wrongPassword(),
      KeyringError.wrongPassword(remainingAttempts: 3),
      KeyringError.absent(),
      KeyringError.locked(),
      KeyringError.biometricUnavailable(),
      KeyringError.tampered(),
      StorageError.openFailed(cause: StateError('io')),
      StorageError.migrationFailed(from: 1, to: 2),
      StorageError.schemaTooNew(found: 5, supported: 1),
      ImportExportError.conflict(count: 7),
      ImportExportError.rollbackFailed(),
      ImportExportError.incompatible(detail: 'entity kind mismatch'),
      ImportExportError.volumeIncomplete(expected: 3, found: 1),
      DomainError.currencyMismatch(left: 'CNY', right: 'USD'),
      DomainError.moneyOverflow(value: 1),
      DomainError.moneyFormat(input: 'abc'),
      DomainError.validation(detail: 'x'),
    ];

    test('每条错误都有非空且完整的用户提示', () {
      for (final error in samples) {
        expect(error.userMessage.trim(), isNotEmpty, reason: error.code);
        expect(
          error.userMessage.trim().endsWith('。'),
          isTrue,
          reason: '${error.code} 的用户提示应当是完整句子：${error.userMessage}',
        );
      }
    });

    test('toString 是单行且可安全写入日志', () {
      for (final error in samples) {
        final text = error.toString();
        expect(text, contains(error.code));
        expect(text.contains('\n'), isFalse, reason: error.code);
      }
    });

    test('cause 被保留用于诊断', () {
      final cause = StateError('底层失败');
      final error = StorageError.openFailed(cause: cause);
      expect(error.cause, same(cause));
      expect(error.toString(), contains('底层失败'));
    });

    test('码不重复（同一情形不得有两个码）', () {
      final codes = <String>[
        PfErrorCode.containerMagic,
        PfErrorCode.containerVersionUnsupported,
        PfErrorCode.containerTruncated,
        PfErrorCode.containerDigestMismatch,
        PfErrorCode.containerAuthFailed,
        PfErrorCode.containerHeaderInvalid,
        PfErrorCode.kdfParamsOutOfRange,
        PfErrorCode.kdfFailed,
        PfErrorCode.keyringWrongPassword,
        PfErrorCode.keyringAbsent,
        PfErrorCode.keyringLocked,
        PfErrorCode.keyringBiometricUnavailable,
        PfErrorCode.keyringTampered,
        PfErrorCode.storageOpenFailed,
        PfErrorCode.storageMigrationFailed,
        PfErrorCode.storageSchemaTooNew,
        PfErrorCode.ioConflict,
        PfErrorCode.ioRollbackFailed,
        PfErrorCode.ioIncompatible,
        PfErrorCode.ioVolumeIncomplete,
        PfErrorCode.moneyCurrencyMismatch,
        PfErrorCode.moneyOverflow,
        PfErrorCode.moneyFormat,
        PfErrorCode.validation,
      ];
      expect(codes.toSet(), hasLength(codes.length));
      for (final code in codes) {
        expect(code, matches(RegExp(r'^PF[BCIKD]_E_[A-Z_]+$')), reason: code);
      }
    });
  });
}

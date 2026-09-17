/// 驱动：SQLCipher 打开流程（方案 §3.4，已实装，纯 Dart）。
///
/// ## 为什么 PRAGMA 脚本值得向量
///
/// 打开脚本里的每一行都是**安全设置**（§3.4 的表格逐条给了理由），
/// 顺序又是**正确性**要求（key 必须在 cipher 参数之前、iOS 明文头必须在
/// key 之前）。任何一处被"顺手改掉"，轻则打不开库，重则把
/// `temp_store=FILE` 的明文泄漏点重新打开 —— 而这类回归在真实库上
/// 只有端到端测试能抓到。用向量把「脚本长什么样」锁死，
/// 纯 Dart 的 CI 就能在每次提交时守住这份契约。
///
/// 期望值来自 `tools/golden_vectors_gen/db_open.py`：从规格 §3.4 原文
/// **人工转录**（与 AES 的 NIST 锚点同理 —— 来源是文档，不是实现）。
library;

import 'package:pf_data/pf_data.dart';

import '../driver.dart';
import '../json_util.dart';
import '../outcome.dart';

/// 打开前的有序 PRAGMA 脚本（setup）+ 打开后的有序脚本（post-open）。
final class DbOpenPlanDriver extends VectorDriver {
  const DbOpenPlanDriver();

  @override
  String get kind => 'db.open.plan';

  @override
  String get description => '§3.4 打开脚本的顺序与内容（key → cipher 参数 → 安全 PRAGMA）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'dekHex': '32 字节数据库密钥（DBKey）',
    'plaintextHeaderBytes': '0（Android/桌面）或 32（iOS 明文头）',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final dek = requireHexBytes(input, 'dekHex', kind);
    final plaintextHeaderBytes = requireInt(input, 'plaintextHeaderBytes', kind);
    final setup = PfSqlitePragma.openSetup(dek, plaintextHeaderBytes: plaintextHeaderBytes);
    return VectorOutcome.value(<String, Object?>{
      'setupStatements': setup,
      'postOpenStatements': PfSqlitePragma.postOpen,
    });
  }
}

/// SQLite 打开期错误的分类（§3.4 `_isCipherKeyError` 的对接点）。
final class DbOpenClassifyDriver extends VectorDriver {
  const DbOpenClassifyDriver();

  @override
  String get kind => 'db.open.classify';

  @override
  String get description => '把 SQLite 异常分类为 wrongPassword / openFailed（NOTADB 双分支）';

  @override
  bool get isImplemented => true;

  @override
  String get plannedMilestone => 'M1';

  @override
  Map<String, String> get inputContract => const <String, String>{
    'message': '驱动异常的 message（或 toString）',
    'resultCode': '可选：SQLite 结果码/扩展码（NOTADB=26，CORRUPT=11）',
    'keyVerifiedViaKeyCheck': '调用前 keyCheck 是否已通过',
  };

  @override
  Future<VectorOutcome> run(Map<String, Object?> input) async {
    final message = requireString(input, 'message', kind);
    final rawCode = input['resultCode'];
    final resultCode =
        rawCode is int ? rawCode : (rawCode is String ? int.tryParse(rawCode) : null);
    final keyVerified = requireBool(input, 'keyVerifiedViaKeyCheck', kind);
    // 分类器是工厂函数（返回 PfError，不抛）。向量的语义是"分类结果"，
    // 因此这里直接把返回的错误映射为 errored。
    final error = classifySqliteOpenError(
      message: message,
      resultCode: resultCode,
      keyVerifiedViaKeyCheck: keyVerified,
    );
    return VectorOutcome.errored(error.code);
  }
}

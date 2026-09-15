/// 向量文件的领域模型。
///
/// ## 一条向量由什么构成
///
/// ```
///   id     唯一标识 —— 失败报告、基线文件、代码注释都靠它指认
///   kind   驱动标识 —— 决定「谁来跑」也是唯一契约
///   input  输入      —— 驱动定义的字段集合，必须完全确定（不含随机、不含时钟）
///   expect 期望      —— 要么 {ok:true, value:{…}}，要么 {ok:false, errorCode:"…"}
/// ```
///
/// `input` 与 `expect` 都刻意是**弱类型的 Map**：
/// 让格式演进不需要改动模型层，校验责任交给驱动。
/// 代价是驱动必须自己校验输入字段（见 [VectorDriver.inputContract]），
/// 这是划算的 —— 换来的是一份不会被框架限制住的格式。
library;

import 'dart:convert';

import 'json_util.dart';
import 'schema.dart';

/// 一条向量用例。
final class PfVectorCase {
  const PfVectorCase({
    required this.id,
    required this.kind,
    required this.title,
    required this.milestone,
    required this.input,
    required this.expect,
    this.notes,
    this.tags = const <String>[],
  });

  /// 全局唯一的用例标识。命名约定：`<领域>.<对象>.<行为>[.<变体>]`。
  final String id;

  /// 驱动标识。
  final String kind;

  /// 一句话标题，失败报告里显示。
  final String title;

  /// 该用例属于哪个里程碑。
  final MilestoneTag milestone;

  /// 输入。字段集合由驱动定义。
  final Map<String, Object?> input;

  /// 期望。见 [VectorExpectation]。
  final VectorExpectation expect;

  /// 补充说明。**鼓励写「为什么是这条向量」**：
  /// 例如「这条向量锁定 m 的上限，防止导入时被构造的文件触发 OOM」。
  /// 只写「测试参数校验」的注释在半年后等于没写。
  final String? notes;

  /// 标签，用于按主题筛选（如 `security`、`regression`）。
  final List<String> tags;

  static PfVectorCase fromJson(Map<String, Object?> json, String path) {
    final id = requireString(json, 'id', path);
    return PfVectorCase(
      id: id,
      kind: requireString(json, 'kind', path),
      title: requireString(json, 'title', path),
      milestone: MilestoneTag.parse(requireString(json, 'milestone', path), '$path.milestone'),
      input: requireMap(json, 'input', path),
      expect: VectorExpectation.fromJson(requireMap(json, 'expect', path), '$path.expect'),
      notes: _optionalNotes(json, path),
      tags: stringList(json, 'tags', path),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind,
    'title': title,
    'milestone': milestone.value,
    'input': input,
    'expect': expect.toJson(),
    if (notes != null) 'notes': notes,
    if (tags.isNotEmpty) 'tags': tags,
  };

  @override
  String toString() => 'PfVectorCase($id, kind=$kind, ${milestone.value})';
}

/// `description` 允许缺失，也允许写空串；两者都归一为 null。
String? _optionalDescription(Map<String, Object?> json, String source) {
  final Object? raw = json['description'];
  if (raw == null) return null;
  if (raw is! String) {
    throw VectorFormatException(
      'description 必须是字符串（实际 ${raw.runtimeType}）',
      path: '$source.description',
    );
  }
  return raw.isEmpty ? null : raw;
}

/// `notes` 允许缺失，也允许写空串；两者都归一为 null。
String? _optionalNotes(Map<String, Object?> json, String path) {
  final Object? raw = json['notes'];
  if (raw == null) return null;
  if (raw is! String) {
    throw VectorFormatException('notes 必须是字符串（实际 ${raw.runtimeType}）', path: '$path.notes');
  }
  return raw.isEmpty ? null : raw;
}

/// 一条向量的期望结果。
///
/// 两种形态互斥：
///   - 成功：`{"ok": true, "value": {…}}`
///   - 失败：`{"ok": false, "errorCode": "PFB_E_MAGIC"}`
///
/// `errorCode` 允许写 `"*"`，表示「期望抛出任意 `PfError`」。
/// 这只应该用在「错误码本身不是契约」的场景（如纯参数类型错误），
/// 绝大多数向量应当写明具体错误码 —— 否则错误码的稳定性就没人守了。
final class VectorExpectation {
  const VectorExpectation.success(Map<String, Object?> this.value) : errorCode = null;

  const VectorExpectation.failure(String this.errorCode) : value = const <String, Object?>{};

  /// 期望的返回值。仅在成功形态下有意义。
  final Map<String, Object?>? value;

  /// 期望的错误码。`"*"` 表示任意错误码。
  final String? errorCode;

  /// 是否期望抛错。
  bool get expectsError => errorCode != null;

  /// 是否接受任意错误码。
  bool get acceptsAnyError => errorCode == '*';

  static VectorExpectation fromJson(Map<String, Object?> json, String path) {
    final ok = requireBool(json, 'ok', path);
    if (ok) {
      final value = requireMap(json, 'value', path);
      // 空期望是一个必须堵死的地洞。
      //
      // 比对规则是「期望里写到的每个键都必须一致」—— 于是 `value: {}`
      // 会让这条向量**无论实现输出什么都通过**。它看起来是条测试，
      // 实际什么都没测，而且不会有人发现。这类「假绿灯」比缺测试更危险。
      if (value.isEmpty) {
        throw VectorFormatException(
          '成功形态的 value 不得为空对象：空期望等于永远通过，什么都没测。'
          '若某项期望值暂时无法确定（例如需要独立的参考实现生成），'
          '就不要把这条向量写进文件，等能写清期望值再加',
          path: '$path.value',
        );
      }
      return VectorExpectation.success(value);
    }
    final code = requireString(json, 'errorCode', path);
    if (code.isEmpty) {
      throw VectorFormatException('errorCode 不得为空字符串', path: path);
    }
    return VectorExpectation.failure(code);
  }

  Map<String, Object?> toJson() =>
      expectsError
          ? <String, Object?>{'ok': false, 'errorCode': errorCode}
          : <String, Object?>{'ok': true, 'value': value};

  @override
  String toString() =>
      expectsError ? 'expectError($errorCode)' : 'expectValue(${jsonEncode(value)})';
}

/// 一个向量文件。
final class PfVectorSuite {
  const PfVectorSuite({
    required this.suite,
    required this.title,
    required this.cases,
    this.description,
    this.schemaVersion = VectorSchema.current,
  });

  /// 套件名（一般等于不含后缀的文件名）。
  final String suite;

  /// 人类可读标题。
  final String title;

  /// 用例列表。
  final List<PfVectorCase> cases;

  /// 套件说明。
  final String? description;

  /// 文件格式版本。
  final int schemaVersion;

  /// 解析一个向量文件。
  ///
  /// [source] 仅用于错误信息（通常传文件名）。
  static PfVectorSuite fromJson(Map<String, Object?> json, String source) {
    final schemaVersion = requireInt(json, 'schemaVersion', source);
    VectorSchema.requireSupported(schemaVersion, source);

    final suite = PfVectorSuite(
      suite: requireString(json, 'suite', source),
      title: requireString(json, 'title', source),
      description: _optionalDescription(json, source),
      schemaVersion: schemaVersion,
      cases: const <PfVectorCase>[],
    );

    final rawCases = requireList(json, 'cases', source);
    if (rawCases.isEmpty) {
      throw VectorFormatException('用例数组不得为空', path: '$source.cases');
    }

    final cases = <PfVectorCase>[];
    for (var i = 0; i < rawCases.length; i++) {
      final Object? raw = rawCases[i];
      if (raw is! Map<String, Object?>) {
        throw VectorFormatException('用例必须是对象（实际 ${raw.runtimeType}）', path: '$source.cases[$i]');
      }
      cases.add(PfVectorCase.fromJson(raw, '$source [$suite.suite] cases[$i]'));
    }

    return PfVectorSuite(
      suite: suite.suite,
      title: suite.title,
      description: suite.description,
      schemaVersion: schemaVersion,
      cases: List<PfVectorCase>.unmodifiable(cases),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'suite': suite,
    'title': title,
    if (description != null) 'description': description,
    'cases': cases.map((PfVectorCase c) => c.toJson()).toList(),
  };

  /// 该套件内所有用例 ID 是否唯一。
  void validateUniqueIds() {
    final seen = <String>{};
    for (final c in cases) {
      if (!seen.add(c.id)) {
        throw VectorFormatException('用例 ID 重复：${c.id}', path: suite);
      }
    }
  }

  @override
  String toString() => 'PfVectorSuite($suite, ${cases.length} 条用例)';
}

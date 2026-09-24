/// 取用**定版**的 SQLCipher / SQLite 原生库（CI 与本机自测用）。
///
/// 用法：
/// ```
/// dart run tools/pf_cli/bin/fetch_engine.dart                    # 两个都取
/// dart run tools/pf_cli/bin/fetch_engine.dart --artifact sqlcipher
/// dart run tools/pf_cli/bin/fetch_engine.dart --print-path plain  # 只打印路径
/// ```
///
/// ## 为什么这个脚本里可以出现网络客户端
///
/// `banned_api.yaml` 的 `no-network-client` 只扫 `apps/**` 与 `packages/**`
/// —— 那两条红线约束的是**要交付到用户设备上的代码**。本文件在 `tools/`
/// 下，是开发期工具，它做的事情恰恰是把「一次网络访问」换成「一份被
/// sha256 钉死的字节」，从而让后续所有步骤（探针、测试、命令行）
/// 都变成离线的、可复现的。
///
/// 但缺口要说清楚：**这个脚本是整条链上唯一需要联网的环节**。
/// 产物只落在 `build/`（已在 .gitignore 与 tracked_paths 的 deny 里），
/// **不入库**；库里只留下 [kVendorManifestPath] 那份清单。
///
/// ## 两级校验
///
///   1. 整包 `.nupkg` 的 sha256 —— 网线对面给的东西对不对；
///   2. 解出的那个成员文件的 sha256 —— 我们的解压实现有没有解错。
///
/// 只做第 1 级不够（解压 bug 会静默产出一份「包校验通过但内容不对」的文件），
/// 只做第 2 级也不够（要先把整包下下来才能解，而整包本身也得被钉住）。
/// 两级都在清单里，改任何一级都必须动清单，也就是必须出现在 diff 里。
///
/// ## 落盘是幂等的
///
/// 目标文件已存在且 sha256 相符就直接复用。CI 里探针与测试都会调它，
/// 因此第二次调用必须是纯本地操作（不联网、不重复解压）。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:pf_cli/engine_paths.dart';
import 'package:pf_cli/exit_codes.dart';
import 'package:pf_cli/zip.dart';
import 'package:pf_crypto/pf_crypto.dart';

/// 清单文件相对仓库根的路径。
const String kVendorManifestPath = 'tools/ci/native/engine_vendor.json';

/// 下载缓存目录（相对仓库根）。整包留着，重跑时不必再下一次。
const String kVendorCacheRoot = 'build/native/cache';

// 产物落地目录与落盘清单文件名住在 `engine_paths.dart`（`kEngineOutputRoot`
// / `kEnginePathsFileName`）—— 消费方（测试、探针、CI 脚本）读的是同一份
// 常量与同一个 `EnginePaths` 类型，不在这里另立一份。
/// 可测试的入口：argv、两个输出流、repo 根目录与下载实现都从参数进。
Future<int> runFetchEngine(
  List<String> arguments, {
  required StringSink out,
  required StringSink err,
  String? repoRoot,
  Future<Uint8List> Function(Uri url)? download,
}) async {
  final root = repoRoot ?? _repoRootFromScript();
  final parsed = _parseArgs(arguments);

  if (parsed.showHelp) {
    out.writeln(_usage);
    return ExitCodes.ok;
  }
  if (parsed.error != null) {
    err.writeln('用法错误：${parsed.error}');
    err.writeln(_usage);
    return ExitCodes.toolError;
  }

  final manifestFile = File('$root/$kVendorManifestPath');
  if (!manifestFile.existsSync()) {
    err.writeln('找不到定版清单：${manifestFile.path}');
    return ExitCodes.toolError;
  }

  final _Manifest manifest;
  try {
    manifest = _Manifest.parse(manifestFile.readAsStringSync());
  } on FormatException catch (error) {
    err.writeln('清单无法解析：${error.message}');
    return ExitCodes.toolError;
  }

  final wanted = parsed.artifacts.isEmpty ? manifest.artifactNames : parsed.artifacts;
  for (final name in wanted) {
    if (!manifest.artifacts.containsKey(name)) {
      err.writeln('清单里没有名为 "$name" 的产物（有的是 ${manifest.artifactNames.join(', ')}）');
      return ExitCodes.toolError;
    }
  }

  final runtime = parsed.runtime ?? currentRuntimeId();
  if (runtime == null) {
    err.writeln('无法识别当前平台（${Platform.operatingSystem} / ${Abi.current()}），清单里没有对应条目');
    return ExitCodes.toolError;
  }

  final fetch = download ?? _httpDownload;
  final resolved = <String, EnginePathEntry>{};

  for (final name in wanted) {
    final artifact = manifest.artifacts[name]!;
    final member = artifact.members[runtime];
    if (member == null) {
      err.writeln('产物 "$name" 在清单里没有 $runtime 的条目');
      return ExitCodes.toolError;
    }
    final target = File('$root/$kEngineOutputRoot/$runtime/${_leafOf(member.path)}');

    if (parsed.printPathOnly) {
      out.writeln(target.path);
      continue;
    }

    // ---- 已就位就不重来 ----
    if (_verifyBytesIfPresent(target, member.sha256) == null) {
      resolved[name] = EnginePathEntry(
        kind: artifact.kind,
        path: target.path,
        sha256: member.sha256,
        bytes: member.bytes,
      );
      out.writeln(
        'engine-vendor  artifact=$name  runtime=$runtime  action=reuse  '
        'bytes=${member.bytes}  sha256=${_short(member.sha256)}  path=${_rel(root, target)}',
      );
      continue;
    }

    final archive = await _obtainArchive(
      artifact: artifact,
      cacheDir: Directory('$root/$kVendorCacheRoot'),
      fetch: fetch,
    );
    if (archive.error != null) {
      err.writeln(
        'engine-vendor  artifact=$name  status=download-failed  message=${archive.error}',
      );
      return ExitCodes.toolError;
    }

    final nupkgProblem = _verifyBytes(archive.bytes!, artifact.nupkgSha256, '整包');
    if (nupkgProblem != null) {
      err.writeln('engine-vendor  artifact=$name  status=digest-mismatch  message=$nupkgProblem');
      return ExitCodes.toolError;
    }

    final Uint8List memberBytes;
    try {
      memberBytes = readZipMember(archive.bytes!, member.path);
    } on FormatException catch (error) {
      err.writeln('engine-vendor  artifact=$name  status=extract-failed  message=${error.message}');
      return ExitCodes.toolError;
    }

    final memberProblem = _verifyBytes(memberBytes, member.sha256, '成员 ${member.path}');
    if (memberProblem != null) {
      err.writeln('engine-vendor  artifact=$name  status=digest-mismatch  message=$memberProblem');
      return ExitCodes.toolError;
    }

    target.parent.createSync(recursive: true);
    target.writeAsBytesSync(memberBytes, flush: true);
    resolved[name] = EnginePathEntry(
      kind: artifact.kind,
      path: target.path,
      sha256: member.sha256,
      bytes: memberBytes.length,
    );
    out.writeln(
      'engine-vendor  artifact=$name  runtime=$runtime  '
      'action=${archive.fromCache ? 'extract' : 'download'}  '
      'bytes=${memberBytes.length}  sha256=${_short(member.sha256)}  path=${_rel(root, target)}',
    );
  }

  if (!parsed.printPathOnly) {
    _writePathsFile(root: root, runtime: runtime, resolved: resolved, out: out);
    out.writeln(
      'engine-vendor  status=ok  runtime=$runtime  artifacts=${wanted.join(',')}  '
      'kind=${wanted.map((n) => '$n=${manifest.artifacts[n]!.kind}').join(' ')}',
    );
  }
  return ExitCodes.ok;
}

/// 写下 `<产物目录>/engine_paths.json`。消费方（测试、探针、CI 脚本）
/// 读它，不再自己算平台条目 —— 那会变成第二份真相。
void _writePathsFile({
  required String root,
  required String runtime,
  required Map<String, EnginePathEntry> resolved,
  required StringSink out,
}) {
  final file = File('$root/$kEngineOutputRoot/$kEnginePathsFileName');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    EnginePaths(runtime: runtime, repoRoot: root, artifacts: resolved, source: file.path).encode(),
    flush: true,
  );
  out.writeln('engine-vendor  paths-file=${_rel(root, file)}');
}

// -----------------------------------------------------------------------------
// 参数
// -----------------------------------------------------------------------------

const String _usage = '''
fetch_engine —— 取用定版的 SQLCipher / 纯 SQLite 原生库

用法：
  dart run tools/pf_cli/bin/fetch_engine.dart [选项]

选项：
  --artifact <name>   只取某一个（可重复）。缺省取清单里的全部。
  --runtime <id>      指定平台条目（如 win-x64 / osx-arm64）。缺省按当前平台推断。
  --print-path        只把落盘路径打出来（供 shell 取用），不下载。
                      **stdout 上只有这一行**，因此可以安全地用 \$( ) 接住。
  -h, --help          显示本帮助

清单：$kVendorManifestPath
产物：$kEngineOutputRoot/<runtime>/（不入库；build/ 已被 .gitignore 与 tracked_paths 拦住）
''';

final class _ParsedArgs {
  const _ParsedArgs({
    required this.artifacts,
    required this.runtime,
    required this.printPathOnly,
    required this.showHelp,
    required this.error,
  });

  final List<String> artifacts;
  final String? runtime;
  final bool printPathOnly;
  final bool showHelp;
  final String? error;

  static const _ParsedArgs help = _ParsedArgs(
    artifacts: <String>[],
    runtime: null,
    printPathOnly: false,
    showHelp: true,
    error: null,
  );

  static _ParsedArgs bad(String message) => _ParsedArgs(
    artifacts: const <String>[],
    runtime: null,
    printPathOnly: false,
    showHelp: false,
    error: message,
  );
}

_ParsedArgs _parseArgs(List<String> arguments) {
  final artifacts = <String>[];
  String? runtime;
  var printPath = false;
  for (var i = 0; i < arguments.length; i++) {
    final arg = arguments[i];
    switch (arg) {
      case '--artifact':
        if (i + 1 >= arguments.length) return _ParsedArgs.bad('--artifact 需要一个值');
        artifacts.add(arguments[++i]);
      case '--runtime':
        if (i + 1 >= arguments.length) return _ParsedArgs.bad('--runtime 需要一个值');
        runtime = arguments[++i];
      case '--print-path':
        printPath = true;
      case '-h':
      case '--help':
        return _ParsedArgs.help;
      default:
        return _ParsedArgs.bad('不认识的参数：$arg');
    }
  }
  return _ParsedArgs(
    artifacts: artifacts,
    runtime: runtime,
    printPathOnly: printPath,
    showHelp: false,
    error: null,
  );
}

// -----------------------------------------------------------------------------
// 平台
// -----------------------------------------------------------------------------

/// 当前平台在清单里的条目名。
///
/// 用 `Abi.current()` 而不是 `Platform.version` 去猜位数：
/// macOS 的 runner 已经是 arm64，而 `dart --version` 的输出
/// 在不同安装方式下并不一致。
String? currentRuntimeId() {
  final suffix = switch (Abi.current()) {
    Abi.macosArm64 || Abi.linuxArm64 || Abi.windowsArm64 => 'arm64',
    _ => 'x64',
  };
  return switch (Platform.operatingSystem) {
    'windows' => 'win-$suffix',
    'linux' => 'linux-$suffix',
    'macos' => 'osx-$suffix',
    _ => null,
  };
}

/// 仓库根 = 本脚本所在目录往上数三层（`bin` → `pf_cli` → `tools` → 根）。
String _repoRootFromScript() {
  var dir = File.fromUri(Platform.script).parent;
  for (var i = 0; i < 3; i++) {
    dir = dir.parent;
  }
  return dir.path;
}

String _leafOf(String memberPath) => memberPath.split('/').last;

String _rel(String root, File file) =>
    file.path.startsWith('$root/') ? file.path.substring(root.length + 1) : file.path;

String _short(String sha256) => '${sha256.substring(0, 16)}…';

// -----------------------------------------------------------------------------
// 校验
// -----------------------------------------------------------------------------

/// 校验一个已存在的文件。**返回 null 表示通过**（含"不存在即不通过"）。
String? _verifyBytesIfPresent(File file, String expectedSha256) {
  if (!file.existsSync()) return '文件不存在';
  return _verifyBytes(file.readAsBytesSync(), expectedSha256, file.path);
}

/// 校验字节。**返回 null 表示通过**，否则返回失败描述。
String? _verifyBytes(Uint8List bytes, String expectedSha256, String label) {
  final actual = Sha256.instance.hashHex(bytes);
  if (actual == expectedSha256) return null;
  return '$label 的 sha256 不符：期望 $expectedSha256，实际 $actual';
}

// -----------------------------------------------------------------------------
// 下载
// -----------------------------------------------------------------------------

final class _Archive {
  const _Archive({this.bytes, this.fromCache = false, this.error});

  final Uint8List? bytes;
  final bool fromCache;
  final String? error;
}

Future<_Archive> _obtainArchive({
  required _Artifact artifact,
  required Directory cacheDir,
  required Future<Uint8List> Function(Uri url) fetch,
}) async {
  final cached = File('${cacheDir.path}/${artifact.package}.${artifact.version}.nupkg');
  if (cached.existsSync()) {
    final bytes = cached.readAsBytesSync();
    if (_verifyBytes(bytes, artifact.nupkgSha256, '整包（缓存）') == null) {
      return _Archive(bytes: bytes, fromCache: true);
    }
    // 缓存坏了就删掉重下 —— 留着它只会让下一次也失败。
    cached.deleteSync();
  }

  try {
    final bytes = await fetch(Uri.parse(artifact.url));
    if (_verifyBytes(bytes, artifact.nupkgSha256, '整包') == null) {
      cacheDir.createSync(recursive: true);
      cached.writeAsBytesSync(bytes, flush: true);
    }
    return _Archive(bytes: bytes);
  } catch (error) {
    return _Archive(error: '$error');
  }
}

Future<Uint8List> _httpDownload(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final proxy = _proxyFromEnvironment();
    if (proxy != null) {
      client.findProxy = (Uri _) => 'PROXY $proxy';
    }
    final request = await client.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, 'pf-wallet-engine-vendor');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: url);
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  } finally {
    client.close();
  }
}

/// 从环境变量读 HTTP 代理。
///
/// `dart:io` 的 `HttpClient` **不会**自动读取 `*_proxy`（它默认 DIRECT），
/// 所以代理机器上必须显式接上，否则这个脚本在公司网络里会以
/// 「连接超时」失败 —— 一个与"清单写错了"完全无关的报错。
///
/// 只认 `http://host:port` 形式：`socks5://` 需要另一套握手，
/// 而把它当 `PROXY` 用会得到一个更难查的失败。认不出来就返回 null
/// （直连），让报错停留在"连不上"这一个事实上。
String? _proxyFromEnvironment() {
  const keys = <String>[
    'HTTPS_PROXY',
    'https_proxy',
    'HTTP_PROXY',
    'http_proxy',
    'ALL_PROXY',
    'all_proxy',
  ];
  for (final key in keys) {
    final raw = Platform.environment[key];
    if (raw == null || raw.isEmpty) continue;
    var value = raw;
    if (value.contains('://')) {
      if (!value.startsWith('http://')) continue;
      value = value.substring('http://'.length);
    }
    if (value.isEmpty) continue;
    return value;
  }
  return null;
}

// -----------------------------------------------------------------------------
// 清单
// -----------------------------------------------------------------------------

final class _Member {
  const _Member({required this.path, required this.bytes, required this.sha256});

  final String path;
  final int bytes;
  final String sha256;
}

final class _Artifact {
  const _Artifact({
    required this.package,
    required this.version,
    required this.kind,
    required this.nupkgSha256,
    required this.members,
    required this.url,
  });

  final String package;
  final String version;
  final String kind;
  final String nupkgSha256;
  final Map<String, _Member> members;
  final String url;
}

final class _Manifest {
  const _Manifest({required this.artifacts});

  final Map<String, _Artifact> artifacts;

  List<String> get artifactNames => artifacts.keys.toList()..sort();

  static _Manifest parse(String text) {
    final root = jsonDecode(text);
    if (root is! Map<String, Object?>) {
      throw const FormatException('根必须是一个 JSON 对象');
    }
    final source = root['source'];
    if (source is! Map<String, Object?>) {
      throw const FormatException('缺少 source');
    }
    final template = '${source['urlTemplate']}';

    final raw = root['artifacts'];
    if (raw is! Map<String, Object?>) {
      throw const FormatException('缺少 artifacts');
    }

    final artifacts = <String, _Artifact>{};
    raw.forEach((name, value) {
      if (value is! Map<String, Object?>) {
        throw FormatException('产物 "$name" 不是一个对象');
      }
      final membersRaw = value['members'];
      if (membersRaw is! Map<String, Object?>) {
        throw FormatException('产物 "$name" 缺少 members');
      }
      final members = <String, _Member>{};
      membersRaw.forEach((runtime, memberValue) {
        if (memberValue is! Map<String, Object?>) {
          throw FormatException('产物 "$name" 的 $runtime 条目不是一个对象');
        }
        final bytes = memberValue['bytes'];
        if (bytes is! int) {
          throw FormatException('产物 "$name" 的 $runtime 条目缺少整数 bytes');
        }
        members[runtime] = _Member(
          path: '${memberValue['path']}',
          bytes: bytes,
          sha256: '${memberValue['sha256']}',
        );
      });
      final package = '${value['package']}';
      final version = '${value['version']}';
      artifacts[name] = _Artifact(
        package: package,
        version: version,
        kind: '${value['kind']}',
        nupkgSha256: '${value['nupkgSha256']}',
        members: members,
        url: template.replaceAll('{package}', package).replaceAll('{version}', version),
      );
    });
    return _Manifest(artifacts: artifacts);
  }
}

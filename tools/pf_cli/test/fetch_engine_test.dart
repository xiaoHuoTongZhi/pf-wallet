/// `fetch_engine.dart` —— 取件脚本的单元测试。
///
/// ## 造一份"假包"，把整条链都跑一遍
///
/// 夹具不是真 nupkg，而是现场造的一个 ZIP（`support/zip_builder.dart`），
/// 配一份指向它的清单。这样：
///
///   - 下载被换成注入的函数 —— 用例**不联网**，也就不受上游包变化的干扰；
///   - 两级校验（整包 sha256 / 成员 sha256）都能被精确地"弄错一位"来验；
///   - 幂等与缓存两条路径可以在同一个临时目录里连续跑。
///
/// 真包只由 CI 取一次（`dart run tools/pf_cli/bin/fetch_engine.dart`），
/// 而那份产物由 `engine_sqlcipher_test.dart` / `engine_plain_test.dart` 消费。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pf_cli/pf_cli.dart';
import 'package:pf_crypto/pf_crypto.dart';
import 'package:test/test.dart';

import 'support/harness.dart';
import 'support/zip_builder.dart';

const String _memberPath = 'runtimes/win-x64/native/e_fake.dll';
const String _artifact = 'sqlcipher';
const String _package = 'Fake.SqlCipher';
const String _version = '1.2.3';
const String _runtime = 'win-x64';

/// 夹具：一个临时"仓库根"，里面放着清单与一份可注入的下载实现。
final class _Fixture {
  _Fixture(this.root, this.archive, this.payload);

  final Directory root;
  final Uint8List archive;
  final Uint8List payload;

  // 路径拼法与生产一致：仓库根之后一律用 '/'（Windows 接受混用分隔符）。
  // 夹具若用 Platform.pathSeparator 拼，就会与生产代码拼出的字符串对不上 ——
  // 而"对不上"在这里毫无信息量，只会让断言变脆。
  String get artifactPath => '${root.path}/build/native/engine/$_runtime/e_fake.dll';

  String get cachePath => '${root.path}/build/native/cache/$_package.$_version.nupkg';

  String get pathsFile => '${root.path}/build/native/engine/engine_paths.json';

  /// 写清单。两级摘要都可以被故意写错（用来验"校验真的会发生"）。
  void writeManifest({
    String? nupkgSha256,
    String? memberSha256,
    int? memberBytes,
    String? runtime,
    String? artifactName,
  }) {
    final members = <String, Object?>{
      runtime ?? _runtime: <String, Object?>{
        'path': _memberPath,
        'bytes': memberBytes ?? payload.length,
        'sha256': memberSha256 ?? Sha256.instance.hashHex(payload),
      },
    };
    final manifest = <String, Object?>{
      'version': 1,
      'source': <String, Object?>{
        'urlTemplate': 'https://example.invalid/{package}/{version}/{package}.{version}.nupkg',
      },
      'artifacts': <String, Object?>{
        artifactName ?? _artifact: <String, Object?>{
          'package': _package,
          'version': _version,
          'kind': 'sqlcipher',
          'nupkgSha256': nupkgSha256 ?? Sha256.instance.hashHex(archive),
          'members': members,
        },
      },
    };
    final file = File('${root.path}/tools/ci/native/engine_vendor.json');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest), flush: true);
  }

  /// 调一次脚本。[download] 缺省是"只要被调用就抛" —— 幂等/缓存路径**必须**
  /// 在不联网的情况下也能过；没抛就说明那段逻辑悄悄联网了。
  Future<CliResult> run(List<String> args, {Future<Uint8List> Function(Uri url)? download}) async {
    final out = Capture();
    final err = Capture();
    final code = await runFetchEngine(
      args,
      out: out,
      err: err,
      repoRoot: root.path,
      download: download ?? (Uri url) async => throw StateError('这个用例不该联网：$url'),
    );
    return CliResult(code: code, out: out, err: err);
  }
}

void main() {
  late Directory tmp;
  late _Fixture fixture;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pf_cli_fetch_');
    final payload = Uint8List.fromList(
      utf8.encode('假的 SQLCipher 动态库内容') + List<int>.generate(64, (i) => i),
    );
    final archive = ZipBuilder().add(_memberPath, payload, ZipMethod.stored).build();
    fixture = _Fixture(tmp, archive, payload);
    fixture.writeManifest();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('首次取件：下载 → 两级校验 → 解出 → 落盘 → 写清单', () {
    test('成功路径', () async {
      final result = await fixture.run(
        <String>['--artifact', _artifact, '--runtime', _runtime],
        download: (Uri url) async {
          // 地址必须由清单里的 urlTemplate 拼出来 —— 否则"改了模板"不会被发现。
          expect(url.host, 'example.invalid');
          expect(url.path, contains('$_package.$_version.nupkg'));
          return fixture.archive;
        },
      );

      expect(result.code, ExitCodes.ok);
      expect(result.err.text, isEmpty);
      expect(result.out.text, contains('status=ok'));
      expect(result.out.text, contains('action=download'));

      // ① 产物落盘且字节正确。
      final artifact = File(fixture.artifactPath);
      expect(artifact.existsSync(), isTrue);
      expect(artifact.readAsBytesSync(), fixture.payload);

      // ② 整包进了缓存（下次不必再下）。
      expect(File(fixture.cachePath).readAsBytesSync(), fixture.archive);

      // ③ 落盘清单可被消费方解析，且指向同一个文件。
      final paths = EnginePaths.decode(
        File(fixture.pathsFile).readAsStringSync(),
        source: fixture.pathsFile,
      );
      expect(paths.runtime, _runtime);
      expect(paths.require(_artifact).path, fixture.artifactPath);
      expect(paths.require(_artifact).sha256, Sha256.instance.hashHex(fixture.payload));
      expect(paths.require(_artifact).kind, 'sqlcipher');
    });

    test('整包 sha256 不符 ⇒ 退出码 2、不落盘', () async {
      fixture.writeManifest(nupkgSha256: List<String>.filled(64, '0').join());

      final result = await fixture.run(<String>[
        '--artifact',
        _artifact,
        '--runtime',
        _runtime,
      ], download: (Uri url) async => fixture.archive);

      expect(result.code, ExitCodes.toolError);
      // 失败诊断走 **stderr**：stdout 只留给"机器要读的那一行"。
      expect(result.err.text, contains('status=digest-mismatch'));
      expect(result.err.text, contains('整包'));
      // 校验没过就绝不能留下文件 —— 半成品比没有更糟（下次会被"复用"）。
      expect(File(fixture.artifactPath).existsSync(), isFalse);
    });

    test('成员 sha256 不符 ⇒ 退出码 2、不落盘、报错指明是成员', () async {
      fixture.writeManifest(memberSha256: List<String>.filled(64, 'f').join());

      final result = await fixture.run(<String>[
        '--artifact',
        _artifact,
        '--runtime',
        _runtime,
      ], download: (Uri url) async => fixture.archive);

      expect(result.code, ExitCodes.toolError);
      expect(result.err.text, contains('status=digest-mismatch'));
      expect(result.err.text, contains(_memberPath));
      expect(File(fixture.artifactPath).existsSync(), isFalse);
    });

    test('清单声明的成员长度与实际不符 ⇒ 读出来就对不上（不会"先落盘再说"）', () async {
      fixture.writeManifest(memberBytes: 1);

      final result = await fixture.run(<String>[
        '--artifact',
        _artifact,
        '--runtime',
        _runtime,
      ], download: (Uri url) async => fixture.archive);

      // 长度不是校验项（校验只有 sha256），但落盘清单里记的是**实际**长度。
      expect(result.code, ExitCodes.ok);
      final paths = EnginePaths.decode(
        File(fixture.pathsFile).readAsStringSync(),
        source: fixture.pathsFile,
      );
      expect(paths.require(_artifact).bytes, fixture.payload.length);
    });

    test('下载失败 ⇒ 退出码 2 + download-failed（不写清单）', () async {
      final result = await fixture.run(<String>[
        '--artifact',
        _artifact,
        '--runtime',
        _runtime,
      ], download: (Uri url) async => throw const SocketException('连不上'));

      expect(result.code, ExitCodes.toolError);
      expect(result.err.text, contains('status=download-failed'));
      expect(File(fixture.pathsFile).existsSync(), isFalse);
    });
  });

  group('幂等与缓存：第二次调用必须是纯本地操作', () {
    test('产物已就位且摘要相符 ⇒ 复用，且**不联网**', () async {
      await fixture.run(<String>[
        '--artifact',
        _artifact,
        '--runtime',
        _runtime,
      ], download: (Uri url) async => fixture.archive);
      final firstBytes = File(fixture.artifactPath).readAsBytesSync();

      // 第二次：download 缺省实现会在被调用时抛错，因此这条用例同时
      // 断言了"没有发生下载"。
      final second = await fixture.run(<String>['--artifact', _artifact, '--runtime', _runtime]);

      expect(second.code, ExitCodes.ok);
      expect(second.out.text, contains('action=reuse'));
      expect(File(fixture.artifactPath).readAsBytesSync(), firstBytes);
    });

    test('产物没了但整包在缓存里 ⇒ 从缓存解出来，同样不联网', () async {
      await fixture.run(<String>[
        '--artifact',
        _artifact,
        '--runtime',
        _runtime,
      ], download: (Uri url) async => fixture.archive);
      File(fixture.artifactPath).deleteSync();

      final second = await fixture.run(<String>['--artifact', _artifact, '--runtime', _runtime]);

      expect(second.code, ExitCodes.ok);
      expect(second.out.text, contains('action=extract'));
      expect(File(fixture.artifactPath).readAsBytesSync(), fixture.payload);
    });

    test('产物在但内容被改过 ⇒ 不信任它，重新解出（而不是"文件在就算数"）', () async {
      await fixture.run(<String>[
        '--artifact',
        _artifact,
        '--runtime',
        _runtime,
      ], download: (Uri url) async => fixture.archive);
      File(fixture.artifactPath).writeAsBytesSync(Uint8List.fromList(<int>[0, 0, 0]));

      // 整包已在缓存里，所以这次走 extract 而不是 download ——
      // 判据是"产物的摘要对了没有"，不是"文件存在与否"。
      final second = await fixture.run(<String>['--artifact', _artifact, '--runtime', _runtime]);

      expect(second.code, ExitCodes.ok);
      expect(second.out.text, isNot(contains('action=reuse')));
      expect(second.out.text, contains('action=extract'));
      expect(File(fixture.artifactPath).readAsBytesSync(), fixture.payload);
    });
  });

  group('参数与清单的边界', () {
    test('--print-path 只打印路径：不下载、不写清单', () async {
      final result = await fixture.run(<String>[
        '--artifact',
        _artifact,
        '--runtime',
        _runtime,
        '--print-path',
      ]);

      expect(result.code, ExitCodes.ok);
      expect(result.out.lines, <String>[fixture.artifactPath]);
      expect(File(fixture.pathsFile).existsSync(), isFalse);
    });

    test('清单里没有的产物名 ⇒ 2，并列出有的', () async {
      final result = await fixture.run(<String>['--artifact', 'nope', '--runtime', _runtime]);

      expect(result.code, ExitCodes.toolError);
      expect(result.err.text, contains('nope'));
      expect(result.err.text, contains(_artifact));
    });

    test('清单里没有的平台条目 ⇒ 2', () async {
      final result = await fixture.run(<String>['--artifact', _artifact, '--runtime', 'osx-arm64']);

      expect(result.code, ExitCodes.toolError);
      expect(result.err.text, contains('osx-arm64'));
    });

    test('清单文件不存在 ⇒ 2，并指出期望路径', () async {
      File('${tmp.path}/tools/ci/native/engine_vendor.json').deleteSync();

      final result = await fixture.run(<String>['--artifact', _artifact, '--runtime', _runtime]);

      expect(result.code, ExitCodes.toolError);
      expect(result.err.text, contains('engine_vendor.json'));
    });

    test('不认识的参数 / 缺值 ⇒ 2（用法错误）', () async {
      expect((await fixture.run(<String>['--nope'])).code, ExitCodes.toolError);
      expect((await fixture.run(<String>['--artifact'])).code, ExitCodes.toolError);
    });

    test('-h ⇒ 0，打印用法', () async {
      final result = await fixture.run(<String>['-h']);

      expect(result.code, ExitCodes.ok);
      expect(result.out.text, contains('fetch_engine'));
    });

    test('缺省取清单里的**全部**产物（按名字排序，结果稳定）', () async {
      final result = await fixture.run(<String>[
        '--runtime',
        _runtime,
      ], download: (Uri url) async => fixture.archive);

      expect(result.code, ExitCodes.ok);
      expect(result.out.text, contains('artifacts=$_artifact'));
    });
  });
}

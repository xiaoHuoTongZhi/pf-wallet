import 'package:pf_guards/glob.dart';
import 'package:test/test.dart';

void main() {
  group('globToRegExp', () {
    test('`*` 不跨越目录分隔符', () {
      final regex = globToRegExp('apps/*/lib/*.dart');
      expect(regex.hasMatch('apps/mobile/lib/main.dart'), isTrue);
      expect(regex.hasMatch('apps/mobile/other/lib/main.dart'), isFalse);
      expect(regex.hasMatch('apps/mobile/lib/sub/main.dart'), isFalse);
    });

    test('`**` 跨越目录分隔符', () {
      expect(globToRegExp('apps/**').hasMatch('apps/a/b/c.dart'), isTrue);
      expect(globToRegExp('apps/**').hasMatch('packages/a.dart'), isFalse);
      expect(
        globToRegExp('packages/**/*.dart').hasMatch('packages/pf_core/lib/src/money.dart'),
        isTrue,
      );
    });

    test('`**/` 可匹配零层目录', () {
      final regex = globToRegExp('**/*_test.dart');
      expect(regex.hasMatch('money_test.dart'), isTrue);
      expect(regex.hasMatch('packages/pf_core/test/money_test.dart'), isTrue);
      expect(regex.hasMatch('packages/pf_core/test/money.dart'), isFalse);
    });

    test('`?` 匹配单个非分隔符字符', () {
      final regex = globToRegExp('a?c.dart');
      expect(regex.hasMatch('abc.dart'), isTrue);
      expect(regex.hasMatch('ac.dart'), isFalse);
      expect(regex.hasMatch('a/c.dart'), isFalse);
    });

    test('正则元字符被转义为字面量', () {
      final regex = globToRegExp('tools/guards/bin/guards.dart');
      expect(regex.hasMatch('tools/guards/bin/guards.dart'), isTrue);
      expect(regex.hasMatch('toolsXguardsXbinXguardsXdart'), isFalse);
      // `.` 必须当字面点，不能当通配
      expect(globToRegExp('a.dart').hasMatch('aXdart'), isFalse);
    });

    test('大小写敏感', () {
      expect(globToRegExp('Readme.md').hasMatch('readme.md'), isFalse);
    });

    test('完整路径锚定：不会匹配后缀相同的长路径', () {
      final regex = globToRegExp('pubspec.yaml');
      expect(regex.hasMatch('pubspec.yaml'), isTrue);
      expect(regex.hasMatch('apps/pf_mobile/pubspec.yaml'), isFalse);
    });
  });

  group('PathMatcher', () {
    test('空集合永不匹配', () {
      final matcher = PathMatcher();
      expect(matcher.isEmpty, isTrue);
      expect(matcher.matches('anything.dart'), isFalse);
    });

    test('任一模式命中即匹配，并可通过 matchedPattern 回溯', () {
      final matcher = PathMatcher(<String>['apps/**', 'packages/**']);
      expect(matcher.matches('packages/pf_core/lib/pf_core.dart'), isTrue);
      expect(matcher.matchedPattern('packages/pf_core/lib/pf_core.dart'), 'packages/**');
      expect(matcher.matches('tools/guards/bin/guards.dart'), isFalse);
      expect(matcher.matchedPattern('tools/guards/bin/guards.dart'), isNull);
    });
  });
}

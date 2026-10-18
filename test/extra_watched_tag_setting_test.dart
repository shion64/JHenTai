import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/setting/extra_watched_tag_setting.dart';

void main() {
  group('ExtraWatchedTagSetting', () {
    late ExtraWatchedTagSetting setting;

    setUp(() {
      setting = ExtraWatchedTagSetting();
      setting.applyBeanConfig(
        '{"tags":["Artist:some_tag", "artist:Some Tag", 7, ":invalid", "bad:"]}',
      );
    });

    test('matches tag names case-insensitively', () {
      expect(setting.contains('ARTIST', 'SOME_TAG'), isTrue);
      expect(setting.contains('artist', 'some tag'), isTrue);
    });

    test('normalizes duplicate values when restoring configuration', () {
      expect(setting.tags.toList(), <String>['Artist:some_tag']);
    });

    test('rejects malformed or normalized duplicate additions', () async {
      expect(await setting.addTag('not-a-namespaced-tag'), isFalse);
      expect(await setting.addTag('artist:some tag'), isFalse);
    });

    test('does not match unrelated tags', () {
      expect(setting.contains('artist', 'another_tag'), isFalse);
    });

    test('keeps colons that belong to the key', () {
      setting.applyBeanConfig('{"tags":["other:foo: bar"]}');

      expect(setting.tags.toList(), <String>['other:foo: bar']);
      expect(setting.contains('other', 'foo: bar'), isTrue);
      expect(setting.contains('other', 'foo'), isFalse);
    });

    test('ignores whitespace differences', () {
      setting.applyBeanConfig('{"tags":["artist:  big   breasts "]}');

      expect(setting.tags.toList(), <String>['artist:big   breasts']);
      expect(setting.contains('artist', 'Big_Breasts'), isTrue);
    });

    test('clears the tags when the stored configuration has an unexpected shape', () {
      setting.applyBeanConfig('{"tags":"artist:alp"}');

      expect(setting.tags, isEmpty);
      expect(setting.contains('artist', 'some tag'), isFalse);
    });
  });
}

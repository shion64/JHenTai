import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';

import '../service/jh_service.dart';

ExtraWatchedTagSetting extraWatchedTagSetting = ExtraWatchedTagSetting();

/// Locally stored watched tags that are merged into the Watched page.
///
/// The online watched tag list of E-Hentai is limited (100 tags without a paid plan),
/// so these tags are kept only on this device and searched by the app itself.
class ExtraWatchedTagSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  /// format: `namespace:key`, e.g. `artist:alp`. Only the first `:` separates the namespace from the key.
  RxList<String> tags = <String>[].obs;

  /// Normalized tags are cached so rendering many tag chips stays O(1) per lookup.
  final Set<String> _normalizedTags = <String>{};

  static final RegExp _spaces = RegExp(r'\s+');

  /// Splits `namespace:key` at the first `:`. Returns null if either side is empty.
  static ({String namespace, String key})? _split(String tag) {
    final int separator = tag.indexOf(':');
    if (separator <= 0 || separator == tag.length - 1) {
      return null;
    }

    final String namespace = tag.substring(0, separator).trim();
    final String key = tag.substring(separator + 1).trim();
    if (namespace.isEmpty || key.isEmpty) {
      return null;
    }
    return (namespace: namespace, key: key);
  }

  /// The tag as it is stored: trimmed, but with the original case and spelling.
  static String? _cleanTag(String tag) {
    final ({String namespace, String key})? parts = _split(tag);
    return parts == null ? null : '${parts.namespace}:${parts.key}';
  }

  static String _normalizePart(String value) => value.toLowerCase().replaceAll('_', ' ').replaceAll(_spaces, ' ').trim();

  /// The tag as it is compared: ignoring case, `_`/space differences and repeated spaces.
  static String? _normalizeFullTag(String tag) {
    final ({String namespace, String key})? parts = _split(tag);
    if (parts == null) {
      return null;
    }

    final String namespace = _normalizePart(parts.namespace);
    final String key = _normalizePart(parts.key);
    if (namespace.isEmpty || key.isEmpty) {
      return null;
    }
    return '$namespace:$key';
  }

  void _rebuildNormalizedTags() {
    _normalizedTags
      ..clear()
      ..addAll(tags.map(_normalizeFullTag).whereType<String>());
  }

  /// Whether this tag is registered, ignoring case and `_`/space differences.
  bool contains(String namespace, String key) {
    final String? normalized = _normalizeFullTag('$namespace:$key');
    return normalized != null && _normalizedTags.contains(normalized);
  }

  @override
  ConfigEnum get configEnum => ConfigEnum.extraWatchedTagSetting;

  @override
  void applyBeanConfig(String configString) {
    final Object? decoded = jsonDecode(configString);
    if (decoded is Map && decoded['tags'] is List) {
      final List<String> restoredTags = <String>[];
      final Set<String> seen = <String>{};
      for (final Object? rawTag in decoded['tags'] as List) {
        if (rawTag is! String) {
          continue;
        }
        final String? cleaned = _cleanTag(rawTag);
        final String? normalized = cleaned == null ? null : _normalizeFullTag(cleaned);
        if (cleaned != null && normalized != null && seen.add(normalized)) {
          restoredTags.add(cleaned);
        }
      }
      tags.value = restoredTags;
    } else {
      tags.clear();
    }
    _rebuildNormalizedTags();
  }

  @override
  String toConfigString() {
    return jsonEncode({'tags': tags.toList()});
  }

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  /// Returns false if the tag is malformed or already registered.
  Future<bool> addTag(String tag) async {
    final String? cleaned = _cleanTag(tag);
    final String? normalized = cleaned == null ? null : _normalizeFullTag(cleaned);
    if (cleaned == null || normalized == null || _normalizedTags.contains(normalized)) {
      return false;
    }

    tags.add(cleaned);
    _rebuildNormalizedTags();
    await saveBeanConfig();
    return true;
  }

  Future<void> removeTag(String tag) async {
    final String? normalized = _normalizeFullTag(tag);
    if (normalized == null) {
      return;
    }

    final int index = tags.indexWhere((savedTag) => _normalizeFullTag(savedTag) == normalized);
    if (index < 0) {
      return;
    }

    tags.removeAt(index);
    _rebuildNormalizedTags();
    await saveBeanConfig();
  }
}

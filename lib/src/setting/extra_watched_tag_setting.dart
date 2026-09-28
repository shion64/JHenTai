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
  /// format: `namespace:key`, e.g. `artist:alp`
  RxList<String> tags = <String>[].obs;

  @override
  ConfigEnum get configEnum => ConfigEnum.extraWatchedTagSetting;

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);
    tags.value = (map['tags'] as List).cast<String>();
  }

  @override
  String toConfigString() {
    return jsonEncode({'tags': tags.toList()});
  }

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  Future<bool> addTag(String tag) async {
    String normalized = tag.trim();
    if (!normalized.contains(':') || normalized.startsWith(':') || normalized.endsWith(':')) {
      return false;
    }
    if (tags.contains(normalized)) {
      return false;
    }
    tags.add(normalized);
    await saveBeanConfig();
    return true;
  }

  Future<void> removeTag(String tag) async {
    tags.remove(tag);
    await saveBeanConfig();
  }
}

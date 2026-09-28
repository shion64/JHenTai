import 'dart:convert';
import 'dart:math';

import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/pages/watched/watched_page_state.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/setting/extra_watched_tag_setting.dart';
import 'package:jhentai/src/utils/eh_spider_parser.dart';

import '../../enum/config_enum.dart';
import '../../model/search_config.dart';
import '../../service/local_config_service.dart';
import '../base/base_page_logic.dart';

class WatchedPageLogic extends BasePageLogic {
  /// how many pages are loaded for each extra watched tag
  static const int _extraPagesPerTag = 3;

  /// how many tags are requested at the same time
  static const int _extraConcurrency = 3;

  static const Duration _extraCacheTtl = Duration(minutes: 10);

  List<Gallery>? _extraGalleriesCache;
  List<String>? _extraGalleriesCacheTags;
  DateTime? _extraGalleriesCacheTime;

  @override
  bool get useSearchConfig => true;

  @override
  bool get autoLoadNeedLogin => true;

  @override
  final WatchedPageState state = WatchedPageState();

  @override
  Future<void> saveSearchConfig(SearchConfig searchConfig) async {
    await localConfigService.write(
      configKey: ConfigEnum.searchConfig,
      subConfigKey: searchConfigKey,
      value: jsonEncode(searchConfig.copyWith(keyword: '', tags: [])),
    );
  }

  /// Merge galleries of locally stored extra watched tags into the official watched result by publish time.
  @override
  Future<GalleryPageInfo> getGalleryPage({String? prevGid, String? nextGid, DateTime? seek}) async {
    GalleryPageInfo official = await super.getGalleryPage(prevGid: prevGid, nextGid: nextGid, seek: seek);

    List<String> extraTags = extraWatchedTagSetting.tags.toList();
    if (extraTags.isEmpty || official.galleries.isEmpty) {
      return official;
    }

    List<Gallery> extraGalleries;
    try {
      bool isFirstPage = prevGid == null && nextGid == null && seek == null;
      extraGalleries = await _loadExtraGalleries(extraTags, forceRefresh: isFirstPage);
    } catch (e) {
      log.warning('Load extra watched galleries failed', e, true);
      return official;
    }

    /// The official result is paged by cursor, so only the extra galleries which fall into the time range of
    /// this page are merged in. The newest page has no upper bound and the oldest page has no lower bound.
    List<String> times = official.galleries.map((g) => g.publishTime).toList()..sort();
    String oldest = times.first;
    String newest = times.last;
    bool hasNewerPage = official.prevGid != null;
    bool hasOlderPage = official.nextGid != null;

    Set<int> officialGids = official.galleries.map((g) => g.galleryUrl.gid).toSet();
    List<Gallery> extrasInRange = extraGalleries.where((g) {
      if (officialGids.contains(g.galleryUrl.gid)) {
        return false;
      }
      if (hasOlderPage && g.publishTime.compareTo(oldest) < 0) {
        return false;
      }
      if (hasNewerPage && g.publishTime.compareTo(newest) > 0) {
        return false;
      }
      return true;
    }).toList();

    if (extrasInRange.isEmpty) {
      return official;
    }

    List<Gallery> merged = [...official.galleries, ...extrasInRange]..sort((a, b) => b.publishTime.compareTo(a.publishTime));

    return GalleryPageInfo(
      galleries: merged,
      favoriteSortOrder: official.favoriteSortOrder,
      totalCount: official.totalCount,
      prevGid: official.prevGid,
      nextGid: official.nextGid,
    );
  }

  Future<List<Gallery>> _loadExtraGalleries(List<String> tags, {required bool forceRefresh}) async {
    bool cacheValid = _extraGalleriesCache != null &&
        _extraGalleriesCacheTime != null &&
        DateTime.now().difference(_extraGalleriesCacheTime!) < _extraCacheTtl &&
        _extraGalleriesCacheTags?.join('\n') == tags.join('\n');

    if (!forceRefresh && cacheValid) {
      return _extraGalleriesCache!;
    }

    Map<int, Gallery> galleries = {};

    for (int i = 0; i < tags.length; i += _extraConcurrency) {
      List<String> chunk = tags.sublist(i, min(i + _extraConcurrency, tags.length));
      List<List<Gallery>> results = await Future.wait(chunk.map(_loadGalleriesOfTag));
      for (Gallery gallery in results.expand((e) => e)) {
        galleries[gallery.galleryUrl.gid] = gallery;
      }
    }

    _extraGalleriesCache = galleries.values.toList();
    _extraGalleriesCacheTags = tags;
    _extraGalleriesCacheTime = DateTime.now();
    return _extraGalleriesCache!;
  }

  Future<List<Gallery>> _loadGalleriesOfTag(String tag) async {
    int index = tag.indexOf(':');
    String namespace = tag.substring(0, index);
    String key = tag.substring(index + 1);

    /// exact match
    SearchConfig searchConfig = SearchConfig(keyword: '$namespace:"$key\$"');

    List<Gallery> result = [];
    String? nextGid;
    try {
      for (int page = 0; page < _extraPagesPerTag; page++) {
        GalleryPageInfo pageInfo = await ehRequest.requestGalleryPage(
          nextGid: nextGid,
          searchConfig: searchConfig,
          parser: EHSpiderParser.galleryPage2GalleryPageInfo,
        );
        result.addAll(pageInfo.galleries);
        nextGid = pageInfo.nextGid;
        if (nextGid == null) {
          break;
        }
      }
    } catch (e) {
      log.warning('Load galleries of extra watched tag $tag failed', e, true);
    }
    return result;
  }
}

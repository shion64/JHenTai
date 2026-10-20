import 'dart:convert';
import 'dart:math';

import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/pages/watched/watched_page_state.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/setting/extra_watched_tag_setting.dart';
import 'package:jhentai/src/utils/eh_spider_parser.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';

import '../../enum/config_enum.dart';
import '../../model/search_config.dart';
import '../../service/local_config_service.dart';
import '../base/base_page_logic.dart';

class WatchedPageLogic extends BasePageLogic {
  /// How many pages are loaded per extra watched tag while only a few tags are registered.
  /// With many tags only the newest page of each tag is loaded to keep the number of requests low.
  static const int _extraPagesPerTagFew = 3;
  static const int _extraFewTagsThreshold = 20;

  /// how many tags are requested at the same time, and the pause between two batches
  static const int _extraConcurrency = 3;
  static const Duration _extraChunkInterval = Duration(milliseconds: 300);

  static const Duration _extraCacheTtl = Duration(minutes: 10);

  /// How long a page waits for the extra galleries. After that the official result is shown right away
  /// and the extra galleries are merged into the list as soon as they are ready.
  static const Duration _extraWaitBudget = Duration(seconds: 6);

  List<Gallery>? _extraGalleriesCache;
  List<String>? _extraGalleriesCacheTags;
  DateTime? _extraGalleriesCacheTime;

  Future<List<Gallery>>? _extraGalleriesLoading;
  List<String>? _extraGalleriesLoadingTags;

  /// set by pull-to-refresh so that the extra galleries are loaded again instead of served from the cache
  bool _forceExtraRefresh = false;

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

  @override
  Future<void> handleRefresh({String? updateId}) {
    _forceExtraRefresh = true;
    return super.handleRefresh(updateId: updateId);
  }

  @override
  Future<void> handleClearAndRefresh() {
    _forceExtraRefresh = true;
    return super.handleClearAndRefresh();
  }

  /// Merge galleries of locally stored extra watched tags into the official watched result by publish time.
  @override
  Future<GalleryPageInfo> getGalleryPage({String? prevGid, String? nextGid, DateTime? seek}) async {
    GalleryPageInfo official = await super.getGalleryPage(prevGid: prevGid, nextGid: nextGid, seek: seek);

    List<String> extraTags = extraWatchedTagSetting.tags.toList();
    if (extraTags.isEmpty) {
      return official;
    }

    bool isFirstPage = prevGid == null && nextGid == null && seek == null;
    if (official.galleries.isEmpty && !isFirstPage) {
      return official;
    }

    bool refresh = false;
    if (isFirstPage) {
      refresh = _forceExtraRefresh;
      _forceExtraRefresh = false;
    }

    List<Gallery>? extraGalleries = await _getExtraGalleries(extraTags, refresh: refresh);
    if (extraGalleries == null || extraGalleries.isEmpty) {
      return official;
    }

    List<Gallery> extras;
    if (official.galleries.isEmpty) {
      /// There is no time range to merge into: show the local results on the initial page.
      extras = extraGalleries;
    } else {
      extras = _pickExtrasInRange(
        extraGalleries,
        official.galleries,
        hasNewerPage: official.prevGid != null,
        hasOlderPage: official.nextGid != null,
      );
    }
    if (extras.isEmpty) {
      return official;
    }

    List<Gallery> merged = [...official.galleries, ...extras]..sort((a, b) => b.publishTime.compareTo(a.publishTime));

    return GalleryPageInfo(
      galleries: merged,
      favoriteSortOrder: official.favoriteSortOrder,
      totalCount: official.totalCount,
      prevGid: official.prevGid,
      nextGid: official.nextGid,
    );
  }

  /// Extra galleries (not shown yet) which belong into the time range covered by [pageGalleries].
  /// The newest page has no upper bound and the oldest page has no lower bound.
  List<Gallery> _pickExtrasInRange(
    List<Gallery> extras,
    List<Gallery> pageGalleries, {
    required bool hasNewerPage,
    required bool hasOlderPage,
  }) {
    Set<int> shownGids = pageGalleries.map((g) => g.galleryUrl.gid).toSet();
    List<Gallery> candidates = extras.where((g) => !shownGids.contains(g.galleryUrl.gid)).toList();

    if (pageGalleries.isEmpty) {
      return hasNewerPage || hasOlderPage ? [] : candidates;
    }

    List<String> times = pageGalleries.map((g) => g.publishTime).toList()..sort();
    String oldest = times.first;
    String newest = times.last;

    return candidates.where((g) {
      if (hasOlderPage && g.publishTime.compareTo(oldest) < 0) {
        return false;
      }
      if (hasNewerPage && g.publishTime.compareTo(newest) > 0) {
        return false;
      }
      return true;
    }).toList();
  }

  bool _hasCacheForTags(List<String> tags) {
    return _extraGalleriesCache != null && _extraGalleriesCacheTags?.join('\n') == tags.join('\n');
  }

  bool _isCacheValid(List<String> tags) {
    return _hasCacheForTags(tags) && _extraGalleriesCacheTime != null && DateTime.now().difference(_extraGalleriesCacheTime!) < _extraCacheTtl;
  }

  /// Returns null if the extra galleries are not available within [_extraWaitBudget]; in that case they are
  /// merged into the already shown list later by [_mergeLateExtraGalleries].
  Future<List<Gallery>?> _getExtraGalleries(List<String> tags, {required bool refresh}) async {
    if (!refresh && _isCacheValid(tags)) {
      return _extraGalleriesCache;
    }

    Future<List<Gallery>> loading = _startLoadingExtraGalleries(tags);
    List<Gallery>? loaded = await loading.then<List<Gallery>?>((galleries) => galleries).timeout(_extraWaitBudget, onTimeout: () => null);
    if (loaded != null) {
      return loaded;
    }

    loading.then((_) => _mergeLateExtraGalleries());

    /// An outdated result of the same tags is still better than nothing.
    return _hasCacheForTags(tags) ? _extraGalleriesCache : null;
  }

  /// Requests for the same tags share one running load.
  Future<List<Gallery>> _startLoadingExtraGalleries(List<String> tags) {
    if (_extraGalleriesLoading != null && _extraGalleriesLoadingTags?.join('\n') == tags.join('\n')) {
      return _extraGalleriesLoading!;
    }

    Future<List<Gallery>> loading = _loadExtraGalleries(tags);
    _extraGalleriesLoading = loading;
    _extraGalleriesLoadingTags = tags;
    loading.whenComplete(() {
      if (identical(_extraGalleriesLoading, loading)) {
        _extraGalleriesLoading = null;
        _extraGalleriesLoadingTags = null;
      }
    });
    return loading;
  }

  /// Never throws: failures of single tags only shorten the result.
  Future<List<Gallery>> _loadExtraGalleries(List<String> tags) async {
    int pagesPerTag = tags.length <= _extraFewTagsThreshold ? _extraPagesPerTagFew : 1;
    Map<int, Gallery> galleries = {};
    int failedTags = 0;

    try {
      for (int i = 0; i < tags.length; i += _extraConcurrency) {
        List<String> chunk = tags.sublist(i, min(i + _extraConcurrency, tags.length));
        List<List<Gallery>?> results = await Future.wait(chunk.map((tag) => _loadGalleriesOfTag(tag, pagesPerTag)));

        int failedInChunk = 0;
        for (List<Gallery>? result in results) {
          if (result == null) {
            failedInChunk++;
            continue;
          }
          for (Gallery gallery in result) {
            galleries[gallery.galleryUrl.gid] = gallery;
          }
        }
        failedTags += failedInChunk;

        /// Offline or temporarily blocked: don't keep sending requests.
        if (failedInChunk == chunk.length) {
          log.warning('Stop loading extra watched galleries because a whole batch of tags failed');
          break;
        }

        if (i + _extraConcurrency < tags.length) {
          await Future.delayed(_extraChunkInterval);
        }
      }
    } catch (e) {
      log.warning('Load extra watched galleries failed', e, true);
    }

    List<Gallery> result = galleries.values.toList();

    /// Don't cache a result which only consists of failures, so that the next load tries again.
    if (result.isNotEmpty || failedTags == 0) {
      _extraGalleriesCache = result;
      _extraGalleriesCacheTags = tags;
      _extraGalleriesCacheTime = DateTime.now();
    }
    return result;
  }

  /// Returns null if the first page of the tag could not be loaded.
  Future<List<Gallery>?> _loadGalleriesOfTag(String tag, int pages) async {
    int index = tag.indexOf(':');
    String namespace = tag.substring(0, index);
    String key = tag.substring(index + 1);

    /// exact match
    SearchConfig searchConfig = SearchConfig(keyword: '$namespace:"$key\$"');

    List<Gallery> result = [];
    String? nextGid;
    for (int page = 0; page < pages; page++) {
      try {
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
      } catch (e) {
        log.warning('Load galleries of extra watched tag $tag failed', e, true);

        /// A failed first page is a failure of the tag, a failed later page only shortens the result.
        return page == 0 ? null : result;
      }
    }
    return result;
  }

  /// Merge extra galleries which finished loading after the page was already shown into the loaded list.
  Future<void> _mergeLateExtraGalleries() async {
    try {
      if (!_canMergeIntoState()) {
        return;
      }

      List<String> tags = extraWatchedTagSetting.tags.toList();
      if (!_hasCacheForTags(tags)) {
        return;
      }

      List<Gallery> picked = _pickExtrasInRange(
        _extraGalleriesCache!,
        state.galleries,
        hasNewerPage: state.prevGid != null,
        hasOlderPage: state.nextGid != null,
      );
      if (picked.isEmpty) {
        return;
      }

      picked = [...await postHandleNewGalleries(picked, cleanDuplicate: false)];

      /// The list may have changed while the galleries were post-processed.
      if (!_canMergeIntoState()) {
        return;
      }
      Set<int> shownGids = state.galleries.map((g) => g.galleryUrl.gid).toSet();
      picked.removeWhere((g) => shownGids.contains(g.galleryUrl.gid));
      if (picked.isEmpty) {
        return;
      }

      state.galleries = [...state.galleries, ...picked]..sort((a, b) => b.publishTime.compareTo(a.publishTime));
      if (state.loadingState == LoadingState.noData) {
        state.loadingState = LoadingState.noMore;
      }

      updateSafely();
      updateSafely([bodyId]);
    } catch (e) {
      log.warning('Merge late extra watched galleries failed', e, true);
    }
  }

  bool _canMergeIntoState() {
    return !isClosed && state.loadingState != LoadingState.loading && state.refreshState != LoadingState.loading;
  }
}

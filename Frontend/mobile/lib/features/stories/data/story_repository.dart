import '../../../core/errors/app_exception.dart';
import '../../auth/data/auth_repository.dart';
import '../domain/story_availability.dart';
import '../domain/story_detail.dart';
import 'story_api.dart';

abstract interface class StoryRepository {
  Future<List<StoryDetail>> fetchStories({String? search, String? category});

  Future<StoryDetail> fetchStory(String slug);
}

/// Fetches story content with the parent's refresh-aware authenticated session.
class RemoteStoryRepository implements StoryRepository {
  RemoteStoryRepository({
    AuthRepository? authRepository,
    StoryApi? api,
    StoryCatalogueCache? catalogueCache,
  }) : _authRepository = authRepository ?? AuthRepository(),
       _api = api ?? _sharedApi,
       _catalogueCache = catalogueCache ?? _sharedCatalogueCache;

  static final StoryApi _sharedApi = HttpStoryApi();
  static final _sharedCatalogueCache = StoryCatalogueCache();

  final AuthRepository _authRepository;
  final StoryApi _api;
  final StoryCatalogueCache _catalogueCache;

  @override
  Future<List<StoryDetail>> fetchStories({String? search, String? category}) {
    return _authRepository
        .withAccessToken(
          (accessToken) => _catalogueCache.fetch(
            (_api, accessToken, search ?? '', category ?? ''),
            () => _api.fetchStories(
              accessToken,
              search: search,
              category: category,
            ),
          ),
        )
        .then(
          (stories) => List<StoryDetail>.unmodifiable(
            stories.where((story) => isStoryAvailable(story.slug)),
          ),
        );
  }

  @override
  Future<StoryDetail> fetchStory(String slug) {
    if (!isStoryAvailable(slug)) {
      return Future.error(
        const AppException(
          'This story is no longer in the library. Choose another adventure.',
          code: 'story_unavailable',
          statusCode: 404,
        ),
      );
    }
    return _authRepository.withAccessToken(
      (accessToken) => _api.fetchStory(slug, accessToken),
    );
  }
}

/// The home and story-library screens share a short-lived catalogue request.
/// Authentication is still checked on every call, and each token/API/filter
/// combination is isolated. Failed requests are immediately retryable.
class StoryCatalogueCache {
  StoryCatalogueCache({
    this.maxAge = const Duration(seconds: 30),
    this.maxEntries = 8,
    DateTime Function()? now,
  }) : assert(maxEntries > 0),
       _now = now ?? DateTime.now;

  final Duration maxAge;
  final int maxEntries;
  final DateTime Function() _now;
  final _entries = <Object, _CatalogueEntry>{};
  final _pending = <Object, Future<List<StoryDetail>>>{};

  Future<List<StoryDetail>> fetch(
    Object key,
    Future<List<StoryDetail>> Function() load,
  ) {
    final cached = _entries.remove(key);
    if (cached != null && _now().difference(cached.savedAt) < maxAge) {
      _entries[key] = cached;
      return Future.value(cached.stories);
    }
    final pending = _pending[key];
    if (pending != null) return pending;

    Future<List<StoryDetail>> loadAndStore() async {
      try {
        final stories = List<StoryDetail>.unmodifiable(
          await Future<List<StoryDetail>>.sync(load),
        );
        _entries[key] = _CatalogueEntry(stories, _now());
        while (_entries.length > maxEntries) {
          _entries.remove(_entries.keys.first);
        }
        return stories;
      } finally {
        _pending.remove(key);
      }
    }

    final request = loadAndStore();
    _pending[key] = request;
    return request;
  }
}

class _CatalogueEntry {
  const _CatalogueEntry(this.stories, this.savedAt);
  final List<StoryDetail> stories;
  final DateTime savedAt;
}

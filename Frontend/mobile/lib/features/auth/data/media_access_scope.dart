import '../../../core/errors/app_exception.dart';
import '../../../core/media/content_media_fetcher.dart';
import '../../../core/network/feature_read_cache.dart';
import 'auth_repository.dart';

/// A media refresh belongs to the parent/child that created its consumer.
/// Token rotation is allowed; switching family, child or avatar is not.
class MediaAccessScope {
  MediaAccessScope(this.authRepository) {
    _origin = _read();
  }

  final AuthRepository authRepository;
  late final Future<MediaAccessIdentity?> _origin;

  Future<MediaAccessIdentity?> _read() async {
    try {
      final before = await authRepository.restoreSession();
      final child = await authRepository.currentKid();
      final after = await authRepository.restoreSession();
      if (before == null ||
          after == null ||
          child == null ||
          before.parent.id.isEmpty ||
          child.id.isEmpty ||
          before.parent.id != after.parent.id ||
          child.parentId != before.parent.id) {
        return null;
      }
      return MediaAccessIdentity(
        before.parent.id,
        child.id,
        child.avatarKey.trim().toLowerCase(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<MediaAccessIdentity> requireCurrent() async {
    final origin = await _origin;
    final current = await _read();
    if (origin == null ||
        current == null ||
        origin.parentId != current.parentId ||
        origin.childId != current.childId ||
        origin.avatarKey != current.avatarKey) {
      throw const AppException(
        'The active profile changed. Return to the library and try again.',
        code: 'active_kid_changed',
      );
    }
    return origin;
  }
}

class MediaAccessIdentity {
  const MediaAccessIdentity(this.parentId, this.childId, this.avatarKey);
  final String parentId, childId, avatarKey;
}

/// A private image cache never establishes authorization. Each consumer checks
/// its original parent/child/avatar and current sign-in scope around every hit.
class ScopedContentMediaFetcher implements ContentMediaFetcher {
  ScopedContentMediaFetcher({
    required this.authRepository,
    MediaAccessScope? accessScope,
    CachedContentMediaFetcher? cache,
  }) : _accessScope = accessScope ?? MediaAccessScope(authRepository),
       _cache = cache ?? defaultContentMediaFetcher;

  final AuthRepository authRepository;
  final MediaAccessScope _accessScope;
  final CachedContentMediaFetcher _cache;

  @override
  Future<FetchedContentMedia> fetch(Object? source) async {
    await _accessScope.requireCurrent();
    final scope = await authRepository.featureCacheScope();
    final generation = featureReadCache.mediaGeneration;
    final media = scope == null
        ? await _cache.fetch(source)
        : await _cache.fetchScoped(source, scope: scope);
    await _accessScope.requireCurrent();
    if ((scope != null && scope != await authRepository.featureCacheScope()) ||
        generation != featureReadCache.mediaGeneration) {
      throw const AppException(
        'The active profile changed. Return to the library and try again.',
        code: 'active_kid_changed',
      );
    }
    return media;
  }
}

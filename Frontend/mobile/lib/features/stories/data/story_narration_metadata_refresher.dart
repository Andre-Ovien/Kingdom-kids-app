import '../../../core/errors/app_exception.dart';
import '../../auth/data/auth_repository.dart';
import '../domain/story_detail.dart';
import 'story_repository.dart';

/// Obtains a fresh signed link from the authenticated story API. The original
/// story edition and parent/child/character scope remain fixed for this reader.
/// This resolves metadata only; it never accepts an arbitrary replacement URL.
class StoryNarrationMetadataRefresher {
  StoryNarrationMetadataRefresher({
    required this.story,
    required this.authRepository,
    StoryRepository? storyRepository,
  }) : _repository =
           storyRepository ??
           RemoteStoryRepository(authRepository: authRepository) {
    _scope = _readScope();
  }

  final StoryDetail story;
  final AuthRepository authRepository;
  final StoryRepository _repository;
  late final Future<_NarrationScope?> _scope;

  Future<_NarrationScope?> _readScope() async {
    try {
      final session = await authRepository.restoreSession();
      final child = await authRepository.currentKid();
      final current = await authRepository.restoreSession();
      if (session == null ||
          child == null ||
          current == null ||
          session.parent.id.isEmpty ||
          child.id.isEmpty ||
          child.parentId != session.parent.id ||
          current.parent.id != session.parent.id) {
        return null;
      }
      return _NarrationScope(
        session.parent.id,
        child.id,
        child.avatarKey.trim().toLowerCase(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _requireScope(_NarrationScope expected) async {
    final current = await _readScope();
    if (current == null ||
        current.parentId != expected.parentId ||
        current.childId != expected.childId ||
        current.avatarKey != expected.avatarKey) {
      throw const AppException(
        'The active profile changed. Return to the story library and try again.',
        code: 'active_kid_changed',
      );
    }
  }

  Future<void> validateScope() async {
    final scope = await _scope;
    if (scope == null) {
      throw const AppException(
        'Return to the story library to refresh this voice.',
      );
    }
    await _requireScope(scope);
  }

  Future<StoryNarration> resolve(
    StoryNarration original,
    String fullText,
  ) async {
    final scope = await _scope;
    if (scope == null ||
        original.avatarKey.trim().toLowerCase() != scope.avatarKey ||
        story.id.isEmpty ||
        story.slug.isEmpty ||
        fullText != story.body) {
      throw const AppException(
        'Return to the story library to refresh this voice.',
      );
    }
    await _requireScope(scope);
    final StoryDetail fresh;
    try {
      fresh = await _repository.fetchStory(story.slug);
    } catch (_) {
      // Do not propagate response bodies, signed URLs or provider diagnostics.
      throw const AppException(
        'This voice could not refresh. Check your connection or ask a grown-up to check your access.',
        code: 'story_media_refresh_failed',
      );
    }
    await _requireScope(scope);
    // Exact UTF-16 text equality is stronger than comparing a text hash and
    // preserves all bookmark/cue offsets for the edition already being read.
    if (fresh.id != story.id ||
        fresh.slug != story.slug ||
        fresh.body != fullText) {
      throw const AppException(
        'This story has been updated. Reopen it from the library to keep reading.',
        code: 'story_edition_changed',
      );
    }
    final matches = fresh.narrations
        .where(
          (item) =>
              item.avatarKey.trim().toLowerCase() ==
                  original.avatarKey.trim().toLowerCase() &&
              item.voiceKey == original.voiceKey,
        )
        .toList();
    if (matches.length != 1 ||
        matches.single.status.toLowerCase() != 'ready' ||
        !matches.single.audioAvailable ||
        matches.single.audioUrl == null) {
      throw const AppException(
        'This character’s reading voice is not ready yet.',
      );
    }
    return matches.single;
  }
}

class _NarrationScope {
  const _NarrationScope(this.parentId, this.childId, this.avatarKey);
  final String parentId, childId, avatarKey;
}

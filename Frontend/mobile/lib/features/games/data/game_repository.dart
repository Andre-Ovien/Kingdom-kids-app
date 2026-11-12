import '../../../core/errors/app_exception.dart';
import '../../../core/network/feature_read_cache.dart';
import '../../auth/data/auth_repository.dart';
import '../domain/mini_game.dart';
import 'game_api.dart';

/// A narrow, injectable boundary used by the catalogue and all seven engines.
abstract interface class GameRepository {
  Future<List<MiniGame>> fetchGames({required String profileId});

  Future<MiniGame> fetchGame(String slug, {required String profileId});

  Future<GameSubmission> submitResult({
    required String slug,
    required String profileId,
    required int levelNumber,
    required String operationId,
    required Map<String, dynamic> result,
  });
}

/// Fetches kid-specific games through the parent's refresh-aware session.
///
/// A caller supplies a profile id for explicit UI state, but it must match the
/// currently selected kid. This prevents a stale widget from requesting or
/// submitting progress for a different child after a profile switch.
class RemoteGameRepository implements GameRepository {
  RemoteGameRepository({AuthRepository? authRepository, GameApi? api})
    : _authRepository = authRepository ?? AuthRepository(),
      _api = api ?? _sharedApi;

  static final GameApi _sharedApi = HttpGameApi();

  final AuthRepository _authRepository;
  final GameApi _api;

  @override
  Future<List<MiniGame>> fetchGames({required String profileId}) async {
    final activeProfileId = await _requireCurrentProfile(profileId);
    return _authRepository.withCachedFeatureRead(
      (_api, 'games', activeProfileId),
      (accessToken) async {
        await _requireCurrentProfile(activeProfileId);
        return _api.fetchGames(accessToken, profileId: activeProfileId);
      },
      expiresAt: (games) =>
          featureMediaExpiry(games.map((game) => game.coverImageUrl)),
    );
  }

  @override
  Future<MiniGame> fetchGame(String slug, {required String profileId}) async {
    final activeProfileId = await _requireCurrentProfile(profileId);
    return _authRepository.withCachedFeatureRead(
      (_api, 'game', slug, activeProfileId),
      (accessToken) async {
        await _requireCurrentProfile(activeProfileId);
        return _api.fetchGame(slug, accessToken, profileId: activeProfileId);
      },
      expiresAt: (game) => featureMediaExpiry([game.coverImageUrl]),
    );
  }

  @override
  Future<GameSubmission> submitResult({
    required String slug,
    required String profileId,
    required int levelNumber,
    required String operationId,
    required Map<String, dynamic> result,
  }) async {
    final activeProfileId = await _requireCurrentProfile(profileId);
    final submission = await _authRepository.withAccessToken((
      accessToken,
    ) async {
      // Token refresh can outlive a profile switch. Keep this attempt bound
      // to its original child and operation, or stop before another POST.
      await _requireCurrentProfile(activeProfileId);
      return _api.submitResult(
        slug: slug,
        profileId: activeProfileId,
        levelNumber: levelNumber,
        operationId: operationId,
        result: result,
        accessToken: accessToken,
      );
    });
    _authRepository.invalidateFeatureReads(includeMedia: false);
    return submission;
  }

  Future<String> _requireCurrentProfile(String requestedProfileId) async {
    final normalized = requestedProfileId.trim();
    if (normalized.isEmpty) {
      throw const AppException(
        'Choose a kid profile before playing.',
        code: 'active_kid_required',
      );
    }

    final activeKid = await _authRepository.currentKid();
    if (activeKid == null) {
      throw const AppException(
        'Choose a kid profile before playing.',
        code: 'active_kid_required',
      );
    }
    if (activeKid.id != normalized) {
      throw const AppException(
        'The active kid profile changed. Return to Games and try again.',
        code: 'active_kid_changed',
      );
    }
    return activeKid.id;
  }
}

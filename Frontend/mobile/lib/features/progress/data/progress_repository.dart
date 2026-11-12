import '../../../core/errors/app_exception.dart';
import '../../auth/data/auth_repository.dart';
import '../domain/story_activity_event.dart';
import 'progress_api.dart';

abstract interface class ProgressRepository {
  Future<StoryActivityEvent> recordStoryActivity({
    required String profileId,
    required String storyId,
    required StoryActivityType eventType,
    required String operationId,
  });
}

/// Saves meaningful story milestones through the parent's refresh-aware token.
///
/// The selected-profile guard prevents an old screen from writing progress to
/// the wrong child after a parent switches profiles.
class RemoteProgressRepository implements ProgressRepository {
  RemoteProgressRepository({AuthRepository? authRepository, ProgressApi? api})
    : _authRepository = authRepository ?? AuthRepository(),
      _api = api ?? HttpProgressApi();

  final AuthRepository _authRepository;
  final ProgressApi _api;

  @override
  Future<StoryActivityEvent> recordStoryActivity({
    required String profileId,
    required String storyId,
    required StoryActivityType eventType,
    required String operationId,
  }) async {
    final activeProfileId = await _requireCurrentProfile(profileId);
    return _authRepository.withAccessToken((accessToken) async {
      await _requireCurrentProfile(activeProfileId);
      return _api.recordStoryActivity(
        accessToken: accessToken,
        profileId: activeProfileId,
        storyId: storyId,
        eventType: eventType,
        operationId: operationId,
      );
    });
  }

  Future<String> _requireCurrentProfile(String requestedProfileId) async {
    final normalized = requestedProfileId.trim();
    if (normalized.isEmpty) {
      throw const AppException(
        'Choose a kid profile before reading.',
        code: 'active_kid_required',
      );
    }
    final activeKid = await _authRepository.currentKid();
    if (activeKid == null) {
      throw const AppException(
        'Choose a kid profile before reading.',
        code: 'active_kid_required',
      );
    }
    if (activeKid.id != normalized) {
      throw const AppException(
        'The active kid profile changed. Return to Stories and try again.',
        code: 'active_kid_changed',
      );
    }
    return activeKid.id;
  }
}

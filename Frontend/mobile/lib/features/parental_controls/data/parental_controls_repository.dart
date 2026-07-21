import '../../../core/errors/app_exception.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/kid_profile.dart';
import '../domain/parent_settings.dart';
import 'parental_controls_api.dart';

abstract interface class ParentalControlsRepository {
  Future<ParentSettings> fetchSettings({required String profileId});

  Future<ParentSettings> updateSettings({
    required String profileId,
    StoryTextScale? storyTextScale,
    bool? narrationEnabled,
  });
}

class RemoteParentalControlsRepository implements ParentalControlsRepository {
  RemoteParentalControlsRepository({
    AuthRepository? authRepository,
    ParentalControlsApi? api,
  }) : _authRepository = authRepository ?? AuthRepository(),
       _api = api ?? HttpParentalControlsApi();

  final AuthRepository _authRepository;
  final ParentalControlsApi _api;

  @override
  Future<ParentSettings> fetchSettings({required String profileId}) async {
    final activeKid = await _requireActiveKid(profileId);
    final settings = await _authRepository.withAccessToken(
      (accessToken) =>
          _api.fetchSettings(accessToken: accessToken, profileId: activeKid.id),
    );
    return _requireMatchingProfile(settings, activeKid.id);
  }

  @override
  Future<ParentSettings> updateSettings({
    required String profileId,
    StoryTextScale? storyTextScale,
    bool? narrationEnabled,
  }) async {
    if (storyTextScale == null && narrationEnabled == null) {
      throw const AppException(
        'Choose at least one reading preference to update.',
        code: 'empty_preferences_update',
      );
    }
    final activeKid = await _requireActiveKid(profileId);
    final settings = await _authRepository.withAccessToken(
      (accessToken) => _api.updateSettings(
        accessToken: accessToken,
        profileId: activeKid.id,
        storyTextScale: storyTextScale,
        narrationEnabled: narrationEnabled,
      ),
    );
    return _requireMatchingProfile(settings, activeKid.id);
  }

  Future<KidProfile> _requireActiveKid(String profileId) async {
    final normalizedProfileId = profileId.trim();
    final activeKid = await _authRepository.currentKid();
    if (activeKid == null) {
      throw const AppException(
        'Choose a kid profile to manage their reading preferences.',
        code: 'active_kid_required',
      );
    }
    if (normalizedProfileId.isEmpty || activeKid.id != normalizedProfileId) {
      throw const AppException(
        'The active kid profile changed. Open Settings again.',
        code: 'active_kid_changed',
      );
    }
    return activeKid;
  }

  ParentSettings _requireMatchingProfile(
    ParentSettings settings,
    String expectedProfileId,
  ) {
    if (settings.profileId != expectedProfileId) {
      throw const AppException(
        'The preferences service returned another child profile.',
        code: 'preferences_profile_changed',
      );
    }
    return settings;
  }
}

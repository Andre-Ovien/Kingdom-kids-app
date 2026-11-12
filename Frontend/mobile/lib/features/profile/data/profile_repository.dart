import '../../../core/errors/app_exception.dart';
import '../../auth/data/auth_repository.dart';
import '../domain/progress_summary.dart';
import 'profile_api.dart';

abstract interface class ProfileRepository {
  Future<ProfileProgressSummary> fetchSummary({required String profileId});
}

class RemoteProfileRepository implements ProfileRepository {
  RemoteProfileRepository({AuthRepository? authRepository, ProfileApi? api})
    : _authRepository = authRepository ?? AuthRepository(),
      _api = api ?? _sharedApi;

  static final ProfileApi _sharedApi = HttpProfileApi();

  final AuthRepository _authRepository;
  final ProfileApi _api;

  @override
  Future<ProfileProgressSummary> fetchSummary({
    required String profileId,
  }) async {
    final normalized = profileId.trim();
    final activeKid = await _authRepository.currentKid();
    if (activeKid == null) {
      throw const AppException(
        'Choose a kid profile to see their progress.',
        code: 'active_kid_required',
      );
    }
    if (normalized.isEmpty || activeKid.id != normalized) {
      throw const AppException(
        'The active kid profile changed. Open Profile again.',
        code: 'active_kid_changed',
      );
    }
    final summary = await _authRepository.withCachedFeatureRead(
      (_api, 'summary', activeKid.id, DateTime.now().timeZoneOffset.inMinutes),
      (accessToken) async {
        if ((await _authRepository.currentKid())?.id != activeKid.id) {
          throw const AppException(
            'The active kid profile changed.',
            code: 'active_kid_changed',
          );
        }
        return _api.fetchSummary(
          accessToken: accessToken,
          profileId: activeKid.id,
          timezoneOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
        );
      },
    );
    if ((await _authRepository.currentKid())?.id != activeKid.id) {
      throw const AppException(
        'The active kid profile changed.',
        code: 'active_kid_changed',
      );
    }
    return summary;
  }
}

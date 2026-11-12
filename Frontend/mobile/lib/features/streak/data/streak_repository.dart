import '../../../core/errors/app_exception.dart';
import '../../auth/data/auth_repository.dart';
import '../domain/streak_claim_receipt.dart';
import 'streak_api.dart';

abstract interface class StreakRepository {
  Future<StreakClaimReceipt> claimPresentation({required String profileId});
}

class RemoteStreakRepository implements StreakRepository {
  RemoteStreakRepository({AuthRepository? authRepository, StreakApi? api})
    : _authRepository = authRepository ?? AuthRepository(),
      _api = api ?? HttpStreakApi();

  final AuthRepository _authRepository;
  final StreakApi _api;

  @override
  Future<StreakClaimReceipt> claimPresentation({
    required String profileId,
  }) async {
    final normalizedProfileId = profileId.trim();
    final activeProfile = await _authRepository.currentKid();
    if (activeProfile == null) {
      throw const AppException(
        'Choose a kid profile to see their streak.',
        code: 'active_kid_required',
      );
    }
    if (normalizedProfileId.isEmpty ||
        normalizedProfileId != activeProfile.id) {
      throw const AppException(
        'The active kid profile changed. Open Home again.',
        code: 'active_kid_changed',
      );
    }

    final receipt = await _authRepository.withAccessToken((accessToken) async {
      final latestProfile = await _authRepository.currentKid();
      if (latestProfile?.id != activeProfile.id ||
          latestProfile?.parentId != activeProfile.parentId) {
        throw const AppException(
          'The active kid profile changed. Open Home again.',
          code: 'active_kid_changed',
        );
      }
      return _api.claimPresentation(
        accessToken: accessToken,
        profileId: activeProfile.id,
        timezoneOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
      );
    });
    if (receipt.xpAwarded > 0 || receipt.levelMilestone != null) {
      _authRepository.invalidateFeatureReads(includeMedia: false);
    }
    return receipt;
  }
}

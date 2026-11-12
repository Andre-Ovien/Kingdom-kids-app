import '../../../core/errors/app_exception.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/kid_profile.dart';
import '../domain/streak_claim_receipt.dart';
import 'streak_api.dart';

abstract interface class StreakRepository {
  Future<StreakClaimReceipt> claimPresentation({required String profileId});
}

class RemoteStreakRepository implements StreakRepository {
  RemoteStreakRepository({
    AuthRepository? authRepository,
    StreakApi? api,
    DateTime Function()? now,
  }) : _authRepository = authRepository ?? AuthRepository(),
       _api = api ?? HttpStreakApi(),
       _now = now ?? DateTime.now;

  // Home recreates this repository on tab returns. A saved daily reward is
  // replayed by the server, so remember only which receipts already refreshed
  // this exact signed-in family/child's progress. This never skips a claim POST.
  static const _maximumRememberedRewards = 128;
  static final _refreshedRewards = <Object, bool>{};

  final AuthRepository _authRepository;
  final StreakApi _api;
  final DateTime Function() _now;

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

    final scope = await _readScope();
    var claimedAt = _now();
    final receipt = await _authRepository.withAccessToken((accessToken) async {
      final latestProfile = await _authRepository.currentKid();
      if (latestProfile?.id != activeProfile.id ||
          latestProfile?.parentId != activeProfile.parentId) {
        throw const AppException(
          'The active kid profile changed. Open Home again.',
          code: 'active_kid_changed',
        );
      }
      claimedAt = _now();
      return _api.claimPresentation(
        accessToken: accessToken,
        profileId: activeProfile.id,
        timezoneOffsetMinutes: claimedAt.timeZoneOffset.inMinutes,
      );
    });
    if (receipt.xpAwarded > 0 || receipt.levelMilestone != null) {
      // The mutation is already committed. A failed local ownership read must
      // not turn its successful receipt into an error or trigger another POST.
      final current = await _currentKidAfterClaim();
      if (current?.id != activeProfile.id ||
          current?.parentId != activeProfile.parentId ||
          current?.avatarKey != activeProfile.avatarKey) {
        return receipt;
      }
      // A committed response may arrive after a child switch or fresh login.
      // Its receipt remains valid, but must not invalidate the new session.
      final currentScope = await _readScope();
      if (scope != currentScope) return receipt;
      if (scope != null) {
        final day = receipt.presentation?.localDate ?? claimedAt;
        final milestone = receipt.levelMilestone;
        final level = milestone?.level;
        final fingerprint = (
          scope,
          _api is HttpStreakApi ? _api.baseUrl : _api,
          (day.year, day.month, day.day),
          receipt.xpAwarded,
          milestone == null
              ? null
              : (
                  milestone.previousLevel,
                  level!.number,
                  level.title,
                  level.xp,
                  level.nextLevelXp,
                  level.maxLevel,
                  level.isMaxLevel,
                ),
        );
        if (_refreshedRewards.remove(fingerprint) != null) {
          _refreshedRewards[fingerprint] = true;
          return receipt;
        }
        _refreshedRewards[fingerprint] = true;
        while (_refreshedRewards.length > _maximumRememberedRewards) {
          _refreshedRewards.remove(_refreshedRewards.keys.first);
        }
      }
      // An unavailable scope cannot safely establish replay identity. Keep the
      // existing conservative refresh behavior for that case.
      _authRepository.invalidateFeatureReads(includeMedia: false);
    }
    return receipt;
  }

  Future<Object?> _readScope() async {
    try {
      return await _authRepository.featureCacheScope();
    } catch (_) {
      return null;
    }
  }

  Future<KidProfile?> _currentKidAfterClaim() async {
    try {
      return await _authRepository.currentKid();
    } catch (_) {
      return null;
    }
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../auth/data/auth_repository.dart';
import '../data/level_milestone_store.dart';
import '../domain/level_milestone.dart';
import 'level_milestone_screen.dart';

enum LevelMilestonePresentationResult { presented, skipped, deferred }

/// Uses the same presentation watermark for story, streak and quest rewards.
/// Callers retain a deferred receipt until their route becomes visible again.
class LevelMilestonePresenter {
  LevelMilestonePresenter({
    required AuthRepository authRepository,
    LevelMilestoneStore? store,
  }) : _authRepository = authRepository,
       _store = store ?? SecureLevelMilestoneStore();

  final AuthRepository _authRepository;
  final LevelMilestoneStore _store;
  bool _opening = false;

  bool _available(BuildContext context, bool Function() canPresent) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return context.mounted &&
        ModalRoute.of(context)?.isCurrent == true &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        canPresent();
  }

  Future<LevelMilestonePresentationResult> present(
    BuildContext context, {
    required String profileId,
    required LevelMilestone milestone,
    required bool Function() canPresent,
    VoidCallback? beforePresent,
    VoidCallback? afterPresent,
  }) async {
    if (!milestone.isLevelUp) return LevelMilestonePresentationResult.skipped;
    if (_opening || !_available(context, canPresent)) {
      return LevelMilestonePresentationResult.deferred;
    }
    _opening = true;
    var entered = false;
    var openingStarted = false;
    try {
      final highest = await _store.highestPresentedLevel(profileId);
      final profile = await _authRepository.currentKid();
      if (!context.mounted) {
        return LevelMilestonePresentationResult.deferred;
      }
      if (profile?.id != profileId || highest >= milestone.level.number) {
        return LevelMilestonePresentationResult.skipped;
      }
      if (!_available(context, canPresent)) {
        return LevelMilestonePresentationResult.deferred;
      }
      beforePresent?.call();
      openingStarted = true;
      if (!context.mounted) return LevelMilestonePresentationResult.deferred;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: AppRoutes.levelMilestone),
          builder: (_) => LevelMilestoneScreen(
            profile: profile!,
            level: milestone.level.number,
            levelTitle: milestone.level.title,
            isMaxLevel: milestone.level.isMaxLevel,
            onPresented: () {
              entered = true;
              unawaited(
                _store
                    .markPresented(profileId, milestone.level.number)
                    .catchError((Object _) {}),
              );
            },
          ),
        ),
      );
      return entered
          ? LevelMilestonePresentationResult.presented
          : LevelMilestonePresentationResult.deferred;
    } catch (_) {
      // The activity was already saved; its celebration must not block use.
      return LevelMilestonePresentationResult.skipped;
    } finally {
      _opening = false;
      if (openingStarted) afterPresent?.call();
    }
  }
}

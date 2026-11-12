import '../../milestones/domain/level_milestone.dart';
import 'streak_presentation.dart';

/// A saved daily visit can award XP even when its streak page was shown before.
class StreakClaimReceipt {
  const StreakClaimReceipt({
    this.presentation,
    this.xpAwarded = 0,
    this.levelMilestone,
  });

  final StreakPresentation? presentation;
  final int xpAwarded;
  final LevelMilestone? levelMilestone;
}

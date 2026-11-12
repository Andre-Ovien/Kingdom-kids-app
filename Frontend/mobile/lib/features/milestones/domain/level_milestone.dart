import '../../auth/domain/kid_profile.dart';
import '../../profile/domain/progress_summary.dart';

/// An overall level increase captured with the authoritative quest receipt.
class LevelMilestone {
  const LevelMilestone({required this.previousLevel, required this.level});

  final int previousLevel;
  final ProfileLevel level;

  bool get isLevelUp =>
      previousLevel >= 1 &&
      level.number > previousLevel &&
      level.number <= ProfileLevel.maximumLevel;

  static LevelMilestone? tryParse(Object? value) {
    if (value is! Map || value['level'] is! Map) return null;
    final previous = value['previous_level'];
    if (previous is! int || previous < 1) return null;
    final rawLevel = value['level'] as Map;
    if (rawLevel['number'] is! int ||
        (rawLevel['number'] as int) <= previous ||
        (rawLevel['number'] as int) > ProfileLevel.maximumLevel ||
        rawLevel['title'] is! String ||
        (rawLevel['title'] as String).trim().isEmpty) {
      return null;
    }
    final parsed = ProfileLevel.fromJson(
      rawLevel.map((key, nested) => MapEntry(key.toString(), nested)),
    );
    final milestone = LevelMilestone(previousLevel: previous, level: parsed);
    return milestone.isLevelUp ? milestone : null;
  }
}

class LevelMilestonePresentation {
  const LevelMilestonePresentation({
    required this.profile,
    required this.milestone,
  });

  final KidProfile profile;
  final LevelMilestone milestone;
}

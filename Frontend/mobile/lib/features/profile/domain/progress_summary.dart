import 'dart:collection';

import '../../auth/domain/kid_profile.dart';

class ProfileProgressSummary {
  ProfileProgressSummary({
    required this.profile,
    required this.level,
    required this.stats,
    required List<ProfileBadge> badges,
    required this.activityStreak,
    required List<WeeklyProfileActivity> weeklyActivity,
    this.lastActivityAt,
  }) : badges = UnmodifiableListView(badges),
       weeklyActivity = UnmodifiableListView(weeklyActivity);

  final KidProfile profile;
  final ProfileLevel level;
  final ProfileStats stats;
  final List<ProfileBadge> badges;
  final ProfileActivityStreak activityStreak;
  final List<WeeklyProfileActivity> weeklyActivity;
  final DateTime? lastActivityAt;

  factory ProfileProgressSummary.fromJson(Map<String, dynamic> json) {
    final rawBadges = json['badges'];
    final rawWeeks = json['weekly_activity'];
    return ProfileProgressSummary(
      profile: KidProfile.fromJson(_map(json['profile'])),
      level: ProfileLevel.fromJson(_map(json['level'])),
      stats: ProfileStats.fromJson(_map(json['stats'])),
      badges: rawBadges is List
          ? rawBadges
                .whereType<Map>()
                .map((value) => ProfileBadge.fromJson(_map(value)))
                .toList(growable: false)
          : const [],
      activityStreak: ProfileActivityStreak.fromJson(
        _map(json['activity_streak']),
      ),
      weeklyActivity: rawWeeks is List
          ? rawWeeks
                .whereType<Map>()
                .map((value) => WeeklyProfileActivity.fromJson(_map(value)))
                .toList(growable: false)
          : const [],
      lastActivityAt: _date(json['last_activity_at']),
    );
  }
}

class ProfileLevel {
  const ProfileLevel({
    required this.number,
    required this.title,
    required this.xp,
    required this.nextLevelXp,
  });

  final int number;
  final String title;
  final int xp;
  final int nextLevelXp;

  double get progress {
    if (nextLevelXp <= 0) return 1;
    final levelFloor = (number - 1) * 300;
    final span = (nextLevelXp - levelFloor).clamp(1, 1 << 31).toInt();
    return ((xp - levelFloor) / span).clamp(0.0, 1.0).toDouble();
  }

  factory ProfileLevel.fromJson(Map<String, dynamic> json) {
    return ProfileLevel(
      number: _integer(json['number'], fallback: 1).clamp(1, 999).toInt(),
      title: _string(json['title'], fallback: 'New Explorer'),
      xp: _integer(json['xp']).clamp(0, 1 << 31).toInt(),
      nextLevelXp: _integer(
        json['next_level_xp'],
        fallback: 300,
      ).clamp(0, 1 << 31).toInt(),
    );
  }
}

class ProfileStats {
  const ProfileStats({
    required this.completedGameLevels,
    required this.totalGameLevels,
    required this.gameStars,
    required this.maxGameStars,
    required this.gamesStarted,
    required this.gamesCompleted,
    required this.earnedBadges,
    this.totalStories = 0,
    this.storiesStarted = 0,
    this.storiesCompleted = 0,
  });

  final int completedGameLevels;
  final int totalGameLevels;
  final int gameStars;
  final int maxGameStars;
  final int gamesStarted;
  final int gamesCompleted;
  final int earnedBadges;
  final int totalStories;
  final int storiesStarted;
  final int storiesCompleted;

  factory ProfileStats.fromJson(Map<String, dynamic> json) {
    return ProfileStats(
      completedGameLevels: _nonNegative(json['completed_game_levels']),
      totalGameLevels: _nonNegative(json['total_game_levels']),
      gameStars: _nonNegative(json['game_stars']),
      maxGameStars: _nonNegative(json['max_game_stars']),
      gamesStarted: _nonNegative(json['games_started']),
      gamesCompleted: _nonNegative(json['games_completed']),
      earnedBadges: _nonNegative(json['earned_badges']),
      totalStories: _nonNegative(json['total_stories']),
      storiesStarted: _nonNegative(json['stories_started']),
      storiesCompleted: _nonNegative(json['stories_completed']),
    );
  }
}

class ProfileBadge {
  const ProfileBadge({
    required this.key,
    required this.title,
    required this.description,
    required this.iconKey,
    required this.earned,
    required this.progress,
    required this.target,
  });

  final String key;
  final String title;
  final String description;
  final String iconKey;
  final bool earned;
  final int progress;
  final int target;

  double get completion =>
      target <= 0 ? 1 : (progress / target).clamp(0.0, 1.0).toDouble();

  factory ProfileBadge.fromJson(Map<String, dynamic> json) {
    return ProfileBadge(
      key: _string(json['key']),
      title: _string(json['title'], fallback: 'Mystery badge'),
      description: _string(json['description']),
      iconKey: _string(json['icon_key'], fallback: 'stars'),
      earned: _boolean(json['earned']),
      progress: _nonNegative(json['progress']),
      target: _nonNegative(json['target']),
    );
  }
}

class ProfileActivityStreak {
  const ProfileActivityStreak({
    required this.currentDays,
    required this.longestDays,
  });

  final int currentDays;
  final int longestDays;

  factory ProfileActivityStreak.fromJson(Map<String, dynamic> json) {
    return ProfileActivityStreak(
      currentDays: _nonNegative(json['current_days']),
      longestDays: _nonNegative(json['longest_days']),
    );
  }
}

class WeeklyProfileActivity {
  const WeeklyProfileActivity({
    required this.weekStart,
    required this.label,
    required this.attempts,
    this.storyCompletions = 0,
    int? activities,
  }) : activities = activities ?? attempts;

  final DateTime? weekStart;
  final String label;
  final int attempts;
  final int storyCompletions;
  final int activities;

  factory WeeklyProfileActivity.fromJson(Map<String, dynamic> json) {
    final attempts = _nonNegative(json['attempts']);
    return WeeklyProfileActivity(
      weekStart: _date(json['week_start']),
      label: _string(json['label'], fallback: 'Week'),
      attempts: attempts,
      storyCompletions: _nonNegative(json['story_completions']),
      activities: json.containsKey('activities')
          ? _nonNegative(json['activities'])
          : attempts,
    );
  }
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, nested) => MapEntry(key.toString(), nested));
  }
  return const {};
}

String _string(Object? value, {String fallback = ''}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

int _integer(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

int _nonNegative(Object? value) => _integer(value).clamp(0, 1 << 31).toInt();

bool _boolean(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  return switch (value?.toString().toLowerCase()) {
    'true' || '1' || 'yes' => true,
    _ => false,
  };
}

DateTime? _date(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : DateTime.tryParse(text);
}

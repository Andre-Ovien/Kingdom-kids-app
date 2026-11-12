import 'dart:collection';

import '../../auth/domain/kid_profile.dart';
import '../../streak/domain/streak_presentation.dart';

class ProfileProgressSummary {
  ProfileProgressSummary({
    required this.profile,
    required this.level,
    required this.stats,
    required List<ProfileBadge> badges,
    required this.activityStreak,
    required List<WeeklyProfileActivity> weeklyActivity,
    this.lastActivityAt,
    this.xpBreakdown,
    this.streakWeek,
  }) : badges = UnmodifiableListView(badges),
       weeklyActivity = UnmodifiableListView(weeklyActivity);

  final KidProfile profile;
  final ProfileLevel level;
  final ProfileStats stats;
  final List<ProfileBadge> badges;
  final ProfileActivityStreak activityStreak;
  final List<WeeklyProfileActivity> weeklyActivity;
  final DateTime? lastActivityAt;
  final ProfileXpBreakdown? xpBreakdown;
  final ProfileStreakWeek? streakWeek;

  factory ProfileProgressSummary.fromJson(Map<String, dynamic> json) {
    final rawBadges = json['badges'];
    final rawWeeks = json['weekly_activity'];
    final xpSources = _map(json['xp_breakdown']);
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
      xpBreakdown: xpSources.isEmpty
          ? null
          : ProfileXpBreakdown.fromJson(xpSources),
      streakWeek: ProfileStreakWeek.tryParse(json['streak_week']),
    );
  }
}

/// Optional real weekday history; missing or malformed data stays unavailable.
class ProfileStreakWeek {
  ProfileStreakWeek({required this.localDate, required List<StreakDay> days})
    : days = UnmodifiableListView(days);

  final DateTime localDate;
  final List<StreakDay> days;

  static ProfileStreakWeek? tryParse(Object? value) {
    if (value is! Map) return null;
    final date = _calendarDate(value['local_date']);
    final rawDays = value['days'];
    if (date == null || rawDays is! List || rawDays.length != 7) return null;
    final monday = DateTime.utc(
      date.year,
      date.month,
      date.day,
    ).subtract(Duration(days: date.weekday - 1));
    final days = <StreakDay>[];
    for (var index = 0; index < rawDays.length; index++) {
      final raw = rawDays[index];
      if (raw is! Map || raw['active'] is! bool) return null;
      final day = _calendarDate(raw['date']);
      final expected = monday.add(Duration(days: index));
      if (day == null ||
          day.year != expected.year ||
          day.month != expected.month ||
          day.day != expected.day ||
          (day.isAfter(date) && raw['active'] == true)) {
        return null;
      }
      days.add(StreakDay(date: day, active: raw['active'] as bool));
    }
    return ProfileStreakWeek(localDate: date, days: days);
  }

  static DateTime? _calendarDate(Object? value) {
    if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      return null;
    }
    final date = DateTime.tryParse(value);
    if (date == null ||
        '${date.year.toString().padLeft(4, '0')}-'
                '${date.month.toString().padLeft(2, '0')}-'
                '${date.day.toString().padLeft(2, '0')}' !=
            value) {
      return null;
    }
    return date;
  }
}

class ProfileXpBreakdown {
  const ProfileXpBreakdown({
    required this.quests,
    required this.stories,
    required this.streaks,
  });

  final int quests;
  final int stories;
  final int streaks;
  int get total => quests + stories + streaks;

  factory ProfileXpBreakdown.fromJson(Map<String, dynamic> json) =>
      ProfileXpBreakdown(
        quests: _nonNegative(json['quests']),
        stories: _nonNegative(json['stories']),
        streaks: _nonNegative(json['streaks']),
      );
}

class ProfileLevel {
  const ProfileLevel({
    required this.number,
    required this.title,
    required this.xp,
    required this.nextLevelXp,
    this.maxLevel = maximumLevel,
    bool isMaxLevel = false,
  }) : _isMaxLevel = isMaxLevel;

  static const maximumLevel = 15;
  final int number;
  final String title;
  final int xp;
  final int nextLevelXp;
  final int maxLevel;
  final bool _isMaxLevel;

  bool get isMaxLevel => _isMaxLevel || number >= maxLevel;

  double get progress {
    if (isMaxLevel || nextLevelXp <= 0) return 1;
    final levelFloor = (number - 1) * 300;
    final span = (nextLevelXp - levelFloor).clamp(1, 1 << 31).toInt();
    return ((xp - levelFloor) / span).clamp(0.0, 1.0).toDouble();
  }

  factory ProfileLevel.fromJson(Map<String, dynamic> json) {
    final maxLevel = _integer(
      json['max_level'],
      fallback: maximumLevel,
    ).clamp(1, maximumLevel).toInt();
    return ProfileLevel(
      number: _integer(json['number'], fallback: 1).clamp(1, maxLevel).toInt(),
      title: _string(json['title'], fallback: 'New Explorer'),
      xp: _integer(json['xp']).clamp(0, 1 << 31).toInt(),
      nextLevelXp: _integer(
        json['next_level_xp'],
        fallback: 300,
      ).clamp(0, 1 << 31).toInt(),
      maxLevel: maxLevel,
      isMaxLevel: _boolean(json['is_max_level']),
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

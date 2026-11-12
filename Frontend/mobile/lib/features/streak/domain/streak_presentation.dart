import 'dart:collection';

import '../../auth/domain/kid_profile.dart';

enum StreakPresentationState {
  firstStreak('first_streak'),
  continued('continued');

  const StreakPresentationState(this.wireName);

  final String wireName;

  static StreakPresentationState fromWireName(Object? value) {
    final wireName = value?.toString().trim() ?? '';
    for (final state in values) {
      if (state.wireName == wireName) return state;
    }
    throw const FormatException('Unsupported streak presentation state.');
  }
}

class StreakDay {
  const StreakDay({required this.date, required this.active});

  final DateTime date;
  final bool active;

  factory StreakDay.fromJson(Map<String, dynamic> json) {
    final date = DateTime.tryParse(json['date']?.toString() ?? '');
    if (date == null) {
      throw const FormatException('Invalid streak day.');
    }
    return StreakDay(date: date, active: json['active'] == true);
  }
}

class StreakPresentation {
  StreakPresentation({
    required this.profile,
    required this.state,
    required this.currentDays,
    required this.longestDays,
    required this.localDate,
    required List<StreakDay> recentDays,
  }) : recentDays = UnmodifiableListView(recentDays);

  final KidProfile profile;
  final StreakPresentationState state;
  final int currentDays;
  final int longestDays;
  final DateTime localDate;
  final List<StreakDay> recentDays;

  bool get isPersonalBest => currentDays > 1 && currentDays >= longestDays;

  int get nextMilestone {
    for (final milestone in const [3, 7, 14, 30, 50, 100]) {
      if (milestone > currentDays) return milestone;
    }
    return ((currentDays ~/ 50) + 1) * 50;
  }

  factory StreakPresentation.fromJson(Map<String, dynamic> json) {
    final profile = _map(json['profile']);
    final rawDays = json['recent_days'];
    final localDate = DateTime.tryParse(json['local_date']?.toString() ?? '');
    if (profile.isEmpty || localDate == null || rawDays is! List) {
      throw const FormatException('Incomplete streak presentation.');
    }
    return StreakPresentation(
      profile: KidProfile.fromJson(profile),
      state: StreakPresentationState.fromWireName(json['state']),
      currentDays: _nonNegative(json['current_days']),
      longestDays: _nonNegative(json['longest_days']),
      localDate: localDate,
      recentDays: rawDays
          .whereType<Map>()
          .map((value) => StreakDay.fromJson(_map(value)))
          .toList(growable: false),
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

int _nonNegative(Object? value) {
  final number = value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '') ?? 0;
  return number.clamp(0, 1 << 31).toInt();
}

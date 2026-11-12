import '../../milestones/domain/level_milestone.dart';

enum StoryActivityType {
  storyStarted('story_started'),
  storyCompleted('story_completed');

  const StoryActivityType(this.wireName);

  final String wireName;

  static StoryActivityType fromWireName(Object? value) {
    final wireName = value?.toString().trim() ?? '';
    for (final type in values) {
      if (type.wireName == wireName) return type;
    }
    throw const FormatException('Unsupported story activity type.');
  }
}

/// The backend receipt for one privacy-safe, profile-owned learning event.
///
/// The app deliberately records only story starts and verified completions;
/// raw taps, text positions, device details, and reading content are excluded.
class StoryActivityEvent {
  const StoryActivityEvent({
    required this.eventId,
    required this.operationId,
    required this.profileId,
    required this.type,
    required this.storyId,
    required this.recordedAt,
    required this.isIdempotentReplay,
    this.xpAwarded = 0,
    this.levelMilestone,
  });

  final String eventId;
  final String operationId;
  final String profileId;
  final StoryActivityType type;
  final String storyId;
  final DateTime recordedAt;
  final bool isIdempotentReplay;
  final int xpAwarded;
  final LevelMilestone? levelMilestone;

  factory StoryActivityEvent.fromJson(Map<String, dynamic> json) {
    final eventId = _requiredString(json['event_id'], 'event_id');
    final operationId = _requiredString(json['operation_id'], 'operation_id');
    final profileId = _requiredString(json['profile_id'], 'profile_id');
    final storyId = _requiredString(json['story_id'], 'story_id');
    final recordedAtText = _requiredString(json['recorded_at'], 'recorded_at');
    final recordedAt = DateTime.tryParse(recordedAtText);
    if (recordedAt == null) {
      throw const FormatException('Invalid recorded_at value.');
    }
    return StoryActivityEvent(
      eventId: eventId,
      operationId: operationId,
      profileId: profileId,
      type: StoryActivityType.fromWireName(json['event_type']),
      storyId: storyId,
      recordedAt: recordedAt,
      isIdempotentReplay: _boolean(json['idempotent_replay']),
      xpAwarded: _xpAwarded(json['xp_awarded']),
      levelMilestone: LevelMilestone.tryParse(json['level_milestone']),
    );
  }
}

int _xpAwarded(Object? value) {
  if (value == null) return 0;
  if (value is! int || value < 0) {
    throw const FormatException('Invalid XP reward.');
  }
  return value;
}

String _requiredString(Object? value, String field) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) throw FormatException('Missing $field value.');
  return text;
}

bool _boolean(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  return switch (value?.toString().trim().toLowerCase()) {
    'true' || '1' || 'yes' => true,
    _ => false,
  };
}

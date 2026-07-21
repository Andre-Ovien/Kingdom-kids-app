enum StoryTextScale {
  comfortable('comfortable', 'Comfortable'),
  large('large', 'Large'),
  extraLarge('extra_large', 'Extra large');

  const StoryTextScale(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static StoryTextScale fromWireValue(Object? value) {
    final wireValue = value?.toString().trim() ?? '';
    for (final scale in values) {
      if (scale.wireValue == wireValue) return scale;
    }
    throw FormatException('Unknown story text scale: $wireValue');
  }
}

/// Backend-owned reading preferences for one child profile.
class ParentSettings {
  const ParentSettings({
    required this.profileId,
    required this.storyTextScale,
    required this.narrationEnabled,
    required this.updatedAt,
  });

  final String profileId;
  final StoryTextScale storyTextScale;
  final bool narrationEnabled;
  final DateTime updatedAt;

  factory ParentSettings.fromJson(Map<String, dynamic> json) {
    final profileId = json['profile_id']?.toString().trim() ?? '';
    final narrationEnabled = json['narration_enabled'];
    final updatedAt = DateTime.tryParse(
      json['updated_at']?.toString().trim() ?? '',
    );
    if (profileId.isEmpty) {
      throw const FormatException('Missing child profile ID.');
    }
    if (narrationEnabled is! bool) {
      throw const FormatException('Invalid narration preference.');
    }
    if (updatedAt == null) {
      throw const FormatException('Invalid preferences update time.');
    }
    return ParentSettings(
      profileId: profileId,
      storyTextScale: StoryTextScale.fromWireValue(json['story_text_scale']),
      narrationEnabled: narrationEnabled,
      updatedAt: updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'profile_id': profileId,
    'story_text_scale': storyTextScale.wireValue,
    'narration_enabled': narrationEnabled,
    'updated_at': updatedAt.toIso8601String(),
  };
}

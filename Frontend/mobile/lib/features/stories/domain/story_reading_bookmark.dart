import 'story_detail.dart';

enum StoryReadingMode { readAlong, read }

/// Actual narrated coverage; seeking or scrolling never adds a heard range.
class StoryHeardRange {
  const StoryHeardRange(this.start, this.end);

  final int start;
  final int end;

  Map<String, int> toJson() => {'start': start, 'end': end};
}

/// A local reading session, independent from server completion and XP records.
class StoryReadingBookmark {
  const StoryReadingBookmark({
    required this.storyId,
    required this.storySlug,
    required this.bodyFingerprint,
    required this.textOffset,
    required this.updatedAt,
    this.heardRanges = const [],
    this.readingMode = StoryReadingMode.readAlong,
  });

  factory StoryReadingBookmark.forStory({
    required StoryDetail story,
    required int textOffset,
    required DateTime updatedAt,
    List<StoryHeardRange> heardRanges = const [],
    StoryReadingMode readingMode = StoryReadingMode.readAlong,
  }) => StoryReadingBookmark(
    storyId: story.id,
    storySlug: story.slug,
    bodyFingerprint: fingerprintFor(story.body),
    textOffset: textOffset,
    updatedAt: updatedAt,
    heardRanges: List.unmodifiable(heardRanges),
    readingMode: readingMode,
  );

  final String storyId;
  final String storySlug;
  final String bodyFingerprint;
  final int textOffset;
  final DateTime updatedAt;
  final List<StoryHeardRange> heardRanges;
  final StoryReadingMode readingMode;

  bool isForStory(StoryDetail story) =>
      storyId.isNotEmpty && story.id == storyId;

  bool hasCurrentBody(StoryDetail story) =>
      isForStory(story) && bodyFingerprint == fingerprintFor(story.body);

  int resumeOffsetFor(StoryDetail story) => hasCurrentBody(story)
      ? textOffset.clamp(0, story.body.isEmpty ? 0 : story.body.length - 1)
      : 0;

  /// An edition check, not a security hash. Avoids depending on device/runtime
  /// hashCode, which is not guaranteed to stay stable across app launches.
  static String fingerprintFor(String text) {
    var hash = 0;
    for (final unit in text.codeUnits) {
      hash = (hash * 31 + unit) & 0x3fffffff;
    }
    return '${text.length}:${hash.toRadixString(16)}';
  }

  Map<String, dynamic> toJson() => {
    'story_id': storyId,
    'reading_mode': readingMode.name,
    'story_slug': storySlug,
    'body_fingerprint': bodyFingerprint,
    'text_offset': textOffset,
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'heard_ranges': heardRanges.map((range) => range.toJson()).toList(),
  };

  static StoryReadingBookmark? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['story_id'];
    final slug = value['story_slug'];
    final fingerprint = value['body_fingerprint'];
    final offset = value['text_offset'];
    final updated = DateTime.tryParse('${value['updated_at']}');
    if (id is! String ||
        id.isEmpty ||
        slug is! String ||
        fingerprint is! String ||
        fingerprint.isEmpty ||
        offset is! int ||
        offset < 0 ||
        updated == null) {
      return null;
    }
    final ranges = <StoryHeardRange>[];
    final rawRanges = value['heard_ranges'];
    if (rawRanges is List) {
      for (final range in rawRanges) {
        if (range is! Map) continue;
        final start = range['start'];
        final end = range['end'];
        if (start is int && end is int && start >= 0 && end > start) {
          ranges.add(StoryHeardRange(start, end));
        }
      }
    }
    return StoryReadingBookmark(
      storyId: id,
      storySlug: slug,
      bodyFingerprint: fingerprint,
      textOffset: offset,
      updatedAt: updated,
      heardRanges: List.unmodifiable(ranges),
      readingMode: value['reading_mode'] == 'read'
          ? StoryReadingMode.read
          : StoryReadingMode.readAlong,
    );
  }
}

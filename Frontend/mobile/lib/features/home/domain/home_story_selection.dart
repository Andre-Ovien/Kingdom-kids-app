import '../../stories/domain/story_availability.dart';
import '../../stories/domain/story_detail.dart';
import '../../stories/domain/story_reading_bookmark.dart';

/// Matches this child's saved reading progress to the current backend library.
///
/// Callers must supply bookmarks loaded for the active parent and child. Merely
/// opening a story at offset zero is not evidence of reading. A saved position
/// or actual narrated coverage is. Completion removes its bookmark in the
/// readers; a missing bookmark is never interpreted as a completed story here.
List<StoryDetail> unfinishedHomeStories({
  required List<StoryDetail> stories,
  required List<StoryReadingBookmark> bookmarks,
}) {
  final catalogue = {
    for (final story in _availableStories(stories)) story.id: story,
  };
  final latest = <String, StoryReadingBookmark>{};
  for (final bookmark in bookmarks) {
    final previous = latest[bookmark.storyId];
    if (previous == null || bookmark.updatedAt.isAfter(previous.updatedAt)) {
      latest[bookmark.storyId] = bookmark;
    }
  }
  final ordered = latest.values.toList()
    ..sort((a, b) {
      final recency = b.updatedAt.compareTo(a.updatedAt);
      return recency != 0 ? recency : a.storyId.compareTo(b.storyId);
    });
  return List<StoryDetail>.unmodifiable([
    for (final bookmark in ordered)
      if (catalogue[bookmark.storyId] case final story?)
        if (_hasReadingProgress(bookmark)) story,
  ]);
}

/// One backend story per child and local calendar day, without timers or state.
///
/// Stable ID ordering keeps a catalogue reorder or Home rebuild from replacing
/// the card. Calendar-day rotation provides a new choice the next day whenever
/// there is more than one story. This deliberately makes no claim that a story
/// is unread: the catalogue does not expose per-child completion history, and
/// previously completed stories remain available to enjoy again.
StoryDetail? selectDailyHomeStory({
  required List<StoryDetail> stories,
  required String profileId,
  required DateTime localDate,
}) {
  if (profileId.trim().isEmpty) return null;
  final catalogue = _availableStories(stories)
    ..sort((a, b) => a.id.compareTo(b.id));
  if (catalogue.isEmpty) return null;
  // Use civil date components, rather than elapsed local hours, so daylight
  // saving changes cannot repeat or skip the daily slot.
  final day = DateTime.utc(
    localDate.year,
    localDate.month,
    localDate.day,
  ).difference(DateTime.utc(1970)).inDays;
  final index = (_stableHash(profileId) + day) % catalogue.length;
  return catalogue[index];
}

List<StoryDetail> _availableStories(List<StoryDetail> stories) {
  final byId = <String, StoryDetail>{};
  for (final story in stories) {
    if (story.id.trim().isEmpty ||
        story.slug.trim().isEmpty ||
        !isStoryAvailable(story.slug)) {
      continue;
    }
    byId.putIfAbsent(story.id, () => story);
  }
  return byId.values.toList();
}

bool _hasReadingProgress(StoryReadingBookmark bookmark) =>
    bookmark.textOffset > 0 ||
    bookmark.heardRanges.any(
      (range) => range.start >= 0 && range.end > range.start,
    );

int _stableHash(String value) {
  var hash = 0;
  for (final codeUnit in value.codeUnits) {
    hash = (hash * 31 + codeUnit) & 0x3fffffff;
  }
  return hash;
}

import 'story_detail.dart';

/// Explicitly continues an unfinished visual reading session.
class StoryReadingArguments {
  const StoryReadingArguments({
    required this.story,
    this.resumeReading = false,
  });

  final StoryDetail story;
  final bool resumeReading;
}

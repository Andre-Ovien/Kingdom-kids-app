import 'story_detail.dart';

/// An explicit resume action, while ordinary story launches still start fresh.
class StoryReadAlongArguments {
  const StoryReadAlongArguments({
    required this.story,
    this.resumeReading = false,
  });

  final StoryDetail story;
  final bool resumeReading;
}

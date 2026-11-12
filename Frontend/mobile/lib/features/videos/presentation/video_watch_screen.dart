import 'package:flutter/material.dart';

import '../domain/video_story.dart';
import 'videos_screen.dart';

/// Legacy route kept so an old notification or saved route remains safe.
///
/// The beta does not expose placeholder playback. Any attempt to open a former
/// video detail route lands on the same honest coming-soon destination instead
/// of a player with a nonfunctional Play button.
class VideoWatchScreen extends StatelessWidget {
  const VideoWatchScreen({required this.video, super.key});

  final VideoStory video;

  @override
  Widget build(BuildContext context) {
    return const VideosScreen(key: Key('video-detail-coming-soon'));
  }
}

import 'package:flutter/material.dart';

import '../domain/video_story.dart';

class VideoRepository {
  const VideoRepository();

  static const items = [
    VideoStory.fallback,
    VideoStory(
      id: 'jonah-big-fish',
      title: 'Jonah and the Big Fish',
      category: 'Mercy',
      duration: '6 min',
      imageAsset: 'assets/images/jonah.jpg',
      description:
          'Jonah learns that God gives second chances. Kids follow the storm, '
          'the big fish, and the choice to listen again.',
      videoUrl: 'local://jonah-big-fish',
      progress: 0.42,
    ),
    VideoStory(
      id: 'red-sea',
      title: 'Crossing the Red Sea',
      category: 'Miracle',
      duration: '7 min',
      imageAsset: 'assets/images/crossing_red_sea.webp',
      description:
          'Moses and God\'s people stand before the sea and learn that God can '
          'make a way when there seems to be no way.',
      videoUrl: 'local://red-sea',
      progress: 0.64,
      imageAlignment: Alignment(-0.38, 0),
    ),
    VideoStory(
      id: 'noah-ark',
      title: 'Noah Builds the Ark',
      category: 'Obedience',
      duration: '8 min',
      imageAsset: 'assets/images/noahs_ark.png',
      description:
          'Noah listens to God, builds the ark, and cares for his family and '
          'the animals through the rain.',
      videoUrl: 'local://noah-ark',
      imageAlignment: Alignment(-0.4, 0),
    ),
    VideoStory(
      id: 'creation-week',
      title: 'Creation Week',
      category: 'Wonder',
      duration: '5 min',
      imageAsset: 'assets/images/creation_week.jpg',
      description:
          'A gentle look at the days of creation, from light and sky to animals '
          'and people, ending with rest and worship.',
      videoUrl: 'local://creation-week',
    ),
    VideoStory(
      id: 'daniel-lions',
      title: 'Daniel in the Lions\' Den',
      category: 'Faith',
      duration: '6 min',
      imageAsset: 'assets/images/daniel.jpeg',
      description:
          'Daniel keeps praying and discovers that God is near, even in a hard '
          'and scary place.',
      videoUrl: 'local://daniel-lions',
      imageAlignment: Alignment(0, -0.12),
    ),
    VideoStory(
      id: 'moses-called',
      title: 'Moses Is Called',
      category: 'Adventure',
      duration: '7 min',
      imageAsset: 'assets/images/moses2.jpeg',
      description:
          'Moses learns that God can use him for brave work, one obedient step '
          'at a time.',
      videoUrl: 'local://moses-called',
    ),
    VideoStory(
      id: 'queen-esther',
      title: 'Queen Esther',
      category: 'Bravery',
      duration: '6 min',
      imageAsset: 'assets/images/esther.jpeg',
      description:
          'Esther chooses courage and kindness when her people need help.',
      videoUrl: 'local://queen-esther',
    ),
  ];

  Future<List<VideoStory>> fetchVideos() async {
    return items;
  }
}

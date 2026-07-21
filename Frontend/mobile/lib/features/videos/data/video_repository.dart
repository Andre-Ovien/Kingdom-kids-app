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
      imageAsset: 'assets/images/stories/jonah-and-the-big-fish-v2.webp',
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
      imageAsset: 'assets/images/stories/crossing-the-red-sea-v2.webp',
      description:
          'Moses and God\'s people stand before the sea and learn that God can '
          'make a way when there seems to be no way.',
      videoUrl: 'local://red-sea',
      progress: 0.64,
    ),
    VideoStory(
      id: 'noah-ark',
      title: 'Noah Builds the Ark',
      category: 'Obedience',
      duration: '8 min',
      imageAsset: 'assets/images/stories/noah-builds-the-ark-v2.webp',
      description:
          'Noah listens to God, builds the ark, and cares for his family and '
          'the animals through the rain.',
      videoUrl: 'local://noah-ark',
    ),
    VideoStory(
      id: 'creation-week',
      title: 'Creation Week',
      category: 'Wonder',
      duration: '5 min',
      imageAsset: 'assets/images/stories/creation-week-v2.webp',
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
      imageAsset: 'assets/images/stories/daniel-in-the-lions-den-v2.webp',
      description:
          'Daniel keeps praying and discovers that God is near, even in a hard '
          'and scary place.',
      videoUrl: 'local://daniel-lions',
    ),
    VideoStory(
      id: 'moses-called',
      title: 'Moses Is Called',
      category: 'Adventure',
      duration: '7 min',
      imageAsset: 'assets/images/stories/moses-follows-god-v2.webp',
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
      imageAsset: 'assets/images/stories/esther-speaks-up-v2.webp',
      description:
          'Esther chooses courage and kindness when her people need help.',
      videoUrl: 'local://queen-esther',
    ),
  ];

  Future<List<VideoStory>> fetchVideos() async {
    return items;
  }
}

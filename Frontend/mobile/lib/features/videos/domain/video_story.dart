import 'package:flutter/material.dart';

class VideoStory {
  const VideoStory({
    required this.id,
    required this.title,
    required this.category,
    required this.duration,
    required this.imageAsset,
    required this.description,
    required this.videoUrl,
    this.progress = 0,
    this.imageAlignment = Alignment.center,
  });

  final String id;
  final String title;
  final String category;
  final String duration;
  final String imageAsset;
  final String description;
  final String videoUrl;
  final double progress;
  final Alignment imageAlignment;

  static const fallback = VideoStory(
    id: 'david-and-goliath',
    title: 'David & Goliath',
    category: 'Courage',
    duration: '5 min',
    imageAsset: 'assets/images/david_and_goliath.png',
    description:
        'Watch David trust God with a brave heart. This short Bible video helps '
        'kids see that courage can start small when God is with them.',
    videoUrl: 'local://david-and-goliath',
    imageAlignment: Alignment(0.35, 0),
  );
}

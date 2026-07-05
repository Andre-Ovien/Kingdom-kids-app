import 'package:flutter/widgets.dart';

class StoryDetail {
  const StoryDetail({
    required this.title,
    required this.author,
    required this.category,
    required this.imageAsset,
    required this.description,
    this.imageAlignment = Alignment.center,
    this.rating = '4.8',
    this.reviewCount = '2k',
  });

  final String title;
  final String author;
  final String category;
  final String imageAsset;
  final Alignment imageAlignment;
  final String rating;
  final String reviewCount;
  final String description;

  static const fallback = StoryDetail(
    title: 'David & Goliath',
    author: 'Kingdom Kids',
    category: 'Bible story',
    imageAsset: 'assets/images/david_and_goliath.png',
    imageAlignment: Alignment(0.2, 0.1),
    description:
        'David was a young shepherd who trusted God with his whole heart. '
        'When the giant Goliath frightened the army, David remembered how God '
        'had helped him protect his sheep before.\n\n'
        'With a sling, five smooth stones, and brave faith, David stepped '
        'forward. This story reminds kids that courage grows when we remember '
        'God is with us.\n\n'
        'David did not need heavy armor to do what was right. Children can '
        'learn that a faithful heart, a listening spirit, and trust in God are '
        'stronger than fear.\n\n'
        'When the battle was over, everyone saw that the victory belonged to '
        'God. David\'s story helps kids remember that small hands can do brave '
        'things with God\'s help.',
  );
}

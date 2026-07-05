import 'package:flutter/widgets.dart';

import '../domain/story_detail.dart';

class StoryCatalog {
  const StoryCatalog._();

  static const items = [
    StoryDetail.fallback,
    StoryDetail(
      title: 'Jonah and the Big Fish',
      author: 'Kingdom Kids',
      category: 'Mercy',
      imageAsset: 'assets/images/jonah.jpg',
      rating: '4.6',
      reviewCount: '1.5k',
      description:
          'Jonah tried to run away from what God asked him to do. A storm, a '
          'great fish, and three quiet days helped Jonah learn that God\'s '
          'mercy is bigger than fear.\n\n'
          'This story helps kids talk about second chances, listening to God, '
          'and choosing kindness even when it is hard.\n\n'
          'Jonah learned that God cares for people we may not understand. '
          'Children can see that mercy is wide, patient, and full of hope.',
    ),
    StoryDetail(
      title: 'Crossing the Red Sea',
      author: 'Kingdom Kids',
      category: 'Miracle',
      imageAsset: 'assets/images/crossing_red_sea.webp',
      imageAlignment: Alignment(-0.38, 0),
      rating: '4.9',
      reviewCount: '3k',
      description:
          'The Israelites stood at the edge of the sea with danger behind them '
          'and no road ahead. God told Moses to lift his staff, and the water '
          'opened into a dry path.\n\n'
          'Kids will see that God can make a way when things feel impossible '
          'and that trusting Him can move us forward.\n\n'
          'When they reached the other side, the people sang and celebrated. '
          'They remembered that God had rescued them with mighty love.',
    ),
    StoryDetail(
      title: 'Noah Builds the Ark',
      author: 'Kingdom Kids',
      category: 'Faith',
      imageAsset: 'assets/images/noahs_ark.png',
      imageAlignment: Alignment(-0.4, 0),
      rating: '4.7',
      reviewCount: '1.8k',
      description:
          'Noah loved God and listened carefully, even when the job seemed too '
          'big. God told Noah to build an ark because a great flood was coming, '
          'and Noah obeyed one step at a time.\n\n'
          'This story helps kids see that obedience matters. Noah trusted God, '
          'cared for his family, and welcomed the animals safely into the ark.\n\n'
          'After the rain, God placed a rainbow in the sky as a promise.',
    ),
    StoryDetail(
      title: 'Creation Week',
      author: 'Kingdom Kids',
      category: 'Wonder',
      imageAsset: 'assets/images/creation_week.jpg',
      rating: '4.9',
      reviewCount: '2.4k',
      description:
          'In the beginning, God made the heavens and the earth. Day by day, He '
          'filled the world with light, sky, land, seas, plants, stars, animals, '
          'and people.\n\n'
          'Creation Week invites kids to slow down and notice God\'s good world '
          'with wonder, gratitude, and joy.\n\n'
          'Every flower, ocean, animal, and star points back to God\'s care.',
    ),
    StoryDetail(
      title: 'Daniel',
      author: 'Kingdom Kids',
      category: 'Courage',
      imageAsset: 'assets/images/daniel.jpeg',
      imageAlignment: Alignment(0, -0.12),
      description:
          'Daniel kept praying to God even when it became dangerous. When he was '
          'thrown into the lions\' den, God protected him through the night.\n\n'
          'Daniel did not have to be loud to be brave. His quiet trust teaches '
          'children that prayer can give courage even when everyone else is afraid.',
    ),
    StoryDetail(
      title: 'Moses',
      author: 'Kingdom Kids',
      category: 'Adventure',
      imageAsset: 'assets/images/moses2.jpeg',
      description:
          'Moses learned that God can use ordinary people for brave work. From '
          'the burning bush to leading God\'s people, Moses had to trust God one '
          'step at a time.\n\n'
          'Through each challenge, Moses learned to listen for God\'s voice. His '
          'story reminds kids that leadership starts with obedience.',
    ),
    StoryDetail(
      title: 'Esther',
      author: 'Kingdom Kids',
      category: 'Bravery',
      imageAsset: 'assets/images/esther.jpeg',
      description:
          'Esther became queen at a time when her people needed help. With '
          'wisdom and courage, she spoke up even though it was scary.\n\n'
          'Because Esther cared for others, her brave choice helped save many '
          'lives. Her story makes kindness feel strong.',
    ),
  ];
}

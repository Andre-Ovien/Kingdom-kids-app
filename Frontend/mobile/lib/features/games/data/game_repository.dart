import 'package:flutter/material.dart';

import '../domain/mini_game.dart';

class GameRepository {
  const GameRepository();

  static const items = [
    MiniGame.fallback,
    MiniGame(
      id: 'creation-order',
      title: 'Creation Order',
      type: MiniGameType.dragAndDrop,
      difficulty: 'Easy',
      duration: '4 min',
      imageAsset: 'assets/images/creation_week.jpg',
      description:
          'Drag the days of creation into the right order. A gentle sequencing '
          'game for learning how God made the world day by day.',
      rewardStars: 12,
      totalLevels: 6,
      currentLevel: 3,
      progress: 0.5,
    ),
    MiniGame(
      id: 'david-sling-shot',
      title: 'David\'s Sling Aim',
      type: MiniGameType.puzzle,
      difficulty: 'Medium',
      duration: '5 min',
      imageAsset: 'assets/images/david_and_goliath.png',
      description:
          'Help David aim carefully by solving simple path puzzles. Kids learn '
          'that courage and focus can work together.',
      rewardStars: 15,
      totalLevels: 5,
      imageAlignment: Alignment(0.35, 0),
    ),
    MiniGame(
      id: 'jonah-ocean-maze',
      title: 'Jonah Ocean Maze',
      type: MiniGameType.puzzle,
      difficulty: 'Medium',
      duration: '4 min',
      imageAsset: 'assets/images/jonah.jpg',
      description:
          'Guide Jonah through an ocean maze and learn about listening, mercy, '
          'and second chances.',
      rewardStars: 15,
      totalLevels: 4,
    ),
    MiniGame(
      id: 'red-sea-path',
      title: 'Red Sea Path',
      type: MiniGameType.dragAndDrop,
      difficulty: 'Easy',
      duration: '4 min',
      imageAsset: 'assets/images/crossing_red_sea.webp',
      description:
          'Move the people safely along the path God opened through the sea. '
          'A simple drag game about trust and rescue.',
      rewardStars: 12,
      totalLevels: 5,
      imageAlignment: Alignment(-0.38, 0),
    ),
    MiniGame(
      id: 'daniel-memory',
      title: 'Daniel Memory Match',
      type: MiniGameType.memory,
      difficulty: 'Easy',
      duration: '3 min',
      imageAsset: 'assets/images/daniel.jpeg',
      description:
          'Flip cards and match symbols from Daniel\'s story: prayer, courage, '
          'lions, and God\'s protection.',
      rewardStars: 10,
      totalLevels: 5,
      imageAlignment: Alignment(0, -0.12),
    ),
    MiniGame(
      id: 'esther-quiz',
      title: 'Esther Brave Quiz',
      type: MiniGameType.quiz,
      difficulty: 'Easy',
      duration: '3 min',
      imageAsset: 'assets/images/esther.jpeg',
      description:
          'Answer gentle questions about Esther\'s brave choice and how God can '
          'use kindness at the right time.',
      rewardStars: 10,
      totalLevels: 4,
    ),
    MiniGame(
      id: 'moses-match',
      title: 'Moses Mission Match',
      type: MiniGameType.matching,
      difficulty: 'Medium',
      duration: '5 min',
      imageAsset: 'assets/images/moses2.jpeg',
      description:
          'Match Moses story items like the staff, sandals, river, and tablets '
          'while learning how God leads His people.',
      rewardStars: 15,
      totalLevels: 6,
    ),
  ];

  Future<List<MiniGame>> fetchGames() async {
    return items;
  }
}

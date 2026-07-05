import 'package:flutter/material.dart';

enum MiniGameType { dragAndDrop, matching, memory, quiz, puzzle }

class MiniGame {
  const MiniGame({
    required this.id,
    required this.title,
    required this.type,
    required this.difficulty,
    required this.duration,
    required this.imageAsset,
    required this.description,
    required this.rewardStars,
    required this.totalLevels,
    this.currentLevel = 1,
    this.progress = 0,
    this.imageAlignment = Alignment.center,
  });

  final String id;
  final String title;
  final MiniGameType type;
  final String difficulty;
  final String duration;
  final String imageAsset;
  final String description;
  final int rewardStars;
  final int totalLevels;
  final int currentLevel;
  final double progress;
  final Alignment imageAlignment;

  String get typeLabel {
    return switch (type) {
      MiniGameType.dragAndDrop => 'Drag',
      MiniGameType.matching => 'Match',
      MiniGameType.memory => 'Memory',
      MiniGameType.quiz => 'Quiz',
      MiniGameType.puzzle => 'Puzzle',
    };
  }

  static const fallback = MiniGame(
    id: 'ark-animal-match',
    title: 'Match the Ark Animals',
    type: MiniGameType.matching,
    difficulty: 'Easy',
    duration: '3 min',
    imageAsset: 'assets/images/noahs_ark.png',
    description:
        'Pair the animals that came into Noah\'s ark. Kids practice matching, '
        'memory, and careful looking while remembering how God cared for Noah.',
    rewardStars: 10,
    totalLevels: 5,
    currentLevel: 2,
    progress: 0.42,
    imageAlignment: Alignment(-0.4, 0),
  );
}

import 'dart:collection';

import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../milestones/domain/level_milestone.dart';

/// The game engines understood by the backend and mobile app.
enum GameType { quiz, memory, ordering, matching, maze, path, aim, puzzle }

/// Catalogue sections describe the activity, independently of its wire engine.
enum GameCategory { puzzle, quiz, game, matching }

extension GameCategoryLabel on GameCategory {
  String get label => switch (this) {
    GameCategory.puzzle => 'Puzzles',
    GameCategory.quiz => 'Quizzes',
    GameCategory.game => 'Games',
    GameCategory.matching => 'Matching',
  };
}

extension GameTypeValue on GameType {
  String get wireName => name;

  String get label => switch (this) {
    GameType.quiz => 'Quiz',
    GameType.memory => 'Memory',
    GameType.ordering => 'Order',
    GameType.matching => 'Match',
    GameType.maze => 'Maze',
    GameType.path => 'Path',
    GameType.aim => 'Aim',
    GameType.puzzle => 'Puzzle',
  };

  MiniGameType get legacyType => switch (this) {
    GameType.quiz => MiniGameType.quiz,
    GameType.memory => MiniGameType.memory,
    GameType.matching => MiniGameType.matching,
    GameType.ordering || GameType.path => MiniGameType.dragAndDrop,
    GameType.maze || GameType.aim => MiniGameType.puzzle,
    GameType.puzzle => MiniGameType.jigsaw,
  };

  static GameType parse(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    return switch (normalized) {
      'quiz' => GameType.quiz,
      'memory' => GameType.memory,
      'ordering' || 'order' || 'drag_and_drop' => GameType.ordering,
      'matching' || 'match' => GameType.matching,
      'maze' => GameType.maze,
      'path' => GameType.path,
      'aim' || 'aiming' => GameType.aim,
      'puzzle' || 'jigsaw' => GameType.puzzle,
      _ => throw FormatException('Unsupported game type: $value'),
    };
  }
}

/// Kept as a presentation compatibility bridge while the screens migrate to
/// the backend-driven [GameType] engines. The older `puzzle` value still maps
/// to the maze engine; `jigsaw` is reserved for Puzzle Quest.
enum MiniGameType { dragAndDrop, matching, memory, quiz, puzzle, jigsaw }

/// One ordered, server-authored level. Engine-specific content stays in
/// [config], allowing new content to be shipped without a mobile app release.
class GameLevel {
  GameLevel({
    required this.id,
    required this.number,
    required this.title,
    required this.instructions,
    required Map<String, dynamic> config,
    required this.maxScore,
  }) : config = UnmodifiableMapView(_deepStringMap(config));

  final String id;
  final int number;
  final String title;
  final String instructions;
  final Map<String, dynamic> config;
  final int maxScore;

  factory GameLevel.fromJson(Map<String, dynamic> json) {
    final number = _asInt(json['level_number'] ?? json['number']);
    if (number < 1) {
      throw const FormatException('A game level needs a positive number.');
    }
    final maxScore = _asInt(json['max_score']);
    if (maxScore < 1) {
      throw const FormatException('A game level needs a positive max score.');
    }

    return GameLevel(
      id: _string(json['id'], fallback: 'level-$number'),
      number: number,
      title: _string(json['title'], fallback: 'Level $number'),
      instructions: _string(json['instructions']),
      maxScore: maxScore,
      config: _asMap(json['config']),
    );
  }

  T? configValue<T>(String key) {
    final value = config[key];
    return value is T ? value : null;
  }
}

/// Progress belongs to one kid profile; the parent token only authorizes it.
class GameProgress {
  const GameProgress({
    this.profileId = '',
    this.highestCompletedLevel = 0,
    this.currentLevel = 1,
    this.completedLevels = 0,
    this.totalLevels = 0,
    this.bestScore = 0,
    this.starsEarned = 0,
    this.maxStars = 0,
    this.percent = 0,
    this.lastPlayedAt,
  });

  final String profileId;
  final int highestCompletedLevel;
  final int currentLevel;
  final int completedLevels;
  final int totalLevels;
  final int bestScore;
  final int starsEarned;
  final int maxStars;

  /// Normalized to the inclusive 0...1 range.
  final double percent;
  final DateTime? lastPlayedAt;

  bool get hasStarted => completedLevels > 0 || starsEarned > 0;
  bool get isComplete => totalLevels > 0 && completedLevels >= totalLevels;

  factory GameProgress.fromJson(
    Map<String, dynamic> json, {
    int fallbackTotalLevels = 0,
    String fallbackProfileId = '',
  }) {
    final completedValue = json['completed_levels'];
    final completedLevels = completedValue is List
        ? completedValue.length
        : _asInt(completedValue);
    final totalLevels = _asInt(
      json['total_levels'],
      fallback: fallbackTotalLevels,
    );
    final highestCompleted = _asInt(
      json['highest_completed_level'],
      fallback: completedLevels,
    );
    final rawPercent = _asDouble(
      json['percent'] ?? json['completion_percent'],
      fallback: totalLevels > 0 ? completedLevels / totalLevels : 0,
    );
    final normalizedPercent = rawPercent > 1 ? rawPercent / 100 : rawPercent;
    final nextLevel = totalLevels == 0
        ? highestCompleted + 1
        : (highestCompleted + 1).clamp(1, totalLevels);

    return GameProgress(
      profileId: _string(
        json['profile_id'] ?? json['profile'],
        fallback: fallbackProfileId,
      ),
      highestCompletedLevel: highestCompleted,
      currentLevel: _asInt(json['current_level'], fallback: nextLevel),
      completedLevels: completedLevels,
      totalLevels: totalLevels,
      bestScore: _asInt(json['best_score']),
      starsEarned: _asInt(json['total_stars'] ?? json['stars_earned']),
      maxStars: _asInt(json['max_stars']),
      percent: normalizedPercent.clamp(0, 1),
      lastPlayedAt: _asDate(json['last_played_at']),
    );
  }

  static const empty = GameProgress();
}

/// The authoritative result returned after one idempotent level submission.
class GameSubmission {
  const GameSubmission({
    required this.attemptId,
    required this.operationId,
    required this.gameSlug,
    required this.profileId,
    required this.levelNumber,
    required this.completed,
    required this.correct,
    required this.score,
    required this.maxScore,
    required this.starsAwarded,
    required this.feedback,
    required this.progress,
    required this.idempotentReplay,
    this.levelMilestone,
  });

  final String attemptId;
  final String operationId;
  final String gameSlug;
  final String profileId;
  final int levelNumber;
  final bool completed;
  final bool correct;
  final int score;
  final int maxScore;
  final int starsAwarded;
  final String feedback;
  final GameProgress progress;
  final bool idempotentReplay;
  final LevelMilestone? levelMilestone;

  factory GameSubmission.fromJson(Map<String, dynamic> json) {
    final score = _asInt(json['score']);
    final maxScore = _asInt(json['max_score']);
    final completed = _asBool(json['completed']);
    return GameSubmission(
      attemptId: _string(json['attempt_id'] ?? json['id']),
      operationId: _string(json['operation_id']),
      gameSlug: _string(json['game_slug'] ?? json['slug']),
      profileId: _string(json['profile_id'] ?? json['profile']),
      levelNumber: _asInt(json['level_number']),
      completed: completed,
      correct: _asBool(
        json['correct'] ?? json['is_correct'],
        fallback: completed && maxScore > 0 && score == maxScore,
      ),
      score: score,
      maxScore: maxScore,
      starsAwarded: _asInt(json['stars'] ?? json['stars_awarded']),
      feedback: _string(json['feedback'] ?? json['message']),
      progress: GameProgress.fromJson(
        _asMap(json['progress']),
        fallbackProfileId: _string(json['profile_id'] ?? json['profile']),
      ),
      idempotentReplay: _asBool(json['idempotent_replay']),
      levelMilestone: LevelMilestone.tryParse(json['level_milestone']),
    );
  }
}

typedef GameSubmissionResult = GameSubmission;

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
    this.slug = '',
    this.subtitle = '',
    GameType? gameType,
    this.estimatedDurationSeconds = 0,
    this.coverAssetKey = '',
    this.coverImageUrl,
    this.accentColor = '#FF7043',
    this.iconKey = 'games',
    this.currentLevel = 1,
    this.progress = 0,
    this.playerProgress = GameProgress.empty,
    this.levels = const [],
    this.isFeatured = false,
    this.imageAlignment = Alignment.center,
  }) : _gameType = gameType;

  final String id;
  final String slug;
  final String title;
  final String subtitle;
  final MiniGameType type;
  final GameType? _gameType;
  final String difficulty;
  final String duration;
  final int estimatedDurationSeconds;
  final String imageAsset;
  final String coverAssetKey;
  final String? coverImageUrl;
  final String accentColor;
  final String iconKey;
  final String description;
  final int rewardStars;
  final int totalLevels;
  final int currentLevel;
  final double progress;
  final GameProgress playerProgress;
  final List<GameLevel> levels;
  final bool isFeatured;
  final Alignment imageAlignment;

  GameType get gameType =>
      _gameType ??
      switch (type) {
        MiniGameType.quiz => GameType.quiz,
        MiniGameType.memory => GameType.memory,
        MiniGameType.matching => GameType.matching,
        MiniGameType.dragAndDrop => GameType.ordering,
        MiniGameType.puzzle => GameType.maze,
        MiniGameType.jigsaw => GameType.puzzle,
      };

  // Catalogue summaries omit level configs, so the garden's stable identity
  // must also identify it before its detail is fetched. Its matching wire type
  // remains the engine/API dispatch contract, not its presentation category.
  bool get isArkGarden =>
      slug == 'noahs-ark-garden' ||
      (gameType == GameType.matching &&
          levels.any((level) => level.config['mode'] == 'ark_garden'));

  GameCategory get category => switch (gameType) {
    GameType.puzzle => GameCategory.puzzle,
    GameType.quiz => GameCategory.quiz,
    GameType.matching when !isArkGarden => GameCategory.matching,
    _ => GameCategory.game,
  };

  String get typeLabel => isArkGarden ? 'Game' : gameType.label;
  bool get hasStarted => playerProgress.hasStarted;

  GameLevel? level(int levelNumber) {
    for (final level in levels) {
      if (level.number == levelNumber) {
        return level;
      }
    }
    return null;
  }

  factory MiniGame.fromJson(
    Map<String, dynamic> json, {
    ContentMediaPolicy mediaPolicy = AppConfig.contentMediaPolicy,
  }) {
    final gameType = GameTypeValue.parse(json['game_type'] ?? json['type']);
    final slug = _string(json['slug'] ?? json['id']);
    if (slug.isEmpty) {
      throw const FormatException('A game needs a slug.');
    }
    final rawLevels = json['levels'];
    final levels = rawLevels is List
        ? rawLevels
              .whereType<Map>()
              .map((value) => GameLevel.fromJson(_asMap(value)))
              .toList(growable: false)
        : <GameLevel>[];
    levels.sort((left, right) => left.number.compareTo(right.number));

    final totalLevels = _asInt(
      json['total_levels'] ?? json['level_count'],
      fallback: levels.length,
    );
    final progress = GameProgress.fromJson(
      _asMap(json['progress']),
      fallbackTotalLevels: totalLevels,
    );
    final durationSeconds = _asInt(
      json['estimated_duration_seconds'] ?? json['duration_seconds'],
    );
    final coverAssetKey = _coverAsset(
      slug,
      gameType,
      _string(json['cover_asset_key'] ?? json['image_asset']),
    );

    return MiniGame(
      id: _string(json['id'], fallback: slug),
      slug: slug,
      title: _string(json['title'], fallback: 'Bible Game'),
      subtitle: _string(json['subtitle']),
      type: gameType.legacyType,
      gameType: gameType,
      difficulty: _string(json['difficulty'], fallback: 'Easy'),
      duration: _string(
        json['duration'],
        fallback: _durationLabel(durationSeconds),
      ),
      estimatedDurationSeconds: durationSeconds,
      imageAsset: coverAssetKey,
      coverAssetKey: coverAssetKey,
      coverImageUrl: mediaPolicy.sanitize(
        json['cover_image_url'] ?? json['image_url'],
      ),
      accentColor: _string(json['accent_color'], fallback: '#FF7043'),
      iconKey: _string(json['icon_key'], fallback: gameType.wireName),
      description: _string(
        json['description'],
        fallback: _string(json['subtitle']),
      ),
      rewardStars: _asInt(
        json['reward_stars'] ?? json['max_stars'],
        fallback: progress.maxStars,
      ),
      totalLevels: totalLevels,
      currentLevel: progress.currentLevel,
      progress: progress.percent,
      playerProgress: progress,
      levels: List.unmodifiable(levels),
      isFeatured: _asBool(json['is_featured']),
      imageAlignment: Alignment(
        _asDouble(json['cover_focus_x']),
        _asDouble(json['cover_focus_y']),
      ),
    );
  }
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map(
      (key, nestedValue) => MapEntry(key.toString(), nestedValue),
    );
  }
  return const {};
}

Map<String, dynamic> _deepStringMap(Map<String, dynamic> source) {
  Object? convert(Object? value) {
    if (value is Map) {
      return value.map(
        (key, nestedValue) => MapEntry(key.toString(), convert(nestedValue)),
      );
    }
    if (value is List) {
      return List<Object?>.unmodifiable(value.map(convert));
    }
    return value;
  }

  return source.map((key, value) => MapEntry(key, convert(value)));
}

String _string(Object? value, {String fallback = ''}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

int _asInt(Object? value, {int fallback = 0}) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

double _asDouble(Object? value, {double fallback = 0}) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}

bool _asBool(Object? value, {bool fallback = false}) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  return switch (value?.toString().toLowerCase()) {
    'true' || 'yes' || '1' => true,
    'false' || 'no' || '0' => false,
    _ => fallback,
  };
}

DateTime? _asDate(Object? value) {
  final text = _string(value);
  return text.isEmpty ? null : DateTime.tryParse(text);
}

String _durationLabel(int seconds) {
  if (seconds <= 0) {
    return '3 min';
  }
  final minutes = (seconds / 60).ceil();
  return '$minutes min';
}

const _canonicalGameCoverAssets = <String, String>{
  'noahs-ark-garden': 'assets/images/stories/noah-builds-the-ark-v2.webp',
  'ark-animal-match': 'assets/images/stories/noah-builds-the-ark-v2.webp',
  'creation-order': 'assets/images/stories/creation-week-v2.webp',
  'david-sling-shot': 'assets/images/stories/david-and-goliath-v2.webp',
  'david-sling-aim': 'assets/images/stories/david-and-goliath-v2.webp',
  'jonah-ocean-maze': 'assets/images/stories/jonah-and-the-big-fish-v2.webp',
  'red-sea-path': 'assets/images/stories/crossing-the-red-sea-v2.webp',
  'daniel-memory': 'assets/images/stories/daniel-in-the-lions-den-v2.webp',
  'esther-quiz': 'assets/images/stories/esther-speaks-up-v2.webp',
  'moses-match': 'assets/images/stories/moses-follows-god-v2.webp',
  'puzzle-quest': 'assets/images/games/puzzle_quest/puzzle-quest-cover-v1.webp',
};

String _coverAsset(String slug, GameType type, String backendAsset) {
  // These games deliberately share the same visual world as their stories.
  // Prefer the bundled canonical cover even while a device is talking to a
  // backend that has not applied the matching data migration yet.
  final canonicalAsset = _canonicalGameCoverAssets[slug];
  if (canonicalAsset != null) return canonicalAsset;
  if (backendAsset.isNotEmpty) return backendAsset;
  return _fallbackAsset(type);
}

String _fallbackAsset(GameType type) {
  return switch (type) {
    GameType.quiz => 'assets/images/stories/esther-speaks-up-v2.webp',
    GameType.memory => 'assets/images/stories/daniel-in-the-lions-den-v2.webp',
    GameType.ordering => 'assets/images/stories/creation-week-v2.webp',
    GameType.matching => 'assets/images/stories/noah-builds-the-ark-v2.webp',
    GameType.maze => 'assets/images/stories/jonah-and-the-big-fish-v2.webp',
    GameType.path => 'assets/images/stories/crossing-the-red-sea-v2.webp',
    GameType.aim => 'assets/images/stories/david-and-goliath-v2.webp',
    GameType.puzzle =>
      'assets/images/games/puzzle_quest/puzzle-quest-cover-v1.webp',
  };
}

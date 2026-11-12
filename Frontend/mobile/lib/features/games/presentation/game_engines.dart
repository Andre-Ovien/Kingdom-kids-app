import 'package:flutter/material.dart';

import '../domain/mini_game.dart';
import 'ark_boarding_engine.dart';
import 'ark_garden_engine.dart';
import 'ark_garden_native_engine.dart';
import 'ark_traffic_engine.dart';
import 'creation_world_engine.dart';
import 'david_sling_engine.dart';
import 'puzzle_quest_engine.dart';
import 'joseph_coat_engine.dart';
import 'ruth_harvest_engine.dart';
import 'find_my_sheep_engine.dart';
import 'creation_bloom_engine.dart';
import 'esther_table_engine.dart';
import 'sea_journey_engine.dart';
import 'storybook_game_engines.dart';
import 'wise_builders_engine.dart';

typedef GameEngineComplete = void Function(Map<String, dynamic> result);

/// Routes each authored level to its story-specific interaction. Only the
/// server decides whether the submitted choices earn completion or rewards.
class GameLevelEngine extends StatelessWidget {
  const GameLevelEngine({
    required this.type,
    required this.level,
    required this.onComplete,
    this.onExit,
    this.paused = false,
    super.key,
  });

  final GameType type;
  final GameLevel level;
  final GameEngineComplete onComplete;
  final VoidCallback? onExit;
  final bool paused;

  @override
  Widget build(BuildContext context) => switch (type) {
    GameType.quiz => StoryQuizEngine(level: level, onComplete: onComplete),
    GameType.ordering => switch (level.config['mode']) {
      'living_world' => CreationWorldEngine(
        level: level,
        onComplete: onComplete,
        onExit: onExit,
        paused: paused,
      ),
      'wise_builders' => WiseBuildersEngine(
        level: level,
        onComplete: onComplete,
        onExit: onExit,
        paused: paused,
      ),
      _ => CreationStudioEngine(level: level, onComplete: onComplete),
    },
    GameType.memory => LanternMemoryEngine(
      level: level,
      onComplete: onComplete,
    ),
    GameType.matching => switch (level.config['mode']) {
      'sheep_reunion' => FindMySheepEngine(
        level: level,
        onComplete: onComplete,
        onExit: onExit,
        paused: paused,
      ),
      'creation_bloom' => CreationBloomEngine(
        level: level,
        onComplete: onComplete,
        onExit: onExit,
        paused: paused,
      ),
      'esther_table' => EstherTableEngine(
        level: level,
        onComplete: onComplete,
        onExit: onExit,
        paused: paused,
      ),
      'coat_studio' => JosephCoatEngine(
        level: level,
        onComplete: onComplete,
        onExit: onExit,
        paused: paused,
      ),
      'harvest_chain' => RuthHarvestEngine(
        level: level,
        onComplete: onComplete,
        onExit: onExit,
        paused: paused,
      ),
      // The old v1 shape fixture remains held. A v2 course uses the actual
      // bundled model viewer and deterministic boarding queue. Catalogue
      // publication is a separate server action; no retired ID is reopened.
      'ark_garden' =>
        level.config['garden'] is Map && level.config['garden']['version'] == 2
            ? ArkGardenNativeEngine(
                level: level,
                onComplete: onComplete,
                onExit: onExit,
                paused: paused,
              )
            : ArkGardenEngine(
                level: level,
                onComplete: onComplete,
                onExit: onExit,
                paused: paused,
              ),
      'ark_traffic' => ArkTrafficEngine(
        level: level,
        onComplete: onComplete,
        onExit: onExit,
        paused: paused,
      ),
      'ark_boarding' => ArkBoardingEngine(level: level, onComplete: onComplete),
      _ => StoryMatchingEngine(level: level, onComplete: onComplete),
    },
    GameType.aim => DavidSlingEngine(level: level, onComplete: onComplete),
    GameType.path => SeaJourneyEngine(
      level: level,
      onComplete: onComplete,
      isSeaPath: true,
    ),
    GameType.maze => SeaJourneyEngine(
      level: level,
      onComplete: onComplete,
      isSeaPath: false,
    ),
    GameType.puzzle => PuzzleQuestEngine(level: level, onComplete: onComplete),
  };
}

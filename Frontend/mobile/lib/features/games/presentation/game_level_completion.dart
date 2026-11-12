import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../auth/domain/kid_profile.dart';
import '../../auth/presentation/kid_character_pose.dart';
import '../domain/mini_game.dart';
import 'game_cover_image.dart';

const _victoryInk = Color(0xFF211A35);
const _victoryPaper = Color(0xFFFFF8EA);
const _victoryGold = Color(0xFFFFBE0B);

/// A focused, full-screen celebration for every completed game level.
///
/// Each game keeps its own voice and color while the interaction stays
/// predictable: celebrate the child, show the earned result, then offer one
/// clear next action.
class GameLevelCompletion extends StatelessWidget {
  const GameLevelCompletion({
    required this.game,
    required this.profile,
    required this.submission,
    required this.onNext,
    required this.onFinish,
    super.key,
  });

  final MiniGame game;
  final KidProfile profile;
  final GameSubmission submission;
  final VoidCallback? onNext;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final accent = gameAccent(game);
    final copy = _VictoryCopy.forType(game.gameType);
    final firstName = _firstName(profile.displayName);
    final foreground = accent.computeLuminance() > 0.43
        ? _victoryInk
        : Colors.white;
    final iconBrightness = foreground == Colors.white
        ? Brightness.light
        : Brightness.dark;
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: iconBrightness,
        statusBarBrightness: iconBrightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarColor: accent,
        systemNavigationBarIconBrightness: iconBrightness,
      ),
      child: Semantics(
        key: const Key('game-completion'),
        container: true,
        explicitChildNodes: true,
        label:
            '${copy.semanticLabel}. Great work, $firstName. '
            'Score ${submission.score} out of ${submission.maxScore}. '
            '${submission.starsAwarded} of 3 stars.',
        child: ColoredBox(
          color: accent,
          child: Stack(
            fit: StackFit.expand,
            children: [
              IgnorePointer(
                child: ExcludeSemantics(
                  child: CustomPaint(
                    painter: _GameVictoryBackdropPainter(
                      foreground: foreground,
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxHeight < 700;
                    final horizontalPadding = constraints.maxWidth < 350
                        ? 18.0
                        : 24.0;
                    return SingleChildScrollView(
                      key: const Key('game-completion-scroll'),
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        compact ? 18 : 28,
                        horizontalPadding,
                        compact ? 18 : 28,
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: math.max(
                            0,
                            constraints.maxHeight - (compact ? 36 : 56),
                          ),
                        ),
                        child: TweenAnimationBuilder<double>(
                          duration: reduceMotion
                              ? Duration.zero
                              : const Duration(milliseconds: 680),
                          curve: Curves.easeOutBack,
                          tween: Tween(begin: 0.8, end: 1),
                          builder: (context, progress, child) {
                            return Opacity(
                              opacity: progress.clamp(0, 1),
                              child: Transform.scale(
                                scale: progress,
                                child: child,
                              ),
                            );
                          },
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                copy.heading(firstName),
                                key: const Key('game-completion-title'),
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.displaySmall
                                    ?.copyWith(
                                      color: foreground,
                                      fontSize: compact ? 38 : 46,
                                      height: 0.98,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: -1,
                                      shadows: [
                                        Shadow(
                                          color: _victoryInk.withValues(
                                            alpha: 0.24,
                                          ),
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                              ),
                              SizedBox(height: compact ? 12 : 18),
                              _CelebratingCharacter(
                                profile: profile,
                                icon: gameTypeIcon(game.gameType),
                                compact: compact,
                              ),
                              SizedBox(height: compact ? 14 : 22),
                              _GameResultStats(submission: submission),
                              SizedBox(height: compact ? 18 : 26),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  key: Key(
                                    onNext == null
                                        ? 'finish-game-button'
                                        : 'next-level-button',
                                  ),
                                  onPressed: onNext ?? onFinish,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: _victoryPaper,
                                    foregroundColor: _victoryInk,
                                    minimumSize: const Size.fromHeight(58),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(18),
                                      side: const BorderSide(
                                        color: _victoryInk,
                                        width: 2.5,
                                      ),
                                    ),
                                    shadowColor: _victoryInk,
                                    elevation: 6,
                                  ),
                                  icon: Icon(
                                    onNext == null
                                        ? Icons.flag_rounded
                                        : Icons.arrow_forward_rounded,
                                  ),
                                  label: Text(
                                    onNext == null
                                        ? 'Finish quest'
                                        : 'Next level',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CelebratingCharacter extends StatelessWidget {
  const _CelebratingCharacter({
    required this.profile,
    required this.icon,
    required this.compact,
  });

  final KidProfile profile;
  final IconData icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final stageSize = compact ? 208.0 : 265.0;
    return Semantics(
      image: true,
      label: '${profile.displayName}’s character celebrating',
      child: SizedBox(
        key: const Key('game-completion-character'),
        width: stageSize,
        height: compact ? 214 : 272,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.bottomCenter,
          children: [
            Positioned(
              left: 8,
              right: 8,
              bottom: 3,
              child: Container(
                height: stageSize * 0.76,
                decoration: BoxDecoration(
                  color: _victoryPaper,
                  shape: BoxShape.circle,
                  border: Border.all(color: _victoryInk, width: 3),
                  boxShadow: const [
                    BoxShadow(color: _victoryInk, offset: Offset(7, 8)),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: -2,
              child: Container(
                width: compact ? 48 : 56,
                height: compact ? 48 : 56,
                decoration: BoxDecoration(
                  color: _victoryGold,
                  shape: BoxShape.circle,
                  border: Border.all(color: _victoryInk, width: 2.5),
                ),
                child: Icon(icon, color: _victoryInk, size: compact ? 25 : 29),
              ),
            ),
            Positioned(
              left: 0,
              top: compact ? 50 : 62,
              child: const Icon(
                Icons.auto_awesome_rounded,
                color: _victoryPaper,
                size: 31,
              ),
            ),
            Positioned.fill(
              child: KidProfileCharacterPose(
                profile: profile,
                pose: KidCharacterPose.celebrate,
                fit: BoxFit.contain,
                alignment: Alignment.bottomCenter,
                semanticLabel: 'Your character celebrating',
                fallbackSize: stageSize * 0.68,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GameResultStats extends StatelessWidget {
  const _GameResultStats({required this.submission});

  final GameSubmission submission;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('game-completion-stats'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: _victoryPaper,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _victoryInk, width: 2.5),
        boxShadow: const [BoxShadow(color: _victoryInk, offset: Offset(7, 8))],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stackStats =
              MediaQuery.textScalerOf(context).scale(1) >= 2 ||
              constraints.maxWidth < 250;
          final score = _VictoryStat(
            key: const Key('game-completion-score'),
            icon: Icons.bolt_rounded,
            iconColor: const Color(0xFF7653E8),
            value: '${submission.score}/${submission.maxScore}',
            label: 'Score',
          );
          final stars = _VictoryStat(
            key: const Key('game-completion-stars'),
            icon: Icons.star_rounded,
            iconColor: const Color(0xFFFFA800),
            value: '${submission.starsAwarded}/3',
            label: 'Stars',
          );
          if (stackStats) {
            return Column(
              children: [
                score,
                const Divider(height: 26, color: Color(0xFFD9D2C5)),
                stars,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: score),
              const SizedBox(
                height: 54,
                child: VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: Color(0xFFD9D2C5),
                ),
              ),
              Expanded(child: stars),
            ],
          );
        },
      ),
    );
  }
}

class _VictoryStat extends StatelessWidget {
  const _VictoryStat({
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.label,
    super.key,
  });

  final IconData icon;
  final Color iconColor;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: iconColor, size: 27),
        const SizedBox(height: 3),
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: _victoryInk,
            fontWeight: FontWeight.w900,
          ),
        ),
        Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: _victoryInk.withValues(alpha: 0.72),
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _VictoryCopy {
  const _VictoryCopy({required this.semanticLabel, required this.heading});

  final String semanticLabel;
  final String Function(String firstName) heading;

  factory _VictoryCopy.forType(GameType type) {
    return switch (type) {
      GameType.quiz => _VictoryCopy(
        semanticLabel: 'Quiz complete',
        heading: (name) => 'Brilliant thinking,\n$name!',
      ),
      GameType.memory => _VictoryCopy(
        semanticLabel: 'Memory game complete',
        heading: (name) => 'Memory magic,\n$name!',
      ),
      GameType.ordering => _VictoryCopy(
        semanticLabel: 'Ordering game complete',
        heading: (name) => 'Perfect order,\n$name!',
      ),
      GameType.matching => _VictoryCopy(
        semanticLabel: 'Matching game complete',
        heading: (name) => 'Perfect match,\n$name!',
      ),
      GameType.maze => _VictoryCopy(
        semanticLabel: 'Maze complete',
        heading: (name) => 'You found the way,\n$name!',
      ),
      GameType.path => _VictoryCopy(
        semanticLabel: 'Path game complete',
        heading: (name) => 'Trailblazer,\n$name!',
      ),
      GameType.aim => _VictoryCopy(
        semanticLabel: 'Aim game complete',
        heading: (name) => 'Bullseye,\n$name!',
      ),
      GameType.puzzle => _VictoryCopy(
        semanticLabel: 'Puzzle complete',
        heading: (name) => 'Picture perfect,\n$name!',
      ),
    };
  }
}

class _GameVictoryBackdropPainter extends CustomPainter {
  const _GameVictoryBackdropPainter({required this.foreground});

  final Color foreground;

  @override
  void paint(Canvas canvas, Size size) {
    final soft = Paint()
      ..color = foreground.withValues(alpha: 0.08)
      ..style = PaintingStyle.fill;
    final outline = Paint()
      ..color = foreground.withValues(alpha: 0.13)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;

    canvas.drawCircle(
      Offset(size.width * 0.92, size.height * 0.12),
      size.width * 0.38,
      soft,
    );
    canvas.drawCircle(
      Offset(size.width * 0.02, size.height * 0.84),
      size.width * 0.45,
      outline,
    );

    const confetti = <(double, double, double, double)>[
      (0.08, 0.12, -0.3, 0.55),
      (0.86, 0.25, 0.25, 0.72),
      (0.12, 0.48, 0.4, 0.5),
      (0.91, 0.55, -0.2, 0.62),
      (0.08, 0.75, 0.18, 0.7),
      (0.88, 0.87, -0.35, 0.48),
      (0.25, 0.93, 0.3, 0.55),
      (0.72, 0.08, -0.12, 0.65),
    ];
    for (final item in confetti) {
      canvas.save();
      canvas.translate(size.width * item.$1, size.height * item.$2);
      canvas.rotate(item.$3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: 8, height: 21),
          const Radius.circular(4),
        ),
        Paint()..color = foreground.withValues(alpha: item.$4),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_GameVictoryBackdropPainter oldDelegate) {
    return oldDelegate.foreground != foreground;
  }
}

String _firstName(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return 'superstar';
  return trimmed.split(RegExp(r'\s+')).first;
}

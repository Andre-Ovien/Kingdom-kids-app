import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../auth/domain/kid_profile.dart';
import '../../auth/presentation/kid_character_pose.dart';
import '../domain/mini_game.dart';
import 'game_cover_image.dart';

/// A focused, full-screen celebration shown after a puzzle is saved.
class PuzzleQuestCompletion extends StatefulWidget {
  const PuzzleQuestCompletion({
    required this.game,
    required this.profile,
    required this.submission,
    required this.result,
    required this.onNext,
    required this.onFinish,
    super.key,
  });

  final MiniGame game;
  final KidProfile profile;
  final GameSubmission submission;
  final Map<String, dynamic>? result;
  final VoidCallback? onNext;
  final VoidCallback onFinish;

  @override
  State<PuzzleQuestCompletion> createState() => _PuzzleQuestCompletionState();
}

class _PuzzleQuestCompletionState extends State<PuzzleQuestCompletion>
    with TickerProviderStateMixin {
  static const _ink = Color(0xFF211A35);
  static const _paper = Color(0xFFFFF7E6);

  late final AnimationController _entranceController;
  late final AnimationController _ambientController;
  bool? _reduceMotion;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2300),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    final reduceMotion = media.disableAnimations || media.accessibleNavigation;
    if (_reduceMotion == reduceMotion) return;
    _reduceMotion = reduceMotion;

    if (reduceMotion) {
      _entranceController.stop();
      _ambientController.stop();
      _entranceController.value = 1;
      _ambientController.value = 0.5;
      return;
    }

    if (_entranceController.value < 1) {
      _entranceController.forward();
    }
    _ambientController.repeat(reverse: true);
  }

  @override
  void dispose() {
    _entranceController.dispose();
    _ambientController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = gameAccent(widget.game);
    final onAccent = _foregroundFor(accent);
    final metrics = _PuzzleMetrics.from(
      submission: widget.submission,
      result: widget.result,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: accent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Semantics(
        key: const Key('puzzle-completion'),
        container: true,
        label: 'Puzzle Quest completion',
        child: ColoredBox(
          color: accent,
          child: AnimatedBuilder(
            animation: Listenable.merge([
              _entranceController,
              _ambientController,
            ]),
            builder: (context, _) {
              final entrance = _entranceController.value;
              final ambient = _ambientController.value * 2 - 1;
              final copyProgress = Curves.easeOutCubic.transform(
                _interval(entrance, 0, 0.48),
              );
              final characterProgress = Curves.elasticOut.transform(
                _interval(entrance, 0.08, 0.74),
              );
              final statsProgress = Curves.easeOutBack.transform(
                _interval(entrance, 0.42, 0.88),
              );
              final actionProgress = Curves.easeOutCubic.transform(
                _interval(entrance, 0.66, 1),
              );

              return LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxHeight < 680;
                  final horizontalPadding = constraints.maxWidth < 360
                      ? 16.0
                      : 22.0;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      _CelebrationBackdrop(
                        accent: accent,
                        ink: _ink,
                        paper: _paper,
                        progress: entrance,
                        ambient: ambient,
                      ),
                      SafeArea(
                        child: Column(
                          children: [
                            Expanded(
                              child: SingleChildScrollView(
                                key: const Key('puzzle-completion-scroll'),
                                padding: EdgeInsets.fromLTRB(
                                  horizontalPadding,
                                  compact ? 12 : 22,
                                  horizontalPadding,
                                  compact ? 14 : 20,
                                ),
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minHeight: math.max(
                                      0,
                                      constraints.maxHeight -
                                          (compact ? 116 : 136),
                                    ),
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Opacity(
                                        opacity: copyProgress.clamp(0, 1),
                                        child: Transform.translate(
                                          offset: Offset(
                                            0,
                                            18 * (1 - copyProgress),
                                          ),
                                          child: _CompletionCopy(
                                            profile: widget.profile,
                                            metrics: metrics,
                                            onAccent: onAccent,
                                          ),
                                        ),
                                      ),
                                      SizedBox(height: compact ? 8 : 14),
                                      Opacity(
                                        opacity: entrance.clamp(0, 1),
                                        child: Transform.translate(
                                          offset: Offset(
                                            0,
                                            34 * (1 - characterProgress) +
                                                ambient * 4,
                                          ),
                                          child: Transform.scale(
                                            scale:
                                                0.58 + characterProgress * 0.42,
                                            child: _CharacterStage(
                                              profile: widget.profile,
                                              compact: compact,
                                              ink: _ink,
                                              paper: _paper,
                                            ),
                                          ),
                                        ),
                                      ),
                                      SizedBox(height: compact ? 8 : 14),
                                      Opacity(
                                        opacity: statsProgress.clamp(0, 1),
                                        child: Transform.translate(
                                          offset: Offset(
                                            0,
                                            15 * (1 - statsProgress),
                                          ),
                                          child: _StatsCard(
                                            metrics: metrics,
                                            ink: _ink,
                                            paper: _paper,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            Opacity(
                              opacity: actionProgress.clamp(0, 1),
                              child: Transform.translate(
                                offset: Offset(0, 14 * (1 - actionProgress)),
                                child: _PrimaryAction(
                                  hasNext: widget.onNext != null,
                                  onPressed: widget.onNext ?? widget.onFinish,
                                  ink: _ink,
                                  paper: _paper,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CompletionCopy extends StatelessWidget {
  const _CompletionCopy({
    required this.profile,
    required this.metrics,
    required this.onAccent,
  });

  final KidProfile profile;
  final _PuzzleMetrics metrics;
  final Color onAccent;

  @override
  Widget build(BuildContext context) {
    final firstName = _firstName(profile.displayName);
    return Semantics(
      key: const Key('puzzle-completion-announcement'),
      container: true,
      liveRegion: true,
      label:
          'Puzzle complete. Picture perfect, $firstName! '
          '${metrics.starsSemanticLabel}, ${metrics.movesSemanticLabel}, '
          '${metrics.timeSemanticLabel}.',
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Picture perfect,\n$firstName!',
              key: const Key('puzzle-completion-title'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                color: onAccent,
                fontSize: 43,
                height: 0.96,
                fontWeight: FontWeight.w900,
                letterSpacing: -1.4,
                shadows: [
                  Shadow(
                    color: _PuzzleQuestCompletionState._ink.withValues(
                      alpha: 0.24,
                    ),
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Every piece found its place!',
              key: const Key('puzzle-completion-message'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: onAccent.withValues(alpha: 0.9),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CharacterStage extends StatelessWidget {
  const _CharacterStage({
    required this.profile,
    required this.compact,
    required this.ink,
    required this.paper,
  });

  final KidProfile profile;
  final bool compact;
  final Color ink;
  final Color paper;

  @override
  Widget build(BuildContext context) {
    final stageWidth = compact ? 206.0 : 270.0;
    final stageHeight = compact ? 218.0 : 294.0;
    final haloSize = compact ? 158.0 : 214.0;
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: 'Your character celebrating the completed puzzle',
      child: SizedBox(
        key: const Key('puzzle-completion-character-stage'),
        width: stageWidth,
        height: stageHeight,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Container(
              width: haloSize,
              height: haloSize,
              decoration: BoxDecoration(
                color: paper,
                shape: BoxShape.circle,
                border: Border.all(color: ink, width: 3.5),
                boxShadow: [
                  BoxShadow(
                    color: ink.withValues(alpha: 0.92),
                    offset: const Offset(7, 8),
                  ),
                ],
              ),
            ),
            Positioned.fill(
              child: KidProfileCharacterPose(
                key: const Key('puzzle-completion-character'),
                profile: profile,
                pose: KidCharacterPose.celebrate,
                fit: BoxFit.contain,
                alignment: Alignment.bottomCenter,
                semanticLabel:
                    'Your character celebrating the completed puzzle',
                fallbackSize: compact ? 116 : 148,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({
    required this.metrics,
    required this.ink,
    required this.paper,
  });

  final _PuzzleMetrics metrics;
  final Color ink;
  final Color paper;

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final stats = [
      _Stat(
        key: const Key('puzzle-completion-stars'),
        icon: Icons.star_rounded,
        value: '${metrics.stars}/3',
        label: 'Stars',
        color: const Color(0xFFFFB300),
      ),
      _Stat(
        key: const Key('puzzle-completion-moves'),
        icon: Icons.touch_app_rounded,
        value: metrics.moves?.toString() ?? '—',
        label: 'Moves',
        color: const Color(0xFF7653E8),
      ),
      _Stat(
        key: const Key('puzzle-completion-time'),
        icon: Icons.timer_rounded,
        value: metrics.timeLabel,
        label: 'Time',
        color: const Color(0xFF00A987),
      ),
    ];

    return Semantics(
      key: const Key('puzzle-completion-stats'),
      container: true,
      label:
          '${metrics.starsSemanticLabel}. ${metrics.movesSemanticLabel}. '
          '${metrics.timeSemanticLabel}.',
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 390),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 12),
            decoration: BoxDecoration(
              color: paper,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: ink, width: 2.5),
              boxShadow: [
                BoxShadow(
                  color: ink.withValues(alpha: 0.9),
                  offset: const Offset(5, 6),
                ),
              ],
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (textScale >= 1.8 || constraints.maxWidth < 245) {
                  return Column(
                    children: [
                      for (var index = 0; index < stats.length; index++) ...[
                        stats[index].asRow(),
                        if (index < stats.length - 1)
                          Divider(
                            height: 15,
                            color: ink.withValues(alpha: 0.14),
                          ),
                      ],
                    ],
                  );
                }
                return Row(
                  children: [
                    for (var index = 0; index < stats.length; index++) ...[
                      Expanded(child: stats[index]),
                      if (index < stats.length - 1)
                        Container(
                          width: 1.5,
                          height: 50,
                          color: ink.withValues(alpha: 0.14),
                        ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
    super.key,
  });

  final IconData icon;
  final String value;
  final String label;
  final Color color;

  Widget asRow() {
    return Builder(
      builder: (context) => Row(
        children: [
          Container(
            width: 37,
            height: 37,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 23),
        const SizedBox(height: 3),
        Text(
          value,
          maxLines: 1,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
        ),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: _PuzzleQuestCompletionState._ink.withValues(alpha: 0.66),
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    required this.hasNext,
    required this.onPressed,
    required this.ink,
    required this.paper,
  });

  final bool hasNext;
  final VoidCallback onPressed;
  final Color ink;
  final Color paper;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 430),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: ink.withValues(alpha: 0.9),
                offset: const Offset(5, 6),
              ),
            ],
          ),
          child: FilledButton.icon(
            key: Key(hasNext ? 'puzzle-next-button' : 'puzzle-finish-button'),
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              backgroundColor: paper,
              foregroundColor: ink,
              minimumSize: const Size.fromHeight(58),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(color: ink, width: 3),
              ),
              textStyle: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
            icon: Icon(
              hasNext ? Icons.arrow_forward_rounded : Icons.flag_rounded,
              size: 24,
            ),
            label: Text(hasNext ? 'Next puzzle' : 'Finish quest'),
          ),
        ),
      ),
    );
  }
}

class _CelebrationBackdrop extends StatelessWidget {
  const _CelebrationBackdrop({
    required this.accent,
    required this.ink,
    required this.paper,
    required this.progress,
    required this.ambient,
  });

  final Color accent;
  final Color ink;
  final Color paper;
  final double progress;
  final double ambient;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: CustomPaint(
          painter: _CelebrationPainter(
            accent: accent,
            ink: ink,
            paper: paper,
            progress: progress,
            ambient: ambient,
          ),
        ),
      ),
    );
  }
}

class _CelebrationPainter extends CustomPainter {
  const _CelebrationPainter({
    required this.accent,
    required this.ink,
    required this.paper,
    required this.progress,
    required this.ambient,
  });

  final Color accent;
  final Color ink;
  final Color paper;
  final double progress;
  final double ambient;

  static const _confetti = <(double, double, double, double)>[
    (0.08, 0.12, -0.35, 8),
    (0.22, 0.07, 0.22, 6),
    (0.78, 0.09, -0.18, 7),
    (0.92, 0.2, 0.4, 9),
    (0.12, 0.39, 0.12, 6),
    (0.89, 0.43, -0.3, 7),
    (0.06, 0.7, 0.32, 8),
    (0.94, 0.76, -0.12, 6),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = accent);

    canvas.drawCircle(
      Offset(size.width + 28, 12),
      118,
      Paint()..color = paper.withValues(alpha: 0.08),
    );
    canvas.drawCircle(
      Offset(-34, size.height * 0.72),
      106,
      Paint()..color = ink.withValues(alpha: 0.07),
    );

    for (var index = 0; index < _confetti.length; index++) {
      final item = _confetti[index];
      final opacity = (0.12 + (index.isEven ? 0.08 : 0.03)) * progress;
      final paint = Paint()
        ..color = (index % 3 == 0 ? ink : paper).withValues(alpha: opacity);
      final x = item.$1 * size.width + ambient * (index.isEven ? 3 : -3);
      final y = item.$2 * size.height;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(item.$3 + ambient * 0.04);
      final side = item.$4 * (0.7 + progress * 0.3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: side, height: side * 1.8),
          const Radius.circular(2),
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _CelebrationPainter oldDelegate) {
    return oldDelegate.accent != accent ||
        oldDelegate.progress != progress ||
        oldDelegate.ambient != ambient;
  }
}

class _PuzzleMetrics {
  const _PuzzleMetrics({
    required this.stars,
    required this.moves,
    required this.elapsedSeconds,
  });

  final int stars;
  final int? moves;
  final int? elapsedSeconds;

  factory _PuzzleMetrics.from({
    required GameSubmission submission,
    required Map<String, dynamic>? result,
  }) {
    return _PuzzleMetrics(
      stars: submission.starsAwarded.clamp(0, 3),
      moves: _nonNegativeInt(result?['moves']),
      elapsedSeconds: _nonNegativeInt(result?['elapsed_seconds']),
    );
  }

  String get starsSemanticLabel => '$stars ${stars == 1 ? 'star' : 'stars'}';

  String get movesSemanticLabel => moves == null
      ? 'moves not available'
      : '$moves ${moves == 1 ? 'move' : 'moves'}';

  String get timeLabel {
    final seconds = elapsedSeconds;
    if (seconds == null) return '—';
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return remainder == 0 ? '${minutes}m' : '${minutes}m ${remainder}s';
  }

  String get timeSemanticLabel {
    final seconds = elapsedSeconds;
    if (seconds == null) return 'time not available';
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    if (minutes == 0) {
      return '$seconds ${seconds == 1 ? 'second' : 'seconds'}';
    }
    final minuteText = '$minutes ${minutes == 1 ? 'minute' : 'minutes'}';
    if (remainder == 0) return minuteText;
    return '$minuteText and $remainder '
        '${remainder == 1 ? 'second' : 'seconds'}';
  }
}

Color _foregroundFor(Color background) {
  final luminance = background.computeLuminance();
  return luminance > 0.42 ? _PuzzleQuestCompletionState._ink : Colors.white;
}

double _interval(double value, double begin, double end) {
  if (value <= begin) return 0;
  if (value >= end) return 1;
  return (value - begin) / (end - begin);
}

String _firstName(String displayName) {
  final normalized = displayName.trim();
  if (normalized.isEmpty) return 'Explorer';
  return normalized.split(RegExp(r'\s+')).first;
}

int? _nonNegativeInt(Object? value) {
  final parsed = switch (value) {
    int number => number,
    num number => number.toInt(),
    _ => int.tryParse(value?.toString() ?? ''),
  };
  return parsed != null && parsed >= 0 ? parsed : null;
}

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../auth/domain/kid_profile.dart';
import '../../auth/presentation/kid_character_pose.dart';
import '../../auth/presentation/kid_profile_avatar.dart';
import '../domain/story_detail.dart';

/// A focused celebration shown after a child finishes a narrated story.
///
/// This view deliberately celebrates the completed activity without promising
/// XP or a badge. Story rewards can be introduced once completion is persisted
/// by the backend.
class StoryCompletionView extends StatefulWidget {
  const StoryCompletionView({
    required this.story,
    required this.profile,
    required this.onContinue,
    super.key,
  });

  final StoryDetail story;
  final KidProfile profile;
  final VoidCallback onContinue;

  @override
  State<StoryCompletionView> createState() => _StoryCompletionViewState();
}

class _StoryCompletionViewState extends State<StoryCompletionView>
    with TickerProviderStateMixin {
  static const _ink = Color(0xFF211A35);

  late final AnimationController _entranceController;
  late final AnimationController _ambientController;
  bool? _reduceMotion;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 920),
    );
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2100),
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
    final option = kidAvatarOptionFor(widget.profile.avatarKey);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        key: const Key('story-completion-screen'),
        backgroundColor: option.color,
        body: SafeArea(
          child: AnimatedBuilder(
            animation: Listenable.merge([
              _entranceController,
              _ambientController,
            ]),
            builder: (context, _) {
              final entrance = _entranceController.value;
              final ambient = _ambientController.value * 2 - 1;
              final stageProgress = Curves.elasticOut.transform(
                _interval(entrance, 0.04, 0.72),
              );
              final stageOpacity = Curves.easeOut.transform(
                _interval(entrance, 0, 0.35),
              );
              final copyProgress = Curves.easeOutCubic.transform(
                _interval(entrance, 0.38, 0.82),
              );
              final actionProgress = Curves.easeOutCubic.transform(
                _interval(entrance, 0.62, 1),
              );

              return LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxHeight < 620;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      _CompletionBackdrop(
                        key: const Key('story-completion-stars'),
                        color: option.color,
                        entrance: stageOpacity,
                        ambient: ambient,
                      ),
                      Column(
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              key: const Key('story-completion-scroll'),
                              padding: EdgeInsets.fromLTRB(
                                24,
                                compact ? 12 : 26,
                                24,
                                compact ? 10 : 18,
                              ),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minHeight: math.max(
                                    0,
                                    constraints.maxHeight -
                                        (compact ? 108 : 132),
                                  ),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Opacity(
                                      opacity: stageOpacity.clamp(0, 1),
                                      child: Transform.translate(
                                        offset: Offset(
                                          0,
                                          42 * (1 - stageProgress) +
                                              ambient * 6,
                                        ),
                                        child: Transform.rotate(
                                          angle: ambient * 0.018,
                                          child: Transform.scale(
                                            scale:
                                                0.58 +
                                                stageProgress * 0.42 +
                                                ambient * 0.008,
                                            child: _CharacterStage(
                                              profile: widget.profile,
                                              option: option,
                                              compact: compact,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    SizedBox(height: compact ? 20 : 30),
                                    Opacity(
                                      opacity: copyProgress.clamp(0, 1),
                                      child: Transform.translate(
                                        offset: Offset(
                                          0,
                                          22 * (1 - copyProgress),
                                        ),
                                        child: _CompletionCopy(
                                          story: widget.story,
                                          option: option,
                                          ink: _ink,
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
                              offset: Offset(0, 16 * (1 - actionProgress)),
                              child: _ContinueAction(
                                ink: _ink,
                                storyTitle: widget.story.title,
                                onPressed: widget.onContinue,
                              ),
                            ),
                          ),
                        ],
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

class _CharacterStage extends StatelessWidget {
  const _CharacterStage({
    required this.profile,
    required this.option,
    required this.compact,
  });

  final KidProfile profile;
  final KidAvatarOption option;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final stageWidth = compact ? 214.0 : 280.0;
    final stageHeight = compact ? 224.0 : 310.0;
    final haloSize = compact ? 168.0 : 224.0;
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: '${option.label} celebrating',
      child: SizedBox(
        key: const Key('story-completion-stage'),
        width: stageWidth,
        height: stageHeight,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Container(
              key: const Key('story-completion-character-halo'),
              width: haloSize,
              height: haloSize,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.92),
                shape: BoxShape.circle,
                border: Border.all(
                  color: _StoryCompletionViewState._ink,
                  width: 4,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: _StoryCompletionViewState._ink,
                    offset: Offset(8, 9),
                  ),
                ],
              ),
            ),
            Positioned.fill(
              child: KidProfileCharacterPose(
                key: const Key('story-completion-avatar'),
                profile: profile,
                pose: KidCharacterPose.celebrate,
                fit: BoxFit.contain,
                semanticLabel: '${option.label} celebrating with a star',
                fallbackSize: compact ? 124 : 154,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompletionCopy extends StatelessWidget {
  const _CompletionCopy({
    required this.story,
    required this.option,
    required this.ink,
  });

  final StoryDetail story;
  final KidAvatarOption option;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: ink, width: 2),
          ),
          child: Text(
            'STORY COMPLETE',
            style: textTheme.labelLarge?.copyWith(
              color: ink,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.1,
            ),
          ),
        ),
        const SizedBox(height: 15),
        Semantics(
          key: const Key('story-completion-announcement'),
          container: true,
          liveRegion: true,
          label:
              'Story complete. ${option.label} is proud of you for finishing ${story.title}.',
          child: ExcludeSemantics(
            child: Text(
              'You did it!',
              key: const Key('story-completion-title'),
              textAlign: TextAlign.center,
              style: textTheme.displaySmall?.copyWith(
                color: ink,
                fontSize: 44,
                fontWeight: FontWeight.w900,
                height: 0.98,
                letterSpacing: -1.5,
              ),
            ),
          ),
        ),
        const SizedBox(height: 13),
        Text(
          '${option.label} is proud of you. You followed every word!',
          key: const Key('story-completion-message'),
          textAlign: TextAlign.center,
          style: textTheme.titleMedium?.copyWith(
            color: ink.withValues(alpha: 0.88),
            fontSize: 18,
            fontWeight: FontWeight.w700,
            height: 1.3,
          ),
        ),
      ],
    );
  }
}

class _ContinueAction extends StatelessWidget {
  const _ContinueAction({
    required this.ink,
    required this.storyTitle,
    required this.onPressed,
  });

  final Color ink;
  final String storyTitle;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 58),
        child: SizedBox(
          width: double.infinity,
          child: Semantics(
            label: 'Continue after finishing $storyTitle',
            button: true,
            child: ExcludeSemantics(
              child: FilledButton(
                key: const Key('story-completion-continue'),
                onPressed: onPressed,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: ink,
                  disabledBackgroundColor: Colors.white.withValues(alpha: 0.7),
                  disabledForegroundColor: ink.withValues(alpha: 0.5),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 17,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                    side: BorderSide(color: ink, width: 3),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.2,
                  ),
                ),
                child: const Text('Continue'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CompletionBackdrop extends StatelessWidget {
  const _CompletionBackdrop({
    super.key,
    required this.color,
    required this.entrance,
    required this.ambient,
  });

  final Color color;
  final double entrance;
  final double ambient;

  @override
  Widget build(BuildContext context) {
    final ink = _StoryCompletionViewState._ink;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: color),
            Positioned(
              top: -72,
              right: -56,
              child: _BackdropCircle(
                size: 190,
                color: Colors.white.withValues(alpha: 0.2),
              ),
            ),
            Positioned(
              left: -70,
              bottom: 78,
              child: _BackdropCircle(
                size: 170,
                color: ink.withValues(alpha: 0.08),
              ),
            ),
            _MotionStar(
              alignment: const Alignment(-0.78, -0.68),
              size: 31,
              rotation: ambient * 0.12,
              scale: 0.72 + entrance * 0.28,
              opacity: entrance,
              color: Colors.white,
            ),
            _MotionStar(
              alignment: const Alignment(0.78, -0.42),
              size: 24,
              rotation: -ambient * 0.16,
              scale: 0.68 + entrance * 0.32,
              opacity: entrance * 0.9,
              color: ink,
            ),
            _MotionStar(
              alignment: const Alignment(-0.72, 0.24),
              size: 19,
              rotation: ambient * 0.18,
              scale: 0.7 + entrance * 0.3,
              opacity: entrance * 0.82,
              color: ink,
            ),
            _MotionStar(
              alignment: const Alignment(0.72, 0.3),
              size: 28,
              rotation: -ambient * 0.11,
              scale: 0.72 + entrance * 0.28,
              opacity: entrance,
              color: Colors.white,
            ),
          ],
        ),
      ),
    );
  }
}

class _BackdropCircle extends StatelessWidget {
  const _BackdropCircle({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: _StoryCompletionViewState._ink.withValues(alpha: 0.14),
          width: 3,
        ),
      ),
    );
  }
}

class _MotionStar extends StatelessWidget {
  const _MotionStar({
    required this.alignment,
    required this.size,
    required this.rotation,
    required this.scale,
    required this.opacity,
    required this.color,
  });

  final Alignment alignment;
  final double size;
  final double rotation;
  final double scale;
  final double opacity;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Opacity(
        opacity: opacity.clamp(0, 1),
        child: Transform.rotate(
          angle: rotation,
          child: Transform.scale(
            scale: scale,
            child: Icon(Icons.auto_awesome_rounded, size: size, color: color),
          ),
        ),
      ),
    );
  }
}

double _interval(double value, double start, double end) {
  if (value <= start) return 0;
  if (value >= end) return 1;
  return (value - start) / (end - start);
}

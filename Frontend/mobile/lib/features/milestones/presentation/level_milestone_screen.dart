import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../auth/domain/kid_profile.dart';
import 'milestone_reveal_graphics.dart';

/// A celebration for a server-confirmed overall level increase.
class LevelMilestoneScreen extends StatefulWidget {
  const LevelMilestoneScreen({
    required this.profile,
    required this.level,
    required this.levelTitle,
    this.isMaxLevel = false,
    this.onContinue,
    this.onPresented,
    this.graphicsLoader,
    this.previewGiftReveal = false,
    super.key,
  });

  final KidProfile profile;
  final int level;
  final String levelTitle;
  final bool isMaxLevel;
  final VoidCallback? onContinue;
  final VoidCallback? onPresented;
  final MilestoneRevealGraphicsLoader? graphicsLoader;

  /// Only the off-device review harness opts into the unapproved gift artwork.
  /// Profile and release builds always show the simple earned-level screen.
  final bool previewGiftReveal;

  @override
  State<LevelMilestoneScreen> createState() => _LevelMilestoneScreenState();
}

class _LevelMilestoneScreenState extends State<LevelMilestoneScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _gold = Color(0xFFF6D989);
  late final _reveal = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 7),
  );
  MilestoneRevealGraphics? _graphics;
  bool? _reduceMotion;
  bool _foreground = true;
  bool _loading = false;
  bool _graphicsReady = false;
  bool _closing = false;

  bool get _giftPreviewEnabled => widget.previewGiftReveal && kDebugMode;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onPresented?.call();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    final reduced = media.disableAnimations || media.accessibleNavigation;
    if (!_giftPreviewEnabled) {
      _reduceMotion = reduced;
      _reveal.stop();
      _reveal.value = 1;
      return;
    }
    if (_reduceMotion == reduced) return;
    _reduceMotion = reduced;
    if (reduced) {
      _reveal.stop();
      _reveal.value = 1;
    } else if (!_graphicsReady) {
      unawaited(_loadGraphics());
    } else {
      _resumeReveal();
    }
  }

  Future<void> _loadGraphics() async {
    if (!_giftPreviewEnabled || _loading) return;
    _loading = true;
    MilestoneRevealGraphics? graphics;
    try {
      graphics =
          await (widget.graphicsLoader?.call() ??
              MilestoneRevealGraphics.load());
      if (!mounted || _closing) {
        graphics.dispose();
        return;
      }
      _reveal.duration = Duration(
        microseconds:
            ((graphics.durationSeconds + 3) * Duration.microsecondsPerSecond)
                .round(),
      );
    } catch (_) {
      // A missing visual must never hide an earned level or block navigation.
    }
    if (!mounted || _closing) return;
    setState(() {
      _graphics = graphics;
      _graphicsReady = true;
      _loading = false;
    });
    if (graphics == null) {
      _reveal.value = 1;
    } else {
      _resumeReveal();
    }
  }

  void _resumeReveal() {
    if (_giftPreviewEnabled &&
        _foreground &&
        _reduceMotion == false &&
        _graphicsReady &&
        !_closing &&
        _reveal.value < 1) {
      _reveal.forward();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _resumeReveal();
    } else {
      _reveal.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reveal.dispose();
    _graphics?.dispose();
    super.dispose();
  }

  void _continue() {
    if (_closing) return;
    _closing = true;
    _reveal.stop();
    if (widget.onContinue case final action?) {
      action();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_giftPreviewEnabled) return _buildEarnedLevel(context);
    final reduced = _reduceMotion ?? false;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        key: const Key('level-milestone-screen'),
        backgroundColor: const Color(0xFF07131D),
        body: AnimatedBuilder(
          animation: _reveal,
          builder: (context, _) {
            final progress = _reveal.value;
            final totalSeconds =
                _reveal.duration!.inMicroseconds /
                Duration.microsecondsPerSecond;
            final seconds = progress * totalSeconds;
            final boxProgress = _range(
              seconds,
              0,
              _graphics?.durationSeconds ?? 4,
            );
            final badgeEnd = _graphics?.badgeEndSeconds ?? 2.8;
            final bright = reduced
                ? 1.0
                : Curves.easeOutCubic.transform(
                    _range(
                      seconds,
                      (_graphics?.badgeStartSeconds ?? 2.1),
                      badgeEnd + .2,
                    ),
                  );
            final ink = Color.lerp(
              Colors.white,
              const Color(0xFF173D38),
              bright,
            )!;
            final rankInk = Color.lerp(_gold, const Color(0xFF226D59), bright)!;
            final words = reduced
                ? 1.0
                : Curves.easeOutCubic.transform(
                    _range(seconds, badgeEnd - 0.25, badgeEnd + 0.45),
                  );
            return Stack(
              fit: StackFit.expand,
              children: [
                AnnotatedRegion<SystemUiOverlayStyle>(
                  value: bright > .6
                      ? SystemUiOverlayStyle.dark
                      : SystemUiOverlayStyle.light,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color.lerp(
                            const Color(0xFF090F24),
                            const Color(0xFFF0F9FF),
                            bright,
                          )!,
                          Color.lerp(
                            const Color(0xFF071C21),
                            const Color(0xFFFFF6E2),
                            bright,
                          )!,
                          Color.lerp(
                            const Color(0xFF061C15),
                            const Color(0xFFE9FFF1),
                            bright,
                          )!,
                        ],
                      ),
                    ),
                  ),
                ),
                IgnorePointer(
                  child: CustomPaint(
                    key: const Key('level-milestone-spotlight'),
                    painter: _StageAtmospherePainter(
                      progress: progress,
                      brightness: bright,
                    ),
                  ),
                ),
                SafeArea(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxHeight < 660;
                      final side = constraints.maxWidth < 360 ? 20.0 : 28.0;
                      return Column(
                        children: [
                          Align(
                            alignment: Alignment.centerRight,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 12, top: 4),
                              child: IconButton(
                                key: const Key('level-milestone-close'),
                                tooltip: 'Continue exploring',
                                onPressed: _continue,
                                color: ink.withValues(alpha: 0.7),
                                icon: const Icon(Icons.close_rounded),
                              ),
                            ),
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              key: const Key('level-milestone-scroll'),
                              padding: EdgeInsets.fromLTRB(side, 0, side, 18),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minHeight: math.max(
                                    0,
                                    constraints.maxHeight - 156,
                                  ),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      height: compact ? 360 : 420,
                                      width: double.infinity,
                                      child: _RevealStage(
                                        level: widget.level,
                                        progress: boxProgress,
                                        graphics: _graphics,
                                        reducedMotion: reduced,
                                      ),
                                    ),
                                    ExcludeSemantics(
                                      excluding: words == 0,
                                      child: Opacity(
                                        opacity: words,
                                        child: Transform.translate(
                                          offset: Offset(0, 18 * (1 - words)),
                                          child: Column(
                                            children: [
                                              Text(
                                                widget.isMaxLevel
                                                    ? 'MAXIMUM LEVEL ACHIEVED'
                                                    : 'A NEW MILESTONE',
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                  color: rankInk,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w800,
                                                  letterSpacing: 2.1,
                                                ),
                                              ),
                                              const SizedBox(height: 12),
                                              Semantics(
                                                liveRegion: true,
                                                header: true,
                                                child: Text(
                                                  'You reached\nlevel ${widget.level}!',
                                                  key: const Key(
                                                    'level-milestone-title',
                                                  ),
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                    color: ink,
                                                    fontSize: compact ? 34 : 40,
                                                    fontWeight: FontWeight.w900,
                                                    height: 1.05,
                                                    letterSpacing: -1,
                                                  ),
                                                ),
                                              ),
                                              if (widget.levelTitle
                                                  .trim()
                                                  .isNotEmpty) ...[
                                                const SizedBox(height: 13),
                                                Text(
                                                  widget.levelTitle.trim(),
                                                  key: const Key(
                                                    'level-milestone-rank',
                                                  ),
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                    color: rankInk,
                                                    fontSize: 21,
                                                    fontWeight: FontWeight.w800,
                                                    height: 1.15,
                                                  ),
                                                ),
                                              ],
                                              const SizedBox(height: 10),
                                              Text(
                                                'Amazing work, ${widget.profile.displayName}!',
                                                key: const Key(
                                                  'level-milestone-personal-message',
                                                ),
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                  color: ink.withValues(
                                                    alpha: 0.68,
                                                  ),
                                                  fontSize: 15,
                                                  height: 1.3,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.fromLTRB(side, 12, side, 16),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 420),
                              child: SizedBox(
                                width: double.infinity,
                                child: FilledButton(
                                  key: const Key('level-milestone-continue'),
                                  onPressed: _continue,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: _gold,
                                    foregroundColor: const Color(0xFF112D2B),
                                    textStyle: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(
                                          fontSize: 17,
                                          fontWeight: FontWeight.w800,
                                        ),
                                    minimumSize: const Size.fromHeight(58),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 17,
                                      horizontal: 20,
                                    ),
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                  ),
                                  child: const Row(
                                    children: [
                                      SizedBox(width: 24),
                                      Expanded(
                                        child: Text(
                                          'Keep exploring',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            fontSize: 17,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                      Icon(
                                        Icons.arrow_forward_rounded,
                                        size: 24,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                if (!reduced)
                  IgnorePointer(
                    child: CustomPaint(
                      key: const Key('level-milestone-confetti'),
                      painter: _RevealConfettiPainter(
                        progress: _range(
                          seconds,
                          _graphics?.badgeStartSeconds ?? 2.1,
                          totalSeconds,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildEarnedLevel(BuildContext context) {
    const ink = Color(0xFF173D38);
    const rankInk = Color(0xFF226D59);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        key: const Key('level-milestone-screen'),
        backgroundColor: const Color(0xFFFFF6E2),
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFF0F9FF), Color(0xFFFFF6E2), Color(0xFFE9FFF1)],
            ),
          ),
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxHeight < 660;
                final side = constraints.maxWidth < 360 ? 20.0 : 28.0;
                return Column(
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 12, top: 4),
                        child: IconButton(
                          key: const Key('level-milestone-close'),
                          tooltip: 'Continue exploring',
                          onPressed: _continue,
                          color: ink.withValues(alpha: .7),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        key: const Key('level-milestone-scroll'),
                        padding: EdgeInsets.fromLTRB(side, 0, side, 18),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: math.max(0, constraints.maxHeight - 156),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Semantics(
                                key: const Key('level-milestone-stage'),
                                container: true,
                                excludeSemantics: true,
                                label: 'Level ${widget.level} medal',
                                child: SizedBox.square(
                                  dimension: compact ? 156 : 180,
                                  child: _EarnedLevelMedal(level: widget.level),
                                ),
                              ),
                              const SizedBox(height: 24),
                              Text(
                                widget.isMaxLevel
                                    ? 'MAXIMUM LEVEL ACHIEVED'
                                    : 'A NEW MILESTONE',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: rankInk,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 2.1,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Semantics(
                                liveRegion: true,
                                header: true,
                                child: Text(
                                  'You reached\nlevel ${widget.level}!',
                                  key: const Key('level-milestone-title'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: ink,
                                    fontSize: compact ? 34 : 40,
                                    fontWeight: FontWeight.w900,
                                    height: 1.05,
                                    letterSpacing: -1,
                                  ),
                                ),
                              ),
                              if (widget.levelTitle.trim().isNotEmpty) ...[
                                const SizedBox(height: 13),
                                Text(
                                  widget.levelTitle.trim(),
                                  key: const Key('level-milestone-rank'),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: rankInk,
                                    fontSize: 21,
                                    fontWeight: FontWeight.w800,
                                    height: 1.15,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 10),
                              Text(
                                'Amazing work, ${widget.profile.displayName}!',
                                key: const Key(
                                  'level-milestone-personal-message',
                                ),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: ink.withValues(alpha: .68),
                                  fontSize: 15,
                                  height: 1.3,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(side, 12, side, 16),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            key: const Key('level-milestone-continue'),
                            onPressed: _continue,
                            style: FilledButton.styleFrom(
                              backgroundColor: _gold,
                              foregroundColor: ink,
                              textStyle: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                  ),
                              minimumSize: const Size.fromHeight(58),
                              padding: const EdgeInsets.symmetric(
                                vertical: 17,
                                horizontal: 20,
                              ),
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                            ),
                            icon: const Icon(Icons.arrow_forward_rounded),
                            iconAlignment: IconAlignment.end,
                            label: const Text('Keep exploring'),
                          ),
                        ),
                      ),
                    ),
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

class _RevealStage extends StatelessWidget {
  const _RevealStage({
    required this.level,
    required this.progress,
    required this.graphics,
    required this.reducedMotion,
  });

  final int level;
  final double progress;
  final MilestoneRevealGraphics? graphics;
  final bool reducedMotion;

  @override
  Widget build(BuildContext context) {
    final seconds = progress * (graphics?.durationSeconds ?? 4);
    final rawBadge = reducedMotion
        ? 1.0
        : _range(
            seconds,
            graphics?.badgeStartSeconds ?? 2.1,
            graphics?.badgeEndSeconds ?? 2.8,
          );
    final rise = Curves.easeOutBack.transform(rawBadge);
    final opacity = _range(rawBadge, 0, 0.22);
    final start = graphics?.badgeEmergenceAnchor ?? const Offset(0.5, 0.54);
    final end = graphics?.badgeAnchor ?? const Offset(0.46, 0.1);
    return LayoutBuilder(
      builder: (context, constraints) {
        // The medal finishes above the box camera shot, with room for its rim.
        final side = math.min(
          constraints.maxWidth + 34,
          constraints.maxHeight - 64,
        );
        final top = constraints.maxHeight - side;
        final medalSize = math.min(156.0, side * 0.43);
        return Semantics(
          key: const Key('level-milestone-stage'),
          container: true,
          excludeSemantics: true,
          label: rawBadge > 0
              ? 'Level $level medal revealed from a gift box'
              : 'A wrapped gift is opening to reveal your earned level',
          child: Center(
            child: SizedBox(
              width: side,
              height: constraints.maxHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    top: top,
                    width: side,
                    height: side,
                    child: CustomPaint(
                      painter: _BoxContactGlowPainter(progress: progress),
                    ),
                  ),
                  Positioned(
                    top: top,
                    width: side,
                    height: side,
                    child: reducedMotion
                        ? Image.asset(
                            graphics?.posterAsset ?? milestoneRevealPosterAsset,
                            fit: BoxFit.contain,
                            excludeFromSemantics: true,
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          )
                        : CustomPaint(
                            key: const Key('level-milestone-box'),
                            painter: _RenderedBoxPainter(
                              progress: progress,
                              graphics: graphics,
                            ),
                          ),
                  ),
                  Positioned(
                    left: side * _mix(start.dx, end.dx, rise) - medalSize / 2,
                    top:
                        top +
                        side * _mix(start.dy, end.dy, rise) -
                        medalSize / 2,
                    width: medalSize,
                    height: medalSize,
                    child: Opacity(
                      opacity: opacity,
                      child: Transform.rotate(
                        angle: -0.18 * (1 - rawBadge),
                        child: Transform.scale(
                          scale: _mix(0.18, 1, rise),
                          child: _EarnedLevelMedal(level: level),
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
    );
  }
}

class _EarnedLevelMedal extends StatelessWidget {
  const _EarnedLevelMedal({required this.level});

  final int level;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: const _EarnedMedalPainter(),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 18),
              Text(
                '$level',
                key: const Key('level-milestone-badge-number'),
                textScaler: TextScaler.noScaling,
                style: const TextStyle(
                  color: Color(0xFFFFF4C4),
                  fontSize: 52,
                  fontWeight: FontWeight.w900,
                  height: 0.95,
                  letterSpacing: -2,
                  shadows: [
                    Shadow(color: Color(0xFF052A2B), offset: Offset(0, 3)),
                  ],
                ),
              ),
              const SizedBox(height: 5),
              const Text(
                'LEVEL',
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  color: Color(0xFFF2D58A),
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 3.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RenderedBoxPainter extends CustomPainter {
  const _RenderedBoxPainter({required this.progress, required this.graphics});

  final double progress;
  final MilestoneRevealGraphics? graphics;

  @override
  void paint(Canvas canvas, Size size) {
    final render = graphics;
    render?.drawFrame(canvas, progress, Offset.zero & size);
  }

  @override
  bool shouldRepaint(covariant _RenderedBoxPainter old) =>
      old.progress != progress || old.graphics != graphics;
}

class _StageAtmospherePainter extends CustomPainter {
  const _StageAtmospherePainter({
    required this.progress,
    required this.brightness,
  });

  final double progress;
  final double brightness;

  @override
  void paint(Canvas canvas, Size size) {
    final intensity =
        _mix(0.12, 1, Curves.easeOut.transform(_range(progress, 0, 0.15))) *
        (1 - brightness);
    final target = Offset(size.width * 0.5, size.height * 0.43);
    final aura = Rect.fromCenter(
      center: target,
      width: size.width * 1.8,
      height: size.height * 0.92,
    );
    canvas.drawOval(
      aura,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF258C77).withValues(alpha: 0.2 * intensity),
            const Color(0xFF07392E).withValues(alpha: 0),
          ],
        ).createShader(aura),
    );
    final beam = Path()
      ..moveTo(size.width * 0.43, -50)
      ..lineTo(size.width * 0.57, -50)
      ..lineTo(size.width * 0.88, size.height * 0.6)
      ..quadraticBezierTo(
        size.width * 0.5,
        size.height * 0.75,
        size.width * 0.12,
        size.height * 0.6,
      )
      ..close();
    canvas.drawPath(
      beam,
      Paint()
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18)
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFFFFEDB8).withValues(alpha: 0.03 * intensity),
            const Color(0xFFFFEDB8).withValues(alpha: 0.13 * intensity),
            const Color(0xFF77D4BB).withValues(alpha: 0),
          ],
          stops: const [0, 0.65, 1],
        ).createShader(Offset.zero & size),
    );
    for (var i = 0; i < 22; i++) {
      final x = size.width * (0.22 + ((i * 43) % 59) / 100);
      final y = size.height * (0.08 + ((i * 29) % 51) / 100);
      final alpha = (0.12 + (i % 3) * 0.06) * intensity;
      canvas.drawCircle(
        Offset(x, y - 12 * progress * (1 + i % 3)),
        i % 4 == 0 ? 1.5 : 0.8,
        Paint()..color = const Color(0xFFFFEABA).withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StageAtmospherePainter old) =>
      old.progress != progress || old.brightness != brightness;
}

class _BoxContactGlowPainter extends CustomPainter {
  const _BoxContactGlowPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final opening = Curves.easeOut.transform(_range(progress, 0.4, 0.64));
    final ground = Rect.fromCenter(
      center: Offset(size.width * 0.5, size.height * 0.925),
      width: size.width * 0.8,
      height: size.height * 0.12,
    );
    canvas.drawOval(
      ground,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF60CBA8).withValues(alpha: 0.18 + 0.12 * opening),
            const Color(0xFF45A98D).withValues(alpha: 0),
          ],
        ).createShader(ground),
    );
    if (opening > 0) {
      final glow = Rect.fromCenter(
        center: Offset(size.width * 0.5, size.height * 0.54),
        width: size.width * 0.72,
        height: size.height * 0.72,
      );
      canvas.drawOval(
        glow,
        Paint()
          ..shader = RadialGradient(
            colors: [
              const Color(0xFFFFE4A0).withValues(alpha: 0.18 * opening),
              const Color(0xFF9AE1BD).withValues(alpha: 0),
            ],
          ).createShader(glow),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BoxContactGlowPainter old) =>
      old.progress != progress;
}

class _EarnedMedalPainter extends CustomPainter {
  const _EarnedMedalPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) * 0.46;
    final glow = Rect.fromCircle(center: center, radius: radius * 1.35);
    canvas.drawCircle(
      center,
      radius * 1.35,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0x66E8BC59), Color(0x00E8BC59)],
        ).createShader(glow),
    );
    final seal = Path();
    for (var i = 0; i < 48; i++) {
      final angle = -math.pi / 2 + i * math.pi / 24;
      final r = radius * (i.isEven ? 1 : 0.95);
      final point = center + Offset(math.cos(angle), math.sin(angle)) * r;
      if (i == 0) {
        seal.moveTo(point.dx, point.dy);
      } else {
        seal.lineTo(point.dx, point.dy);
      }
    }
    seal.close();
    canvas.drawCircle(
      center.translate(0, 6),
      radius,
      Paint()
        ..color = const Color(0x99010D11)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawPath(
      seal,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFFFF1B0),
            Color(0xFFBB7E2F),
            Color(0xFFFFDE80),
            Color(0xFF805421),
          ],
          stops: [0, 0.42, 0.67, 1],
        ).createShader(Offset.zero & size),
    );
    canvas.drawCircle(
      center,
      radius * 0.85,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF267E72), Color(0xFF073936), Color(0xFF052729)],
        ).createShader(Offset.zero & size),
    );
    for (final ring in [0.88, 0.76]) {
      canvas.drawCircle(
        center,
        radius * ring,
        Paint()
          ..color = const Color(
            0xFFFFEAB0,
          ).withValues(alpha: ring == 0.88 ? 0.75 : 0.3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = ring == 0.88 ? 1.5 : 0.8,
      );
    }
    final crown = Path()
      ..moveTo(center.dx - radius * 0.25, center.dy - radius * 0.49)
      ..lineTo(center.dx - radius * 0.29, center.dy - radius * 0.68)
      ..lineTo(center.dx - radius * 0.1, center.dy - radius * 0.58)
      ..lineTo(center.dx, center.dy - radius * 0.75)
      ..lineTo(center.dx + radius * 0.1, center.dy - radius * 0.58)
      ..lineTo(center.dx + radius * 0.29, center.dy - radius * 0.68)
      ..lineTo(center.dx + radius * 0.25, center.dy - radius * 0.49)
      ..close();
    canvas.drawPath(crown, Paint()..color = const Color(0xFFF2D27F));
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius * 0.96),
      math.pi * 1.08,
      math.pi * 0.45,
      false,
      Paint()
        ..color = const Color(0xFFFFF9DA)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _EarnedMedalPainter old) => false;
}

class _RevealConfettiPainter extends CustomPainter {
  const _RevealConfettiPainter({required this.progress});

  final double progress;

  static const _colors = [
    Color(0xFFE9AE22),
    Color(0xFF00AC84),
    Color(0xFFFF5E80),
    Color(0xFF299BD7),
    Color(0xFF955CE2),
    Color(0xFFFF8138),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || progress >= 1) return;
    final fade = 1 - _range(progress, 0.82, 1);
    for (var i = 0; i < 380; i++) {
      final rain = i >= 150;
      final launch = rain ? .08 + (i % 17) * .018 : (i % 12) / 200;
      final flight = _range(progress, launch, 1);
      if (flight <= 0) continue;
      final side = i.isEven ? -1.0 : 1.0;
      final speed = 0.3 + ((i * 37) % 60) / 100;
      final spread = math.sin(flight * math.pi / 2);
      final x = rain
          ? size.width * (((i * 73) % 101) / 100) +
                math.sin(i * 2.4 + flight * 8) * 22
          : size.width * 0.5 +
                side * size.width * speed * spread +
                math.sin(i * 2.4 + flight * 8) * 14;
      final y = rain
          ? size.height * (-.06 + 1.2 * flight)
          : size.height * 0.39 -
                size.height * (0.25 + (i % 7) * 0.025) * flight +
                size.height * 0.98 * flight * flight;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(i * 0.73 + flight * (i.isEven ? 9 : -8));
      canvas.scale(1, 0.35 + math.sin(flight * 13 + i).abs() * 0.65);
      final paint = Paint()
        ..color = _colors[i % _colors.length].withValues(alpha: fade);
      if (i % 5 == 0) {
        canvas.drawCircle(Offset.zero, 3.1, paint);
      } else {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset.zero,
              width: i % 3 == 0 ? 5 : 9,
              height: i % 3 == 0 ? 13 : 5,
            ),
            const Radius.circular(1),
          ),
          paint,
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _RevealConfettiPainter old) =>
      old.progress != progress;
}

double _range(double value, double start, double end) =>
    ((value - start) / (end - start)).clamp(0.0, 1.0);

double _mix(double from, double to, double progress) =>
    from + (to - from) * progress;

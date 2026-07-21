import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../auth/data/auth_repository.dart';

/// A playful, image-first introduction that hands users to the parent account
/// flow instead of dropping them into the child experience unauthenticated.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with SingleTickerProviderStateMixin {
  late final PageController _pageController;
  late final AnimationController _motionController;
  late final AuthRepository _authRepository;
  bool _reduceMotion = false;
  bool? _lastReduceMotionPreference;
  int _currentIndex = 0;

  static const _pages = [
    _OnboardingPageData(
      background: Color(0xFF3F61D6),
      accent: Color(0xFFFFD269),
      foreground: Colors.white,
      actionBackground: Colors.white,
      actionForeground: Color(0xFF27315F),
      eyebrow: 'WELCOME TO KINGDOM KIDS',
      title: 'Big Bible adventures begin here',
      body:
          'Discover brave stories, joyful songs, and faith-filled fun made for little hearts.',
      imageAsset: 'assets/images/onboarding/story-explorer-v2.png',
      imageDescription: 'A child reading a Bible beneath a dove and rainbow',
    ),
    _OnboardingPageData(
      background: Color(0xFFFFAF43),
      accent: Color(0xFF5E3B91),
      foreground: Color(0xFF3A214F),
      actionBackground: Color(0xFF3A214F),
      actionForeground: Colors.white,
      eyebrow: 'STEP INTO THE STORY',
      title: 'Watch wonder unfold',
      body:
          'Explore stories, videos, and gentle games that help kids see God\'s love in action.',
      imageAsset: 'assets/images/onboarding/noahs-ark-v2.png',
      imageDescription: 'Noah\'s ark with friendly animals and a dove',
    ),
    _OnboardingPageData(
      background: Color(0xFFFF7862),
      accent: Color(0xFF4D2C68),
      foreground: Color(0xFF3A214F),
      actionBackground: Color(0xFF3A214F),
      actionForeground: Colors.white,
      eyebrow: 'A LITTLE WONDER EVERY DAY',
      title: 'Grow, play, and shine',
      body:
          'Build happy habits, celebrate brave moments, and make every day an adventure.',
      imageAsset: 'assets/images/onboarding/story-celebration-v2.png',
      imageDescription: 'A child celebrating with story cards and stars',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _authRepository = AuthRepository();
    _motionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4200),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resumeExistingFamilySession();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    if (_lastReduceMotionPreference == reduceMotion) {
      return;
    }

    _lastReduceMotionPreference = reduceMotion;
    _reduceMotion = reduceMotion;
    if (reduceMotion) {
      _motionController.stop();
    } else {
      _motionController.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _motionController.dispose();
    super.dispose();
  }

  void _advance() {
    if (_currentIndex == _pages.length - 1) {
      _openAccountFlow();
      return;
    }

    _pageController.nextPage(
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutCubic,
    );
  }

  void _openAccountFlow() {
    Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.auth, (_) => false);
  }

  Future<void> _resumeExistingFamilySession() async {
    try {
      final storedSession = await _authRepository.restoreSession();
      if (!mounted || storedSession == null) {
        return;
      }

      final session = await _authRepository.refreshSession();
      if (!mounted) {
        return;
      }

      final activeKid = await _authRepository.currentKid();
      if (!mounted) {
        return;
      }

      final destination = activeKid != null
          ? AppRoutes.home
          : session.hasProfiles
          ? AppRoutes.profilePicker
          : AppRoutes.kidProfileSetup;
      Navigator.of(context).pushNamedAndRemoveUntil(
        destination,
        (_) => false,
        arguments: session.profiles,
      );
    } catch (_) {
      // If secure storage is unavailable or a previous session is malformed,
      // let the family begin from the friendly onboarding flow instead.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView.builder(
        controller: _pageController,
        itemCount: _pages.length,
        onPageChanged: (index) => setState(() => _currentIndex = index),
        itemBuilder: (context, index) => _OnboardingPage(
          data: _pages[index],
          index: index,
          pageCount: _pages.length,
          isLast: index == _pages.length - 1,
          motion: _motionController,
          reduceMotion: _reduceMotion,
          onAdvance: _advance,
          onOpenAccountFlow: _openAccountFlow,
        ),
      ),
    );
  }
}

class _OnboardingPage extends StatelessWidget {
  const _OnboardingPage({
    required this.data,
    required this.index,
    required this.pageCount,
    required this.isLast,
    required this.motion,
    required this.reduceMotion,
    required this.onAdvance,
    required this.onOpenAccountFlow,
  });

  final _OnboardingPageData data;
  final int index;
  final int pageCount;
  final bool isLast;
  final Animation<double> motion;
  final bool reduceMotion;
  final VoidCallback onAdvance;
  final VoidCallback onOpenAccountFlow;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: motion,
      builder: (context, _) {
        final t = reduceMotion ? 0.5 : motion.value;
        final wave = math.sin((t + index * 0.19) * math.pi * 2);

        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(data.background, Colors.white, 0.09)!,
                data.background,
                Color.lerp(data.background, Colors.black, 0.12)!,
              ],
              stops: const [0, 0.52, 1],
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              IgnorePointer(
                child: CustomPaint(
                  painter: _ContourPainter(phase: t, color: Colors.white),
                ),
              ),
              IgnorePointer(
                child: CustomPaint(
                  painter: _SparklePainter(
                    phase: t,
                    color: data.accent,
                    seed: index,
                  ),
                ),
              ),
              SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxHeight < 690;
                    final textScale = MediaQuery.textScalerOf(context).scale(1);
                    final requiresVerticalScroll = textScale > 1.3;
                    final baseHeroHeight = compact ? 238.0 : 318.0;
                    final heroHeight =
                        (baseHeroHeight - math.max(0, textScale - 1) * 130)
                            .clamp(112.0, baseHeroHeight)
                            .toDouble();
                    final titleSize = compact ? 31.0 : 37.0;
                    final content = Padding(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 18),
                      child: Column(
                        mainAxisSize: requiresVerticalScroll
                            ? MainAxisSize.min
                            : MainAxisSize.max,
                        children: [
                          if (requiresVerticalScroll)
                            const SizedBox(height: 24)
                          else
                            const Spacer(),
                          _HeroScene(
                            data: data,
                            wave: wave,
                            reduceMotion: reduceMotion,
                            height: heroHeight,
                          ),
                          SizedBox(
                            height: requiresVerticalScroll
                                ? 16
                                : compact
                                ? 22
                                : 30,
                          ),
                          Text(
                            data.eyebrow,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: data.foreground,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.1,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            data.title,
                            maxLines: requiresVerticalScroll ? 3 : 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: data.foreground,
                              fontSize: titleSize,
                              fontWeight: FontWeight.w800,
                              height: 1.02,
                              letterSpacing: -0.8,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            data.body,
                            maxLines: requiresVerticalScroll
                                ? 3
                                : compact
                                ? 2
                                : 3,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: data.foreground,
                              fontSize: compact ? 14 : 15,
                              fontWeight: FontWeight.w500,
                              height: 1.38,
                            ),
                          ),
                          if (requiresVerticalScroll)
                            const SizedBox(height: 28)
                          else
                            const Spacer(),
                          _Footer(
                            index: index,
                            pageCount: pageCount,
                            isLast: isLast,
                            foreground: data.foreground,
                            actionBackground: data.actionBackground,
                            actionForeground: data.actionForeground,
                            onAdvance: onAdvance,
                            onSkip: onOpenAccountFlow,
                          ),
                        ],
                      ),
                    );

                    if (requiresVerticalScroll) {
                      return SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: constraints.maxHeight,
                          ),
                          child: content,
                        ),
                      );
                    }

                    return content;
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HeroScene extends StatelessWidget {
  const _HeroScene({
    required this.data,
    required this.wave,
    required this.reduceMotion,
    required this.height,
  });

  final _OnboardingPageData data;
  final double wave;
  final bool reduceMotion;
  final double height;

  @override
  Widget build(BuildContext context) {
    final verticalOffset = reduceMotion ? 0.0 : wave * 7;
    final angle = reduceMotion ? 0.0 : wave * 0.012;
    final scale = reduceMotion ? 1.0 : 1.04 + wave * 0.018;

    return SizedBox(
      height: height,
      child: Center(
        child: Transform.translate(
          offset: Offset(reduceMotion ? 0 : wave * 3, verticalOffset),
          child: Transform.rotate(
            angle: angle,
            child: Transform.scale(
              scale: scale,
              child: Semantics(
                image: true,
                label: data.imageDescription,
                child: Image.asset(
                  data.imageAsset,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.index,
    required this.pageCount,
    required this.isLast,
    required this.foreground,
    required this.actionBackground,
    required this.actionForeground,
    required this.onAdvance,
    required this.onSkip,
  });

  final int index;
  final int pageCount;
  final bool isLast;
  final Color foreground;
  final Color actionBackground;
  final Color actionForeground;
  final VoidCallback onAdvance;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _PageDots(count: pageCount, index: index, color: foreground),
        const Spacer(),
        if (isLast)
          FilledButton(
            onPressed: onAdvance,
            style: FilledButton.styleFrom(
              backgroundColor: actionBackground,
              foregroundColor: actionForeground,
              minimumSize: const Size(132, 48),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
            ),
            child: const Text('Let\'s go'),
          )
        else
          TextButton(
            onPressed: onSkip,
            style: TextButton.styleFrom(
              foregroundColor: foreground,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              textStyle: const TextStyle(fontWeight: FontWeight.w700),
            ),
            child: const Text('Skip'),
          ),
      ],
    );
  }
}

class _PageDots extends StatelessWidget {
  const _PageDots({
    required this.count,
    required this.index,
    required this.color,
  });

  final int count;
  final int index;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Page ${index + 1} of $count',
      child: Row(
        children: List.generate(count, (dotIndex) {
          final selected = dotIndex == index;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            width: selected ? 22 : 7,
            height: 7,
            margin: EdgeInsets.only(right: dotIndex == count - 1 ? 0 : 6),
            decoration: BoxDecoration(
              color: selected ? color : color.withValues(alpha: 0.42),
              borderRadius: BorderRadius.circular(999),
            ),
          );
        }),
      ),
    );
  }
}

class _OnboardingPageData {
  const _OnboardingPageData({
    required this.background,
    required this.accent,
    required this.foreground,
    required this.actionBackground,
    required this.actionForeground,
    required this.eyebrow,
    required this.title,
    required this.body,
    required this.imageAsset,
    required this.imageDescription,
  });

  final Color background;
  final Color accent;
  final Color foreground;
  final Color actionBackground;
  final Color actionForeground;
  final String eyebrow;
  final String title;
  final String body;
  final String imageAsset;
  final String imageDescription;
}

class _ContourPainter extends CustomPainter {
  const _ContourPainter({required this.phase, required this.color});

  final double phase;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.17)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final shift = (phase - 0.5) * 22;

    for (final offset in [-0.12, 0.29, 0.73]) {
      final path = Path()
        ..moveTo(-20, size.height * (offset + 0.08))
        ..cubicTo(
          size.width * 0.22,
          size.height * (offset - 0.02) + shift,
          size.width * 0.72,
          size.height * (offset + 0.17) - shift,
          size.width + 24,
          size.height * (offset + 0.04),
        );
      canvas.drawPath(path, paint);
    }

    final loop = Path()
      ..moveTo(size.width * 0.73, -18)
      ..cubicTo(
        size.width * 0.98,
        size.height * 0.09 + shift,
        size.width * 0.45,
        size.height * 0.21,
        size.width * 0.78,
        size.height * 0.34,
      )
      ..cubicTo(
        size.width * 0.97,
        size.height * 0.43,
        size.width * 0.78,
        size.height * 0.54,
        size.width * 1.08,
        size.height * 0.67,
      );
    canvas.drawPath(loop, paint);
  }

  @override
  bool shouldRepaint(covariant _ContourPainter oldDelegate) {
    return oldDelegate.phase != phase || oldDelegate.color != color;
  }
}

class _SparklePainter extends CustomPainter {
  const _SparklePainter({
    required this.phase,
    required this.color,
    required this.seed,
  });

  final double phase;
  final Color color;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    const locations = <Offset>[
      Offset(0.1, 0.19),
      Offset(0.85, 0.21),
      Offset(0.16, 0.55),
      Offset(0.91, 0.65),
      Offset(0.48, 0.1),
    ];

    for (var i = 0; i < locations.length; i++) {
      final point = locations[i];
      final wobble = math.sin((phase + seed * 0.13 + i * 0.19) * math.pi * 2);
      final center = Offset(
        size.width * point.dx + wobble * 3,
        size.height * point.dy - wobble * 5,
      );
      final radius = 2.3 + (wobble + 1) * 1.25;
      final paint = Paint()..color = color.withValues(alpha: 0.55);
      canvas.drawCircle(center, radius, paint);

      if (i.isEven) {
        final linePaint = Paint()
          ..color = Colors.white.withValues(alpha: 0.44)
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(
          Offset(center.dx - radius * 2.2, center.dy),
          Offset(center.dx + radius * 2.2, center.dy),
          linePaint,
        );
        canvas.drawLine(
          Offset(center.dx, center.dy - radius * 2.2),
          Offset(center.dx, center.dy + radius * 2.2),
          linePaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SparklePainter oldDelegate) {
    return oldDelegate.phase != phase ||
        oldDelegate.color != color ||
        oldDelegate.seed != seed;
  }
}

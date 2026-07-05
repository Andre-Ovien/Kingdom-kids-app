import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/router.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with SingleTickerProviderStateMixin {
  late final PageController _pageController;
  late final AnimationController _motionController;
  int _currentIndex = 0;

  static const _pages = [
    _OnboardingPageData(
      eyebrow: 'WELCOME',
      title: 'Bible stories made for little hearts',
      body:
          'Step into a warm world of faith-filled stories kids can understand, love, and remember.',
      imageAsset: 'assets/images/david_and_goliath.png',
      accent: Color(0xFFFF7043),
      visual: _OnboardingVisual.storyWorld,
    ),
    _OnboardingPageData(
      eyebrow: 'DISCOVER',
      title: 'Read, watch, and play',
      body:
          'Stories, Bible videos, and gentle games come together in one joyful place.',
      imageAsset: 'assets/images/crossing_red_sea.webp',
      accent: Color(0xFF4A8EDB),
      visual: _OnboardingVisual.activityCards,
    ),
    _OnboardingPageData(
      eyebrow: 'GROW',
      title: 'Grow a little every day',
      body:
          'Build streaks, earn badges, and celebrate every Bible adventure along the way.',
      imageAsset: 'assets/images/noahs_ark.png',
      accent: Color(0xFFE45B4D),
      visual: _OnboardingVisual.progress,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _motionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _motionController.dispose();
    super.dispose();
  }

  void _next() {
    if (_currentIndex == _pages.length - 1) {
      _finish();
      return;
    }

    _pageController.nextPage(
      duration: const Duration(milliseconds: 460),
      curve: Curves.easeOutCubic,
    );
  }

  void _finish() {
    Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.home, (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final page = _pages[_currentIndex];

    return Scaffold(
      backgroundColor: _pageBackground(context),
      body: SafeArea(
        child: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: _pages.length,
              onPageChanged: (index) => setState(() => _currentIndex = index),
              itemBuilder: (context, index) {
                return AnimatedBuilder(
                  animation: _motionController,
                  builder: (context, _) {
                    return _OnboardingPage(
                      page: _pages[index],
                      loopValue: _motionController.value,
                    );
                  },
                );
              },
            ),
            Positioned(
              top: 8,
              right: 20,
              child: TextButton(
                onPressed: _finish,
                child: Text(
                  'Skip',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: _mutedText(context),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 24,
              right: 24,
              bottom: 18,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _OnboardingDots(
                    count: _pages.length,
                    index: _currentIndex,
                    accent: page.accent,
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: page.accent,
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(52),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                            textStyle: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0,
                            ),
                          ),
                          onPressed: _next,
                          child: Text(
                            _currentIndex == _pages.length - 1
                                ? 'Get Started'
                                : 'Next',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OnboardingPage extends StatelessWidget {
  const _OnboardingPage({required this.page, required this.loopValue});

  final _OnboardingPageData page;
  final double loopValue;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 54, 24, 112),
      child: Column(
        children: [
          Expanded(
            child: _OnboardingVisualStage(page: page, loopValue: loopValue),
          ),
          const SizedBox(height: 28),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              page.eyebrow,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: page.accent,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ),
          const SizedBox(height: 9),
          Text(
            page.title,
            textAlign: TextAlign.left,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: _primaryText(context),
              fontSize: 34,
              fontWeight: FontWeight.w600,
              height: 1.04,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 13),
          Text(
            page.body,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: _secondaryText(context),
              fontSize: 15,
              fontWeight: FontWeight.w400,
              height: 1.42,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _OnboardingVisualStage extends StatelessWidget {
  const _OnboardingVisualStage({required this.page, required this.loopValue});

  final _OnboardingPageData page;
  final double loopValue;

  @override
  Widget build(BuildContext context) {
    final wave = math.sin(loopValue * math.pi * 2);

    return ClipRRect(
      borderRadius: BorderRadius.circular(32),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            page.imageAsset,
            fit: BoxFit.cover,
            alignment: Alignment.center,
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 0.02),
                  Colors.black.withValues(alpha: 0.24),
                  Colors.black.withValues(alpha: 0.58),
                ],
              ),
            ),
          ),
          if (page.visual == _OnboardingVisual.storyWorld)
            _StoryWorldMotion(accent: page.accent, wave: wave),
          if (page.visual == _OnboardingVisual.activityCards)
            _ActivityCardsMotion(wave: wave),
          if (page.visual == _OnboardingVisual.progress)
            _ProgressMotion(accent: page.accent, wave: wave),
        ],
      ),
    );
  }
}

class _StoryWorldMotion extends StatelessWidget {
  const _StoryWorldMotion({required this.accent, required this.wave});

  final Color accent;
  final double wave;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: 24 + wave * 4,
          right: 24,
          child: _SunMark(color: accent),
        ),
        Positioned(
          left: 24,
          bottom: 24 - wave * 3,
          child: _GlassBadge(
            icon: Icons.auto_stories_rounded,
            label: 'Story time',
            color: accent,
          ),
        ),
        Positioned(
          top: 38 - wave * 4,
          left: 26,
          child: _CloudMark(opacity: 0.84),
        ),
      ],
    );
  }
}

class _ActivityCardsMotion extends StatelessWidget {
  const _ActivityCardsMotion({required this.wave});

  final double wave;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          left: 22,
          bottom: 34 + wave * 4,
          child: _MiniActivityCard(
            icon: Icons.auto_stories_rounded,
            label: 'Read',
            color: const Color(0xFF4A8EDB),
          ),
        ),
        Positioned(
          right: 24,
          bottom: 86 - wave * 5,
          child: _MiniActivityCard(
            icon: Icons.play_circle_rounded,
            label: 'Watch',
            color: const Color(0xFFFF7043),
          ),
        ),
        Positioned(
          left: 70,
          top: 36 + wave * 3,
          child: _MiniActivityCard(
            icon: Icons.extension_rounded,
            label: 'Play',
            color: const Color(0xFFFFD26A),
          ),
        ),
      ],
    );
  }
}

class _ProgressMotion extends StatelessWidget {
  const _ProgressMotion({required this.accent, required this.wave});

  final Color accent;
  final double wave;

  @override
  Widget build(BuildContext context) {
    final heights = [54.0, 84.0, 42.0, 102.0];

    return Stack(
      children: [
        Positioned(
          left: 24,
          right: 24,
          bottom: 24,
          child: Container(
            height: 126,
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var index = 0; index < heights.length; index++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 420),
                    width: 34,
                    height:
                        heights[index] + (index.isEven ? wave * 4 : -wave * 4),
                    decoration: BoxDecoration(
                      color: [
                        const Color(0xFFE14D42),
                        const Color(0xFF4168D7),
                        const Color(0xFF7B5DDA),
                        accent,
                      ][index],
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Positioned(
          top: 30 - wave * 4,
          right: 28,
          child: _GlassBadge(
            icon: Icons.local_fire_department_rounded,
            label: '5 day streak',
            color: accent,
          ),
        ),
      ],
    );
  }
}

class _MiniActivityCard extends StatelessWidget {
  const _MiniActivityCard({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 94,
      height: 88,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.32)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 7),
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _GlassBadge extends StatelessWidget {
  const _GlassBadge({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 17),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _OnboardingDots extends StatelessWidget {
  const _OnboardingDots({
    required this.count,
    required this.index,
    required this.accent,
  });

  final int count;
  final int index;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (dotIndex) {
        final selected = dotIndex == index;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: selected ? 22 : 7,
          height: 7,
          decoration: BoxDecoration(
            color: selected ? accent : _dotColor(context),
            borderRadius: BorderRadius.circular(999),
          ),
        );
      }),
    );
  }
}

class _SunMark extends StatelessWidget {
  const _SunMark({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.34),
            blurRadius: 24,
            spreadRadius: 4,
          ),
        ],
      ),
    );
  }
}

class _CloudMark extends StatelessWidget {
  const _CloudMark({required this.opacity});

  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: SizedBox(
        width: 58,
        height: 28,
        child: Stack(
          children: [
            Positioned(bottom: 0, left: 0, child: _CloudCircle(size: 24)),
            Positioned(bottom: 3, left: 17, child: _CloudCircle(size: 32)),
            Positioned(bottom: 0, right: 0, child: _CloudCircle(size: 24)),
          ],
        ),
      ),
    );
  }
}

class _CloudCircle extends StatelessWidget {
  const _CloudCircle({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        shape: BoxShape.circle,
      ),
    );
  }
}

class _OnboardingPageData {
  const _OnboardingPageData({
    required this.eyebrow,
    required this.title,
    required this.body,
    required this.imageAsset,
    required this.accent,
    required this.visual,
  });

  final String eyebrow;
  final String title;
  final String body;
  final String imageAsset;
  final Color accent;
  final _OnboardingVisual visual;
}

enum _OnboardingVisual { storyWorld, activityCards, progress }

Color _pageBackground(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF101414)
      : const Color(0xFFFFFBFA);
}

Color _primaryText(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface;

Color _secondaryText(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFFC9C0BD)
      : const Color(0xFF756C6C);
}

Color _mutedText(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF9EA8A6)
      : const Color(0xFF9D9090);
}

Color _dotColor(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? Colors.white.withValues(alpha: 0.18)
      : const Color(0xFFE7DEDC);
}

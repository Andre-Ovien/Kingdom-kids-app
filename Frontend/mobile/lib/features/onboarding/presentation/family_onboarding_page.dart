import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'onboarding_navigation.dart';

/// The family portrait composition follows the supplied peach reference.
/// Photographs remain separate assets so each circular window stays sharp.
class FamilyOnboardingPage extends StatelessWidget {
  const FamilyOnboardingPage({
    super.key,
    required this.onAdvance,
    required this.activeIndex,
  });

  final VoidCallback onAdvance;
  final int activeIndex;

  static const portraitAssets = [
    'assets/images/onboarding/family-20261111/portrait-1.png',
    'assets/images/onboarding/family-20261111/portrait-2.png',
    'assets/images/onboarding/family-20261111/portrait-3.png',
    'assets/images/onboarding/family-20261111/portrait-4.png',
    'assets/images/onboarding/family-20261111/portrait-5.png',
    'assets/images/onboarding/family-20261111/portrait-6.png',
  ];

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: SystemUiOverlayStyle.dark,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final reflow =
            constraints.maxWidth < 350 ||
            constraints.maxHeight < 740 ||
            MediaQuery.textScalerOf(context).scale(1) > 1.15;
        return DecoratedBox(
          key: const Key('onboarding-family-page'),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xFFF9D6BD),
                Color(0xFFFADAC5),
                Colors.white,
                Colors.white,
              ],
              stops: [0, 0.38, 0.65, 1],
            ),
          ),
          child: reflow
              ? _FamilyReflow(onAdvance: onAdvance, activeIndex: activeIndex)
              : SizedBox.expand(
                  child: ClipRect(
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: 393,
                        height: 852,
                        child: Stack(
                          children: [
                            Positioned(
                              top: 100,
                              left: 0,
                              width: 393,
                              height: 340,
                              child: MediaQuery.withNoTextScaling(
                                child: _FamilyPortraits(),
                              ),
                            ),
                            const Positioned(
                              top: 506,
                              left: 31,
                              width: 331,
                              child: _FamilyHeading(),
                            ),
                            const Positioned(
                              top: 597,
                              left: 35,
                              width: 323,
                              child: _FamilyBody(),
                            ),
                            Positioned(
                              left: 31,
                              bottom: 68,
                              child: OnboardingProgressDots(
                                key: const Key('onboarding-family-progress'),
                                index: activeIndex,
                                light: false,
                              ),
                            ),
                            Positioned(
                              right: 21,
                              bottom: 44,
                              child: OnboardingArrowButton(
                                onPressed: onAdvance,
                                buttonKey: const Key('onboarding-family-next'),
                                light: false,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        );
      },
    ),
  );
}

class _FamilyPortraits extends StatelessWidget {
  const _FamilyPortraits();

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      const Positioned.fill(
        child: IgnorePointer(child: CustomPaint(painter: _FamilyConnections())),
      ),
      const Positioned(
        left: 65,
        top: 30,
        width: 96,
        height: 96,
        child: _FamilyPortrait(0, 'A smiling Black parent'),
      ),
      const Positioned(
        left: 197,
        top: 94,
        width: 65,
        height: 65,
        child: _FamilyPortrait(1, 'A smiling Black parent'),
      ),
      const Positioned(
        left: 309,
        top: 62,
        width: 60,
        height: 60,
        child: _FamilyPortrait(2, 'A smiling Black child'),
      ),
      const Positioned(
        left: 20,
        top: 260,
        width: 62,
        height: 62,
        child: _FamilyPortrait(3, 'A smiling Black parent'),
      ),
      const Positioned(
        left: 107,
        top: 239,
        width: 60,
        height: 60,
        child: _FamilyPortrait(4, 'A smiling Black child'),
      ),
      const Positioned(
        left: 290,
        top: 237,
        width: 78,
        height: 78,
        child: _FamilyPortrait(5, 'A smiling Black parent'),
      ),
      Positioned(
        left: 67,
        top: 167,
        width: 259,
        height: 57,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(34),
            boxShadow: const [
              BoxShadow(color: Color(0x14F5A866), blurRadius: 22),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 25,
                height: 25,
                decoration: const BoxDecoration(
                  color: Color(0xFF452004),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_rounded,
                  color: Colors.white,
                  size: 19,
                ),
              ),
              const SizedBox(width: 9),
              const Text(
                'Growing, together',
                style: TextStyle(
                  fontFamily: 'OnboardingPoppins',
                  fontSize: 17,
                  height: 1.2,
                  color: Color(0xFF111111),
                ),
              ),
            ],
          ),
        ),
      ),
      const Positioned(
        left: 6,
        top: 149,
        child: _FamilyIcon(Icons.auto_stories_rounded),
      ),
      const Positioned(
        right: 4,
        top: 163,
        child: _FamilyIcon(Icons.favorite_rounded),
      ),
      const Positioned(
        left: 183,
        top: 307,
        child: _FamilyIcon(Icons.emoji_people_rounded),
      ),
    ],
  );
}

class _FamilyPortrait extends StatelessWidget {
  const _FamilyPortrait(this.index, this.description);
  final int index;
  final String description;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      color: Colors.white,
    ),
    child: Padding(
      padding: const EdgeInsets.all(1.1),
      child: ClipOval(
        child: Image.asset(
          FamilyOnboardingPage.portraitAssets[index],
          key: ValueKey('onboarding-family-portrait-${index + 1}'),
          fit: BoxFit.cover,
          cacheWidth: 384,
          semanticLabel: description,
          filterQuality: FilterQuality.high,
        ),
      ),
    ),
  );
}

class _FamilyIcon extends StatelessWidget {
  const _FamilyIcon(this.icon);
  final IconData icon;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: 47,
      height: 31,
      decoration: BoxDecoration(
        color: const Color(0xFF452004),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFEFA971), width: 0.6),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: const Color(0xFFFFF6EC), size: 18),
    ),
  );
}

class _FamilyHeading extends StatelessWidget {
  const _FamilyHeading();
  @override
  Widget build(BuildContext context) => const Text(
    'Big discoveries.\nShared together.',
    textAlign: TextAlign.center,
    style: TextStyle(
      fontFamily: 'OnboardingPoppins',
      fontSize: 27,
      fontWeight: FontWeight.w700,
      color: Color(0xFF111111),
      height: 1.27,
      letterSpacing: -0.7,
    ),
  );
}

class _FamilyBody extends StatelessWidget {
  const _FamilyBody();
  @override
  Widget build(BuildContext context) => const Text(
    'Explore Bible stories and joyful activities,\nwith a little guidance from the\ngrown-ups they love.',
    textAlign: TextAlign.center,
    style: TextStyle(
      fontFamily: 'OnboardingPoppins',
      fontSize: 13.5,
      height: 1.55,
      color: Color(0xFF303030),
      letterSpacing: -0.25,
    ),
  );
}

class _FamilyReflow extends StatelessWidget {
  const _FamilyReflow({required this.onAdvance, required this.activeIndex});
  final VoidCallback onAdvance;
  final int activeIndex;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      key: const Key('onboarding-family-scroll'),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 22),
          AspectRatio(
            aspectRatio: 393 / 340,
            child: FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: 393,
                height: 340,
                child: MediaQuery.withNoTextScaling(child: _FamilyPortraits()),
              ),
            ),
          ),
          const SizedBox(height: 40),
          const _FamilyHeading(),
          const SizedBox(height: 20),
          const _FamilyBody(),
          const SizedBox(height: 40),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              OnboardingProgressDots(
                key: const Key('onboarding-family-progress'),
                index: activeIndex,
                light: false,
              ),
              OnboardingArrowButton(
                onPressed: onAdvance,
                buttonKey: const Key('onboarding-family-next'),
                light: false,
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _FamilyConnections extends CustomPainter {
  const _FamilyConnections();
  @override
  void paint(Canvas canvas, Size size) {
    final orbit = Paint()
      ..color = const Color(0x88FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.65;
    for (final rect in [
      const Rect.fromLTWH(15, 99, 370, 214),
      const Rect.fromLTWH(34, 125, 329, 164),
      const Rect.fromLTWH(45, 147, 305, 120),
    ]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(90)),
        orbit,
      );
    }
    final arrow = Path()
      ..moveTo(331, 276)
      ..cubicTo(292, 294, 236, 274, 212, 245);
    canvas.drawPath(
      arrow,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round,
    );
    final point = Path()
      ..moveTo(215, 243)
      ..lineTo(196, 225)
      ..quadraticBezierTo(190, 223, 193, 232)
      ..lineTo(198, 252);
    canvas.drawPath(
      point,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    _spark(canvas, const Offset(37, 35), 14, 17);
    _spark(canvas, const Offset(267, 11), 15, 28);
    _spark(canvas, const Offset(279, 232), 7, 13);
    _spark(canvas, const Offset(126, 305), 6, 12);
  }

  void _spark(Canvas canvas, Offset center, double x, double y) {
    final path = Path()..moveTo(center.dx, center.dy - y);
    for (var i = 1; i <= 8; i++) {
      final angle = -math.pi / 2 + i * math.pi / 4;
      final inner = i.isOdd ? 0.24 : 1.0;
      path.lineTo(
        center.dx + math.cos(angle) * x * inner,
        center.dy + math.sin(angle) * y * inner,
      );
    }
    path.close();
    canvas.drawPath(path, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _FamilyConnections oldDelegate) => false;
}

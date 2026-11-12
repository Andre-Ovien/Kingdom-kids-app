import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'onboarding_navigation.dart';

const _portraitRoot = 'assets/images/onboarding/photos/';
const _welcomeTitle = 'Big Stories, For Little\nHearts.';
const _welcomeBody =
    'Discover Bible stories, joyful activities,\n'
    'and little moments of wonder that help\n'
    'curious hearts learn and grow.';

/// Native versions of the approved photographic compositions. The normal
/// canvas preserves their 393 × 852 geometry; accessible/compact layouts keep
/// enlarged copy and navigation reachable without shrinking text.
class PhotographicWelcomePage extends StatelessWidget {
  const PhotographicWelcomePage({super.key, required this.onAdvance});

  final VoidCallback onAdvance;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final accessible = _needsReflow(context, constraints);
          return ColoredBox(
            key: const Key('onboarding-photo-first-page'),
            color: Colors.white,
            child: accessible
                ? _WelcomeReflow(onAdvance: onAdvance)
                : _ReferenceCanvas(
                    child: Stack(
                      children: [
                        const Positioned.fill(
                          child: CustomPaint(painter: _PastelPainter()),
                        ),
                        const _WelcomePortraits(),
                        const Positioned(
                          top: 572,
                          left: 20,
                          width: 353,
                          child: _WelcomeTitle(),
                        ),
                        const Positioned(
                          top: 650,
                          left: 26,
                          width: 341,
                          child: _WelcomeBody(),
                        ),
                        Positioned(
                          bottom: 46,
                          left: 71,
                          width: 251,
                          child: _WelcomeContinue(onPressed: onAdvance),
                        ),
                      ],
                    ),
                  ),
          );
        },
      ),
    );
  }
}

class PhotographicDiscoveryPage extends StatelessWidget {
  const PhotographicDiscoveryPage({
    super.key,
    required this.onAdvance,
    this.activeIndex = 1,
  });

  final VoidCallback onAdvance;
  final int activeIndex;

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: SystemUiOverlayStyle.dark,
    child: LayoutBuilder(
      builder: (context, constraints) => ColoredBox(
        key: const Key('onboarding-photo-second-page'),
        color: Colors.white,
        child: _needsReflow(context, constraints)
            ? _DiscoveryReflow(onAdvance: onAdvance, activeIndex: activeIndex)
            : _ReferenceCanvas(
                child: Stack(
                  children: [
                    const Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: 500,
                      child: _DiscoveryPhotoHeader(),
                    ),
                    const Positioned(
                      top: 506,
                      left: 31,
                      width: 331,
                      child: _DiscoveryTitle(),
                    ),
                    const Positioned(
                      top: 597,
                      left: 35,
                      width: 323,
                      child: _DiscoveryBody(),
                    ),
                    Positioned(
                      left: 31,
                      bottom: 68,
                      child: OnboardingProgressDots(
                        key: const Key('onboarding-discovery-progress'),
                        index: activeIndex,
                        light: false,
                      ),
                    ),
                    Positioned(
                      right: 21,
                      bottom: 44,
                      child: OnboardingArrowButton(
                        onPressed: onAdvance,
                        buttonKey: const Key('onboarding-photo-second-next'),
                        light: false,
                      ),
                    ),
                  ],
                ),
              ),
      ),
    ),
  );
}

bool _needsReflow(BuildContext context, BoxConstraints constraints) =>
    MediaQuery.textScalerOf(context).scale(1) > 1.15 ||
    constraints.maxWidth < 350 ||
    constraints.maxHeight < 740;

class _ReferenceCanvas extends StatelessWidget {
  const _ReferenceCanvas({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: ClipRect(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(width: 393, height: 852, child: child),
        ),
      ),
    );
  }
}

class _WelcomePortraits extends StatelessWidget {
  const _WelcomePortraits();

  @override
  Widget build(BuildContext context) {
    return const Stack(
      children: [
        Positioned(
          left: 29,
          top: 128,
          width: 117,
          height: 141,
          child: _Portrait(
            filename: 'boy-twists.png',
            label: 'A smiling child in a green shirt',
            radius: 85,
          ),
        ),
        Positioned(
          right: 42,
          top: 113,
          width: 159,
          height: 197,
          child: _Portrait(
            filename: 'girl-puffs.png',
            label: 'A smiling child with afro puffs',
            radius: 95,
          ),
        ),
        Positioned(
          left: 52,
          top: 297,
          width: 148,
          height: 179,
          child: _Portrait(
            filename: 'boy-curls.png',
            label: 'A smiling child in a yellow shirt',
            radius: 95,
          ),
        ),
        Positioned(
          right: 63,
          top: 350,
          width: 99,
          height: 114,
          child: _Portrait(
            filename: 'girl-braids.png',
            label: 'A smiling child with braids',
            radius: 80,
          ),
        ),
        Positioned(
          left: 23,
          top: 222,
          width: 53,
          height: 53,
          child: CustomPaint(painter: _WelcomeDecoration(_Decoration.flower)),
        ),
        Positioned(
          right: 41,
          top: 103,
          width: 60,
          height: 60,
          child: CustomPaint(painter: _WelcomeDecoration(_Decoration.spark)),
        ),
        Positioned(
          left: 158,
          top: 266,
          width: 43,
          height: 45,
          child: CustomPaint(
            painter: _WelcomeDecoration(_Decoration.butterfly),
          ),
        ),
        Positioned(
          left: 294,
          top: 343,
          width: 44,
          height: 44,
          child: CustomPaint(painter: _WelcomeDecoration(_Decoration.mint)),
        ),
      ],
    );
  }
}

class _Portrait extends StatelessWidget {
  const _Portrait({
    required this.filename,
    required this.label,
    required this.radius,
  });

  final String filename;
  final String label;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1562566E),
            offset: Offset(0, 6),
            blurRadius: 18,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius - 4),
          child: Image.asset(
            '$_portraitRoot$filename',
            key: ValueKey('onboarding-portrait-$filename'),
            semanticLabel: label,
            fit: BoxFit.cover,
            alignment: const Alignment(0, -0.2),
            filterQuality: FilterQuality.high,
          ),
        ),
      ),
    );
  }
}

class _WelcomeTitle extends StatelessWidget {
  const _WelcomeTitle();

  @override
  Widget build(BuildContext context) => const Text(
    _welcomeTitle,
    textAlign: TextAlign.center,
    style: TextStyle(
      fontFamily: 'OnboardingPoppins',
      fontSize: 29,
      fontWeight: FontWeight.w400,
      height: 1.08,
      letterSpacing: -1.2,
      color: Color(0xFF151515),
    ),
  );
}

class _WelcomeBody extends StatelessWidget {
  const _WelcomeBody();

  @override
  Widget build(BuildContext context) => const Text(
    _welcomeBody,
    textAlign: TextAlign.center,
    style: TextStyle(
      fontFamily: 'OnboardingPoppins',
      fontSize: 13,
      fontWeight: FontWeight.w400,
      height: 1.45,
      letterSpacing: -0.45,
      color: Color(0xFF686868),
    ),
  );
}

class _WelcomeContinue extends StatelessWidget {
  const _WelcomeContinue({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 9,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: FilledButton(
        key: const Key('onboarding-photo-first-continue'),
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF242424),
          foregroundColor: Colors.white,
          minimumSize: const Size(251, 52),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontFamily: 'OnboardingPoppins',
            fontSize: 17,
            fontWeight: FontWeight.w400,
            height: 1.4,
          ),
        ),
        child: const Text('Continue'),
      ),
    );
  }
}

class _DiscoveryPhotoHeader extends StatelessWidget {
  const _DiscoveryPhotoHeader();

  @override
  Widget build(BuildContext context) => ClipRect(
    key: const Key('onboarding-discovery-photo-header'),
    child: ColoredBox(
      color: Colors.white,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // One continuous AI-extended photograph keeps the approved small
          // framing without the visible joins of a rectangular source overlay.
          const _DiscoveryPhoto(
            fit: BoxFit.fill,
            photoKey: Key('onboarding-discovery-photo'),
          ),
          const IgnorePointer(
            child: DecoratedBox(
              key: Key('onboarding-discovery-photo-fade'),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x00FFFFFF),
                    Color(0x00FFFFFF),
                    Color(0x40FFFFFF),
                    Colors.white,
                  ],
                  stops: [0, 0.75, 0.84, 1],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _DiscoveryPhoto extends StatelessWidget {
  const _DiscoveryPhoto({required this.fit, required this.photoKey});
  final BoxFit fit;
  final Key photoKey;

  @override
  Widget build(BuildContext context) => Image.asset(
    '${_portraitRoot}second-screen-expanded-scene-v7.png',
    key: photoKey,
    semanticLabel: 'Five smiling children enjoying an adventure together',
    fit: fit,
    alignment: Alignment.center,
    filterQuality: FilterQuality.high,
  );
}

class _DiscoveryTitle extends StatelessWidget {
  const _DiscoveryTitle();

  @override
  Widget build(BuildContext context) => const Text(
    'Big smiles.\nBigger discoveries.',
    textAlign: TextAlign.center,
    style: TextStyle(
      fontFamily: 'OnboardingPoppins',
      fontWeight: FontWeight.w700,
      fontSize: 27,
      height: 1.27,
      letterSpacing: -0.7,
      color: Color(0xFF111111),
    ),
  );
}

class _DiscoveryBody extends StatelessWidget {
  const _DiscoveryBody();

  @override
  Widget build(BuildContext context) => const Text(
    'Explore Bible stories, discover new ideas,\n'
    'and enjoy little moments of wonder\n'
    'together.',
    textAlign: TextAlign.center,
    style: TextStyle(
      fontFamily: 'OnboardingPoppins',
      fontSize: 13.5,
      height: 1.55,
      letterSpacing: -0.25,
      color: Color(0xFF303030),
    ),
  );
}

class _WelcomeReflow extends StatelessWidget {
  const _WelcomeReflow({required this.onAdvance});

  final VoidCallback onAdvance;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      const Positioned.fill(child: CustomPaint(painter: _PastelPainter())),
      SafeArea(
        child: SingleChildScrollView(
          key: const Key('onboarding-photo-first-scroll'),
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const AspectRatio(
                aspectRatio: 393 / 490,
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: SizedBox(
                    width: 393,
                    height: 490,
                    child: _WelcomePortraits(),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const _WelcomeTitle(),
              const SizedBox(height: 20),
              const _WelcomeBody(),
              const SizedBox(height: 28),
              Center(child: _WelcomeContinue(onPressed: onAdvance)),
            ],
          ),
        ),
      ),
    ],
  );
}

class _DiscoveryReflow extends StatelessWidget {
  const _DiscoveryReflow({required this.onAdvance, required this.activeIndex});

  final VoidCallback onAdvance;
  final int activeIndex;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      key: const Key('onboarding-photo-second-scroll'),
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AspectRatio(
            aspectRatio: 393 / 500,
            child: _DiscoveryPhotoHeader(),
          ),
          const SizedBox(height: 12),
          const _DiscoveryTitle(),
          const SizedBox(height: 20),
          const _DiscoveryBody(),
          const SizedBox(height: 36),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              OnboardingProgressDots(
                key: const Key('onboarding-discovery-progress'),
                index: activeIndex,
                light: false,
              ),
              OnboardingArrowButton(
                onPressed: onAdvance,
                buttonKey: const Key('onboarding-photo-second-next'),
                light: false,
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _PastelPainter extends CustomPainter {
  const _PastelPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(Colors.white, BlendMode.src);
    void wash(Offset center, double rx, double ry, Color color, double stop) {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.scale(rx, ry);
      canvas.drawCircle(
        Offset.zero,
        1,
        Paint()
          ..shader = ui.Gradient.radial(
            Offset.zero,
            1,
            [color, color.withValues(alpha: 0)],
            [0, stop],
          ),
      );
      canvas.restore();
    }

    final sx = size.width / 393;
    final sy = size.height / 852;
    wash(
      Offset(size.width * .02, size.height * .50),
      240 * sx,
      280 * sy,
      const Color(0xFFE6E4FF),
      .9,
    );
    wash(
      Offset(size.width * .90, size.height * .38),
      250 * sx,
      240 * sy,
      const Color(0xFFD7F3DF),
      .9,
    );
    wash(
      Offset(size.width * .95, size.height * .12),
      270 * sx,
      280 * sy,
      const Color(0xFFFFD1ED),
      .95,
    );
    wash(
      Offset(size.width * .09, size.height * .10),
      230 * sx,
      260 * sy,
      const Color(0xFFFFE3B1),
      .95,
    );
  }

  @override
  bool shouldRepaint(_PastelPainter oldDelegate) => false;
}

enum _Decoration { flower, spark, butterfly, mint }

class _WelcomeDecoration extends CustomPainter {
  const _WelcomeDecoration(this.kind);

  final _Decoration kind;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    switch (kind) {
      case _Decoration.flower:
        canvas.translate(size.width / 2, size.height / 2);
        canvas.rotate(17 * math.pi / 180);
        final paint = Paint()..color = const Color(0xFFFFE1A0);
        for (var i = 0; i < 5; i++) {
          canvas.save();
          canvas.rotate(i * math.pi * 2 / 5);
          canvas.drawOval(const Rect.fromLTWH(-8, -25, 16, 29), paint);
          canvas.restore();
        }
        canvas.drawCircle(Offset.zero, 7, Paint()..color = Colors.white);
      case _Decoration.spark:
        final path = Path()
          ..moveTo(30, 0)
          ..quadraticBezierTo(35, 21, 60, 30)
          ..quadraticBezierTo(39, 35, 30, 60)
          ..quadraticBezierTo(24, 39, 0, 30)
          ..quadraticBezierTo(21, 24, 30, 0)
          ..close();
        canvas.drawPath(path, Paint()..color = const Color(0xFFB7A7EB));
      case _Decoration.butterfly:
        canvas.translate(size.width / 2, size.height / 2);
        canvas.rotate(-24 * math.pi / 180);
        final path = Path()
          ..moveTo(0, 17)
          ..cubicTo(-35, 8, -24, -30, -8, -18)
          ..quadraticBezierTo(-1, -14, 0, -4)
          ..cubicTo(12, -38, 32, -16, 19, 9)
          ..quadraticBezierTo(9, 26, 0, 17)
          ..close();
        canvas.drawPath(path, Paint()..color = const Color(0xFFF6C1C6));
      case _Decoration.mint:
        final paint = Paint()..color = const Color(0xFFB9F3D3);
        for (final petal in [
          (14.0, 12.0, -44.0),
          (31.0, 12.0, 44.0),
          (13.0, 32.0, 44.0),
          (31.0, 32.0, -44.0),
        ]) {
          canvas.save();
          canvas.translate(petal.$1, petal.$2);
          canvas.rotate(petal.$3 * math.pi / 180);
          canvas.drawOval(const Rect.fromLTWH(-6, -15, 12, 30), paint);
          canvas.restore();
        }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WelcomeDecoration oldDelegate) =>
      oldDelegate.kind != kind;
}

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/router.dart';

class StreakScreen extends StatefulWidget {
  const StreakScreen({super.key});

  @override
  State<StreakScreen> createState() => _StreakScreenState();
}

class _StreakScreenState extends State<StreakScreen>
    with TickerProviderStateMixin {
  late final AnimationController _introController;
  late final AnimationController _fireController;

  @override
  void initState() {
    super.initState();
    _introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1900),
    )..forward();
    _fireController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 820),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _introController.dispose();
    _fireController.dispose();
    super.dispose();
  }

  void _close() {
    Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.home, (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF1E8),
      body: AnimatedBuilder(
        animation: Listenable.merge([_introController, _fireController]),
        builder: (context, _) {
          final intro = _introController.value;
          final firePulse = Curves.easeInOut.transform(_fireController.value);
          final ballsProgress = _interval(intro, 0, 0.56);
          final fireProgress = _interval(intro, 0.38, 0.76);
          final textProgress = _interval(intro, 0.66, 1);

          return Stack(
            children: [
              _WarmFullScreenBackground(progress: ballsProgress),
              _FallingCreamBalls(progress: ballsProgress),
              SafeArea(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 14, right: 22),
                    child: _CloseButton(onPressed: _close),
                  ),
                ),
              ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 56, 24, 40),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Transform.translate(
                        offset: Offset(0, 24 * (1 - fireProgress)),
                        child: Transform.scale(
                          scale:
                              0.18 +
                              Curves.elasticOut.transform(fireProgress) * 0.82,
                          child: Opacity(
                            opacity: fireProgress,
                            child: _AnimatedBonfire(
                              progress: firePulse,
                              intro: fireProgress,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 48),
                      Opacity(
                        opacity: textProgress,
                        child: Transform.translate(
                          offset: Offset(0, 24 * (1 - textProgress)),
                          child: Column(
                            children: [
                              Text(
                                '5 day streak!',
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(
                                      color: const Color(0xFF211A35),
                                      fontSize: _titleSize(context),
                                      fontWeight: FontWeight.w700,
                                      height: 1,
                                      letterSpacing: 0,
                                    ),
                              ),
                              const SizedBox(height: 14),
                              Text(
                                'Keep going to unlock more badges.',
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: const Color(0xFF736779),
                                      fontSize: 16,
                                      fontWeight: FontWeight.w400,
                                      height: 1.35,
                                      letterSpacing: 0,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  double _titleSize(BuildContext context) {
    return MediaQuery.sizeOf(context).width < 380 ? 38 : 46;
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 46,
      child: IconButton(
        key: const Key('streak-close-button'),
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: const Color(0xFF211A35).withValues(alpha: 0.08),
          foregroundColor: const Color(0xFF211A35),
        ),
        onPressed: onPressed,
        icon: const Icon(Icons.close_rounded, size: 25),
      ),
    );
  }
}

class _WarmFullScreenBackground extends StatelessWidget {
  const _WarmFullScreenBackground({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFFBF7), Color(0xFFFFF1E8), Color(0xFFFFEBDD)],
          stops: [0, 0.48, 1],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -166,
            left: -142,
            child: _SoftBall(size: 360, opacity: 0.62 + progress * 0.08),
          ),
          Positioned(
            top: 244,
            right: -190,
            child: _SoftBall(size: 310, opacity: 0.18 + progress * 0.08),
          ),
        ],
      ),
    );
  }
}

class _FallingCreamBalls extends StatelessWidget {
  const _FallingCreamBalls({required this.progress});

  final double progress;

  static const _balls = [
    _BallSpec(left: -42, top: 88, size: 112, delay: 0),
    _BallSpec(right: 24, top: 150, size: 72, delay: 0.08),
    _BallSpec(left: 74, top: 270, size: 46, delay: 0.18),
    _BallSpec(right: 86, top: 344, size: 54, delay: 0.26),
    _BallSpec(left: 22, top: 470, size: 72, delay: 0.34),
  ];

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        for (final ball in _balls)
          _FallingBall(progress: _delayed(progress, ball.delay), spec: ball),
      ],
    );
  }

  double _delayed(double value, double delay) {
    final adjusted = ((value - delay) / (1 - delay)).clamp(0.0, 1.0);
    return Curves.easeOutCubic.transform(adjusted);
  }
}

class _FallingBall extends StatelessWidget {
  const _FallingBall({required this.progress, required this.spec});

  final double progress;
  final _BallSpec spec;

  @override
  Widget build(BuildContext context) {
    final dropDistance = MediaQuery.sizeOf(context).height * 0.42;
    final y = spec.top - dropDistance * (1 - progress);
    final opacity = (0.34 * progress).clamp(0.0, 0.34);

    return Positioned(
      left: spec.left,
      right: spec.right,
      top: y,
      child: _SoftBall(size: spec.size, opacity: opacity),
    );
  }
}

class _AnimatedBonfire extends StatelessWidget {
  const _AnimatedBonfire({required this.progress, required this.intro});

  final double progress;
  final double intro;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final size = math.min(screenWidth * 0.48, 186.0);
    final wave = math.sin(progress * math.pi);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Transform.scale(
            scale: 0.8 + intro * 0.2,
            child: Container(
              width: size * 0.82,
              height: size * 0.82,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFFF7043).withValues(alpha: 0.12),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFF7043).withValues(alpha: 0.2),
                    blurRadius: 42 + wave * 13,
                    spreadRadius: 8 + wave * 5,
                  ),
                ],
              ),
            ),
          ),
          Transform.scale(
            scale: 0.96 + wave * 0.08,
            child: CustomPaint(
              size: Size.square(size * 0.78),
              painter: _BonfirePainter(progress),
            ),
          ),
        ],
      ),
    );
  }
}

class _SoftBall extends StatelessWidget {
  const _SoftBall({required this.size, required this.opacity});

  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFFFE7DB).withValues(alpha: opacity),
        shape: BoxShape.circle,
      ),
    );
  }
}

class _BallSpec {
  const _BallSpec({
    this.left,
    this.right,
    required this.top,
    required this.size,
    required this.delay,
  });

  final double? left;
  final double? right;
  final double top;
  final double size;
  final double delay;
}

class _BonfirePainter extends CustomPainter {
  const _BonfirePainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final wave = math.sin(progress * math.pi * 2);

    _drawLogs(canvas, size);
    _drawFlame(
      canvas,
      center,
      size.width * (0.32 + wave.abs() * 0.02),
      size.height * 0.48,
      const Color(0xFFFF7043),
      Offset(0, -2 + wave * 3),
    );
    _drawFlame(
      canvas,
      center,
      size.width * 0.23,
      size.height * (0.36 + wave.abs() * 0.03),
      const Color(0xFFFFB642),
      Offset(-2, 4 - wave * 2),
    );
    _drawFlame(
      canvas,
      center,
      size.width * 0.13,
      size.height * (0.24 + wave.abs() * 0.02),
      const Color(0xFFFFF0B8),
      Offset(3, 12 + wave),
    );
  }

  void _drawFlame(
    Canvas canvas,
    Offset center,
    double width,
    double height,
    Color color,
    Offset offset,
  ) {
    final base = center + Offset(offset.dx, offset.dy + height * 0.26);
    final path = Path()
      ..moveTo(base.dx, base.dy)
      ..cubicTo(
        base.dx - width,
        base.dy - height * 0.26,
        base.dx - width * 0.48,
        base.dy - height * 0.72,
        base.dx,
        base.dy - height,
      )
      ..cubicTo(
        base.dx + width * 0.64,
        base.dy - height * 0.64,
        base.dx + width,
        base.dy - height * 0.2,
        base.dx,
        base.dy,
      )
      ..close();

    canvas.drawPath(path, Paint()..color = color);
  }

  void _drawLogs(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.76);
    final paint = Paint()
      ..color = const Color(0xFF6D3927)
      ..strokeWidth = 13
      ..strokeCap = StrokeCap.round;
    final highlight = Paint()
      ..color = const Color(0xFFA8613E)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(
      center + const Offset(-36, -3),
      center + const Offset(36, 16),
      paint,
    );
    canvas.drawLine(
      center + const Offset(36, -3),
      center + const Offset(-36, 16),
      paint,
    );
    canvas.drawLine(
      center + const Offset(-30, -4),
      center + const Offset(25, 10),
      highlight,
    );
  }

  @override
  bool shouldRepaint(covariant _BonfirePainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

double _interval(double value, double start, double end) {
  return ((value - start) / (end - start)).clamp(0.0, 1.0);
}

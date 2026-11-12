import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../../shared/widgets/floating_liquid_nav.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/kid_profile.dart';

const _watchInk = Color(0xFF171426);
const _watchSky = Color(0xFF74D3F5);
const _watchNightSky = Color(0xFF183C53);
const _watchYellow = Color(0xFFFFCC3D);
const _watchCream = Color(0xFFFFF8E8);
const _watchCoral = Color(0xFFFF7658);
const _watchPurple = Color(0xFF8A6CFF);
const _watchMint = Color(0xFF66DDB0);

/// The beta Watch destination.
///
/// Videos are intentionally not exposed until real, reviewed media is ready.
/// This gives children a complete destination instead of presenting catalogue
/// cards whose play controls cannot do anything yet.
class VideosScreen extends StatefulWidget {
  const VideosScreen({super.key, this.authRepository});

  final AuthRepository? authRepository;

  @override
  State<VideosScreen> createState() => _VideosScreenState();
}

class _VideosScreenState extends State<VideosScreen>
    with SingleTickerProviderStateMixin {
  late final AuthRepository _authRepository;
  late final AnimationController _tvController;
  KidProfile? _activeProfile;
  bool? _lastReduceMotionPreference;

  @override
  void initState() {
    super.initState();
    _authRepository = widget.authRepository ?? AuthRepository();
    _tvController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2300),
      value: 0.25,
    );
    _loadActiveProfile();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.maybeOf(context);
    final reduceMotion =
        media?.disableAnimations == true || media?.accessibleNavigation == true;
    if (_lastReduceMotionPreference == reduceMotion) return;

    _lastReduceMotionPreference = reduceMotion;
    if (reduceMotion) {
      _tvController
        ..stop()
        ..value = 0.25;
    } else {
      _tvController.repeat();
    }
  }

  Future<void> _loadActiveProfile() async {
    try {
      final profile = await _authRepository.currentKid();
      if (mounted) setState(() => _activeProfile = profile);
    } catch (_) {
      // A profile lookup problem should never block this local beta message.
    }
  }

  @override
  void dispose() {
    _tvController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = dark ? _watchNightSky : _watchSky;
    final reduceMotion = _lastReduceMotionPreference ?? false;

    return Scaffold(
      key: const Key('videos-screen'),
      backgroundColor: background,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              child: ExcludeSemantics(
                child: CustomPaint(
                  painter: _ComingSoonBackdropPainter(dark: dark),
                ),
              ),
            ),
            Positioned.fill(
              bottom: 88,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxHeight < 610;
                  final horizontalPadding = constraints.maxWidth < 350
                      ? 20.0
                      : 28.0;
                  return SingleChildScrollView(
                    key: const Key('videos-coming-soon-scroll'),
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      compact ? 16 : 28,
                      horizontalPadding,
                      compact ? 18 : 28,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: math.max(
                          0,
                          constraints.maxHeight - (compact ? 34 : 56),
                        ),
                      ),
                      child: Center(
                        child: _ComingSoonContent(
                          animation: _tvController,
                          compact: compact,
                          dark: dark,
                          reduceMotion: reduceMotion,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: FloatingLiquidNav(
                selectedRoute: AppRoutes.videos,
                activeProfile: _activeProfile,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComingSoonContent extends StatelessWidget {
  const _ComingSoonContent({
    required this.animation,
    required this.compact,
    required this.dark,
    required this.reduceMotion,
  });

  final Animation<double> animation;
  final bool compact;
  final bool dark;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final foreground = dark ? Colors.white : _watchInk;
    final muted = foreground.withValues(alpha: 0.72);
    final illustrationSize = compact ? 148.0 : 190.0;

    return Semantics(
      key: const Key('videos-coming-soon'),
      container: true,
      explicitChildNodes: true,
      label:
          'Videos are coming soon. We are getting joyful Bible adventures '
          'ready for you.',
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _SoonEyebrow(foreground: foreground, dark: dark),
            SizedBox(height: compact ? 18 : 25),
            Semantics(
              image: true,
              label: 'A happy television getting ready for a new show',
              child: ExcludeSemantics(
                child: AnimatedBuilder(
                  animation: animation,
                  builder: (context, child) {
                    final phase = animation.value * math.pi * 2;
                    final bob = reduceMotion ? 0.0 : math.sin(phase) * 7;
                    final tilt = reduceMotion
                        ? 0.0
                        : math.sin(phase + math.pi / 2) * 0.018;
                    return Transform.translate(
                      key: const Key('coming-soon-tv-motion'),
                      offset: Offset(0, bob),
                      child: Transform.rotate(angle: tilt, child: child),
                    );
                  },
                  child: _TelevisionTile(
                    size: illustrationSize,
                    foreground: _watchInk,
                  ),
                ),
              ),
            ),
            SizedBox(height: compact ? 23 : 32),
            Text(
              'Videos are\ncoming soon!',
              key: const Key('videos-coming-soon-title'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                color: foreground,
                fontSize: compact ? 36 : 45,
                height: 0.96,
                fontWeight: FontWeight.w900,
                letterSpacing: -1.7,
              ),
            ),
            SizedBox(height: compact ? 12 : 16),
            Text(
              'We’re getting joyful Bible adventures ready for you. '
              'The Watch Clubhouse will open its doors soon!',
              key: const Key('videos-coming-soon-message'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: muted,
                fontSize: compact ? 14 : 16,
                height: 1.38,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
            SizedBox(height: compact ? 17 : 22),
            DecoratedBox(
              decoration: BoxDecoration(
                color: dark
                    ? Colors.white.withValues(alpha: 0.12)
                    : _watchCream.withValues(alpha: 0.92),
                border: Border.all(color: foreground, width: 2),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 15,
                  vertical: 9,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.auto_awesome_rounded,
                      color: _watchCoral,
                      size: 19,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'New stories are on the way',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: foreground,
                          fontSize: 12,
                          height: 1.1,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SoonEyebrow extends StatelessWidget {
  const _SoonEyebrow({required this.foreground, required this.dark});

  final Color foreground;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: dark ? _watchPurple : Colors.white.withValues(alpha: 0.92),
        border: Border.all(color: foreground, width: 2),
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: foreground.withValues(alpha: 0.16),
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text(
          'THE WATCH CLUBHOUSE',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: foreground,
            fontSize: 11,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.15,
          ),
        ),
      ),
    );
  }
}

class _TelevisionTile extends StatelessWidget {
  const _TelevisionTile({required this.size, required this.foreground});

  final double size;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('coming-soon-tv-tile'),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _watchYellow,
        border: Border.all(color: foreground, width: 3),
        borderRadius: BorderRadius.circular(size * 0.28),
        boxShadow: [
          BoxShadow(
            color: foreground,
            offset: Offset(size * 0.045, size * 0.055),
          ),
        ],
      ),
      child: CustomPaint(painter: _HappyTelevisionPainter(ink: foreground)),
    );
  }
}

class _HappyTelevisionPainter extends CustomPainter {
  const _HappyTelevisionPainter({required this.ink});

  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 190;
    final stroke = 5.5 * scale;
    final inkPaint = Paint()
      ..color = ink
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final antennaOrigin = Offset(size.width * 0.52, size.height * 0.31);
    canvas.drawLine(
      antennaOrigin,
      Offset(size.width * 0.37, size.height * 0.16),
      inkPaint,
    );
    canvas.drawLine(
      antennaOrigin,
      Offset(size.width * 0.68, size.height * 0.12),
      inkPaint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.37, size.height * 0.16),
      4 * scale,
      Paint()..color = _watchCoral,
    );
    canvas.drawCircle(
      Offset(size.width * 0.68, size.height * 0.12),
      4 * scale,
      Paint()..color = _watchPurple,
    );

    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        size.width * 0.16,
        size.height * 0.28,
        size.width * 0.70,
        size.height * 0.50,
      ),
      Radius.circular(size.width * 0.10),
    );
    canvas.drawRRect(body, Paint()..color = _watchCream);
    canvas.drawRRect(body, inkPaint);

    final screen = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        size.width * 0.23,
        size.height * 0.35,
        size.width * 0.43,
        size.height * 0.34,
      ),
      Radius.circular(size.width * 0.065),
    );
    canvas.drawRRect(screen, Paint()..color = _watchMint);
    canvas.drawRRect(
      screen,
      Paint()
        ..color = ink
        ..strokeWidth = 4 * scale
        ..style = PaintingStyle.stroke,
    );

    final eyePaint = Paint()..color = ink;
    canvas.drawCircle(
      Offset(size.width * 0.35, size.height * 0.49),
      4 * scale,
      eyePaint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.53, size.height * 0.49),
      4 * scale,
      eyePaint,
    );
    final smile = Path()
      ..moveTo(size.width * 0.36, size.height * 0.57)
      ..quadraticBezierTo(
        size.width * 0.44,
        size.height * 0.64,
        size.width * 0.53,
        size.height * 0.57,
      );
    canvas.drawPath(smile, inkPaint..strokeWidth = 4 * scale);

    canvas.drawCircle(
      Offset(size.width * 0.76, size.height * 0.44),
      8 * scale,
      Paint()..color = _watchCoral,
    );
    canvas.drawCircle(
      Offset(size.width * 0.76, size.height * 0.61),
      8 * scale,
      Paint()..color = _watchPurple,
    );

    canvas.drawLine(
      Offset(size.width * 0.32, size.height * 0.80),
      Offset(size.width * 0.28, size.height * 0.86),
      inkPaint,
    );
    canvas.drawLine(
      Offset(size.width * 0.70, size.height * 0.80),
      Offset(size.width * 0.74, size.height * 0.86),
      inkPaint,
    );

    final sparklePaint = Paint()..color = _watchCream;
    final sparkleCenter = Offset(size.width * 0.87, size.height * 0.22);
    final sparkle = Path();
    for (var index = 0; index < 8; index++) {
      final radius = index.isEven ? 11 * scale : 4 * scale;
      final angle = -math.pi / 2 + index * math.pi / 4;
      final point = Offset(
        sparkleCenter.dx + math.cos(angle) * radius,
        sparkleCenter.dy + math.sin(angle) * radius,
      );
      if (index == 0) {
        sparkle.moveTo(point.dx, point.dy);
      } else {
        sparkle.lineTo(point.dx, point.dy);
      }
    }
    sparkle.close();
    canvas.drawPath(sparkle, sparklePaint);
    canvas.drawPath(
      sparkle,
      Paint()
        ..color = ink
        ..strokeWidth = 2.5 * scale
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _HappyTelevisionPainter oldDelegate) {
    return oldDelegate.ink != ink;
  }
}

class _ComingSoonBackdropPainter extends CustomPainter {
  const _ComingSoonBackdropPainter({required this.dark});

  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final cloud = Paint()
      ..color = Colors.white.withValues(alpha: dark ? 0.08 : 0.33);
    canvas.drawCircle(Offset(size.width * 0.04, size.height * 0.15), 52, cloud);
    canvas.drawCircle(Offset(size.width * 0.17, size.height * 0.12), 36, cloud);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(-24, size.height * 0.12, size.width * 0.29, 55),
        const Radius.circular(28),
      ),
      cloud,
    );

    final sun = Paint()
      ..color = _watchYellow.withValues(alpha: dark ? 0.10 : 0.24);
    canvas.drawCircle(
      Offset(size.width * 0.96, size.height * 0.18),
      size.width * 0.26,
      sun,
    );

    final dots = [
      (Offset(size.width * 0.11, size.height * 0.39), _watchPurple, 8.0),
      (Offset(size.width * 0.90, size.height * 0.48), _watchCoral, 10.0),
      (Offset(size.width * 0.12, size.height * 0.76), _watchYellow, 7.0),
      (Offset(size.width * 0.91, size.height * 0.78), _watchMint, 8.0),
    ];
    for (final (offset, color, radius) in dots) {
      canvas.drawCircle(
        offset,
        radius,
        Paint()..color = color.withValues(alpha: dark ? 0.42 : 0.62),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ComingSoonBackdropPainter oldDelegate) {
    return oldDelegate.dark != dark;
  }
}

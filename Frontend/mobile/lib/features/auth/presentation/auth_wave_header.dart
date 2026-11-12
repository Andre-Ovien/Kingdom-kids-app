import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One continuous header: 0 is sign in, 1 is sign up.
class AuthWaveHeader extends StatelessWidget {
  const AuthWaveHeader({
    super.key,
    required this.progress,
    required this.height,
    required this.topInset,
    this.compact = false,
    this.color = const Color(0xFF1457FF),
  });

  final double progress;
  final double height;
  final double topInset;
  final bool compact;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0);
    final fontSize = compact ? 26.0 : 38.0;
    final titleStyle = TextStyle(
      fontFamily: 'OnboardingPoppins',
      color: Colors.white,
      fontSize: fontSize,
      height: 1.15,
      fontWeight: FontWeight.w700,
      letterSpacing: -1.1,
    );
    return SizedBox(
      key: const Key('auth-wave-header'),
      height: height,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipPath(
              clipper: AuthWaveClipper(progress: p, compact: compact),
              child: ColoredBox(color: color),
            ),
          ),
          Positioned(
            top: topInset + (compact ? 1 : 44),
            left: 0,
            right: 0,
            child: Semantics(
              header: true,
              label: p < 0.5 ? 'Sign in' : 'Sign up',
              child: ExcludeSemantics(
                child: Center(
                  child: AuthModeWordmark(
                    progress: p,
                    style: titleStyle,
                    gap: MediaQuery.textScalerOf(
                      context,
                    ).scale(compact ? 6 : 8),
                    signKey: const Key('auth-sign-label'),
                    suffixKey: const Key('auth-suffix-viewport'),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AuthModeWordmark extends StatelessWidget {
  const AuthModeWordmark({
    super.key,
    required this.progress,
    required this.style,
    required this.gap,
    this.signInSuffix = 'In',
    this.signUpSuffix = 'Up',
    this.signKey,
    this.suffixKey,
  });
  final double progress;
  final TextStyle style;
  final double gap;
  final String signInSuffix;
  final String signUpSuffix;
  final Key? signKey;
  final Key? suffixKey;

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0);
    Size measure(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final measured = painter.size;
      painter.dispose();
      return measured;
    }

    final signSize = measure('Sign');
    final inSize = measure(signInSuffix);
    final upSize = measure(signUpSuffix);
    final suffixWidth = math.max(inSize.width, upSize.width);
    final lineHeight =
        math.max(signSize.height, math.max(inSize.height, upSize.height)) + 4;
    return SizedBox(
      width: signSize.width + gap + suffixWidth + 2,
      height: lineHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: signSize.width + 1,
            child: Text('Sign', key: signKey, style: style),
          ),
          SizedBox(width: gap),
          Expanded(
            child: ClipRect(
              key: suffixKey,
              child: SizedBox(
                height: lineHeight,
                child: Stack(
                  alignment: Alignment.topLeft,
                  children: [
                    _Suffix(
                      text: signInSuffix,
                      opacity: 1 - p,
                      offset: -p * lineHeight,
                      angle: p * math.pi / 2,
                      style: style,
                    ),
                    _Suffix(
                      text: signUpSuffix,
                      opacity: p,
                      offset: (1 - p) * lineHeight,
                      angle: -(1 - p) * math.pi / 2,
                      style: style,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Suffix extends StatelessWidget {
  const _Suffix({
    required this.text,
    required this.opacity,
    required this.offset,
    required this.angle,
    required this.style,
  });

  final String text;
  final double opacity;
  final double offset;
  final double angle;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: Transform.translate(
        offset: Offset(0, offset),
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0015)
            ..rotateX(angle),
          child: Text(text, style: style),
        ),
      ),
    );
  }
}

/// Identical Bezier topology at both ends makes every intermediate wave valid.
class AuthWaveClipper extends CustomClipper<Path> {
  const AuthWaveClipper({required this.progress, this.compact = false});

  final double progress;
  final bool compact;

  @override
  Path getClip(Size size) {
    final w = size.width;
    final h = size.height;
    final depth = compact ? 14.0 : w * (0.16 + (1 - progress) * 0.01);
    // Traced from the supplied reference: two unequal rounded drops, a
    // shallow left scallop, and the narrower rising neck on the right.
    const contour = <Offset>[
      Offset(0, 430),
      Offset(.023, 433),
      Offset(.054, 437),
      Offset(.085, 438),
      Offset(.116, 434),
      Offset(.147, 432),
      Offset(.178, 434),
      Offset(.209, 441),
      Offset(.240, 452),
      Offset(.271, 462),
      Offset(.302, 468),
      Offset(.333, 470),
      Offset(.364, 468),
      Offset(.395, 463),
      Offset(.426, 453),
      Offset(.457, 443),
      Offset(.488, 435),
      Offset(.519, 432),
      Offset(.550, 433),
      Offset(.581, 437),
      Offset(.612, 451),
      Offset(.643, 467),
      Offset(.674, 472),
      Offset(.705, 474),
      Offset(.736, 472),
      Offset(.767, 467),
      Offset(.798, 453),
      Offset(.829, 438),
      Offset(.860, 426),
      Offset(.891, 423),
      Offset(.922, 426),
      Offset(.953, 433),
      Offset(1, 435),
    ];
    final points = contour
        .map((p) => Offset(p.dx * w, h - depth + depth * (p.dy - 423) / 51))
        .toList();
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(points.first.dx, points.first.dy);
    // Catmull–Rom to cubic Beziers preserves each measured feature and uses
    // exactly the same point topology throughout the mode transition.
    for (var i = 0; i < points.length - 1; i++) {
      final p0 = points[i == 0 ? 0 : i - 1];
      final p1 = points[i];
      final p2 = points[i + 1];
      final p3 = points[i + 2 < points.length ? i + 2 : points.length - 1];
      final c1 = p1 + (p2 - p0) / 6;
      final c2 = p2 - (p3 - p1) / 6;
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }
    return path
      ..lineTo(w, 0)
      ..close();
  }

  @override
  bool shouldReclip(AuthWaveClipper oldClipper) =>
      progress != oldClipper.progress || compact != oldClipper.compact;
}

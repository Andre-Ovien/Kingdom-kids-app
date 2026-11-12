import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A small native illustration, with no asset download or animation loop.
class PasswordResetIllustration extends StatelessWidget {
  const PasswordResetIllustration({
    super.key,
    this.codeSent = false,
    this.passwordReady = false,
  });

  final bool codeSent;
  final bool passwordReady;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(
      size: const Size(248, 200),
      painter: _ResetFacePainter(
        codeSent: codeSent,
        passwordReady: passwordReady,
      ),
    ),
  );
}

class _ResetFacePainter extends CustomPainter {
  const _ResetFacePainter({
    required this.codeSent,
    required this.passwordReady,
  });

  final bool codeSent;
  final bool passwordReady;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 248, size.height / 200);
    final shadow = Paint()..color = const Color(0xFFDFEDF2);
    canvas.drawOval(const Rect.fromLTWH(69, 171, 113, 9), shadow);
    final face = Rect.fromCircle(center: const Offset(124, 108), radius: 58);
    canvas.drawCircle(
      const Offset(124, 112),
      58,
      Paint()..color = const Color(0xFFE5AD24),
    );
    canvas.drawCircle(
      const Offset(124, 106),
      58,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-.38, -.55),
          radius: 1.25,
          colors: [Color(0xFFFFE974), Color(0xFFFFCF43)],
        ).createShader(face),
    );
    for (final x in [103.0, 145.0]) {
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x, 99), width: 31, height: 37),
        Paint()..color = const Color(0xFFF7FAFD),
      );
      final pupil = Offset(x + (codeSent ? 0 : 2), codeSent ? 100 : 92);
      canvas.drawOval(
        Rect.fromCenter(center: pupil, width: 12, height: 16),
        Paint()..color = const Color(0xFF26333C),
      );
      canvas.drawCircle(
        pupil + const Offset(-2, -3),
        2.2,
        Paint()..color = Colors.white,
      );
    }
    final line = Paint()
      ..color = const Color(0xFF7A4D23)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final mouth = Path()..moveTo(114, 135);
    if (codeSent) {
      mouth.quadraticBezierTo(124, 146, 135, 133);
    } else {
      mouth.quadraticBezierTo(124, 128, 132, 132);
    }
    canvas.drawPath(mouth, line);
    canvas.drawOval(
      const Rect.fromLTWH(80, 123, 15, 7),
      Paint()..color = const Color(0xFFFFB153),
    );
    canvas.drawOval(
      const Rect.fromLTWH(155, 123, 15, 7),
      Paint()..color = const Color(0xFFFFB153),
    );

    _star(canvas, const Offset(49, 116), 6, const Color(0xFFFFBB65));
    _star(canvas, const Offset(203, 89), 5, const Color(0xFFBBABF3));
    canvas.drawCircle(
      const Offset(193, 138),
      5,
      Paint()
        ..color = const Color(0xFF9DDCCF)
        ..strokeWidth = 2.6
        ..style = PaintingStyle.stroke,
    );
    canvas.drawCircle(
      const Offset(67, 48),
      2.8,
      Paint()..color = const Color(0xFF9DDCCF),
    );
    if (codeSent) {
      _star(canvas, const Offset(77, 41), 5, const Color(0xFF8CBFE8));
      _star(canvas, const Offset(172, 36), 7, const Color(0xFFE9B6D6));
      if (passwordReady) {
        _padlock(canvas);
      } else {
        _envelope(canvas);
      }
    } else {
      _question(canvas, const Offset(48, 60), -.28, const Color(0xFF4BAACB));
      _question(canvas, const Offset(188, 43), .22, const Color(0xFFAD93D1));
      _question(
        canvas,
        const Offset(207, 151),
        -.2,
        const Color(0xFFE8A47F),
        scale: .65,
      );
    }
    canvas.restore();
  }

  void _question(
    Canvas canvas,
    Offset position,
    double angle,
    Color color, {
    double scale = 1,
  }) {
    canvas.save();
    canvas.translate(position.dx, position.dy);
    canvas.rotate(angle);
    canvas.scale(scale);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(-7, -9)
      ..cubicTo(-7, -20, 10, -21, 10, -9)
      ..cubicTo(10, -1, 1, -1, 1, 7);
    canvas.drawPath(path, paint);
    canvas.drawCircle(const Offset(1, 17), 2.7, Paint()..color = color);
    canvas.restore();
  }

  void _star(Canvas canvas, Offset center, double radius, Color color) {
    final path = Path();
    for (var index = 0; index < 8; index++) {
      final angle = index * math.pi / 4 - math.pi / 2;
      final distance = index.isEven ? radius : radius * .34;
      final point =
          center + Offset(math.cos(angle), math.sin(angle)) * distance;
      if (index == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(path..close(), Paint()..color = color);
  }

  void _envelope(Canvas canvas) {
    canvas.save();
    canvas.translate(164, 151);
    canvas.rotate(-.15);
    final rect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(-29, -17, 58, 39),
      const Radius.circular(8),
    );
    canvas.drawRRect(rect, Paint()..color = const Color(0xFF60C3E7));
    canvas.drawPath(
      Path()
        ..moveTo(-26, -12)
        ..lineTo(0, 7)
        ..lineTo(26, -12),
      Paint()
        ..color = const Color(0xFFF2FBFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  void _padlock(Canvas canvas) {
    canvas.save();
    canvas.translate(164, 151);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-14, -27, 28, 34),
        const Radius.circular(14),
      ),
      Paint()
        ..color = const Color(0xFF4EA3C8)
        ..strokeWidth = 6
        ..style = PaintingStyle.stroke,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-23, -8, 46, 34),
        const Radius.circular(9),
      ),
      Paint()..color = const Color(0xFF60C3E7),
    );
    canvas.drawCircle(
      const Offset(0, 5),
      4,
      Paint()..color = const Color(0xFFF2FBFF),
    );
    canvas.drawLine(
      const Offset(0, 7),
      const Offset(0, 13),
      Paint()
        ..color = const Color(0xFFF2FBFF)
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ResetFacePainter oldDelegate) =>
      oldDelegate.codeSent != codeSent ||
      oldDelegate.passwordReady != passwordReady;
}

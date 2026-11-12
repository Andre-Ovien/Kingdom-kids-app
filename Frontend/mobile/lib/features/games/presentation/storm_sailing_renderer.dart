import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'storm_sailing_model.dart';

class StormSailingPainter extends CustomPainter {
  StormSailingPainter({
    required this.run,
    required this.time,
    required this.arrival,
    required this.reducedMotion,
    super.repaint,
  });
  final SailingRun run;
  final double Function() time;
  final double Function() arrival;
  final bool reducedMotion;
  late Canvas _canvas;
  late Size _size;
  late double _time;
  late double _focal;
  late double _horizon;
  late double _cameraX;
  final List<_Face> _faces = [];

  @override
  void paint(Canvas canvas, Size size) {
    _canvas = canvas;
    _size = size;
    _time = time();
    _focal = size.height * .9;
    _horizon = size.height * .24;
    _cameraX = run.x * 3.5;
    _faces.clear();
    _sky();
    _water();
    _coast();
    for (final obstacle in run.course.obstacles) {
      final z = (obstacle.progress - run.progress) * 220 + 2.5;
      if (z > -3 && z < 90) _reef(obstacle, z);
    }
    _wake();
    _ship();
    _faces.sort((a, b) => b.depth.compareTo(a.depth));
    for (final face in _faces) {
      final path = Path()..addPolygon(face.points.map(_project).toList(), true);
      canvas.drawPath(path, Paint()..color = face.color);
      // Hairline seams are covered without expensive per-frame shadows.
      canvas.drawPath(
        path,
        Paint()
          ..color = face.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = .65,
      );
    }
    _rain();
    final hit = (1 - (run.elapsed - run.lastHitAt) / .6).clamp(0, 1);
    if (hit > 0) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = Color.fromRGBO(255, 125, 87, hit * .16),
      );
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = const RadialGradient(
          radius: .9,
          colors: [Colors.transparent, Color(0x440C202F)],
          stops: [.45, 1],
        ).createShader(Offset.zero & size),
    );
  }

  Offset _project(_V point) {
    final depth = math.max(.8, point.z + 5);
    return Offset(
      _size.width / 2 + (point.x - _cameraX) * _focal / depth,
      _horizon + (3.5 - point.y) * _focal / depth,
    );
  }

  void _sky() {
    final rect = Offset.zero & _size;
    _canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF172D48), Color(0xFF667A92), Color(0xFFACCFD2)],
          stops: [0, .2, .35],
        ).createShader(rect),
    );
    final glow = Rect.fromCircle(
      center: Offset(_size.width * .8, _horizon * .82),
      radius: _size.width * .55,
    );
    _canvas.drawOval(
      glow,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0x558EE2E5), Colors.transparent],
        ).createShader(glow),
    );
    for (var i = 0; i < 13; i++) {
      final x = ((i * .19 + _time * .002) % 1.5 - .25) * _size.width;
      final y = _horizon * (.24 + (i % 4) * .15);
      final cloud = Rect.fromCenter(
        center: Offset(x, y),
        width: _size.width * (.55 + (i % 3) * .14),
        height: _horizon * .75,
      );
      _canvas.drawOval(
        cloud,
        Paint()
          ..shader = RadialGradient(
            colors: [
              const Color(0xFF243D56).withValues(alpha: .7),
              const Color(0x00243D56),
            ],
            radius: .6,
          ).createShader(cloud),
      );
    }
    if (!reducedMotion && (_time % 17) > 14.4 && (_time % 17) < 14.65) {
      final flash = math.sin((_time % 17 - 14.4) / .25 * math.pi) * .11;
      _canvas.drawRect(
        Rect.fromLTRB(0, 0, _size.width, _horizon * 1.1),
        Paint()..color = Colors.white.withValues(alpha: flash),
      );
    }
  }

  double _wave(double x, double z) =>
      math.sin(x * 1.6 + z * .83 - _time * 2.4) * .065 +
      math.sin(x * 2.4 - z * 1.2 + _time * 3.2) * .04;

  void _water() {
    final rect = Rect.fromLTRB(0, _horizon, _size.width, _size.height);
    _canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF81ABB4), Color(0xFF267B89), Color(0xFF07495D)],
        ).createShader(rect),
    );
    final positions = <Offset>[];
    final colors = <Color>[];
    for (var row = 0; row < 30; row++) {
      final near = -2.35 + row * row * .125;
      final far = -2.35 + (row + 1) * (row + 1) * .125;
      for (var col = 0; col < 22; col++) {
        final a = col / 22 * 2 - 1;
        final b = (col + 1) / 22 * 2 - 1;
        _V vertex(double u, double z) {
          final x = _cameraX + u * (_size.width / _focal) * (z + 5) * .56;
          return _V(x, _wave(x, z + run.elapsed * 5), z);
        }

        final points = [
          vertex(a, near),
          vertex(b, near),
          vertex(b, far),
          vertex(a, far),
        ];
        for (final index in [0, 1, 2, 0, 2, 3]) {
          final p = points[index];
          positions.add(_project(p));
          final slope = math.cos(
            p.x * 1.6 + (p.z + run.elapsed * 5) * .83 - _time * 2.4,
          );
          final shade = ((slope + 1) * .5).clamp(0.0, 1.0);
          final base = Color.lerp(
            const Color(0xFF0E596F),
            const Color(0xFF57A7AC),
            shade,
          )!;
          colors.add(
            Color.lerp(
              base,
              const Color(0xFF8DB6BD),
              (p.z / 100).clamp(0, .75),
            )!,
          );
        }
      }
    }
    final vertices = ui.Vertices(
      ui.VertexMode.triangles,
      positions,
      colors: colors,
    );
    _canvas.drawVertices(vertices, BlendMode.srcOver, Paint());
    vertices.dispose();
    // Moving crests recede in perspective instead of sliding as a flat texture.
    for (var row = 0; row < 34; row++) {
      final z = -1.5 + ((row * 2.75 - _time * 3.2) % 94);
      for (var col = -3; col <= 3; col++) {
        final x = col * 3.4 + math.sin(row * 8.1) * 1.8;
        final path = Path();
        for (var k = 0; k <= 10; k++) {
          final px = x + k * .16;
          final pz = z + math.sin(k * .4 + row) * .13;
          final point = _project(
            _V(px, _wave(px, pz + run.elapsed * 5) + .015, pz),
          );
          if (k == 0) {
            path.moveTo(point.dx, point.dy);
          } else {
            path.lineTo(point.dx, point.dy);
          }
        }
        _canvas.drawPath(
          path,
          Paint()
            ..color = const Color(
              0xFFC7ECE8,
            ).withValues(alpha: .13 + .13 * (1 - z / 95))
            ..style = PaintingStyle.stroke
            ..strokeWidth = (_focal / (z + 5) * .013).clamp(.4, 2.2)
            ..strokeCap = StrokeCap.round,
        );
      }
    }
  }

  void _coast() {
    final approaching = ((run.progress - .72) / .28).clamp(0.0, 1.0);
    final height = _size.height * (.012 + .075 * approaching);
    final shore = Path()..moveTo(0, _horizon + 4);
    for (var i = 0; i <= 20; i++) {
      final x = _size.width * i / 20;
      shore.lineTo(
        x,
        _horizon -
            height * (.6 + .25 * math.sin(i * 1.7) + .12 * math.cos(i * 3)),
      );
    }
    shore
      ..lineTo(_size.width, _horizon + 8)
      ..close();
    _canvas.drawPath(
      shore,
      Paint()
        ..color = Color.lerp(
          const Color(0xFF658B96),
          const Color(0xFF244E53),
          approaching,
        )!,
    );
    final lightX = _size.width * .7 - run.x * _size.width * .06;
    final baseY = _horizon - height * .45;
    final tower = height * 1.5;
    _canvas.drawPath(
      Path()
        ..moveTo(lightX - tower * .1, baseY)
        ..lineTo(lightX - tower * .075, baseY - tower)
        ..lineTo(lightX + tower * .075, baseY - tower)
        ..lineTo(lightX + tower * .1, baseY)
        ..close(),
      Paint()..color = const Color(0xFFDFE8D8),
    );
    final beacon = Offset(lightX, baseY - tower * .92);
    final halo = Rect.fromCircle(center: beacon, radius: 9 + approaching * 10);
    _canvas.drawOval(
      halo,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0x99FFE9A7), Color(0x00FFE9A7)],
        ).createShader(halo),
    );
    _canvas.drawCircle(
      beacon,
      1.2 + approaching * 2.5,
      Paint()..color = const Color(0xFFFFECB2),
    );
    if (arrival() > 0) {
      final dock = _project(const _V(0, .02, 10));
      final rect = Rect.fromCenter(
        center: dock,
        width: _size.width * .6,
        height: 18,
      );
      _canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()
          ..color = const Color(
            0xFF8D6D46,
          ).withValues(alpha: arrival().clamp(0, 1)),
      );
    }
  }

  void _wake() {
    for (var side in [-1.0, 1.0]) {
      for (var line = 0; line < 4; line++) {
        final path = Path();
        for (var i = 0; i < 18; i++) {
          final z = 1.1 - i * .17;
          final spread = .45 + i * .045 + line * .06;
          final px =
              run.positionAgo(i * .07) * 4.6 +
              side * spread +
              math.sin(i * .8 + _time * 7) * .035;
          final p = _project(_V(px, .01, z));
          if (i == 0) {
            path.moveTo(p.dx, p.dy);
          } else {
            path.lineTo(p.dx, p.dy);
          }
        }
        _canvas.drawPath(
          path,
          Paint()
            ..color = const Color(
              0xFFD9F9EF,
            ).withValues(alpha: run.started ? .32 - line * .06 : .08)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.8 - line * .3
            ..strokeCap = StrokeCap.round,
        );
      }
    }
  }

  void _reef(SailingObstacle obstacle, double z) {
    final radius = obstacle.radius * 4.6;
    final x = obstacle.x * 4.6;
    final seed = obstacle.id.codeUnits.fold<int>(0, (a, b) => a + b);
    final top = _V(x + radius * .16, radius * 1.12, z - radius * .1);
    final rim = <_V>[];
    final shoulders = <_V>[];
    for (var i = 0; i < 7; i++) {
      final angle = i / 7 * math.pi * 2;
      final r = radius * (.9 + .1 * math.sin(seed + i * 8));
      rim.add(
        _V(
          x + math.cos(angle) * r,
          .04 + .18 * radius * (i % 2),
          z + math.sin(angle) * r,
        ),
      );
      shoulders.add(
        _V(
          x + math.cos(angle) * r * (.52 + .13 * math.sin(seed + i)),
          radius * (.62 + .22 * math.sin(seed * .7 + i * 2.1)),
          z + math.sin(angle) * r * .66,
        ),
      );
    }
    for (var i = 0; i < rim.length; i++) {
      final next = (i + 1) % rim.length;
      final light = (.35 + .5 * (math.cos(i / 7 * math.pi * 2 - .8) + 1) / 2);
      final shade = Color.lerp(
        const Color(0xFF2D4A55),
        const Color(0xFF879D9E),
        light,
      )!;
      _face([rim[i], rim[next], shoulders[next], shoulders[i]], shade);
      _face([
        shoulders[i],
        shoulders[next],
        top,
      ], Color.lerp(shade, const Color(0xFFB2BABB), .13)!);
    }
    final p = _project(_V(x, 0, z));
    final scale = _focal / (z + 5);
    _canvas.drawOval(
      Rect.fromCenter(
        center: p,
        width: radius * scale * 2.5,
        height: radius * scale * .35,
      ),
      Paint()
        ..color = const Color(0xFFBFE5DC).withValues(alpha: .4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = (scale * .014).clamp(.7, 3),
    );
  }

  _V _shipPoint(double x, double y, double z) {
    final roll = -run.velocity * .055 + math.sin(_time * 2.1) * .025;
    final pitch = math.sin(_time * 2.7) * .02;
    final yaw = run.velocity * .17;
    final rolledX = x * math.cos(roll) - y * math.sin(roll);
    final rolledY = x * math.sin(roll) + y * math.cos(roll);
    final pitchedY = rolledY * math.cos(pitch) - z * math.sin(pitch);
    final pitchedZ = rolledY * math.sin(pitch) + z * math.cos(pitch);
    return _V(
      rolledX * math.cos(yaw) + pitchedZ * math.sin(yaw) + run.x * 4.6,
      pitchedY + .035 * math.sin(_time * 3.1),
      pitchedZ * math.cos(yaw) - rolledX * math.sin(yaw) + 2.5,
    );
  }

  void _ship() {
    final outline = [
      const _V(-.46, .35, -1.25),
      const _V(-.7, .43, -.45),
      const _V(-.58, .47, .6),
      const _V(0, .58, 1.65),
      const _V(.58, .47, .6),
      const _V(.7, .43, -.45),
      const _V(.46, .35, -1.25),
    ];
    final lower = [
      const _V(-.27, -.03, -1.1),
      const _V(-.45, -.08, -.4),
      const _V(-.37, -.04, .6),
      const _V(0, .2, 1.6),
      const _V(.37, -.04, .6),
      const _V(.45, -.08, -.4),
      const _V(.27, -.03, -1.1),
    ];
    for (var i = 0; i < outline.length; i++) {
      final next = (i + 1) % outline.length;
      final color = i < 3 ? const Color(0xFF8A4C2D) : const Color(0xFFB57B42);
      _shipFace([outline[i], outline[next], lower[next], lower[i]], color);
      _shipFace([
        outline[i],
        outline[next],
        const _V(0, .39, 0),
      ], const Color(0xFFD0A366));
      // Raised gunwales and darker wooden planking stay joined to the hull.
      final a = outline[i];
      final b = outline[next];
      _shipFace([
        a,
        b,
        _V(b.x * 1.015, b.y + .095, b.z),
        _V(a.x * 1.015, a.y + .095, a.z),
      ], const Color(0xFF683E2A));
      for (var plank = 1; plank <= 3; plank++) {
        final t = plank / 4;
        final pa = _V.lerp(lower[i], a, t);
        final pb = _V.lerp(lower[next], b, t);
        _shipFace([
          pa,
          pb,
          _V(pb.x, pb.y + .012, pb.z),
          _V(pa.x, pa.y + .012, pa.z),
        ], const Color(0xFF6E432C));
      }
    }
    // Deck boards, stern cabin, masts and rigging are actual projected geometry.
    for (var i = 0; i < 11; i++) {
      final z = -1.04 + i * .21;
      final width = z < -.45
          ? .43 + (z + 1.25) / .8 * .22
          : z < .6
          ? .62
          : math.max(.1, .55 * (1.65 - z));
      _shipFace([
        _V(-width, .443, z),
        _V(width, .443, z),
        _V(width, .443, z + .012),
        _V(-width, .443, z + .012),
      ], const Color(0xFF9E7446));
    }
    _box(-.34, .45, -1.0, .68, .25, .4, const Color(0xFFAE7845));
    _box(-.39, .7, -1.06, .78, .055, .52, const Color(0xFF673D2A));
    _box(-.026, .4, .06, .052, 2.22, .052, const Color(0xFF674A32));
    _box(-.022, .48, 1.05, .044, 1.36, .044, const Color(0xFF805737));
    _box(-.82, 2.27, .07, 1.64, .035, .035, const Color(0xFF69503A));
    _sail(-.78, .78, 1.0, 2.27, .075, 9, 7);
    _sail(-.39, .39, .86, 1.61, 1.07, 6, 5);
    _rope(const _V(0, 2.6, .09), const _V(-.62, .52, -.53));
    _rope(const _V(0, 2.6, .09), const _V(.62, .52, -.53));
    _rope(const _V(0, 2.6, .09), const _V(0, .66, 1.57));
    _rope(const _V(-.78, 2.27, .075), const _V(-.56, .53, .59));
    _rope(const _V(.78, 2.27, .075), const _V(.56, .53, .59));
    // Small pennant catches the wind, without rotating the whole ship image.
    final flutter = math.sin(_time * 8) * .06;
    _shipFace([
      const _V(0, 2.6, .09),
      const _V(0, 2.42, .09),
      _V(.36, 2.5 + flutter, .13),
    ], const Color(0xFFE8AD50));
  }

  void _sail(
    double left,
    double right,
    double bottom,
    double top,
    double z,
    int columns,
    int rows,
  ) {
    _V point(int x, int y) {
      final u = x / columns;
      final v = y / rows;
      final billow =
          math.sin(u * math.pi) *
          math.sin(v * math.pi) *
          (.23 + .035 * math.sin(_time * 3.2 + u * 3));
      return _V(
        (left + (right - left) * u) * (1 - .12 * v),
        bottom + (top - bottom) * v + .075 * math.sin(u * math.pi) * (1 - v),
        z - billow,
      );
    }

    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < columns; x++) {
        final shade = math.sin(x / columns * math.pi);
        final color = Color.lerp(
          const Color(0xFFA5BBB7),
          const Color(0xFFF5F0D9),
          shade * .65 + .3,
        )!;
        _shipFace([
          point(x, y),
          point(x + 1, y),
          point(x + 1, y + 1),
          point(x, y + 1),
        ], color);
        if (x == 0 || x == columns - 1) {
          _rope(point(x, y), point(x, y + 1));
        }
      }
    }
  }

  void _rope(_V a, _V b) {
    const width = .009;
    _shipFace([
      _V(a.x - width, a.y, a.z),
      _V(a.x + width, a.y, a.z),
      _V(b.x + width, b.y, b.z),
      _V(b.x - width, b.y, b.z),
    ], const Color(0xFF8D8267));
  }

  void _box(
    double x,
    double y,
    double z,
    double w,
    double h,
    double d,
    Color color,
  ) {
    final p = [
      _V(x, y, z),
      _V(x + w, y, z),
      _V(x + w, y + h, z),
      _V(x, y + h, z),
      _V(x, y, z + d),
      _V(x + w, y, z + d),
      _V(x + w, y + h, z + d),
      _V(x, y + h, z + d),
    ];
    final faces = [
      [0, 1, 2, 3],
      [1, 5, 6, 2],
      [4, 0, 3, 7],
      [5, 4, 7, 6],
      [3, 2, 6, 7],
    ];
    for (var face = 0; face < faces.length; face++) {
      final shade = face == 4
          ? Color.lerp(color, const Color(0xFFFFE6B3), .18)!
          : Color.lerp(color, const Color(0xFF2B292C), face == 0 ? .15 : .28)!;
      _shipFace([for (final i in faces[face]) p[i]], shade);
    }
  }

  void _shipFace(List<_V> points, Color color) =>
      _face([for (final p in points) _shipPoint(p.x, p.y, p.z)], color);
  void _face(List<_V> points, Color color) {
    _faces.add(
      _Face(
        points,
        color,
        points.fold<double>(0, (sum, p) => sum + p.z) / points.length,
      ),
    );
  }

  void _rain() {
    final strength = (1 - ((run.progress - .86) / .14).clamp(0, .75));
    final paint = Paint()
      ..strokeWidth = .85
      ..strokeCap = StrokeCap.round;
    final count = reducedMotion ? 36 : 115;
    for (var i = 0; i < count; i++) {
      final seed = (i * 7919 % 997) / 997;
      final x = ((seed + _time * .09) % 1.25 - .13) * _size.width;
      final y = ((i * .618033 + _time * (.75 + seed * .45)) % 1) * _size.height;
      final length = 7 + seed * 15;
      paint.color = const Color(
        0xFFDAF3F3,
      ).withValues(alpha: (.08 + seed * .22) * strength);
      _canvas.drawLine(
        Offset(x, y),
        Offset(x - length * .35, y + length),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant StormSailingPainter oldDelegate) =>
      oldDelegate.run != run || oldDelegate.reducedMotion != reducedMotion;
}

class _V {
  const _V(this.x, this.y, this.z);
  final double x, y, z;
  static _V lerp(_V a, _V b, double t) =>
      _V(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t);
}

class _Face {
  const _Face(this.points, this.color, this.depth);
  final List<_V> points;
  final Color color;
  final double depth;
}

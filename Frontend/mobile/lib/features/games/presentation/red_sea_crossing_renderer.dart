import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'red_sea_crossing_graphics.dart';
import 'red_sea_crossing_model.dart';

/// The crowd's feet and visible pickup points are shared with gesture targets.
class RedSeaCrossingPainter extends CustomPainter {
  RedSeaCrossingPainter({
    required this.run,
    required this.sceneTime,
    required this.draggedPosition,
    required this.draggedTravellerId,
    required this.reducedMotion,
    this.graphics,
    super.repaint,
  });

  final RedSeaCrossingRun run;
  final double Function() sceneTime;
  final Offset? Function() draggedPosition;
  final String? Function() draggedTravellerId;
  final bool reducedMotion;
  final RedSeaCrossingGraphics? graphics;
  late Canvas _canvas;
  late Size _size;
  late double _time;
  late double _opening;

  static double travellerRadius(Size size) =>
      math.min(size.width * .11, size.height * .055);

  // These deliberately uneven groups leave every head visible while allowing
  // lower robes to overlap naturally. Their ordering mixes the three existing
  // native man, woman and child assets throughout the crowd.
  static const _tenPersonCrowd = <Offset>[
    Offset(.18, .865),
    Offset(.46, .842),
    Offset(.75, .864),
    Offset(.33, .907),
    Offset(.62, .919),
    Offset(.87, .921),
    Offset(.11, .949),
    Offset(.40, .978),
    Offset(.68, .965),
    Offset(.89, .982),
  ];
  static const _fifteenPersonCrowd = <Offset>[
    Offset(.14, .835),
    Offset(.38, .849),
    Offset(.61, .838),
    Offset(.84, .856),
    Offset(.25, .888),
    Offset(.50, .889),
    Offset(.75, .908),
    Offset(.10, .920),
    Offset(.36, .938),
    Offset(.61, .946),
    Offset(.88, .951),
    Offset(.22, .974),
    Offset(.48, .981),
    Offset(.75, .981),
    Offset(.91, .989),
  ];
  static const _twentyPersonCrowd = <Offset>[
    Offset(.13, .830),
    Offset(.34, .839),
    Offset(.55, .826),
    Offset(.77, .844),
    Offset(.91, .858),
    Offset(.22, .876),
    Offset(.45, .881),
    Offset(.66, .878),
    Offset(.83, .896),
    Offset(.10, .914),
    Offset(.32, .916),
    Offset(.54, .929),
    Offset(.73, .935),
    Offset(.92, .937),
    Offset(.20, .961),
    Offset(.42, .963),
    Offset(.62, .978),
    Offset(.83, .970),
    Offset(.08, .985),
    Offset(.96, .985),
  ];

  static Offset queuePosition(int index, int count, Size size) {
    if (size.isEmpty || index < 0 || index >= count) return Offset.zero;
    final group = count <= 10
        ? _tenPersonCrowd
        : count <= 15
        ? _fifteenPersonCrowd
        : _twentyPersonCrowd;
    final point = group[index % group.length];
    final edge = math.max(
      18.0,
      math.min(size.width * .06, travellerRadius(size) * .6),
    );
    return Offset(
      (point.dx * size.width).clamp(edge, size.width - edge),
      point.dy * size.height,
    );
  }

  /// Crowd density changes positions, not anatomical size relative to Moses.
  static double crowdRadius(int count, Size size) =>
      count > 0 ? travellerRadius(size) : 0;

  static double travellerHeight(int index, int count, Size size) {
    if (size.isEmpty || count <= 0) return 0;
    final depth = queuePosition(index, count, size).dy / size.height;
    final perspective = .94 + .06 * ((depth - .826) / .163).clamp(0.0, 1.0);
    return crowdRadius(count, size) *
        2 *
        _travellerHeightScale(index) *
        perspective;
  }

  /// The face remains visible even when a nearer traveller covers a lower robe.
  static Offset queueHitCenter(int index, int count, Size size) {
    final height = travellerHeight(index, count, size);
    return queuePosition(index, count, size) -
        Offset(height * .02, height * .94);
  }

  static Rect queueBodyBounds(int index, int count, Size size) {
    final foot = queuePosition(index, count, size);
    final height = travellerHeight(index, count, size);
    return Rect.fromLTWH(
      foot.dx - height * .23,
      foot.dy - height * 1.03,
      height * .46,
      height * 1.08,
    );
  }

  static Rect queueSemanticsBounds(int index, int count, Size size) {
    final center = queueHitCenter(index, count, size);
    final width = math.min(44.0, size.width);
    final height = math.min(44.0, size.height);
    return Rect.fromLTWH(
      (center.dx - width / 2).clamp(0.0, size.width - width),
      (center.dy - height / 2).clamp(0.0, size.height - height),
      width,
      height,
    );
  }

  static String travellerRole(int index) => switch (index % 3) {
    0 => 'man',
    1 => 'woman',
    _ => 'child',
  };

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    _canvas = canvas;
    _size = size;
    _time = reducedMotion ? 0 : sceneTime();
    _opening = _smooth(run.openingProgress);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (!_renderEnvironment()) {
      _sky();
      _farShore();
      _closedSea();
      _foreground();
      if (_opening > .001) {
        _dryPath();
        _waterWall(false);
        _waterWall(true);
      }
    }
    _people();
    if (graphics == null) _sunlight();
    canvas.restore();
  }

  bool _renderEnvironment() {
    final assets = graphics;
    if (assets == null) return false;
    final name = run.phase == RedSeaCrossingPhase.ready
        ? 'sea_ready'
        : run.phase == RedSeaCrossingPhase.parting
        ? 'sea_opening'
        : 'sea_idle';
    final clip = assets.clip(name);
    if (clip == null) return false;
    final progress = reducedMotion
        ? 0.0
        : switch (name) {
            'sea_opening' => run.openingProgress,
            'sea_ready' => _time / clip.durationSeconds,
            _ =>
              math.max(0, _time - RedSeaCrossingRun.partingSeconds) /
                  clip.durationSeconds,
          };
    clip.drawFrame(_canvas, progress, Offset.zero & _size);
    return true;
  }

  Offset _p(double x, double y) => Offset(x * _size.width, y * _size.height);
  double _smooth(double value) {
    final p = value.clamp(0.0, 1.0);
    return p * p * (3 - 2 * p);
  }

  void _fill(
    Path path,
    List<Color> colors, {
    Alignment begin = Alignment.topLeft,
    Alignment end = Alignment.bottomRight,
  }) {
    _canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: begin,
          end: end,
          colors: colors,
        ).createShader(path.getBounds()),
    );
  }

  void _line(Path path, Color color, double width) {
    _canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
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
          colors: [Color(0xFF76C8E0), Color(0xFFDBEACB), Color(0xFFFFD784)],
          stops: [0, .23, .4],
        ).createShader(rect),
    );
    final glow = Rect.fromCircle(
      center: _p(.64, .16),
      radius: _size.width * .62,
    );
    _canvas.drawOval(
      glow,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xDDFFF6BC), Color(0x55FFE6A2), Color(0x00FFE6A2)],
          stops: [0, .32, 1],
        ).createShader(glow),
    );
    _canvas.drawCircle(
      _p(.65, .153),
      _size.width * .069,
      Paint()..color = const Color(0xFFFFF8CC),
    );
    for (var i = 0; i < 6; i++) {
      final x = (.12 + i * .19 + _time * .002) % 1.2 - .1;
      final cloud = Path()
        ..moveTo(
          _p(x - .12, .17 + i % 3 * .024).dx,
          _p(0, .17 + i % 3 * .024).dy,
        )
        ..relativeCubicTo(
          _size.width * .018,
          -_size.height * .016,
          _size.width * .038,
          -_size.height * .022,
          _size.width * .057,
          -_size.height * .014,
        )
        ..relativeCubicTo(
          _size.width * .011,
          -_size.height * .035,
          _size.width * .07,
          -_size.height * .035,
          _size.width * .088,
          -_size.height * .006,
        )
        ..relativeCubicTo(
          _size.width * .037,
          -_size.height * .01,
          _size.width * .065,
          0,
          _size.width * .078,
          _size.height * .02,
        )
        ..close();
      _fill(cloud, [const Color(0xDFFFFFF0), const Color(0x00FFFFFF)]);
    }
    // Small gulls, with a wing beat rather than a translating static shape.
    for (var i = 0; i < 3; i++) {
      final origin = _p(.38 + i * .055, .222 + i % 2 * .012);
      final wing = math.sin(_time * 2.6 + i) * 1.5;
      _line(
        Path()
          ..moveTo(origin.dx - 5, origin.dy - 2 - wing)
          ..quadraticBezierTo(
            origin.dx - 2,
            origin.dy - 3,
            origin.dx,
            origin.dy,
          )
          ..quadraticBezierTo(
            origin.dx + 2,
            origin.dy - 3,
            origin.dx + 5,
            origin.dy - 2 - wing,
          ),
        const Color(0x77757058),
        1.1,
      );
    }
  }

  void _farShore() {
    final dunes = Path()
      ..moveTo(0, _size.height * .3)
      ..cubicTo(
        _size.width * .12,
        _size.height * .25,
        _size.width * .19,
        _size.height * .29,
        _size.width * .32,
        _size.height * .274,
      )
      ..cubicTo(
        _size.width * .43,
        _size.height * .255,
        _size.width * .55,
        _size.height * .3,
        _size.width * .71,
        _size.height * .266,
      )
      ..cubicTo(
        _size.width * .87,
        _size.height * .231,
        _size.width * .98,
        _size.height * .285,
        _size.width,
        _size.height * .271,
      )
      ..lineTo(_size.width, _size.height * .325)
      ..lineTo(0, _size.height * .325)
      ..close();
    _fill(dunes, [const Color(0xFFE9B264), const Color(0xFFFBE2A0)]);
    final shore = Path()
      ..moveTo(0, _size.height * .31)
      ..quadraticBezierTo(
        _size.width * .46,
        _size.height * .279,
        _size.width,
        _size.height * .304,
      )
      ..lineTo(_size.width, _size.height * .329)
      ..lineTo(0, _size.height * .334)
      ..close();
    _fill(shore, [const Color(0xFFF8D88F), const Color(0xFFDDA365)]);
    for (var i = 0; i < 5; i++) {
      final x = i < 3 ? .075 + i * .067 : .83 + (i - 3) * .06;
      _palm(_p(x, .299), _size.height * (.039 + i % 2 * .009));
    }
    for (var i = 0; i < 4; i++) {
      final rect = Rect.fromLTWH(
        _size.width * (.71 + i * .023),
        _size.height * .281,
        _size.width * .019,
        _size.height * .018,
      );
      _canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        Paint()
          ..color = Color.lerp(
            const Color(0xFFC09265),
            const Color(0xFFECCB93),
            i / 4,
          )!,
      );
      _canvas.drawRect(
        Rect.fromLTWH(
          rect.left + rect.width * .43,
          rect.bottom - rect.height * .44,
          rect.width * .25,
          rect.height * .44,
        ),
        Paint()..color = const Color(0x997D604E),
      );
    }
  }

  void _palm(Offset foot, double height) {
    final top = foot.translate(height * .13, -height);
    _line(
      Path()
        ..moveTo(foot.dx, foot.dy)
        ..quadraticBezierTo(
          foot.dx - height * .04,
          foot.dy - height * .55,
          top.dx,
          top.dy,
        ),
      const Color(0xAA9D7147),
      height * .085,
    );
    for (var i = 0; i < 7; i++) {
      final angle = math.pi + i * math.pi / 6;
      final tip =
          top +
          Offset(
            math.cos(angle) * height * .48,
            math.sin(angle) * height * .23 + height * .12,
          );
      _line(
        Path()
          ..moveTo(top.dx, top.dy)
          ..quadraticBezierTo(
            (top.dx + tip.dx) / 2,
            top.dy - height * .13,
            tip.dx,
            tip.dy,
          ),
        const Color(0xAA7D8A57),
        height * .075,
      );
    }
  }

  void _closedSea() {
    final water = Rect.fromLTRB(
      0,
      _size.height * .31,
      _size.width,
      _size.height * .81,
    );
    _canvas.drawRect(
      water,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF70D1D5), Color(0xFF168FB4), Color(0xFF087D9B)],
          stops: [0, .45, 1],
        ).createShader(water),
    );
    for (var row = 0; row < 24; row++) {
      final depth = row / 24;
      final y = .316 + depth * depth * .49;
      final ripple = Path();
      for (var j = 0; j <= 18; j++) {
        final x = j / 18;
        final p = _p(
          x,
          y +
              math.sin(j * .64 + row * .81 - _time * 1.3) *
                  (.001 + depth * .002),
        );
        if (j == 0) {
          ripple.moveTo(p.dx, p.dy);
        } else {
          ripple.lineTo(p.dx, p.dy);
        }
      }
      _line(
        ripple,
        Color.fromRGBO(189, 246, 232, .17 + depth * .12),
        .7 + depth * 1.3,
      );
    }
    final glitter = Rect.fromLTRB(
      _size.width * .45,
      _size.height * .31,
      _size.width * .73,
      _size.height * .61,
    );
    _canvas.drawOval(
      glitter,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0x44FFF3BE), Color(0x00FFF3BE)],
        ).createShader(glitter),
    );
  }

  void _foreground() {
    final sand = Path()
      ..moveTo(0, _size.height * .773)
      ..quadraticBezierTo(
        _size.width * .24,
        _size.height * .728,
        _size.width * .48,
        _size.height * .766,
      )
      ..quadraticBezierTo(
        _size.width * .75,
        _size.height * .73,
        _size.width,
        _size.height * .763,
      )
      ..lineTo(_size.width, _size.height)
      ..lineTo(0, _size.height)
      ..close();
    _fill(sand, [
      const Color(0xFFF5D191),
      const Color(0xFFEABA76),
      const Color(0xFFD5A361),
    ]);
    for (var i = 0; i < 64; i++) {
      final x = ((i * 47 + 13) % 97) / 97;
      final y = .782 + ((i * 31) % 89) / 89 * .215;
      final radius = _size.width * (.0018 + i % 4 * .0012);
      _canvas.drawOval(
        Rect.fromCenter(center: _p(x, y), width: radius * 2.6, height: radius),
        Paint()
          ..color = i.isEven
              ? const Color(0x3FA17342)
              : const Color(0x55FFF0BB),
      );
    }
    _rock(_p(.03, .817), _size.width * .048, const Color(0xFFA9856B));
    _rock(_p(.94, .789), _size.width * .041, const Color(0xFFBB9270));
    _rock(_p(.04, .985), _size.width * .066, const Color(0xFFC68C58));
    _rock(_p(.975, .982), _size.width * .061, const Color(0xFFB38158));
  }

  // At y=.43 the half-width is .225, so all four corners of the authored
  // .34..66 / .43..70 rectangle are on sand. Perspective never narrows that
  // playable rectangle into water.
  double _pathHalfWidth(double y) {
    if (y < .43) return .043 + (y - .29).clamp(0, .14) / .14 * .182;
    return .225 + (y - .43).clamp(0, .37) / .37 * .225;
  }

  Path _pathShape() {
    final path = Path();
    for (var i = 0; i <= 28; i++) {
      final y = .29 + i / 28 * .53;
      final p = _p(.5 - _pathHalfWidth(y) * _opening, y);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    for (var i = 28; i >= 0; i--) {
      final y = .29 + i / 28 * .53;
      final p = _p(.5 + _pathHalfWidth(y) * _opening, y);
      path.lineTo(p.dx, p.dy);
    }
    return path..close();
  }

  void _dryPath() {
    final path = _pathShape();
    _fill(
      path,
      [
        const Color(0xFFFFE9AA),
        const Color(0xFFF4C777),
        const Color(0xFFE5AB62),
      ],
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
    );
    _canvas.save();
    _canvas.clipPath(path);
    final brightLane = Path()
      ..moveTo(_size.width * .486, _size.height * .29)
      ..lineTo(_size.width * .61, _size.height * .82)
      ..lineTo(_size.width * .35, _size.height * .82)
      ..close();
    _fill(brightLane, [const Color(0x55FFF8BD), const Color(0x33FFE9A6)]);
    for (var i = 0; i < 79; i++) {
      final y = .322 + ((i * 41) % 83) / 83 * .47;
      final half = _pathHalfWidth(y);
      final x = .5 + (((i * 59) % 89) / 89 * 2 - 1) * half * .96;
      final r = _size.width * (.0016 + (y - .29) * .016) * (1 + i % 3 * .3);
      if (i % 7 == 0) {
        _rock(_p(x, y), r * 1.5, const Color(0xFFB88E60));
      } else {
        _canvas.drawOval(
          Rect.fromCenter(center: _p(x, y), width: r * 2.2, height: r * .8),
          Paint()
            ..color = i.isEven
                ? const Color(0x44895F36)
                : const Color(0x66FFEDB1),
        );
      }
    }
    _canvas.restore();
    for (final sign in [-1.0, 1.0]) {
      final edge = Path();
      for (var i = 0; i <= 26; i++) {
        final y = .30 + i / 26 * .49;
        final p = _p(.5 + sign * _pathHalfWidth(y) * _opening, y);
        if (i == 0) {
          edge.moveTo(p.dx, p.dy);
        } else {
          edge.lineTo(p.dx, p.dy);
        }
      }
      _line(edge, const Color(0x558E805A), _size.width * .006);
    }
  }

  void _waterWall(bool right) {
    final sign = right ? 1.0 : -1.0;
    final face = Path();
    final foot = <Offset>[];
    final crest = <Offset>[];
    for (var i = 0; i <= 36; i++) {
      final t = i / 36;
      final y = .302 + t * .486;
      final half = _pathHalfWidth(y) * _opening;
      final height = _wallHeight(t, right);
      final ripple = math.sin(t * 18 - _time * 1.05) * .007 * t * _opening;
      foot.add(_p(.5 + sign * half, y));
      crest.add(
        _p(.5 + sign * (half + .028 * t * _opening + ripple), y - height),
      );
    }
    face.moveTo(foot.first.dx, foot.first.dy);
    for (final p in foot.skip(1)) {
      face.lineTo(p.dx, p.dy);
    }
    for (final p in crest.reversed) {
      face.lineTo(p.dx, p.dy);
    }
    face.close();
    _fill(
      face,
      [
        const Color(0xF246D2E0),
        const Color(0xE5087DAE),
        const Color(0xF007527F),
      ],
      begin: right ? Alignment.topLeft : Alignment.topRight,
      end: right ? Alignment.bottomRight : Alignment.bottomLeft,
    );
    _canvas.save();
    _canvas.clipPath(face);
    for (var strand = 0; strand < 17; strand++) {
      final flow = Path();
      for (var i = 0; i <= 36; i++) {
        final t = i / 36;
        final y = .304 + t * .48;
        final half = _pathHalfWidth(y) * _opening;
        final frac = strand / 16;
        final wave =
            math.sin(t * 17 + frac * 9 - _time * 1.4) * .012 * t * _opening;
        final p = _p(
          .5 + sign * (half + wave + frac * .023 * t * _opening),
          y - _wallHeight(t, right) * frac,
        );
        if (i == 0) {
          flow.moveTo(p.dx, p.dy);
        } else {
          flow.lineTo(p.dx, p.dy);
        }
      }
      _line(
        flow,
        strand % 3 == 0 ? const Color(0x668EECED) : const Color(0x2252D6DF),
        _size.width * (.004 + strand % 3 * .0015),
      );
    }
    // Suspended bubbles and lighter submerged eddies make the wall a volume.
    for (var i = 0; i < 39; i++) {
      final t = .16 + ((i * 31) % 43) / 43 * .82;
      final y = .302 + t * .486;
      final rise = (((i * .173 + _time * .025) % 1) * .77 + .1);
      final x =
          .5 + sign * (_pathHalfWidth(y) * _opening + .012 * math.sin(i * 4.7));
      final center = _p(x, y - _wallHeight(t, right) * rise);
      final radius = _size.width * (.0016 + t * .004) * _opening;
      _canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = const Color(0x779BEFF0)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .7,
      );
    }
    _canvas.restore();
    // Light passes through the rolling lip. Its changing depth is separate
    // from the water/sand contact boundary, which never moves into a drop.
    final lip = Path()..moveTo(crest.first.dx, crest.first.dy);
    for (final p in crest.skip(1)) {
      lip.lineTo(p.dx, p.dy);
    }
    for (var i = crest.length - 1; i >= 0; i--) {
      final t = i / (crest.length - 1);
      final p = crest[i].translate(
        -sign * _size.width * (.009 + t * .022) * _opening,
        _size.height * (.001 + t * .006) * _opening,
      );
      lip.lineTo(p.dx, p.dy);
    }
    lip.close();
    _fill(lip, [const Color(0xC69EEFE2), const Color(0xAA58D6DF)]);
    final foam = Path()..moveTo(crest.first.dx, crest.first.dy);
    for (final p in crest.skip(1)) {
      foam.lineTo(p.dx, p.dy);
    }
    _line(foam, const Color(0xC8E6FFF1), _size.width * .016 * _opening);
    _line(foam, const Color(0xEDFFFFDD), _size.width * .005 * _opening);
    final inward = -sign;
    for (var curl = 0; curl < 6; curl++) {
      final t = .14 + curl * .155;
      final index = (t * (crest.length - 1)).round();
      final r = _size.width * (.009 + t * .031) * _opening;
      final p = crest[index].translate(
        0,
        math.sin(_time * 1.25 + curl * 1.7 + (right ? .8 : 0)) * r * .17,
      );
      final breaking = Path()
        ..moveTo(p.dx - inward * r * 1.4, p.dy + r * .58)
        ..cubicTo(
          p.dx - inward * r * 1.6,
          p.dy - r * .85,
          p.dx + inward * r * 1.6,
          p.dy - r * 1.35,
          p.dx + inward * r * 1.15,
          p.dy + r * .12,
        )
        ..cubicTo(
          p.dx + inward * r * .9,
          p.dy + r * .85,
          p.dx - inward * r * .15,
          p.dy + r * .8,
          p.dx + inward * r * .2,
          p.dy + r * .17,
        );
      _line(breaking, const Color(0xA61DA5BD), r * .9);
      _line(breaking, const Color(0xDAB8F5E7), r * .61);
      _line(breaking, const Color(0xEFFBFFDD), r * .23);
      // The trailing little sheets curve down the face, with changing light.
      final spill = Path()
        ..moveTo(p.dx - inward * r * .3, p.dy + r * .32)
        ..quadraticBezierTo(
          p.dx - inward * r * .8,
          p.dy + r * 2.1,
          p.dx - inward * r * 1.15,
          p.dy + r * 3.6,
        );
      _line(spill, const Color(0x608EEADB), r * .13);
      for (var spray = 0; spray < 3; spray++) {
        final flicker = (math.sin(_time * 1.3 + curl + spray) + 1) / 2;
        _canvas.drawCircle(
          p.translate(
            inward * r * (.65 + spray * .43),
            -r * (.8 + spray * .39 + flicker * .25),
          ),
          r * (.055 + flicker * .025),
          Paint()..color = const Color(0xC9EDFFEF),
        );
      }
    }
    final wetEdge = Path()..moveTo(foot.first.dx, foot.first.dy);
    for (final p in foot.skip(1)) {
      wetEdge.lineTo(p.dx, p.dy);
    }
    _line(wetEdge, const Color(0xAA9FEBDF), _size.width * .006 * _opening);
    for (var i = 4; i < crest.length; i += 3) {
      final p = crest[i];
      final r = _size.width * (.002 + i / crest.length * .007) * _opening;
      _canvas.drawOval(
        Rect.fromCenter(
          center: p.translate(sign * r * .2, -r * .2),
          width: r * 3,
          height: r * 1.4,
        ),
        Paint()..color = const Color(0xDDEFFFF4),
      );
    }
  }

  double _wallHeight(double depth, bool right) {
    final roll = math.sin(depth * 8.0 - _time * 1.1 + (right ? .75 : 0));
    return (.016 +
            depth * .59 +
            math.sin(depth * math.pi) * .03 +
            roll * depth * .008) *
        _opening;
  }

  void _rock(Offset position, double radius, Color color) {
    final path = Path()
      ..moveTo(position.dx - radius, position.dy)
      ..quadraticBezierTo(
        position.dx - radius * .55,
        position.dy - radius * .9,
        position.dx + radius * .12,
        position.dy - radius * .78,
      )
      ..quadraticBezierTo(
        position.dx + radius * .68,
        position.dy - radius * .66,
        position.dx + radius,
        position.dy,
      )
      ..quadraticBezierTo(
        position.dx,
        position.dy + radius * .22,
        position.dx - radius,
        position.dy,
      )
      ..close();
    _fill(path, [Color.lerp(color, const Color(0xFFFFDFA2), .3)!, color]);
  }

  void _people() {
    final dragging = draggedTravellerId();
    final people = <_PaintedTraveller>[];
    for (var i = 0; i < run.course.travellers.length; i++) {
      final person = run.course.travellers[i];
      if (person.id == dragging) continue;
      final placement = run.placements[person.id];
      if (placement == null) {
        people.add(
          _PaintedTraveller(
            index: i,
            foot: queuePosition(i, run.course.travellers.length, _size),
            height: travellerHeight(i, run.course.travellers.length, _size),
          ),
        );
      } else {
        final progress = placement.walkProgress;
        final travel = _smooth(progress);
        final targetX = .5 + ((i % 5) - 2) * .011;
        final x = placement.x + (targetX - placement.x) * travel;
        final y = placement.y + (.299 - placement.y) * travel;
        final scale = (.24 + (y - .29).clamp(0, .60) / .60 * .8).clamp(
          .24,
          1.0,
        );
        people.add(
          _PaintedTraveller(
            index: i,
            foot: _p(x, y),
            height:
                travellerHeight(i, run.course.travellers.length, _size) * scale,
            turn: _smooth(progress / .12),
            gait: reducedMotion || progress >= 1
                ? 0
                : math.sin(progress * placement.walkDuration * 9 + i * .7),
            walking: progress > 0 && progress < 1,
            animationSeconds: progress * placement.walkDuration,
            turnDuration: placement.walkDuration * .12,
          ),
        );
      }
    }
    people.sort((a, b) => a.foot.dy.compareTo(b.foot.dy));
    // People farther along the path stand behind the lead figure in depth.
    var mosesDrawn = false;
    final mosesFoot = _p(.265, .765);
    // Moses stands farther away than the waiting adults. Keep his anatomical
    // height comparable to theirs rather than scaling him as a hero portrait.
    final mosesHeight = travellerRadius(_size) * 2 * .92;
    for (final person in people) {
      if (!mosesDrawn && person.foot.dy > mosesFoot.dy) {
        _human(
          mosesFoot,
          mosesHeight,
          _HumanLook.moses,
          raise: _smooth(run.openingProgress),
        );
        mosesDrawn = true;
      }
      _human(
        person.foot,
        person.height,
        _HumanLook.traveller(person.index),
        turn: person.turn,
        gait: person.gait,
        walking: person.walking,
        animationSeconds: person.animationSeconds,
        turnDuration: person.turnDuration,
      );
    }
    if (!mosesDrawn) {
      _human(
        mosesFoot,
        mosesHeight,
        _HumanLook.moses,
        raise: _smooth(run.openingProgress),
      );
    }
    final drag = draggedPosition();
    if (drag != null && dragging != null) {
      final index = run.course.travellers.indexWhere(
        (person) => person.id == dragging,
      );
      if (index >= 0) {
        final valid = run.course.dropZone.contains(
          drag.dx / _size.width,
          drag.dy / _size.height,
        );
        _canvas.drawOval(
          Rect.fromCenter(
            center: drag.translate(0, 3),
            width: crowdRadius(run.course.travellers.length, _size) * 1.6,
            height: crowdRadius(run.course.travellers.length, _size) * .43,
          ),
          Paint()
            ..color =
                (valid ? const Color(0xFF63BB8F) : const Color(0xFFFFDA85))
                    .withValues(alpha: .5),
        );
        _human(
          drag,
          travellerHeight(index, run.course.travellers.length, _size) * 1.1,
          _HumanLook.traveller(index),
          lifted: true,
        );
      }
    }
  }

  static double _travellerHeightScale(int index) => switch (index % 3) {
    0 => 1.05,
    1 => .96,
    _ => .70,
  };

  void _human(
    Offset foot,
    double height,
    _HumanLook look, {
    double raise = 0,
    double turn = 0,
    double gait = 0,
    bool walking = false,
    bool lifted = false,
    double animationSeconds = 0,
    double turnDuration = 0,
  }) {
    if (_renderHuman(
      foot,
      height,
      look,
      turn: turn,
      walking: walking,
      lifted: lifted,
      animationSeconds: animationSeconds,
      turnDuration: turnDuration,
    )) {
      return;
    }
    _canvas.save();
    _canvas.translate(foot.dx, foot.dy);
    _canvas.scale(height / 180);
    final shadow = Rect.fromCenter(
      center: const Offset(2, 1),
      width: 67,
      height: 13,
    );
    _canvas.drawOval(
      shadow,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Color.fromRGBO(93, 53, 24, lifted ? .15 : .35),
            const Color(0x006C4626),
          ],
        ).createShader(shadow),
    );
    final bob = walking ? -gait.abs() * 1.6 : 0.0;
    final width = 1 - math.sin(turn * math.pi) * .26;
    _canvas.scale(width, 1);
    final pelvis = Offset(0, -68 + bob);
    final leftHip = pelvis.translate(-9, 0);
    final rightHip = pelvis.translate(9, 0);
    final leftFoot = Offset(
      -12 + gait * 7,
      -3 - (walking ? math.max(0, gait) * 7 : 0),
    );
    final rightFoot = Offset(
      13 - gait * 7,
      -3 - (walking ? math.max(0, -gait) * 7 : 0),
    );
    final leftKnee = _jointBetween(leftHip, leftFoot, 35, 34, -1);
    final rightKnee = _jointBetween(rightHip, rightFoot, 35, 34, 1);
    _limb(leftHip, leftKnee, leftFoot, look, 14, 11);
    _limb(rightHip, rightKnee, rightFoot, look, 14, 11);
    _sandal(leftFoot, look, facing: turn);
    _sandal(rightFoot, look, facing: turn);

    final leftShoulder = Offset(-21, -125 + bob);
    final rightShoulder = Offset(21, -125 + bob);
    final leftAngle = look.isMoses
        ? 2.20 + (math.pi * 2 - 1.76 - 2.20) * raise
        : 1.78 + gait * .30;
    final rightAngle = look.isMoses
        ? 1.10 + (.12 - 1.10) * raise
        : 1.30 - gait * .30;
    final leftElbow = leftShoulder + _polar(32, leftAngle);
    final rightElbow = rightShoulder + _polar(32, rightAngle);
    final leftHand =
        leftElbow +
        _polar(31, look.isMoses ? -1.18 + -.10 * raise : 1.50 + gait * .18);
    final rightHand =
        rightElbow +
        _polar(
          30,
          look.isMoses ? 1.62 + (-.28 - 1.62) * raise : 1.65 - gait * .18,
        );

    // The far arms are joined to the same shoulder anchors as their sleeves.
    _limb(leftShoulder, leftElbow, leftHand, look, 14, 11);
    _limb(rightShoulder, rightElbow, rightHand, look, 14, 11);
    _robe(look, bob, gait, turn);
    _sleeve(leftShoulder, leftElbow, look, isLeft: true);
    _sleeve(rightShoulder, rightElbow, look, isLeft: false);
    _limbSegment(leftElbow, leftHand, look, 11);
    _limbSegment(rightElbow, rightHand, look, 11);
    if (look.isMoses) _staff(leftHand, raise);
    _hand(
      leftHand,
      look,
      gripping: look.isMoses,
      open: false,
      angle: leftAngle,
    );
    _hand(
      rightHand,
      look,
      gripping: false,
      open: look.isMoses && raise > .05,
      angle: look.isMoses ? -.35 * raise : 1.5,
    );
    _neckAndFace(look, bob, turn, raise);
    _canvas.restore();
  }

  bool _renderHuman(
    Offset foot,
    double height,
    _HumanLook look, {
    required double turn,
    required bool walking,
    required bool lifted,
    required double animationSeconds,
    required double turnDuration,
  }) {
    final assets = graphics;
    if (assets == null) return false;
    late String name;
    var progress = 0.0;
    if (look.isMoses) {
      name =
          run.phase == RedSeaCrossingPhase.ready ||
              (reducedMotion && run.phase == RedSeaCrossingPhase.parting)
          ? 'moses_ready'
          : 'moses_action';
      progress = reducedMotion ? 1 : run.openingProgress;
    } else {
      final prefix = 'traveller_${look.spriteVariant}';
      if (walking && turn < 1 && !reducedMotion) {
        name = '${prefix}_turn';
        progress = turn;
      } else if (walking && !reducedMotion) {
        name = '${prefix}_walk';
        final walk = assets.clip(name);
        if (walk == null) return false;
        progress =
            math.max(0, animationSeconds - turnDuration) / walk.durationSeconds;
      } else {
        name = turn >= 1 ? '${prefix}_back' : '${prefix}_idle';
      }
    }
    final clip = assets.clip(name);
    final anchor = clip?.footAnchor;
    final bodyHeight = clip?.bodyHeight;
    if (clip == null || anchor == null || bodyHeight == null) return false;
    final scale = height / bodyHeight;
    final shadow = Rect.fromCenter(
      center: foot.translate(0, height * .028),
      width: height * (look.isMoses ? .40 : .34),
      height: height * .073,
    );
    _canvas.drawOval(
      shadow,
      Paint()
        ..color = Color.fromRGBO(34, 28, 24, lifted ? .10 : .28)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, height * .012),
    );
    clip.drawFrame(
      _canvas,
      progress,
      Rect.fromLTWH(
        foot.dx - anchor.dx * scale,
        foot.dy - anchor.dy * scale,
        clip.cellWidth * scale,
        clip.cellHeight * scale,
      ),
    );
    return true;
  }

  Offset _polar(double length, double angle) =>
      Offset(math.cos(angle) * length, math.sin(angle) * length);

  Offset _jointBetween(
    Offset root,
    Offset end,
    double upper,
    double lower,
    double bend,
  ) {
    final delta = end - root;
    final distance = delta.distance.clamp(.01, upper + lower - .01);
    final along =
        (upper * upper + distance * distance - lower * lower) / (2 * distance);
    final across = math.sqrt(math.max(0, upper * upper - along * along));
    final unit = delta / delta.distance;
    return root + unit * along + Offset(-unit.dy, unit.dx) * across * bend;
  }

  void _limb(
    Offset root,
    Offset joint,
    Offset end,
    _HumanLook look,
    double upper,
    double lower,
  ) {
    _limbSegment(root, joint, look, upper);
    _limbSegment(joint, end, look, lower);
    _canvas.drawCircle(joint, lower * .37, Paint()..color = look.skin);
    _line(
      Path()
        ..moveTo(joint.dx - lower * .14, joint.dy + lower * .17)
        ..quadraticBezierTo(
          joint.dx,
          joint.dy + lower * .24,
          joint.dx + lower * .15,
          joint.dy + lower * .14,
        ),
      look.skinShade.withValues(alpha: .6),
      .7,
    );
  }

  void _limbSegment(Offset start, Offset end, _HumanLook look, double width) {
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..lineTo(end.dx, end.dy);
    _line(path, look.outline, width + 2.3);
    _line(path, look.skinShade, width);
    final direction = end - start;
    final normal =
        Offset(-direction.dy, direction.dx) / math.max(1, direction.distance);
    _line(
      Path()
        ..moveTo((start + normal * 1.4).dx, (start + normal * 1.4).dy)
        ..lineTo((end + normal * 1.4).dx, (end + normal * 1.4).dy),
      look.skin,
      width * .74,
    );
    _line(
      Path()
        ..moveTo((start + normal * 2.3).dx, (start + normal * 2.3).dy)
        ..lineTo((end + normal * 2.3).dx, (end + normal * 2.3).dy),
      look.skinLight,
      width * .21,
    );
  }

  void _sandal(Offset ankle, _HumanLook look, {required double facing}) {
    final sole = Rect.fromCenter(
      center: ankle.translate(1, 2),
      width: 22,
      height: 9,
    );
    _canvas.drawRRect(
      RRect.fromRectAndRadius(sole, const Radius.circular(5)),
      Paint()..color = look.outline,
    );
    _canvas.drawOval(sole.deflate(1.4), Paint()..color = look.skin);
    _line(
      Path()
        ..moveTo(sole.left + 4, sole.top + 2)
        ..quadraticBezierTo(
          sole.center.dx,
          sole.top - 1,
          sole.right - 4,
          sole.top + 2,
        ),
      const Color(0xFF9C6A37),
      3.2,
    );
    _line(
      Path()
        ..moveTo(sole.left + 3, sole.bottom - 1)
        ..lineTo(sole.right - 3, sole.bottom - 1),
      const Color(0xFF573C29),
      1.5,
    );
    if (facing < .6) {
      for (var i = 0; i < 3; i++) {
        _line(
          Path()
            ..moveTo(ankle.dx - 3 + i * 3, ankle.dy + 1)
            ..lineTo(ankle.dx - 3 + i * 3, ankle.dy + 3),
          look.skinShade,
          .65,
        );
      }
    }
  }

  void _robe(_HumanLook look, double bob, double gait, double turn) {
    final hem = look.isMoses ? -18.0 : -34.0;
    final sway = gait * 2.8;
    final robe = Path()
      ..moveTo(-21, -128 + bob)
      ..quadraticBezierTo(-6, -137 + bob, 0, -132 + bob)
      ..quadraticBezierTo(11, -137 + bob, 22, -126 + bob)
      ..quadraticBezierTo(18, -93 + bob, 20, -71 + bob)
      ..quadraticBezierTo(25 + sway, -44, 29 + sway, hem)
      ..quadraticBezierTo(14 + sway, hem + 8, 0, hem + 7)
      ..quadraticBezierTo(-17 + sway, hem + 8, -29 + sway, hem)
      ..quadraticBezierTo(-23 + sway, -49, -19, -77 + bob)
      ..quadraticBezierTo(-22, -109 + bob, -21, -128 + bob)
      ..close();
    _fill(robe, [look.clothLight, look.cloth, look.clothShade]);
    _line(robe, look.outline, 2.2);
    final neckline = Path()
      ..moveTo(-8, -131 + bob)
      ..lineTo(-3, -116 + bob)
      ..lineTo(6, -132 + bob);
    _line(neckline, look.clothShade, 2.5);
    for (var i = 0; i < 4; i++) {
      final x = -16 + i * 10.5;
      _line(
        Path()
          ..moveTo(x * .55, -73 + bob)
          ..quadraticBezierTo(x + sway * .4, -48, x * 1.2 + sway, hem + 1),
        look.clothShade.withValues(alpha: .48),
        1.35,
      );
    }
    _line(
      Path()
        ..moveTo(-20, -104 + bob)
        ..quadraticBezierTo(-5, -109 + bob, 9, -90 + bob),
      look.clothLight.withValues(alpha: .65),
      2,
    );
    final belt = Path()
      ..moveTo(-20, -79 + bob)
      ..quadraticBezierTo(0, -74 + bob, 20, -80 + bob)
      ..lineTo(21, -69 + bob)
      ..quadraticBezierTo(0, -63 + bob, -20, -69 + bob)
      ..close();
    _fill(belt, [
      look.belt,
      Color.lerp(look.belt, const Color(0xFF312C37), .3)!,
    ]);
    _line(belt, look.outline, 1.4);
    _line(
      Path()
        ..moveTo(-18, -76 + bob)
        ..quadraticBezierTo(0, -72 + bob, 18, -77 + bob),
      Color.lerp(look.belt, Colors.white, .28)!,
      1.3,
    );
    if (look.isMoses || look.shawl) {
      final left = Path()
        ..moveTo(-20, -131 + bob)
        ..quadraticBezierTo(-29, -126 + bob, -26, -108 + bob)
        ..quadraticBezierTo(-29, -76, -35 + sway, -30)
        ..lineTo(-22 + sway, -17)
        ..quadraticBezierTo(-16, -60, -12, -89 + bob)
        ..quadraticBezierTo(-12, -116 + bob, -13, -133 + bob)
        ..close();
      final right = Path()
        ..moveTo(13, -133 + bob)
        ..quadraticBezierTo(29, -128 + bob, 25, -108 + bob)
        ..quadraticBezierTo(23, -81, 36 + sway, -31)
        ..lineTo(22 + sway, -15)
        ..quadraticBezierTo(12, -71, 13, -89 + bob)
        ..close();
      for (final cloak in [left, right]) {
        _fill(cloak, [look.cloakLight, look.cloak, look.cloakShade]);
        _line(cloak, look.outline, 2.1);
      }
      _line(
        Path()
          ..moveTo(-15, -128 + bob)
          ..quadraticBezierTo(-16, -86, -25 + sway, -24),
        look.cloakLight,
        2.0,
      );
      _line(
        Path()
          ..moveTo(17, -124 + bob)
          ..quadraticBezierTo(16, -77, 26 + sway, -25),
        look.cloakShade,
        1.6,
      );
    }
    if (turn > .45) {
      _line(
        Path()
          ..moveTo(0, -127 + bob)
          ..quadraticBezierTo(-2, -97, 0, -81 + bob),
        look.clothShade.withValues(alpha: turn * .5),
        1.6,
      );
    }
  }

  void _sleeve(
    Offset shoulder,
    Offset elbow,
    _HumanLook look, {
    required bool isLeft,
  }) {
    final delta = elbow - shoulder;
    final unit = delta / delta.distance;
    final normal = Offset(-unit.dy, unit.dx);
    final end = shoulder + unit * 22;
    final sleeve = Path()
      ..moveTo((shoulder + normal * 11).dx, (shoulder + normal * 11).dy)
      ..quadraticBezierTo(
        (shoulder + unit * 12 + normal * 12).dx,
        (shoulder + unit * 12 + normal * 12).dy,
        (end + normal * 10).dx,
        (end + normal * 10).dy,
      )
      ..quadraticBezierTo(
        (end + unit * 3).dx,
        (end + unit * 3).dy,
        (end - normal * 10).dx,
        (end - normal * 10).dy,
      )
      ..lineTo((shoulder - normal * 10).dx, (shoulder - normal * 10).dy)
      ..close();
    final orange = look.isMoses && !isLeft;
    _fill(
      sleeve,
      orange
          ? [look.cloakLight, look.cloak, look.cloakShade]
          : [look.clothLight, look.cloth, look.clothShade],
    );
    _line(sleeve, look.outline, 1.8);
    _line(
      Path()
        ..moveTo((end + normal * 9).dx, (end + normal * 9).dy)
        ..quadraticBezierTo(
          (end + unit * 2).dx,
          (end + unit * 2).dy,
          (end - normal * 9).dx,
          (end - normal * 9).dy,
        ),
      orange ? look.cloakShade : look.clothShade,
      1.3,
    );
  }

  void _staff(Offset hand, double raise) {
    final direction = Offset(.055 + raise * .14, -1);
    final top = hand + direction * 96;
    final bottom = hand - direction * 103;
    final staff = Path()
      ..moveTo(bottom.dx, bottom.dy)
      ..quadraticBezierTo(hand.dx - 1, hand.dy - 20, top.dx, top.dy)
      ..quadraticBezierTo(top.dx + 4, top.dy - 10, top.dx + 8, top.dy - 7);
    _line(staff, const Color(0xFF4F2E20), 10);
    _line(staff, const Color(0xFF9F602B), 6.5);
    _line(
      Path()
        ..moveTo(bottom.dx - 1.5, bottom.dy - 2)
        ..quadraticBezierTo(hand.dx - 1.5, hand.dy - 24, top.dx - 1.5, top.dy),
      const Color(0xFFD59345),
      1.8,
    );
    for (var i = -2; i <= 2; i++) {
      final point = hand + direction * (i * 31.0);
      _line(
        Path()
          ..moveTo(point.dx - 2, point.dy)
          ..quadraticBezierTo(
            point.dx,
            point.dy + 1.5,
            point.dx + 2.5,
            point.dy - .5,
          ),
        const Color(0xFF704323),
        1.2,
      );
    }
  }

  void _hand(
    Offset wrist,
    _HumanLook look, {
    required bool gripping,
    required bool open,
    required double angle,
  }) {
    _canvas.save();
    _canvas.translate(wrist.dx, wrist.dy);
    _canvas.rotate(gripping ? -.12 : angle);
    final palm = Path()
      ..moveTo(-5, -4)
      ..quadraticBezierTo(-8, -2, -6, 5)
      ..quadraticBezierTo(-2, 10, 4, 7)
      ..quadraticBezierTo(8, 4, 5, -4)
      ..close();
    _fill(palm, [look.skinLight, look.skin, look.skinShade]);
    _line(palm, look.outline, 1.3);
    if (gripping) {
      for (var i = 0; i < 4; i++) {
        final y = -4 + i * 3.3;
        _line(
          Path()
            ..moveTo(-5, y)
            ..quadraticBezierTo(0, y - 2.8, 5, y),
          look.outline,
          3.0,
        );
        _line(
          Path()
            ..moveTo(-5, y)
            ..quadraticBezierTo(0, y - 2.8, 5, y),
          look.skinLight,
          1.7,
        );
      }
      _line(
        Path()
          ..moveTo(5, -1)
          ..quadraticBezierTo(9, -4, 7, -8),
        look.outline,
        4.3,
      );
      _line(
        Path()
          ..moveTo(5, -1)
          ..quadraticBezierTo(9, -4, 7, -8),
        look.skin,
        2.7,
      );
    } else if (open) {
      for (var i = 0; i < 4; i++) {
        final x = -4.2 + i * 2.8;
        _line(
          Path()
            ..moveTo(x, -3)
            ..quadraticBezierTo(
              x + 1.5,
              -10,
              x + 1.2 + i * .7,
              -14 + (i - 1.5).abs() * 2,
            ),
          look.outline,
          3.4,
        );
        _line(
          Path()
            ..moveTo(x, -3)
            ..quadraticBezierTo(
              x + 1.5,
              -10,
              x + 1.2 + i * .7,
              -14 + (i - 1.5).abs() * 2,
            ),
          look.skinLight,
          1.9,
        );
      }
      _line(
        Path()
          ..moveTo(-5, 0)
          ..quadraticBezierTo(-10, -1, -11, -5),
        look.outline,
        4,
      );
      _line(
        Path()
          ..moveTo(-5, 0)
          ..quadraticBezierTo(-10, -1, -11, -5),
        look.skin,
        2.5,
      );
    } else {
      _line(
        Path()
          ..moveTo(-3, 2)
          ..quadraticBezierTo(0, 5, 3, 3),
        look.skinShade,
        .8,
      );
      _line(
        Path()
          ..moveTo(-5, -1)
          ..quadraticBezierTo(-2, -2, -1, 1),
        look.skinShade,
        .9,
      );
    }
    _canvas.restore();
  }

  void _neckAndFace(_HumanLook look, double bob, double turn, double raise) {
    _canvas.save();
    _canvas.translate(0, bob);
    _limbSegment(const Offset(0, -128), const Offset(0, -142), look, 16);
    final front = (1 - turn).clamp(0.0, 1.0);
    final headShift =
        math.sin(turn * math.pi) * 4 + (look.isMoses ? raise * 1.6 : 0);
    _canvas.translate(headShift, 0);
    _canvas.rotate(look.isMoses ? -.04 * raise : .015);
    // Hair behind the face has its own curls and warm side light.
    if (look.isMoses || look.curls) {
      for (var i = 0; i < 11; i++) {
        final angle = math.pi * .13 + i / 10 * math.pi * 1.75;
        final p = Offset(math.cos(angle) * 19, -157 + math.sin(angle) * 20);
        _canvas.drawCircle(
          p,
          look.isMoses ? 7.3 : 6.5,
          Paint()..color = look.outline,
        );
        _canvas.drawCircle(
          p.translate(-.6, -.8),
          look.isMoses ? 5.9 : 5.3,
          Paint()..color = i % 3 == 0 ? look.hairLight : look.hair,
        );
        _line(
          Path()
            ..moveTo(p.dx - 2.3, p.dy - 2)
            ..quadraticBezierTo(p.dx + 1, p.dy - 4, p.dx + 3, p.dy - 1),
          look.hairLight.withValues(alpha: .7),
          .8,
        );
      }
    }
    for (final side in [-1.0, 1.0]) {
      final ear = Rect.fromCenter(
        center: Offset(side * 19, -154),
        width: 10,
        height: 15,
      );
      _canvas.drawOval(ear, Paint()..color = look.outline);
      _canvas.drawOval(ear.deflate(1.3), Paint()..color = look.skin);
      _line(
        Path()
          ..moveTo(side * 20, -157)
          ..quadraticBezierTo(side * 23, -154, side * 20, -150),
        look.skinShade,
        1.2,
      );
    }
    final face = Path()
      ..moveTo(-16, -170)
      ..cubicTo(-22, -164, -20, -148, -15, -141)
      ..quadraticBezierTo(-6, -132, 4, -136)
      ..quadraticBezierTo(21, -138, 20, -158)
      ..quadraticBezierTo(20, -176, 2, -176)
      ..quadraticBezierTo(-8, -178, -16, -170)
      ..close();
    _fill(face, [look.skinLight, look.skin, look.skinShade]);
    _line(face, look.outline, 1.7);
    if (front > .01) {
      final hairline = Path()
        ..moveTo(-18, -162)
        ..quadraticBezierTo(-17, -174, -7, -173)
        ..quadraticBezierTo(0, -181, 8, -172)
        ..quadraticBezierTo(18, -175, 19, -162)
        ..lineTo(16, -164)
        ..quadraticBezierTo(10, -167, 8, -169)
        ..quadraticBezierTo(1, -165, -3, -169)
        ..quadraticBezierTo(-12, -167, -15, -159)
        ..close();
      _fill(hairline, [look.hairLight, look.hair]);
      _line(hairline, look.outline, 1.2);
      for (final x in [-7.5, 8.0]) {
        final eye = Rect.fromCenter(
          center: Offset(x, -156.6),
          width: 10,
          height: 13,
        );
        _canvas.drawOval(
          eye,
          Paint()..color = look.outline.withValues(alpha: front),
        );
        _canvas.drawOval(
          eye.deflate(1),
          Paint()..color = const Color(0xFFFFF7DE).withValues(alpha: front),
        );
        final pupil = Offset(
          x + 1 + math.sin(turn * math.pi) * 2.2,
          -156.1 - raise * .9,
        );
        _canvas.drawOval(
          Rect.fromCenter(center: pupil, width: 5, height: 8),
          Paint()..color = const Color(0xFF342719).withValues(alpha: front),
        );
        _canvas.drawCircle(
          pupil.translate(1, -2),
          1.05,
          Paint()..color = Colors.white.withValues(alpha: front),
        );
        _line(
          Path()
            ..moveTo(x - 4.8, -166)
            ..quadraticBezierTo(x, -169 + (x > 0 ? -1 : 0), x + 4.7, -166.5),
          look.hair.withValues(alpha: front),
          2.2,
        );
      }
      final nose = Path()
        ..moveTo(2.3, -157)
        ..quadraticBezierTo(1.8, -151, 5.7, -149.3)
        ..quadraticBezierTo(2.2, -146.5, -.3, -148.3);
      _line(nose, look.skinShade.withValues(alpha: front), 1.3);
      _canvas.drawOval(
        Rect.fromCenter(
          center: const Offset(3.8, -149),
          width: 4.5,
          height: 2.2,
        ),
        Paint()..color = look.skinLight.withValues(alpha: front),
      );
      final smile = Path()
        ..moveTo(-6.5, -143.6)
        ..quadraticBezierTo(1, -139.2, 9, -144.4)
        ..quadraticBezierTo(2, -134.1, -5.4, -140.1)
        ..close();
      _canvas.drawPath(
        smile,
        Paint()..color = look.outline.withValues(alpha: front),
      );
      _canvas.drawPath(
        Path()
          ..moveTo(-5, -143)
          ..quadraticBezierTo(1, -140.6, 7.5, -143.6)
          ..quadraticBezierTo(1, -138.8, -4, -141.3)
          ..close(),
        Paint()..color = const Color(0xFFFFEFC8).withValues(alpha: front),
      );
      _canvas.drawOval(
        Rect.fromCenter(center: const Offset(1.8, -137.8), width: 6, height: 2),
        Paint()..color = const Color(0xFFBB6959).withValues(alpha: front),
      );
      if (look.isMoses) _beard(look, front);
    }
    if (turn > .04) {
      // Continuous turning: the back-of-head coverage grows over the face,
      // while eyes fade and the visible cheek turns into a side profile.
      final cover = _smooth((turn - .12) / .88);
      final rearHair = Path()
        ..moveTo(-18, -164)
        ..quadraticBezierTo(-15, -179, 0, -177)
        ..quadraticBezierTo(21, -179, 20, -158)
        ..quadraticBezierTo(18, -144 + cover * 5, 4, -143 + cover * 6)
        ..quadraticBezierTo(-13, -144 + cover * 6, -18, -164)
        ..close();
      _canvas.drawPath(
        rearHair,
        Paint()..color = look.hair.withValues(alpha: cover),
      );
      _line(
        Path()
          ..moveTo(-10, -169)
          ..quadraticBezierTo(-4, -175, 3, -170),
        look.hairLight.withValues(alpha: cover * .65),
        2.5,
      );
    }
    if (look.headWrap && !look.isMoses) {
      final band = Path()
        ..moveTo(-21, -166)
        ..quadraticBezierTo(-5, -183, 20, -168)
        ..lineTo(19, -163)
        ..quadraticBezierTo(-2, -176, -21, -161)
        ..close();
      _fill(band, [look.cloakLight, look.cloak]);
      _line(band, look.outline, 1.4);
    }
    _canvas.restore();
  }

  void _beard(_HumanLook look, double opacity) {
    final beard = Path()
      ..moveTo(-17, -152)
      ..quadraticBezierTo(-21, -141, -17, -129)
      ..quadraticBezierTo(-12, -116, -3, -122)
      ..quadraticBezierTo(6, -116, 14, -130)
      ..quadraticBezierTo(20, -139, 16, -151)
      ..lineTo(11, -147)
      ..quadraticBezierTo(13, -139, 7, -135)
      ..quadraticBezierTo(0, -131, -7, -136)
      ..quadraticBezierTo(-11, -140, -11, -149)
      ..close();
    _fill(beard, [
      look.hairLight.withValues(alpha: opacity),
      look.hair.withValues(alpha: opacity),
    ]);
    _line(beard, look.outline.withValues(alpha: opacity), 1.6);
    for (var i = 0; i < 8; i++) {
      final p = Offset(-14 + i % 4 * 8, -133 + i ~/ 4 * 8.0);
      _line(
        Path()
          ..moveTo(p.dx - 3, p.dy)
          ..quadraticBezierTo(p.dx, p.dy + 5, p.dx + 3, p.dy + 1),
        look.hairLight.withValues(alpha: opacity * .75),
        1.3,
      );
    }
    final moustache = Path()
      ..moveTo(-1, -147)
      ..quadraticBezierTo(-7, -150, -11, -144)
      ..quadraticBezierTo(-4, -142, 1, -144)
      ..quadraticBezierTo(7, -141, 12, -145)
      ..quadraticBezierTo(6, -150, 2, -147)
      ..close();
    _canvas.drawPath(
      moustache,
      Paint()..color = look.hairLight.withValues(alpha: opacity),
    );
    _line(moustache, look.outline.withValues(alpha: opacity), .9);
  }

  void _sunlight() {
    final glow = Rect.fromCenter(
      center: _p(.55, .30),
      width: _size.width * .5,
      height: _size.height * .14,
    );
    _canvas.drawOval(
      glow,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0x35FFF5B4), Color(0x00FFF5B4)],
        ).createShader(glow),
    );
  }

  @override
  bool shouldRepaint(covariant RedSeaCrossingPainter oldDelegate) => true;
}

class _PaintedTraveller {
  const _PaintedTraveller({
    required this.index,
    required this.foot,
    required this.height,
    this.turn = 0,
    this.gait = 0,
    this.walking = false,
    this.animationSeconds = 0,
    this.turnDuration = 0,
  });
  final int index;
  final Offset foot;
  final double height;
  final double turn;
  final double gait;
  final bool walking;
  final double animationSeconds;
  final double turnDuration;
}

class _HumanLook {
  const _HumanLook({
    required this.skin,
    required this.cloth,
    required this.cloak,
    required this.belt,
    this.hair = const Color(0xFF342824),
    this.hairLight = const Color(0xFF5B4331),
    this.isMoses = false,
    this.curls = true,
    this.shawl = false,
    this.headWrap = false,
    this.spriteVariant = 0,
  });
  final Color skin;
  final Color cloth;
  final Color cloak;
  final Color belt;
  final Color hair;
  final Color hairLight;
  final bool isMoses;
  final bool curls;
  final bool shawl;
  final bool headWrap;
  final int spriteVariant;
  Color get skinLight => Color.lerp(skin, const Color(0xFFE6A15B), .29)!;
  Color get skinShade => Color.lerp(skin, const Color(0xFF48271F), .4)!;
  Color get outline => const Color(0xFF513527);
  Color get clothLight => Color.lerp(cloth, const Color(0xFFFFEDB3), .35)!;
  Color get clothShade => Color.lerp(cloth, const Color(0xFF775637), .29)!;
  Color get cloakLight => Color.lerp(cloak, const Color(0xFFFFD481), .27)!;
  Color get cloakShade => Color.lerp(cloak, const Color(0xFF6B3728), .29)!;

  static const moses = _HumanLook(
    skin: Color(0xFF955027),
    cloth: Color(0xFFFFDCA0),
    cloak: Color(0xFFDD632E),
    belt: Color(0xFF316483),
    hair: Color(0xFF7F7567),
    hairLight: Color(0xFFB3A18A),
    isMoses: true,
    shawl: true,
  );

  static _HumanLook traveller(int index) {
    const skins = [
      Color(0xFF8A4828),
      Color(0xFF6F3926),
      Color(0xFF9B532B),
      Color(0xFF7D442D),
      Color(0xFFA55C31),
    ];
    const clothes = [
      Color(0xFF278F91),
      Color(0xFFF2B833),
      Color(0xFFEEE0B1),
      Color(0xFFDA7840),
      Color(0xFF4E9D9D),
      Color(0xFF9173B4),
      Color(0xFFDAAA51),
    ];
    const cloaks = [
      Color(0xFFE7B84A),
      Color(0xFFC26941),
      Color(0xFF38728B),
      Color(0xFFDB7838),
      Color(0xFFEAB249),
    ];
    return _HumanLook(
      skin: skins[index % skins.length],
      cloth: clothes[index % clothes.length],
      cloak: cloaks[index % cloaks.length],
      belt: index.isEven ? const Color(0xFFBD6438) : const Color(0xFF3D6F88),
      shawl: index % 4 == 0,
      headWrap: index % 4 == 1,
      curls: index % 3 != 1,
      spriteVariant: index % 3,
    );
  }
}

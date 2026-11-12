import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/mini_game.dart';

class SeaJourneyCell {
  const SeaJourneyCell(this.row, this.column);
  final int row;
  final int column;
  @override
  bool operator ==(Object other) =>
      other is SeaJourneyCell && other.row == row && other.column == column;
  @override
  int get hashCode => Object.hash(row, column);
  List<int> get coordinates => [row, column];
}

/// Collects only the route the player actually traces. Walls and adjacency
/// remain identical to the server-authored maze; no solution is auto-filled.
class SeaJourneyRoute {
  SeaJourneyRoute({
    required this.rows,
    required this.columns,
    required this.start,
    required this.end,
    required this.walls,
  }) : _path = [start];

  factory SeaJourneyRoute.fromLevel(GameLevel level) {
    final grid = _map(level.config['grid'] ?? level.config);
    final rows = _integer(grid['rows'], 5).clamp(2, 10);
    final columns = _integer(grid['columns'], 5).clamp(2, 10);
    return SeaJourneyRoute(
      rows: rows,
      columns: columns,
      start: _cell(grid['start'], const SeaJourneyCell(0, 0)),
      end: _cell(grid['end'], SeaJourneyCell(rows - 1, columns - 1)),
      walls: {
        for (final value in grid['walls'] as List? ?? const [])
          _cell(value, const SeaJourneyCell(-1, -1)),
      },
    );
  }

  final int rows;
  final int columns;
  final SeaJourneyCell start;
  final SeaJourneyCell end;
  final Set<SeaJourneyCell> walls;
  final List<SeaJourneyCell> _path;
  List<SeaJourneyCell> get path => List.unmodifiable(_path);
  SeaJourneyCell get current => _path.last;
  bool get atShore => current == end;

  bool isOpen(SeaJourneyCell cell) =>
      cell.row >= 0 &&
      cell.row < rows &&
      cell.column >= 0 &&
      cell.column < columns &&
      !walls.contains(cell);

  bool advance(SeaJourneyCell cell) {
    if (!isOpen(cell) ||
        (cell.row - current.row).abs() + (cell.column - current.column).abs() !=
            1) {
      return false;
    }
    final previous = _path.indexOf(cell);
    if (previous >= 0) {
      _path.removeRange(previous + 1, _path.length);
    } else {
      if (_path.length >= rows * columns * 4) return false;
      _path.add(cell);
    }
    return true;
  }

  void reset() => _path
    ..clear()
    ..add(start);
}

class SeaJourneyEngine extends StatefulWidget {
  const SeaJourneyEngine({
    required this.level,
    required this.onComplete,
    required this.isSeaPath,
    super.key,
  });
  final GameLevel level;
  final void Function(Map<String, dynamic>) onComplete;
  final bool isSeaPath;

  @override
  State<SeaJourneyEngine> createState() => _SeaJourneyEngineState();
}

class _SeaJourneyEngineState extends State<SeaJourneyEngine>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late SeaJourneyRoute _route;
  late final AnimationController _arrival;
  final FocusNode _focus = FocusNode(debugLabel: 'Sea journey');
  Offset? _lastPointer;
  bool _tracing = false;
  bool _arriving = false;
  bool _finished = false;
  bool _active = true;
  String? _hint;

  bool get _fishGoal => !widget.isSeaPath && widget.level.number == 3;

  @override
  void initState() {
    super.initState();
    _route = SeaJourneyRoute.fromLevel(widget.level);
    WidgetsBinding.instance.addObserver(this);
    _arrival = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..addStatusListener(_arrived);
  }

  @override
  void didUpdateWidget(covariant SeaJourneyEngine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.level.id != widget.level.id) {
      _arrival.stop();
      _route = SeaJourneyRoute.fromLevel(widget.level);
      _tracing = _arriving = _finished = false;
      _hint = null;
      _lastPointer = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (!_active) {
      _arrival.stop(canceled: false);
      _tracing = false;
      _lastPointer = null;
    } else if (_arriving && !_finished) {
      _arrival.forward();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _arrival.removeStatusListener(_arrived);
    _arrival.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _canPlay => _active && !_arriving && !_finished;

  void _arrived(AnimationStatus status) {
    if (status != AnimationStatus.completed ||
        !_active ||
        !_arriving ||
        _finished) {
      return;
    }
    _finished = true;
    widget.onComplete({
      'path': [for (final cell in _route.path) cell.coordinates],
    });
  }

  void _arrive() {
    if (!_canPlay || !_route.atShore) return;
    setState(() {
      _arriving = true;
      _hint = widget.isSeaPath
          ? 'Everyone is safely across!'
          : _fishGoal
          ? 'The big fish is here to help!'
          : 'You found safe waters!';
    });
    HapticFeedback.mediumImpact();
    _arrival.forward(from: 0);
  }

  SeaJourneyCell _at(Offset position, Size size) {
    final usable = Size(size.width - 24, size.height - 24);
    return SeaJourneyCell(
      ((position.dy - 12) / usable.height * _route.rows).floor(),
      ((position.dx - 12) / usable.width * _route.columns).floor(),
    );
  }

  void _begin(Offset pointer, Size size) {
    if (!_canPlay) return;
    _focus.requestFocus();
    final cell = _at(pointer, size);
    setState(() {
      _tracing = cell == _route.current;
      _lastPointer = _tracing ? pointer : null;
      _hint = _tracing
          ? null
          : widget.isSeaPath
          ? 'Start at the little family.'
          : 'Start at your boat.';
    });
  }

  void _trace(Offset pointer, Size size) {
    if (!_tracing || !_canPlay || _lastPointer == null) return;
    final previous = _lastPointer!;
    // Sample the actual finger segment at less than a quarter cell spacing.
    // Every crossed cell must still pass adjacency and wall validation.
    final step =
        math.min(
          (size.width - 24) / _route.columns,
          (size.height - 24) / _route.rows,
        ) *
        .2;
    final samples = math.max(1, ((pointer - previous).distance / step).ceil());
    setState(() {
      for (var i = 1; i <= samples; i++) {
        final point = Offset.lerp(previous, pointer, i / samples)!;
        final cell = _at(point, size);
        if (cell == _route.current) continue;
        if (!_route.advance(cell)) {
          _hint = _route.walls.contains(cell)
              ? widget.isSeaPath
                    ? 'Deep water! Draw around the wave.'
                    : 'A reef! Sail around it.'
              : 'Follow the route from where you stopped.';
          break;
        }
        _hint = null;
      }
      _lastPointer = pointer;
    });
  }

  void _end() {
    if (!_tracing) return;
    _tracing = false;
    _lastPointer = null;
    _arrive();
  }

  void _move(int row, int column) {
    if (!_canPlay) return;
    setState(() {
      if (!_route.advance(
        SeaJourneyCell(
          _route.current.row + row,
          _route.current.column + column,
        ),
      )) {
        _hint = widget.isSeaPath
            ? 'Deep water blocks that route.'
            : 'A reef blocks that route.';
      } else {
        _hint = null;
      }
    });
    _arrive();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !_canPlay) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1, 0);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _move(1, 0);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _move(0, -1);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _move(0, 1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _tapCell(SeaJourneyCell cell) {
    if (!_canPlay) return;
    if (cell == _route.current && _route.atShore) {
      _arrive();
      return;
    }
    setState(() {
      if (!_route.advance(cell)) {
        _hint =
            'Choose an open space next to your ${widget.isSeaPath ? 'family' : 'boat'}.';
      } else {
        _hint = null;
      }
    });
    _arrive();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              widget.level.title,
              key: const Key('sea-level-title'),
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: Color(0xFF1D4B61),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFE1F5F4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '${_route.path.length - 1} turns',
              key: const Key('sea-turn-count'),
              style: const TextStyle(
                color: Color(0xFF28616D),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        widget.isSeaPath
            ? 'Draw a dry road through the sea.'
            : _fishGoal
            ? 'Guide your boat to the friendly big fish.'
            : 'Sail your boat around the reefs to the shore.',
        style: const TextStyle(
          color: Color(0xFF608493),
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 14),
      LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(
            constraints.maxWidth,
            (constraints.maxWidth - 24) * _route.rows / _route.columns + 24,
          );
          return Focus(
            focusNode: _focus,
            onKeyEvent: _key,
            child: Listener(
              onPointerCancel: (_) {
                _tracing = false;
                _lastPointer = null;
              },
              child: GestureDetector(
                key: const Key('sea-route-board'),
                behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                onPanStart: (event) => _begin(event.localPosition, size),
                onPanUpdate: (event) => _trace(event.localPosition, size),
                onPanEnd: (_) => _end(),
                onPanCancel: () {
                  _tracing = false;
                  _lastPointer = null;
                },
                onTapUp: (event) => _tapCell(_at(event.localPosition, size)),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(25),
                  child: SizedBox.fromSize(
                    size: size,
                    child: AnimatedBuilder(
                      animation: _arrival,
                      builder: (context, _) => CustomPaint(
                        painter: _SeaMapPainter(
                          route: _route,
                          seaPath: widget.isSeaPath,
                          fishGoal: _fishGoal,
                          celebration: _arriving ? _arrival.value : 0,
                        ),
                        child: Stack(
                          children: [
                            for (var row = 0; row < _route.rows; row++)
                              for (
                                var column = 0;
                                column < _route.columns;
                                column++
                              )
                                Positioned(
                                  left:
                                      12 +
                                      column *
                                          (size.width - 24) /
                                          _route.columns,
                                  top:
                                      12 +
                                      row * (size.height - 24) / _route.rows,
                                  width: (size.width - 24) / _route.columns,
                                  height: (size.height - 24) / _route.rows,
                                  child: Semantics(
                                    key: Key('sea-cell-$row-$column'),
                                    label: _cellLabel(
                                      SeaJourneyCell(row, column),
                                    ),
                                    button: _route.isOpen(
                                      SeaJourneyCell(row, column),
                                    ),
                                    enabled:
                                        _canPlay &&
                                        _route.isOpen(
                                          SeaJourneyCell(row, column),
                                        ),
                                    onTap:
                                        _canPlay &&
                                            _route.isOpen(
                                              SeaJourneyCell(row, column),
                                            )
                                        ? () => _tapCell(
                                            SeaJourneyCell(row, column),
                                          )
                                        : null,
                                    child: const SizedBox.expand(),
                                  ),
                                ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
      const SizedBox(height: 12),
      Semantics(
        liveRegion: true,
        child: Text(
          _hint ??
              (_route.path.length == 1
                  ? widget.isSeaPath
                        ? 'Drag from the family to open your road.'
                        : 'Drag from the boat to set sail.'
                  : 'Keep drawing. You can lift your finger and continue.'),
          key: const Key('sea-live-status'),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: Color(0xFF396977),
          ),
        ),
      ),
      Align(
        alignment: Alignment.center,
        child: TextButton.icon(
          key: const Key('sea-restart'),
          onPressed: _canPlay
              ? () => setState(() {
                  _route.reset();
                  _tracing = false;
                  _lastPointer = null;
                  _hint = null;
                })
              : null,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Try a new route'),
        ),
      ),
    ],
  );

  String _cellLabel(SeaJourneyCell cell) =>
      '${cell == _route.current
          ? widget.isSeaPath
                ? 'Family. '
                : 'Boat. '
          : ''}'
      '${cell == _route.end
          ? _fishGoal
                ? 'Friendly big fish. '
                : 'Safe shore. '
          : ''}'
      '${_route.walls.contains(cell)
          ? widget.isSeaPath
                ? 'Deep water. '
                : 'Reef. '
          : 'Open water. '}'
      'Row ${cell.row + 1}, column ${cell.column + 1}';
}

class _SeaMapPainter extends CustomPainter {
  const _SeaMapPainter({
    required this.route,
    required this.seaPath,
    required this.celebration,
    this.fishGoal = false,
  });
  final SeaJourneyRoute route;
  final bool seaPath;
  final double celebration;
  final bool fishGoal;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF7FE1E2), Color(0xFF36B3CF), Color(0xFF198EBD)],
        ).createShader(bounds),
    );
    final cellW = (size.width - 24) / route.columns;
    final cellH = (size.height - 24) / route.rows;
    final unit = math.min(cellW, cellH);
    Offset center(SeaJourneyCell cell) =>
        Offset(12 + (cell.column + .5) * cellW, 12 + (cell.row + .5) * cellH);
    for (var row = 0; row < route.rows; row++) {
      for (var column = 0; column < route.columns; column++) {
        final cell = SeaJourneyCell(row, column);
        final p = center(cell);
        if (route.walls.contains(cell)) {
          seaPath
              ? _waveWall(canvas, p, unit * .44)
              : _reef(canvas, p, unit * .43);
        } else {
          // Water currents give open spaces a readable structure without
          // exposing a checkerboard of buttons or a direction pad.
          final line = Path()
            ..moveTo(p.dx - unit * .2, p.dy + unit * .22)
            ..quadraticBezierTo(
              p.dx,
              p.dy + unit * .12,
              p.dx + unit * .2,
              p.dy + unit * .22,
            );
          canvas.drawPath(
            line,
            Paint()
              ..color = Colors.white.withValues(alpha: .3)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..strokeCap = StrokeCap.round,
          );
          canvas.drawCircle(
            p,
            2,
            Paint()..color = Colors.white.withValues(alpha: .22),
          );
        }
      }
    }
    final trail = Path()
      ..moveTo(center(route.start).dx, center(route.start).dy);
    for (final cell in route.path.skip(1)) {
      trail.lineTo(center(cell).dx, center(cell).dy);
    }
    canvas.drawPath(
      trail,
      Paint()
        ..color = const Color(0xFF166C91).withValues(alpha: .25)
        ..strokeWidth = unit * .66
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      trail,
      Paint()
        ..color = seaPath ? const Color(0xFFF4DDA3) : const Color(0xFFA5F0E9)
        ..strokeWidth = unit * .56
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      trail,
      Paint()
        ..color = seaPath
            ? const Color(0xFFFFECC8)
            : Colors.white.withValues(alpha: .65)
        ..strokeWidth = unit * .11
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    if (fishGoal) {
      _bigFish(canvas, center(route.end), unit * .47);
    } else {
      _island(canvas, center(route.end), unit * .47);
    }
    if (seaPath) {
      for (
        var index = math.max(0, route.path.length - 3);
        index < route.path.length - 1;
        index++
      ) {
        _family(canvas, center(route.path[index]), unit * .25, tiny: true);
      }
      _family(canvas, center(route.current), unit * .36);
    } else {
      _boat(canvas, center(route.current), unit * .41);
    }
    if (celebration > 0) {
      final p = center(route.end);
      for (var index = 0; index < 12; index++) {
        final angle = index / 12 * math.pi * 2;
        final burst =
            Offset(math.cos(angle), math.sin(angle)) *
            unit *
            (.4 + celebration);
        canvas.drawCircle(
          p + burst,
          2.5 * (1 - celebration),
          Paint()
            ..color = [
              const Color(0xFFFFD36E),
              Colors.white,
              const Color(0xFFDDFFF0),
            ][index % 3],
        );
      }
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(bounds.deflate(1.5), const Radius.circular(24)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = const Color(0xFFD7FFFF).withValues(alpha: .58),
    );
  }

  void _waveWall(Canvas canvas, Offset p, double r) {
    canvas.drawOval(
      Rect.fromCenter(
        center: p + Offset(0, r * .3),
        width: r * 2,
        height: r * .85,
      ),
      Paint()..color = const Color(0xFF176B9F),
    );
    final wave = Path()
      ..moveTo(p.dx - r, p.dy + r * .4)
      ..quadraticBezierTo(
        p.dx - r * .7,
        p.dy - r * .8,
        p.dx + r * .1,
        p.dy - r * .6,
      )
      ..quadraticBezierTo(
        p.dx + r,
        p.dy - r * .5,
        p.dx + r * .35,
        p.dy + r * .15,
      )
      ..quadraticBezierTo(
        p.dx + r * .18,
        p.dy - r * .17,
        p.dx - r * .05,
        p.dy + r * .18,
      )
      ..quadraticBezierTo(
        p.dx + r * .38,
        p.dy + r * .54,
        p.dx + r,
        p.dy + r * .4,
      )
      ..close();
    canvas.drawPath(wave, Paint()..color = const Color(0xFF2D8DCA));
    canvas.drawPath(
      wave,
      Paint()
        ..color = const Color(0xFFCFEBFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * .08
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void _reef(Canvas canvas, Offset p, double r) {
    canvas.drawOval(
      Rect.fromCenter(
        center: p + Offset(0, r * .3),
        width: r * 2.05,
        height: r * .95,
      ),
      Paint()..color = const Color(0xFF126C8D).withValues(alpha: .42),
    );
    final rock = Path()
      ..moveTo(p.dx - r, p.dy + r * .36)
      ..lineTo(p.dx - r * .55, p.dy - r * .48)
      ..lineTo(p.dx + r * .02, p.dy - r * .62)
      ..lineTo(p.dx + r * .68, p.dy - r * .24)
      ..lineTo(p.dx + r, p.dy + r * .4)
      ..close();
    canvas.drawPath(rock, Paint()..color = const Color(0xFF637E89));
    canvas.drawPath(
      Path()
        ..moveTo(p.dx - r * .55, p.dy - r * .48)
        ..lineTo(p.dx + r * .02, p.dy - r * .62)
        ..lineTo(p.dx + r * .33, p.dy + r * .28)
        ..lineTo(p.dx - r * .7, p.dy + r * .32)
        ..close(),
      Paint()..color = const Color(0xFF8BA7AA),
    );
    canvas.drawArc(
      Rect.fromCenter(
        center: p + Offset(0, r * .36),
        width: r * 2.2,
        height: r * .8,
      ),
      0,
      math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * .09
        ..color = const Color(0xFFC7F3EE),
    );
  }

  void _bigFish(Canvas canvas, Offset p, double r) {
    final body = Rect.fromCenter(
      center: p - Offset(r * .15, 0),
      width: r * 1.75,
      height: r * 1.28,
    );
    canvas.drawOval(
      body.shift(Offset(0, r * .2)),
      Paint()..color = const Color(0xFF176389).withValues(alpha: .22),
    );
    canvas.drawPath(
      Path()
        ..moveTo(p.dx + r * .55, p.dy)
        ..quadraticBezierTo(
          p.dx + r * 1.25,
          p.dy - r * .9,
          p.dx + r * 1.12,
          p.dy + r * .03,
        )
        ..quadraticBezierTo(
          p.dx + r * 1.4,
          p.dy + r * .63,
          p.dx + r * .65,
          p.dy + r * .25,
        )
        ..close(),
      Paint()..color = const Color(0xFF486DC5),
    );
    canvas.drawOval(
      body,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF8AAAF2), Color(0xFF536FC6)],
        ).createShader(body),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: p + Offset(-r * .24, r * .37),
        width: r * 1.26,
        height: r * .38,
      ),
      Paint()..color = const Color(0xFFC6DCFF),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: p + Offset(r * .1, r * .38),
        width: r * .35,
        height: r * .5,
      ),
      Paint()..color = const Color(0xFF3D5EA8),
    );
    canvas.drawCircle(
      p + Offset(-r * .59, -r * .06),
      r * .13,
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      p + Offset(-r * .62, -r * .04),
      r * .065,
      Paint()..color = const Color(0xFF283C72),
    );
    canvas.drawArc(
      Rect.fromCenter(
        center: p + Offset(-r * .62, r * .15),
        width: r * .33,
        height: r * .2,
      ),
      .1,
      math.pi - .2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * .045
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFF344577),
    );
    canvas.drawLine(
      p + Offset(-r * .2, -r * .66),
      p + Offset(-r * .2, -r),
      Paint()
        ..color = const Color(0xFFD4F2FF)
        ..strokeWidth = r * .11
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(
      p + Offset(-r * .37, -r * 1.04),
      r * .12,
      Paint()..color = const Color(0xFFD4F2FF),
    );
    canvas.drawCircle(
      p + Offset(-r * .03, -r * 1.04),
      r * .12,
      Paint()..color = const Color(0xFFD4F2FF),
    );
  }

  void _island(Canvas canvas, Offset p, double r) {
    canvas.drawOval(
      Rect.fromCenter(
        center: p + Offset(0, r * .1),
        width: r * 2.04,
        height: r * 1.15,
      ),
      Paint()..color = const Color(0xFFCDF0C6),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: p + Offset(0, r * .12),
        width: r * 1.84,
        height: r * .98,
      ),
      Paint()..color = const Color(0xFFFFE4A3),
    );
    final trunk = Path()
      ..moveTo(p.dx + r * .24, p.dy + r * .23)
      ..quadraticBezierTo(
        p.dx + r * .42,
        p.dy - r * .15,
        p.dx + r * .23,
        p.dy - r * .57,
      );
    canvas.drawPath(
      trunk,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * .13
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFF976644),
    );
    for (final vector in [
      const Offset(-.5, -.2),
      const Offset(.5, -.2),
      const Offset(-.45, .14),
      const Offset(.46, .18),
      const Offset(0, -.38),
    ]) {
      canvas.drawLine(
        p + Offset(r * .23, -r * .57),
        p + Offset(r * .23, -r * .57) + vector * r,
        Paint()
          ..color = const Color(0xFF2E9B65)
          ..strokeWidth = r * .18
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  void _boat(Canvas canvas, Offset p, double r) {
    canvas.drawOval(
      Rect.fromCenter(
        center: p + Offset(0, r * .6),
        width: r * 2.2,
        height: r * .6,
      ),
      Paint()..color = const Color(0xFF164A70).withValues(alpha: .24),
    );
    final hull = Path()
      ..moveTo(p.dx - r, p.dy + r * .25)
      ..lineTo(p.dx + r, p.dy + r * .25)
      ..quadraticBezierTo(
        p.dx + r * .5,
        p.dy + r * .88,
        p.dx - r * .53,
        p.dy + r * .59,
      )
      ..close();
    canvas.drawPath(hull, Paint()..color = const Color(0xFFC97937));
    canvas.drawLine(
      p + Offset(-r, r * .25),
      p + Offset(r, r * .25),
      Paint()
        ..color = const Color(0xFFFFD079)
        ..strokeWidth = r * .14,
    );
    canvas.drawLine(
      p + Offset(0, r * .22),
      p - Offset(0, r * 1.05),
      Paint()
        ..color = const Color(0xFF79512D)
        ..strokeWidth = r * .1,
    );
    canvas.drawPath(
      Path()
        ..moveTo(p.dx - r * .09, p.dy - r)
        ..lineTo(p.dx - r * .09, p.dy + r * .03)
        ..lineTo(p.dx - r * .87, p.dy + r * .03)
        ..close(),
      Paint()..color = const Color(0xFFFFF5D6),
    );
    canvas.drawPath(
      Path()
        ..moveTo(p.dx + r * .09, p.dy - r * .83)
        ..lineTo(p.dx + r * .09, p.dy + r * .03)
        ..lineTo(p.dx + r * .71, p.dy + r * .03)
        ..close(),
      Paint()..color = const Color(0xFFFFD587),
    );
    // Jonah is intentionally tiny in the boat, with visibly brown skin.
    canvas.drawCircle(
      p + Offset(r * .4, r * .05),
      r * .13,
      Paint()..color = const Color(0xFF855337),
    );
  }

  void _family(Canvas canvas, Offset p, double r, {bool tiny = false}) {
    canvas.drawOval(
      Rect.fromCenter(
        center: p + Offset(0, r * .62),
        width: r * 2.1,
        height: r * .4,
      ),
      Paint()..color = const Color(0xFF8A7148).withValues(alpha: .2),
    );
    for (var i = 0; i < (tiny ? 1 : 3); i++) {
      final x = tiny ? 0.0 : (i - 1) * r * .65;
      final small = i == 1 && !tiny ? .74 : 1.0;
      final head = p + Offset(x, -r * .35 * small);
      canvas.drawPath(
        Path()
          ..moveTo(head.dx - r * .16, head.dy + r * .2)
          ..lineTo(head.dx + r * .16, head.dy + r * .2)
          ..lineTo(head.dx + r * .29, p.dy + r * .5)
          ..lineTo(head.dx - r * .29, p.dy + r * .5)
          ..close(),
        Paint()
          ..color = [
            const Color(0xFF825AB5),
            const Color(0xFFF4A042),
            const Color(0xFFD85B58),
          ][i],
      );
      canvas.drawCircle(
        head,
        r * .23 * small,
        Paint()..color = const Color(0xFF855337),
      );
      canvas.drawArc(
        Rect.fromCircle(center: head, radius: r * .24 * small),
        math.pi,
        math.pi,
        true,
        Paint()..color = const Color(0xFF352A29),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SeaMapPainter oldDelegate) => true;
}

Map<String, dynamic> _map(Object? value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : const {};
int _integer(Object? value, int fallback) =>
    value is num && value.isFinite ? value.toInt() : fallback;
SeaJourneyCell _cell(Object? value, SeaJourneyCell fallback) =>
    value is List && value.length == 2
    ? SeaJourneyCell(
        _integer(value[0], fallback.row),
        _integer(value[1], fallback.column),
      )
    : fallback;

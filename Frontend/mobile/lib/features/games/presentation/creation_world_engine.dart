import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/creation_world_model.dart';
import '../domain/mini_game.dart';
import 'creation_world_graphics.dart';

class CreationWorldEngine extends StatefulWidget {
  const CreationWorldEngine({
    required this.level,
    required this.onComplete,
    this.paused = false,
    this.onExit,
    this.graphicsLoader,
    super.key,
  });
  final GameLevel level;
  final void Function(Map<String, dynamic>) onComplete;
  final bool paused;
  final VoidCallback? onExit;
  final Future<CreationWorldGraphics> Function(int)? graphicsLoader;
  @override
  State<CreationWorldEngine> createState() => _CreationWorldEngineState();
}

class _CreationWorldEngineState extends State<CreationWorldEngine>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late CreationWorldModel _world;
  late final AnimationController _motion;
  final _elapsed = Stopwatch();
  CreationWorldGraphics? _graphics;
  String? _selected;
  String _message = 'Choose a piece, then tap a space. You can move it again.';
  Object? _error;
  bool _night = false, _submitted = false, _paused = false;
  bool _foreground = true;
  bool get _isPaused => widget.paused || _paused || !_foreground;
  bool get _animationsEnabled {
    final media = MediaQuery.maybeOf(context);
    return !(media?.disableAnimations ?? false) &&
        !(media?.accessibleNavigation ?? false);
  }

  void _syncRunState() {
    if (_isPaused || _submitted || _graphics == null) {
      _elapsed.stop();
      _motion.stop();
    } else {
      _elapsed.start();
      if (_animationsEnabled) {
        _motion.repeat();
      } else {
        _motion.stop();
      }
    }
  }

  @override
  void didUpdateWidget(covariant CreationWorldEngine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paused != widget.paused) {
      _syncRunState();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _world = CreationWorldModel.fromConfig(widget.level.config);
    _motion = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    );
    _load();
  }

  Future<void> _load() async {
    try {
      final art = await (widget.graphicsLoader ?? CreationWorldGraphics.load)(
        widget.level.number,
      );
      if (!mounted) {
        art.dispose();
        return;
      }
      setState(() {
        _graphics = art;
        _error = null;
      });
      _syncRunState();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncRunState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncRunState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _elapsed.stop();
    _motion.dispose();
    _graphics?.dispose();
    super.dispose();
  }

  Rect _board(Size size) {
    final width = size.width * .88;
    final height = math.min(size.height * .47, width * .90);
    return Rect.fromLTWH(size.width * .06, size.height * .28, width, height);
  }

  int? _cell(Offset local, Rect board) {
    if (!board.contains(local)) return null;
    final col = ((local.dx - board.left) / (board.width / _world.columns))
        .floor();
    final row = ((local.dy - board.top) / (board.height / _world.rows)).floor();
    return row * _world.columns + col;
  }

  void _place(String id, int cell) {
    if (_isPaused || _submitted) return;
    setState(() {
      if (_world.place(id, cell)) {
        _selected = null;
        _message = _world.piece(id).layer == 'life'
            ? 'Watch what happens when its home is ready.'
            : 'Try different shapes. Water and meadows need connected spaces.';
        HapticFeedback.selectionClick();
      } else {
        _message = _world.piece(id).layer == 'sky'
            ? 'Choose an empty space along the top row for the sky.'
            : 'Move the piece already in this space first.';
      }
    });
  }

  void _tapCell(int cell) {
    if (_isPaused || _submitted) return;
    if (_selected != null) {
      _place(_selected!, cell);
      return;
    }
    final entries = _world.placements.entries
        .where((e) => e.value == cell)
        .toList();
    if (entries.isEmpty) return;
    final life = entries
        .where((e) => _world.piece(e.key).layer == 'life')
        .firstOrNull;
    if (_world.complete && life != null) {
      final kind = _world.piece(life.key).kind;
      setState(
        () => _message = switch (kind) {
          'fish' => 'The fish follows your connected river.',
          'bird' => 'The bird can fly and land in your forest.',
          _ => 'Your $kind walks through the meadow you made.',
        },
      );
      HapticFeedback.lightImpact();
      return;
    }
    final chosen = life ?? entries.first;
    setState(() {
      _selected = chosen.key;
      _message =
          'Choose another space for ${_world.piece(chosen.key).label.toLowerCase()}.';
    });
  }

  void _tapBoard(Offset local, Rect board) {
    if (_isPaused || _submitted) return;
    if (_world.complete && _selected == null) {
      Offset center(int cell) => Offset(
        board.left +
            (cell % _world.columns + .5) * board.width / _world.columns,
        board.top + (cell ~/ _world.columns + .5) * board.height / _world.rows,
      );
      for (final entry in _world.placements.entries) {
        final piece = _world.piece(entry.key);
        if (piece.layer != 'life') continue;
        var position = center(entry.value);
        final path = _world.creaturePath(piece);
        if (path.length > 1) {
          final progress = _motion.value * (path.length - 1);
          final index = progress.floor().clamp(0, path.length - 2);
          position = Offset.lerp(
            center(path[index]),
            center(path[index + 1]),
            progress - index,
          )!;
          if (piece.kind == 'bird') {
            position -= Offset(
              0,
              math.sin((progress - index) * math.pi).abs() *
                  board.height /
                  _world.rows *
                  .65,
            );
          }
        }
        position -= Offset(0, board.height / _world.rows * .14);
        if ((local - position).distance < board.width / _world.columns * .48) {
          setState(
            () => _message = switch (piece.kind) {
              'fish' => 'The fish follows your connected river.',
              'bird' => 'The bird can fly and land in your forest.',
              _ => 'Your ${piece.kind} walks through the meadow you made.',
            },
          );
          HapticFeedback.lightImpact();
          return;
        }
      }
    }
    final cell = _cell(local, board);
    if (cell != null) {
      _tapCell(cell);
    }
  }

  void _advance() {
    if (_isPaused || _submitted) return;
    if (_world.advanceDay()) {
      HapticFeedback.mediumImpact();
      setState(() {
        _selected = null;
        _message = _world.complete
            ? 'Your living world is ready. Tap and explore it!'
            : 'Day ${_world.currentDay}: ${creationDayLabels[_world.currentDay - 1]}.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final art = _graphics;
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('The Creation artwork is still getting ready.'),
            TextButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );
    }
    if (art == null) return const Center(child: CircularProgressIndicator());
    final facts = _world.requirements(_world.currentDay);
    final readyPieces = _world.availablePieces
        .where((p) => !_world.placements.containsKey(p.id))
        .toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest, board = _board(size);
        return Stack(
          children: [
            Positioned.fill(
              child: DragTarget<String>(
                onWillAcceptWithDetails: (_) => !_isPaused && !_submitted,
                onAcceptWithDetails: (details) {
                  final box = context.findRenderObject() as RenderBox;
                  final cell = _cell(box.globalToLocal(details.offset), board);
                  if (cell != null) _place(details.data, cell);
                },
                builder: (_, _, _) => GestureDetector(
                  onTapUp: (details) {
                    _tapBoard(details.localPosition, board);
                  },
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _CreationWorldPainter(
                        _world,
                        art,
                        board,
                        _motion,
                        _selected,
                        _night,
                      ),
                      size: size,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 12,
              left: 16,
              right: 16,
              child: SafeArea(
                bottom: false,
                child: Column(
                  children: [
                    Row(
                      children: [
                        if (widget.onExit != null)
                          IconButton(
                            tooltip: 'Leave this world',
                            onPressed: widget.onExit,
                            icon: const Icon(Icons.close_rounded),
                          ),
                        Expanded(
                          child: Text(
                            _world.complete
                                ? 'Your living world'
                                : 'Day ${_world.currentDay} • ${creationDayLabels[_world.currentDay - 1]}',
                            style: const TextStyle(
                              fontSize: 23,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF153D3A),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: _night ? 'Sunrise' : 'Night sky',
                          onPressed: _isPaused
                              ? null
                              : () => setState(() => _night = !_night),
                          icon: Icon(
                            _night
                                ? Icons.wb_sunny_rounded
                                : Icons.nightlight_round,
                          ),
                        ),
                        IconButton(
                          tooltip: _paused
                              ? 'Resume building'
                              : 'Pause building',
                          onPressed: widget.paused || !_foreground
                              ? null
                              : () {
                                  setState(() => _paused = !_paused);
                                  _syncRunState();
                                },
                          icon: Icon(
                            _paused
                                ? Icons.play_arrow_rounded
                                : Icons.pause_rounded,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(
                        _world.totalDays,
                        (i) => Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: CircleAvatar(
                            radius: 13,
                            backgroundColor: i < _world.completedDays
                                ? const Color(0xFF62B790)
                                : Colors.white.withValues(alpha: .8),
                            child: Text(
                              '${i + 1}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF173A37),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 18,
              right: 18,
              bottom: 14,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_world.currentDay >= 3)
                      Wrap(
                        spacing: 8,
                        children: [
                          _status('Flowing river', facts.riverConnected),
                          _status('Open meadow', facts.meadowConnected),
                          if (_world.currentDay >= 5)
                            _status(
                              'Safe homes',
                              facts.fishSafe &&
                                  facts.birdsSafe &&
                                  facts.animalsSafe,
                            ),
                        ],
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: Text(
                        _message,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFF173C39),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (readyPieces.isNotEmpty)
                      Container(
                        height: 83,
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .92),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: readyPieces.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 5),
                          itemBuilder: (_, i) {
                            final piece = readyPieces[i];
                            final preview = _piecePreview(piece.kind, art);
                            return Draggable<String>(
                              data: piece.id,
                              feedback: SizedBox(
                                width: 90,
                                height: 90,
                                child: preview,
                              ),
                              childWhenDragging: Opacity(
                                opacity: .3,
                                child: _palettePiece(piece, preview),
                              ),
                              child: GestureDetector(
                                onTap: _isPaused
                                    ? null
                                    : () =>
                                          setState(() => _selected = piece.id),
                                child: _palettePiece(piece, preview),
                              ),
                            );
                          },
                        ),
                      ),
                    if (_selected != null)
                      TextButton.icon(
                        onPressed: () {
                          if (_isPaused || _submitted) return;
                          setState(() {
                            _world.remove(_selected!);
                            _selected = null;
                          });
                        },
                        icon: const Icon(Icons.undo_rounded),
                        label: const Text('Return this piece to the tray'),
                      ),
                    const SizedBox(height: 7),
                    if (!_world.complete)
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          foregroundColor: Colors.white,
                          textStyle: const TextStyle(
                            fontFamily: 'Avenir Next',
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        onPressed: !_isPaused && _world.canAdvance
                            ? _advance
                            : null,
                        icon: const Icon(Icons.check_circle_outline_rounded),
                        label: Text(
                          _world.currentDay == 7
                              ? 'Rest and enjoy your world'
                              : 'Finish day ${_world.currentDay}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontFamily: 'Avenir Next',
                          ),
                        ),
                      ),
                    if (_world.complete)
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          foregroundColor: Colors.white,
                          textStyle: const TextStyle(
                            fontFamily: 'Avenir Next',
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        onPressed: _submitted || _isPaused
                            ? null
                            : () {
                                setState(() => _submitted = true);
                                _elapsed.stop();
                                widget.onComplete(
                                  _world.submission(_elapsed.elapsed.inSeconds),
                                );
                              },
                        icon: const Icon(
                          Icons.favorite_rounded,
                          color: Colors.white,
                        ),
                        label: const Text(
                          'Save my world',
                          style: TextStyle(
                            color: Colors.white,
                            fontFamily: 'Avenir Next',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_paused)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(color: Colors.black.withValues(alpha: .10)),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _palettePiece(CreationPiece piece, Widget preview) => Container(
    width: 67,
    decoration: BoxDecoration(
      color: _selected == piece.id
          ? const Color(0xFFDCF5B2)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      children: [
        SizedBox(height: 47, child: preview),
        Text(
          piece.kind,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );

  Widget _piecePreview(String kind, CreationWorldGraphics art) => CustomPaint(
    painter: _CreationPiecePainter(kind, art),
    size: const Size(65, 55),
  );
  Widget _status(String label, bool ready) => Chip(
    visualDensity: VisualDensity.compact,
    avatar: Icon(
      ready ? Icons.check_rounded : Icons.more_horiz_rounded,
      size: 16,
    ),
    label: Text(label, style: const TextStyle(fontSize: 11)),
    backgroundColor: ready ? const Color(0xFFD8F0BD) : Colors.white,
  );
}

class _CreationPiecePainter extends CustomPainter {
  _CreationPiecePainter(this.kind, this.art);
  final String kind;
  final CreationWorldGraphics art;
  @override
  void paint(Canvas canvas, Size size) {
    final image = art.images[kind];
    if (image == null) return;
    canvas.drawImageRect(
      image,
      art.source(kind, 0, 0),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_CreationPiecePainter old) =>
      kind != old.kind || art != old.art;
}

class _CreationWorldPainter extends CustomPainter {
  _CreationWorldPainter(
    this.world,
    this.art,
    this.board,
    this.motion,
    this.selected,
    this.night,
  ) : super(repaint: motion);
  final CreationWorldModel world;
  final CreationWorldGraphics art;
  final Rect board;
  final Animation<double> motion;
  final String? selected;
  final bool night;

  Offset center(int cell) => Offset(
    board.left + (cell % world.columns + .5) * board.width / world.columns,
    board.top + (cell ~/ world.columns + .5) * board.height / world.rows,
  );

  void image(
    Canvas canvas,
    String kind,
    Rect target, {
    int frame = 0,
    int direction = 0,
  }) {
    final texture = art.images[kind];
    if (texture == null) return;
    canvas.drawImageRect(
      texture,
      art.source(kind, frame, direction),
      target,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    image(canvas, 'background', Offset.zero & size);
    if (night) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = const Color(0xFF102554).withValues(alpha: .30),
      );
    }
    final width = board.width / world.columns,
        height = board.height / world.rows;
    final floors = world.floors;
    for (var cell = 0; cell < world.rows * world.columns; cell++) {
      final floor = floors[cell] ?? 'empty';
      image(
        canvas,
        floor,
        Rect.fromCenter(
          center: center(cell),
          width: width * 1.12,
          height: height * 1.30,
        ),
      );
      if (cell == world.riverStart || cell == world.riverEnd) {
        canvas.drawCircle(
          center(cell),
          8,
          Paint()..color = const Color(0xFF48C7DF).withValues(alpha: .9),
        );
        final label = TextPainter(
          text: TextSpan(
            text: cell == world.riverStart ? 'SOURCE' : 'SEA',
            style: const TextStyle(
              fontSize: 8,
              fontFamily: 'Avenir Next',
              color: Color(0xFF103F62),
              fontWeight: FontWeight.w800,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        label.paint(canvas, center(cell) + Offset(-label.width / 2, 9));
      }
    }
    for (final entry in world.placements.entries) {
      final p = world.piece(entry.key);
      if (p.layer == 'ground') continue;
      var position = center(entry.value);
      var direction = 0, frame = 0;
      if (p.layer == 'sky') {
        position = Offset(
          position.dx,
          board.top - 44 + math.sin(motion.value * math.pi * 2) * 3,
        );
      } else {
        final path = world.creaturePath(p);
        if (path.length > 1) {
          final progress = motion.value * (path.length - 1);
          final index = progress.floor().clamp(0, path.length - 2);
          final a = center(path[index]), b = center(path[index + 1]);
          position = Offset.lerp(a, b, progress - index)!;
          final angle = math.atan2(b.dy - a.dy, b.dx - a.dx);
          direction = ((angle / (math.pi / 4)).round() % 8 + 8) % 8;
          frame = 1 + ((motion.value * 96).floor() % 8);
          if (p.kind == 'bird') {
            position -= Offset(
              0,
              math.sin((progress - index) * math.pi).abs() * height * .65,
            );
          }
        }
      }
      final extent = p.layer == 'sky' ? width * 1.15 : width * .90;
      final animal = art.animals[p.kind];
      final anchor = animal?['foot_anchor'] as List?;
      final cell = (animal?['cell'] as num?)?.toDouble();
      final target = anchor != null && cell != null
          ? Rect.fromLTWH(
              position.dx - (anchor[0] as num) / cell * extent,
              position.dy - (anchor[1] as num) / cell * extent,
              extent,
              extent,
            )
          : Rect.fromCenter(
              center: position - Offset(0, height * .14),
              width: extent,
              height: extent,
            );
      image(canvas, p.kind, target, frame: frame, direction: direction);
      if (entry.key == selected) {
        canvas.drawCircle(
          center(entry.value),
          width * .40,
          Paint()
            ..color = const Color(0xFFFDCA52)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CreationWorldPainter old) => true;
}

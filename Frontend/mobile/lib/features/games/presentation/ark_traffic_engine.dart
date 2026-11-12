import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../domain/ark_traffic_model.dart';
import '../domain/mini_game.dart';
import 'ark_traffic_graphics.dart';
import 'ark_traffic_renderer.dart';

class ArkTrafficEngine extends StatefulWidget {
  const ArkTrafficEngine({
    required this.level,
    required this.onComplete,
    this.onExit,
    this.graphicsLoader,
    this.paused = false,
    super.key,
  });
  final GameLevel level;
  final void Function(Map<String, dynamic>) onComplete;
  final VoidCallback? onExit;
  final Future<ArkTrafficGraphics> Function(int)? graphicsLoader;
  final bool paused;
  @override
  State<ArkTrafficEngine> createState() => _ArkTrafficEngineState();
}

class _ArkTrafficEngineState extends State<ArkTrafficEngine>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  ArkTrafficRun? _run;
  ArkTrafficGraphics? _graphics;
  Object? _loadError;
  late final Ticker _ticker;
  final ValueNotifier<int> _paintClock = ValueNotifier(0);
  Duration? _lastFrame;
  double _accumulator = 0;
  final Map<String, ArkTrafficPoint> _previousPositions = {};
  String? _selectedId;
  bool _drawingWasWaiting = false;
  final List<String> _draft = [];
  bool _sent = false;
  bool _finishing = false;
  bool _userPaused = false;
  bool _foreground = true;
  Timer? _finishTimer;
  int _generation = 0;
  Size _sceneSize = Size.zero;
  String _message = 'Draw a trail from an animal to the ark.';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    try {
      _run = ArkTrafficRun(ArkTrafficCourse.fromConfig(widget.level.config));
      _run!.paused = widget.paused || !_foreground;
    } catch (error) {
      _loadError = error;
    }
    _ticker = createTicker(_frame);
    if (_run != null) unawaited(_loadGraphics());
  }

  Future<void> _loadGraphics() async {
    final generation = ++_generation;
    try {
      final graphics =
          await (widget.graphicsLoader?.call(widget.level.number) ??
              ArkTrafficGraphics.load(widget.level.number));
      if (!mounted || generation != _generation) {
        graphics.dispose();
        return;
      }
      setState(() => _graphics = graphics);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _loadError = error);
      }
    }
  }

  void _frame(Duration elapsed) {
    final prior = _lastFrame;
    _lastFrame = elapsed;
    final run = _run;
    if (prior == null ||
        run == null ||
        !run.started ||
        run.paused ||
        run.finished ||
        _finishing) {
      return;
    }
    final before = run.boardedCount;
    final beforeSeconds = run.tick ~/ 10;
    _accumulator += math.min(.25, (elapsed - prior).inMicroseconds / 1000000);
    while (_accumulator >= .1 && !run.finished) {
      for (final state in run.animals) {
        _previousPositions[state.animal.id] = state.position(run.course);
      }
      run.step();
      _accumulator -= .1;
    }
    _paintClock.value += 1;
    if (run.finished) {
      _ticker.stop();
      _previousPositions.clear();
      setState(() {
        _finishing = true;
        _selectedId = null;
        _draft.clear();
      });
      // Keep the filled ark visible long enough to enjoy the rescue.
      _scheduleSubmission();
    } else if (before != run.boardedCount || beforeSeconds != run.tick ~/ 10) {
      setState(() {
        if (before != run.boardedCount) {
          _message =
              '${run.boardedCount} ${run.boardedCount == 1 ? 'friend' : 'friends'} aboard! Keep the rescue going.';
        }
      });
    }
  }

  ArkTrafficPoint _displayPosition(ArkTrafficAnimalState state) {
    final actual = state.position(_run!.course);
    final previous = _previousPositions[state.animal.id];
    if (previous == null || !state.movedLastTick) return actual;
    final blend = (_accumulator / .1).clamp(0.0, 1.0);
    return ArkTrafficPoint(
      previous.x + (actual.x - previous.x) * blend,
      previous.y + (actual.y - previous.y) * blend,
    );
  }

  @override
  void didUpdateWidget(covariant ArkTrafficEngine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paused != widget.paused) _syncPause();
  }

  void _syncPause() {
    final run = _run;
    if (run == null) return;
    run.paused = _userPaused || widget.paused || !_foreground;
    _lastFrame = null;
    if (run.paused) {
      _ticker.stop();
      _finishTimer?.cancel();
    } else if (run.started && !run.finished && !_ticker.isActive) {
      _ticker.start();
    }
    if (run.finished && !widget.paused && _foreground && !_sent) {
      _scheduleSubmission();
    }
  }

  void _scheduleSubmission() {
    _finishTimer?.cancel();
    if (widget.paused || !_foreground || _sent) return;
    _finishTimer = Timer(const Duration(milliseconds: 1400), _submit);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state != AppLifecycleState.resumed &&
        _run?.started == true &&
        _run?.finished == false) {
      setState(() {
        _userPaused = true;
        _run!.paused = true;
        _accumulator = 0;
        _message = 'Your animals are safe. Resume when you are ready.';
      });
      _ticker.stop();
    }
    _syncPause();
  }

  @override
  void dispose() {
    _generation += 1;
    _finishTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _paintClock.dispose();
    _graphics?.dispose();
    super.dispose();
  }

  void _start() {
    final run = _run;
    if (run == null || _graphics == null || widget.paused || !_foreground) {
      return;
    }
    setState(() {
      run.start();
      _userPaused = false;
      run.paused = false;
      _accumulator = 0;
      _lastFrame = null;
      _message = 'Draw along a trail. Tap an animal to wait at the side.';
    });
    if (!_ticker.isActive) _ticker.start();
  }

  void _pause() {
    if (_run?.started != true || _run!.finished) return;
    setState(() {
      _run!.paused = true;
      _userPaused = true;
      _accumulator = 0;
    });
    _ticker.stop();
  }

  void _submit() {
    if (!mounted || _sent || _run == null || widget.paused || !_foreground) {
      return;
    }
    _sent = true;
    widget.onComplete(_run!.result);
  }

  ArkTrafficAnimalState? _hitAnimal(Offset offset) {
    final run = _run;
    if (run == null) return null;
    ArkTrafficAnimalState? best;
    var distance = double.infinity;
    for (final state in run.animals) {
      if (state.boarded) continue;
      final center = ArkTrafficPainter.animalPosition(
        state,
        run.course,
        _sceneSize,
        pointOverride: _displayPosition(state),
      );
      final next = (center - offset).distance;
      if (next <=
              ArkTrafficPainter.hitRadius(_sceneSize, state.animal.species) &&
          next < distance) {
        best = state;
        distance = next;
      }
    }
    return best;
  }

  void _tapAnimal(String id) {
    final run = _run;
    final animal = run?.animal(id);
    if (run == null || animal == null || !run.canCommand) return;
    if (run.setWaiting(id, !animal.waiting)) {
      setState(() {
        _message = animal.waiting
            ? '${_label(animal)} steps aside. Let a friend pass!'
            : '${_label(animal)} is ready to go.';
      });
      HapticFeedback.selectionClick();
    }
  }

  void _tapGate(String id) {
    if (_run?.toggleGate(id) != true) return;
    setState(
      () => _message = _run!.gates[id]!
          ? 'The gate is open. Here come the friends!'
          : 'Gate closed. Draw another route or tap to open.',
    );
    HapticFeedback.selectionClick();
  }

  void _tap(Offset offset) {
    if (_run?.canCommand != true) return;
    final animal = _hitAnimal(offset);
    if (animal != null) {
      _tapAnimal(animal.animal.id);
      return;
    }
    for (final edge in _run!.course.edges.where((edge) => edge.gate != null)) {
      final a = _run!.course.nodes[edge.a]!;
      final b = _run!.course.nodes[edge.b]!;
      final position = ArkTrafficPainter.point(
        ArkTrafficPoint((a.x + b.x) / 2, (a.y + b.y) / 2),
        _sceneSize,
      );
      if ((position - offset).distance <= 30) {
        _tapGate(edge.gate!);
        return;
      }
    }
  }

  void _drawStart(Offset offset) {
    if (_run?.canCommand != true) return;
    final state = _hitAnimal(offset);
    if (state == null) return;
    if (_selectedId == state.animal.id && _draft.isNotEmpty) return;
    _drawingWasWaiting = state.waiting;
    if (!state.waiting) _run!.setWaiting(state.animal.id, true);
    setState(() {
      _selectedId = state.animal.id;
      _draft
        ..clear()
        ..add(state.anchor);
      _message = switch (state.animal.species) {
        'elephant' => 'Elephants need wide trails. Draw a roomy route.',
        'goat' => 'Goats love the rocky shortcut. Draw across the stones!',
        'tortoise' => 'Slow and steady! Give this tortoise a little room.',
        _ => 'Tiny feet catch up fast. Draw a clear trail!',
      };
    });
  }

  void _drawUpdate(Offset offset) {
    final run = _run;
    if (run == null ||
        _selectedId == null ||
        !run.canCommand ||
        _draft.isEmpty) {
      return;
    }
    final state = run.animal(_selectedId!)!;
    final nearest = run.course.nearestNode(
      ArkTrafficPainter.normalized(offset, _sceneSize),
      within: .105,
    );
    if (nearest == null || nearest.id == _draft.last) return;
    if (_draft.length >= 2 && nearest.id == _draft[_draft.length - 2]) {
      setState(() => _draft.removeLast());
      return;
    }
    if (_draft.length >= 24 || _draft.last == run.course.arkNode) return;
    final edge = run.course.edge(_draft.last, nearest.id);
    if (edge == null) return;
    if (!edge.accepts(state.animal.species)) {
      setState(
        () => _message = edge.terrain == 'rocky'
            ? 'Those rocks are a goat shortcut. Try a wider trail.'
            : 'This friend needs a wider trail.',
      );
      return;
    }
    setState(() => _draft.add(nearest.id));
  }

  void _drawEnd() {
    final run = _run;
    final id = _selectedId;
    if (run == null || id == null) return;
    if (run.paused) return;
    final path = List<String>.of(_draft);
    final accepted = path.length >= 2 && run.setRoute(id, path);
    if (!_drawingWasWaiting) run.setWaiting(id, false);
    setState(() {
      if (accepted) {
        _message = run.animal(id)!.waiting
            ? 'Route ready! Tap this friend to go.'
            : path.last == run.course.arkNode
            ? 'Off to the ark! Who needs a route next?'
            : 'Route ready. Draw again from the next junction to the ark.';
      } else {
        _message = 'Follow the glowing trail dots to draw a route.';
      }
      _selectedId = null;
      _draft.clear();
    });
    if (accepted) HapticFeedback.lightImpact();
  }

  static String _label(ArkTrafficAnimalState state) =>
      switch (state.animal.species) {
        'tortoise' => 'Tortoise',
        'elephant' => 'Elephant',
        'goat' => 'Goat',
        _ => 'Rabbit',
      };

  @override
  Widget build(BuildContext context) {
    final run = _run;
    final graphics = _graphics;
    if (_loadError != null) {
      return ColoredBox(
        color: const Color(0xFFEAF4DF),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'The animals are getting ready. This map could not load.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                if (run != null)
                  FilledButton(
                    onPressed: () => setState(() {
                      _loadError = null;
                      unawaited(_loadGraphics());
                    }),
                    child: const Text('Try again'),
                  ),
                if (widget.onExit != null)
                  TextButton(
                    onPressed: widget.onExit,
                    child: const Text('Back to games'),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    if (run == null || graphics == null) {
      return const ColoredBox(
        color: Color(0xFFEAF4DF),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        _sceneSize = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          key: const Key('ark-traffic-engine'),
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              dragStartBehavior: DragStartBehavior.down,
              onTapUp: (event) => _tap(event.localPosition),
              onPanStart: (event) => _drawStart(event.localPosition),
              onPanUpdate: (event) => _drawUpdate(event.localPosition),
              onPanEnd: (_) => _drawEnd(),
              onPanCancel: () {
                if (widget.paused || _run?.paused == true) return;
                final id = _selectedId;
                if (id != null && !_drawingWasWaiting) {
                  _run?.setWaiting(id, false);
                }
                setState(() {
                  _selectedId = null;
                  _draft.clear();
                });
              },
              child: CustomPaint(
                painter: ArkTrafficPainter(
                  run: run,
                  graphics: graphics,
                  selectedId: _selectedId,
                  draft: List.of(_draft),
                  reducedMotion: reducedMotion,
                  positionFor: _displayPosition,
                  repaint: _paintClock,
                  onAnimalTap: _tapAnimal,
                  onGateTap: _tapGate,
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 12,
              right: 12,
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    if (widget.onExit != null)
                      _roundButton(
                        Icons.arrow_back_rounded,
                        'Exit rescue',
                        widget.onExit!,
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _stat(
                        '${run.boardedCount} / ${run.animals.length} aboard',
                        Icons.pets_rounded,
                        key: const Key('ark-traffic-boarded'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _stat(
                      '${((run.course.timeLimitTicks - run.tick) / 10).ceil()}s',
                      Icons.timer_rounded,
                      key: const Key('ark-traffic-time'),
                    ),
                    const SizedBox(width: 8),
                    _roundButton(Icons.pause_rounded, 'Pause rescue', _pause),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 10,
              child: SafeArea(
                top: false,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xF7FFF8E7),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Text(
                      _message,
                      key: const Key('ark-traffic-message'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFF244544),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (!run.started || (run.paused && !_finishing && !widget.paused))
              _readyCard(run),
            if (_finishing)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 20,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xF7FFF8E7),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        run.complete ? 'Everyone is aboard!' : 'A kind rescue!',
                        style: const TextStyle(
                          color: Color(0xFF244544),
                          fontSize: 25,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${run.boardedCount} animal friends are safe.',
                        style: const TextStyle(color: Color(0xFF244544)),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _readyCard(ArkTrafficRun run) => ColoredBox(
    color: const Color(0x66142F2B),
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF8E7),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  run.paused ? 'Your rescue is paused' : "Noah’s Ark Rescue",
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF244544),
                    fontSize: 27,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  run.paused
                      ? 'Your friends will wait for you.'
                      : 'ANIMAL TRAFFIC · LEVEL ${widget.level.number}',
                  style: const TextStyle(
                    color: Color(0xFF278185),
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: .7,
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Draw from each animal along a trail to the ark. Tap a friend to wait at the side, then tap again to go.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF244544),
                    fontSize: 15,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  switch (widget.level.number) {
                    3 =>
                      'Mud slows the animals. Open both gates, and give fast little feet a clear route.',
                    2 =>
                      'Goats take the rocks. Tap gates to open them. Watch out for fast little feet!',
                    _ =>
                      'Tortoises are slow. Elephants need wide trails. Goats can take the rocky shortcut.',
                  },
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF5B6B5A),
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  key: const Key('ark-traffic-start'),
                  onPressed: _start,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF137E87),
                    minimumSize: const Size(200, 50),
                  ),
                  child: Text(
                    run.paused ? 'Resume rescue' : 'Let’s rescue the animals!',
                  ),
                ),
                if (widget.onExit != null)
                  TextButton(
                    onPressed: widget.onExit,
                    child: const Text('Back to games'),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  static Widget _roundButton(
    IconData icon,
    String label,
    VoidCallback action,
  ) => Material(
    color: const Color(0xF7FFF8E7),
    shape: const CircleBorder(),
    child: IconButton(
      tooltip: label,
      onPressed: action,
      icon: Icon(icon, color: const Color(0xFF244544)),
    ),
  );
  static Widget _stat(String text, IconData icon, {Key? key}) => Container(
    key: key,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0xF7FFF8E7),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 17, color: const Color(0xFF137E87)),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            style: const TextStyle(
              color: Color(0xFF244544),
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ],
    ),
  );
}

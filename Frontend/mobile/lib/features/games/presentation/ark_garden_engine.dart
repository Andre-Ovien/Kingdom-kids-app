import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../domain/ark_garden_model.dart';
import '../domain/ark_garden_projection.dart';
import '../domain/mini_game.dart';
import 'ark_garden_scene.dart';

/// Staged tap-to-board engine. It stays inert until a reviewed scene covering
/// all ten species is supplied. The catalogue has no enabled garden entry.
class ArkGardenEngine extends StatefulWidget {
  const ArkGardenEngine({
    required this.level,
    required this.onComplete,
    this.scene,
    this.onExit,
    this.paused = false,
    this.restoreOrientations = const [],
    super.key,
  });
  final GameLevel level;
  final void Function(Map<String, dynamic>) onComplete;
  final ArkGardenScene? scene;
  final VoidCallback? onExit;
  final bool paused;

  /// The current host has no orientation lock. A future locked host can supply
  /// its own policy so an approved rescue restores that exact policy on exit.
  final List<DeviceOrientation> restoreOrientations;

  @override
  State<ArkGardenEngine> createState() => _ArkGardenEngineState();
}

class _ArkGardenEngineState extends State<ArkGardenEngine>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  ArkGardenRun? _run;
  late final Ticker _ticker;
  final ValueNotifier<int> _paintClock = ValueNotifier(0);
  final Map<String, ArkGardenPoint> _previousPositions = {};
  Duration? _lastFrame;
  double _accumulator = 0;
  double _pan = 0;
  bool _foreground = true;
  bool _userPaused = false;
  bool _sent = false;
  bool _finished = false;
  bool _landscapeRequested = false;
  ArkGardenViewport? _viewport;

  bool get _artReady {
    final scene = widget.scene;
    return scene != null &&
        scene.reviewed &&
        scene.species.length == arkGardenSpecies.length &&
        scene.species.containsAll(arkGardenSpecies);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    try {
      if (widget.level.number != 1) {
        throw const FormatException('Ark garden has one level.');
      }
      _run = ArkGardenRun(ArkGardenCourse.fromConfig(widget.level.config));
    } on FormatException {
      // An unavailable or malformed course cannot start or submit a round.
    }
    _ticker = createTicker(_frame);
    _syncPause();
  }

  @override
  void didUpdateWidget(covariant ArkGardenEngine oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPause();
  }

  void _syncPause() {
    final run = _run;
    if (run == null) return;
    if (_artReady && !_landscapeRequested) {
      _landscapeRequested = true;
      unawaited(
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]).catchError((Object _) {}),
      );
    }
    run.paused = widget.paused || _userPaused || !_foreground || !_artReady;
    _lastFrame = null;
    if (run.paused) {
      _ticker.stop();
    } else {
      run.start();
      if (!run.finished && !_ticker.isActive) _ticker.start();
      if (run.finished) _submitWhenAvailable();
    }
  }

  void _frame(Duration elapsed) {
    final prior = _lastFrame;
    _lastFrame = elapsed;
    final run = _run;
    if (prior == null || run == null || run.paused || run.finished) return;
    final boarded = run.boardedCount;
    final seconds = run.tick ~/ 10;
    // Preserve foreground time after a slow frame. The bounded course caps the
    // catch-up work; throwing time away would stretch the advertised deadline.
    _accumulator += math.max(0, (elapsed - prior).inMicroseconds / 1000000);
    while (_accumulator + 1e-9 >= .1 && !run.finished) {
      for (final animal in run.animals) {
        _previousPositions[animal.animal.id] = animal.position;
      }
      run.step();
      _accumulator = math.max(0, _accumulator - .1);
    }
    _paintClock.value += 1;
    if (run.finished) {
      _ticker.stop();
      _previousPositions.clear();
      setState(() => _finished = true);
      // Paint the final disappearance before the host opens its save overlay.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _submitWhenAvailable(),
      );
    } else if (run.boardedCount != boarded || run.tick ~/ 10 != seconds) {
      setState(() {});
    }
  }

  ArkGardenPoint _displayPosition(ArkGardenAnimalState state) {
    final previous = _previousPositions[state.animal.id];
    if (previous == null || state.boarded || state.tappedAtTick == null) {
      return state.position;
    }
    return previous.lerp(state.position, (_accumulator / .1).clamp(0.0, 1.0));
  }

  void _submitWhenAvailable() {
    final run = _run;
    if (!mounted ||
        _sent ||
        run == null ||
        !run.finished ||
        run.paused ||
        !_artReady) {
      return;
    }
    _sent = true;
    widget.onComplete(run.result);
  }

  void _tapAnimal(String id) {
    if (_run?.tap(id) != true) return;
    HapticFeedback.selectionClick();
    _paintClock.value += 1;
    setState(() {});
  }

  void _tap(Offset at) {
    final run = _run;
    final viewport = _viewport;
    if (run == null || viewport == null || !run.canTap) return;
    final painter = _painter(viewport);
    ArkGardenAnimalFrame? nearest;
    var distance = double.infinity;
    for (final animal in painter.frames) {
      if (animal.phase != ArkGardenAnimalPhase.idle) continue;
      final next = (animal.feet - at).distance;
      if (next < distance && next <= ArkGardenPainter.hitRadius(animal)) {
        nearest = animal;
        distance = next;
      }
    }
    if (nearest != null) _tapAnimal(nearest.animal.id);
  }

  ArkGardenPainter _painter(ArkGardenViewport viewport) => ArkGardenPainter(
    run: _run!,
    scene: widget.scene!,
    viewport: viewport,
    reducedMotion: MediaQuery.disableAnimationsOf(context),
    positionFor: _displayPosition,
    onAnimalTap: _tapAnimal,
    repaint: _paintClock,
  );

  void _pause() {
    if (_run?.finished != false) return;
    setState(() => _userPaused = true);
    _syncPause();
  }

  void _resume() {
    if (!_foreground || widget.paused) return;
    setState(() => _userPaused = false);
    _syncPause();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() {
      _foreground = state == AppLifecycleState.resumed;
      if (!_foreground && _run?.started == true && _run?.finished == false) {
        _userPaused = true;
      }
    });
    _syncPause();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _paintClock.dispose();
    if (_landscapeRequested) {
      unawaited(
        SystemChrome.setPreferredOrientations(
          widget.restoreOrientations,
        ).catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final run = _run;
    if (!_artReady || run == null) {
      return const SizedBox.expand(key: Key('ark-garden-held'));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = ArkGardenViewport(
          course: run.course,
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          pan: _pan,
        );
        _viewport = viewport;
        _pan = viewport.panPixels;
        return Stack(
          key: const Key('ark-garden-engine'),
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (event) => _tap(event.localPosition),
              onHorizontalDragUpdate: (event) {
                if (run.paused || _finished) return;
                setState(
                  () => _pan = (_pan - event.delta.dx).clamp(
                    0.0,
                    viewport.maximumPan,
                  ),
                );
              },
              child: CustomPaint(painter: _painter(viewport)),
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
                      IconButton.filledTonal(
                        tooltip: 'Exit rescue',
                        onPressed: widget.onExit,
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _stat(
                        '${run.boardedCount} / 10 aboard',
                        const Key('ark-garden-boarded'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _stat(
                      '${((run.course.timeLimitTicks - run.tick) / 10).ceil()}s',
                      const Key('ark-garden-time'),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      key: const Key('ark-garden-pause'),
                      tooltip: 'Pause rescue',
                      onPressed: _finished ? null : _pause,
                      icon: const Icon(Icons.pause_rounded),
                    ),
                  ],
                ),
              ),
            ),
            if (_userPaused && !_finished)
              ColoredBox(
                color: const Color(0xD9F4F6E5),
                child: Center(
                  child: FilledButton.icon(
                    key: const Key('ark-garden-resume'),
                    onPressed: widget.paused || !_foreground ? null : _resume,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Resume rescue'),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _stat(String label, Key key) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xF7FFF8E7),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Text(
        label,
        key: key,
        textAlign: TextAlign.center,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
  );
}

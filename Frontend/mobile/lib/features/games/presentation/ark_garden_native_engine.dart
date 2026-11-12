import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../data/ark_garden_assets.dart';
import '../data/ark_garden_viewer.dart';
import '../domain/ark_garden_model.dart';
import '../domain/mini_game.dart';

/// The real, bundled GLB garden. Its WebView is a rendering surface; the same
/// Dart/Python course and ordered boarding queue own all gameplay decisions.
class ArkGardenNativeEngine extends StatefulWidget {
  const ArkGardenNativeEngine({
    required this.level,
    required this.onComplete,
    this.onExit,
    this.paused = false,
    this.restoreOrientations = const [],
    this.viewerFactory,
    this.originFactory,
    super.key,
  });
  final GameLevel level;
  final void Function(Map<String, dynamic>) onComplete;
  final VoidCallback? onExit;
  final bool paused;
  final List<DeviceOrientation> restoreOrientations;
  final ArkGardenViewer Function()? viewerFactory;
  final Future<ArkGardenAssetOrigin> Function()? originFactory;

  @override
  State<ArkGardenNativeEngine> createState() => _ArkGardenNativeEngineState();
}

class _ArkGardenNativeEngineState extends State<ArkGardenNativeEngine>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  ArkGardenRun? _run;
  ArkGardenViewer? _viewer;
  ArkGardenAssetOrigin? _origin;
  late final Ticker _ticker;
  Duration? _lastFrame;
  Timer? _loadingDeadline;
  Timer? _finishDelay;
  Timer? _renderDeadline;
  final Set<String> _renderedArrivals = {};
  double _accumulator = 0;
  bool _ready = false;
  bool _failed = false;
  bool _foreground = true;
  bool _userPaused = false;
  bool _landscapeRequested = false;
  bool _sent = false;
  bool _configuring = false;
  bool _sendingState = false;
  bool _finalStateDelivered = false;
  int _generation = 0;
  Map<String, dynamic>? _pendingState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _ticker = createTicker(_frame);
    try {
      final course = ArkGardenCourse.fromConfig(widget.level.config);
      if (widget.level.number != 1 || course.version != 2) {
        throw const FormatException('The native Ark garden has one v2 level.');
      }
      _run = ArkGardenRun(course)..paused = true;
      _landscapeRequested = true;
      unawaited(
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]).catchError((Object _) {}),
      );
      unawaited(_loadViewer());
    } on FormatException {
      _failed = true;
    }
  }

  Future<void> _loadViewer() async {
    final generation = ++_generation;
    final oldViewer = _viewer;
    final oldOrigin = _origin;
    _viewer = null;
    _origin = null;
    _ready = false;
    _configuring = false;
    _pendingState = null;
    _sendingState = false;
    _finalStateDelivered = false;
    _renderedArrivals.clear();
    _renderDeadline?.cancel();
    _renderDeadline = null;
    _finishDelay?.cancel();
    _finishDelay = null;
    _loadingDeadline?.cancel();
    _loadingDeadline = Timer(const Duration(seconds: 45), () {
      if (mounted && generation == _generation) _fail();
    });
    try {
      await _closeResources(oldViewer, oldOrigin);
      final origin =
          await (widget.originFactory?.call() ?? ArkGardenAssetServer.open());
      if (!mounted || generation != _generation) {
        await origin.close();
        return;
      }
      _origin = origin;
      final viewer = widget.viewerFactory?.call() ?? ArkGardenWebView();
      _viewer = viewer;
      setState(() => _failed = false);
      await viewer.load(
        uri: origin.entryPoint,
        allowsNavigation: origin.allowsNavigation,
        onMessage: (message) {
          if (mounted && generation == _generation) _message(message);
        },
        onFailure: () {
          if (mounted && generation == _generation) _fail();
        },
      );
    } on Object {
      if (generation == _generation && _viewer == null) {
        final origin = _origin;
        _origin = null;
        await origin?.close();
      }
      if (mounted && generation == _generation) _fail();
    }
  }

  void _message(String message) {
    if (message.length > 4096) return;
    try {
      final event = jsonDecode(message);
      if (event is! Map) return;
      switch (event['type']) {
        case 'bridgeReady':
          if (_configuring || _viewer == null || _failed) return;
          _configuring = true;
          final generation = _generation;
          final viewer = _viewer!;
          unawaited(
            viewer.configure(widget.level.config).catchError((Object _) {
              if (mounted && generation == _generation && viewer == _viewer) {
                _fail();
              }
            }),
          );
        case 'ready':
          if (_failed) return;
          final ids = event['animalIds'];
          if (!_configuring ||
              event['version'] != 2 ||
              ids is! List ||
              ids.length != 10 ||
              ids.toSet().length != 10 ||
              !ids.toSet().containsAll(_run!.animals.map((a) => a.animal.id))) {
            _fail();
            return;
          }
          _loadingDeadline?.cancel();
          setState(() {
            _ready = true;
            // A final render failure can arrive before the delayed submission.
            // Finished runs have no Resume overlay, so a successful explicit
            // retry must clear that failure pause without replaying the run.
            if (_run!.finished && !_sent) _userPaused = false;
          });
          _syncPause();
        case 'animalTapped':
          final id = event['id'];
          if (id is String && _run?.tap(id) == true) {
            HapticFeedback.selectionClick();
            _sendState();
          }
        case 'pause':
          if (_ready && _run?.finished == false) {
            setState(() => _userPaused = true);
            _syncPause();
          }
        case 'failure':
          _fail();
        case 'animalEntered':
          final id = event['id'];
          // This acknowledgement only gates presentation. It cannot board an
          // animal or change the authoritative result, score or elapsed time.
          if (_ready &&
              !_failed &&
              event['visualOnly'] == true &&
              id is String &&
              _run?.animal(id)?.boarded == true) {
            _renderedArrivals.add(id);
            _scheduleSubmit();
          }
        // Renderer arrival/result reports are visual-only. Completion is
        // computed from the course and first taps, never accepted from JS.
      }
    } on Object {
      // Malformed or unsupported bridge messages cannot mutate the run.
    }
  }

  void _fail() {
    if (!mounted) return;
    _loadingDeadline?.cancel();
    _finishDelay?.cancel();
    _finishDelay = null;
    _renderDeadline?.cancel();
    _renderDeadline = null;
    setState(() {
      _failed = true;
      _ready = false;
      _userPaused = true;
    });
    _syncPause();
  }

  @override
  void didUpdateWidget(covariant ArkGardenNativeEngine oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPause();
  }

  void _syncPause() {
    final run = _run;
    if (run == null) return;
    run.paused =
        widget.paused || _userPaused || !_foreground || !_ready || _failed;
    _lastFrame = null;
    if (_ready && !_landscapeRequested) {
      _landscapeRequested = true;
      unawaited(
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]).catchError((Object _) {}),
      );
    }
    if (run.paused || run.finished) {
      _ticker.stop();
      if (run.paused) {
        _renderDeadline?.cancel();
        _renderDeadline = null;
      }
    } else {
      run.start();
      if (!_ticker.isActive) _ticker.start();
    }
    _sendState();
    if (run.finished) _scheduleSubmit();
  }

  void _frame(Duration elapsed) {
    final previous = _lastFrame;
    _lastFrame = elapsed;
    final run = _run;
    if (previous == null || run == null || run.paused || run.finished) return;
    _accumulator += math.max(0, (elapsed - previous).inMicroseconds / 1000000);
    final before = run.tick;
    final aboard = run.boardedCount;
    while (_accumulator + 1e-9 >= .1 && !run.finished) {
      run.step();
      _accumulator = math.max(0, _accumulator - .1);
    }
    if (run.tick != before) _sendState();
    if (run.tick ~/ 10 != before ~/ 10 ||
        run.boardedCount != aboard ||
        run.finished) {
      setState(() {});
    }
    if (run.finished) {
      _ticker.stop();
      _scheduleSubmit();
    }
  }

  void _sendState() {
    final run = _run;
    if (_viewer == null || !_ready || run == null) return;
    if (run.finished) _finalStateDelivered = false;
    _pendingState = {
      'tick': run.tick,
      'renderTick': run.tick,
      'taps': {
        for (final animal in run.animals)
          if (animal.tappedAtTick != null)
            animal.animal.id: animal.tappedAtTick,
      },
      'distances': {
        for (final animal in run.animals)
          animal.animal.id: animal.distanceTravelled,
      },
      'paused': run.paused,
      'finished': run.finished,
    };
    if (!_sendingState) unawaited(_drainState());
  }

  Future<void> _closeResources(
    ArkGardenViewer? viewer,
    ArkGardenAssetOrigin? origin,
  ) async {
    try {
      await viewer?.close().timeout(const Duration(seconds: 2));
    } on Object {
      // The route may have disposed its platform surface before this callback.
    } finally {
      await origin?.close();
    }
  }

  Future<void> _drainState() async {
    final generation = _generation;
    final viewer = _viewer!;
    _sendingState = true;
    try {
      while (mounted &&
          generation == _generation &&
          viewer == _viewer &&
          _ready &&
          _pendingState != null) {
        final state = _pendingState!;
        _pendingState = null;
        await viewer.state(state).timeout(const Duration(seconds: 2));
        if (mounted &&
            generation == _generation &&
            viewer == _viewer &&
            state['finished'] == true &&
            state['paused'] == false) {
          _finalStateDelivered = true;
          _scheduleSubmit();
        }
      }
    } on Object {
      if (mounted && generation == _generation && viewer == _viewer) _fail();
    } finally {
      if (generation == _generation && viewer == _viewer) _sendingState = false;
    }
  }

  void _scheduleSubmit() {
    final run = _run;
    if (_sent ||
        _finishDelay != null ||
        !_finalStateDelivered ||
        !_ready ||
        run == null ||
        run.paused ||
        !run.finished) {
      return;
    }
    final generation = _generation;
    if (!_requiredArrivalsRendered(run)) {
      // Delivery to JS does not mean a frame has actually been drawn. A slow
      // rAF must not let the result overlay hide the last boarding animal.
      _renderDeadline ??= Timer(const Duration(seconds: 5), () {
        _renderDeadline = null;
        if (mounted &&
            generation == _generation &&
            !_sent &&
            _ready &&
            !run.paused &&
            !_requiredArrivalsRendered(run)) {
          _fail();
        }
      });
      return;
    }
    _renderDeadline?.cancel();
    _renderDeadline = null;
    // Keep a short presentation settle after actual arrivals as well as the
    // authoritative final state. Missing visual acknowledgements retry safely.
    _finishDelay = Timer(const Duration(milliseconds: 120), () {
      _finishDelay = null;
      final run = _run;
      if (!mounted ||
          generation != _generation ||
          _sent ||
          !_finalStateDelivered ||
          !_ready ||
          run == null ||
          run.paused ||
          !run.finished ||
          !_requiredArrivalsRendered(run)) {
        return;
      }
      _sent = true;
      widget.onComplete(run.result);
    });
  }

  bool _requiredArrivalsRendered(ArkGardenRun run) => run.animals
      .where((animal) => animal.boarded)
      .every((animal) => _renderedArrivals.contains(animal.animal.id));

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
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _loadingDeadline?.cancel();
    _finishDelay?.cancel();
    _renderDeadline?.cancel();
    final viewer = _viewer;
    final origin = _origin;
    unawaited(_closeResources(viewer, origin));
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
    return Stack(
      key: const Key('ark-garden-native-engine'),
      fit: StackFit.expand,
      children: [
        if (_viewer != null) _viewer!.view,
        if (!_ready || _failed)
          ColoredBox(
            color: const Color(0xFFF0F7D9),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_failed) const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    _failed
                        ? 'The garden could not open. Your progress is safe.'
                        : 'Getting the garden ready…',
                  ),
                  if (_failed && run != null) ...[
                    const SizedBox(height: 12),
                    FilledButton(
                      key: const Key('ark-garden-retry'),
                      onPressed: () => unawaited(_loadViewer()),
                      child: const Text('Try again'),
                    ),
                  ],
                ],
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
                  IconButton.filledTonal(
                    tooltip: 'Exit rescue',
                    onPressed: widget.onExit,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: _stat(
                    '${run?.boardedCount ?? 0} / 10 aboard',
                    const Key('ark-garden-boarded'),
                  ),
                ),
                const SizedBox(width: 8),
                _stat(_time(run), const Key('ark-garden-time')),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  key: const Key('ark-garden-pause'),
                  tooltip: 'Pause rescue',
                  onPressed: _ready && run?.finished == false ? _pause : null,
                  icon: const Icon(Icons.pause_rounded),
                ),
              ],
            ),
          ),
        ),
        if (_ready && _userPaused && run?.finished == false)
          ColoredBox(
            color: const Color(0xDCF4F6E5),
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
  }

  String _time(ArkGardenRun? run) {
    final seconds = run == null
        ? 0
        : ((run.course.timeLimitTicks - run.tick) / 10).ceil();
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Widget _stat(String text, Key key) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xF7FFF8E7),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Text(
        text,
        key: key,
        textAlign: TextAlign.center,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
  );
}

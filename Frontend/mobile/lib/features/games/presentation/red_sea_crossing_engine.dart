import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../domain/mini_game.dart';
import 'red_sea_crossing_graphics.dart';
import 'red_sea_crossing_model.dart';
import 'red_sea_crossing_renderer.dart';

class RedSeaCrossingEngine extends StatefulWidget {
  const RedSeaCrossingEngine({
    required this.level,
    required this.onComplete,
    required this.onExit,
    this.paused = false,
    this.graphics,
    this.graphicsManifestAsset,
    super.key,
  });
  final GameLevel level;
  final void Function(Map<String, dynamic>) onComplete;
  final VoidCallback onExit;
  final bool paused;
  final RedSeaCrossingGraphics? graphics;
  final String? graphicsManifestAsset;

  @override
  State<RedSeaCrossingEngine> createState() => _RedSeaCrossingEngineState();
}

class _RedSeaCrossingEngineState extends State<RedSeaCrossingEngine>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  RedSeaCrossingRun? _run;
  late final Ticker _ticker;
  final _boardKey = GlobalKey();
  final _frames = ValueNotifier<int>(0);
  final _hud = ValueNotifier<int>(0);
  Duration? _lastFrame;
  Size _size = Size.zero;
  double _sceneTime = 0;
  double _lastHudAt = 0;
  double _finishHold = 0;
  bool _active = true;
  bool _tickerMode = true;
  bool _submitted = false;
  bool _keyboardPickup = false;
  String? _dragId;
  Offset? _dragFoot;
  Offset _pickupOffset = Offset.zero;
  Offset? _returnFrom;
  double _returnElapsed = 0;
  String? _feedback;
  RedSeaCrossingGraphics? _loadedGraphics;
  int _graphicsGeneration = 0;
  bool _graphicsLoading = false;
  bool _graphicsFailed = false;

  bool get _paused => widget.paused || !_active || !_tickerMode;

  @override
  void initState() {
    super.initState();
    _loadCourse();
    _active =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_tick)..start();
    unawaited(_loadGraphics());
  }

  Future<void> _loadGraphics() async {
    final generation = ++_graphicsGeneration;
    final manifest = widget.graphicsManifestAsset;
    _graphicsLoading = manifest != null && widget.graphics == null;
    _graphicsFailed = false;
    if (!_graphicsLoading) {
      final previous = _loadedGraphics;
      _loadedGraphics = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => previous?.dispose());
      return;
    }
    try {
      final loaded = await RedSeaCrossingGraphics.load(manifest!);
      if (!mounted || generation != _graphicsGeneration) {
        loaded.dispose();
        return;
      }
      final previous = _loadedGraphics;
      setState(() {
        _loadedGraphics = loaded;
        _graphicsLoading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => previous?.dispose());
    } catch (_) {
      if (!mounted || generation != _graphicsGeneration) return;
      setState(() {
        _graphicsLoading = false;
        _graphicsFailed = true;
      });
    }
  }

  void _loadCourse() {
    try {
      _run = RedSeaCrossingRun(RedSeaCrossingCourse.fromLevel(widget.level));
    } on FormatException {
      _run = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mode = TickerMode.valuesOf(context).enabled;
    if (mode != _tickerMode) {
      _tickerMode = mode;
      _lastFrame = null;
      if (_paused) _clearDrag();
    }
  }

  @override
  void didUpdateWidget(covariant RedSeaCrossingEngine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.graphicsManifestAsset != oldWidget.graphicsManifestAsset ||
        widget.graphics != oldWidget.graphics) {
      unawaited(_loadGraphics());
    }
    if (widget.level.id != oldWidget.level.id) {
      _loadCourse();
      _submitted = false;
      _finishHold = _sceneTime = _lastHudAt = 0;
      _clearDrag();
      _lastFrame = null;
      _hud.value += 1;
    }
    if (widget.paused != oldWidget.paused) {
      _lastFrame = null;
      if (_paused) _clearDrag();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    _lastFrame = null;
    if (_paused) _clearDrag();
  }

  void _tick(Duration stamp) {
    final previous = _lastFrame;
    _lastFrame = stamp;
    if (_paused || previous == null || _run == null) return;
    final delta = ((stamp - previous).inMicroseconds / 1000000).clamp(0.0, .1);
    _sceneTime += delta;
    final oldPhase = _run!.phase;
    final oldSafe = _run!.safeCount;
    _run!.advance(delta);
    if (_returnFrom != null && _dragId != null) {
      _returnElapsed += delta;
      final index = _run!.course.travellers.indexWhere((p) => p.id == _dragId);
      final foot = RedSeaCrossingPainter.queuePosition(
        index,
        _run!.course.travellers.length,
        _size,
      );
      _dragFoot = Offset.lerp(
        _returnFrom,
        foot,
        Curves.easeOutCubic.transform((_returnElapsed / .28).clamp(0, 1)),
      );
      if (_returnElapsed >= .28) _clearDrag();
    }
    if (_run!.finished && !_submitted) {
      _clearDrag();
      _finishHold += delta;
      final hold = _run!.phase == RedSeaCrossingPhase.complete ? 1.0 : .7;
      if (_finishHold >= hold) {
        _submitted = true;
        widget.onComplete(_run!.result());
      }
    }
    if (_sceneTime - _lastHudAt >= .1 ||
        oldPhase != _run!.phase ||
        oldSafe != _run!.safeCount) {
      _lastHudAt = _sceneTime;
      _hud.value += 1;
    }
    _frames.value += 1;
  }

  void _openSea() {
    if (_paused || _run == null || _graphicsLoading || _graphicsFailed) return;
    _run!.start();
    _sceneTime = 0;
    _lastHudAt = 0;
    _feedback = null;
    _hud.value += 1;
    unawaited(HapticFeedback.selectionClick());
  }

  Offset _local(Offset global) =>
      (_boardKey.currentContext!.findRenderObject()! as RenderBox)
          .globalToLocal(global);

  void _pick(DragDownDetails details) {
    if (_paused || _run?.canPlace != true || _returnFrom != null) return;
    final pointer = _local(details.globalPosition);
    var nearest = double.infinity;
    String? selected;
    Offset? foot;
    final people = _run!.course.travellers;
    // Prefer the nearest visible face. Foreground torsos can overlap lower
    // robes, so selecting by the old uniform waist circles hid rear people.
    for (var index = 0; index < people.length; index++) {
      if (_run!.placements.containsKey(people[index].id)) continue;
      final center = RedSeaCrossingPainter.queueHitCenter(
        index,
        people.length,
        _size,
      );
      final height = RedSeaCrossingPainter.travellerHeight(
        index,
        people.length,
        _size,
      );
      final hitRadius = math.max(24.0, height * .36);
      final distance = (pointer - center).distanceSquared;
      if (distance <= hitRadius * hitRadius && distance < nearest) {
        nearest = distance;
        selected = people[index].id;
        foot = RedSeaCrossingPainter.queuePosition(index, people.length, _size);
      }
    }
    if (selected == null) {
      // A body pickup follows the same back-to-front order as the painter.
      final available =
          <int>[
            for (var index = 0; index < people.length; index++)
              if (!_run!.placements.containsKey(people[index].id)) index,
          ]..sort(
            (a, b) =>
                RedSeaCrossingPainter.queuePosition(
                  b,
                  people.length,
                  _size,
                ).dy.compareTo(
                  RedSeaCrossingPainter.queuePosition(
                    a,
                    people.length,
                    _size,
                  ).dy,
                ),
          );
      for (final index in available) {
        if (RedSeaCrossingPainter.queueBodyBounds(
          index,
          people.length,
          _size,
        ).contains(pointer)) {
          selected = people[index].id;
          foot = RedSeaCrossingPainter.queuePosition(
            index,
            people.length,
            _size,
          );
          break;
        }
      }
    }
    if (selected == null) return;
    _dragId = selected;
    _dragFoot = foot;
    _pickupOffset = foot! - pointer;
    _keyboardPickup = false;
    _feedback = null;
    _frames.value += 1;
    _hud.value += 1;
  }

  void _move(DragUpdateDetails details) {
    _movePointer(details.globalPosition);
  }

  void _movePointer(Offset globalPosition) {
    if (_paused || _dragId == null || _returnFrom != null) return;
    final pointer = _local(globalPosition) + _pickupOffset;
    _dragFoot = Offset(
      pointer.dx.clamp(0, _size.width),
      pointer.dy.clamp(0, _size.height),
    );
    _frames.value += 1;
  }

  void _drop() {
    if (_dragId == null || _dragFoot == null || _paused) {
      _clearDrag();
      return;
    }
    final accepted = _run!.place(
      _dragId!,
      _dragFoot!.dx / _size.width,
      _dragFoot!.dy / _size.height,
    );
    if (accepted) {
      _clearDrag();
      _feedback = null;
      unawaited(HapticFeedback.lightImpact());
    } else {
      _returnFrom = _dragFoot;
      _returnElapsed = 0;
      _feedback = 'Drop them on the dry path.';
    }
    _frames.value += 1;
    _hud.value += 1;
  }

  void _clearDrag() {
    _dragId = null;
    _dragFoot = null;
    _returnFrom = null;
    _keyboardPickup = false;
    _frames.value += 1;
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (_paused || _run?.canPlace != true || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _clearDrag();
      _frames.value += 1;
      return KeyEventResult.handled;
    }
    final directions = <LogicalKeyboardKey, Offset>{
      LogicalKeyboardKey.arrowLeft: const Offset(-.04, 0),
      LogicalKeyboardKey.arrowRight: const Offset(.04, 0),
      LogicalKeyboardKey.arrowUp: const Offset(0, -.04),
      LogicalKeyboardKey.arrowDown: const Offset(0, .04),
    };
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        !directions.containsKey(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    if (_dragId == null) {
      final index = _run!.course.travellers.indexWhere(
        (p) => !_run!.placements.containsKey(p.id),
      );
      _dragId = _run!.course.travellers[index].id;
      _dragFoot = RedSeaCrossingPainter.queuePosition(
        index,
        _run!.course.travellers.length,
        _size,
      );
      _keyboardPickup = true;
    } else if (event.logicalKey == LogicalKeyboardKey.enter) {
      _drop();
      return KeyEventResult.handled;
    }
    final direction = directions[event.logicalKey];
    if (direction != null) {
      _dragFoot = Offset(
        (_dragFoot!.dx + direction.dx * _size.width).clamp(0, _size.width),
        (_dragFoot!.dy + direction.dy * _size.height).clamp(0, _size.height),
      );
    }
    _frames.value += 1;
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _graphicsGeneration += 1;
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _frames.dispose();
    _hud.dispose();
    _loadedGraphics?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_run == null) {
      return ColoredBox(
        color: const Color(0xFF0D455B),
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'This crossing could not be loaded.',
                  style: TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: widget.onExit,
                  child: const Text('Return to the game library'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Focus(
      autofocus: true,
      onKeyEvent: _key,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _size = Size(constraints.maxWidth, constraints.maxHeight);
          return GestureDetector(
            key: _boardKey,
            behavior: HitTestBehavior.opaque,
            onPanDown: _pick,
            onPanStart: (details) => _movePointer(details.globalPosition),
            onPanUpdate: _move,
            onPanEnd: (_) => _drop(),
            onPanCancel: () {
              // A tap-to-place wins the gesture arena over pan. Keep the
              // accessibility/keyboard pickup until onTapUp places it.
              if (_keyboardPickup) return;
              _clearDrag();
              _frames.value += 1;
            },
            onTapUp: (details) {
              if (_keyboardPickup && _dragId != null && !_paused) {
                _dragFoot = _local(details.globalPosition);
                _drop();
              } else {
                _clearDrag();
                _frames.value += 1;
              }
            },
            child: Stack(
              key: const Key('red-sea-crossing-board'),
              fit: StackFit.expand,
              children: [
                RepaintBoundary(
                  child: CustomPaint(
                    key: const Key('red-sea-crossing-scene'),
                    painter: RedSeaCrossingPainter(
                      run: _run!,
                      sceneTime: () => _sceneTime,
                      draggedPosition: () => _dragFoot,
                      draggedTravellerId: () => _dragId,
                      reducedMotion: MediaQuery.disableAnimationsOf(context),
                      graphics: widget.graphics ?? _loadedGraphics,
                      repaint: _frames,
                    ),
                  ),
                ),
                if ((_graphicsLoading || _graphicsFailed) &&
                    _loadedGraphics == null &&
                    widget.graphics == null)
                  Positioned.fill(
                    child: ColoredBox(
                      color: const Color(0xFFEDDCC0),
                      child: Center(
                        child: _graphicsLoading
                            ? const CircularProgressIndicator(
                                color: Color(0xFF15515B),
                              )
                            : const Icon(
                                Icons.refresh_rounded,
                                color: Color(0xFF15515B),
                                size: 40,
                              ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 12,
                  right: 12,
                  top: MediaQuery.paddingOf(context).top + 10,
                  child: ValueListenableBuilder<int>(
                    valueListenable: _hud,
                    builder: (_, _, _) => _topHud(),
                  ),
                ),
                Positioned(
                  left: 14,
                  right: 14,
                  top: math.max(
                    MediaQuery.paddingOf(context).top + 106,
                    _size.height * .19,
                  ),
                  child: ValueListenableBuilder<int>(
                    valueListenable: _hud,
                    builder: (_, _, _) => _instructions(),
                  ),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: _hud,
                  builder: (_, _, _) => _run!.phase == RedSeaCrossingPhase.ready
                      ? Positioned(
                          left: 20,
                          right: 20,
                          top: math.max(
                            MediaQuery.paddingOf(context).top + 106,
                            _size.height * .15,
                          ),
                          child: _readyPanel(),
                        )
                      : const SizedBox.shrink(),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: _hud,
                  builder: (_, _, _) => Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_run!.canPlace)
                        for (
                          var index = 0;
                          index < _run!.course.travellers.length;
                          index++
                        )
                          if (!_run!.placements.containsKey(
                            _run!.course.travellers[index].id,
                          ))
                            _travellerSemantics(index),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _travellerSemantics(int index) {
    final person = _run!.course.travellers[index];
    final foot = RedSeaCrossingPainter.queuePosition(
      index,
      _run!.course.travellers.length,
      _size,
    );
    final bounds = RedSeaCrossingPainter.queueSemanticsBounds(
      index,
      _run!.course.travellers.length,
      _size,
    );
    return Positioned.fromRect(
      rect: bounds,
      child: Semantics(
        key: ValueKey('red-sea-traveller-${person.id}'),
        label:
            '${person.label}, ${RedSeaCrossingPainter.travellerRole(index)}. Drag to the dry path.',
        sortKey: OrdinalSortKey(index.toDouble()),
        button: true,
        onTap: () {
          if (_paused || !_run!.canPlace) return;
          _dragId = person.id;
          _dragFoot = foot;
          _keyboardPickup = true;
          _frames.value += 1;
        },
        child: const IgnorePointer(child: SizedBox.expand()),
      ),
    );
  }

  Widget _topHud() {
    final compact =
        _size.width < 350 || MediaQuery.textScalerOf(context).scale(1) >= 1.6;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _glass(
          child: IconButton(
            key: const Key('red-sea-exit'),
            tooltip: 'Leave crossing',
            onPressed: widget.onExit,
            color: Colors.white,
            icon: const Icon(Icons.close_rounded),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _glass(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!compact)
                    const Text(
                      'RED SEA CROSSING',
                      style: TextStyle(
                        color: Color(0xFFDDF8FF),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      ),
                    ),
                  if (!compact) const SizedBox(height: 4),
                  Text(
                    '${_run!.safeCount} / ${_run!.course.travellers.length} safe',
                    key: const Key('red-sea-progress'),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: compact ? 14 : 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        _glass(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Text(
              '${_run!.remainingSeconds.ceil()}s',
              key: const Key('red-sea-timer'),
              style: TextStyle(
                color: _run!.remainingSeconds < 10
                    ? const Color(0xFFFFC49B)
                    : Colors.white,
                fontSize: compact ? 20 : 24,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _instructions() {
    final message =
        _feedback ??
        switch (_run!.phase) {
          RedSeaCrossingPhase.ready => '',
          RedSeaCrossingPhase.parting => 'Watch Moses make a way…',
          RedSeaCrossingPhase.placing =>
            'Drag each traveller onto the dry path',
          RedSeaCrossingPhase.walking => 'They’re on their way to safety!',
          RedSeaCrossingPhase.complete => 'Everyone is safe!',
          RedSeaCrossingPhase.timedOut =>
            'Let’s help everyone across next time.',
        };
    if (message.isEmpty) return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      child: _glass(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Text(
            message,
            key: const Key('red-sea-instructions'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  Widget _readyPanel() => _glass(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Make a way',
            style: TextStyle(
              color: Colors.white,
              fontSize: 25,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (_size.height >= 650 &&
              MediaQuery.textScalerOf(context).scale(1) < 1.6) ...[
            const SizedBox(height: 6),
            const Text(
              'Help Moses lead everyone safely across.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFFDCF1F3), fontSize: 14),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('red-sea-open'),
              onPressed: _paused || _graphicsLoading
                  ? null
                  : _graphicsFailed
                  ? () {
                      setState(() => _graphicsLoading = true);
                      unawaited(_loadGraphics());
                    }
                  : _openSea,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFFD37C),
                foregroundColor: const Color(0xFF423322),
                minimumSize: const Size.fromHeight(48),
              ),
              icon: const Icon(Icons.auto_awesome_rounded),
              label: Text(
                _graphicsLoading
                    ? 'Preparing the sea…'
                    : _graphicsFailed
                    ? 'Try loading the scene again'
                    : 'Open the sea',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _glass({required Widget child}) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xDF123E4F),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0x557AD8E6)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x3310222C),
          blurRadius: 12,
          offset: Offset(0, 5),
        ),
      ],
    ),
    child: child,
  );
}

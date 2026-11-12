import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';

import '../domain/mini_game.dart';
import '../data/david_battle_audio.dart';
import 'goliath_mesh_renderer.dart';
import 'goliath_motion_model.dart';

/// Geometry stays in the server's canvas coordinates, independently of the
/// screen size. A release records the projectile's landing, never the target.
class DavidSlingGeometry {
  const DavidSlingGeometry({
    required this.size,
    required this.target,
    required this.targetRadius,
    required this.maxShots,
    this.obstacles = const [],
  });

  factory DavidSlingGeometry.fromLevel(GameLevel level) {
    final canvas = _map(level.config['canvas']);
    final target = _map(level.config['target']);
    final width = _number(canvas['width'], 320).clamp(100.0, 1000.0);
    final height = _number(canvas['height'], 420).clamp(100.0, 1000.0);
    return DavidSlingGeometry(
      size: Size(width, height),
      target: Offset(
        _number(target['x'], width / 2).clamp(0.0, width),
        _number(target['y'], height * .35).clamp(0.0, height),
      ),
      targetRadius: _number(
        target['radius'],
        28,
      ).clamp(1.0, math.min(width, height) / 2),
      maxShots: _number(level.config['max_shots'], 3).toInt().clamp(1, 10),
      obstacles: [
        for (final value in (level.config['obstacles'] as List? ?? const []))
          if (value is Map && value['shape'] == 'circle')
            Rect.fromCircle(
              center: Offset(_number(value['x'], 0), _number(value['y'], 0)),
              radius: _number(value['radius'], 0).clamp(0.0, 500.0),
            ),
      ],
    );
  }

  final Size size;
  final Offset target;
  final double targetRadius;
  final int maxShots;
  final List<Rect> obstacles;

  Offset get pouch => Offset(size.width * .5, size.height * .77);
  double get maximumPull => size.height * .205;
  double get minimumPull => size.height * .035;

  Offset constrainPull(Offset pull) {
    final down = pull.dy.clamp(0.0, maximumPull);
    final sideways = pull.dx.clamp(-size.width * .22, size.width * .22);
    final bounded = Offset(sideways, down);
    return bounded.distance > maximumPull
        ? bounded / bounded.distance * maximumPull
        : bounded;
  }

  bool isHit(Offset landing) => (landing - target).distance <= targetRadius;

  DavidSlingShot shot(Offset pull) =>
      DavidSlingShot._(this, constrainPull(pull));
}

/// A short ballistic projection. Gravity curves the shot; viewport boundaries
/// and circular shields stop it at the first collision, including the preview.
class DavidSlingShot {
  DavidSlingShot._(this.geometry, this.pull) {
    var previous = _unbounded(0);
    var fraction = 1.0;
    for (var sample = 1; sample <= 200; sample++) {
      final t = sample / 200;
      final point = _unbounded(t);
      if (!_inside(point) || _insideShield(point)) {
        // Refine the first impact so the rendered path and submitted coordinate
        // agree even with a narrow obstacle or a resized playing surface.
        var low = (sample - 1) / 200;
        var high = t;
        for (var iteration = 0; iteration < 16; iteration++) {
          final middle = (low + high) / 2;
          final candidate = _unbounded(middle);
          if (_inside(candidate) && !_insideShield(candidate)) {
            low = middle;
          } else {
            high = middle;
          }
        }
        fraction = low;
        previous = _unbounded(low);
        break;
      }
      previous = point;
    }
    flightFraction = fraction;
    landing = Offset(
      previous.dx.clamp(0.0, geometry.size.width),
      previous.dy.clamp(0.0, geometry.size.height),
    );
  }

  final DavidSlingGeometry geometry;
  final Offset pull;
  late final double flightFraction;
  late final Offset landing;

  Offset _unbounded(double t) =>
      geometry.pouch +
      pull -
      pull * (5 * t) +
      Offset(0, geometry.size.height * .12 * t * t);

  bool _inside(Offset p) =>
      p.dx >= 0 &&
      p.dy >= 0 &&
      p.dx <= geometry.size.width &&
      p.dy <= geometry.size.height;

  bool _insideShield(Offset p) => geometry.obstacles.any(
    (shield) => (p - shield.center).distance < shield.width / 2,
  );

  Offset position(double progress) =>
      _unbounded(progress.clamp(0.0, 1.0) * flightFraction);

  bool get hit => geometry.isHit(landing);
}

/// A bounded battlefield. The parent supplies the full viewport and receives
/// only real landing coordinates after the physical outcome has been shown.
class DavidSlingEngine extends StatefulWidget {
  const DavidSlingEngine({
    required this.level,
    required this.onComplete,
    this.onExit,
    this.audio,
    this.paused = false,
    this.backgroundAsset = 'assets/images/games/david-valley-armies-v3.webp',
    this.goliathAsset = 'assets/images/games/goliath-angry-v2.png',
    this.rigBodyAsset = 'assets/images/games/goliath-body-rig-v3.png',
    super.key,
  });

  final GameLevel level;
  final void Function(Map<String, dynamic>) onComplete;
  final VoidCallback? onExit;
  final DavidBattleAudio? audio;
  final bool paused;
  final String? backgroundAsset;
  final String? goliathAsset;
  final String? rigBodyAsset;

  @override
  State<DavidSlingEngine> createState() => _DavidSlingEngineState();
}

enum _BattlePhase {
  ready,
  aiming,
  flight,
  impact,
  stagger,
  falling,
  fallen,
  miss,
}

class _DavidSlingEngineState extends State<DavidSlingEngine>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late DavidSlingGeometry _geometry;
  late final AnimationController _scene;
  late final Ticker _clock;
  final ValueNotifier<int> _frame = ValueNotifier(0);
  final GoliathSkinMesh _skin = GoliathSkinMesh();
  GoliathMotionModel _motion = GoliathMotionModel();
  Size? _motionSize;
  Duration? _lastFrame;
  ui.Image? _originalSkin;
  ui.Image? _reconstructedSkin;
  String? _loadedSkinKey;
  int _skinGeneration = 0;
  bool _loadingSkin = false;
  bool _skinFailed = false;
  double _actionElapsedMs = 0;
  double? _bodyContactMs;
  double? _settledSinceMs;
  late final DavidBattleAudio _audio;
  final FocusNode _focus = FocusNode(debugLabel: 'David slingshot');
  final List<Offset> _shots = [];
  Offset _pull = Offset.zero;
  Offset _basePull = Offset.zero;
  Offset _armedPull = Offset.zero;
  Offset? _dragStart;
  DavidSlingShot? _shot;
  int? _pointer;
  bool _dragging = false;
  bool _busy = false;
  bool _finished = false;
  bool _foreground = true;
  bool _visible = true;
  bool _reducedMotion = false;
  bool _actionReduced = false;
  bool _controls = false;
  bool _muted = false;
  bool _impactPlayed = false;
  bool _victoryPlayed = false;
  bool? _lastHit;
  double _angle = 0;
  double _power = 0;

  bool get _active => _foreground && _visible && !widget.paused;
  bool get _skinReady =>
      widget.goliathAsset == null ||
      (!_loadingSkin &&
          !_skinFailed &&
          _originalSkin != null &&
          _reconstructedSkin != null);
  bool get _canPlay => _active && _skinReady && !_busy && !_finished;
  int get _flightMs => _actionReduced ? 160 : 850;
  int get _holdMs => 900;
  double get _elapsedMs => _actionElapsedMs;
  bool get _fallen =>
      _shot?.hit == true && _motion.pose.isSettled && _motion.pose.isGrounded;
  _BattlePhase get _phase {
    if (!_busy && !_finished) {
      return _dragging || _pull.dy >= _geometry.minimumPull
          ? _BattlePhase.aiming
          : _lastHit == false
          ? _BattlePhase.miss
          : _BattlePhase.ready;
    }
    if (_elapsedMs < _flightMs) return _BattlePhase.flight;
    if (_shot?.hit != true) return _BattlePhase.miss;
    if (_motion.pose.elapsedSeconds < .1) return _BattlePhase.impact;
    if (_motion.pose.phase == GoliathMotionPhase.reacting ||
        _motion.pose.phase == GoliathMotionPhase.buckling) {
      return _BattlePhase.stagger;
    }
    return _fallen ? _BattlePhase.fallen : _BattlePhase.falling;
  }

  @override
  void initState() {
    super.initState();
    _geometry = DavidSlingGeometry.fromLevel(widget.level);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _audio = widget.audio ?? AssetDavidBattleAudio();
    _scene = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
    _clock = createTicker(_tick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    _loadSkin();
    _syncPlayback();
  }

  void _loadSkin({bool retry = false}) {
    final key = '${widget.goliathAsset}|${widget.rigBodyAsset}';
    if (!retry && _loadedSkinKey == key) return;
    _loadedSkinKey = key;
    final generation = ++_skinGeneration;
    _loadingSkin = widget.goliathAsset != null;
    _skinFailed = false;
    if (!_loadingSkin) return;
    Future<ui.Image> decode(String? asset) async {
      if (asset == null) {
        throw StateError('The articulated character needs both textures.');
      }
      final data = await rootBundle.load(asset);
      final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      try {
        return (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    }

    unawaited(() async {
      ui.Image? original;
      ui.Image? reconstructed;
      try {
        original = await decode(widget.goliathAsset);
        reconstructed = await decode(widget.rigBodyAsset);
        if (!mounted || generation != _skinGeneration) {
          original.dispose();
          reconstructed.dispose();
          return;
        }
        final oldOriginal = _originalSkin;
        final oldReconstructed = _reconstructedSkin;
        setState(() {
          _originalSkin = original;
          _reconstructedSkin = reconstructed;
          _loadingSkin = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          oldOriginal?.dispose();
          oldReconstructed?.dispose();
        });
      } catch (_) {
        original?.dispose();
        reconstructed?.dispose();
        if (mounted && generation == _skinGeneration) {
          setState(() {
            _loadingSkin = false;
            _skinFailed = true;
          });
        }
      }
    }());
  }

  @override
  void didUpdateWidget(covariant DavidSlingEngine oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadSkin();
    if (oldWidget.level.id != widget.level.id) {
      _actionElapsedMs = 0;
      _bodyContactMs = _settledSinceMs = null;
      _motion.reset();
      _motionSize = null;
      _geometry = DavidSlingGeometry.fromLevel(widget.level);
      _shots.clear();
      _pull = Offset.zero;
      _shot = null;
      _busy = _finished = _dragging = false;
      _lastHit = null;
      _angle = _power = 0;
      _impactPlayed = _victoryPlayed = false;
      _frame.value++;
    }
    _syncPlayback();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _cancelPull();
    _syncPlayback();
  }

  void _syncPlayback() {
    _motion.setPaused(!_active);
    if (_active && !_finished) {
      if (!_reducedMotion && !_scene.isAnimating) _scene.repeat();
      if (_reducedMotion) _scene.stop(canceled: false);
      if (!_clock.isActive) {
        _lastFrame = null;
        _clock.start();
      }
    } else {
      _scene.stop(canceled: false);
      _clock.stop();
      _lastFrame = null;
      _cancelPull();
    }
    unawaited(_audio.setActive(_active && !_finished));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ++_skinGeneration;
    _clock.dispose();
    _scene.dispose();
    _frame.dispose();
    _originalSkin?.dispose();
    _reconstructedSkin?.dispose();
    _focus.dispose();
    unawaited(_audio.dispose());
    super.dispose();
  }

  void _tick(Duration elapsed) {
    if (!_active || _finished) {
      _lastFrame = null;
      return;
    }
    final previous = _lastFrame;
    _lastFrame = elapsed;
    if (previous == null) return;
    // A resumed screen supplies no background catch-up, and a foreground
    // hitch cannot request unbounded physics work in a single frame.
    final seconds = ((elapsed - previous).inMicroseconds / 1000000).clamp(
      0.0,
      .25,
    );
    if (!_busy) {
      if (!_reducedMotion) _motion.advance(seconds);
      _frame.value++;
      return;
    }
    final before = _actionElapsedMs;
    _actionElapsedMs += seconds * 1000;
    if (!_impactPlayed && _elapsedMs >= _flightMs) {
      _impactPlayed = true;
      unawaited(_audio.playImpact());
      if (_shot!.hit) {
        final direction =
            (_motionSize?.width ?? 390) / 2 >
                _geometry.target.dx /
                    _geometry.size.width *
                    (_motionSize?.width ?? 390)
            ? 1.0
            : -1.0;
        _motion.strikeHead(direction: direction, strength: 1);
        unawaited(HapticFeedback.mediumImpact());
      }
    }
    if (_shot!.hit && _impactPlayed) {
      final bodySeconds = before >= _flightMs
          ? seconds
          : (_elapsedMs - _flightMs) / 1000;
      _motion.advance(bodySeconds);
      final pose = _motion.pose;
      if (_bodyContactMs == null &&
          pose.elapsedSeconds > .45 &&
          pose.groundContacts.any(
            (joint) => const {
              GoliathJoint.head,
              GoliathJoint.chest,
              GoliathJoint.lumbar,
              GoliathJoint.pelvis,
              GoliathJoint.shield,
              GoliathJoint.leftWrist,
              GoliathJoint.rightWrist,
              GoliathJoint.leftPalm,
            }.contains(joint),
          )) {
        _bodyContactMs = _elapsedMs;
        if (!_victoryPlayed) {
          _victoryPlayed = true;
          unawaited(_audio.playVictory());
        }
      }
      if (pose.isSettled && pose.isGrounded) {
        _settledSinceMs ??= _elapsedMs;
        if (_elapsedMs - _settledSinceMs! >= _holdMs) _finishShot();
      } else {
        _settledSinceMs = null;
      }
    } else if (_elapsedMs >= _flightMs + 230) {
      _finishShot();
    }
    if (mounted) _frame.value++;
  }

  void _finishShot() {
    if (!_active || !_busy || _finished) return;
    final hit = _shot!.hit;
    _busy = false;
    _lastHit = hit;
    _pull = Offset.zero;
    _power = _angle = 0;
    if (hit || _shots.length >= _geometry.maxShots) {
      _finished = true;
      _clock.stop();
      _scene.stop(canceled: false);
      unawaited(_audio.setActive(false));
      widget.onComplete({
        'shots': [
          for (final shot in _shots) {'x': shot.dx, 'y': shot.dy},
        ],
      });
    }
  }

  Rect _actorBounds(Size size) {
    final target = _toRender(_geometry.target, size);
    final height = math.min(size.height * .46, size.width * .78);
    final width = math.min(
      height * .75,
      math.min((target.dx - 8) / .451, (size.width - 8 - target.dx) / .549),
    );
    return Rect.fromLTWH(
      target.dx - width * .451,
      target.dy - width / .75 * .115,
      width,
      width / .75,
    );
  }

  void _configureMotion(Size size) {
    if (_motionSize == size) return;
    final actor = _actorBounds(size);
    _motionSize = size;
    if (!_busy && !_finished) {
      _motion = GoliathMotionModel(
        minimumX: (8 - actor.left) / actor.width,
        maximumX: (size.width - 8 - actor.left) / actor.width,
      )..setPaused(!_active);
    }
  }

  Offset _toCanvas(Offset point, Size size) => Offset(
    point.dx / size.width * _geometry.size.width,
    point.dy / size.height * _geometry.size.height,
  );
  Offset _toRender(Offset point, Size size) => Offset(
    point.dx / _geometry.size.width * size.width,
    point.dy / _geometry.size.height * size.height,
  );

  void _pickup(PointerDownEvent event, Size size) {
    if (!_canPlay || _pointer != null) return;
    final stone = _toRender(_geometry.pouch + _pull, size);
    if ((event.localPosition - stone).distance >
        math.max(32, size.width * .09)) {
      return;
    }
    _pointer = event.pointer;
    _focus.requestFocus();
  }

  void _beginPull(DragStartDetails event, Size size) {
    if (!_canPlay || _pointer == null) return;
    setState(() {
      _dragStart = _toCanvas(event.localPosition, size);
      _basePull = _pull;
      _armedPull = _pull;
      _dragging = true;
      _lastHit = null;
      _shot = null;
    });
  }

  void _movePull(DragUpdateDetails event, Size size) {
    if (!_canPlay || !_dragging || _dragStart == null) return;
    setState(() {
      _pull = _geometry.constrainPull(
        _basePull + _toCanvas(event.localPosition, size) - _dragStart!,
      );
      if (_pull.dy >= _geometry.minimumPull &&
          _pull.distance >= _armedPull.distance) {
        _armedPull = _pull;
      }
      _power = (_pull.distance / _geometry.maximumPull).clamp(0.0, 1.0);
      _angle = _pull == Offset.zero
          ? 0
          : math.atan2(-_pull.dx, _pull.dy) * 180 / math.pi;
    });
  }

  void _cancelPull() {
    _pointer = null;
    _dragStart = null;
    _dragging = false;
    _pull = Offset.zero;
    _armedPull = Offset.zero;
    _power = _angle = 0;
  }

  void _release() {
    _pointer = null;
    if (!_canPlay || _pull.dy < _geometry.minimumPull) {
      setState(_cancelPull);
      return;
    }
    final shot = _geometry.shot(_pull);
    _actionReduced = _reducedMotion;
    setState(() {
      _shot = shot;
      _shots.add(shot.landing);
      _dragging = false;
      _dragStart = null;
      _busy = true;
      _lastHit = null;
      _impactPlayed = _victoryPlayed = false;
      _controls = false;
      _actionElapsedMs = 0;
      _bodyContactMs = _settledSinceMs = null;
    });
    unawaited(_audio.playLaunch());
    unawaited(HapticFeedback.lightImpact());
    _lastFrame = null;
    _frame.value++;
  }

  void _finishPull(DragEndDetails event) {
    // A deliberate forward flick can bring the pouch back toward neutral
    // before finger-up. Retain the real armed direction and power for that
    // launch; a slow return still cancels the shot.
    if (_canPlay &&
        event.velocity.pixelsPerSecond.dy < -450 &&
        _armedPull.dy >= _geometry.minimumPull) {
      _pull = _armedPull;
    }
    _release();
  }

  void _adjust({double? angle, double? power}) {
    if (!_canPlay) return;
    setState(() {
      _angle = (angle ?? _angle).clamp(-48.0, 48.0);
      _power = (power ?? _power).clamp(0.0, 1.0);
      final r = _angle * math.pi / 180;
      _pull = _geometry.constrainPull(
        Offset(
          -math.sin(r) * _power * _geometry.maximumPull,
          math.cos(r) * _power * _geometry.maximumPull,
        ),
      );
      _shot = null;
      _lastHit = null;
    });
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !_canPlay) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      _adjust(angle: _angle - 4);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _adjust(angle: _angle + 4);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _adjust(power: _power + .08);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _adjust(power: _power - .08);
    } else if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.enter) {
      _release();
    } else if (key == LogicalKeyboardKey.escape) {
      setState(_cancelPull);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      assert(
        constraints.hasBoundedWidth && constraints.hasBoundedHeight,
        'DavidSlingEngine needs the complete bounded gameplay viewport.',
      );
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      final safe = MediaQuery.paddingOf(context);
      _configureMotion(size);
      return Focus(
        focusNode: _focus,
        onKeyEvent: _key,
        child: Listener(
          onPointerDown: (event) => _pickup(event, size),
          onPointerCancel: (event) {
            if (event.pointer == _pointer) setState(_cancelPull);
          },
          onPointerUp: (event) {
            if (event.pointer == _pointer && !_dragging) _pointer = null;
          },
          child: GestureDetector(
            key: const Key('sling-board'),
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onPanStart: (event) => _beginPull(event, size),
            onPanUpdate: (event) => _movePull(event, size),
            onPanEnd: (event) {
              if (_dragging) _finishPull(event);
            },
            onPanCancel: () => setState(_cancelPull),
            child: AnimatedBuilder(
              animation: Listenable.merge([_scene, _frame]),
              builder: (context, _) {
                final aim =
                    !_busy && !_finished && _pull.dy >= _geometry.minimumPull
                    ? _geometry.shot(_pull)
                    : null;
                final target = _toRender(_geometry.target, size);
                final actor = _actorBounds(size);
                final ground =
                    actor.top + actor.height * GoliathMotionModel.groundY;
                final pelvis = _motion.pose[GoliathJoint.pelvis];
                final bodyCenter = (actor.left + pelvis.x * actor.width).clamp(
                  0.0,
                  size.width,
                );
                final stone = _toRender(
                  _geometry.pouch + (_busy ? Offset.zero : _pull),
                  size,
                );
                return Stack(
                  clipBehavior: Clip.hardEdge,
                  fit: StackFit.expand,
                  children: [
                    if (widget.backgroundAsset != null)
                      Image.asset(
                        widget.backgroundAsset!,
                        fit: BoxFit.cover,
                        excludeFromSemantics: true,
                      ),
                    CustomPaint(
                      key: const Key('sling-living-battlefield'),
                      painter: _BattlefieldPainter(
                        phase: _scene.value,
                        still: _reducedMotion,
                        ground: ground,
                        target: target,
                        fallback: widget.backgroundAsset == null,
                      ),
                    ),
                    if (_skinReady &&
                        _originalSkin != null &&
                        _reconstructedSkin != null)
                      RepaintBoundary(
                        key: const Key('sling-goliath-mesh'),
                        child: CustomPaint(
                          painter: GoliathMeshPainter(
                            image: _originalSkin!,
                            reconstruction: _reconstructedSkin!,
                            pose: _motion.pose,
                            mesh: _skin,
                            bounds: actor,
                          ),
                        ),
                      ),
                    CustomPaint(
                      key: const Key('sling-foreground'),
                      painter: _BattleForegroundPainter(
                        geometry: _geometry,
                        pull: _busy ? Offset.zero : _pull,
                        aim: aim,
                        shot: _shot,
                        busy: _busy,
                        finished: _finished,
                        elapsedMs: _elapsedMs,
                        flightMs: _flightMs,
                        landedAtMs: _bodyContactMs ?? double.infinity,
                        fallenGround: ground,
                        fallenCenter: bodyCenter,
                        phase: _scene.value,
                        still: _reducedMotion,
                      ),
                    ),
                    Positioned(
                      left: stone.dx - 32,
                      top: stone.dy - 32,
                      width: 64,
                      height: 64,
                      child: IgnorePointer(
                        child: Semantics(
                          key: const Key('sling-stone-pickup'),
                          label:
                              'Stone ready. Pull down and sideways to aim, then release.',
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                    Positioned(
                      top: safe.top + 8,
                      left: math.max(safe.left, 10),
                      child: _BattleIcon(
                        key: const Key('sling-exit'),
                        icon: Icons.close_rounded,
                        tooltip: 'Leave battlefield',
                        onPressed: widget.onExit,
                      ),
                    ),
                    Positioned(
                      top: safe.top + 8,
                      right: math.max(safe.right, 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _BattleIcon(
                            key: const Key('sling-sound'),
                            icon: _muted
                                ? Icons.volume_off_rounded
                                : Icons.volume_up_rounded,
                            tooltip: _muted ? 'Turn sound on' : 'Mute sound',
                            onPressed: () {
                              setState(() => _muted = !_muted);
                              unawaited(_audio.setMuted(_muted));
                            },
                          ),
                          const SizedBox(width: 5),
                          _BattleIcon(
                            key: const Key('sling-toggle-controls'),
                            icon: Icons.tune_rounded,
                            tooltip: 'Aim controls',
                            onPressed: _finished
                                ? null
                                : () => setState(() => _controls = !_controls),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      top: safe.top + 20,
                      left: 72,
                      right: 120,
                      child: Semantics(
                        key: const Key('sling-stones'),
                        label:
                            '${_geometry.maxShots - _shots.length} stones remaining',
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (var i = 0; i < _geometry.maxShots; i++)
                              Container(
                                width: 13,
                                height: 13,
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 3,
                                ),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: i < _geometry.maxShots - _shots.length
                                      ? const Color(0xFFEEE9DC)
                                      : const Color(0x558D8D85),
                                  border: Border.all(
                                    color: const Color(0xFF606868),
                                    width: 1,
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
                      bottom: safe.bottom + 13,
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 180),
                          opacity: _busy || _finished ? 0 : 1,
                          child: Text(
                            _lastHit == false
                                ? 'Try again — pull back to aim.'
                                : _pull.dy >= _geometry.minimumPull
                                ? 'Let go to launch'
                                : 'Pull back the stone',
                            key: const Key('sling-live-status'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF563A22),
                              shadows: [
                                Shadow(color: Color(0xFFFFEDD0), blurRadius: 4),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Semantics(
                          liveRegion: true,
                          label: 'Battle phase: ${_phase.name}',
                          child: SizedBox(
                            key: ValueKey('sling-phase-${_phase.name}'),
                          ),
                        ),
                      ),
                    ),
                    if (!_skinReady)
                      Center(
                        child: Material(
                          color: const Color(0xEEFFF8DE),
                          borderRadius: BorderRadius.circular(18),
                          child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: _skinFailed
                                ? Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Text(
                                        'The battlefield could not load.',
                                      ),
                                      TextButton(
                                        key: const Key('sling-retry-skin'),
                                        onPressed: () => setState(
                                          () => _loadSkin(retry: true),
                                        ),
                                        child: const Text('Try again'),
                                      ),
                                    ],
                                  )
                                : const Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: 28,
                                        height: 28,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 3,
                                        ),
                                      ),
                                      SizedBox(height: 10),
                                      Text('Getting the battlefield ready…'),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                    if (_controls) _controlPanel(safe),
                  ],
                );
              },
            ),
          ),
        ),
      );
    },
  );

  Widget _controlPanel(EdgeInsets safe) => Positioned(
    top: safe.top + 64,
    left: math.max(safe.left + 12, 12),
    right: math.max(safe.right + 12, 12),
    child: Material(
      color: const Color(0xF7FFFFF6),
      elevation: 8,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Choose your aim and power',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            Row(
              children: [
                const SizedBox(width: 44, child: Text('Aim')),
                Expanded(
                  child: Slider(
                    key: const Key('sling-angle'),
                    value: _angle.clamp(-48.0, 48.0),
                    min: -48,
                    max: 48,
                    divisions: 48,
                    label: '${_angle.round()}°',
                    semanticFormatterCallback: (v) => '${v.round()} degrees',
                    onChanged: _canPlay ? (v) => _adjust(angle: v) : null,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 44, child: Text('Power')),
                Expanded(
                  child: Slider(
                    key: const Key('sling-power'),
                    value: _power,
                    min: 0,
                    max: 1,
                    divisions: 50,
                    label: '${(_power * 100).round()}%',
                    semanticFormatterCallback: (v) =>
                        '${(v * 100).round()} percent power',
                    onChanged: _canPlay ? (v) => _adjust(power: v) : null,
                  ),
                ),
              ],
            ),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('sling-release'),
                onPressed: _canPlay && _pull.dy >= _geometry.minimumPull
                    ? _release
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFB65B2A),
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.bolt_rounded),
                label: const Text('Launch stone'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _BattleIcon extends StatelessWidget {
  const _BattleIcon({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xBFFFFFF5),
    shape: const CircleBorder(),
    child: IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 22),
      color: const Color(0xFF59492E),
      onPressed: onPressed,
    ),
  );
}

/// Cloth is a deformed vertex mesh: its pole edge is fixed while wind travels
/// across every strip. This is independent of the static landscape artwork.
class _BattlefieldPainter extends CustomPainter {
  const _BattlefieldPainter({
    required this.phase,
    required this.still,
    required this.ground,
    required this.target,
    required this.fallback,
  });
  final double phase;
  final bool still;
  final double ground;
  final Offset target;
  final bool fallback;
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (fallback) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF9CDCF0), Color(0xFFE4F1C5), Color(0xFFE9BB75)],
          ).createShader(Offset.zero & size),
      );
      final hill = Path()
        ..moveTo(0, h * .44)
        ..quadraticBezierTo(w * .22, h * .27, w * .5, h * .48)
        ..quadraticBezierTo(w * .77, h * .30, w, h * .43)
        ..lineTo(w, h)
        ..lineTo(0, h)
        ..close();
      canvas.drawPath(hill, Paint()..color = const Color(0xFF8EAF75));
      final road = Path()
        ..moveTo(w * .42, h * .47)
        ..lineTo(w * .07, h)
        ..lineTo(w * .94, h)
        ..lineTo(w * .57, h * .47)
        ..close();
      canvas.drawPath(road, Paint()..color = const Color(0xFFEAD0A1));
    }
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(target.dx, ground - 4),
        width: w * .30,
        height: w * .04,
      ),
      Paint()..color = const Color(0xFF76583A).withValues(alpha: .2),
    );
    _flag(
      canvas,
      Offset(w * .073, h * .36),
      w * .19,
      w * .095,
      h * .16,
      const Color(0xFF467DC0),
      1,
    );
    _flag(
      canvas,
      Offset(w * .92, h * .36),
      w * .19,
      w * .095,
      h * .16,
      const Color(0xFFBC5D31),
      -1,
    );
    if (!still) {
      for (var i = 0; i < 15; i++) {
        final x = ((i * .073 + phase * .22) % 1) * w;
        final y =
            h * (.60 + (i % 5) * .061) + math.sin(phase * math.pi * 2 + i) * 6;
        canvas.drawOval(
          Rect.fromCenter(center: Offset(x, y), width: 2 + i % 3, height: 1.3),
          Paint()
            ..color = const Color(
              0xFFFFE6B4,
            ).withValues(alpha: .18 + (i % 3) * .08),
        );
      }
    }
  }

  void _flag(
    Canvas canvas,
    Offset pole,
    double width,
    double height,
    double poleHeight,
    Color color,
    double direction,
  ) {
    canvas.drawLine(
      pole - const Offset(0, 7),
      pole + Offset(0, poleHeight),
      Paint()
        ..color = const Color(0xFF765435)
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(
      pole - const Offset(0, 9),
      3.7,
      Paint()..color = const Color(0xFFE7C975),
    );
    Offset vertex(double u, double v) {
      final wave = still
          ? math.sin(u * 4) * .05
          : math.sin(phase * math.pi * 4 - u * 6.4 + v * .5) * .20;
      return pole +
          Offset(direction * (u * width), v * height + wave * height * u);
    }

    for (var x = 0; x < 14; x++) {
      for (var y = 0; y < 4; y++) {
        final u = x / 14;
        final v = y / 4;
        final cloth = Path()
          ..moveTo(vertex(u, v).dx, vertex(u, v).dy)
          ..lineTo(vertex(u + 1 / 14, v).dx, vertex(u + 1 / 14, v).dy)
          ..lineTo(
            vertex(u + 1 / 14, v + .25).dx,
            vertex(u + 1 / 14, v + .25).dy,
          )
          ..lineTo(vertex(u, v + .25).dx, vertex(u, v + .25).dy)
          ..close();
        final shade = still
            ? .5
            : (math.cos(phase * math.pi * 4 - u * 6.4) + 1) / 2;
        canvas.drawPath(
          cloth,
          Paint()
            ..color = Color.lerp(
              color.withValues(alpha: 1),
              Color.lerp(color, Colors.white, .22),
              shade,
            )!,
        );
      }
    }
    final stripe = Path();
    for (var i = 0; i <= 28; i++) {
      final p = vertex(i / 28, .78);
      i == 0 ? stripe.moveTo(p.dx, p.dy) : stripe.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      stripe,
      Paint()
        ..color = const Color(0xFFF6D27B)
        ..strokeWidth = height * .07
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _BattlefieldPainter oldDelegate) => true;
}

class _BattleForegroundPainter extends CustomPainter {
  const _BattleForegroundPainter({
    required this.geometry,
    required this.pull,
    required this.aim,
    required this.shot,
    required this.busy,
    required this.finished,
    required this.elapsedMs,
    required this.flightMs,
    required this.landedAtMs,
    required this.fallenGround,
    required this.fallenCenter,
    required this.phase,
    required this.still,
  });
  final DavidSlingGeometry geometry;
  final Offset pull;
  final DavidSlingShot? aim;
  final DavidSlingShot? shot;
  final bool busy;
  final bool finished;
  final double elapsedMs;
  final int flightMs;
  final double landedAtMs;
  final double fallenGround;
  final double fallenCenter;
  final double phase;
  final bool still;
  @override
  void paint(Canvas canvas, Size size) {
    Offset point(Offset p) => Offset(
      p.dx / geometry.size.width * size.width,
      p.dy / geometry.size.height * size.height,
    );
    for (final shield in geometry.obstacles) {
      _shield(
        canvas,
        point(shield.center),
        shield.width / geometry.size.width * size.width * .46,
      );
    }
    if (aim != null) {
      for (var i = 1; i <= 20; i++) {
        final t = i / 20;
        canvas.drawCircle(
          point(aim!.position(t)),
          2.6 - t,
          Paint()..color = Colors.white.withValues(alpha: .9 - t * .3),
        );
      }
      final landing = point(aim!.landing);
      final ring = Paint()
        ..color = const Color(0xFFFFF8CF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8;
      canvas.drawCircle(landing, 7, ring);
      canvas.drawLine(
        landing - const Offset(11, 0),
        landing + const Offset(11, 0),
        ring,
      );
      canvas.drawLine(
        landing - const Offset(0, 11),
        landing + const Offset(0, 11),
        ring,
      );
      final power = (pull.distance / geometry.maximumPull).clamp(0.0, 1.0);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            size.width - 22,
            size.height * .67,
            5,
            size.height * .16,
          ),
          const Radius.circular(4),
        ),
        Paint()..color = const Color(0x553D311F),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            size.width - 22,
            size.height * (.83 - .16 * power),
            5,
            size.height * .16 * power,
          ),
          const Radius.circular(4),
        ),
        Paint()..color = const Color(0xFFFFCE69),
      );
    }
    if (shot != null && (busy || finished)) {
      final flight = (elapsedMs / flightMs).clamp(0.0, 1.0);
      if (flight < 1) {
        final p = point(shot!.position(flight));
        final tail = point(shot!.position(math.max(0, flight - .045)));
        canvas.drawLine(
          tail,
          p,
          Paint()
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round
            ..color = Colors.white.withValues(alpha: .7),
        );
        _stone(canvas, p, 11 - flight * 7);
      } else if (elapsedMs < flightMs + 220) {
        _impact(
          canvas,
          point(shot!.landing),
          (elapsedMs - flightMs) / 220,
          shot!.hit,
        );
      }
    }
    final dustAge = elapsedMs - landedAtMs;
    if (shot?.hit == true && dustAge >= -100 && dustAge < 560) {
      final burst = ((dustAge + 100) / 100).clamp(0.0, 1.0);
      final decay = (dustAge / 560).clamp(0.0, 1.0);
      final opacity = burst * math.pow(1 - decay, 1.4);
      for (var i = 0; i < 9; i++) {
        final spread = size.width * .079 * (1 + decay * .35);
        final x = fallenCenter + (i - 4) * spread;
        final y = fallenGround - 38 * burst - decay * 34 - (i % 3) * 8;
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(x, y),
            width: 56 + burst * 25 + decay * 20,
            height: 24 + burst * 90 + decay * 20,
          ),
          Paint()
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7)
            ..color = const Color(0xFFE7C38F).withValues(alpha: .64 * opacity),
        );
      }
    }
    final pouch = point(geometry.pouch + pull);
    if (!busy && !finished && pull == Offset.zero) {
      canvas.drawCircle(
        pouch,
        25 + (still ? 0 : math.sin(phase * math.pi * 4) * 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = const Color(0xFFFFEDB1).withValues(alpha: .7),
      );
    }
    canvas.save();
    if (shot?.hit == true && elapsedMs >= flightMs) {
      final retract = ((elapsedMs - flightMs) / 600).clamp(0.0, 1.0);
      canvas.translate(0, size.height * .25 * Curves.easeIn.transform(retract));
    }
    _fork(
      canvas,
      size,
      point(geometry.pouch),
      point(geometry.pouch + pull),
      busy || finished,
    );
    canvas.restore();
  }

  void _fork(Canvas canvas, Size size, Offset p, Offset pouch, bool launched) {
    final w = size.width;
    final left = p + Offset(-w * .16, -w * .10);
    final right = p + Offset(w * .16, -w * .10);
    final join = p + Offset(0, w * .10);
    final grip = p + Offset(0, w * .27);
    for (final tip in [left, right]) {
      final wood = Path()
        ..moveTo(tip.dx, tip.dy)
        ..quadraticBezierTo(tip.dx, join.dy - w * .06, join.dx, join.dy)
        ..lineTo(grip.dx, grip.dy);
      canvas.drawPath(
        wood,
        Paint()
          ..color = const Color(0xFF75401F)
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * .055
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      canvas.drawPath(
        wood,
        Paint()
          ..color = const Color(0xFFC78B4C)
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * .036
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      canvas.drawPath(
        wood.shift(Offset(-w * .007, 0)),
        Paint()
          ..color = const Color(0xFFE3AF70)
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * .007
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
    final band = Paint()
      ..color = const Color(0xFF69452F)
      ..strokeWidth = w * .014
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(left, pouch, band);
    canvas.drawLine(right, pouch, band);
    for (final tip in [left, right]) {
      canvas.drawLine(
        tip - const Offset(0, 3),
        pouch - const Offset(0, 3),
        Paint()
          ..color = const Color(0xFFC8A56F)
          ..strokeWidth = w * .005,
      );
      canvas.drawLine(
        tip - const Offset(0, 4),
        tip + const Offset(0, 4),
        Paint()
          ..color = const Color(0xFF9A714A)
          ..strokeWidth = w * .062
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: pouch, width: w * .095, height: w * .047),
        const Radius.circular(7),
      ),
      Paint()..color = const Color(0xFF5B3F2E),
    );
    if (!launched) _stone(canvas, pouch, w * .037);
    for (var i = 0; i < 6; i++) {
      final y = p.dy + w * (.15 + i * .015);
      canvas.drawLine(
        Offset(grip.dx - w * .025, y),
        Offset(grip.dx + w * .025, y + 3),
        Paint()
          ..color = const Color(0xFF905D3A)
          ..strokeWidth = w * .01,
      );
    }
  }

  void _stone(Canvas canvas, Offset p, double r) {
    canvas.drawCircle(
      p + Offset(r * .1, r * .15),
      r,
      Paint()..color = const Color(0x55313B42),
    );
    canvas.drawCircle(
      p,
      r,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-.4, -.5),
          colors: [Color(0xFFE1E6E6), Color(0xFF747F86)],
        ).createShader(Rect.fromCircle(center: p, radius: r)),
    );
    canvas.drawCircle(
      p - Offset(r * .25, r * .27),
      r * .20,
      Paint()..color = const Color(0xAAFFFFFF),
    );
  }

  void _shield(Canvas canvas, Offset p, double r) {
    final shield = Path()
      ..moveTo(p.dx - r * .76, p.dy - r)
      ..lineTo(p.dx + r * .76, p.dy - r)
      ..quadraticBezierTo(p.dx + r, p.dy + r * .32, p.dx, p.dy + r)
      ..quadraticBezierTo(p.dx - r, p.dy + r * .32, p.dx - r * .76, p.dy - r)
      ..close();
    canvas.drawPath(shield, Paint()..color = const Color(0xFFC77D43));
    canvas.drawPath(
      shield,
      Paint()
        ..color = const Color(0xFFF3D183)
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * .10,
    );
    canvas.drawCircle(p, r * .20, Paint()..color = const Color(0xFFF3D183));
  }

  void _impact(Canvas canvas, Offset p, double t, bool hit) {
    final paint = Paint()
      ..color = (hit ? const Color(0xFFFFD265) : const Color(0xFFF3D8A7))
          .withValues(alpha: 1 - t)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(p, 5 + t * 25, paint);
    for (var i = 0; i < 7; i++) {
      final direction = Offset(
        math.cos(i / 7 * math.pi * 2),
        math.sin(i / 7 * math.pi * 2),
      );
      canvas.drawLine(
        p + direction * (8 + t * 9),
        p + direction * (13 + t * 20),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BattleForegroundPainter oldDelegate) => true;
}

Map<String, dynamic> _map(Object? value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : const {};
double _number(Object? value, double fallback) =>
    value is num && value.isFinite ? value.toDouble() : fallback;

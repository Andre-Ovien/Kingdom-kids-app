import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../domain/mini_game.dart';
import '../domain/wise_builders_model.dart';

class WiseBuildersEngine extends StatefulWidget {
  const WiseBuildersEngine({
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
  final Future<Map<String, ui.Image>> Function()? graphicsLoader;
  @override
  State<WiseBuildersEngine> createState() => _WiseBuildersEngineState();
}

class _WiseBuildersEngineState extends State<WiseBuildersEngine>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final WiseBuildersModel _world;
  late final AnimationController _storm;
  final _elapsed = Stopwatch();
  final Map<String, ui.Image> _art = {};
  String _active = 'house-a',
      _message = 'Choose a house, then choose its foundation.';
  String? _selected;
  bool _loading = true,
      _error = false,
      _stormStarted = false,
      _submitted = false;
  bool _foreground = true;
  bool get _isPaused => widget.paused || !_foreground;
  bool get _animationsEnabled {
    final media = MediaQuery.maybeOf(context);
    return !(media?.disableAnimations ?? false) &&
        !(media?.accessibleNavigation ?? false);
  }

  void _syncRunState() {
    if (_isPaused || _submitted || _loading) {
      _elapsed.stop();
      _storm.stop();
    } else {
      _elapsed.start();
      if (_stormStarted && _storm.value < 1) {
        if (!_animationsEnabled) {
          _storm.value = 1;
        } else {
          _storm.forward();
        }
      }
    }
  }

  @override
  void didUpdateWidget(covariant WiseBuildersEngine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paused != widget.paused) {
      _syncRunState();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncRunState();
  }

  static const _root = 'assets/images/games/wise_builders';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _world = WiseBuildersModel.fromConfig(widget.level.config);
    _active = _world.houses.first.id;
    _storm = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    );
    _storm.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(
          () => _message = _world.complete
              ? 'The house on rock stood strong. The sand washed away beneath the other house.'
              : 'Try one rock foundation and one sand foundation to compare them.',
        );
      }
    });
    _load();
  }

  Future<void> _load() async {
    var memory = 0;
    try {
      if (widget.graphicsLoader != null) {
        final images = await widget.graphicsLoader!();
        if (!mounted) {
          for (final image in images.values.toSet()) {
            image.dispose();
          }
          return;
        }
        _art.addAll(images);
        setState(() {
          _loading = false;
          _error = false;
        });
        _syncRunState();
        return;
      }
      for (final kind in [
        'background',
        'rock',
        'sand',
        ..._world.requiredParts,
        'standing',
        'collapse',
        'storm',
      ]) {
        final asset = kind == 'storm' ? 'storm-${_world.storm}' : kind;
        final bytes = await rootBundle.load('$_root/$asset.png');
        final buffer = await ui.ImmutableBuffer.fromUint8List(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
        ui.ImageDescriptor? descriptor;
        ui.Codec? codec;
        try {
          descriptor = await ui.ImageDescriptor.encoded(buffer);
          memory += descriptor.width * descriptor.height * 4;
          if (memory > 36 * 1024 * 1024 ||
              descriptor.width > 4096 ||
              descriptor.height > 4096) {
            throw const FormatException('Builders artwork exceeds its budget.');
          }
          codec = await descriptor.instantiateCodec();
          final image = (await codec.getNextFrame()).image;
          if (!mounted) {
            image.dispose();
            return;
          }
          _art[kind] = image;
        } finally {
          codec?.dispose();
          descriptor?.dispose();
          buffer.dispose();
        }
      }
      if (mounted) {
        setState(() {
          _loading = false;
          _error = false;
        });
      }
      _syncRunState();
    } catch (_) {
      for (final image in _art.values.toSet()) {
        image.dispose();
      }
      _art.clear();
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncRunState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _elapsed.stop();
    _storm.dispose();
    for (final image in _art.values.toSet()) {
      image.dispose();
    }
    _art.clear();
    super.dispose();
  }

  void _place(String house, String part) {
    if (_isPaused || _storm.isAnimating || _submitted) return;
    setState(() {
      if (_world.place(house, part)) {
        _selected = null;
        _active = house;
        _message = 'Keep building. Four walls support the roof.';
        HapticFeedback.selectionClick();
      } else {
        _message =
            'Choose a foundation first. The roof and brace need all four walls.';
      }
    });
  }

  void _test() {
    if (_isPaused || _submitted) return;
    if (!_world.testStorm()) return;
    setState(() {
      _stormStarted = true;
      _selected = null;
      _message =
          'Watch the foundations as the ${_world.storm.replaceAll('_', ' ')} arrives.';
    });
    if (!_animationsEnabled) {
      _storm.value = 1;
    } else {
      _storm.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('The builders artwork is still getting ready.'),
            TextButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );
    }
    final active = _world.house(_active);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final targets = {
          for (var i = 0; i < _world.houses.length; i++)
            _world.houses[i].id: Rect.fromLTWH(
              size.width * (i == 0 ? .02 : .51),
              size.height * .32,
              size.width * .47,
              size.width * .52,
            ),
        };
        return Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _BuildersPainter(
                    _art,
                    _world,
                    targets,
                    _storm,
                    _active,
                    _stormStarted,
                  ),
                ),
              ),
            ),
            for (final h in _world.houses)
              Positioned.fromRect(
                rect: targets[h.id]!,
                child: DragTarget<String>(
                  onWillAcceptWithDetails: (d) =>
                      !_isPaused &&
                      !_storm.isAnimating &&
                      !_submitted &&
                      _world.canPlace(h.id, d.data),
                  onAcceptWithDetails: (d) => _place(h.id, d.data),
                  builder: (_, _, _) => GestureDetector(
                    onTap: () {
                      if (_isPaused || _storm.isAnimating || _submitted) return;
                      if (_selected != null) {
                        _place(h.id, _selected!);
                        return;
                      }
                      setState(() => _active = h.id);
                    },
                    behavior: HitTestBehavior.opaque,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            Positioned(
              top: 12,
              left: 18,
              right: 18,
              child: SafeArea(
                bottom: false,
                child: Column(
                  children: [
                    if (widget.onExit != null)
                      Align(
                        alignment: Alignment.topLeft,
                        child: IconButton(
                          tooltip: 'Leave building',
                          onPressed: widget.onExit,
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                    const Text(
                      'The Wise and Foolish Builders',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF403320),
                      ),
                    ),
                    const SizedBox(height: 7),
                    const Text(
                      'Build two houses. Find out what stands strong.',
                      textAlign: TextAlign.center,
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final h in _world.houses)
                          Padding(
                            padding: const EdgeInsets.all(5),
                            child: ChoiceChip(
                              label: Text(h.label),
                              selected: _active == h.id,
                              onSelected: _isPaused || _storm.isAnimating
                                  ? null
                                  : (_) => setState(() => _active = h.id),
                            ),
                          ),
                      ],
                    ),
                    if (!_stormStarted)
                      Wrap(
                        spacing: 10,
                        children: [
                          for (final material in ['rock', 'sand'])
                            ActionChip(
                              avatar: SizedBox(
                                width: 27,
                                height: 27,
                                child: RawImage(image: _art[material]),
                              ),
                              label: Text(
                                '${material[0].toUpperCase()}${material.substring(1)} foundation',
                              ),
                              onPressed:
                                  active.parts.isEmpty &&
                                      !_submitted &&
                                      !_isPaused
                                  ? () {
                                      setState(() {
                                        _world.foundation(_active, material);
                                        _message =
                                            'Now add walls to ${active.label.toLowerCase()}.';
                                      });
                                    }
                                  : null,
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            Positioned(
              bottom: 14,
              left: 18,
              right: 18,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF403320),
                      ),
                    ),
                    const SizedBox(height: 9),
                    if (!_stormStarted &&
                        (active.parts.isNotEmpty || active.foundation != null))
                      TextButton.icon(
                        onPressed: _isPaused || _submitted
                            ? null
                            : () {
                                setState(() {
                                  _world.reset(_active);
                                  _selected = null;
                                  _message =
                                      'Choose a new foundation for ${active.label.toLowerCase()}.';
                                });
                              },
                        icon: const Icon(Icons.undo_rounded),
                        label: const Text('Rebuild this house'),
                      ),
                    if (!_stormStarted)
                      Container(
                        height: 91,
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .91),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (final part in _world.requiredParts.where(
                              (p) => !active.parts.contains(p),
                            ))
                              Draggable<String>(
                                data: part,
                                feedback: SizedBox(
                                  width: 100,
                                  height: 100,
                                  child: RawImage(image: _art[part]),
                                ),
                                child: GestureDetector(
                                  onTap: _isPaused || _submitted
                                      ? null
                                      : () => setState(() => _selected = part),
                                  child: Container(
                                    width: 76,
                                    decoration: BoxDecoration(
                                      color: _selected == part
                                          ? const Color(0xFFFFDEA2)
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                    child: Column(
                                      children: [
                                        Expanded(
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 3,
                                            ),
                                            child: RawImage(
                                              image: _art[part],
                                              fit: BoxFit.contain,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          part.replaceAll('-', ' '),
                                          maxLines: 2,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 9),
                    if (!_stormStarted)
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
                        onPressed: _world.canStorm && !_isPaused ? _test : null,
                        icon: const Icon(Icons.thunderstorm_rounded),
                        label: const Text('Test the storm'),
                      ),
                    if (_stormStarted && !_storm.isAnimating)
                      Wrap(
                        spacing: 9,
                        children: [
                          TextButton.icon(
                            onPressed: _submitted || _isPaused
                                ? null
                                : () {
                                    setState(() {
                                      for (final h in _world.houses) {
                                        _world.reset(h.id);
                                      }
                                      _stormStarted = false;
                                      _storm.reset();
                                      _message =
                                          'Try another foundation or build a different house.';
                                    });
                                  },
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Build again'),
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
                                        _world.submission(
                                          _elapsed.elapsed.inSeconds,
                                        ),
                                      );
                                    },
                              icon: const Icon(Icons.check_circle_rounded),
                              label: const Text('Finish discovery'),
                            ),
                        ],
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
}

class _BuildersPainter extends CustomPainter {
  _BuildersPainter(
    this.art,
    this.world,
    this.targets,
    this.storm,
    this.active,
    this.started,
  ) : super(repaint: storm);
  final Map<String, ui.Image> art;
  final WiseBuildersModel world;
  final Map<String, Rect> targets;
  final Animation<double> storm;
  final String active;
  final bool started;
  void draw(
    Canvas canvas,
    String kind,
    Rect target, {
    int frame = 0,
    int frames = 1,
    double opacity = 1,
  }) {
    final texture = art[kind];
    if (texture == null) return;
    final width = texture.width / frames;
    canvas.drawImageRect(
      texture,
      Rect.fromLTWH(width * frame, 0, width, texture.height.toDouble()),
      target,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Colors.white.withValues(alpha: opacity),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    draw(canvas, 'background', Offset.zero & size);
    if (started) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..color = const Color(
            0xFF182A46,
          ).withValues(alpha: .22 * storm.value),
      );
    }
    for (final h in world.houses) {
      final target = targets[h.id]!;
      if (h.foundation != null && !(started && h.foundation == 'sand')) {
        draw(canvas, h.foundation!, target);
      }
      if (started) {
        if (h.foundation == 'sand') {
          draw(
            canvas,
            'collapse',
            target,
            frame: (storm.value * 11).floor().clamp(0, 11),
            frames: 12,
          );
        } else {
          draw(canvas, 'standing', target);
        }
        if (storm.value > 0 && storm.value < 1) {
          draw(
            canvas,
            'storm',
            target,
            frame: (storm.value * 48).floor() % 8,
            frames: 8,
            opacity: .85,
          );
        }
      } else {
        draw(canvas, 'standing', target, opacity: .13);
        for (final part in [
          'back-wall',
          'left-wall',
          'right-wall',
          'front-wall',
          'roof',
          'brace',
        ]) {
          if (h.parts.contains(part)) draw(canvas, part, target);
        }
      }
      if (h.id == active && !started) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(target.deflate(7), const Radius.circular(28)),
          Paint()
            ..color = const Color(0xFFF6C964)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
      final text = TextPainter(
        text: TextSpan(
          text: h.foundation == null
              ? 'Choose a foundation'
              : h.foundation == 'rock'
              ? 'Solid rock'
              : 'Soft sand',
          style: const TextStyle(
            fontSize: 14,
            fontFamily: 'Avenir Next',
            color: Color(0xFF403320),
            fontWeight: FontWeight.w800,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(
        canvas,
        Offset(target.center.dx - text.width / 2, target.bottom + 6),
      );
    }
  }

  @override
  bool shouldRepaint(_BuildersPainter old) => true;
}

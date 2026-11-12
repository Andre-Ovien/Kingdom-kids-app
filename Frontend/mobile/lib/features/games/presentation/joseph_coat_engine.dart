import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/audio/app_audio_controller.dart';
import '../../../shared/audio/app_audio_scope.dart';
import '../../../shared/audio/app_sound_cue.dart';
import '../domain/joseph_coat.dart';
import '../domain/mini_game.dart';

const _ink = Color(0xFF224A3B);
const _cream = Color(0xFFFFF7E8);
const _gold = Color(0xFFD6A34D);

/// A live, stitched-cloth coat, rather than a picture hidden behind a grid.
/// The same six shapes are used for painting, clipping, drag and tap targets.
class JosephCoatEngine extends StatefulWidget {
  const JosephCoatEngine({
    required this.level,
    required this.onComplete,
    this.onExit,
    this.paused = false,
    super.key,
  });

  final GameLevel level;
  final ValueChanged<Map<String, dynamic>> onComplete;
  final VoidCallback? onExit;
  final bool paused;

  @override
  State<JosephCoatEngine> createState() => _JosephCoatEngineState();
}

class _JosephCoatEngineState extends State<JosephCoatEngine>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  JosephCoatRun? _run;
  String? _selected;
  String? _hovered;
  String? _recent;
  String? _wrong;
  bool _sent = false;
  bool _foreground = true;
  bool _resumeStitch = false;
  bool _resumeReveal = false;
  AppAudioController? _audioOwner;
  MatchingGameFeedback? _feedback;
  late final AnimationController _stitch = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
    animationBehavior: AnimationBehavior.preserve,
  );
  late final AnimationController _reveal =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1900),
        animationBehavior: AnimationBehavior.preserve,
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed && !_blocked) _submit();
      });

  bool get _blocked => widget.paused || !_foreground;
  bool get _reduced => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  void _load() {
    try {
      _run = JosephCoatRun(widget.level.config);
    } on FormatException {
      _run = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final owner = AppAudioScope.maybeOf(context);
    if (!identical(owner, _audioOwner)) {
      _feedback?.dispose();
      _audioOwner = owner;
      _feedback = owner?.createMatchingFeedback(paused: _blocked || _sent);
    }
  }

  @override
  void didUpdateWidget(covariant JosephCoatEngine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.level.id != widget.level.id) {
      _stitch.reset();
      _reveal.reset();
      _selected = _hovered = _recent = _wrong = null;
      _sent = _resumeStitch = _resumeReveal = false;
      _load();
    }
    _syncPause();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncPause();
    if (mounted) setState(() {});
  }

  void _syncPause() {
    _feedback?.setPaused(_blocked || _sent);
    if (_blocked) {
      _resumeStitch = _resumeStitch || _stitch.isAnimating;
      _resumeReveal = _resumeReveal || _reveal.isAnimating;
      _stitch.stop(canceled: false);
      _reveal.stop(canceled: false);
    } else {
      if (_resumeStitch) _stitch.forward();
      if (_resumeReveal) _reveal.forward();
      _resumeStitch = _resumeReveal = false;
      if (_reveal.isCompleted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_blocked) _submit();
        });
      }
    }
  }

  void _cue(AppSoundCue cue) {
    _feedback?.play(cue);
  }

  void _choose(CoatFabric cloth) {
    if (_blocked || _run == null || _run!.isComplete || _sent) return;
    HapticFeedback.selectionClick();
    _cue(AppSoundCue.select);
    setState(() {
      _selected = _selected == cloth.id ? null : cloth.id;
      _wrong = null;
    });
  }

  void _place(String panel, String swatch) {
    if (_blocked || _sent || _run == null) return;
    final result = _run!.place(panel, swatch);
    if (result == CoatPlacement.ignored) return;
    setState(() {
      _hovered = null;
      _recent = result == CoatPlacement.correct ? panel : null;
      _wrong = result == CoatPlacement.wrong ? panel : null;
      if (result == CoatPlacement.correct) _selected = null;
    });
    _stitch.forward(from: 0);
    if (result == CoatPlacement.correct) {
      HapticFeedback.lightImpact();
      _cue(AppSoundCue.select);
      if (_run!.isComplete) {
        _cue(AppSoundCue.success);
        _reveal.forward(from: 0);
      }
    } else {
      HapticFeedback.selectionClick();
      if (_run!.exhausted) _submit();
    }
  }

  void _submit() {
    if (_sent || _blocked || _run == null) return;
    _sent = true;
    _feedback?.setPaused(true);
    widget.onComplete(_run!.result);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stitch.dispose();
    _reveal.dispose();
    _feedback?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final run = _run;
    if (run == null) {
      return ColoredBox(
        color: _cream,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Text(
              'This coat is being prepared. Try another round.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
      );
    }
    return TickerMode(
      enabled: !_blocked,
      child: ColoredBox(
        key: const Key('joseph-coat-game'),
        color: _cream,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxHeight < 620;
              final dockHeight = compact ? 148.0 : 174.0;
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    children: [
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          18,
                          compact ? 4 : 12,
                          18,
                          4,
                        ),
                        child: Row(
                          children: [
                            if (widget.onExit != null) ...[
                              _ExitButton(onTap: widget.onExit!),
                              const SizedBox(width: 12),
                            ],
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    "JOSEPH’S",
                                    maxLines: 1,
                                    style: TextStyle(
                                      color: _ink.withValues(alpha: .65),
                                      fontSize: compact ? 10 : 11,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 2.2,
                                    ),
                                  ),
                                  Text(
                                    'Coat Studio',
                                    maxLines: 1,
                                    style: TextStyle(
                                      color: _ink,
                                      fontSize: compact ? 26 : 31,
                                      height: 1.12,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: -1,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Semantics(
                              label: '${run.matched} of 6 patches sewn',
                              child: ExcludeSemantics(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 11,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: .7),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: const Color(0xFFE4D9BF),
                                    ),
                                  ),
                                  child: Text(
                                    '${run.matched} / 6',
                                    key: const Key('coat-progress'),
                                    style: const TextStyle(
                                      color: _ink,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: AnimatedBuilder(
                            animation: Listenable.merge([_stitch, _reveal]),
                            builder: (context, _) => _workshop(run, compact),
                          ),
                        ),
                      ),
                      SizedBox(
                        height: compact ? 27 : 34,
                        child: Center(
                          child: Text(
                            run.isComplete
                                ? 'Made with love. Made by you!'
                                : _selected == null
                                ? 'Find the same colour + pattern'
                                : 'Now tap its patch on the coat',
                            key: const Key('coat-instruction'),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            style: TextStyle(
                              color: _ink.withValues(alpha: .83),
                              fontSize: compact ? 12 : 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      _swatchTray(run, dockHeight, compact),
                      SizedBox(height: compact ? 4 : 10),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _workshop(JosephCoatRun run, bool compact) {
    final reveal = _reduced ? 0.0 : _reveal.value;
    final greeting = run.isComplete
        ? _reduced
              ? 1.0
              : Curves.easeOutCubic.transform(
                  ((_reveal.value - .22) / .48).clamp(0.0, 1.0),
                )
        : 0.0;
    final turn = run.isComplete
        ? math.sin(reveal * math.pi * 3) * .025 * (1 - reveal)
        : 0.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(130),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFF1E9D7),
          border: Border.all(color: const Color(0xFFE3D8BF), width: 1.2),
          borderRadius: BorderRadius.circular(130),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const CustomPaint(painter: _AtelierPainter()),
            Image.asset(
              'assets/images/games/matching/joseph_atelier.png',
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
            LayoutBuilder(
              builder: (context, box) {
                final width = math.min(box.maxWidth, box.maxHeight * 1.02);
                final height = math.min(box.maxHeight, width * 1.12);
                return Center(
                  child: Transform.translate(
                    offset: Offset(-box.maxWidth * .17 * greeting, 0),
                    child: Transform.scale(
                      scale: 1 - .25 * greeting,
                      child: Transform.rotate(
                        angle: turn,
                        alignment: const Alignment(0, -.7),
                        child: SizedBox(
                          width: width,
                          height: height,
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: _CoatPainter(
                                    run: run,
                                    recent: _recent,
                                    hovered: _hovered,
                                    wrong: _wrong,
                                    stitch: _reduced ? 1 : _stitch.value,
                                  ),
                                ),
                              ),
                              for (final panel in run.panels)
                                _panelTarget(panel, Size(width, height)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            if (run.isComplete)
              Positioned(
                right: 16,
                bottom: compact ? 23 : 30,
                top: compact ? 35 : 60,
                width: MediaQuery.sizeOf(context).width.clamp(0, 560) * .45,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: greeting,
                    child: Transform.translate(
                      offset: Offset(20 * (1 - greeting), 0),
                      child: Image.asset(
                        'assets/images/games/matching/joseph_character.png',
                        fit: BoxFit.contain,
                        alignment: Alignment.bottomCenter,
                        semanticLabel:
                            'Joseph smiles beside your finished coat',
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
            if (run.isComplete)
              IgnorePointer(
                child: CustomPaint(
                  painter: _ThreadCelebrationPainter(
                    progress: _reduced ? .7 : _reveal.value,
                  ),
                ),
              ),
            if (run.isComplete)
              Positioned(
                bottom: compact ? 9 : 15,
                left: 0,
                right: 0,
                child: Text(
                  'A BEAUTIFUL COAT!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _ink,
                    fontSize: compact ? 11 : 13,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _panelTarget(CoatFabric panel, Size size) {
    final shape = _shapes[panel.id]!;
    final bounds = shape.bounds;
    final filled = _run!.isPlaced(panel.id);
    final blocked = _blocked || filled || _run!.isComplete || _sent;
    return Positioned(
      left: bounds.left * size.width,
      top: bounds.top * size.height,
      width: bounds.width * size.width,
      height: bounds.height * size.height,
      child: ClipPath(
        clipper: _PatchClipper(shape),
        child: DragTarget<String>(
          onWillAcceptWithDetails: (details) => !blocked,
          onMove: blocked
              ? null
              : (_) {
                  if (_hovered != panel.id) setState(() => _hovered = panel.id);
                },
          onLeave: (_) {
            if (_hovered == panel.id && mounted) {
              setState(() => _hovered = null);
            }
          },
          onAcceptWithDetails: (details) => _place(panel.id, details.data),
          builder: (context, candidates, rejected) => Semantics(
            button: !filled,
            enabled: !blocked,
            label:
                '${filled ? 'Sewn' : 'Empty'} ${_panelName(panel.id)} patch, '
                '${panel.color} ${panel.pattern}',
            child: GestureDetector(
              key: Key('coat-panel-${panel.id}'),
              behavior: HitTestBehavior.opaque,
              onTap: blocked || _selected == null
                  ? null
                  : () => _place(panel.id, _selected!),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _swatchTray(JosephCoatRun run, double height, bool compact) {
    return Container(
      height: height,
      margin: const EdgeInsets.symmetric(horizontal: 14),
      padding: EdgeInsets.fromLTRB(14, compact ? 8 : 10, 14, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFE6C99C),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: const Color(0xFFCCAA77), width: 1.3),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1F573B24),
            blurRadius: 15,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          const SizedBox(
            height: 15,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                'YOUR FABRIC BASKET',
                maxLines: 1,
                style: TextStyle(
                  color: Color(0xFF785332),
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.7,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                final swatchWidth = (box.maxWidth - 20) / 3;
                final swatchHeight = (box.maxHeight - 7) / 2;
                return Wrap(
                  spacing: 10,
                  runSpacing: 7,
                  children: [
                    for (final swatch in run.swatches)
                      SizedBox(
                        width: swatchWidth,
                        height: swatchHeight,
                        child: _swatch(swatch, run),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _swatch(CoatFabric fabric, JosephCoatRun run) {
    final used = run.isUsed(fabric.id);
    final blocked = _blocked || run.isComplete || _sent || used;
    final selected = _selected == fabric.id && !used;
    final cloth = _ClothTile(fabric: fabric, selected: selected, used: used);
    return Semantics(
      label:
          '${fabric.color} fabric with ${fabric.pattern}${used ? ', sewn into coat' : ''}',
      button: !used,
      selected: selected,
      enabled: !blocked,
      child: GestureDetector(
        key: Key('coat-swatch-${fabric.id}'),
        onTap: blocked ? null : () => _choose(fabric),
        child: Draggable<String>(
          data: fabric.id,
          maxSimultaneousDrags: blocked ? 0 : 1,
          onDragStarted: () {
            if (_blocked) return;
            HapticFeedback.selectionClick();
            setState(() => _selected = fabric.id);
          },
          onDragEnd: (_) {
            if (mounted) setState(() => _hovered = null);
          },
          feedback: Material(
            color: Colors.transparent,
            child: Transform.rotate(
              angle: -.06,
              child: SizedBox(
                width: 106,
                height: 78,
                child: _ClothTile(fabric: fabric, selected: true),
              ),
            ),
          ),
          childWhenDragging: Opacity(opacity: .25, child: cloth),
          child: cloth,
        ),
      ),
    );
  }
}

class _ExitButton extends StatelessWidget {
  const _ExitButton({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Leave coat studio',
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .7),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFE2D8C1)),
        ),
        child: const Icon(Icons.close_rounded, color: _ink, size: 23),
      ),
    ),
  );
}

class _ClothTile extends StatelessWidget {
  const _ClothTile({
    required this.fabric,
    this.selected = false,
    this.used = false,
  });
  final CoatFabric fabric;
  final bool selected;
  final bool used;
  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    duration: const Duration(milliseconds: 160),
    opacity: used ? .25 : 1,
    child: CustomPaint(
      painter: _FabricTilePainter(fabric: fabric, selected: selected),
      child: const SizedBox.expand(),
    ),
  );
}

Color _clothColor(String color) => switch (color) {
  'coral' => const Color(0xFFE77D68),
  'gold' => const Color(0xFFE3B84C),
  'teal' => const Color(0xFF58A99B),
  'forest' => const Color(0xFF50785A),
  'sky' => const Color(0xFF76AFC9),
  'lilac' => const Color(0xFFA08ABD),
  _ => const Color(0xFFE7CFAC),
};

String _panelName(String id) => id.replaceAll('_', ' ');

class _PatchShape {
  const _PatchShape(this.points);
  final List<Offset> points;
  Rect get bounds => Rect.fromLTRB(
    points.map((p) => p.dx).reduce(math.min),
    points.map((p) => p.dy).reduce(math.min),
    points.map((p) => p.dx).reduce(math.max),
    points.map((p) => p.dy).reduce(math.max),
  );
  Path path(Size size) => Path()
    ..addPolygon(
      points.map((p) => Offset(p.dx * size.width, p.dy * size.height)).toList(),
      true,
    );
}

const _shapes = <String, _PatchShape>{
  'left_shoulder': _PatchShape([
    Offset(.41, .23),
    Offset(.27, .26),
    Offset(.075, .445),
    Offset(.185, .545),
    Offset(.32, .40),
    Offset(.405, .385),
  ]),
  'right_shoulder': _PatchShape([
    Offset(.59, .23),
    Offset(.73, .26),
    Offset(.925, .445),
    Offset(.815, .545),
    Offset(.68, .40),
    Offset(.595, .385),
  ]),
  'left_body': _PatchShape([
    Offset(.405, .295),
    Offset(.5, .36),
    Offset(.5, .63),
    Offset(.302, .63),
    Offset(.32, .40),
    Offset(.405, .385),
  ]),
  'right_body': _PatchShape([
    Offset(.595, .295),
    Offset(.5, .36),
    Offset(.5, .63),
    Offset(.698, .63),
    Offset(.68, .40),
    Offset(.595, .385),
  ]),
  'left_hem': _PatchShape([
    Offset(.302, .63),
    Offset(.5, .63),
    Offset(.5, .9),
    Offset(.282, .9),
  ]),
  'right_hem': _PatchShape([
    Offset(.5, .63),
    Offset(.698, .63),
    Offset(.718, .9),
    Offset(.5, .9),
  ]),
};

class _PatchClipper extends CustomClipper<Path> {
  const _PatchClipper(this.shape);
  final _PatchShape shape;
  @override
  Path getClip(Size size) {
    final bounds = shape.bounds;
    return Path()..addPolygon(
      shape.points
          .map(
            (p) => Offset(
              (p.dx - bounds.left) / bounds.width * size.width,
              (p.dy - bounds.top) / bounds.height * size.height,
            ),
          )
          .toList(),
      true,
    );
  }

  @override
  bool shouldReclip(_PatchClipper oldClipper) => shape != oldClipper.shape;
}

void _paintPattern(
  Canvas canvas,
  Rect rect,
  String pattern,
  Color color, {
  double scale = 1,
  double opacity = .56,
}) {
  final paint = Paint()
    ..color = color.withValues(alpha: opacity)
    ..strokeWidth = 3 * scale
    ..strokeCap = StrokeCap.round;
  final spacing = 16 * scale;
  if (pattern == 'dots') {
    var row = 0;
    for (var y = rect.top - spacing; y < rect.bottom + spacing; y += spacing) {
      for (
        var x = rect.left - spacing + (row.isEven ? 0 : spacing / 2);
        x < rect.right + spacing;
        x += spacing
      ) {
        canvas.drawCircle(Offset(x, y), 2.3 * scale, paint);
      }
      row++;
    }
  } else if (pattern == 'stripes') {
    paint.strokeWidth = 5 * scale;
    for (
      var x = rect.left - rect.height;
      x < rect.right + rect.height;
      x += spacing
    ) {
      canvas.drawLine(
        Offset(x, rect.bottom),
        Offset(x + rect.height, rect.top),
        paint,
      );
    }
  } else {
    paint.style = PaintingStyle.stroke;
    for (var y = rect.top - spacing; y < rect.bottom + spacing; y += spacing) {
      final path = Path()..moveTo(rect.left - spacing, y);
      var up = true;
      for (
        var x = rect.left - spacing;
        x < rect.right + spacing;
        x += spacing / 2
      ) {
        path.lineTo(x, y + (up ? 0 : spacing * .4));
        up = !up;
      }
      canvas.drawPath(path, paint);
    }
  }
}

void _stitches(
  Canvas canvas,
  Path path,
  Color color,
  double scale, {
  double progress = 1,
}) {
  final paint = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.15 * scale
    ..strokeCap = StrokeCap.round;
  for (final metric in path.computeMetrics()) {
    for (double d = 0; d < metric.length * progress; d += 6.2 * scale) {
      canvas.drawPath(
        metric.extractPath(
          d,
          math.min(d + 2.7 * scale, metric.length * progress),
        ),
        paint,
      );
    }
  }
}

class _FabricTilePainter extends CustomPainter {
  const _FabricTilePainter({required this.fabric, required this.selected});
  final CoatFabric fabric;
  final bool selected;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(4, 3, size.width - 8, size.height - 7);
    final path = Path()
      ..moveTo(rect.left + 7, rect.top)
      ..lineTo(rect.right - 4, rect.top + 2)
      ..lineTo(rect.right, rect.bottom - 4)
      ..lineTo(rect.left + 2, rect.bottom)
      ..lineTo(rect.left, rect.top + 4)
      ..close();
    canvas.drawShadow(path, const Color(0xFF6E4D2D), selected ? 5 : 2, true);
    canvas.save();
    canvas.clipPath(path);
    canvas.drawPath(path, Paint()..color = _clothColor(fabric.color));
    _paintPattern(
      canvas,
      rect,
      fabric.pattern,
      const Color(0xFFFFF9E9),
      scale: .9,
      opacity: .62,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x22FFFFFF), Color(0x00000000), Color(0x19000000)],
        ).createShader(rect),
    );
    canvas.restore();
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 2.8 : 1.3
        ..color = selected ? _ink : const Color(0x55FFFFFF),
    );
    final stitchRect = rect.deflate(4);
    _stitches(
      canvas,
      Path()..addRRect(
        RRect.fromRectAndRadius(stitchRect, const Radius.circular(3)),
      ),
      const Color(0xBFFFFFF2),
      .8,
    );
    if (selected) {
      final center = Offset(rect.right - 3, rect.top + 4);
      canvas.drawCircle(center, 9, Paint()..color = _ink);
      canvas.drawPath(
        Path()
          ..moveTo(center.dx - 3.5, center.dy)
          ..lineTo(center.dx - .5, center.dy + 3)
          ..lineTo(center.dx + 4, center.dy - 3.5),
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_FabricTilePainter oldDelegate) =>
      oldDelegate.fabric != fabric || oldDelegate.selected != selected;
}

class _CoatPainter extends CustomPainter {
  const _CoatPainter({
    required this.run,
    required this.stitch,
    this.recent,
    this.hovered,
    this.wrong,
  });
  final JosephCoatRun run;
  final double stitch;
  final String? recent;
  final String? hovered;
  final String? wrong;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 320;
    // Hook and wooden hanger sit on the same physical point as the neckline.
    final hook = Path()
      ..moveTo(size.width * .5, size.height * .13)
      ..lineTo(size.width * .5, size.height * .09)
      ..cubicTo(
        size.width * .5,
        size.height * .04,
        size.width * .555,
        size.height * .04,
        size.width * .555,
        size.height * .08,
      )
      ..cubicTo(
        size.width * .555,
        size.height * .1,
        size.width * .54,
        size.height * .11,
        size.width * .53,
        size.height * .11,
      );
    canvas.drawPath(
      hook,
      Paint()
        ..color = const Color(0xFF9B7747)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4 * s
        ..strokeCap = StrokeCap.round,
    );
    final hanger = Path()
      ..moveTo(size.width * .5, size.height * .13)
      ..lineTo(size.width * .275, size.height * .275)
      ..lineTo(size.width * .725, size.height * .275)
      ..close();
    canvas.drawPath(
      hanger,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFF9F713C)
        ..strokeWidth = 9 * s,
    );
    canvas.drawPath(
      hanger,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFFD0A66C)
        ..strokeWidth = 5 * s,
    );
    // Cloth has a coherent silhouette, with a single soft floor shadow.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * .5, size.height * .93),
        width: size.width * .47,
        height: 11 * s,
      ),
      Paint()
        ..color = const Color(0x237E6242)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 7 * s),
    );
    for (final panel in run.panels) {
      final shape = _shapes[panel.id]!;
      final basePath = shape.path(size);
      final filled = run.isPlaced(panel.id);
      final isWrong = panel.id == wrong && stitch < 1;
      final isRecent = panel.id == recent;
      final shake = isWrong
          ? math.sin(stitch * math.pi * 7) * (1 - stitch) * 4 * s
          : 0.0;
      canvas.save();
      canvas.translate(shake, 0);
      canvas.drawShadow(basePath, const Color(0xFF745D41), 3 * s, true);
      canvas.save();
      canvas.clipPath(basePath);
      final rect = basePath.getBounds();
      canvas.drawPath(
        basePath,
        Paint()
          ..color = filled ? _clothColor(panel.color) : const Color(0xFFF9F1E1),
      );
      if (filled) {
        _paintPattern(
          canvas,
          rect,
          panel.pattern,
          const Color(0xFFFFF9E9),
          scale: s,
          opacity: .60,
        );
      } else {
        // A little cloth sample is the visual instruction for this patch.
        final sampleSize = math.min(rect.width * .55, rect.height * .43);
        final center = panel.id.contains('shoulder')
            ? Offset(
                rect.center.dx + (panel.id.startsWith('left') ? 2 : -2) * s,
                rect.center.dy + 4 * s,
              )
            : rect.center;
        final sample = Rect.fromCenter(
          center: center,
          width: sampleSize,
          height: sampleSize,
        );
        final samplePath = Path()
          ..addRRect(RRect.fromRectAndRadius(sample, Radius.circular(5 * s)));
        canvas.drawShadow(samplePath, const Color(0xFFC1A777), 2 * s, true);
        canvas.save();
        canvas.clipPath(samplePath);
        canvas.drawPath(
          samplePath,
          Paint()..color = _clothColor(panel.color).withValues(alpha: .83),
        );
        _paintPattern(
          canvas,
          sample,
          panel.pattern,
          const Color(0xFFFFF9E9),
          scale: s * .60,
          opacity: .8,
        );
        canvas.restore();
        _stitches(canvas, samplePath, const Color(0xBBFFFFFF), .7 * s);
      }
      canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              const Color(0x10000000),
              const Color(0x0AFFFFFF),
              const Color(0x16000000),
            ],
            stops: const [0, .3, 1],
          ).createShader(rect),
      );
      // Fine warp threads catch light without distracting from the pattern.
      for (var x = rect.left; x < rect.right; x += 3.2 * s) {
        canvas.drawLine(
          Offset(x, rect.top),
          Offset(x, rect.bottom),
          Paint()
            ..color = const Color(0x09FFFFFF)
            ..strokeWidth = .6 * s,
        );
      }
      canvas.restore();
      canvas.drawPath(
        basePath,
        Paint()
          ..color = isWrong
              ? const Color(0xFFE58E7A)
              : hovered == panel.id
              ? _gold
              : const Color(0xFFD3B98D)
          ..style = PaintingStyle.stroke
          ..strokeWidth = hovered == panel.id ? 4 * s : 1.5 * s,
      );
      // Seam inset is painted by scaling about the panel's center.
      final center = basePath.getBounds().center;
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.scale(.94);
      canvas.translate(-center.dx, -center.dy);
      _stitches(
        canvas,
        basePath,
        filled ? const Color(0xDBFFF4D9) : const Color(0xFFA89474),
        s,
        progress: isRecent ? Curves.easeOut.transform(stitch) : 1,
      );
      canvas.restore();
      canvas.restore();
    }
    // Collar, front opening and brass buttons join the six sewn pieces.
    final collar = Path()
      ..moveTo(size.width * .41, size.height * .235)
      ..lineTo(size.width * .5, size.height * .36)
      ..lineTo(size.width * .59, size.height * .235);
    canvas.drawPath(
      collar,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8 * s
        ..color = const Color(0xFFD4B781)
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      collar,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 * s
        ..color = const Color(0xFFF7E8C7)
        ..strokeJoin = StrokeJoin.round,
    );
    final placket = Rect.fromLTWH(
      size.width * .489,
      size.height * .36,
      size.width * .022,
      size.height * .54,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(placket, Radius.circular(2 * s)),
      Paint()..color = const Color(0xFFCFB073),
    );
    for (var i = 0; i < 4; i++) {
      final p = Offset(size.width * .5, size.height * (.43 + i * .115));
      canvas.drawCircle(
        p.translate(0, 1 * s),
        3.6 * s,
        Paint()..color = const Color(0xFF92713D),
      );
      canvas.drawCircle(p, 3 * s, Paint()..color = const Color(0xFFF0D78D));
      canvas.drawCircle(
        p.translate(-.8 * s, -.8 * s),
        .9 * s,
        Paint()..color = const Color(0xFFFFF3C5),
      );
    }
  }

  @override
  bool shouldRepaint(_CoatPainter oldDelegate) => true;
}

class _AtelierPainter extends CustomPainter {
  const _AtelierPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(0, -.15),
          radius: .85,
          colors: [Color(0xFFFFFBED), Color(0xFFF0E7D2)],
        ).createShader(rect),
    );
    // Tall window light, soft plaster grain and a sunlit work surface.
    canvas.save();
    canvas.rotate(-.15);
    canvas.drawRect(
      Rect.fromLTWH(size.width * .72, -50, size.width * .12, size.height * 1.6),
      Paint()..color = const Color(0x1AFFFFFF),
    );
    canvas.restore();
    final grain = Paint()..color = const Color(0x188C714B);
    for (var i = 0; i < 190; i++) {
      final x = ((i * 71 + 11) % 997) / 997 * size.width;
      final y = ((i * 113 + 19) % 991) / 991 * size.height;
      canvas.drawCircle(Offset(x, y), .5 + (i % 3) * .2, grain);
    }
    final floorY = size.height * .94;
    canvas.drawRect(
      Rect.fromLTRB(0, floorY, size.width, size.height),
      Paint()..color = const Color(0xFFDCC5A2),
    );
    canvas.drawLine(
      Offset(0, floorY),
      Offset(size.width, floorY),
      Paint()
        ..color = const Color(0xFFC3A57E)
        ..strokeWidth = 2,
    );
    // Simple sewing thread spools belong to the workroom, not the controls.
    for (var i = 0; i < 3; i++) {
      final x = size.width * (.12 + i * .06);
      final y = size.height * .84;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, 10, 20),
          const Radius.circular(2),
        ),
        Paint()
          ..color = [
            const Color(0xFFC9856C),
            const Color(0xFF8EA78C),
            const Color(0xFFD0AC5F),
          ][i],
      );
      for (var j = 0; j < 6; j++) {
        canvas.drawLine(
          Offset(x, y + 3 + j * 2.5),
          Offset(x + 10, y + 3 + j * 2.5),
          Paint()
            ..color = const Color(0x33FFFFFF)
            ..strokeWidth = 1,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_AtelierPainter oldDelegate) => false;
}

class _ThreadCelebrationPainter extends CustomPainter {
  const _ThreadCelebrationPainter({required this.progress});
  final double progress;
  @override
  void paint(Canvas canvas, Size size) {
    const colors = [
      Color(0xFFE77D68),
      Color(0xFFE3B84C),
      Color(0xFF58A99B),
      Color(0xFFA08ABD),
    ];
    for (var i = 0; i < 30; i++) {
      final phase = (progress * 1.25 - (i % 5) * .035).clamp(0.0, 1.0);
      if (phase <= 0 || phase >= 1) continue;
      final x = size.width * .5 + math.sin(i * 2.39) * size.width * .48 * phase;
      final y =
          size.height * .48 -
          math.cos(i * 1.7).abs() *
              size.height *
              .48 *
              math.sin(phase * math.pi) +
          phase * size.height * .15;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(i + phase * 8);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(-3, -1.5, 6, 3),
          const Radius.circular(1),
        ),
        Paint()
          ..color = colors[i % colors.length].withValues(
            alpha: (1 - phase) * .9,
          ),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ThreadCelebrationPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

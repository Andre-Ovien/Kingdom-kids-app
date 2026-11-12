import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/audio/app_audio_controller.dart';
import '../../../shared/audio/app_audio_scope.dart';
import '../../../shared/audio/app_sound_cue.dart';
import '../domain/creation_bloom_model.dart';
import '../domain/mini_game.dart';

const _ink = Color(0xFF244F3E);
const _cream = Color(0xFFFFF8EA);
const _coral = Color(0xFFE47E62);
const _gold = Color(0xFFD7A444);

const _habitatNames = {
  'sky': 'Sky',
  'water': 'River',
  'forest': 'Woodland',
  'meadow': 'Meadow',
};
const _pieceNames = {
  'sun': 'Sun',
  'bird': 'Bird',
  'fish': 'Fish',
  'tree': 'Tree',
  'flower': 'Flower',
  'deer': 'Deer',
};
const _homeBounds = {
  'sky': Rect.fromLTWH(.265, .015, .705, .245),
  'forest': Rect.fromLTWH(.025, .295, .45, .35),
  'water': Rect.fromLTWH(.535, .33, .435, .27),
  'meadow': Rect.fromLTWH(.08, .72, .84, .255),
};

/// One growing garden, with living pieces placed directly into their homes.
/// Input is recorded immediately; the host alone handles saving and XP.
class CreationBloomEngine extends StatefulWidget {
  const CreationBloomEngine({
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
  State<CreationBloomEngine> createState() => _CreationBloomEngineState();
}

class _CreationBloomEngineState extends State<CreationBloomEngine>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  CreationBloomRun? _run;
  String? _selected;
  String? _hovered;
  String? _wrong;
  String? _recent;
  String _notice = 'Find a home. Watch it come alive.';
  bool _sent = false;
  bool _foreground = true;
  bool _resumeBloom = false;
  bool _resumeReveal = false;
  AppAudioController? _audioOwner;
  MatchingGameFeedback? _feedback;
  late final AnimationController _bloom = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1350),
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
      _run = CreationBloomRun(widget.level.config);
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
  void didUpdateWidget(covariant CreationBloomEngine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.level.id != widget.level.id) {
      _bloom.reset();
      _reveal.reset();
      _selected = _hovered = _wrong = _recent = null;
      _notice = 'Find a home. Watch it come alive.';
      _sent = _resumeBloom = _resumeReveal = false;
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
      _resumeBloom = _resumeBloom || _bloom.isAnimating;
      _resumeReveal = _resumeReveal || _reveal.isAnimating;
      _bloom.stop(canceled: false);
      _reveal.stop(canceled: false);
    } else {
      if (_resumeBloom) _bloom.forward();
      if (_resumeReveal) _reveal.forward();
      _resumeBloom = _resumeReveal = false;
      if (_reveal.isCompleted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_blocked) _submit();
        });
      }
    }
  }

  void _choose(BloomItem item) {
    final run = _run;
    if (_blocked ||
        _sent ||
        run == null ||
        run.isComplete ||
        run.isUsed(item.id)) {
      return;
    }
    HapticFeedback.selectionClick();
    _feedback?.play(AppSoundCue.select);
    setState(() {
      _selected = _selected == item.id ? null : item.id;
      _wrong = null;
      _notice = _selected == null
          ? 'Find a home. Watch it come alive.'
          : 'Where does the ${_pieceNames[item.id]!.toLowerCase()} belong?';
    });
  }

  void _place(String itemId, String targetId) {
    final run = _run;
    if (_blocked || _sent || run == null) return;
    final outcome = run.place(itemId, targetId);
    if (outcome == BloomPlacement.ignored) return;
    setState(() {
      _hovered = null;
      _wrong = outcome == BloomPlacement.wrong ? targetId : null;
      _recent = outcome == BloomPlacement.correct ? itemId : null;
      if (outcome == BloomPlacement.correct) {
        _selected = null;
        _notice = run.isComplete
            ? 'You brought the garden to life!'
            : '${_pieceNames[itemId]} found a home!';
      } else {
        _selected = itemId;
        final item = run.items.firstWhere((item) => item.id == itemId);
        _notice = 'Try the ${_habitatNames[item.matchKey]!.toLowerCase()}.';
      }
    });
    _bloom.forward(from: 0);
    if (outcome == BloomPlacement.correct) {
      HapticFeedback.lightImpact();
      _feedback?.play(AppSoundCue.select);
      if (run.isComplete) {
        _feedback?.play(AppSoundCue.success);
        // Reduced motion uses the fully grown still scene, while retaining
        // the same short reading/listening interval before the host saves.
        _reveal.forward(from: 0);
      }
    } else {
      HapticFeedback.selectionClick();
      if (run.exhausted) _submit();
    }
  }

  void _submit() {
    if (_blocked || _sent || _run == null) return;
    _sent = true;
    _feedback?.setPaused(true);
    widget.onComplete(_run!.result);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bloom.dispose();
    _reveal.dispose();
    _feedback?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final run = _run;
    if (run == null) {
      return const ColoredBox(
        color: _cream,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: Text(
              'The garden is being prepared. Try another round.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return MediaQuery.withClampedTextScaling(
      // Habitat names sit inside a fixed illustrated playfield. Keep them
      // readable without letting dynamic type cover the pieces themselves;
      // all pieces and homes also expose full spoken semantics.
      maxScaleFactor: 1.3,
      child: TickerMode(
        enabled: !_blocked,
        child: ColoredBox(
          key: const Key('creation-bloom-game'),
          color: _cream,
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxHeight < 620;
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      children: [
                        _header(run, compact),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 2, 18, 7),
                          child: Semantics(
                            liveRegion: true,
                            child: SizedBox(
                              height: compact ? 32 : 36,
                              child: Center(
                                child: Text(
                                  _notice,
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _ink.withValues(alpha: .76),
                                    fontSize: compact ? 12 : 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: compact ? 12 : 16,
                            ),
                            child: _garden(run),
                          ),
                        ),
                        _tray(run, compact),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(CreationBloomRun run, bool compact) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, compact ? 4 : 12, 16, 2),
      child: Row(
        children: [
          if (widget.onExit != null) ...[
            Semantics(
              label: 'Leave garden',
              button: true,
              child: IconButton.filledTonal(
                tooltip: 'Leave garden',
                onPressed: _blocked || _sent ? null : widget.onExit,
                style: IconButton.styleFrom(
                  foregroundColor: _ink,
                  backgroundColor: const Color(0xFFEDEBDD),
                  minimumSize: const Size(44, 44),
                ),
                icon: const Icon(Icons.arrow_back_rounded, size: 22),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CREATION GARDEN',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _ink.withValues(alpha: .56),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.7,
                    fontSize: compact ? 9 : 10,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Match & Bloom',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.w900,
                    fontSize: compact ? 19 : 25,
                    letterSpacing: -.7,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Semantics(
            label: '${run.matched} of 6 garden pieces placed',
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 9 : 12,
                vertical: compact ? 8 : 10,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFFE1EBD6),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(
                '${run.matched} / 6',
                style: const TextStyle(
                  color: _ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _garden(CreationBloomRun run) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: _ink.withValues(alpha: .13),
            blurRadius: 22,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            return AnimatedBuilder(
              animation: Listenable.merge([_bloom, _reveal]),
              builder: (context, _) => Stack(
                key: const Key('bloom-garden-scene'),
                fit: StackFit.expand,
                children: [
                  // Frame the upper garden consistently at every aspect.
                  // The lower quarter of the original art is a spare path.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: size.height / .76,
                    child: Image.asset(
                      'assets/images/games/matching/creation_garden.png',
                      fit: BoxFit.fill,
                      filterQuality: FilterQuality.high,
                      errorBuilder: (context, error, stack) =>
                          const ColoredBox(color: Color(0xFFD4EACF)),
                    ),
                  ),
                  const ColoredBox(color: Color(0x10FFFAE9)),
                  for (final target in run.targets) _target(target, run, size),
                  if (run.isComplete)
                    IgnorePointer(
                      child: CustomPaint(
                        painter: _PetalPainter(
                          phase: _reduced ? 1 : _reveal.value,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _target(BloomTarget target, CreationBloomRun run, Size size) {
    final relative = _homeBounds[target.id]!;
    final bounds = Rect.fromLTWH(
      relative.left * size.width,
      relative.top * size.height,
      relative.width * size.width,
      relative.height * size.height,
    );
    final contents = run.itemsIn(target.id);
    final expected = run.items
        .where((item) => item.matchKey == target.matchKey)
        .toList();
    final filled = contents.length == target.capacity;
    final hovered = _hovered == target.id;
    final wrong = _wrong == target.id;
    final wobble = wrong && !_reduced
        ? math.sin(_bloom.value * math.pi * 6) * (1 - _bloom.value) * 4
        : 0.0;
    return Positioned.fromRect(
      rect: bounds.translate(wobble, 0),
      child: DragTarget<String>(
        key: Key('bloom-target-${target.id}'),
        onWillAcceptWithDetails: (details) {
          if (_blocked || _sent || run.isComplete) return false;
          setState(() => _hovered = target.id);
          return true;
        },
        onLeave: (_) {
          if (mounted && _hovered == target.id) {
            setState(() => _hovered = null);
          }
        },
        onAcceptWithDetails: (details) => _place(details.data, target.id),
        builder: (context, candidates, rejected) => Semantics(
          label:
              '${_habitatNames[target.id]} habitat, ${contents.length} of ${target.capacity} pieces placed',
          button: true,
          onTap: _blocked || _sent || _selected == null
              ? null
              : () => _place(_selected!, target.id),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _blocked || _sent || _selected == null
                ? null
                : () => _place(_selected!, target.id),
            child: CustomPaint(
              painter: _HabitatOutlinePainter(
                id: target.id,
                highlighted: hovered,
                wrong: wrong,
                filled: filled,
              ),
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: target.id == 'water' ? null : 5,
                    bottom: target.id == 'water' ? 5 : null,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: filled
                              ? const Color(0xFFE9F3D9)
                              : const Color(0xEFFFF9E9),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _habitatNames[target.id]!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _ink,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ),
                  for (var i = 0; i < expected.length; i++)
                    _livingPiece(
                      expected[i],
                      target.id,
                      i,
                      expected.length,
                      run.isUsed(expected[i].id),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _livingPiece(
    BloomItem item,
    String habitat,
    int index,
    int total,
    bool placed,
  ) {
    final recent = placed && item.id == _recent;
    final phase = _reduced || !recent ? 1.0 : _bloom.value;
    final emerge = Curves.easeOutBack.transform((phase * 1.5).clamp(0.0, 1.0));
    final alignment = habitat == 'sky'
        ? Alignment(total == 1 ? 0 : (index == 0 ? -.48 : .5), .3)
        : habitat == 'water'
        ? const Alignment(-.05, -.05)
        : Alignment(total == 1 ? 0 : (index == 0 ? -.48 : .48), .34);
    final pieceSize = switch (item.id) {
      'tree' => 1.0,
      'deer' => .82,
      'fish' => .70,
      _ => .72,
    };
    return Positioned(
      top: habitat == 'water' ? 0 : 24,
      bottom: habitat == 'water' ? 24 : 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Align(
          alignment: alignment,
          child: FractionallySizedBox(
            widthFactor: total > 1 ? .44 : pieceSize,
            heightFactor: .92,
            child: Transform.scale(
              scale: placed ? emerge : .82,
              alignment: Alignment.bottomCenter,
              child: Opacity(
                opacity: placed ? 1 : .20,
                child: CustomPaint(
                  key: Key(
                    'bloom-life-${item.id}-${placed ? 'alive' : 'hint'}',
                  ),
                  painter: _LifePainter(
                    kind: item.id,
                    phase: placed ? phase : 1,
                    silhouette: !placed,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tray(CreationBloomRun run, bool compact) {
    final trayHeight = compact ? 174.0 : 192.0;
    return SizedBox(
      height: trayHeight,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, compact ? 7 : 10, 16, compact ? 4 : 9),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFFF0E4CD),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: const Color(0xFFFFFFFF), width: 2),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF7F6542).withValues(alpha: .08),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 7, bottom: 2),
                child: Text(
                  run.isComplete
                      ? 'A little world, full of life'
                      : 'YOUR GARDEN PIECES',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _ink.withValues(alpha: .65),
                    fontSize: compact ? 9 : 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 1, 6, 5),
                  child: Column(
                    children: [
                      for (var row = 0; row < 2; row++)
                        Expanded(
                          child: Row(
                            children: [
                              for (var column = 0; column < 3; column++)
                                Expanded(
                                  child: _piece(
                                    run.items[row * 3 + column],
                                    run,
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _piece(BloomItem item, CreationBloomRun run) {
    final used = run.isUsed(item.id);
    final selected = _selected == item.id && !used;
    final child = Semantics(
      key: Key('bloom-piece-${item.id}'),
      label:
          '${_pieceNames[item.id]}${used ? ', placed in the garden' : ', garden piece'}',
      button: !used,
      selected: selected,
      enabled: !_blocked && !used && !_sent,
      onTap: _blocked || used || _sent ? null : () => _choose(item),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _blocked || used || _sent ? null : () => _choose(item),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
          child: AnimatedContainer(
            duration: _reduced
                ? Duration.zero
                : const Duration(milliseconds: 180),
            decoration: BoxDecoration(
              color: selected ? const Color(0xFFFFFCF3) : Colors.transparent,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected ? _coral : Colors.transparent,
                width: 2,
              ),
            ),
            child: Opacity(
              opacity: used ? .24 : 1,
              child: Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
                      child: CustomPaint(
                        painter: _LifePainter(kind: item.id, phase: 1),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 1),
                    child: Text(
                      _pieceNames[item.id]!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _ink,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (used || _blocked || _sent || run.isComplete) return child;
    return Draggable<String>(
      data: item.id,
      maxSimultaneousDrags: 1,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: () => _choose(item),
      onDraggableCanceled: (_, _) {
        if (mounted) setState(() => _hovered = null);
      },
      feedback: Material(
        color: Colors.transparent,
        child: Transform.translate(
          offset: const Offset(-38, -42),
          child: Container(
            width: 76,
            height: 76,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: _cream,
              borderRadius: BorderRadius.circular(25),
              border: Border.all(color: _coral, width: 2),
              boxShadow: [
                BoxShadow(
                  color: _ink.withValues(alpha: .2),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: CustomPaint(painter: _LifePainter(kind: item.id, phase: 1)),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: .35, child: child),
      child: child,
    );
  }
}

class _HabitatOutlinePainter extends CustomPainter {
  const _HabitatOutlinePainter({
    required this.id,
    required this.highlighted,
    required this.wrong,
    required this.filled,
  });

  final String id;
  final bool highlighted;
  final bool wrong;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(3);
    final shape = Path();
    if (id == 'water') {
      shape.addOval(rect);
    } else if (id == 'sky') {
      shape.addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(45)));
    } else {
      shape.moveTo(rect.left + rect.width * .15, rect.top + rect.height * .06);
      shape.cubicTo(
        rect.right,
        rect.top - 5,
        rect.right + 7,
        rect.bottom * .6,
        rect.right - 9,
        rect.bottom - 8,
      );
      shape.cubicTo(
        rect.center.dx,
        rect.bottom + 6,
        rect.left - 5,
        rect.bottom - 3,
        rect.left + 3,
        rect.center.dy,
      );
      shape.quadraticBezierTo(
        rect.left - 1,
        rect.top + 10,
        rect.left + rect.width * .15,
        rect.top + rect.height * .06,
      );
      shape.close();
    }
    final color = wrong
        ? _coral
        : highlighted
        ? _gold
        : filled
        ? const Color(0xFF7FA66B)
        : const Color(0xFFFCFFF5);
    if (highlighted || wrong) {
      canvas.drawPath(shape, Paint()..color = color.withValues(alpha: .18));
    }
    final paint = Paint()
      ..color = color.withValues(alpha: filled ? .5 : .83)
      ..style = PaintingStyle.stroke
      ..strokeWidth = highlighted || wrong ? 3 : 1.8
      ..strokeCap = StrokeCap.round;
    for (final metric in shape.computeMetrics()) {
      for (var distance = 0.0; distance < metric.length; distance += 12) {
        canvas.drawPath(
          metric.extractPath(distance, math.min(distance + 5, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HabitatOutlinePainter old) =>
      id != old.id ||
      highlighted != old.highlighted ||
      wrong != old.wrong ||
      filled != old.filled;
}

/// All six pieces share an illustrated, softly shaded treatment. These are
/// original vector creatures and plants rather than platform emoji or icons.
class _LifePainter extends CustomPainter {
  const _LifePainter({
    required this.kind,
    required this.phase,
    this.silhouette = false,
  });

  final String kind;
  final double phase;
  final bool silhouette;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = math.min(size.width, size.height) / 100;
    canvas.save();
    canvas.translate(
      (size.width - unit * 100) / 2,
      (size.height - unit * 100) / 2,
    );
    canvas.scale(unit);
    if (silhouette) {
      canvas.saveLayer(
        const Rect.fromLTWH(-15, -15, 130, 130),
        Paint()
          ..colorFilter = const ColorFilter.mode(
            Color(0xFF416955),
            BlendMode.srcIn,
          ),
      );
    }
    switch (kind) {
      case 'sun':
        _sun(canvas);
      case 'bird':
        _bird(canvas);
      case 'fish':
        _fish(canvas);
      case 'tree':
        _tree(canvas);
      case 'flower':
        _flower(canvas);
      case 'deer':
        _deer(canvas);
    }
    if (silhouette) canvas.restore();
    canvas.restore();
  }

  void _oval(Canvas c, Rect rect, Color color) =>
      c.drawOval(rect, Paint()..color = color);

  void _line(Canvas c, Offset a, Offset b, Color color, double width) =>
      c.drawLine(
        a,
        b,
        Paint()
          ..color = color
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round,
      );

  Paint _gradient(Rect bounds, Color light, Color dark) => Paint()
    ..shader = LinearGradient(
      colors: [light, dark],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ).createShader(bounds);

  void _sun(Canvas c) {
    for (var i = 0; i < 10; i++) {
      final angle = i * math.pi / 5 - .2;
      _line(
        c,
        Offset(50 + math.cos(angle) * 34, 50 + math.sin(angle) * 34),
        Offset(50 + math.cos(angle) * 43, 50 + math.sin(angle) * 43),
        const Color(0xFFE7AB42),
        5,
      );
    }
    const circle = Rect.fromLTWH(23, 23, 54, 54);
    c.drawOval(
      circle,
      _gradient(circle, const Color(0xFFFFD66D), const Color(0xFFF0B450)),
    );
    _oval(c, const Rect.fromLTWH(31, 28, 29, 17), const Color(0x40FFFFD5));
    _oval(c, const Rect.fromLTWH(37, 47, 4, 6), _ink);
    _oval(c, const Rect.fromLTWH(59, 47, 4, 6), _ink);
    c.drawArc(
      const Rect.fromLTWH(42, 51, 17, 12),
      .1,
      math.pi - .2,
      false,
      Paint()
        ..color = const Color(0xFF9E7037)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  void _bird(Canvas c) {
    final flutter = math.sin(phase * math.pi * 7) * (1 - phase) * 14;
    c.save();
    c.translate(0, math.sin(phase * math.pi * 2) * (1 - phase) * 8);
    final tail = Path()
      ..moveTo(29, 62)
      ..lineTo(10, 54)
      ..quadraticBezierTo(12, 75, 32, 75)
      ..close();
    c.drawPath(tail, Paint()..color = const Color(0xFF528F9B));
    final body = const Rect.fromLTWH(23, 38, 53, 37);
    c.drawOval(
      body,
      _gradient(body, const Color(0xFFA4CDCC), const Color(0xFF619EA6)),
    );
    _oval(c, const Rect.fromLTWH(48, 23, 32, 34), const Color(0xFFB9DADA));
    final wing = Path()
      ..moveTo(42, 54)
      ..quadraticBezierTo(29, 16 + flutter, 18, 21 + flutter)
      ..quadraticBezierTo(13, 50, 42, 63)
      ..close();
    c.drawPath(wing, Paint()..color = const Color(0xFF7AB5B9));
    final wingHighlight = Path()
      ..moveTo(37, 53)
      ..quadraticBezierTo(29, 32 + flutter, 23, 29 + flutter);
    c.drawPath(
      wingHighlight,
      Paint()
        ..color = const Color(0x99C9E2D9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    c.drawPath(
      Path()
        ..moveTo(77, 37)
        ..lineTo(92, 43)
        ..lineTo(77, 48)
        ..close(),
      Paint()..color = const Color(0xFFE1AC53),
    );
    _oval(c, const Rect.fromLTWH(67, 33, 5, 6), const Color(0xFF244939));
    _oval(c, const Rect.fromLTWH(68, 33.5, 1.5, 1.5), Colors.white);
    c.restore();
  }

  void _fish(Canvas c) {
    final swim = math.sin(phase * math.pi * 2) * (1 - phase) * 10;
    c.save();
    c.translate(swim, 0);
    final tail = Path()
      ..moveTo(26, 49)
      ..quadraticBezierTo(8, 27, 7, 38)
      ..lineTo(8, 69)
      ..quadraticBezierTo(15, 78, 30, 57)
      ..close();
    c.drawPath(tail, Paint()..color = const Color(0xFFE6A64E));
    final body = const Rect.fromLTWH(21, 31, 68, 44);
    c.drawOval(
      body,
      _gradient(body, const Color(0xFFFFCC77), const Color(0xFFE89549)),
    );
    c.drawPath(
      Path()
        ..moveTo(43, 35)
        ..quadraticBezierTo(51, 16, 67, 31)
        ..close(),
      Paint()..color = const Color(0xFFEAAA55),
    );
    c.drawPath(
      Path()
        ..moveTo(51, 54)
        ..quadraticBezierTo(37, 70, 47, 70)
        ..quadraticBezierTo(64, 68, 65, 54)
        ..close(),
      Paint()..color = const Color(0xFFF7BC68),
    );
    c.drawArc(
      const Rect.fromLTWH(62, 40, 13, 25),
      math.pi * .6,
      math.pi * .8,
      false,
      Paint()
        ..color = const Color(0xFFCA7F3F)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    _oval(c, const Rect.fromLTWH(74, 44, 5, 6), _ink);
    _oval(c, const Rect.fromLTWH(75, 44, 1.6, 1.6), Colors.white);
    _oval(c, const Rect.fromLTWH(38, 36, 31, 8), const Color(0x40FFEBBE));
    c.restore();
  }

  void _tree(Canvas c) {
    _oval(c, const Rect.fromLTWH(21, 86, 60, 8), const Color(0x26719451));
    final trunk = Path()
      ..moveTo(42, 89)
      ..lineTo(44, 51)
      ..lineTo(57, 49)
      ..lineTo(60, 89)
      ..close();
    c.drawPath(trunk, Paint()..color = const Color(0xFFA17449));
    _line(
      c,
      const Offset(50, 68),
      const Offset(30, 48),
      const Color(0xFFA17449),
      7,
    );
    _line(
      c,
      const Offset(51, 64),
      const Offset(71, 41),
      const Color(0xFFA17449),
      6,
    );
    _oval(c, const Rect.fromLTWH(8, 29, 48, 42), const Color(0xFF74A46A));
    _oval(c, const Rect.fromLTWH(42, 24, 49, 45), const Color(0xFF67985E));
    _oval(c, const Rect.fromLTWH(24, 7, 51, 55), const Color(0xFF8AB575));
    _oval(c, const Rect.fromLTWH(33, 13, 27, 15), const Color(0xFFABC988));
    _oval(c, const Rect.fromLTWH(17, 36, 17, 9), const Color(0xFF94BA7F));
    _oval(c, const Rect.fromLTWH(65, 39, 15, 9), const Color(0xFF80AA6E));
    _line(
      c,
      const Offset(49, 77),
      const Offset(49, 88),
      const Color(0xFFBD9165),
      2,
    );
  }

  void _flower(Canvas c) {
    _oval(c, const Rect.fromLTWH(26, 85, 50, 7), const Color(0x26719451));
    _line(
      c,
      const Offset(50, 87),
      const Offset(50, 41),
      const Color(0xFF6F9B63),
      5,
    );
    c.drawPath(
      Path()
        ..moveTo(49, 72)
        ..quadraticBezierTo(22, 48, 24, 67)
        ..quadraticBezierTo(30, 83, 49, 77)
        ..close(),
      Paint()..color = const Color(0xFF82AD6B),
    );
    c.drawPath(
      Path()
        ..moveTo(52, 62)
        ..quadraticBezierTo(79, 40, 77, 61)
        ..quadraticBezierTo(68, 77, 52, 68)
        ..close(),
      Paint()..color = const Color(0xFF98B979),
    );
    for (var i = 0; i < 6; i++) {
      c.save();
      c.translate(50, 35);
      c.rotate(i * math.pi / 3);
      const petal = Rect.fromLTWH(-11, -31, 22, 34);
      c.drawOval(
        petal,
        _gradient(petal, const Color(0xFFF3B49A), const Color(0xFFDE826B)),
      );
      c.restore();
    }
    _oval(c, const Rect.fromLTWH(37, 22, 26, 26), const Color(0xFFEAC46B));
    _oval(c, const Rect.fromLTWH(40, 25, 19, 18), const Color(0xFFF6D98D));
    for (var i = 0; i < 5; i++) {
      final a = i * math.pi * .4;
      c.drawCircle(
        Offset(50 + math.cos(a) * 5, 35 + math.sin(a) * 5),
        1.3,
        Paint()..color = const Color(0xFFB6924B),
      );
    }
  }

  void _deer(Canvas c) {
    _oval(c, const Rect.fromLTWH(15, 85, 77, 7), const Color(0x26719451));
    _line(
      c,
      const Offset(31, 63),
      const Offset(25, 86),
      const Color(0xFFB98862),
      5,
    );
    _line(
      c,
      const Offset(43, 64),
      const Offset(42, 87),
      const Color(0xFFBD8D67),
      5,
    );
    _line(
      c,
      const Offset(65, 63),
      const Offset(67, 87),
      const Color(0xFFC39973),
      5,
    );
    _line(
      c,
      const Offset(74, 60),
      const Offset(80, 85),
      const Color(0xFFAE805D),
      5,
    );
    const body = Rect.fromLTWH(20, 42, 61, 32);
    c.drawOval(
      body,
      _gradient(body, const Color(0xFFD7AF83), const Color(0xFFBD8C65)),
    );
    c.drawPath(
      Path()
        ..moveTo(62, 52)
        ..quadraticBezierTo(61, 22, 69, 19)
        ..lineTo(80, 24)
        ..lineTo(79, 59)
        ..close(),
      Paint()..color = const Color(0xFFCFA378),
    );
    _oval(c, const Rect.fromLTWH(62, 12, 29, 23), const Color(0xFFD6B086));
    c.drawPath(
      Path()
        ..moveTo(66, 17)
        ..quadraticBezierTo(46, 0, 55, 2)
        ..quadraticBezierTo(69, 1, 72, 17)
        ..close(),
      Paint()..color = const Color(0xFFC69972),
    );
    c.drawPath(
      Path()
        ..moveTo(75, 16)
        ..quadraticBezierTo(80, -1, 86, 1)
        ..quadraticBezierTo(92, 9, 82, 19)
        ..close(),
      Paint()..color = const Color(0xFFC69972),
    );
    _oval(c, const Rect.fromLTWH(82, 22, 11, 11), const Color(0xFFE4C5A1));
    _oval(c, const Rect.fromLTWH(76, 19, 4, 5), _ink);
    _oval(c, const Rect.fromLTWH(77, 19, 1, 1.5), Colors.white);
    _oval(c, const Rect.fromLTWH(89, 25, 4, 4), const Color(0xFF6A584A));
    c.drawPath(
      Path()
        ..moveTo(22, 48)
        ..quadraticBezierTo(10, 32, 10, 47)
        ..quadraticBezierTo(15, 56, 23, 55)
        ..close(),
      Paint()..color = const Color(0xFFE5CDB1),
    );
    for (final point in const [
      Offset(32, 49),
      Offset(43, 47),
      Offset(54, 51),
      Offset(36, 58),
      Offset(48, 58),
    ]) {
      c.drawOval(
        Rect.fromCenter(center: point, width: 5, height: 3),
        Paint()..color = const Color(0xFFEAD1AA),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LifePainter old) =>
      kind != old.kind || phase != old.phase || silhouette != old.silhouette;
}

class _PetalPainter extends CustomPainter {
  const _PetalPainter({required this.phase});
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    const colors = [
      Color(0xFFEDAC8E),
      Color(0xFFF0D184),
      Color(0xFF82AF7B),
      Color(0xFF87BFBC),
    ];
    for (var i = 0; i < 35; i++) {
      final x = (i * .6180339 % 1) * size.width;
      final y = ((i * .2718 + phase * .65) % 1) * size.height;
      final opacity = (math.sin(phase * math.pi) * .85).clamp(0.0, .85);
      canvas.save();
      canvas.translate(x + math.sin(i + phase * 5) * 12, y);
      canvas.rotate(i + phase * math.pi);
      canvas.drawOval(
        const Rect.fromLTWH(-3, -5, 6, 10),
        Paint()..color = colors[i % 4].withValues(alpha: opacity),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _PetalPainter old) => phase != old.phase;
}

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/audio/app_audio_controller.dart';
import '../../../shared/audio/app_audio_scope.dart';
import '../../../shared/audio/app_sound_cue.dart';
import '../domain/find_my_sheep_model.dart';
import '../domain/mini_game.dart';

const _ink = Color(0xFF244C3D);
const _cream = Color(0xFFFFF9EC);

/// A little meadow reunion. Every scarf has a colour AND a visible pattern.
class FindMySheepEngine extends StatefulWidget {
  const FindMySheepEngine({
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
  State<FindMySheepEngine> createState() => _FindMySheepEngineState();
}

class _FindMySheepEngineState extends State<FindMySheepEngine>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  SheepReunionRun? _run;
  String? _selected;
  String? _hovered;
  String? _moving;
  String? _wrong;
  bool _sent = false;
  bool _foreground = true;
  bool _resumeMotion = false;
  bool _resumeReveal = false;
  AppAudioController? _audioOwner;
  MatchingGameFeedback? _feedback;
  late final AnimationController _motion =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 720),
        animationBehavior: AnimationBehavior.preserve,
      )..addStatusListener((status) {
        if (status != AnimationStatus.completed || !mounted) return;
        setState(() {
          _moving = null;
          _wrong = null;
        });
        if (_run?.isComplete == true && !_blocked) _reveal.forward(from: 0);
      });
  late final AnimationController _reveal =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1500),
        animationBehavior: AnimationBehavior.preserve,
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed && !_blocked) _submit();
      });

  bool get _blocked => widget.paused || !_foreground;
  bool get _busy => _moving != null || _run?.isComplete == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  void _load() {
    try {
      _run = SheepReunionRun(widget.level.config);
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
  void didUpdateWidget(covariant FindMySheepEngine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.level.id != widget.level.id) {
      _motion.reset();
      _reveal.reset();
      _selected = _hovered = _moving = _wrong = null;
      _sent = _resumeMotion = _resumeReveal = false;
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
      _resumeMotion = _resumeMotion || _motion.isAnimating;
      _resumeReveal = _resumeReveal || _reveal.isAnimating;
      _motion.stop(canceled: false);
      _reveal.stop(canceled: false);
    } else {
      if (_resumeMotion) _motion.forward();
      if (_resumeReveal) _reveal.forward();
      _resumeMotion = _resumeReveal = false;
      if (_run?.isComplete == true &&
          _motion.isCompleted &&
          !_reveal.isAnimating) {
        if (_reveal.isCompleted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_blocked) _submit();
          });
        } else {
          _reveal.forward();
        }
      }
    }
  }

  void _choose(LostLamb lamb) {
    if (_blocked || _busy || _sent || _run!.isPlaced(lamb.id)) return;
    setState(() {
      _selected = _selected == lamb.id ? null : lamb.id;
      _wrong = null;
    });
    HapticFeedback.selectionClick();
  }

  void _place(String item, String family) {
    if (_blocked || _busy || _sent || _run == null) return;
    final result = _run!.place(item, family);
    if (result == SheepPlacement.ignored) return;
    setState(() {
      _hovered = null;
      _selected = result == SheepPlacement.correct ? null : item;
      _moving = result == SheepPlacement.correct ? item : null;
      _wrong = result == SheepPlacement.wrong ? item : null;
    });
    _motion.forward(from: 0);
    if (result == SheepPlacement.correct) {
      _feedback?.play(
        _run!.isComplete ? AppSoundCue.success : AppSoundCue.select,
      );
      HapticFeedback.lightImpact();
    } else if (_run!.exhausted) {
      _submit();
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
    _motion.dispose();
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
        child: Center(child: Text('This meadow is being prepared.')),
      );
    }
    return TickerMode(
      enabled: !_blocked,
      child: ColoredBox(
        key: const Key('find-my-sheep-game'),
        color: _cream,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxHeight < 640;
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    children: [
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          16,
                          compact ? 4 : 12,
                          18,
                          8,
                        ),
                        child: Row(
                          children: [
                            if (widget.onExit != null) ...[
                              IconButton.filledTonal(
                                key: const Key('sheep-exit'),
                                onPressed: widget.onExit,
                                tooltip: 'Leave game',
                                style: IconButton.styleFrom(
                                  foregroundColor: _ink,
                                  backgroundColor: const Color(0xFFE7EDD9),
                                ),
                                icon: const Icon(Icons.arrow_back_rounded),
                              ),
                              const SizedBox(width: 10),
                            ],
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'A MEADOW REUNION',
                                    maxLines: 1,
                                    style: TextStyle(
                                      color: _ink.withValues(alpha: .62),
                                      letterSpacing: 1.6,
                                      fontSize: compact ? 9 : 10,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      'Find My Sheep',
                                      style: TextStyle(
                                        color: _ink,
                                        fontSize: compact ? 24 : 28,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: -.9,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 11,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE9EFDA),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Text(
                                '${run.matched} / ${run.lambs.length}',
                                key: const Key('sheep-progress'),
                                style: const TextStyle(
                                  color: _ink,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                        child: Row(
                          children: [
                            for (var i = 0; i < run.lambs.length; i++)
                              Expanded(
                                child: Container(
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 2,
                                  ),
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: i < run.matched
                                        ? const Color(0xFF7F9C53)
                                        : const Color(0xFFE3E7D4),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          18,
                          compact ? 10 : 16,
                          18,
                          compact ? 4 : 8,
                        ),
                        child: Text(
                          run.isComplete
                              ? 'Together again. Every lamb is home!'
                              : _wrong != null
                              ? 'Look for the same scarf pattern.'
                              : _selected != null
                              ? 'Now tap the family with the same scarf.'
                              : 'Match each little lamb to its family.',
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          style: TextStyle(
                            color: _ink,
                            fontSize: compact ? 12 : 14,
                            height: 1.3,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Expanded(child: _meadow(run, compact)),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          16,
                          5,
                          16,
                          compact ? 8 : 14,
                        ),
                        child: Text(
                          'DRAG A LAMB  ·  OR TAP A LAMB, THEN ITS FAMILY',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _ink.withValues(alpha: .6),
                            letterSpacing: .7,
                            fontSize: compact ? 8 : 9,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
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

  Widget _meadow(SheepReunionRun run, bool compact) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final lambW = math.min(size.width * .255, 115.0);
        final lambH = lambW * 1.12;
        final corralW = (size.width - 38) / 3;
        final corralH = math.min(size.height * .33, 180.0);
        final corralY = size.height - corralH - 8;
        final freeHeight = corralY - 10;
        final secondRow = math.min(freeHeight * .57, freeHeight - lambH - 4);
        // Offset rows leave an organic scatter, while retaining generous targets.
        final spots = [
          Offset(size.width * .045, freeHeight * .10),
          Offset(size.width * .385, freeHeight * .025),
          Offset(size.width * .70, freeHeight * .16),
          Offset(size.width * .085, secondRow - 5),
          Offset(size.width * .39, secondRow - freeHeight * .06),
          Offset(size.width * .705, secondRow),
        ];
        return ClipRect(
          child: Stack(
            children: [
              Positioned.fill(
                child: Image.asset(
                  'assets/images/games/matching/sheep_meadow.png',
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  excludeFromSemantics: true,
                ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        _cream.withValues(alpha: .05),
                        const Color(0xFFA7C37B).withValues(alpha: .05),
                        const Color(0xFFE1E6BE).withValues(alpha: .7),
                      ],
                      stops: const [0, .6, 1],
                    ),
                  ),
                ),
              ),
              for (var i = 0; i < run.families.length; i++)
                Positioned(
                  left: 12 + i * (corralW + 7),
                  top: corralY,
                  width: corralW,
                  height: corralH,
                  child: _family(run, run.families[i], compact),
                ),
              for (var i = 0; i < run.lambs.length; i++)
                if (!run.isPlaced(run.lambs[i].id))
                  AnimatedBuilder(
                    animation: _motion,
                    builder: (context, child) {
                      final shake = _wrong == run.lambs[i].id
                          ? math.sin(_motion.value * math.pi * 6) *
                                (1 - _motion.value) *
                                9
                          : 0.0;
                      return Positioned(
                        left: spots[i].dx + shake,
                        top: spots[i].dy,
                        width: lambW,
                        height: lambH,
                        child: child!,
                      );
                    },
                    child: _lamb(run.lambs[i], lambW, lambH),
                  ),
              if (_moving != null)
                AnimatedBuilder(
                  animation: _motion,
                  builder: (context, _) {
                    final index = run.lambs.indexWhere((l) => l.id == _moving);
                    final lamb = run.lambs[index];
                    final familyIndex = run.families.indexWhere(
                      (f) => f.id == run.familyFor(lamb.id),
                    );
                    final destination = Offset(
                      12 + familyIndex * (corralW + 7) + corralW * .12,
                      corralY + corralH * .25,
                    );
                    final t = Curves.easeInOutCubic.transform(_motion.value);
                    final spot = Offset.lerp(spots[index], destination, t)!;
                    final reduced = MediaQuery.disableAnimationsOf(context);
                    final hop = reduced
                        ? 0.0
                        : math.sin(_motion.value * math.pi * 5).abs() *
                              8 *
                              (1 - t);
                    return Positioned(
                      left: spot.dx,
                      top: spot.dy - hop,
                      width: lambW,
                      height: lambH,
                      child: IgnorePointer(
                        child: Transform.scale(
                          scale: 1 - t * .4,
                          child: _LambPicture(matchKey: lamb.matchKey),
                        ),
                      ),
                    );
                  },
                ),
              if (run.isComplete && _moving == null)
                Positioned(
                  left: 30,
                  right: 30,
                  top: size.height * .25,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: .92, end: 1).animate(
                      CurvedAnimation(
                        parent: _reveal,
                        curve: Curves.easeOutBack,
                      ),
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 18,
                        horizontal: 20,
                      ),
                      decoration: BoxDecoration(
                        color: _cream.withValues(alpha: .96),
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(
                          color: const Color(0xFFD8DFBF),
                          width: 2,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x22304D25),
                            blurRadius: 22,
                            offset: Offset(0, 7),
                          ),
                        ],
                      ),
                      child: const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.favorite_rounded,
                            color: Color(0xFFD8856E),
                            size: 30,
                          ),
                          SizedBox(height: 6),
                          Text(
                            'Home, sweet home.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _ink,
                              fontWeight: FontWeight.w800,
                              fontSize: 21,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'You brought every family together.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: _ink, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _lamb(LostLamb lamb, double width, double height) {
    final selected = _selected == lamb.id;
    final label = '${_label(lamb.matchKey)} lamb';
    final content = _LambPicture(matchKey: lamb.matchKey, selected: selected);
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      onTap: () => _choose(lamb),
      child: Draggable<String>(
        key: Key('sheep-lamb-${lamb.id}'),
        data: lamb.id,
        maxSimultaneousDrags: _blocked || _busy || _sent ? 0 : 1,
        onDragStarted: () {
          if (_blocked || _busy || _sent) return;
          setState(() => _selected = lamb.id);
        },
        feedback: Material(
          type: MaterialType.transparency,
          child: SizedBox(width: width, height: height, child: content),
        ),
        childWhenDragging: Opacity(opacity: .22, child: content),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _choose(lamb),
          child: content,
        ),
      ),
    );
  }

  Widget _family(SheepReunionRun run, SheepFamily family, bool compact) {
    final count = run.countFor(family.id);
    final visibleCount =
        count -
        (_moving != null && run.familyFor(_moving!) == family.id ? 1 : 0);
    final color = _familyColor(family.matchKey);
    final isHovered = _hovered == family.id;
    return Semantics(
      label:
          '${_label(family.matchKey)} family, $count of ${family.capacity} lambs home',
      button: true,
      onTap: () {
        if (_selected != null) _place(_selected!, family.id);
      },
      child: DragTarget<String>(
        onWillAcceptWithDetails: (details) {
          if (_blocked || _busy || _sent) return false;
          setState(() => _hovered = family.id);
          return true;
        },
        onLeave: (_) {
          if (mounted) setState(() => _hovered = null);
        },
        onAcceptWithDetails: (details) => _place(details.data, family.id),
        builder: (context, accepted, rejected) => GestureDetector(
          key: Key('sheep-family-${family.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (_selected != null) _place(_selected!, family.id);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              color: const Color(
                0xFFFFFBED,
              ).withValues(alpha: isHovered ? .94 : .67),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: color.withValues(alpha: isHovered ? .9 : .45),
                width: isHovered ? 3 : 1.5,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x12364C22),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: LayoutBuilder(
              builder: (context, box) {
                return Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(painter: _FencePainter()),
                    ),
                    Positioned(
                      left: box.maxWidth * .2,
                      top: 1,
                      width: box.maxWidth * .66,
                      height: box.maxHeight * .62,
                      child: _LambPicture(matchKey: family.matchKey),
                    ),
                    for (var i = 0; i < visibleCount; i++)
                      Positioned(
                        left: box.maxWidth * (.02 + i * .45),
                        top: box.maxHeight * .28,
                        width: box.maxWidth * .58,
                        height: box.maxHeight * .46,
                        child: _LambPicture(matchKey: family.matchKey),
                      ),
                    Positioned(
                      left: 3,
                      right: 3,
                      bottom: compact ? 8 : 10,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              for (var i = 0; i < family.capacity; i++)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 3,
                                  ),
                                  child: Icon(
                                    i < count
                                        ? Icons.favorite_rounded
                                        : Icons.favorite_border_rounded,
                                    color: color,
                                    size: compact ? 15 : 18,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              _label(family.matchKey),
                              style: TextStyle(
                                color: _ink,
                                fontSize: compact ? 10 : 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

String _label(String key) => key.replaceAll('_', ' ');

Color _familyColor(String key) => switch (key.split('_').first) {
  'coral' => const Color(0xFFD87661),
  'teal' => const Color(0xFF398E8A),
  'gold' => const Color(0xFFC59632),
  'forest' => const Color(0xFF537657),
  'sky' => const Color(0xFF6399BE),
  _ => const Color(0xFF997AAB),
};

class _LambPicture extends StatelessWidget {
  const _LambPicture({required this.matchKey, this.selected = false});

  final String matchKey;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        return Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              left: box.maxWidth * .13,
              right: box.maxWidth * .1,
              bottom: box.maxHeight * .11,
              height: box.maxHeight * .09,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF63734E).withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(40),
                ),
              ),
            ),
            if (selected)
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _cream.withValues(alpha: .55),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                        color: _familyColor(matchKey),
                        width: 2.5,
                      ),
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: Image.asset(
                'assets/images/games/matching/sheep_lamb.png',
                fit: BoxFit.contain,
                excludeFromSemantics: true,
              ),
            ),
            // The painted lamb is neutral; an actual cloth-shaped pattern patch
            // makes each matching family readable even without colour perception.
            Positioned(
              left: box.maxWidth * .20,
              top: box.maxHeight * .34,
              width: box.maxWidth * .36,
              height: box.maxHeight * .23,
              child: CustomPaint(painter: _ScarfPainter(matchKey)),
            ),
          ],
        );
      },
    );
  }
}

class _ScarfPainter extends CustomPainter {
  const _ScarfPainter(this.matchKey);
  final String matchKey;

  @override
  void paint(Canvas canvas, Size size) {
    final cloth = Path()
      ..moveTo(0, size.height * .12)
      ..quadraticBezierTo(
        size.width * .45,
        -size.height * .08,
        size.width,
        size.height * .09,
      )
      ..lineTo(size.width * .55, size.height)
      ..close();
    canvas.drawShadow(cloth, Colors.black26, 2, false);
    final color = _familyColor(matchKey);
    canvas.drawPath(
      cloth,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color, Color.lerp(color, const Color(0xFF624A38), .2)!],
        ).createShader(Offset.zero & size),
    );
    canvas.save();
    canvas.clipPath(cloth);
    final paint = Paint()
      ..color = const Color(0xFFFFF6DC)
      ..strokeWidth = math.max(1.4, size.width * .055);
    final pattern = matchKey.split('_').last;
    if (pattern == 'dots') {
      for (var y = size.height * .2; y < size.height; y += size.height * .24) {
        for (var x = size.width * .16; x < size.width; x += size.width * .27) {
          canvas.drawCircle(Offset(x, y), size.width * .05, paint);
        }
      }
    } else if (pattern == 'stripes') {
      for (var x = -size.height; x < size.width; x += size.width * .24) {
        canvas.drawLine(
          Offset(x, 0),
          Offset(x + size.height, size.height),
          paint,
        );
      }
    } else {
      paint.style = PaintingStyle.stroke;
      for (var y = 0.0; y < size.height; y += size.height * .32) {
        final zig = Path()..moveTo(-size.width * .1, y);
        for (var i = 0; i < 7; i++) {
          zig.lineTo(
            size.width * i / 6,
            y + (i.isEven ? 0 : size.height * .15),
          );
        }
        canvas.drawPath(zig, paint);
      }
    }
    canvas.restore();
    canvas.drawPath(
      cloth,
      Paint()
        ..color = const Color(0x44514A36)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .8,
    );
  }

  @override
  bool shouldRepaint(covariant _ScarfPainter oldDelegate) =>
      oldDelegate.matchKey != matchKey;
}

class _FencePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFC7A476);
    for (final y in [size.height * .56, size.height * .68]) {
      canvas.drawLine(Offset(6, y), Offset(size.width - 6, y), paint);
    }
    paint.color = const Color(0xFFD6B98C);
    paint.strokeWidth = 6;
    for (var i = 0; i < 4; i++) {
      final x = 9 + i * (size.width - 18) / 3;
      canvas.drawLine(
        Offset(x, size.height * .52),
        Offset(x, size.height * .73),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FencePainter oldDelegate) => false;
}

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/audio/app_audio_controller.dart';
import '../../../shared/audio/app_audio_scope.dart';
import '../../../shared/audio/app_sound_cue.dart';
import '../domain/esther_table_model.dart';
import '../domain/mini_game.dart';

const _ink = Color(0xFF29483F);
const _cream = Color(0xFFFFF8EB);
const _gold = Color(0xFFBD8B3B);
const _plum = Color(0xFF785078);
const _banquetAsset =
    'assets/images/games/matching/esther_banquet_fullscreen_v2.png';
const _banquetSourceSize = Size(1024, 1536);

/// Six illustrated requests become a shared banquet. Each ceramic setting is
/// both a generous drag target and a tap target for children using two taps.
class EstherTableEngine extends StatefulWidget {
  const EstherTableEngine({
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
  State<EstherTableEngine> createState() => _EstherTableEngineState();
}

class _EstherTableEngineState extends State<EstherTableEngine>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  EstherTableRun? _run;
  String? _selected;
  String? _hovered;
  String? _recent;
  String? _wrong;
  bool _sent = false;
  bool _instructionsOpen = true;
  bool _foreground = true;
  bool _resumePlace = false;
  bool _resumeReveal = false;
  AppAudioController? _audioOwner;
  MatchingGameFeedback? _feedback;
  late final _instructionEnter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 440),
    animationBehavior: AnimationBehavior.preserve,
  );
  late final _placement = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
    animationBehavior: AnimationBehavior.preserve,
  );
  late final _reveal =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1700),
        animationBehavior: AnimationBehavior.preserve,
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed && !_blocked) _submit();
      });

  bool get _appBlocked => widget.paused || !_foreground;
  bool get _blocked => _appBlocked || _instructionsOpen;
  bool get _reduced => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncPause();
    });
  }

  void _load() {
    try {
      _run = EstherTableRun(widget.level.config);
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
  void didUpdateWidget(covariant EstherTableEngine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.level.id != widget.level.id) {
      _instructionEnter.reset();
      _instructionsOpen = true;
      _placement.reset();
      _reveal.reset();
      _selected = _hovered = _recent = _wrong = null;
      _sent = _resumePlace = _resumeReveal = false;
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
    if (_appBlocked) {
      _instructionEnter.stop(canceled: false);
    } else if (_instructionsOpen && !_instructionEnter.isCompleted) {
      if (_reduced) {
        _instructionEnter.value = 1;
      } else {
        _instructionEnter.forward();
      }
    }
    _feedback?.setPaused(_blocked || _sent);
    if (_blocked) {
      _resumePlace = _resumePlace || _placement.isAnimating;
      _resumeReveal = _resumeReveal || _reveal.isAnimating;
      _placement.stop(canceled: false);
      _reveal.stop(canceled: false);
    } else {
      if (_resumePlace) _placement.forward();
      if (_resumeReveal) _reveal.forward();
      _resumePlace = _resumeReveal = false;
      if (_reveal.isCompleted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_blocked) _submit();
        });
      }
    }
  }

  void _dismissInstructions() {
    if (_appBlocked || !_instructionsOpen) return;
    setState(() => _instructionsOpen = false);
    _instructionEnter.stop(canceled: false);
    _syncPause();
  }

  void _choose(String itemId) {
    final run = _run;
    if (_blocked ||
        _sent ||
        run == null ||
        run.isComplete ||
        run.isUsed(itemId)) {
      return;
    }
    HapticFeedback.selectionClick();
    _feedback?.play(AppSoundCue.select);
    setState(() {
      _selected = _selected == itemId ? null : itemId;
      _wrong = null;
    });
  }

  void _place(String itemId, String targetId) {
    final run = _run;
    if (_blocked || _sent || run == null) return;
    final outcome = run.place(itemId, targetId);
    if (outcome == EstherPlacement.ignored) return;
    setState(() {
      _hovered = null;
      _wrong = outcome == EstherPlacement.wrong ? targetId : null;
      _recent = outcome == EstherPlacement.correct ? targetId : null;
      _selected = outcome == EstherPlacement.correct ? null : itemId;
    });
    _placement.forward(from: 0);
    if (outcome == EstherPlacement.correct) {
      HapticFeedback.lightImpact();
      _feedback?.play(AppSoundCue.select);
      if (run.isComplete) {
        _feedback?.play(AppSoundCue.success);
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
    _instructionEnter.dispose();
    _placement.dispose();
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
              'The celebration table is being prepared. Try another round.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return TickerMode(
      enabled: !_appBlocked,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final insets = MediaQuery.paddingOf(context);
          final compact = size.height < 700;
          final controlsTop = insets.top + 10;
          final trayHeight = (compact ? 150.0 : 183.0) + 11;
          final trayBottom = insets.bottom + 4;
          final trayTop = size.height - trayBottom - trayHeight;
          final imageScale = math.max(
            size.width / _banquetSourceSize.width,
            size.height / _banquetSourceSize.height,
          );
          final artSize = _banquetSourceSize * imageScale;
          final artRect = Rect.fromLTWH(
            (size.width - artSize.width) / 2,
            0,
            artSize.width,
            artSize.height,
          );
          return Stack(
            key: const Key('esther-table-game'),
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: Image.asset(
                  _banquetAsset,
                  key: const Key('esther-banquet-background'),
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  excludeFromSemantics: true,
                ),
              ),
              Positioned.fill(child: _scene(run, compact, artRect, trayTop)),
              if (widget.onExit != null)
                Positioned(
                  top: controlsTop,
                  left: 16,
                  width: 48,
                  height: 48,
                  child: DecoratedBox(
                    decoration: _controlDecoration,
                    child: Semantics(
                      button: true,
                      label: 'Leave celebration table',
                      child: InkResponse(
                        key: const Key('esther-exit'),
                        onTap: _blocked ? null : widget.onExit,
                        radius: 27,
                        child: const Center(
                          child: Icon(
                            Icons.arrow_back_rounded,
                            color: _ink,
                            size: 25,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: controlsTop,
                right: 16,
                width: 72,
                height: 48,
                child: DecoratedBox(
                  key: const Key('esther-progress-badge'),
                  decoration: _controlDecoration,
                  child: Semantics(
                    liveRegion: true,
                    label: '${run.matched} of 6 dishes served',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 8,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '${run.matched} / 6',
                          style: const TextStyle(
                            color: _ink,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: trayBottom,
                height: trayHeight,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: _tray(run, compact),
                  ),
                ),
              ),
              if (_instructionsOpen)
                Positioned.fill(child: _instructions(compact)),
            ],
          );
        },
      ),
    );
  }

  BoxDecoration get _controlDecoration => BoxDecoration(
    color: _cream.withValues(alpha: .96),
    borderRadius: BorderRadius.circular(18),
    border: Border.all(color: const Color(0xFFE3CCA0), width: 1.4),
    boxShadow: const [
      BoxShadow(color: Color(0x33654824), blurRadius: 12, offset: Offset(0, 4)),
    ],
  );

  Widget _instructions(bool compact) {
    return Stack(
      key: const Key('esther-instructions-overlay'),
      fit: StackFit.expand,
      children: [
        const ModalBarrier(dismissible: false, color: Color(0x6B2F281B)),
        SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: AnimatedBuilder(
                animation: _instructionEnter,
                builder: (context, child) {
                  final t = _reduced
                      ? 1.0
                      : Curves.easeOutCubic.transform(_instructionEnter.value);
                  return Opacity(
                    opacity: t,
                    child: Transform.translate(
                      offset: Offset(0, 22 * (1 - t)),
                      child: Transform.scale(
                        scale: .94 + .06 * t,
                        child: child,
                      ),
                    ),
                  );
                },
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 352),
                  child: Semantics(
                    scopesRoute: true,
                    explicitChildNodes: true,
                    namesRoute: true,
                    label: 'How to play',
                    child: Container(
                      padding: EdgeInsets.fromLTRB(
                        22,
                        12,
                        22,
                        compact ? 20 : 26,
                      ),
                      decoration: BoxDecoration(
                        color: _cream,
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(
                          color: const Color(0xFFE8D3AA),
                          width: 2,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x4D2D251A),
                            blurRadius: 28,
                            offset: Offset(0, 12),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Align(
                            alignment: Alignment.centerRight,
                            child: IconButton(
                              key: const Key('esther-instructions-close'),
                              tooltip: 'Close instructions',
                              onPressed: _appBlocked
                                  ? null
                                  : _dismissInstructions,
                              icon: const Icon(
                                Icons.close_rounded,
                                color: _ink,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: compact ? 88 : 108,
                            height: compact ? 88 : 108,
                            child: CustomPaint(
                              painter: const _ServingPlatePainter(filled: true),
                              child: const Padding(
                                padding: EdgeInsets.all(14),
                                child: CustomPaint(
                                  painter: _FoodPainter('bread'),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            'A place for everyone',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _ink,
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              height: 1.15,
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'Match each dish to its place at the table.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _ink,
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              height: 1.35,
                            ),
                          ),
                          const SizedBox(height: 22),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              key: const Key('esther-instructions-play'),
                              onPressed: _appBlocked
                                  ? null
                                  : _dismissInstructions,
                              style: FilledButton.styleFrom(
                                backgroundColor: _ink,
                                foregroundColor: _cream,
                                minimumSize: const Size.fromHeight(50),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(17),
                                ),
                              ),
                              child: const Text(
                                'Let’s play',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _scene(
    EstherTableRun run,
    bool compact,
    Rect artRect,
    double trayTop,
  ) {
    return ClipRect(
      key: const Key('esther-banquet-scene'),
      child: LayoutBuilder(
        builder: (context, bounds) {
          final width = bounds.maxWidth;
          final tableTop = artRect.top + artRect.height * .40;
          final labelHeight = compact ? 0.0 : 15.0;
          const gap = 4.0;
          final tableBottom = trayTop - 6;
          final edge = math
              .min(
                66.0,
                (tableBottom - tableTop - gap * 2) / 3 - labelHeight - 8,
              )
              .clamp(36.0, 66.0);
          final targetHeight = edge + labelHeight + 8;
          final lastCenter = tableBottom - targetHeight / 2;
          final firstCenter = math.min(
            artRect.top + artRect.height * .48,
            lastCenter - 2 * (targetHeight + gap),
          );
          final centers = [
            firstCenter,
            (firstCenter + lastCenter) / 2,
            lastCenter,
          ];
          const settings = [.31, .71, .24, .76, .22, .80];
          return Stack(
            fit: StackFit.expand,
            children: [
              for (var index = 0; index < run.targets.length; index++)
                Positioned(
                  left:
                      (artRect.left +
                              settings[index] * artRect.width -
                              (edge + 8) / 2)
                          .clamp(12.0, width - edge - 20),
                  top: centers[index ~/ 2] - targetHeight / 2,
                  width: edge + 8,
                  height: targetHeight,
                  child: _target(run.targets[index], edge, run, compact),
                ),
              if (run.isComplete)
                Positioned(
                  left: width * .39,
                  width: width * .22,
                  top: firstCenter,
                  height: math.max(50, lastCenter - firstCenter),
                  child: Image.asset(
                    'assets/images/games/matching/banquet_feast.png',
                    fit: BoxFit.contain,
                    excludeFromSemantics: true,
                  ),
                ),
              if (run.isComplete)
                IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _reveal,
                    builder: (context, _) => CustomPaint(
                      painter: _PetalsPainter(
                        progress: _reduced ? 1 : _reveal.value,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _target(
    EstherPlaceSetting target,
    double edge,
    EstherTableRun run,
    bool compact,
  ) {
    final filled = run.isFilled(target.id);
    return DragTarget<String>(
      key: Key('esther-target-${target.id}'),
      onWillAcceptWithDetails: (details) {
        if (_blocked || _sent || filled || run.isUsed(details.data)) {
          return false;
        }
        setState(() => _hovered = target.id);
        return true;
      },
      onLeave: (_) {
        if (mounted) setState(() => _hovered = null);
      },
      onAcceptWithDetails: (details) => _place(details.data, target.id),
      builder: (context, _, _) => Semantics(
        button: !filled,
        excludeSemantics: true,
        onTap: _selected == null || filled || _blocked || _sent
            ? null
            : () => _place(_selected!, target.id),
        label: filled
            ? 'Served ${_foodName(target.matchKey)}'
            : 'Place ${_foodName(target.matchKey)} here',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _selected == null || filled || _blocked || _sent
              ? null
              : () => _place(_selected!, target.id),
          child: AnimatedBuilder(
            animation: _placement,
            builder: (context, child) {
              final pulse = _reduced
                  ? 0.0
                  : math.sin(_placement.value * math.pi);
              final shake = _wrong == target.id
                  ? math.sin(_placement.value * math.pi * 5) *
                        4 *
                        (1 - _placement.value)
                  : 0.0;
              return Transform.translate(
                offset: Offset(shake, 0),
                child: Transform.scale(
                  scale: _recent == target.id ? 1 + pulse * .08 : 1,
                  child: child,
                ),
              );
            },
            child: Column(
              children: [
                SizedBox(
                  height: edge + 8,
                  width: edge + 8,
                  child: CustomPaint(
                    painter: _ServingPlatePainter(
                      filled: filled,
                      highlighted: _hovered == target.id,
                      wrong: _wrong == target.id && _placement.value < 1,
                    ),
                    child: Padding(
                      padding: EdgeInsets.all(edge * .12),
                      child: Opacity(
                        opacity: filled ? 1 : .45,
                        child: CustomPaint(
                          painter: _FoodPainter(target.matchKey),
                        ),
                      ),
                    ),
                  ),
                ),
                if (!compact)
                  SizedBox(
                    height: 15,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _foodName(target.matchKey),
                        style: TextStyle(
                          color: filled ? _ink : const Color(0xFF695A46),
                          fontSize: 11,
                          height: 1,
                          fontWeight: filled
                              ? FontWeight.w800
                              : FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tray(EstherTableRun run, bool compact) {
    final height = compact ? 150.0 : 183.0;
    return Container(
      key: const Key('esther-floating-tray'),
      height: height,
      margin: const EdgeInsets.fromLTRB(12, 3, 12, 8),
      padding: const EdgeInsets.fromLTRB(11, 7, 11, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF0E4C9),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFE1CCA1), width: 1.4),
        boxShadow: const [
          BoxShadow(
            color: Color(0x126C4D20),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          SizedBox(
            height: 22,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                run.isComplete
                    ? 'EVERYONE IS WELCOME'
                    : 'CHOOSE A DISH · TAP OR DRAG',
                style: const TextStyle(
                  color: Color(0xFF80694B),
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                  fontSize: 10,
                ),
              ),
            ),
          ),
          Expanded(
            child: Column(
              children: [
                for (var row = 0; row < 2; row++)
                  Expanded(
                    child: Row(
                      children: [
                        for (var column = 0; column < 3; column++)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(3),
                              child: _item(run.items[row * 3 + column], run),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _item(EstherServingItem item, EstherTableRun run) {
    final used = run.isUsed(item.id);
    final selected = _selected == item.id;
    final tile = AnimatedContainer(
      duration: _reduced ? Duration.zero : const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: used ? const Color(0xFFE9DDBF) : const Color(0xFFFFFCF3),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: selected
              ? _plum
              : used
              ? Colors.transparent
              : const Color(0xFFE0CFAC),
          width: selected ? 2.5 : 1,
        ),
        boxShadow: used
            ? null
            : const [
                BoxShadow(
                  color: Color(0x14654921),
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
      ),
      child: used
          ? const Center(
              child: Text(
                'Served',
                style: TextStyle(
                  color: Color(0xFF9C8B69),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  flex: 3,
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: CustomPaint(painter: _FoodPainter(item.matchKey)),
                    ),
                  ),
                ),
                Flexible(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _foodName(item.matchKey),
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
    return Semantics(
      button: !used,
      selected: selected,
      label: used
          ? '${_foodName(item.matchKey)} served'
          : 'Choose ${_foodName(item.matchKey)}',
      child: Draggable<String>(
        key: Key('esther-item-${item.id}'),
        data: item.id,
        maxSimultaneousDrags: used || _blocked || _sent || run.isComplete
            ? 0
            : 1,
        onDragStarted: () => _choose(item.id),
        feedback: Material(
          color: Colors.transparent,
          child: SizedBox(
            width: 84,
            height: 84,
            child: CustomPaint(
              painter: const _ServingPlatePainter(filled: true),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: CustomPaint(painter: _FoodPainter(item.matchKey)),
              ),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: .28, child: tile),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: used ? null : () => _choose(item.id),
          child: tile,
        ),
      ),
    );
  }
}

String _foodName(String key) => switch (key) {
  'bread' => 'Bread',
  'grapes' => 'Grapes',
  'figs' => 'Figs',
  'water' => 'Water',
  'flowers' => 'Flowers',
  'dates' => 'Dates',
  _ => key,
};

class _ServingPlatePainter extends CustomPainter {
  const _ServingPlatePainter({
    this.filled = false,
    this.highlighted = false,
    this.wrong = false,
  });
  final bool filled;
  final bool highlighted;
  final bool wrong;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 4;
    canvas.drawCircle(
      center + const Offset(0, 3),
      radius,
      Paint()..color = const Color(0x25754F28),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xFFFFFEF9), Color(0xFFEDE8DA)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawCircle(
      center,
      radius - 2,
      Paint()
        ..color = wrong
            ? _plum
            : highlighted
            ? const Color(0xFF3E9274)
            : _gold
        ..style = PaintingStyle.stroke
        ..strokeWidth = highlighted ? 3 : 1.7,
    );
    canvas.drawCircle(
      center,
      radius * .75,
      Paint()
        ..color = const Color(0xFFE2D7BF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .8,
    );
    for (var i = 0; i < 12; i++) {
      final angle = i * math.pi / 6;
      final dot =
          center + Offset(math.cos(angle), math.sin(angle)) * (radius * .86);
      canvas.drawCircle(dot, 1, Paint()..color = _gold.withValues(alpha: .55));
    }
    if (filled) {
      canvas.drawCircle(
        center,
        radius * .72,
        Paint()..color = const Color(0x13DCB963),
      );
    }
  }

  @override
  bool shouldRepaint(_ServingPlatePainter oldDelegate) =>
      oldDelegate.filled != filled ||
      oldDelegate.highlighted != highlighted ||
      oldDelegate.wrong != wrong;
}

/// Original painted serving illustrations share a soft outline and highlights,
/// while their shapes and colors remain distinguishable without reading labels.
class _FoodPainter extends CustomPainter {
  const _FoodPainter(this.food);
  final String food;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    final scale = math.min(size.width, size.height) / 100;
    canvas.translate(
      (size.width - scale * 100) / 2,
      (size.height - scale * 100) / 2,
    );
    canvas.scale(scale);
    switch (food) {
      case 'bread':
        _bread(canvas);
      case 'grapes':
        _grapes(canvas);
      case 'figs':
        _figs(canvas);
      case 'water':
        _water(canvas);
      case 'flowers':
        _flowers(canvas);
      case 'dates':
        _dates(canvas);
    }
    canvas.restore();
  }

  void _shadow(Canvas canvas, Rect rect) =>
      canvas.drawOval(rect, Paint()..color = const Color(0x207C5B38));

  void _bread(Canvas canvas) {
    _shadow(canvas, const Rect.fromLTWH(12, 69, 79, 15));
    final loaf = Path()
      ..moveTo(12, 61)
      ..cubicTo(4, 36, 33, 21, 51, 21)
      ..cubicTo(80, 16, 95, 35, 91, 53)
      ..cubicTo(89, 75, 25, 85, 12, 61)
      ..close();
    canvas.drawPath(
      loaf,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFFF5CE7B), Color(0xFFC1803C)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ).createShader(const Rect.fromLTWH(8, 20, 85, 60)),
    );
    canvas.drawPath(
      loaf,
      Paint()
        ..color = const Color(0xFFAD6C2D)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    for (var i = 0; i < 3; i++) {
      final x = 30.0 + i * 18;
      final score = Path()
        ..moveTo(x, 36 - i * 2)
        ..quadraticBezierTo(x - 7, 47, x + 1, 55);
      canvas.drawPath(
        score,
        Paint()
          ..color = const Color(0xFFFCE4A1)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawPath(
        score.shift(const Offset(1, 1)),
        Paint()
          ..color = const Color(0xFFC48D44)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round,
      );
    }
    for (final p in [
      const Offset(21, 57),
      const Offset(67, 64),
      const Offset(78, 43),
      const Offset(43, 63),
    ]) {
      canvas.drawOval(
        Rect.fromCenter(center: p, width: 4, height: 1.8),
        Paint()..color = const Color(0xFFFFE4A1),
      );
    }
  }

  void _grapes(Canvas canvas) {
    _shadow(canvas, const Rect.fromLTWH(26, 77, 53, 11));
    final leaf = Path()
      ..moveTo(49, 29)
      ..cubicTo(22, 24, 27, 8, 45, 12)
      ..quadraticBezierTo(59, 6, 66, 13)
      ..quadraticBezierTo(68, 25, 49, 29)
      ..close();
    canvas.drawPath(leaf, Paint()..color = const Color(0xFF70945A));
    canvas.drawLine(
      const Offset(52, 29),
      const Offset(61, 12),
      Paint()
        ..color = const Color(0xFF726039)
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    final berries = [
      const Offset(36, 35),
      const Offset(55, 34),
      const Offset(73, 39),
      const Offset(26, 50),
      const Offset(46, 51),
      const Offset(65, 55),
      const Offset(37, 68),
      const Offset(55, 71),
      const Offset(46, 84),
    ];
    for (final center in berries) {
      canvas.drawCircle(
        center,
        10.5,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(-.35, -.45),
            colors: [Color(0xFFB18ABC), Color(0xFF765080)],
          ).createShader(Rect.fromCircle(center: center, radius: 11)),
      );
      canvas.drawCircle(
        center,
        10.5,
        Paint()
          ..color = const Color(0xFF624469)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
      canvas.drawCircle(
        center + const Offset(-3, -3.5),
        2.3,
        Paint()..color = const Color(0x77EAD1E9),
      );
    }
  }

  void _figs(Canvas canvas) {
    _shadow(canvas, const Rect.fromLTWH(11, 76, 80, 12));
    final whole = Path()
      ..moveTo(31, 17)
      ..cubicTo(29, 36, 6, 45, 12, 67)
      ..cubicTo(17, 91, 58, 89, 61, 66)
      ..cubicTo(63, 44, 39, 35, 37, 17)
      ..close();
    canvas.drawPath(
      whole,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFFB38BAB), Color(0xFF76517B)],
        ).createShader(const Rect.fromLTWH(10, 16, 54, 72)),
    );
    canvas.drawLine(
      const Offset(33, 19),
      const Offset(35, 10),
      Paint()
        ..color = const Color(0xFF76854E)
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );
    final half = Path()
      ..moveTo(70, 31)
      ..cubicTo(69, 49, 47, 54, 49, 71)
      ..cubicTo(51, 92, 93, 90, 93, 71)
      ..cubicTo(92, 52, 76, 48, 76, 31)
      ..close();
    canvas.drawPath(half, Paint()..color = const Color(0xFF6B4A6C));
    canvas.save();
    canvas.translate(71, 60);
    canvas.scale(.81);
    canvas.translate(-71, -60);
    canvas.drawPath(half, Paint()..color = const Color(0xFFF2D5AC));
    canvas.save();
    canvas.translate(71, 62);
    canvas.scale(.8);
    canvas.translate(-71, -62);
    canvas.drawPath(half, Paint()..color = const Color(0xFFC57475));
    for (var i = 0; i < 20; i++) {
      final a = i * 2.4;
      final r = 3.0 + (i % 4) * 3;
      canvas.drawCircle(
        Offset(71 + math.cos(a) * r, 68 + math.sin(a) * r),
        .9,
        Paint()..color = const Color(0xFFF8D28D),
      );
    }
    canvas.restore();
    canvas.restore();
  }

  void _water(Canvas canvas) {
    _shadow(canvas, const Rect.fromLTWH(24, 78, 54, 12));
    final cup = Path()
      ..moveTo(24, 27)
      ..lineTo(77, 27)
      ..lineTo(71, 76)
      ..quadraticBezierTo(50, 87, 30, 76)
      ..close();
    canvas.drawPath(
      cup,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFF7DB8C2), Color(0xFF43808D), Color(0xFF8CC4CA)],
        ).createShader(const Rect.fromLTWH(24, 27, 53, 57)),
    );
    final handle = Path()
      ..moveTo(76, 37)
      ..cubicTo(100, 33, 98, 67, 74, 64);
    canvas.drawPath(
      handle,
      Paint()
        ..color = const Color(0xFF4D8A94)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawOval(
      const Rect.fromLTWH(23, 18, 55, 18),
      Paint()..color = const Color(0xFFD8EFE6),
    );
    canvas.drawOval(
      const Rect.fromLTWH(28, 22, 45, 10),
      Paint()..color = const Color(0xFF77B5CE),
    );
    canvas.drawArc(
      const Rect.fromLTWH(34, 23, 29, 6),
      math.pi,
      math.pi,
      false,
      Paint()
        ..color = const Color(0xFFBCE5E9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    canvas.drawLine(
      const Offset(33, 39),
      const Offset(36, 67),
      Paint()
        ..color = const Color(0x99C5E6DE)
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      const Offset(38, 73),
      const Offset(65, 73),
      Paint()
        ..color = const Color(0xFFDAC47B)
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  void _flowers(Canvas canvas) {
    _shadow(canvas, const Rect.fromLTWH(23, 80, 56, 9));
    for (final branch in [
      const Offset(32, 32),
      const Offset(52, 20),
      const Offset(73, 38),
    ]) {
      canvas.drawLine(
        const Offset(51, 77),
        branch,
        Paint()
          ..color = const Color(0xFF6C8D58)
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset((51 + branch.dx) / 2 + 7, (77 + branch.dy) / 2),
          width: 17,
          height: 7,
        ),
        Paint()..color = const Color(0xFF8BA86B),
      );
      for (var p = 0; p < 5; p++) {
        final angle = p * math.pi * 2 / 5;
        canvas.drawCircle(
          branch + Offset(math.cos(angle), math.sin(angle)) * 7,
          6.5,
          Paint()
            ..color = branch.dx < 40
                ? const Color(0xFFEBA08A)
                : const Color(0xFFECCAB1),
        );
      }
      canvas.drawCircle(branch, 4, Paint()..color = const Color(0xFFD4A553));
    }
    final ribbon = Path()
      ..moveTo(42, 70)
      ..quadraticBezierTo(25, 60, 31, 78)
      ..lineTo(49, 75)
      ..quadraticBezierTo(69, 62, 67, 80)
      ..lineTo(50, 76)
      ..lineTo(46, 91)
      ..lineTo(39, 86)
      ..lineTo(45, 76)
      ..close();
    canvas.drawPath(ribbon, Paint()..color = const Color(0xFFB184A6));
  }

  void _dates(Canvas canvas) {
    _shadow(canvas, const Rect.fromLTWH(11, 75, 80, 14));
    canvas.drawOval(
      const Rect.fromLTWH(8, 50, 84, 34),
      Paint()..color = const Color(0xFFCCA86B),
    );
    canvas.drawOval(
      const Rect.fromLTWH(11, 48, 78, 24),
      Paint()..color = const Color(0xFFF4DCA0),
    );
    for (var i = 0; i < 5; i++) {
      canvas.save();
      canvas.translate(24.0 + i % 3 * 23, 44.0 + i ~/ 3 * 16);
      canvas.rotate((i.isEven ? -.35 : .3));
      final date = RRect.fromRectAndRadius(
        const Rect.fromLTWH(-9, -16, 18, 32),
        const Radius.circular(9),
      );
      canvas.drawRRect(
        date,
        Paint()
          ..shader = const LinearGradient(
            colors: [Color(0xFFBD7C49), Color(0xFF7A4A31)],
          ).createShader(const Rect.fromLTWH(-9, -16, 18, 32)),
      );
      final crease = Path()
        ..moveTo(-1, -11)
        ..quadraticBezierTo(3, 0, -1, 11);
      canvas.drawPath(
        crease,
        Paint()
          ..color = const Color(0xFF653F2A)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawLine(
        const Offset(-4, -9),
        const Offset(-5, 6),
        Paint()
          ..color = const Color(0x77F0B67B)
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_FoodPainter oldDelegate) => oldDelegate.food != food;
}

class _PetalsPainter extends CustomPainter {
  const _PetalsPainter({required this.progress});
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const colors = [
      Color(0xFFD7AE5C),
      Color(0xFFD99485),
      Color(0xFF95AB77),
      Color(0xFFB394B4),
    ];
    for (var i = 0; i < 34; i++) {
      final seed = (i * 37 % 101) / 101;
      final y = size.height * ((seed + progress * .7) % 1);
      final x =
          size.width * ((i * 61 % 97) / 97) +
          math.sin(progress * math.pi * 2 + i) * 12;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(i + progress * 3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(-2, -4, 4, 8),
          const Radius.circular(2),
        ),
        Paint()..color = colors[i % colors.length].withValues(alpha: .8),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_PetalsPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

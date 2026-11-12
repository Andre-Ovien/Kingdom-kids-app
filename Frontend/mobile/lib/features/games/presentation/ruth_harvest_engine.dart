import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/audio/app_audio_controller.dart';
import '../../../shared/audio/app_audio_scope.dart';
import '../../../shared/audio/app_sound_cue.dart';
import '../domain/mini_game.dart';
import '../domain/ruth_harvest_model.dart';

const _ink = Color(0xFF34452C);
const _olive = Color(0xFF667C42);
const _paper = Color(0xFFFFF9E9);
const _gold = Color(0xFFEBAC49);
const _assetRoot = 'assets/images/games/matching/';

/// A tactile, unhurried chain-matching field. Only the selected cell indices
/// leave the device; the server recreates the board and harvest independently.
class RuthHarvestEngine extends StatefulWidget {
  const RuthHarvestEngine({
    required this.level,
    required this.onComplete,
    this.onExit,
    this.paused = false,
    super.key,
  });

  final GameLevel level;
  final void Function(Map<String, dynamic>) onComplete;
  final VoidCallback? onExit;
  final bool paused;

  @override
  State<RuthHarvestEngine> createState() => _RuthHarvestEngineState();
}

class _RuthHarvestEngineState extends State<RuthHarvestEngine>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late RuthHarvestModel _field;
  late final AnimationController _gather;
  RuthHarvestMove? _move;
  AppAudioController? _audio;
  MatchingGameFeedback? _feedbackAudio;
  final List<int> _selection = [];
  List<int> _hint = [];
  bool _submitted = false;
  bool _foreground = true;
  bool _resumeMotion = false;
  bool _dragging = false;
  bool _celebrateLanding = false;
  Offset? _lastPointer;
  Offset? _pointerStart;
  String? _feedback;
  final _boardKey = GlobalKey();

  bool get _isPaused => widget.paused || !_foreground;
  bool get _busy => _move != null || _submitted || _isPaused;
  bool get _reduceMotion =>
      MediaQuery.disableAnimationsOf(context) ||
      MediaQuery.accessibleNavigationOf(context);

  @override
  void initState() {
    super.initState();
    _field = RuthHarvestModel.fromConfig(widget.level.config);
    _hint = _field.findMatch() ?? [];
    _feedback = 'Trace the trail, or tap matching bundles.';
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _gather = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 820),
    )..addStatusListener(_motionStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final audio = AppAudioScope.maybeOf(context);
    if (!identical(audio, _audio)) {
      _feedbackAudio?.dispose();
      _audio = audio;
      _feedbackAudio = audio?.createMatchingFeedback(paused: _isPaused);
    }
  }

  @override
  void didUpdateWidget(covariant RuthHarvestEngine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.level.id != widget.level.id) {
      _gather.stop();
      _field = RuthHarvestModel.fromConfig(widget.level.config);
      _selection.clear();
      _hint = _field.findMatch() ?? [];
      _move = null;
      _feedback = 'Trace the trail, or tap matching bundles.';
      _submitted = false;
      _resumeMotion = false;
      _celebrateLanding = false;
    }
    _syncPause();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncPause();
  }

  void _syncPause() {
    _feedbackAudio?.setPaused(_isPaused);
    if (_isPaused && _gather.isAnimating) {
      _resumeMotion = true;
      _gather.stop();
    } else if (!_isPaused && _resumeMotion && _move != null) {
      _resumeMotion = false;
      _gather.forward();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gather.removeStatusListener(_motionStatus);
    _gather.dispose();
    _feedbackAudio?.dispose();
    super.dispose();
  }

  void _motionStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    if (_celebrateLanding && !_isPaused) {
      _feedbackAudio?.play(AppSoundCue.success);
    }
    _celebrateLanding = false;
    setState(() => _move = null);
    _finishIfNeeded();
  }

  void _finishIfNeeded() {
    if (!_field.finished || _submitted || _isPaused) return;
    _submitted = true;
    widget.onComplete(_field.result);
  }

  Rect _boardRect(Size size) => Rect.fromLTWH(
    10,
    12,
    math.max(0, size.width - 20),
    math.max(0, size.height - 24),
  );

  Offset _center(int cell, Rect board) => Offset(
    board.left + (cell % _field.columns + .5) * board.width / _field.columns,
    board.top + (cell ~/ _field.columns + .5) * board.height / _field.rows,
  );

  int? _cell(Offset point, Rect board) {
    if (!board.contains(point) || board.isEmpty) return null;
    final column = ((point.dx - board.left) / board.width * _field.columns)
        .floor();
    final row = ((point.dy - board.top) / board.height * _field.rows).floor();
    final cell = row * _field.columns + column;
    // A generous target remains forgiving without selecting a diagonal merely
    // because the finger clips the outer corner of a neighbouring stalk.
    final center = _center(cell, board);
    final dx = (point.dx - center.dx) / (board.width / _field.columns);
    final dy = (point.dy - center.dy) / (board.height / _field.rows);
    return dx * dx + dy * dy <= .37 ? cell : null;
  }

  void _select(int cell, {bool restart = false}) {
    if (_busy) return;
    if (restart) {
      _selection.clear();
      _hint = [];
    }
    if (_selection.isEmpty) {
      setState(() {
        _selection.add(cell);
        _feedback = null;
        _hint = [];
      });
      HapticFeedback.selectionClick();
      return;
    }
    if (_selection.last == cell) return;
    if (_selection.length > 1 && _selection[_selection.length - 2] == cell) {
      setState(() => _selection.removeLast());
      return;
    }
    if (_selection.contains(cell) || !_field.adjacent(_selection.last, cell)) {
      return;
    }
    if (_field.board[cell] != _field.board[_selection.first]) {
      return;
    }
    setState(() {
      _selection.add(cell);
      _feedback = null;
      _hint = [];
    });
    HapticFeedback.selectionClick();
  }

  void _tapCell(int cell) {
    if (_busy) return;
    if (_selection.length == 1 && _selection.single == cell) {
      setState(_selection.clear);
      return;
    }
    if (_selection.isNotEmpty &&
        !_selection.contains(cell) &&
        (_field.board[cell] != _field.board[_selection.first] ||
            !_field.adjacent(_selection.last, cell))) {
      setState(
        () => _feedback = 'Stay with the same grain, one neighbour at a time.',
      );
      return;
    }
    _select(cell);
  }

  void _dragStart(Offset point, Rect board) {
    if (_busy) return;
    final cell = _cell(point, board);
    _lastPointer = point;
    if (cell != null) _select(cell, restart: true);
  }

  void _dragTo(Offset point, Rect board) {
    if (_busy) return;
    final previous = _lastPointer ?? point;
    final gap = (point - previous).distance;
    final spacing =
        math.min(board.width / _field.columns, board.height / _field.rows) *
        .22;
    final samples = math.max(1, (gap / math.max(spacing, 1)).ceil());
    for (var step = 1; step <= samples; step++) {
      final sample = Offset.lerp(previous, point, step / samples)!;
      final cell = _cell(sample, board);
      if (cell != null) _select(cell);
    }
    _lastPointer = point;
  }

  void _collect() {
    _lastPointer = null;
    if (_busy || _selection.isEmpty) return;
    if (_selection.length < _field.minChain) {
      setState(() {
        _feedback = 'Nearly! Join at least 3 matching bundles.';
        _selection.clear();
      });
      return;
    }
    final type = _field.board[_selection.first];
    final previousCount = _field.collected[type]!;
    final move = _field.harvest(List.of(_selection));
    if (move == null) return;
    _celebrateLanding =
        previousCount < _field.goals[type]! &&
        _field.collected[type]! >= _field.goals[type]!;
    _feedbackAudio?.play(AppSoundCue.select);
    HapticFeedback.lightImpact();
    setState(() {
      _move = move;
      _selection.clear();
      _hint = [];
      _feedback = move.cells.length >= 6
          ? 'Wonderful harvest! ${move.cells.length} for Naomi.'
          : 'A little kindness, gathered together.';
    });
    if (_reduceMotion) {
      if (_celebrateLanding) _feedbackAudio?.play(AppSoundCue.success);
      _celebrateLanding = false;
      setState(() => _move = null);
      _finishIfNeeded();
    } else {
      _gather.forward(from: 0);
    }
  }

  void _showHint() {
    if (_busy) return;
    setState(() {
      _selection.clear();
      _hint = _field.findMatch() ?? [];
      _feedback = 'Follow the three glowing bundles. You can add more!';
    });
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      key: const Key('ruth-harvest-engine'),
      color: const Color(0xFFF2D8A0),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const Positioned.fill(child: CustomPaint(painter: _FieldBackdrop())),
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x35FFF6D8),
                    Color(0xD9F8EBCB),
                    Color(0xFFF3D9A3),
                  ],
                  stops: [0, .38, 1],
                ),
              ),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxHeight < 650;
                return Padding(
                  padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 18),
                  child: Column(
                    children: [
                      _header(compact),
                      SizedBox(
                        height: compact ? 65 : 130,
                        width: double.infinity,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Semantics(
                            image: true,
                            label: 'Ruth and Naomi gathering grain together.',
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(19),
                              child: ExcludeSemantics(
                                child: Image.asset(
                                  '${_assetRoot}ruth_field.png',
                                  fit: BoxFit.cover,
                                  alignment: const Alignment(0, -.86),
                                  errorBuilder: (_, _, _) => const CustomPaint(
                                    painter: _FieldBackdrop(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      AnimatedBuilder(
                        animation: _gather,
                        builder: (context, _) => _baskets(compact),
                      ),
                      SizedBox(height: compact ? 8 : 14),
                      Expanded(child: _fieldBoard()),
                      _footer(compact),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(bool compact) => SizedBox(
    height: compact ? 44 : 52,
    child: Row(
      children: [
        if (widget.onExit != null) ...[
          IconButton.filledTonal(
            key: const Key('ruth-exit'),
            onPressed: _isPaused ? null : widget.onExit,
            tooltip: 'Pause and leave the harvest',
            style: IconButton.styleFrom(
              backgroundColor: _paper.withValues(alpha: .9),
              foregroundColor: _ink,
              minimumSize: const Size(42, 42),
            ),
            icon: const Icon(Icons.arrow_back_rounded, size: 23),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            'Ruth’s Harvest',
            style: TextStyle(
              color: _ink,
              fontWeight: FontWeight.w800,
              fontSize: compact ? 18 : 20,
            ),
          ),
        ),
        Semantics(
          label: '${_field.remainingChains} gathers remaining',
          child: Container(
            key: const Key('ruth-moves'),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: BoxDecoration(
              color: _paper.withValues(alpha: .92),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(
              '${_field.remainingChains} gathers',
              style: const TextStyle(
                color: _ink,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _baskets(bool compact) => Container(
    padding: EdgeInsets.fromLTRB(6, compact ? 5 : 9, 6, compact ? 5 : 10),
    decoration: BoxDecoration(
      color: _paper.withValues(alpha: .95),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: const Color(0xFFFEF2D2), width: 2),
      boxShadow: const [
        BoxShadow(
          color: Color(0x16886731),
          blurRadius: 16,
          offset: Offset(0, 5),
        ),
      ],
    ),
    child: Row(
      children: [
        for (final type in _field.grainTypes)
          Expanded(
            child: Semantics(
              key: Key('ruth-basket-$type'),
              label:
                  '${_label(type)} basket, ${_field.collected[type]} of ${_field.goals[type]} gathered',
              child: ExcludeSemantics(
                child: _BasketGoal(
                  grain: type,
                  count: _field.collected[type]!,
                  goal: _field.goals[type]!,
                  compact: compact,
                  celebrating: _move?.grain == type
                      ? math.sin(_gather.value * math.pi)
                      : 0,
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _fieldBoard() => Container(
    decoration: BoxDecoration(
      color: const Color(0xFFFDF1D3),
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: const Color(0xFFFFFCF1), width: 3),
      boxShadow: const [
        BoxShadow(
          color: Color(0x24835A24),
          blurRadius: 18,
          offset: Offset(0, 7),
        ),
      ],
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final board = _boardRect(size);
        return GestureDetector(
          key: _boardKey,
          behavior: HitTestBehavior.opaque,
          onPanDown: (details) {
            if (!_busy) _pointerStart = details.localPosition;
          },
          onPanStart: (details) {
            _dragging = true;
            _dragStart(_pointerStart ?? details.localPosition, board);
            _dragTo(details.localPosition, board);
            _pointerStart = null;
          },
          onPanUpdate: (details) => _dragTo(details.localPosition, board),
          onPanEnd: (_) {
            _dragging = false;
            _collect();
          },
          onPanCancel: () {
            if (_dragging && !_busy) setState(_selection.clear);
            _dragging = false;
            _lastPointer = null;
            _pointerStart = null;
          },
          onTapUp: (details) {
            _pointerStart = null;
            final cell = _cell(details.localPosition, board);
            if (cell != null) _tapCell(cell);
          },
          child: AnimatedBuilder(
            animation: _gather,
            builder: (context, _) => Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(25),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _FieldRowsPainter(
                              rows: _field.rows,
                              board: board,
                            ),
                          ),
                        ),
                        if (_move == null)
                          for (var cell = 0; cell < _field.board.length; cell++)
                            _bundle(
                              cell,
                              _field.board[cell],
                              _center(cell, board),
                              board,
                              selected: _selection.contains(cell),
                              hinted: _hint.contains(cell),
                            )
                        else
                          ..._movingBundles(board),
                        if (_selection.isNotEmpty || _hint.isNotEmpty)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: _ChainPainter(
                                  points:
                                      (_selection.isEmpty ? _hint : _selection)
                                          .map((cell) => _center(cell, board))
                                          .toList(),
                                  hint: _selection.isEmpty,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (_move != null) ..._flyingBundles(board),
              ],
            ),
          ),
        );
      },
    ),
  );

  Widget _bundle(
    int cell,
    String grain,
    Offset center,
    Rect board, {
    bool selected = false,
    bool hinted = false,
    double opacity = 1,
    double scale = 1,
    bool interactive = true,
  }) {
    final width = board.width / _field.columns;
    final height = board.height / _field.rows;
    final token = SizedBox(
      width: width,
      height: height,
      child: Center(
        child: Transform.scale(
          scale: scale * (selected ? 1.09 : 1),
          child: Container(
            width: math.min(width * .94, height * 1.28),
            height: height * .92,
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0xFFFFE6A1)
                  : hinted
                  ? const Color(0xFFE5EBCB)
                  : const Color(0x75FFFCF1),
              borderRadius: BorderRadius.circular(17),
              border: Border.all(
                color: selected
                    ? _olive
                    : hinted
                    ? _olive.withValues(alpha: .55)
                    : Colors.transparent,
                width: selected || hinted ? 2.5 : 1,
              ),
              boxShadow: selected
                  ? const [
                      BoxShadow(
                        color: Color(0x276A793F),
                        blurRadius: 9,
                        offset: Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Transform.rotate(
                angle: ((cell * 13) % 7 - 3) * .025,
                child: _GrainArt(grain: grain),
              ),
            ),
          ),
        ),
      ),
    );
    return Positioned(
      key: Key('ruth-cell-$cell'),
      left: center.dx - width / 2,
      top: center.dy - height / 2,
      width: width,
      height: height,
      child: Opacity(
        opacity: opacity.clamp(0, 1),
        child: interactive
            ? Semantics(
                button: true,
                enabled: !_busy,
                selected: selected,
                label:
                    '${_label(grain)}, row ${cell ~/ _field.columns + 1}, column ${cell % _field.columns + 1}',
                hint: 'Tap matching neighbours, then choose Harvest.',
                onTap: _busy ? null : () => _tapCell(cell),
                child: ExcludeSemantics(child: token),
              )
            : IgnorePointer(child: ExcludeSemantics(child: token)),
      ),
    );
  }

  List<Widget> _movingBundles(Rect board) {
    final move = _move!;
    final value = _gather.value;
    if (value < .24) {
      return [
        for (var cell = 0; cell < move.before.length; cell++)
          if (!move.cells.contains(cell))
            _bundle(
              cell,
              move.before[cell],
              _center(cell, board),
              board,
              interactive: false,
            ),
      ];
    }
    final progress = Curves.easeOutCubic.transform(
      ((value - .24) / .58).clamp(0, 1),
    );
    return [
      for (final drop in move.drops)
        _bundle(
          drop.to,
          drop.grain,
          Offset.lerp(
            drop.from == null
                ? Offset(
                    _center(drop.to, board).dx,
                    board.top -
                        (drop.to ~/ _field.columns + 1) *
                            board.height /
                            _field.rows,
                  )
                : _center(drop.from!, board),
            _center(drop.to, board),
            progress,
          )!,
          board,
          opacity: drop.from == null ? progress : 1,
          interactive: false,
        ),
    ];
  }

  List<Widget> _flyingBundles(Rect board) {
    final move = _move!;
    final typeIndex = _field.grainTypes.indexOf(move.grain);
    final destination = Offset(
      board.left + (typeIndex + .5) * board.width / 3,
      board.top - 34,
    );
    return [
      for (var index = 0; index < move.cells.length; index++)
        _flyingBundle(move, index, destination, board),
    ];
  }

  Widget _flyingBundle(
    RuthHarvestMove move,
    int index,
    Offset destination,
    Rect board,
  ) {
    final progress = ((_gather.value - index * .012) / .68).clamp(0.0, 1.0);
    if (progress >= 1) return const SizedBox.shrink();
    final start = _center(move.cells[index], board);
    final bend = Offset(
      (start.dx + destination.dx) / 2 + 24,
      math.min(start.dy, destination.dy) - 45,
    );
    final a = Offset.lerp(start, bend, progress)!;
    final b = Offset.lerp(bend, destination, progress)!;
    final point = Offset.lerp(a, b, progress)!;
    final extent =
        math.min(board.width / _field.columns, board.height / _field.rows) * .9;
    return Positioned(
      key: Key('ruth-flying-$index'),
      left: point.dx - extent / 2,
      top: point.dy - extent / 2,
      width: extent,
      height: extent,
      child: IgnorePointer(
        child: Opacity(
          opacity: (1 - math.max(0, progress - .7) / .3).clamp(0, 1),
          child: Transform.rotate(
            angle: progress * .5,
            child: Transform.scale(
              scale: 1 + math.sin(progress * math.pi) * .15 - progress * .5,
              child: _GrainArt(grain: move.grain),
            ),
          ),
        ),
      ),
    );
  }

  Widget _footer(bool compact) {
    final selected = _selection.length;
    final label = selected >= 3
        ? '${_label(_field.board[_selection.first])} · $selected bundles'
        : _feedback ?? 'Join 3 or more of the same grain.';
    return SizedBox(
      height: compact ? 80 : 105,
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      label,
                      maxLines: 2,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  key: const Key('ruth-hint'),
                  onPressed: _busy ? null : _showHint,
                  tooltip: 'Show a match',
                  icon: const Icon(
                    Icons.lightbulb_outline_rounded,
                    color: _ink,
                    size: 23,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: double.infinity,
            height: compact ? 43 : 48,
            child: FilledButton(
              key: const Key('ruth-harvest-button'),
              onPressed: !_busy && selected >= 3 ? _collect : null,
              style: FilledButton.styleFrom(
                backgroundColor: _ink,
                foregroundColor: _paper,
                disabledBackgroundColor: const Color(0xFFC7C49B),
                disabledForegroundColor: const Color(0xFF626C49),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(17),
                ),
                textStyle: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  fontFamily: Theme.of(
                    context,
                  ).textTheme.labelLarge?.fontFamily,
                ),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      selected >= 3
                          ? Icons.grass_rounded
                          : Icons.gesture_rounded,
                      size: 21,
                    ),
                    const SizedBox(width: 9),
                    Text(
                      selected >= 3
                          ? 'Harvest $selected bundles'
                          : 'Draw a trail to gather',
                    ),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(height: compact ? 7 : 11),
        ],
      ),
    );
  }
}

String _label(String grain) => switch (grain) {
  'wheat' => 'Wheat',
  'barley' => 'Barley',
  'oats' => 'Oats',
  _ => grain,
};

class _GrainArt extends StatelessWidget {
  const _GrainArt({required this.grain});
  final String grain;

  @override
  Widget build(BuildContext context) => Image.asset(
    '${_assetRoot}grain_$grain.png',
    fit: BoxFit.contain,
    filterQuality: FilterQuality.medium,
    errorBuilder: (_, _, _) => CustomPaint(painter: _GrainFallback(grain)),
  );
}

class _BasketGoal extends StatelessWidget {
  const _BasketGoal({
    required this.grain,
    required this.count,
    required this.goal,
    required this.compact,
    required this.celebrating,
  });
  final String grain;
  final int count;
  final int goal;
  final bool compact;
  final double celebrating;

  @override
  Widget build(BuildContext context) {
    final complete = count >= goal;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Transform.scale(
          scale: 1 + celebrating * .07,
          child: SizedBox(
            height: compact ? 27 : 42,
            width: compact ? 48 : 61,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _BasketPainter(fill: (count / goal).clamp(0, 1)),
                  ),
                ),
                Positioned(
                  left: 9,
                  right: 9,
                  top: -2,
                  bottom: 6,
                  child: _GrainArt(grain: grain),
                ),
                if (complete)
                  const Positioned(
                    right: 0,
                    top: 0,
                    child: CircleAvatar(
                      backgroundColor: _olive,
                      radius: 8,
                      child: Icon(
                        Icons.check_rounded,
                        color: Colors.white,
                        size: 13,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '${_label(grain)}  ${math.min(count, goal)}/$goal',
            maxLines: 1,
            style: TextStyle(
              color: complete ? _olive : _ink,
              fontSize: compact ? 11 : 12,
              height: 1.1,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}

class _ChainPainter extends CustomPainter {
  const _ChainPainter({required this.points, required this.hint});
  final List<Offset> points;
  final bool hint;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      path,
      paint
        ..color = _paper.withValues(alpha: .9)
        ..strokeWidth = 9,
    );
    canvas.drawPath(
      path,
      paint
        ..color = _olive.withValues(alpha: hint ? .55 : .95)
        ..strokeWidth = 4,
    );
    for (final point in points) {
      canvas.drawCircle(point, 5, Paint()..color = _paper);
      canvas.drawCircle(point, 2.5, Paint()..color = _olive);
    }
  }

  @override
  bool shouldRepaint(covariant _ChainPainter oldDelegate) => true;
}

class _FieldRowsPainter extends CustomPainter {
  const _FieldRowsPainter({required this.rows, required this.board});
  final int rows;
  final Rect board;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x28B99851)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (var row = 0; row < rows; row++) {
      final y = board.top + (row + .96) * board.height / rows;
      final path = Path()
        ..moveTo(board.left - 10, y)
        ..quadraticBezierTo(board.center.dx, y + 5, board.right + 10, y - 2);
      canvas.drawPath(path, paint);
    }
    final fleck = Paint()..color = const Color(0x35C9A758);
    for (var index = 0; index < 45; index++) {
      final x = board.left + ((index * 37) % 101) / 101 * board.width;
      final y = board.top + ((index * 23) % 83) / 83 * board.height;
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x, y), width: 2, height: .7),
        fleck,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FieldRowsPainter oldDelegate) =>
      oldDelegate.board != board;
}

class _BasketPainter extends CustomPainter {
  const _BasketPainter({required this.fill});
  final double fill;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Rect.fromLTWH(
      2,
      size.height * .39,
      size.width - 4,
      size.height * .57,
    );
    final basket = Path()
      ..moveTo(bounds.left, bounds.top)
      ..lineTo(bounds.right, bounds.top)
      ..lineTo(bounds.right - 6, bounds.bottom - 3)
      ..quadraticBezierTo(
        bounds.center.dx,
        bounds.bottom + 3,
        bounds.left + 6,
        bounds.bottom - 3,
      )
      ..close();
    canvas.drawShadow(basket, const Color(0x557F6029), 2, true);
    canvas.drawPath(basket, Paint()..color = const Color(0xFFCAA367));
    canvas.save();
    canvas.clipPath(basket);
    canvas.drawRect(
      Rect.fromLTRB(
        bounds.left,
        bounds.bottom - bounds.height * fill,
        bounds.right,
        bounds.bottom,
      ),
      Paint()..color = _gold.withValues(alpha: .62),
    );
    final weave = Paint()
      ..color = const Color(0xFFAE834A)
      ..strokeWidth = 1;
    for (var row = 0; row < 5; row++) {
      final y = bounds.top + row * bounds.height / 4;
      canvas.drawLine(Offset(bounds.left, y), Offset(bounds.right, y), weave);
    }
    for (var column = 0; column < 8; column++) {
      final x = bounds.left + column * bounds.width / 7;
      canvas.drawLine(
        Offset(x, bounds.top),
        Offset(x + (column.isEven ? 2 : -2), bounds.bottom),
        weave,
      );
    }
    canvas.restore();
    canvas.drawLine(
      Offset(bounds.left, bounds.top),
      Offset(bounds.right, bounds.top),
      Paint()
        ..color = const Color(0xFF8F713F)
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _BasketPainter oldDelegate) =>
      oldDelegate.fill != fill;
}

/// An intentional, silhouette-distinct fallback for a missing or slow asset.
/// The shipped game uses the illustrated transparent grain cut-outs.
class _GrainFallback extends CustomPainter {
  const _GrainFallback(this.grain);
  final String grain;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 60, size.height / 72);
    final stem = Paint()
      ..color = const Color(0xFF8A793A)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final kernel = Paint()
      ..color = grain == 'barley'
          ? const Color(0xFFB79D58)
          : grain == 'oats'
          ? const Color(0xFFD9AC62)
          : const Color(0xFFE9B74D);
    for (var stalk = 0; stalk < 3; stalk++) {
      final x = 30.0 + (stalk - 1) * 10;
      final top = 7.0 + (stalk == 1 ? 0 : 8);
      canvas.drawLine(Offset(30, 65), Offset(x, top + 15), stem);
      if (grain == 'oats') {
        for (var branch = 0; branch < 3; branch++) {
          final y = top + branch * 9;
          final dx = branch.isEven ? -9.0 : 9.0;
          canvas.drawLine(Offset(x, y + 6), Offset(x + dx, y - 1), stem);
          canvas.drawOval(
            Rect.fromCenter(
              center: Offset(x + dx, y + 3),
              width: 7,
              height: 11,
            ),
            kernel,
          );
        }
      } else {
        for (var pair = 0; pair < 5; pair++) {
          final y = top + pair * 5;
          for (final side in [-1, 1]) {
            canvas.save();
            canvas.translate(x + side * 3.8, y);
            canvas.rotate(side * .55);
            canvas.drawOval(const Rect.fromLTWH(-3, -4.5, 6, 9), kernel);
            canvas.restore();
            if (grain == 'barley') {
              canvas.drawLine(
                Offset(x + side * 5, y),
                Offset(x + side * 10, y - 14),
                stem..strokeWidth = .8,
              );
            }
          }
        }
      }
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(22, 50, 16, 5),
        const Radius.circular(2),
      ),
      Paint()..color = const Color(0xFFB9774D),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GrainFallback oldDelegate) =>
      oldDelegate.grain != grain;
}

class _FieldBackdrop extends CustomPainter {
  const _FieldBackdrop();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF7E5B4), Color(0xFFE3C47E)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawCircle(
      Offset(size.width * .81, size.height * .1),
      size.width * .2,
      Paint()..color = const Color(0x77FFF8D8),
    );
    final hills = Path()
      ..moveTo(0, size.height * .25)
      ..quadraticBezierTo(
        size.width * .4,
        size.height * .13,
        size.width,
        size.height * .26,
      )
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(hills, Paint()..color = const Color(0xFFBFBA74));
    final hills2 = Path()
      ..moveTo(0, size.height * .32)
      ..quadraticBezierTo(
        size.width * .7,
        size.height * .2,
        size.width,
        size.height * .37,
      )
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(hills2, Paint()..color = const Color(0xFFE1BC72));
  }

  @override
  bool shouldRepaint(covariant _FieldBackdrop oldDelegate) => false;
}

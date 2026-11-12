import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/mini_game.dart';

const _puzzleViolet = Color(0xFF7653E8);
const _puzzleInk = Color(0xFF201A30);
const _puzzleCream = Color(0xFFFFFBED);
const _puzzleGold = Color(0xFFFFCF2F);
const _puzzleMint = Color(0xFF76E1BE);

/// A tactile picture-building engine for Puzzle Quest.
///
/// The shared artwork is cropped at runtime, so every tile stays as sharp as
/// the reference image and the reconstructed picture always lines up exactly.
class PuzzleQuestEngine extends StatefulWidget {
  const PuzzleQuestEngine({
    required this.level,
    required this.onComplete,
    super.key,
  });

  final GameLevel level;
  final void Function(Map<String, dynamic> result) onComplete;

  @override
  State<PuzzleQuestEngine> createState() => _PuzzleQuestEngineState();
}

enum _PuzzleStage { preview, playing, finished }

enum _ArtworkAvailability { loading, ready, unavailable }

class _PuzzleQuestEngineState extends State<PuzzleQuestEngine> {
  late final _PuzzleConfig? _config;
  late final List<_PuzzlePiece> _trayOrder;
  final Map<String, _PuzzlePiece> _placements = {};
  final List<String> _placementHistory = [];
  final Stopwatch _stopwatch = Stopwatch();

  _PuzzleStage _stage = _PuzzleStage.preview;
  String? _selectedPieceId;
  String _status = 'Study the picture, then tell us when you are ready.';
  int _moves = 0;
  bool _artPrecacheStarted = false;
  _ArtworkAvailability _artworkAvailability = _ArtworkAvailability.loading;
  bool _completionSent = false;
  Timer? _completionTimer;

  @override
  void initState() {
    super.initState();
    _config = _PuzzleConfig.tryParse(widget.level.config);
    _trayOrder = _shuffledPieces(_config?.pieces ?? const []);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final config = _config;
    if (!_artPrecacheStarted && config != null && config.assetKey.isNotEmpty) {
      _artPrecacheStarted = true;
      unawaited(_precacheArtwork(config));
    }
  }

  Future<void> _precacheArtwork(_PuzzleConfig config) async {
    var failed = false;
    await precacheImage(
      AssetImage(config.assetKey),
      context,
      onError: (_, _) => failed = true,
    );
    if (!mounted) return;
    setState(() {
      _artworkAvailability = failed
          ? _ArtworkAvailability.unavailable
          : _ArtworkAvailability.ready;
    });
  }

  @override
  void dispose() {
    _completionTimer?.cancel();
    _stopwatch.stop();
    super.dispose();
  }

  List<_PuzzlePiece> _shuffledPieces(List<_PuzzlePiece> source) {
    final pieces = List<_PuzzlePiece>.of(source);
    pieces.shuffle(math.Random(_stableSeed(widget.level.id)));
    if (pieces.length > 1 &&
        pieces.indexed.every(
          (entry) =>
              entry.$2.sourceRow * (_config?.columns ?? 1) +
                  entry.$2.sourceColumn ==
              entry.$1,
        )) {
      pieces.add(pieces.removeAt(0));
    }
    return pieces;
  }

  void _startPuzzle() {
    if (_stage != _PuzzleStage.preview ||
        _artworkAvailability != _ArtworkAvailability.ready) {
      return;
    }
    unawaited(HapticFeedback.mediumImpact());
    _stopwatch
      ..reset()
      ..start();
    setState(() {
      _stage = _PuzzleStage.playing;
      _status = 'Drag a piece down, or tap a piece and then its board space.';
    });
  }

  void _selectPiece(String pieceId) {
    if (_stage != _PuzzleStage.playing || _isPlaced(pieceId)) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() {
      _selectedPieceId = _selectedPieceId == pieceId ? null : pieceId;
      final piece = _piece(pieceId);
      _status = _selectedPieceId == null
          ? 'Piece selection cleared.'
          : '${piece?.label ?? 'Puzzle piece'} selected. Choose a board space.';
    });
  }

  void _tapSlot(_PuzzleSlot slot) {
    final pieceId = _selectedPieceId;
    if (pieceId == null) {
      setState(() => _status = 'Choose a picture piece first.');
      return;
    }
    _tryPlace(pieceId, slot);
  }

  void _tryPlace(String pieceId, _PuzzleSlot slot) {
    if (_stage != _PuzzleStage.playing ||
        _placements.containsKey(slot.id) ||
        _isPlaced(pieceId)) {
      return;
    }
    final piece = _piece(pieceId);
    if (piece == null) return;

    _moves += 1;
    final correct =
        piece.sourceRow == slot.row && piece.sourceColumn == slot.column;
    if (!correct) {
      unawaited(HapticFeedback.lightImpact());
      setState(() {
        _selectedPieceId = pieceId;
        _status = 'Almost! That piece has another home.';
      });
      return;
    }

    unawaited(HapticFeedback.mediumImpact());
    setState(() {
      _placements[slot.id] = piece;
      _placementHistory.add(slot.id);
      _selectedPieceId = null;
      _status =
          'Piece placed! ${_placements.length} of ${_config!.pieces.length} complete.';
    });

    if (_placements.length == _config!.pieces.length) {
      _finish();
    }
  }

  void _finish() {
    if (_completionSent || _stage == _PuzzleStage.finished) return;
    _stopwatch.stop();
    setState(() {
      _stage = _PuzzleStage.finished;
      _status = 'Picture complete! Saving your puzzle.';
    });
    unawaited(HapticFeedback.heavyImpact());
    _completionTimer = Timer(const Duration(milliseconds: 650), () {
      if (!mounted || _completionSent) return;
      _completionSent = true;
      widget.onComplete({
        'placements': [
          for (final slot in _config!.slots)
            {'piece_id': _placements[slot.id]!.id, 'slot_id': slot.id},
        ],
        'moves': _moves,
        'elapsed_seconds': _stopwatch.elapsed.inSeconds,
      });
    });
  }

  void _undo() {
    if (_stage != _PuzzleStage.playing || _placementHistory.isEmpty) return;
    final slotId = _placementHistory.removeLast();
    final piece = _placements.remove(slotId);
    if (piece == null) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() {
      _selectedPieceId = piece.id;
      _status = '${piece.label} returned to the piece dock.';
    });
  }

  void _reset() {
    if (_stage != _PuzzleStage.playing || _placements.isEmpty && _moves == 0) {
      return;
    }
    unawaited(HapticFeedback.mediumImpact());
    setState(() {
      _placements.clear();
      _placementHistory.clear();
      _selectedPieceId = null;
      _moves = 0;
      _status = 'Board reset. Build the picture again!';
      _stopwatch
        ..reset()
        ..start();
    });
  }

  bool _isPlaced(String pieceId) {
    return _placements.values.any((piece) => piece.id == pieceId);
  }

  _PuzzlePiece? _piece(String id) {
    for (final piece in _config?.pieces ?? const <_PuzzlePiece>[]) {
      if (piece.id == id) return piece;
    }
    return null;
  }

  Future<void> _showReference() async {
    final config = _config;
    if (config == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.visibility_rounded, color: _puzzleViolet),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      config.artworkTitle,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close picture',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _ArtworkFrame(config: config, maxSize: 420),
              const SizedBox(height: 14),
              const Text(
                'Take your time—peeking is part of the adventure!',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    if (config == null) {
      return _UnavailablePuzzle(onBack: () => _leavePuzzle(context));
    }
    switch (_artworkAvailability) {
      case _ArtworkAvailability.loading:
        return const _PuzzleArtworkLoading();
      case _ArtworkAvailability.unavailable:
        return _UnavailablePuzzle(onBack: () => _leavePuzzle(context));
      case _ArtworkAvailability.ready:
        break;
    }
    return AnimatedSwitcher(
      duration: _reduceMotion(context)
          ? Duration.zero
          : const Duration(milliseconds: 420),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: _stage == _PuzzleStage.preview
          ? _ReferenceStage(
              key: const Key('puzzle-reference-stage'),
              config: config,
              levelTitle: widget.level.title,
              instructions: widget.level.instructions,
              onReady: _startPuzzle,
            )
          : _buildBoard(config),
    );
  }

  void _leavePuzzle(BuildContext context) {
    unawaited(Navigator.of(context).maybePop());
  }

  Widget _buildBoard(_PuzzleConfig config) {
    final remaining = _trayOrder
        .where((piece) => !_isPlaced(piece.id))
        .toList(growable: false);
    return Column(
      key: const Key('puzzle-board-stage'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PuzzleHud(
          placed: _placements.length,
          total: config.pieces.length,
          moves: _moves,
          onPeek: _showReference,
        ),
        if (_stage == _PuzzleStage.playing) ...[
          const SizedBox(height: 14),
          _PieceDockHeader(
            canUndo: _placementHistory.isNotEmpty,
            canReset: _placements.isNotEmpty || _moves > 0,
            onUndo: _undo,
            onReset: _reset,
          ),
          const SizedBox(height: 9),
          if (remaining.isNotEmpty)
            _PieceDock(
              config: config,
              pieces: remaining,
              selectedPieceId: _selectedPieceId,
              onSelect: _selectPiece,
            ),
          const SizedBox(height: 12),
        ] else
          const SizedBox(height: 14),
        Center(
          child: _PuzzleBoard(
            config: config,
            placements: _placements,
            selectedPieceId: _selectedPieceId,
            finished: _stage == _PuzzleStage.finished,
            onTapSlot: _tapSlot,
            onAcceptPiece: _tryPlace,
          ),
        ),
        const SizedBox(height: 14),
        Semantics(
          container: true,
          liveRegion: true,
          child: Container(
            key: const Key('puzzle-status'),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: _puzzleMint.withValues(alpha: 0.24),
              border: Border.all(color: _puzzleInk, width: 2),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Row(
              children: [
                Icon(
                  _stage == _PuzzleStage.finished
                      ? Icons.auto_awesome_rounded
                      : Icons.lightbulb_rounded,
                  size: 20,
                  color: _puzzleInk,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: _puzzleInk,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ReferenceStage extends StatelessWidget {
  const _ReferenceStage({
    required this.config,
    required this.levelTitle,
    required this.instructions,
    required this.onReady,
    super.key,
  });

  final _PuzzleConfig config;
  final String levelTitle;
  final String instructions;
  final VoidCallback onReady;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
            decoration: BoxDecoration(
              color: _puzzleViolet,
              border: Border.all(color: _puzzleInk, width: 2),
              borderRadius: BorderRadius.circular(999),
              boxShadow: const [
                BoxShadow(color: _puzzleInk, offset: Offset(3, 3)),
              ],
            ),
            child: Semantics(
              label: 'Puzzle Quest',
              child: const ExcludeSemantics(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.extension_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                      SizedBox(width: 7),
                      Text(
                        'PUZZLE QUEST',
                        maxLines: 1,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          levelTitle,
          key: const Key('puzzle-level-title'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            color: _puzzleInk,
            fontWeight: FontWeight.w900,
            height: 1.05,
          ),
        ),
        const SizedBox(height: 7),
        if (instructions.isNotEmpty)
          Text(
            instructions,
            key: const Key('puzzle-level-instructions'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
        const SizedBox(height: 12),
        Semantics(
          label: 'Look closely. Remember where everything goes.',
          child: const ExcludeSemantics(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.visibility_rounded, color: _puzzleViolet, size: 20),
                SizedBox(width: 7),
                Flexible(
                  child: Text(
                    'Look closely—remember where everything goes.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _puzzleViolet,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        _ArtworkFrame(config: config, maxSize: 340),
        const SizedBox(height: 20),
        FilledButton.icon(
          key: const Key('puzzle-ready-button'),
          onPressed: onReady,
          style: FilledButton.styleFrom(
            backgroundColor: _puzzleViolet,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(58),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
          icon: const Icon(Icons.rocket_launch_rounded),
          label: const Text(
            'I’m ready!',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
          ),
        ),
      ],
    );
  }
}

class _ArtworkFrame extends StatelessWidget {
  const _ArtworkFrame({required this.config, required this.maxSize});

  final _PuzzleConfig config;
  final double maxSize;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxSize),
        child: Padding(
          padding: const EdgeInsets.only(right: 7, bottom: 7),
          child: Stack(
            children: [
              Positioned.fill(
                left: 7,
                top: 7,
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: _puzzleInk,
                    borderRadius: BorderRadius.circular(22),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 7, bottom: 7),
                child: AspectRatio(
                  aspectRatio: config.aspectRatio,
                  child: Semantics(
                    image: true,
                    label: config.altText,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: _puzzleCream,
                          border: Border.all(color: _puzzleInk, width: 3),
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(17),
                          child: ExcludeSemantics(
                            child: Image.asset(
                              config.assetKey,
                              fit: BoxFit.cover,
                              filterQuality: FilterQuality.high,
                              frameBuilder:
                                  (context, child, frame, wasSyncLoaded) {
                                    if (wasSyncLoaded || frame != null) {
                                      return child;
                                    }
                                    return const ColoredBox(
                                      color: _puzzleCream,
                                      child: Center(
                                        child: Icon(
                                          Icons.image_rounded,
                                          color: _puzzleViolet,
                                          size: 38,
                                        ),
                                      ),
                                    );
                                  },
                              errorBuilder: (_, _, _) =>
                                  const _MissingArtwork(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PuzzleHud extends StatelessWidget {
  const _PuzzleHud({
    required this.placed,
    required this.total,
    required this.moves,
    required this.onPeek,
  });

  final int placed;
  final int total;
  final int moves;
  final VoidCallback onPeek;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        _HudPill(
          icon: Icons.extension_rounded,
          label: '$placed / $total placed',
          color: _puzzleMint,
        ),
        _HudPill(
          icon: Icons.touch_app_rounded,
          label: '$moves ${moves == 1 ? 'move' : 'moves'}',
          color: _puzzleGold,
        ),
        Semantics(
          button: true,
          label: 'Peek at the complete picture',
          child: OutlinedButton.icon(
            key: const Key('puzzle-peek-button'),
            onPressed: onPeek,
            style: OutlinedButton.styleFrom(
              foregroundColor: _puzzleInk,
              backgroundColor: _puzzleCream,
              side: const BorderSide(color: _puzzleInk, width: 2),
              minimumSize: const Size(88, 48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            icon: const Icon(Icons.visibility_rounded, size: 20),
            label: const Text(
              'Peek',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ),
      ],
    );
  }
}

class _HudPill extends StatelessWidget {
  const _HudPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: _puzzleInk, width: 2),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 19, color: _puzzleInk),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _puzzleInk,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PuzzleBoard extends StatelessWidget {
  const _PuzzleBoard({
    required this.config,
    required this.placements,
    required this.selectedPieceId,
    required this.finished,
    required this.onTapSlot,
    required this.onAcceptPiece,
  });

  final _PuzzleConfig config;
  final Map<String, _PuzzlePiece> placements;
  final String? selectedPieceId;
  final bool finished;
  final ValueChanged<_PuzzleSlot> onTapSlot;
  final void Function(String pieceId, _PuzzleSlot slot) onAcceptPiece;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 340.0;
        final boardSize = math.min(available, 344.0);
        return Semantics(
          container: true,
          label:
              'Puzzle board. ${placements.length} of ${config.pieces.length} pieces placed.',
          child: SizedBox.square(
            key: const Key('puzzle-board'),
            dimension: boardSize,
            child: Padding(
              padding: const EdgeInsets.only(right: 6, bottom: 6),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    left: 6,
                    top: 6,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: _puzzleInk,
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    right: 6,
                    bottom: 6,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: _puzzleCream,
                          border: Border.all(color: _puzzleInk, width: 3),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: AnimatedSwitcher(
                          duration: _reduceMotion(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 420),
                          child: finished
                              ? SizedBox.expand(
                                  key: const Key('puzzle-finished-art'),
                                  child: Image.asset(
                                    config.assetKey,
                                    fit: BoxFit.fill,
                                    filterQuality: FilterQuality.high,
                                    errorBuilder: (_, _, _) =>
                                        const _MissingArtwork(),
                                  ),
                                )
                              : LayoutBuilder(
                                  builder: (context, boardConstraints) {
                                    final width = boardConstraints.maxWidth;
                                    final height = boardConstraints.maxHeight;
                                    final cellWidth = width / config.columns;
                                    final cellHeight = height / config.rows;
                                    return Stack(
                                      children: [
                                        const Positioned.fill(
                                          child: _BoardBackdrop(),
                                        ),
                                        for (final slot in config.slots)
                                          Positioned(
                                            left: slot.column * cellWidth,
                                            top: slot.row * cellHeight,
                                            width: cellWidth,
                                            height: cellHeight,
                                            child: _PuzzleSlotTarget(
                                              config: config,
                                              slot: slot,
                                              piece: placements[slot.id],
                                              selectedPieceId: selectedPieceId,
                                              onTap: () => onTapSlot(slot),
                                              onAccept: (pieceId) =>
                                                  onAcceptPiece(pieceId, slot),
                                            ),
                                          ),
                                      ],
                                    );
                                  },
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PuzzleSlotTarget extends StatelessWidget {
  const _PuzzleSlotTarget({
    required this.config,
    required this.slot,
    required this.piece,
    required this.selectedPieceId,
    required this.onTap,
    required this.onAccept,
  });

  final _PuzzleConfig config;
  final _PuzzleSlot slot;
  final _PuzzlePiece? piece;
  final String? selectedPieceId;
  final VoidCallback onTap;
  final ValueChanged<String> onAccept;

  @override
  Widget build(BuildContext context) {
    final position = slot.row * config.columns + slot.column + 1;
    final placedPiece = piece;
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => placedPiece == null,
      onAcceptWithDetails: (details) => onAccept(details.data),
      builder: (context, candidates, rejected) {
        final highlighted = candidates.isNotEmpty || selectedPieceId != null;
        return Semantics(
          button: placedPiece == null,
          label: placedPiece == null
              ? 'Empty puzzle space $position of ${config.slots.length}'
              : 'Puzzle space $position, ${placedPiece.label}, placed',
          hint: placedPiece == null
              ? 'Drop a piece here or select this space after choosing a piece'
              : null,
          child: InkWell(
            key: Key('puzzle-slot-${slot.id}'),
            onTap: placedPiece == null ? onTap : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              decoration: BoxDecoration(
                color: highlighted
                    ? _puzzleGold.withValues(alpha: 0.22)
                    : Colors.transparent,
                border: Border.all(
                  color: highlighted
                      ? _puzzleViolet
                      : _puzzleInk.withValues(alpha: 0.42),
                  width: highlighted ? 2.5 : 1.2,
                ),
              ),
              child: placedPiece == null
                  ? Center(
                      child: Icon(
                        Icons.extension_rounded,
                        color: _puzzleInk.withValues(alpha: 0.16),
                        size: 30,
                      ),
                    )
                  : _PuzzleCrop(
                      assetKey: config.assetKey,
                      rows: config.rows,
                      columns: config.columns,
                      sourceRow: placedPiece.sourceRow,
                      sourceColumn: placedPiece.sourceColumn,
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _PieceDockHeader extends StatelessWidget {
  const _PieceDockHeader({
    required this.canUndo,
    required this.canReset,
    required this.onUndo,
    required this.onReset,
  });

  final bool canUndo;
  final bool canReset;
  final VoidCallback onUndo;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final label = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Icon(
              Icons.keyboard_double_arrow_down_rounded,
              color: _puzzleViolet,
              size: 22,
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                'YOUR PIECES',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: _puzzleViolet,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          'Hold and drag down, or tap a piece.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SmallAction(
          tooltip: 'Undo last piece',
          icon: Icons.undo_rounded,
          onPressed: canUndo ? onUndo : null,
        ),
        const SizedBox(width: 6),
        _SmallAction(
          tooltip: 'Reset puzzle',
          icon: Icons.refresh_rounded,
          onPressed: canReset ? onReset : null,
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final largeText = MediaQuery.textScalerOf(context).scale(1) >= 1.6;
        if (largeText || constraints.maxWidth < 330) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              label,
              const SizedBox(height: 6),
              Align(alignment: Alignment.centerRight, child: actions),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: label),
            const SizedBox(width: 10),
            actions,
          ],
        );
      },
    );
  }
}

class _PieceDock extends StatelessWidget {
  const _PieceDock({
    required this.config,
    required this.pieces,
    required this.selectedPieceId,
    required this.onSelect,
  });

  final _PuzzleConfig config;
  final List<_PuzzlePiece> pieces;
  final String? selectedPieceId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = config.pieces.length <= 4
            ? 124.0
            : config.rows == 2
            ? 92.0
            : 96.0;
        final height = (width * config.columns / config.rows).clamp(
          72.0,
          142.0,
        );
        const spacing = 10.0;
        return Semantics(
          key: const Key('puzzle-piece-dock'),
          container: true,
          label:
              'Puzzle piece dock. Swipe left or right for more pieces. Hold and drag a piece down to the board, or tap it.',
          child: Container(
            height: height + 18,
            decoration: BoxDecoration(
              color: _puzzleViolet.withValues(alpha: 0.08),
              border: Border.all(
                color: _puzzleViolet.withValues(alpha: 0.28),
                width: 2,
              ),
              borderRadius: BorderRadius.circular(19),
            ),
            child: SingleChildScrollView(
              key: const Key('puzzle-piece-dock-scroll'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: math.max(0, constraints.maxWidth - 20),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var index = 0; index < pieces.length; index++) ...[
                      _DraggablePuzzlePiece(
                        config: config,
                        piece: pieces[index],
                        width: width,
                        height: height,
                        selected: selectedPieceId == pieces[index].id,
                        onSelect: () => onSelect(pieces[index].id),
                      ),
                      if (index < pieces.length - 1)
                        const SizedBox(width: spacing),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DraggablePuzzlePiece extends StatelessWidget {
  const _DraggablePuzzlePiece({
    required this.config,
    required this.piece,
    required this.width,
    required this.height,
    required this.selected,
    required this.onSelect,
  });

  final _PuzzleConfig config;
  final _PuzzlePiece piece;
  final double width;
  final double height;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final card = _PuzzlePieceCard(
      config: config,
      piece: piece,
      width: width,
      height: height,
      selected: selected,
    );
    return Semantics(
      button: true,
      selected: selected,
      label: '${piece.label}${selected ? ', selected' : ''}',
      hint: 'Tap to select, or hold and drag to the puzzle board',
      onTap: onSelect,
      child: LongPressDraggable<String>(
        key: Key('puzzle-piece-${piece.id}'),
        data: piece.id,
        maxSimultaneousDrags: 1,
        rootOverlay: true,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        hapticFeedbackOnStart: true,
        feedback: Material(
          color: Colors.transparent,
          child: Transform.scale(scale: 1.04, child: card),
        ),
        childWhenDragging: Opacity(opacity: 0.28, child: card),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onSelect,
          child: card,
        ),
      ),
    );
  }
}

class _PuzzlePieceCard extends StatelessWidget {
  const _PuzzlePieceCard({
    required this.config,
    required this.piece,
    required this.width,
    required this.height,
    required this.selected,
  });

  final _PuzzleConfig config;
  final _PuzzlePiece piece;
  final double width;
  final double height;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: AnimatedScale(
        scale: selected ? 1.045 : 1,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutBack,
        child: CustomPaint(
          painter: _JigsawShadowPainter(
            row: piece.sourceRow,
            column: piece.sourceColumn,
            rows: config.rows,
            columns: config.columns,
          ),
          foregroundPainter: _JigsawOutlinePainter(
            row: piece.sourceRow,
            column: piece.sourceColumn,
            rows: config.rows,
            columns: config.columns,
            selected: selected,
          ),
          child: ClipPath(
            clipper: _JigsawClipper(
              row: piece.sourceRow,
              column: piece.sourceColumn,
              rows: config.rows,
              columns: config.columns,
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _PuzzleCrop(
                  assetKey: config.assetKey,
                  rows: config.rows,
                  columns: config.columns,
                  sourceRow: piece.sourceRow,
                  sourceColumn: piece.sourceColumn,
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.55),
                      width: 2,
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
}

class _JigsawClipper extends CustomClipper<Path> {
  const _JigsawClipper({
    required this.row,
    required this.column,
    required this.rows,
    required this.columns,
  });

  final int row;
  final int column;
  final int rows;
  final int columns;

  @override
  Path getClip(Size size) =>
      _jigsawPath(size, row: row, column: column, rows: rows, columns: columns);

  @override
  bool shouldReclip(covariant _JigsawClipper oldClipper) {
    return oldClipper.row != row ||
        oldClipper.column != column ||
        oldClipper.rows != rows ||
        oldClipper.columns != columns;
  }
}

class _JigsawShadowPainter extends CustomPainter {
  const _JigsawShadowPainter({
    required this.row,
    required this.column,
    required this.rows,
    required this.columns,
  });

  final int row;
  final int column;
  final int rows;
  final int columns;

  @override
  void paint(Canvas canvas, Size size) {
    final path = _jigsawPath(
      size,
      row: row,
      column: column,
      rows: rows,
      columns: columns,
    );
    canvas.drawPath(
      path.shift(const Offset(4, 5)),
      Paint()..color = _puzzleInk.withValues(alpha: 0.88),
    );
  }

  @override
  bool shouldRepaint(covariant _JigsawShadowPainter oldDelegate) {
    return oldDelegate.row != row ||
        oldDelegate.column != column ||
        oldDelegate.rows != rows ||
        oldDelegate.columns != columns;
  }
}

class _JigsawOutlinePainter extends CustomPainter {
  const _JigsawOutlinePainter({
    required this.row,
    required this.column,
    required this.rows,
    required this.columns,
    required this.selected,
  });

  final int row;
  final int column;
  final int rows;
  final int columns;
  final bool selected;

  @override
  void paint(Canvas canvas, Size size) {
    final path = _jigsawPath(
      size,
      row: row,
      column: column,
      rows: rows,
      columns: columns,
    );
    if (selected) {
      canvas.drawPath(
        path,
        Paint()
          ..color = _puzzleGold
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..strokeJoin = StrokeJoin.round,
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = _puzzleInk
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _JigsawOutlinePainter oldDelegate) {
    return oldDelegate.row != row ||
        oldDelegate.column != column ||
        oldDelegate.rows != rows ||
        oldDelegate.columns != columns ||
        oldDelegate.selected != selected;
  }
}

Path _jigsawPath(
  Size size, {
  required int row,
  required int column,
  required int rows,
  required int columns,
}) {
  final shortest = math.min(size.width, size.height);
  final padding = (shortest * 0.085).clamp(6.0, 11.0);
  final left = padding;
  final top = padding;
  final right = size.width - padding - 4;
  final bottom = size.height - padding - 5;
  final radius = math.min((right - left) / 5.2, (bottom - top) / 5.2);
  final depth = padding * 1.45;
  final even = (row + column).isEven;
  final path = Path()..moveTo(left, top);

  if (row == 0) {
    path.lineTo(right, top);
  } else {
    _horizontalPuzzleEdge(
      path,
      from: left,
      to: right,
      y: top,
      radius: radius,
      bulge: even ? depth : -depth,
    );
  }
  _verticalPuzzleEdge(
    path,
    x: right,
    from: top,
    to: bottom,
    radius: radius,
    bulge: column == columns - 1 ? 0 : (even ? depth : -depth),
  );
  _horizontalPuzzleEdge(
    path,
    from: right,
    to: left,
    y: bottom,
    radius: radius,
    bulge: row == rows - 1 ? 0 : (even ? -depth : depth),
  );
  if (column == 0) {
    path.lineTo(left, top);
  } else {
    _verticalPuzzleEdge(
      path,
      x: left,
      from: bottom,
      to: top,
      radius: radius,
      bulge: even ? -depth : depth,
    );
  }
  return path..close();
}

void _horizontalPuzzleEdge(
  Path path, {
  required double from,
  required double to,
  required double y,
  required double radius,
  required double bulge,
}) {
  if (bulge == 0) {
    path.lineTo(to, y);
    return;
  }
  final direction = (to - from).sign;
  final middle = (from + to) / 2;
  path
    ..lineTo(middle - direction * radius, y)
    ..cubicTo(
      middle - direction * radius,
      y + bulge,
      middle + direction * radius,
      y + bulge,
      middle + direction * radius,
      y,
    )
    ..lineTo(to, y);
}

void _verticalPuzzleEdge(
  Path path, {
  required double x,
  required double from,
  required double to,
  required double radius,
  required double bulge,
}) {
  if (bulge == 0) {
    path.lineTo(x, to);
    return;
  }
  final direction = (to - from).sign;
  final middle = (from + to) / 2;
  path
    ..lineTo(x, middle - direction * radius)
    ..cubicTo(
      x + bulge,
      middle - direction * radius,
      x + bulge,
      middle + direction * radius,
      x,
      middle + direction * radius,
    )
    ..lineTo(x, to);
}

class _PuzzleCrop extends StatelessWidget {
  const _PuzzleCrop({
    required this.assetKey,
    required this.rows,
    required this.columns,
    required this.sourceRow,
    required this.sourceColumn,
  });

  final String assetKey;
  final int rows;
  final int columns;
  final int sourceRow;
  final int sourceColumn;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        return ClipRect(
          child: Stack(
            children: [
              Positioned(
                left: -sourceColumn * width,
                top: -sourceRow * height,
                width: width * columns,
                height: height * rows,
                child: Image.asset(
                  assetKey,
                  fit: BoxFit.fill,
                  filterQuality: FilterQuality.high,
                  errorBuilder: (_, _, _) => const _MissingArtwork(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BoardBackdrop extends StatelessWidget {
  const _BoardBackdrop();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _puzzleViolet.withValues(alpha: 0.08),
      child: CustomPaint(painter: const _BoardDotPainter()),
    );
  }
}

class _BoardDotPainter extends CustomPainter {
  const _BoardDotPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = _puzzleViolet.withValues(alpha: 0.12);
    const gap = 18.0;
    for (var x = gap / 2; x < size.width; x += gap) {
      for (var y = gap / 2; y < size.height; y += gap) {
        canvas.drawCircle(Offset(x, y), 1.8, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BoardDotPainter oldDelegate) => false;
}

class _SmallAction extends StatelessWidget {
  const _SmallAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.outlined(
      tooltip: tooltip,
      onPressed: onPressed,
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
      style: IconButton.styleFrom(
        foregroundColor: _puzzleInk,
        backgroundColor: _puzzleCream,
        side: const BorderSide(color: _puzzleInk, width: 2),
      ),
      icon: Icon(icon),
    );
  }
}

class _MissingArtwork extends StatelessWidget {
  const _MissingArtwork();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFFE9E2FF),
      child: Center(
        child: Icon(Icons.image_not_supported_rounded, color: _puzzleViolet),
      ),
    );
  }
}

class _PuzzleArtworkLoading extends StatelessWidget {
  const _PuzzleArtworkLoading();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const Key('puzzle-artwork-loading'),
      container: true,
      liveRegion: true,
      label: 'Getting your puzzle picture ready.',
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: _puzzleCream,
          border: Border.all(color: _puzzleInk, width: 2),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(
                color: _puzzleViolet,
                strokeWidth: 5,
                semanticsLabel: 'Getting picture ready',
              ),
            ),
            SizedBox(height: 16),
            Text(
              'Getting your picture ready…',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnavailablePuzzle extends StatelessWidget {
  const _UnavailablePuzzle({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const Key('puzzle-artwork-unavailable'),
      container: true,
      explicitChildNodes: true,
      liveRegion: true,
      label: 'This picture is being prepared. Please come back soon.',
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: _puzzleCream,
          border: Border.all(color: _puzzleInk, width: 2),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: _puzzleViolet.withValues(alpha: 0.16),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 78,
              height: 78,
              decoration: BoxDecoration(
                color: _puzzleViolet.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.auto_awesome_rounded,
                size: 40,
                color: _puzzleViolet,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'This picture is being prepared',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _puzzleInk,
                fontWeight: FontWeight.w900,
                fontSize: 20,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Our artists are adding the final sparkle. '
              'Please come back soon!',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('puzzle-unavailable-back'),
              onPressed: onBack,
              style: FilledButton.styleFrom(
                backgroundColor: _puzzleViolet,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(54),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(17),
                ),
              ),
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text(
                'Go back',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PuzzleConfig {
  const _PuzzleConfig({
    required this.assetKey,
    required this.artworkTitle,
    required this.altText,
    required this.aspectRatio,
    required this.rows,
    required this.columns,
    required this.pieces,
    required this.slots,
  });

  final String assetKey;
  final String artworkTitle;
  final String altText;
  final double aspectRatio;
  final int rows;
  final int columns;
  final List<_PuzzlePiece> pieces;
  final List<_PuzzleSlot> slots;

  static _PuzzleConfig? tryParse(Map<String, dynamic> raw) {
    final artwork = _map(raw['artwork']);
    final grid = _map(raw['grid']);
    final assetKey = _text(artwork['asset_key']);
    final artworkTitle = _text(artwork['title'], fallback: 'Picture puzzle');
    final altText = _text(
      artwork['alt_text'],
      fallback: 'The complete picture for this puzzle.',
    );
    final aspectRatio = _double(artwork['aspect_ratio'], fallback: 1);
    final rows = _int(grid['rows']);
    final columns = _int(grid['columns']);
    if (assetKey.isEmpty ||
        rows < 2 ||
        rows > 3 ||
        columns < 2 ||
        columns > 3 ||
        aspectRatio <= 0) {
      return null;
    }

    final pieces = <_PuzzlePiece>[];
    final rawPieces = raw['pieces'];
    if (rawPieces is List) {
      for (final value in rawPieces) {
        final piece = _map(value);
        final id = _text(piece['id']);
        final row = _int(piece['source_row'], fallback: -1);
        final column = _int(piece['source_column'], fallback: -1);
        if (id.isEmpty ||
            row < 0 ||
            row >= rows ||
            column < 0 ||
            column >= columns) {
          return null;
        }
        pieces.add(
          _PuzzlePiece(
            id: id,
            label: _text(piece['label'], fallback: 'Picture puzzle piece'),
            sourceRow: row,
            sourceColumn: column,
          ),
        );
      }
    }

    final slots = <_PuzzleSlot>[];
    final rawSlots = raw['slots'];
    if (rawSlots is List) {
      for (final value in rawSlots) {
        final slot = _map(value);
        final id = _text(slot['id']);
        final row = _int(slot['row'], fallback: -1);
        final column = _int(slot['column'], fallback: -1);
        if (id.isEmpty ||
            row < 0 ||
            row >= rows ||
            column < 0 ||
            column >= columns) {
          return null;
        }
        slots.add(_PuzzleSlot(id: id, row: row, column: column));
      }
    }

    final count = rows * columns;
    final pieceIds = pieces.map((piece) => piece.id).toSet();
    final piecePositions = pieces
        .map((piece) => '${piece.sourceRow}:${piece.sourceColumn}')
        .toSet();
    final slotIds = slots.map((slot) => slot.id).toSet();
    final slotPositions = slots
        .map((slot) => '${slot.row}:${slot.column}')
        .toSet();
    if (pieces.length != count ||
        slots.length != count ||
        pieceIds.length != count ||
        slotIds.length != count ||
        piecePositions.length != count ||
        slotPositions.length != count) {
      return null;
    }

    return _PuzzleConfig(
      assetKey: assetKey,
      artworkTitle: artworkTitle,
      altText: altText,
      aspectRatio: aspectRatio,
      rows: rows,
      columns: columns,
      pieces: List.unmodifiable(pieces),
      slots: List.unmodifiable(slots),
    );
  }
}

class _PuzzlePiece {
  const _PuzzlePiece({
    required this.id,
    required this.label,
    required this.sourceRow,
    required this.sourceColumn,
  });

  final String id;
  final String label;
  final int sourceRow;
  final int sourceColumn;
}

class _PuzzleSlot {
  const _PuzzleSlot({
    required this.id,
    required this.row,
    required this.column,
  });

  final String id;
  final int row;
  final int column;
}

int _stableSeed(String value) {
  var hash = 0x811C9DC5;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash;
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map(
      (key, nestedValue) => MapEntry(key.toString(), nestedValue),
    );
  }
  return const {};
}

String _text(Object? value, {String fallback = ''}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

int _int(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

double _double(Object? value, {double fallback = 0}) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}

bool _reduceMotion(BuildContext context) {
  final media = MediaQuery.maybeOf(context);
  return media?.disableAnimations == true ||
      media?.accessibleNavigation == true;
}

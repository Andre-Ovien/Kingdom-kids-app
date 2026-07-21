import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../domain/mini_game.dart';

typedef GameEngineComplete = void Function(Map<String, dynamic> result);

/// Selects the small, code-native play engine described by the backend level.
///
/// The server remains the authority for answers and rewards. Engines only
/// collect a child's interaction and send the documented result shape.
class GameLevelEngine extends StatelessWidget {
  const GameLevelEngine({
    required this.type,
    required this.level,
    required this.onComplete,
    super.key,
  });

  final GameType type;
  final GameLevel level;
  final GameEngineComplete onComplete;

  @override
  Widget build(BuildContext context) {
    return switch (type) {
      GameType.quiz => _QuizEngine(level: level, onComplete: onComplete),
      GameType.memory => _MemoryEngine(level: level, onComplete: onComplete),
      GameType.ordering => _OrderingEngine(
        level: level,
        onComplete: onComplete,
      ),
      GameType.matching => _MatchingEngine(
        level: level,
        onComplete: onComplete,
      ),
      GameType.maze => _GridJourneyEngine(
        level: level,
        onComplete: onComplete,
        isSeaPath: false,
      ),
      GameType.path => _GridJourneyEngine(
        level: level,
        onComplete: onComplete,
        isSeaPath: true,
      ),
      GameType.aim => _AimEngine(level: level, onComplete: onComplete),
    };
  }
}

class _QuizEngine extends StatefulWidget {
  const _QuizEngine({required this.level, required this.onComplete});

  final GameLevel level;
  final GameEngineComplete onComplete;

  @override
  State<_QuizEngine> createState() => _QuizEngineState();
}

class _QuizEngineState extends State<_QuizEngine> {
  late final List<Map<String, dynamic>> _questions;
  final Map<String, String> _answers = {};
  int _index = 0;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _questions = _maps(widget.level.config['questions']);
  }

  void _choose(String questionId, String optionId) {
    if (_finished) return;
    setState(() => _answers[questionId] = optionId);
  }

  void _continue() {
    if (_finished || _questions.isEmpty) return;
    final question = _questions[_index];
    final questionId = _string(question['id'], fallback: 'q$_index');
    if (!_answers.containsKey(questionId)) return;
    if (_index < _questions.length - 1) {
      setState(() => _index += 1);
      return;
    }
    _finished = true;
    widget.onComplete({
      'answers': [
        for (var index = 0; index < _questions.length; index++)
          {
            'question_id': _string(
              _questions[index]['id'],
              fallback: 'q$index',
            ),
            'option_id':
                _answers[_string(_questions[index]['id'], fallback: 'q$index')],
          },
      ],
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_questions.isEmpty) {
      return const _BrokenLevel(
        message: 'This question is still being prepared.',
      );
    }
    final question = _questions[_index];
    final questionId = _string(question['id'], fallback: 'q$_index');
    final options = _maps(question['options']);
    final selected = _answers[questionId];

    return Column(
      key: ValueKey('quiz-question-$questionId'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MiniProgress(current: _index + 1, total: _questions.length),
        const SizedBox(height: 18),
        Text(
          _string(question['prompt'], fallback: 'Choose your answer'),
          key: const Key('quiz-question'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w900,
            height: 1.12,
          ),
        ),
        const SizedBox(height: 22),
        for (final option in options) ...[
          _ChoiceTile(
            key: Key('quiz-option-${_string(option['id'])}'),
            label: _string(option['text'], fallback: 'Answer'),
            selected: selected == _string(option['id']),
            onTap: () => _choose(questionId, _string(option['id'])),
          ),
          const SizedBox(height: 11),
        ],
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('quiz-continue'),
          onPressed: selected == null ? null : _continue,
          icon: Icon(
            _index == _questions.length - 1
                ? Icons.auto_awesome_rounded
                : Icons.arrow_forward_rounded,
          ),
          label: Text(
            _index == _questions.length - 1 ? 'Check my answers' : 'Next',
          ),
        ),
      ],
    );
  }
}

class _OrderingEngine extends StatefulWidget {
  const _OrderingEngine({required this.level, required this.onComplete});

  final GameLevel level;
  final GameEngineComplete onComplete;

  @override
  State<_OrderingEngine> createState() => _OrderingEngineState();
}

class _OrderingEngineState extends State<_OrderingEngine> {
  late final List<Map<String, dynamic>> _items;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _items = List<Map<String, dynamic>>.of(_maps(widget.level.config['items']));
  }

  void _move(int from, int to) {
    if (_finished || to < 0 || to >= _items.length) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() {
      final item = _items.removeAt(from);
      _items.insert(to, item);
    });
  }

  void _reorder(int oldIndex, int newIndex) {
    if (_finished) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() {
      final item = _items.removeAt(oldIndex);
      _items.insert(newIndex, item);
    });
  }

  void _check() {
    if (_finished || _items.isEmpty) return;
    _finished = true;
    widget.onComplete({
      'sequence': _items.map((item) => _string(item['id'])).toList(),
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      return const _BrokenLevel(message: 'These steps are still being made.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Hold and drag, or use the arrows.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        ReorderableListView.builder(
          key: const Key('ordering-list'),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: _items.length,
          onReorderItem: _reorder,
          itemBuilder: (context, index) {
            final item = _items[index];
            return Padding(
              key: ValueKey(_string(item['id'], fallback: '$index')),
              padding: const EdgeInsets.only(bottom: 10),
              child: _OrderTile(
                number: index + 1,
                label: _string(item['label'], fallback: 'Story step'),
                assetKey: _string(item['asset_key']),
                canMoveUp: index > 0,
                canMoveDown: index < _items.length - 1,
                onUp: () => _move(index, index - 1),
                onDown: () => _move(index, index + 1),
                dragHandle: ReorderableDragStartListener(
                  index: index,
                  child: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Icon(Icons.drag_indicator_rounded),
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          key: const Key('ordering-check'),
          onPressed: _check,
          icon: const Icon(Icons.check_circle_rounded),
          label: const Text('Check the order'),
        ),
      ],
    );
  }
}

class _MatchingEngine extends StatefulWidget {
  const _MatchingEngine({required this.level, required this.onComplete});

  final GameLevel level;
  final GameEngineComplete onComplete;

  @override
  State<_MatchingEngine> createState() => _MatchingEngineState();
}

class _MatchingEngineState extends State<_MatchingEngine> {
  late final List<Map<String, dynamic>> _left;
  late final List<Map<String, dynamic>> _right;
  final Map<String, String> _pairs = {};
  String? _selectedLeft;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _left = _maps(widget.level.config['left_items']);
    _right = _maps(widget.level.config['right_items']);
  }

  void _selectLeft(String id) {
    if (_finished) return;
    setState(() => _selectedLeft = id);
  }

  void _selectRight(String rightId) {
    if (_finished || _selectedLeft == null) return;
    setState(() {
      _pairs.removeWhere((_, value) => value == rightId);
      _pairs[_selectedLeft!] = rightId;
      _selectedLeft = null;
    });
  }

  void _check() {
    if (_finished || _pairs.length != _left.length) return;
    _finished = true;
    widget.onComplete({
      'pairs': [
        for (final entry in _pairs.entries)
          {'left_id': entry.key, 'right_id': entry.value},
      ],
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_left.isEmpty || _right.isEmpty) {
      return const _BrokenLevel(message: 'These matches are still being made.');
    }
    final usedRight = _pairs.values.toSet();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _selectedLeft == null
              ? 'Choose a card on the left.'
              : 'Now choose its match on the right!',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                children: [
                  for (final item in _left) ...[
                    _MatchTile(
                      key: Key('match-left-${_string(item['id'])}'),
                      item: item,
                      selected: _selectedLeft == _string(item['id']),
                      connected: _pairs.containsKey(_string(item['id'])),
                      onTap: () => _selectLeft(_string(item['id'])),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 7, vertical: 20),
              child: Icon(Icons.compare_arrows_rounded),
            ),
            Expanded(
              child: Column(
                children: [
                  for (final item in _right) ...[
                    _MatchTile(
                      key: Key('match-right-${_string(item['id'])}'),
                      item: item,
                      selected: false,
                      connected: usedRight.contains(_string(item['id'])),
                      onTap: () => _selectRight(_string(item['id'])),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          child: Text(
            '${_pairs.length} of ${_left.length} paired',
            key: ValueKey(_pairs.length),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          key: const Key('matching-check'),
          onPressed: _pairs.length == _left.length ? _check : null,
          icon: const Icon(Icons.check_circle_rounded),
          label: const Text('Check my matches'),
        ),
      ],
    );
  }
}

class _MemoryEngine extends StatefulWidget {
  const _MemoryEngine({required this.level, required this.onComplete});

  final GameLevel level;
  final GameEngineComplete onComplete;

  @override
  State<_MemoryEngine> createState() => _MemoryEngineState();
}

class _MemoryEngineState extends State<_MemoryEngine> {
  late final List<Map<String, dynamic>> _cards;
  late final Stopwatch _clock;
  final Set<int> _matched = {};
  final List<List<String>> _matchedPairs = [];
  int? _first;
  int? _second;
  int _moves = 0;
  bool _previewing = true;
  bool _finished = false;
  String _status = 'Study the cards, then hide them when you are ready.';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _cards = _shuffleMemoryCards(
      _maps(widget.level.config['cards']),
      seed: widget.level.id,
    );
    _clock = Stopwatch();
  }

  void _hidePreview() {
    if (_finished || !_previewing) return;
    unawaited(HapticFeedback.mediumImpact());
    setState(() {
      _previewing = false;
      _status = 'Cards hidden. Choose your first card.';
    });
    _clock.start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _clock.stop();
    super.dispose();
  }

  void _flip(int index) {
    if (_finished ||
        _previewing ||
        _second != null ||
        _matched.contains(index) ||
        _first == index) {
      return;
    }
    if (_first == null) {
      unawaited(HapticFeedback.selectionClick());
      setState(() {
        _first = index;
        _status =
            '${_string(_cards[index]['label'], fallback: 'Card')} revealed. '
            'Now find its match.';
      });
      return;
    }

    final first = _first!;
    final isMatch =
        _string(_cards[first]['match_key']) ==
        _string(_cards[index]['match_key']);
    unawaited(
      isMatch ? HapticFeedback.mediumImpact() : HapticFeedback.lightImpact(),
    );
    setState(() {
      _second = index;
      _moves += 1;
      _status = isMatch
          ? 'It is a match!'
          : 'Not a match. The cards will turn back over.';
    });
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: isMatch ? 350 : 720), () {
      if (!mounted) return;
      setState(() {
        if (isMatch) {
          _matched.addAll([first, index]);
          _matchedPairs.add([
            _string(_cards[first]['id']),
            _string(_cards[index]['id']),
          ]);
        }
        _first = null;
        _second = null;
        _status = isMatch
            ? 'Match saved. ${_matched.length ~/ 2} of '
                  '${_cards.length ~/ 2} pairs found.'
            : 'Cards hidden again. Try another pair.';
      });
      if (isMatch && _matched.length == _cards.length) {
        _finish();
      }
    });
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    _clock.stop();
    widget.onComplete({
      'matched_pairs': _matchedPairs,
      'moves': _moves,
      'elapsed_seconds': _clock.elapsed.inSeconds.clamp(1, 3600),
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_cards.isEmpty || _cards.length.isOdd) {
      return const _BrokenLevel(message: 'These cards are still being made.');
    }
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 520 ? 4 : (_cards.length <= 6 ? 3 : 4);
    return Column(
      children: [
        Text(
          _previewing
              ? 'Look closely… remember every card!'
              : 'Moves: $_moves  •  Pairs: ${_matched.length ~/ 2}',
          key: ValueKey(_previewing),
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Semantics(
          key: const Key('memory-live-status'),
          container: true,
          liveRegion: true,
          label: _status,
          child: ExcludeSemantics(
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        if (_previewing) ...[
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('memory-ready'),
            onPressed: _hidePreview,
            icon: const Icon(Icons.visibility_off_rounded),
            label: const Text('I’m ready — hide cards'),
          ),
        ],
        const SizedBox(height: 16),
        GridView.builder(
          key: const Key('memory-grid'),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _cards.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 0.82,
          ),
          itemBuilder: (context, index) {
            final faceUp =
                _previewing ||
                _first == index ||
                _second == index ||
                _matched.contains(index);
            return _MemoryCard(
              key: Key('memory-card-${_string(_cards[index]['id'])}'),
              item: _cards[index],
              position: index + 1,
              total: _cards.length,
              faceUp: faceUp,
              matched: _matched.contains(index),
              onTap: _previewing || _second != null || _finished
                  ? null
                  : () => _flip(index),
            );
          },
        ),
      ],
    );
  }
}

class _GridJourneyEngine extends StatefulWidget {
  const _GridJourneyEngine({
    required this.level,
    required this.onComplete,
    required this.isSeaPath,
  });

  final GameLevel level;
  final GameEngineComplete onComplete;
  final bool isSeaPath;

  @override
  State<_GridJourneyEngine> createState() => _GridJourneyEngineState();
}

class _GridJourneyEngineState extends State<_GridJourneyEngine> {
  late final Map<String, dynamic> _grid;
  late final int _rows;
  late final int _columns;
  late final _Cell _start;
  late final _Cell _end;
  late final Set<_Cell> _walls;
  late final Map<_Cell, String> _decorations;
  late _Cell _position;
  late List<_Cell> _path;
  String? _nudge;
  bool _finished = false;

  int get _maxPathLength => _rows * _columns * 4;

  @override
  void initState() {
    super.initState();
    _grid = _map(widget.level.config['grid'] ?? widget.level.config);
    _rows = _integer(_grid['rows'], fallback: 4).clamp(2, 10);
    _columns = _integer(_grid['columns'], fallback: 4).clamp(2, 10);
    _start = _cell(_grid['start']);
    _end = _cell(_grid['end'], fallback: _Cell(_rows - 1, _columns - 1));
    _walls = _lists(_grid['walls']).map(_cell).toSet();
    _decorations = {
      for (final decoration in _maps(_grid['decorations']))
        _cell(decoration['position']): _string(decoration['asset_key']),
    };
    _position = _start;
    _path = [_start];
  }

  void _move(int rowDelta, int columnDelta) {
    if (_finished) return;
    final next = _Cell(
      _position.row + rowDelta,
      _position.column + columnDelta,
    );
    if (next.row < 0 ||
        next.row >= _rows ||
        next.column < 0 ||
        next.column >= _columns ||
        _walls.contains(next)) {
      unawaited(HapticFeedback.heavyImpact());
      setState(() => _nudge = 'Oops — that way is blocked. Try another!');
      return;
    }
    final isImmediateBacktrack =
        _path.length >= 2 && next == _path[_path.length - 2];
    if (_path.length >= _maxPathLength && !isImmediateBacktrack) {
      unawaited(HapticFeedback.heavyImpact());
      setState(() {
        _nudge = 'This trail is full. Step back or restart the path.';
      });
      return;
    }
    unawaited(HapticFeedback.selectionClick());
    setState(() {
      _position = next;
      if (isImmediateBacktrack) {
        _path.removeLast();
      } else {
        _path.add(next);
      }
      _nudge = null;
    });
    if (next == _end) {
      _finished = true;
      unawaited(HapticFeedback.mediumImpact());
      widget.onComplete({
        'path': [
          for (final cell in _path) [cell.row, cell.column],
        ],
      });
    }
  }

  bool _canMove(int rowDelta, int columnDelta) {
    if (_finished) return false;
    final next = _Cell(
      _position.row + rowDelta,
      _position.column + columnDelta,
    );
    final physicallyOpen =
        next.row >= 0 &&
        next.row < _rows &&
        next.column >= 0 &&
        next.column < _columns &&
        !_walls.contains(next);
    if (!physicallyOpen) return false;
    final isImmediateBacktrack =
        _path.length >= 2 && next == _path[_path.length - 2];
    return _path.length < _maxPathLength || isImmediateBacktrack;
  }

  String get _journeyStatus {
    final blocked = <String>[
      if (!_canMove(-1, 0)) 'up',
      if (!_canMove(1, 0)) 'down',
      if (!_canMove(0, -1)) 'left',
      if (!_canMove(0, 1)) 'right',
    ];
    final position =
        'Current row ${_position.row + 1}, column ${_position.column + 1}. '
        'Goal row ${_end.row + 1}, column ${_end.column + 1}. '
        '${_path.length - 1} moves.';
    final blockedStatus = blocked.isEmpty
        ? 'Every direction is open.'
        : 'Blocked directions: ${blocked.join(', ')}.';
    return [?_nudge, position, blockedStatus].join(' ');
  }

  void _reset() {
    if (_finished) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() {
      _position = _start;
      _path = [_start];
      _nudge = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              widget.isSeaPath ? '🌊' : '🐋',
              style: const TextStyle(fontSize: 28),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                widget.isSeaPath
                    ? 'Lead everyone to the shining shore!'
                    : 'Guide Jonah to the glowing finish!',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        AspectRatio(
          aspectRatio: _columns / _rows,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: widget.isSeaPath
                  ? const Color(0xFFE5F7FF)
                  : const Color(0xFFDFF5FF),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: const Color(0xFF57B8E8).withValues(alpha: 0.4),
                width: 2,
              ),
            ),
            child: GridView.builder(
              key: const Key('journey-grid'),
              padding: const EdgeInsets.all(7),
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _rows * _columns,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _columns,
              ),
              itemBuilder: (context, index) {
                final cell = _Cell(index ~/ _columns, index % _columns);
                final visited = _path.contains(cell);
                return _JourneyCell(
                  row: cell.row,
                  column: cell.column,
                  isWall: _walls.contains(cell),
                  isCurrent: cell == _position,
                  isEnd: cell == _end,
                  visited: visited,
                  decoration: _decorations[cell],
                  isSeaPath: widget.isSeaPath,
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 9),
        Semantics(
          key: const Key('journey-live-status'),
          container: true,
          liveRegion: true,
          label: _journeyStatus,
          child: const SizedBox.shrink(),
        ),
        SizedBox(
          height: 24,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _nudge == null
                ? Text(
                    '${_path.length - 1} moves',
                    key: const ValueKey('moves'),
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                : Text(
                    _nudge!,
                    key: const ValueKey('blocked'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ),
        _DirectionPad(
          onUp: _canMove(-1, 0) ? () => _move(-1, 0) : null,
          onDown: _canMove(1, 0) ? () => _move(1, 0) : null,
          onLeft: _canMove(0, -1) ? () => _move(0, -1) : null,
          onRight: _canMove(0, 1) ? () => _move(0, 1) : null,
        ),
        TextButton.icon(
          onPressed: _reset,
          icon: const Icon(Icons.replay_rounded),
          label: const Text('Start this path again'),
        ),
      ],
    );
  }
}

class _AimEngine extends StatefulWidget {
  const _AimEngine({required this.level, required this.onComplete});

  final GameLevel level;
  final GameEngineComplete onComplete;

  @override
  State<_AimEngine> createState() => _AimEngineState();
}

class _AimEngineState extends State<_AimEngine> {
  late final Map<String, dynamic> _canvas;
  late final Map<String, dynamic> _target;
  late final double _canvasWidth;
  late final double _canvasHeight;
  late final double _targetX;
  late final double _targetY;
  late final double _radius;
  late final int _maxShots;
  final List<Map<String, dynamic>> _shots = [];
  final FocusNode _boardFocusNode = FocusNode(debugLabel: 'Aim board');
  bool _finished = false;
  bool? _lastHit;
  bool _boardFocused = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _canvas = _map(widget.level.config['canvas']);
    _target = _map(widget.level.config['target']);
    _canvasWidth = _number(_canvas['width'], fallback: 320).clamp(100, 1000);
    _canvasHeight = _number(_canvas['height'], fallback: 220).clamp(100, 1000);
    _targetX = _number(_target['x'], fallback: _canvasWidth * 0.72);
    _targetY = _number(_target['y'], fallback: _canvasHeight * 0.45);
    _radius = _number(_target['radius'], fallback: 28).clamp(8, 150);
    _maxShots = _integer(
      widget.level.config['max_shots'],
      fallback: 3,
    ).clamp(1, 10);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _boardFocusNode.dispose();
    super.dispose();
  }

  void _shoot(TapDownDetails details, Size size) {
    if (_finished || size.width <= 0 || size.height <= 0) return;
    _boardFocusNode.requestFocus();
    final x = details.localPosition.dx / size.width * _canvasWidth;
    final y = details.localPosition.dy / size.height * _canvasHeight;
    _recordShot(x, y);
  }

  void _recordShot(double x, double y) {
    if (_finished) return;
    final hit =
        math.sqrt(math.pow(x - _targetX, 2) + math.pow(y - _targetY, 2)) <=
        _radius;
    unawaited(
      hit ? HapticFeedback.mediumImpact() : HapticFeedback.lightImpact(),
    );
    setState(() {
      _shots.add({'x': x.round(), 'y': y.round()});
      _lastHit = hit;
    });
    if (hit || _shots.length >= _maxShots) {
      _finished = true;
      _timer = Timer(const Duration(milliseconds: 650), () {
        if (mounted) widget.onComplete({'shots': _shots});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final remaining = math.max(0, _maxShots - _shots.length);
    return Column(
      children: [
        Text(
          'Tap the glowing target to send David\'s stone!',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(
              constraints.maxWidth,
              constraints.maxWidth * _canvasHeight / _canvasWidth,
            );
            return FocusableActionDetector(
              key: const Key('aim-focus-target'),
              focusNode: _boardFocusNode,
              enabled: !_finished,
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
              },
              actions: {
                ActivateIntent: CallbackAction<ActivateIntent>(
                  onInvoke: (_) {
                    _recordShot(_targetX, _targetY);
                    return null;
                  },
                ),
              },
              onShowFocusHighlight: (focused) {
                if (mounted) setState(() => _boardFocused = focused);
              },
              child: Semantics(
                label: 'Aim board. Activate to shoot the glowing target.',
                hint: 'You can also touch anywhere on the board to aim.',
                button: true,
                focusable: true,
                focused: _boardFocused,
                enabled: !_finished,
                onTap: _finished ? null : () => _recordShot(_targetX, _targetY),
                child: GestureDetector(
                  key: const Key('aim-board'),
                  behavior: HitTestBehavior.opaque,
                  onTapDown: _finished
                      ? null
                      : (details) => _shoot(details, size),
                  child: SizedBox.fromSize(
                    size: size,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: _boardFocused
                              ? Theme.of(context).colorScheme.primary
                              : Colors.transparent,
                          width: 4,
                        ),
                      ),
                      child: CustomPaint(
                        painter: _AimBoardPainter(
                          canvasWidth: _canvasWidth,
                          canvasHeight: _canvasHeight,
                          targetX: _targetX,
                          targetY: _targetY,
                          radius: _radius,
                          shots: _shots,
                          obstacles: _maps(widget.level.config['obstacles']),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          key: const Key('aim-target-action'),
          onPressed: _finished ? null : () => _recordShot(_targetX, _targetY),
          icon: const Icon(Icons.center_focus_strong_rounded),
          label: const Text('Shoot at the glowing target'),
        ),
        const SizedBox(height: 14),
        Semantics(
          key: const Key('aim-live-status'),
          container: true,
          liveRegion: true,
          label: _lastHit == true
              ? 'Bullseye! Courage and focus!'
              : _lastHit == false
              ? '$remaining ${remaining == 1 ? 'shot' : 'shots'} left. Aim again.'
              : '$remaining shots ready.',
          child: ExcludeSemantics(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              child: Container(
                key: ValueKey('${_shots.length}-$_lastHit'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: _lastHit == true
                      ? const Color(0xFFDEF8E8)
                      : const Color(0xFFFFF0D7),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _lastHit == true
                      ? 'Bullseye! Courage and focus! 🎯'
                      : _lastHit == false
                      ? '$remaining ${remaining == 1 ? 'shot' : 'shots'} left — aim again!'
                      : '$remaining brave shots ready',
                  style: const TextStyle(
                    color: Color(0xFF282333),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected
            ? const Color(0xFFFFE4D9)
            : Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected
                    ? const Color(0xFFFF7043)
                    : Theme.of(context).colorScheme.outlineVariant,
                width: selected ? 2.5 : 1,
              ),
            ),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: selected
                        ? const Color(0xFFFF7043)
                        : Colors.transparent,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected
                          ? const Color(0xFFFF7043)
                          : Theme.of(context).colorScheme.outline,
                      width: 2,
                    ),
                  ),
                  child: selected
                      ? const Icon(
                          Icons.check_rounded,
                          color: Colors.white,
                          size: 18,
                        )
                      : null,
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: selected ? const Color(0xFF3A2530) : null,
                      fontWeight: FontWeight.w800,
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

class _OrderTile extends StatelessWidget {
  const _OrderTile({
    required this.number,
    required this.label,
    required this.assetKey,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onUp,
    required this.onDown,
    required this.dragHandle,
  });

  final int number;
  final String label;
  final String assetKey;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback onUp;
  final VoidCallback onDown;
  final Widget dragHandle;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 1,
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 9, 4, 9),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: const Color(0xFFFFE0D2),
              foregroundColor: const Color(0xFFC94722),
              child: Text(
                '$number',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
            const SizedBox(width: 9),
            if (assetKey.isNotEmpty) ...[
              Text(assetKey, style: const TextStyle(fontSize: 25)),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TinyMoveButton(
                  tooltip: 'Move $label up',
                  icon: Icons.keyboard_arrow_up_rounded,
                  onPressed: canMoveUp ? onUp : null,
                ),
                _TinyMoveButton(
                  tooltip: 'Move $label down',
                  icon: Icons.keyboard_arrow_down_rounded,
                  onPressed: canMoveDown ? onDown : null,
                ),
              ],
            ),
            dragHandle,
          ],
        ),
      ),
    );
  }
}

class _TinyMoveButton extends StatelessWidget {
  const _TinyMoveButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 48,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: 24),
      ),
    );
  }
}

class _MatchTile extends StatelessWidget {
  const _MatchTile({
    required this.item,
    required this.selected,
    required this.connected,
    required this.onTap,
    super.key,
  });

  final Map<String, dynamic> item;
  final bool selected;
  final bool connected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final asset = _string(item['asset_key']);
    return Semantics(
      button: true,
      selected: selected || connected,
      child: Material(
        color: selected
            ? const Color(0xFFFFDACB)
            : connected
            ? const Color(0xFFDCF6E7)
            : Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            constraints: const BoxConstraints(minHeight: 88),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected
                    ? const Color(0xFFFF7043)
                    : connected
                    ? const Color(0xFF36A96B)
                    : Theme.of(context).colorScheme.outlineVariant,
                width: selected || connected ? 2 : 1,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (asset.isNotEmpty)
                  Text(asset, style: const TextStyle(fontSize: 29)),
                Text(
                  _string(item['label'], fallback: 'Card'),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: selected || connected
                        ? const Color(0xFF24352E)
                        : null,
                    fontWeight: FontWeight.w800,
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

class _MemoryCard extends StatelessWidget {
  const _MemoryCard({
    required this.item,
    required this.position,
    required this.total,
    required this.faceUp,
    required this.matched,
    required this.onTap,
    super.key,
  });

  final Map<String, dynamic> item;
  final int position;
  final int total;
  final bool faceUp;
  final bool matched;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final label = _string(item['label'], fallback: 'Mystery card');
    final asset = _string(item['asset_key']);
    return Semantics(
      button: true,
      enabled: onTap != null,
      selected: matched,
      sortKey: OrdinalSortKey(position.toDouble()),
      label: 'Card $position of $total',
      value: matched
          ? '$label, matched'
          : faceUp
          ? '$label, face up'
          : 'Hidden',
      onTap: onTap,
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(17),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              decoration: BoxDecoration(
                gradient: faceUp
                    ? const LinearGradient(
                        colors: [Color(0xFFFFF5D9), Color(0xFFFFE5C3)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : const LinearGradient(
                        colors: [Color(0xFF7653E8), Color(0xFF4730A7)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                borderRadius: BorderRadius.circular(17),
                border: Border.all(
                  color: matched ? const Color(0xFF28A966) : Colors.white,
                  width: matched ? 3 : 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.09),
                    blurRadius: 9,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: faceUp
                    ? Column(
                        key: const ValueKey('front'),
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            asset.isEmpty ? '✨' : asset,
                            style: const TextStyle(fontSize: 31),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              label,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF393143),
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      )
                    : const Center(
                        key: ValueKey('back'),
                        child: Text(
                          '✦',
                          style: TextStyle(color: Colors.white, fontSize: 34),
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _JourneyCell extends StatelessWidget {
  const _JourneyCell({
    required this.row,
    required this.column,
    required this.isWall,
    required this.isCurrent,
    required this.isEnd,
    required this.visited,
    required this.decoration,
    required this.isSeaPath,
  });

  final int row;
  final int column;
  final bool isWall;
  final bool isCurrent;
  final bool isEnd;
  final bool visited;
  final String? decoration;
  final bool isSeaPath;

  @override
  Widget build(BuildContext context) {
    String marker = '';
    if (isCurrent) {
      marker = isSeaPath ? '👣' : '⛵';
    } else if (isEnd) {
      marker = '✨';
    } else if (decoration != null && decoration!.isNotEmpty) {
      marker = decoration!;
    } else if (isWall) {
      marker = isSeaPath ? '🌊' : '🪸';
    } else if (visited) {
      marker = '•';
    }
    final state = isCurrent
        ? 'current position'
        : isEnd
        ? 'goal'
        : isWall
        ? 'blocked'
        : visited
        ? 'visited'
        : 'open';
    return Semantics(
      label: 'Row ${row + 1}, column ${column + 1}, $state',
      child: ExcludeSemantics(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.all(1.5),
          decoration: BoxDecoration(
            color: isWall
                ? const Color(0xFF2E91C7).withValues(alpha: 0.72)
                : visited
                ? Colors.white.withValues(alpha: 0.88)
                : Colors.white.withValues(alpha: 0.43),
            borderRadius: BorderRadius.circular(9),
          ),
          alignment: Alignment.center,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              marker,
              style: TextStyle(
                fontSize: isCurrent || isEnd ? 25 : 18,
                color: const Color(0xFF214A5D),
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DirectionPad extends StatelessWidget {
  const _DirectionPad({
    required this.onUp,
    required this.onDown,
    required this.onLeft,
    required this.onRight,
  });

  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final VoidCallback? onLeft;
  final VoidCallback? onRight;

  @override
  Widget build(BuildContext context) {
    Widget direction(String label, IconData icon, VoidCallback? onPressed) {
      return SizedBox.square(
        dimension: 54,
        child: IconButton.filledTonal(
          tooltip: label,
          onPressed: onPressed,
          icon: Icon(icon, size: 29),
        ),
      );
    }

    return Column(
      children: [
        direction('Move up', Icons.keyboard_arrow_up_rounded, onUp),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            direction('Move left', Icons.keyboard_arrow_left_rounded, onLeft),
            const SizedBox(width: 54),
            direction(
              'Move right',
              Icons.keyboard_arrow_right_rounded,
              onRight,
            ),
          ],
        ),
        direction('Move down', Icons.keyboard_arrow_down_rounded, onDown),
      ],
    );
  }
}

class _AimBoardPainter extends CustomPainter {
  const _AimBoardPainter({
    required this.canvasWidth,
    required this.canvasHeight,
    required this.targetX,
    required this.targetY,
    required this.radius,
    required this.shots,
    required this.obstacles,
  });

  final double canvasWidth;
  final double canvasHeight;
  final double targetX;
  final double targetY;
  final double radius;
  final List<Map<String, dynamic>> shots;
  final List<Map<String, dynamic>> obstacles;

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / canvasWidth;
    final scaleY = size.height / canvasHeight;
    final background = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFFFFE8B2), Color(0xFFFFB77E)],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(Offset.zero & size);
    final bounds = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(24),
    );
    canvas.drawRRect(bounds, background);

    final ground = Paint()..color = const Color(0xFFBD734A);
    canvas.drawRect(
      Rect.fromLTWH(0, size.height * 0.82, size.width, size.height * 0.18),
      ground,
    );

    for (final obstacle in obstacles) {
      final x = _number(obstacle['x']) * scaleX;
      final y = _number(obstacle['y']) * scaleY;
      final asset = _string(obstacle['asset_key']);
      if (_string(obstacle['shape']) == 'circle') {
        final obstacleRadius =
            _number(obstacle['radius'], fallback: 24) *
            math.min(scaleX, scaleY);
        canvas.drawCircle(
          Offset(x, y),
          obstacleRadius,
          Paint()..color = const Color(0xFF8E593D).withValues(alpha: 0.8),
        );
        if (asset.isNotEmpty) {
          final text = TextPainter(
            text: TextSpan(
              text: asset,
              style: TextStyle(fontSize: obstacleRadius * 1.2),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          text.paint(canvas, Offset(x - text.width / 2, y - text.height / 2));
        }
      } else {
        final width = _number(obstacle['width'], fallback: 24) * scaleX;
        final height = _number(obstacle['height'], fallback: 50) * scaleY;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, width, height),
            const Radius.circular(8),
          ),
          Paint()..color = const Color(0xFF8E593D),
        );
      }
    }

    final center = Offset(targetX * scaleX, targetY * scaleY);
    final scaledRadius = radius * math.min(scaleX, scaleY);
    canvas.drawCircle(
      center,
      scaledRadius * 1.38,
      Paint()..color = Colors.white.withValues(alpha: 0.3),
    );
    canvas.drawCircle(
      center,
      scaledRadius,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    canvas.drawCircle(
      center,
      scaledRadius * 0.7,
      Paint()..color = const Color(0xFFFF7043),
    );
    canvas.drawCircle(
      center,
      scaledRadius * 0.38,
      Paint()..color = const Color(0xFFFFD54F),
    );
    canvas.drawCircle(
      center,
      scaledRadius * 0.13,
      Paint()..color = const Color(0xFF343044),
    );

    for (final shot in shots) {
      final point = Offset(
        _number(shot['x']) * scaleX,
        _number(shot['y']) * scaleY,
      );
      canvas.drawCircle(point, 8, Paint()..color = const Color(0xFF343044));
      canvas.drawCircle(point, 3, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant _AimBoardPainter oldDelegate) {
    return oldDelegate.shots.length != shots.length ||
        oldDelegate.targetX != targetX ||
        oldDelegate.targetY != targetY;
  }
}

class _MiniProgress extends StatelessWidget {
  const _MiniProgress({required this.current, required this.total});

  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var index = 0; index < total; index++) ...[
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              height: 6,
              decoration: BoxDecoration(
                color: index < current
                    ? const Color(0xFFFF7043)
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          if (index != total - 1) const SizedBox(width: 5),
        ],
      ],
    );
  }
}

class _BrokenLevel extends StatelessWidget {
  const _BrokenLevel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          const Text('🛠️', style: TextStyle(fontSize: 46)),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class _Cell {
  const _Cell(this.row, this.column);

  final int row;
  final int column;

  @override
  bool operator ==(Object other) {
    return other is _Cell && other.row == row && other.column == column;
  }

  @override
  int get hashCode => Object.hash(row, column);
}

/// Produces one stable shuffle for an attempt while keeping matching cards
/// apart. The server commonly sends pairs next to one another for readability;
/// leaving them that way would reveal every answer before play starts.
List<Map<String, dynamic>> _shuffleMemoryCards(
  List<Map<String, dynamic>> source, {
  required String seed,
}) {
  final shuffled = List<Map<String, dynamic>>.of(source);
  var stableSeed = 17;
  for (final unit
      in '$seed:${source.map((card) => _string(card['id'])).join('|')}'
          .codeUnits) {
    stableSeed = 0x1fffffff & (stableSeed * 31 + unit);
  }
  shuffled.shuffle(math.Random(stableSeed));

  final matchKeys = shuffled.map((card) => _string(card['match_key'])).toSet();
  if (shuffled.length <= 2 || matchKeys.length <= 1) return shuffled;

  final arranged = <Map<String, dynamic>>[];
  final remaining = List<Map<String, dynamic>>.of(shuffled);

  bool placeNext() {
    if (remaining.isEmpty) return true;
    final previousKey = arranged.isEmpty
        ? null
        : _string(arranged.last['match_key']);
    for (var index = 0; index < remaining.length; index++) {
      final card = remaining[index];
      if (_string(card['match_key']) == previousKey) continue;
      arranged.add(card);
      remaining.removeAt(index);
      if (placeNext()) return true;
      remaining.insert(index, arranged.removeLast());
    }
    return false;
  }

  return placeNext() ? arranged : shuffled;
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return const {};
}

List<Map<String, dynamic>> _maps(Object? value) {
  if (value is! List) return const [];
  return value.map(_map).where((item) => item.isNotEmpty).toList();
}

List<List<dynamic>> _lists(Object? value) {
  if (value is! List) return const [];
  return value.whereType<List>().toList();
}

String _string(Object? value, {String fallback = ''}) {
  final result = value?.toString().trim() ?? '';
  return result.isEmpty ? fallback : result;
}

double _number(Object? value, {double fallback = 0}) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}

int _integer(Object? value, {int fallback = 0}) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

_Cell _cell(Object? value, {_Cell fallback = const _Cell(0, 0)}) {
  if (value is List && value.length >= 2) {
    return _Cell(_integer(value[0]), _integer(value[1]));
  }
  return fallback;
}

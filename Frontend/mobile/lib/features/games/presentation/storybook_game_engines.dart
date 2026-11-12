import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../domain/mini_game.dart';
import 'ark_boarding_engine.dart';

List<Map<String, dynamic>> _rows(Object? value) => value is List
    ? value.whereType<Map>().map((v) => Map<String, dynamic>.from(v)).toList()
    : [];
String _text(Object? value) => value is String ? value : '';

class StoryQuizEngine extends StatefulWidget {
  const StoryQuizEngine({
    required this.level,
    required this.onComplete,
    super.key,
  });
  final GameLevel level;
  final ValueChanged<Map<String, dynamic>> onComplete;
  @override
  State<StoryQuizEngine> createState() => _StoryQuizEngineState();
}

class _StoryQuizEngineState extends State<StoryQuizEngine> {
  late final _questions = _rows(widget.level.config['questions']);
  final Map<String, String> _answers = {};
  int _index = 0;
  bool _done = false;
  void _next() {
    if (_done || _questions.isEmpty) return;
    final id = _text(_questions[_index]['id']);
    if (!_answers.containsKey(id)) return;
    HapticFeedback.selectionClick();
    if (_index < _questions.length - 1) {
      setState(() => _index++);
    } else {
      setState(() => _done = true);
      widget.onComplete({
        'answers': [
          for (final q in _questions)
            {'question_id': q['id'], 'option_id': _answers[q['id']]},
        ],
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_questions.isEmpty) return const Text('A new question is on its way.');
    final question = _questions[_index];
    final id = _text(question['id']);
    final options = _rows(question['options']);
    const colors = [
      Color(0xFF7957D5),
      Color(0xFF238FAD),
      Color(0xFFDA7548),
      Color(0xFF529663),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GameHeading(
          title: widget.level.title.trim().isEmpty
              ? 'Story quiz'
              : widget.level.title,
          subtitle: widget.level.instructions,
          icon: Icons.auto_awesome,
          color: Color(0xFF7957D5),
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < _questions.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: i == _index ? 36 : 22,
                  height: 12,
                  decoration: BoxDecoration(
                    color: i <= _index
                        ? const Color(0xFF7957D5)
                        : const Color(0xFFE8E1F6),
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 18),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          child: Container(
            key: ValueKey('quiz-question-$id'),
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: const Color(0xFFE7DDF8), width: 2),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x127957D5),
                  offset: Offset(0, 8),
                  blurRadius: 18,
                ),
              ],
            ),
            child: Column(
              children: [
                Text(
                  'QUESTION ${_index + 1} OF ${_questions.length}',
                  style: const TextStyle(
                    color: Color(0xFF7957D5),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _text(question['prompt']),
                  key: const Key('quiz-question'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 25,
                    height: 1.22,
                    color: Color(0xFF292142),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        for (var i = 0; i < options.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _AnswerCard(
              key: Key('quiz-option-${_text(options[i]['id'])}'),
              letter: String.fromCharCode(65 + i),
              label: _text(options[i]['text']),
              color: colors[i % colors.length],
              selected: _answers[id] == options[i]['id'],
              onTap: _done
                  ? null
                  : () {
                      HapticFeedback.selectionClick();
                      setState(() => _answers[id] = _text(options[i]['id']));
                    },
            ),
          ),
        const SizedBox(height: 6),
        _GameAction(
          key: const Key('quiz-continue'),
          label: _index == _questions.length - 1
              ? 'Finish my quest'
              : 'Lock in & continue',
          icon: Icons.arrow_forward_rounded,
          color: const Color(0xFF7957D5),
          onTap: _answers[id] == null || _done ? null : _next,
        ),
      ],
    );
  }
}

class CreationStudioEngine extends StatefulWidget {
  const CreationStudioEngine({
    required this.level,
    required this.onComplete,
    super.key,
  });
  final GameLevel level;
  final ValueChanged<Map<String, dynamic>> onComplete;
  @override
  State<CreationStudioEngine> createState() => _CreationStudioEngineState();
}

class _CreationStudioEngineState extends State<CreationStudioEngine> {
  late final _items = _rows(widget.level.config['items']);
  late final List<String?> _slots = List.filled(_items.length, null);
  String? _selected;
  bool _done = false;

  void _place(String id, int index) {
    if (_done ||
        index < 0 ||
        index >= _slots.length ||
        !_items.any((item) => item['id'] == id)) {
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      final old = _slots.indexOf(id);
      if (old >= 0) _slots[old] = _slots[index];
      _slots[index] = id;
      _selected = null;
    });
  }

  Map<String, dynamic> _item(String id) =>
      _items.firstWhere((item) => item['id'] == id);

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const Text('Creation is being prepared.');
    final placed = _slots.whereType<String>().length;
    final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
    final available = _items
        .where((item) => !_slots.contains(item['id']))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.asset(
                'assets/images/stories/creation-week-v2.webp',
                height: 50,
                width: 50,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Creation studio',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF996516),
                    ),
                  ),
                  Text(
                    '$placed of ${_items.length} wonders placed',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF756746),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Drag each wonder to its day. You can tap, too.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF756746), fontSize: 12, height: 1.3),
        ),
        const SizedBox(height: 12),
        GridView.builder(
          key: const Key('creation-day-board'),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _slots.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            mainAxisExtent: scale > 1.3 ? 76 : 58,
          ),
          itemBuilder: (context, index) => DragTarget<String>(
            onWillAcceptWithDetails: (details) =>
                !_done && _items.any((item) => item['id'] == details.data),
            onAcceptWithDetails: (details) => _place(details.data, index),
            builder: (context, candidates, rejected) {
              final id = _slots[index];
              final selected = id != null && _selected == id;
              final tile = Semantics(
                label:
                    'Day ${index + 1}${id == null ? ', empty' : ', ${_text(_item(id)['label'])}'}',
                selected: selected,
                button: true,
                child: GestureDetector(
                  key: Key('creation-day-$index'),
                  onTap: _done
                      ? null
                      : () {
                          if (_selected != null) {
                            _place(_selected!, index);
                          } else if (id != null) {
                            setState(() => _selected = id);
                          }
                        },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: candidates.isNotEmpty || selected
                          ? const Color(0xFFFFE3A5)
                          : id == null
                          ? const Color(0xFFFFF8E8)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(17),
                      border: Border.all(
                        color: id == null
                            ? const Color(0xFFE9D8AF)
                            : const Color(0xFFE3B84F),
                        width: 2,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 25,
                          height: 25,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            color: Color(0xFFFFDF82),
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            (index + 1).toString(),
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF795018),
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            id == null
                                ? 'Day ${index + 1}'
                                : _text(_item(id)['label']),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: id == null
                                  ? const Color(0xFFAD9670)
                                  : const Color(0xFF443619),
                            ),
                          ),
                        ),
                        if (id == null)
                          const Icon(
                            Icons.add_rounded,
                            size: 18,
                            color: Color(0xFFC6A068),
                          ),
                      ],
                    ),
                  ),
                ),
              );
              if (id == null) return tile;
              return Draggable<String>(
                data: id,
                maxSimultaneousDrags: _done ? 0 : 1,
                feedback: Material(
                  color: Colors.transparent,
                  child: SizedBox(
                    width: 130,
                    child: _CreationTile(item: _item(id), selected: true),
                  ),
                ),
                childWhenDragging: Opacity(opacity: .3, child: tile),
                child: tile,
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) => GridView.builder(
            key: const Key('creation-wonder-tray'),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: available.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: scale > 1.3 ? 2 : 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              mainAxisExtent: scale > 1.3 ? 105 : 82,
            ),
            itemBuilder: (context, index) {
              final item = available[index];
              final id = _text(item['id']);
              final card = _CompactWonderTile(
                item: item,
                selected: _selected == id,
              );
              return Draggable<String>(
                data: id,
                maxSimultaneousDrags: _done ? 0 : 1,
                feedback: Material(
                  color: Colors.transparent,
                  child: SizedBox(
                    width: 130,
                    height: 90,
                    child: _CompactWonderTile(item: item, selected: true),
                  ),
                ),
                childWhenDragging: Opacity(opacity: .25, child: card),
                child: GestureDetector(
                  key: Key('creation-tile-$id'),
                  onTap: _done ? null : () => setState(() => _selected = id),
                  child: card,
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        _GameAction(
          key: const Key('ordering-check'),
          label: 'Reveal my creation week',
          icon: Icons.auto_awesome_rounded,
          color: const Color(0xFFB98124),
          onTap: _done || placed != _items.length
              ? null
              : () {
                  if (_done) return;
                  setState(() => _done = true);
                  widget.onComplete({'sequence': List<String>.from(_slots)});
                },
        ),
      ],
    );
  }
}

class _CompactWonderTile extends StatelessWidget {
  const _CompactWonderTile({required this.item, required this.selected});
  final Map<String, dynamic> item;
  final bool selected;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(5),
    decoration: BoxDecoration(
      color: selected ? const Color(0xFFFFE6AB) : Colors.white,
      borderRadius: BorderRadius.circular(17),
      border: Border.all(
        color: selected ? const Color(0xFFE1AB2D) : const Color(0xFFE9DECB),
        width: 2,
      ),
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _SceneSymbol(symbol: _text(item['asset_key']), size: 25),
        const SizedBox(height: 4),
        Flexible(
          child: Text(
            _text(item['label']),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF544126),
              fontSize: 11,
              fontWeight: FontWeight.w800,
              height: 1.2,
            ),
          ),
        ),
      ],
    ),
  );
}

class LanternMemoryEngine extends StatefulWidget {
  const LanternMemoryEngine({
    required this.level,
    required this.onComplete,
    super.key,
  });
  final GameLevel level;
  final ValueChanged<Map<String, dynamic>> onComplete;
  @override
  State<LanternMemoryEngine> createState() => _LanternMemoryEngineState();
}

class _LanternMemoryEngineState extends State<LanternMemoryEngine>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final List<Map<String, dynamic>> _cards;
  late final AnimationController _clock;
  final List<List<String>> _pairs = [];
  final Set<int> _matched = {};
  Duration? _resolveAt;
  int? _first, _second;
  int _moves = 0;
  late final int _previewSeconds;
  int _lastCountdown = 0;
  bool _preview = true, _done = false, _paused = false;
  String _status = 'Watch the lanterns. Remember their hidden treasures!';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cards = _memoryDeck(_rows(widget.level.config['cards']), widget.level.id);
    _previewSeconds =
        (widget.level.config['preview_seconds'] is int
                ? widget.level.config['preview_seconds'] as int
                : 3)
            .clamp(0, 30);
    _preview = _previewSeconds > 0;
    _lastCountdown = _previewSeconds;
    _clock = AnimationController.unbounded(vsync: this)..addListener(_tick);
    final state = WidgetsBinding.instance.lifecycleState;
    _paused = state != null && state != AppLifecycleState.resumed;
    if (!_paused && _cards.isNotEmpty && _cards.length.isEven) _runClock();
  }

  Duration get _elapsed => Duration(
    microseconds: (_clock.value * Duration.microsecondsPerSecond).round(),
  );

  void _runClock() => _clock.animateWith(_ActiveGameClock(_clock.value));

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && !_done) {
      _clock.stop();
      if (mounted) setState(() => _paused = true);
    }
  }

  void _tick() {
    if (!mounted || _done || _paused) return;
    if (_preview && _elapsed.inSeconds >= _previewSeconds) {
      setState(() {
        _preview = false;
        _status = 'Find two treasures that belong together.';
      });
    } else if (_resolveAt != null && _elapsed >= _resolveAt!) {
      final first = _first!, second = _second!;
      final match = _cards[first]['match_key'] == _cards[second]['match_key'];
      setState(() {
        if (match) {
          _matched.addAll([first, second]);
          _pairs.add([_text(_cards[first]['id']), _text(_cards[second]['id'])]);
        }
        _first = _second = null;
        _resolveAt = null;
        _status = match
            ? 'A lantern is lit! Keep the light growing.'
            : 'Remember those treasures. You can try again.';
      });
      if (_matched.length == _cards.length) {
        _done = true;
        _clock.stop();
        widget.onComplete({
          'matched_pairs': _pairs,
          'moves': _moves,
          'elapsed_seconds': (_elapsed.inSeconds - _previewSeconds).clamp(
            0,
            3600,
          ),
        });
      }
    } else if (_preview) {
      final countdown = math.max(0, _previewSeconds - _elapsed.inSeconds);
      if (countdown != _lastCountdown) {
        setState(() => _lastCountdown = countdown);
      }
    }
  }

  void _flip(int index) {
    if (_done ||
        _paused ||
        _preview ||
        _second != null ||
        _matched.contains(index) ||
        _first == index) {
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      if (_first == null) {
        _first = index;
        _status =
            '${_text(_cards[index]['label'])} revealed. Where is its partner?';
      } else {
        _second = index;
        _moves++;
        _resolveAt = _elapsed + const Duration(milliseconds: 650);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_cards.isEmpty || _cards.length.isOdd) {
      return const Text('The lanterns are being prepared.');
    }
    final countdown = math.max(0, _previewSeconds - _elapsed.inSeconds);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _GameHeading(
          title: 'Daniel’s lantern hunt',
          subtitle: 'Find the treasures. Light the whole night.',
          icon: Icons.nights_stay_rounded,
          color: Color(0xFF565191),
          compact: true,
          artworkAsset: 'assets/images/stories/daniel-in-the-lions-den-v2.webp',
        ),
        const SizedBox(height: 15),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF25204F), Color(0xFF4F438D)],
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      _preview
                          ? 'A little peek · $countdown'
                          : '$_moves ${_moves == 1 ? 'move' : 'moves'}',
                      style: const TextStyle(
                        color: Color(0xFFE8DFFB),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    '${_pairs.length}/${_cards.length ~/ 2} lights',
                    style: const TextStyle(
                      color: Color(0xFFFFDD83),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < _cards.length ~/ 2; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 7),
                      child: AnimatedScale(
                        scale: i < _pairs.length ? 1.2 : 1,
                        duration: const Duration(milliseconds: 280),
                        child: Icon(
                          Icons.lightbulb_rounded,
                          size: 23,
                          color: i < _pairs.length
                              ? const Color(0xFFFFDC7C)
                              : const Color(0xFF7B70A8),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 7),
              Semantics(
                key: const Key('memory-live-status'),
                liveRegion: true,
                child: Text(
                  _paused ? 'Your lantern hunt is paused.' : _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFE8E1FA),
                    height: 1.35,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_paused)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _GameAction(
              key: const Key('memory-resume'),
              label: 'Continue my hunt',
              icon: Icons.play_arrow_rounded,
              color: const Color(0xFF565191),
              onTap: () {
                final state = WidgetsBinding.instance.lifecycleState;
                if (state != null && state != AppLifecycleState.resumed) return;
                setState(() => _paused = false);
                _runClock();
              },
            ),
          ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
            final columns = constraints.maxWidth < 330 || scale > 1.3 ? 2 : 3;
            return GridView.builder(
              key: const Key('memory-grid'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _cards.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                mainAxisExtent: scale > 1.3 ? 150 : 93,
              ),
              itemBuilder: (context, index) => _LanternCard(
                key: Key('memory-card-${_text(_cards[index]['id'])}'),
                card: _cards[index],
                faceUp:
                    _preview ||
                    _matched.contains(index) ||
                    _first == index ||
                    _second == index,
                matched: _matched.contains(index),
                enabled:
                    !_preview &&
                    !_done &&
                    !_paused &&
                    _second == null &&
                    !_matched.contains(index),
                onTap: () => _flip(index),
              ),
            );
          },
        ),
      ],
    );
  }
}

class StoryMatchingEngine extends StatefulWidget {
  const StoryMatchingEngine({
    required this.level,
    required this.onComplete,
    super.key,
  });
  final GameLevel level;
  final ValueChanged<Map<String, dynamic>> onComplete;
  @override
  State<StoryMatchingEngine> createState() => _StoryMatchingEngineState();
}

class _StoryMatchingEngineState extends State<StoryMatchingEngine> {
  late final _left = _rows(widget.level.config['left_items']);
  late final _right = _rows(widget.level.config['right_items']);
  final Map<String, String> _pairs = {};
  String? _selected;
  bool _done = false;
  void _place(String left, String right) {
    if (_done) return;
    setState(() {
      _pairs.removeWhere((k, v) => v == right);
      _pairs[left] = right;
      _selected = null;
    });
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
    final largeText = scale > 1.3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _GameHeading(
          title: 'Moses’ story links',
          subtitle: 'Bring each clue to its story moment.',
          icon: Icons.auto_stories_rounded,
          color: Color(0xFF308B85),
          compact: true,
        ),
        const SizedBox(height: 12),
        GridView.builder(
          key: const Key('matching-clue-tray'),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _left.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: largeText ? 2 : 3,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            mainAxisExtent: largeText ? 110 : 82,
          ),
          itemBuilder: (context, index) {
            final item = _left[index];
            final id = _text(item['id']);
            final tile = _CompactWonderTile(
              item: item,
              selected: _selected == id,
            );
            return Draggable<String>(
              data: id,
              maxSimultaneousDrags: _done ? 0 : 1,
              feedback: Material(
                color: Colors.transparent,
                child: SizedBox(
                  width: 130,
                  height: 92,
                  child: _CompactWonderTile(item: item, selected: true),
                ),
              ),
              childWhenDragging: Opacity(opacity: .25, child: tile),
              child: GestureDetector(
                key: Key('match-left-$id'),
                onTap: _done ? null : () => setState(() => _selected = id),
                child: tile,
              ),
            );
          },
        ),
        const SizedBox(height: 14),
        GridView.builder(
          key: const Key('matching-moment-board'),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _right.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: largeText ? 1 : 2,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            mainAxisExtent: largeText ? 116 : 92,
          ),
          itemBuilder: (context, index) {
            final item = _right[index];
            final id = _text(item['id']);
            return DragTarget<String>(
              onWillAcceptWithDetails: (details) =>
                  !_done && _left.any((item) => item['id'] == details.data),
              onAcceptWithDetails: (details) => _place(details.data, id),
              builder: (context, candidates, rejected) {
                final assigned = _pairs.entries
                    .where((entry) => entry.value == id)
                    .firstOrNull;
                final source = assigned == null
                    ? null
                    : _left.firstWhere((item) => item['id'] == assigned.key);
                return _StoryMomentTile(
                  key: Key('match-right-$id'),
                  item: item,
                  source: source,
                  hovered: candidates.isNotEmpty,
                  onTap: _selected == null || _done
                      ? null
                      : () => _place(_selected!, id),
                );
              },
            );
          },
        ),
        const SizedBox(height: 12),
        _GameAction(
          key: const Key('matching-check'),
          label: 'Check my story links',
          icon: Icons.auto_awesome_rounded,
          color: const Color(0xFF308B85),
          onTap: _done || _pairs.length != _left.length
              ? null
              : () {
                  if (_done) return;
                  setState(() => _done = true);
                  widget.onComplete({
                    'pairs': [
                      for (final entry in _pairs.entries)
                        {'left_id': entry.key, 'right_id': entry.value},
                    ],
                  });
                },
        ),
      ],
    );
  }
}

class _StoryMomentTile extends StatelessWidget {
  const _StoryMomentTile({
    required this.item,
    required this.source,
    required this.hovered,
    required this.onTap,
    super.key,
  });
  final Map<String, dynamic> item;
  final Map<String, dynamic>? source;
  final bool hovered;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    label:
        '${_text(item['label'])}${source == null ? '' : ', linked to ${_text(source!['label'])}'}',
    selected: source != null,
    button: true,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: hovered
                ? const Color(0xFFFFF0C5)
                : source == null
                ? Colors.white
                : const Color(0xFFE6F6EE),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: hovered
                  ? const Color(0xFFCCAA45)
                  : source == null
                  ? const Color(0xFFCBE1D9)
                  : const Color(0xFF308B85),
              width: 2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _text(item['label']),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF25554C),
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          height: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    _SceneSymbol(symbol: _text(item['asset_key']), size: 20),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              if (source == null)
                const Text(
                  'Drop a clue here',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Color(0xFF7D958C),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                )
              else
                Row(
                  children: [
                    const Icon(
                      Icons.check_circle_rounded,
                      color: Color(0xFF308B85),
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        _text(source!['label']),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF308B85),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _GameHeading extends StatelessWidget {
  const _GameHeading({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    this.compact = false,
    this.artworkAsset,
  });
  final String title, subtitle;
  final IconData icon;
  final Color color;
  final bool compact;
  final String? artworkAsset;
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(compact ? 9 : 18),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(24),
    ),
    child: Row(
      children: [
        if (artworkAsset != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: Image.asset(
              artworkAsset!,
              width: 50,
              height: 50,
              fit: BoxFit.cover,
            ),
          )
        else
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(17),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: .2),
                  blurRadius: 12,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
        const SizedBox(width: 15),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: compact ? 1 : null,
                overflow: compact ? TextOverflow.ellipsis : null,
                style: TextStyle(
                  fontSize: compact ? 18 : 21,
                  fontWeight: FontWeight.w900,
                  color: color,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: compact ? 12 : 13,
                  height: 1.35,
                  color: Color(0xFF6C6279),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _GameAction extends StatelessWidget {
  const _GameAction({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    super.key,
  });
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: onTap,
    style: FilledButton.styleFrom(
      backgroundColor: color,
      foregroundColor: Colors.white,
      minimumSize: const Size(0, 56),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(19)),
    ),
    icon: Icon(icon),
    label: Text(
      label,
      textAlign: TextAlign.center,
      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
    ),
  );
}

class _AnswerCard extends StatelessWidget {
  const _AnswerCard({
    required this.letter,
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
    super.key,
  });
  final String letter, label;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    label: label,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(21),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: .12) : Colors.white,
            borderRadius: BorderRadius.circular(21),
            border: Border.all(
              color: selected ? color : color.withValues(alpha: .2),
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: .08),
                offset: const Offset(0, 5),
                blurRadius: 10,
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Text(
                  letter,
                  style: TextStyle(
                    color: color,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xFF352B46),
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
              ),
              if (selected)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(Icons.check_circle_rounded, color: color),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _CreationTile extends StatelessWidget {
  const _CreationTile({required this.item, required this.selected});
  final Map<String, dynamic> item;
  final bool selected;
  @override
  Widget build(BuildContext context) => Container(
    width: 148,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: selected ? const Color(0xFFFFE6AB) : Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: selected ? const Color(0xFFE1AB2D) : const Color(0xFFE9DECB),
        width: 2,
      ),
    ),
    child: Column(
      children: [
        _SceneSymbol(symbol: _text(item['asset_key']), size: 40),
        const SizedBox(height: 8),
        Text(
          _text(item['label']),
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFF544126),
            fontSize: 13,
            fontWeight: FontWeight.w800,
            height: 1.25,
          ),
        ),
      ],
    ),
  );
}

class _SceneSymbol extends StatelessWidget {
  const _SceneSymbol({required this.symbol, required this.size});
  final String symbol;
  final double size;
  @override
  Widget build(BuildContext context) {
    if (symbol == '🦁') {
      return ArkAnimalPortrait(species: 'lion', size: size * 1.4);
    }
    if (symbol == '👧🏾' || symbol == '🕯️' || symbol == '🦯') {
      return Container(
        width: size * 1.25,
        height: size * 1.25,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: Color(0xFFFFE4B9),
          shape: BoxShape.circle,
        ),
        child: Text(symbol, style: TextStyle(fontSize: size, height: 1)),
      );
    }
    final icon = switch (symbol) {
      '🙏🏾' || '🙏' => Icons.volunteer_activism_rounded,
      '🦁' => Icons.pets_rounded,
      '👑' => Icons.workspace_premium_rounded,
      '😇' => Icons.shield_rounded,
      '🪟' => Icons.window_rounded,
      '📜' => Icons.auto_stories_rounded,
      '🪨' => Icons.landscape_rounded,
      '💡' => Icons.lightbulb_rounded,
      '☁️' => Icons.cloud_rounded,
      '🌱' => Icons.forest_rounded,
      '🌞' || '🌅' => Icons.wb_sunny_rounded,
      '🐋' => Icons.water_rounded,
      '🧑🏾‍🤝‍🧑🏾' => Icons.diversity_3_rounded,
      '😌' => Icons.bedtime_rounded,
      '🪄' => Icons.auto_fix_high_rounded,
      '🧺' => Icons.shopping_basket_rounded,
      '🌊' => Icons.waves_rounded,
      '👀' => Icons.visibility_rounded,
      '🛟' => Icons.sailing_rounded,
      '🏞️' => Icons.landscape_rounded,
      '🔥' => Icons.local_fire_department_rounded,
      '🩴' => Icons.hiking_rounded,
      '🏜️' => Icons.account_balance_rounded,
      '✨' => Icons.auto_awesome_rounded,
      '🗺️' => Icons.map_rounded,
      '⭐' => Icons.star_rounded,
      '🦶🏾' => Icons.do_not_step_rounded,
      '🍞' => Icons.bakery_dining_rounded,
      '😋' => Icons.restaurant_rounded,
      '🔟' => Icons.format_list_numbered_rounded,
      '🛤️' => Icons.alt_route_rounded,
      '🧭' => Icons.explore_rounded,
      '💛' => Icons.favorite_rounded,
      '🕊️' => Icons.flutter_dash_rounded,
      _ => Icons.auto_awesome_rounded,
    };
    return Container(
      width: size * 1.25,
      height: size * 1.25,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFFFD775).withValues(alpha: .3),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: size, color: const Color(0xFFB98132)),
    );
  }
}

class _LanternCard extends StatelessWidget {
  const _LanternCard({
    required this.card,
    required this.faceUp,
    required this.matched,
    required this.enabled,
    required this.onTap,
    super.key,
  });
  final Map<String, dynamic> card;
  final bool faceUp, matched, enabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    excludeSemantics: true,
    button: true,
    enabled: enabled,
    onTap: enabled ? onTap : null,
    label: faceUp
        ? _text(card['label']) + (matched ? ', matched' : ', revealed')
        : 'Hidden treasure',
    child: GestureDetector(
      onTap: enabled ? onTap : null,
      child: TweenAnimationBuilder<double>(
        duration: const Duration(milliseconds: 320),
        tween: Tween(end: faceUp ? 0 : math.pi),
        builder: (context, angle, child) {
          final front = angle < math.pi / 2;
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, .001)
              ..rotateY(front ? angle : angle - math.pi),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: front
                      ? [
                          matched
                              ? const Color(0xFFFFF3BB)
                              : const Color(0xFFFFFAF1),
                          const Color(0xFFFFE6B0),
                        ]
                      : const [Color(0xFF615397), Color(0xFF352955)],
                ),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: matched
                      ? const Color(0xFFE9BF54)
                      : const Color(0xFFBCACDF),
                  width: 2,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x203E305D),
                    offset: Offset(0, 6),
                    blurRadius: 9,
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (front) ...[
                    _SceneSymbol(symbol: _text(card['asset_key']), size: 26),
                    const SizedBox(height: 6),
                    Text(
                      _text(card['label']),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF765526),
                      ),
                    ),
                  ] else ...[
                    const Icon(
                      Icons.flare_rounded,
                      color: Color(0xFFF7D991),
                      size: 39,
                    ),
                    const SizedBox(height: 7),
                    const Text(
                      '?',
                      style: TextStyle(
                        color: Color(0xFFBEABD9),
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// Elapsed active time stays on Flutter's monotonic frame clock. Stopping and
/// restarting the controller preserves the preview and any open pair delay.
class _ActiveGameClock extends Simulation {
  _ActiveGameClock(this.initialSeconds);
  final double initialSeconds;
  @override
  double x(double time) => initialSeconds + time;
  @override
  double dx(double time) => 1;
  @override
  bool isDone(double time) => false;
}

List<Map<String, dynamic>> _memoryDeck(
  List<Map<String, dynamic>> source,
  String seed,
) {
  final random = math.Random(
    seed.codeUnits.fold<int>(
      17,
      (value, unit) => (value * 31 + unit) & 0x7fffffff,
    ),
  );
  final deck = List<Map<String, dynamic>>.of(source);
  if (deck.length <= 2) return deck;
  for (var attempt = 0; attempt < 32; attempt++) {
    deck.shuffle(random);
    var adjacentPair = false;
    for (var index = 1; index < deck.length; index++) {
      if (deck[index - 1]['match_key'] == deck[index]['match_key']) {
        adjacentPair = true;
        break;
      }
    }
    if (!adjacentPair) return deck;
  }
  final groups = <String, List<Map<String, dynamic>>>{};
  for (final card in deck) {
    groups.putIfAbsent(_text(card['match_key']), () => []).add(card);
  }
  if (groups.values.any((cards) => cards.length != 2)) return deck;
  return [
    for (final cards in groups.values) cards.first,
    for (final cards in groups.values) cards.last,
  ];
}

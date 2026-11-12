import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/mini_game.dart';

const _arkInk = Color(0xFF213F55);
const _arkTeal = Color(0xFF087D89);
const _arkGold = Color(0xFFFFC84C);

/// A timed, two-by-two boarding round. The server verifies the submitted
/// animals and goal; this engine only records the pairs actually boarded.
class ArkBoardingEngine extends StatefulWidget {
  const ArkBoardingEngine({
    required this.level,
    required this.onComplete,
    super.key,
  });

  final GameLevel level;
  final void Function(Map<String, dynamic>) onComplete;

  @override
  State<ArkBoardingEngine> createState() => _ArkBoardingEngineState();
}

class _ArkBoardingEngineState extends State<ArkBoardingEngine>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _ArkRound? _round;
  late final AnimationController _clock;
  final List<Map<String, String>> _boarded = [];
  final Set<String> _boardedLeft = {};
  final List<_ArkAnimal> _waiting = [];
  String? _selected;
  String _message = 'Drag an animal to its waiting friend aboard the ark.';
  bool _paused = false;
  bool _finished = false;
  bool _sent = false;
  int _streak = 0;
  int _nextWaiting = 0;
  int _dragGeneration = 0;

  bool get _canBoard => _round != null && !_paused && !_finished;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _round = _ArkRound.tryParse(widget.level.config);
    _clock =
        AnimationController(
          vsync: this,
          duration: Duration(seconds: _round?.seconds ?? 45),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) _finish();
        });
    final round = _round;
    if (round != null) {
      _waiting.addAll(round.right.take(3));
      _nextWaiting = _waiting.length;
      final state = WidgetsBinding.instance.lifecycleState;
      _paused = state != null && state != AppLifecycleState.resumed;
      if (!_paused) _clock.forward();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed || _finished || _round == null) {
      return;
    }
    _clock.stop();
    if (mounted) {
      setState(() {
        _paused = true;
        _dragGeneration += 1;
        _selected = null;
        _message = 'Your animals are safe. Resume when you are ready.';
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock.dispose();
    super.dispose();
  }

  void _togglePause() {
    if (_finished || _round == null) return;
    if (_paused) {
      final state = WidgetsBinding.instance.lifecycleState;
      if (state != null && state != AppLifecycleState.resumed) return;
      setState(() {
        _paused = false;
        _message = 'Welcome back! Bring the next animal friend aboard.';
      });
      _clock.forward();
    } else {
      _clock.stop();
      setState(() {
        _paused = true;
        _dragGeneration += 1;
        _selected = null;
        _message = 'Take a little break. Your round is paused.';
      });
    }
  }

  List<_ArkAnimal> get _dock {
    final round = _round;
    if (round == null) return const [];
    final remaining = round.left
        .where((animal) => !_boardedLeft.contains(animal.id))
        .toList();
    final shown = <_ArkAnimal>[];
    for (final partner in _waiting) {
      for (final animal in remaining) {
        if (animal.species == partner.species) {
          shown.add(animal);
          break;
        }
      }
    }
    for (final animal in remaining) {
      if (shown.length == 6) break;
      if (!shown.any((shownAnimal) => shownAnimal.id == animal.id)) {
        shown.add(animal);
      }
    }
    shown.shuffle(math.Random(_seed(widget.level.id) + _boarded.length));
    return shown;
  }

  void _select(_ArkAnimal animal) {
    if (!_canBoard || _boardedLeft.contains(animal.id)) return;
    setState(() {
      _selected = _selected == animal.id ? null : animal.id;
      _message = _selected == null
          ? 'Drag an animal to its waiting friend aboard the ark.'
          : '${animal.label} selected. Tap its matching friend aboard the ark.';
    });
    HapticFeedback.selectionClick();
  }

  void _board(String animalId, _ArkAnimal partner, {int? generation}) {
    if (!_canBoard ||
        _boardedLeft.contains(animalId) ||
        generation != null && generation != _dragGeneration) {
      return;
    }
    final round = _round!;
    final animal = round.left
        .where((value) => value.id == animalId)
        .firstOrNull;
    final bay = _waiting.indexWhere((value) => value.id == partner.id);
    if (animal == null || bay < 0) return;
    if (animal.species != partner.species) {
      setState(() {
        _streak = 0;
        _message =
            'That ${partner.label.toLowerCase()} is waiting for another ${partner.label.toLowerCase()}.';
      });
      HapticFeedback.lightImpact();
      return;
    }
    setState(() {
      _boarded.add({'left_id': animal.id, 'right_id': partner.id});
      _boardedLeft.add(animal.id);
      _selected = null;
      _streak += 1;
      _message = _streak >= 3
          ? '$_streak pairs in a row! Keep the rescue going!'
          : '${animal.label} friends are aboard! Who is next?';
      if (_nextWaiting < round.right.length) {
        _waiting[bay] = round.right[_nextWaiting++];
      } else {
        _waiting.removeAt(bay);
      }
    });
    HapticFeedback.mediumImpact();
    if (_boarded.length == round.left.length) _finish();
  }

  void _finish() {
    if (_finished || _sent || _round == null) return;
    _clock.stop();
    final round = _round;
    final elapsed = (_clock.value * round.seconds).floor().clamp(
      0,
      round.seconds,
    );
    setState(() {
      _finished = true;
      _selected = null;
      _message = _boarded.length == round.left.length
          ? 'Everyone is aboard! What an amazing rescue!'
          : '${_boarded.length} pairs are safe aboard. Great teamwork!';
    });
    _sent = true;
    widget.onComplete({
      'pairs': List<Map<String, String>>.of(_boarded),
      'elapsed_seconds': elapsed,
    });
  }

  @override
  Widget build(BuildContext context) {
    final round = _round;
    if (round == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'This animal round is taking a little rest. Try another level.',
        ),
      );
    }
    return Container(
      key: const Key('ark-boarding-engine'),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FFF9),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFFC7EEE3), width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _ArkStat(
                  icon: Icons.pets_rounded,
                  label: 'PAIRS ABOARD',
                  value: '${_boarded.length} / ${round.left.length}',
                  valueKey: const Key('ark-boarded-count'),
                ),
              ),
              Expanded(
                child: AnimatedBuilder(
                  animation: _clock,
                  builder: (context, _) {
                    final remainingMilliseconds =
                        (round.seconds * 1000 * (1 - _clock.value)).round();
                    final seconds = (remainingMilliseconds + 999) ~/ 1000;
                    return _ArkStat(
                      icon: Icons.timer_rounded,
                      label: 'TIME LEFT',
                      value: '${seconds}s',
                      valueKey: const Key('ark-time-left'),
                      urgent: seconds <= 10,
                    );
                  },
                ),
              ),
              IconButton.filledTonal(
                key: const Key('ark-pause'),
                tooltip: _paused ? 'Resume round' : 'Pause round',
                onPressed: _finished ? null : _togglePause,
                icon: Icon(
                  _paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          AnimatedBuilder(
            animation: _clock,
            builder: (context, _) => ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: LinearProgressIndicator(
                key: const Key('ark-round-clock'),
                value: 1 - _clock.value,
                minHeight: 7,
                color: _clock.value > 0.8 ? const Color(0xFFE86C55) : _arkTeal,
                backgroundColor: const Color(0xFFD4ECE7),
                semanticsLabel: 'Round time remaining',
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Rescue ${round.goal} pairs to finish · ${_boarded.length * 2} animals safe',
            key: const Key('ark-round-goal'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _arkInk,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 7),
          LayoutBuilder(
            builder: (context, constraints) {
              final height = (constraints.maxWidth * 0.83).clamp(240.0, 320.0);
              return SizedBox(
                height: height,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Positioned.fill(
                      child: RepaintBoundary(
                        child: CustomPaint(painter: _ArkScenePainter()),
                      ),
                    ),
                    Positioned(
                      left: 18,
                      right: 18,
                      top: height * 0.32,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          for (final partner in _waiting)
                            Flexible(child: _bay(partner)),
                        ],
                      ),
                    ),
                    Positioned(
                      bottom: 19,
                      left: 24,
                      right: 24,
                      child: IgnorePointer(
                        child: Text(
                          _streak >= 3
                              ? '$_streak PAIR STREAK!'
                              : 'TWO BY TWO, ABOARD!',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _streak >= 3
                                ? _arkGold
                                : const Color(0xFFFFF1CE),
                            fontWeight: FontWeight.w900,
                            fontSize: 12,
                            letterSpacing: 1,
                            shadows: const [
                              Shadow(color: Color(0xFF623D26), blurRadius: 3),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_paused)
                      Positioned.fill(
                        child: Container(
                          key: const Key('ark-paused-overlay'),
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFFF0FFF9,
                            ).withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.pause_circle_rounded,
                                  size: 44,
                                  color: _arkTeal,
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'A little breather',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    color: _arkInk,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                FilledButton.icon(
                                  key: const Key('ark-resume'),
                                  onPressed: _togglePause,
                                  icon: const Icon(Icons.play_arrow_rounded),
                                  label: const Text('Keep rescuing'),
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
          ),
          const SizedBox(height: 7),
          Semantics(
            liveRegion: true,
            child: Text(
              _message,
              key: const Key('ark-status'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _arkInk,
                fontWeight: FontWeight.w600,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(height: 12),
          IgnorePointer(
            ignoring: !_canBoard,
            child: AnimatedOpacity(
              opacity: _paused || _finished ? 0.48 : 1,
              duration: const Duration(milliseconds: 180),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = (constraints.maxWidth - 16) / 3;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final animal in _dock) _animalTile(animal, width),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bay(_ArkAnimal partner) {
    return DragTarget<_ArkDrag>(
      key: Key('ark-bay-${partner.id}'),
      onWillAcceptWithDetails: (details) =>
          _canBoard &&
          details.data.generation == _dragGeneration &&
          !_boardedLeft.contains(details.data.id),
      onAcceptWithDetails: (details) =>
          _board(details.data.id, partner, generation: details.data.generation),
      builder: (context, candidate, rejected) {
        final hover = candidate.isNotEmpty && _canBoard;
        return Semantics(
          label:
              '${partner.label} waiting aboard. Bring a matching ${partner.label.toLowerCase()}.',
          button: true,
          enabled: _canBoard,
          child: GestureDetector(
            onTap: !_canBoard
                ? null
                : () {
                    if (_selected != null) _board(_selected!, partner);
                  },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 80,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              padding: const EdgeInsets.fromLTRB(3, 6, 3, 7),
              decoration: BoxDecoration(
                color: hover
                    ? const Color(0xFFFFEF96)
                    : const Color(0xFFFFF6D8),
                border: Border.all(
                  color: hover ? _arkTeal : const Color(0xFFB9783C),
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(30),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x22613E22),
                    offset: Offset(0, 3),
                    blurRadius: 4,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: ArkAnimalPortrait(
                      key: ValueKey(partner.id),
                      species: partner.species,
                      size: 47,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    partner.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _arkInk,
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Icon(
                    Icons.add_circle_rounded,
                    color: _arkTeal,
                    size: 19,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _animalTile(_ArkAnimal animal, double width) {
    Widget card({bool feedback = false, bool faded = false}) => Material(
      color: Colors.transparent,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: width,
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 3),
        decoration: BoxDecoration(
          color: faded ? const Color(0xFFE0EDE8) : Colors.white,
          borderRadius: BorderRadius.circular(19),
          border: Border.all(
            color: _selected == animal.id || feedback
                ? _arkTeal
                : const Color(0xFFD4E8DC),
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: _arkTeal.withValues(alpha: feedback ? 0.22 : 0.06),
              blurRadius: feedback ? 12 : 3,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Opacity(
          opacity: faded ? 0.2 : 1,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ArkAnimalPortrait(species: animal.species, size: 49),
              const SizedBox(height: 3),
              Text(
                animal.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _arkInk,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Semantics(
      label: '${animal.label}. Drag to its matching friend, or tap to choose.',
      selected: _selected == animal.id,
      button: true,
      enabled: _canBoard,
      child: Draggable<_ArkDrag>(
        key: Key('ark-animal-${animal.id}'),
        data: _ArkDrag(animal.id, _dragGeneration),
        maxSimultaneousDrags: _canBoard ? 1 : 0,
        feedback: card(feedback: true),
        childWhenDragging: card(faded: true),
        onDragStarted: () {
          if (_canBoard) HapticFeedback.selectionClick();
        },
        child: GestureDetector(onTap: () => _select(animal), child: card()),
      ),
    );
  }
}

class _ArkStat extends StatelessWidget {
  const _ArkStat({
    required this.icon,
    required this.label,
    required this.value,
    required this.valueKey,
    this.urgent = false,
  });
  final IconData icon;
  final String label;
  final String value;
  final Key valueKey;
  final bool urgent;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: urgent ? const Color(0xFFCC5C45) : _arkTeal,
              size: 18,
            ),
            const SizedBox(width: 5),
            Text(
              value,
              key: valueKey,
              style: TextStyle(
                color: urgent ? const Color(0xFFCC5C45) : _arkInk,
                fontWeight: FontWeight.w900,
                fontSize: 21,
              ),
            ),
          ],
        ),
      ),
      Text(
        label,
        style: const TextStyle(
          color: Color(0xFF567367),
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
      ),
    ],
  );
}

class _ArkRound {
  const _ArkRound(this.left, this.right, this.seconds, this.goal);
  final List<_ArkAnimal> left;
  final List<_ArkAnimal> right;
  final int seconds;
  final int goal;

  static _ArkRound? tryParse(Map<String, dynamic> config) {
    final seconds = config['time_limit_seconds'];
    final goal = config['goal_pairs'];
    final left = _animals(config['left_items']);
    final right = _animals(config['right_items']);
    if (config['mode'] != 'ark_boarding' ||
        seconds is! int ||
        seconds < 10 ||
        seconds > 180 ||
        goal is! int ||
        left == null ||
        right == null ||
        left.length != right.length ||
        goal < 1 ||
        goal > left.length) {
      return null;
    }
    final leftSpecies = left.map((animal) => animal.species).toSet();
    final rightSpecies = right.map((animal) => animal.species).toSet();
    if (leftSpecies.length != left.length ||
        rightSpecies.length != right.length ||
        !leftSpecies.containsAll(rightSpecies)) {
      return null;
    }
    return _ArkRound(left, right, seconds, goal);
  }

  static List<_ArkAnimal>? _animals(Object? raw) {
    if (raw is! List || raw.isEmpty || raw.length > 24) return null;
    final animals = <_ArkAnimal>[];
    for (final item in raw) {
      if (item is! Map) return null;
      final id = item['id'];
      final label = item['label'];
      final key = item['asset_key'];
      if (id is! String ||
          id.isEmpty ||
          label is! String ||
          label.isEmpty ||
          key is! String ||
          !key.startsWith('animal:')) {
        return null;
      }
      final species = key.substring(7);
      if (!_animalColors.containsKey(species)) return null;
      animals.add(_ArkAnimal(id, label, species));
    }
    if (animals.map((animal) => animal.id).toSet().length != animals.length) {
      return null;
    }
    return animals;
  }
}

class _ArkAnimal {
  const _ArkAnimal(this.id, this.label, this.species);
  final String id;
  final String label;
  final String species;
}

class _ArkDrag {
  const _ArkDrag(this.id, this.generation);
  final String id;
  final int generation;
}

int _seed(String value) =>
    value.codeUnits.fold(17, (seed, unit) => ((seed * 31) + unit) & 0x7fffffff);

const _animalColors = <String, Color>{
  'lion': Color(0xFFE7AB50),
  'elephant': Color(0xFF91A9C2),
  'giraffe': Color(0xFFECBD5B),
  'zebra': Color(0xFFFFFAED),
  'sheep': Color(0xFFF5F0E3),
  'monkey': Color(0xFFB7794E),
  'rabbit': Color(0xFFEECDBA),
  'panda': Color(0xFFFFFBEE),
  'tiger': Color(0xFFF4A544),
  'penguin': Color(0xFF354B68),
  'hippo': Color(0xFFB1A6C8),
  'bear': Color(0xFFB88966),
};

/// Original vector animal portraits, shared by boarding cards and ship bays.
class ArkAnimalPortrait extends StatelessWidget {
  const ArkAnimalPortrait({required this.species, this.size = 60, super.key});
  final String species;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: RepaintBoundary(
      child: CustomPaint(painter: _AnimalPainter(species)),
    ),
  );
}

class _AnimalPainter extends CustomPainter {
  const _AnimalPainter(this.species);
  final String species;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);
    final fur = _animalColors[species] ?? const Color(0xFFB88966);
    final ink = Paint()..color = const Color(0xFF3F3940);
    void oval(double x, double y, double w, double h, Color color) =>
        canvas.drawOval(
          Rect.fromCenter(center: Offset(x, y), width: w, height: h),
          Paint()..color = color,
        );
    void dot(double x, double y, double radius, Color color) =>
        canvas.drawCircle(Offset(x, y), radius, Paint()..color = color);
    void stroke(
      Offset a,
      Offset b, {
      Color color = const Color(0xFF3F3940),
      double width = 3,
    }) => canvas.drawLine(
      a,
      b,
      Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
    oval(50, 91, 64, 10, const Color(0x18087D89));
    if (species == 'giraffe') {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(39, 48, 22, 44),
          const Radius.circular(9),
        ),
        Paint()..color = fur,
      );
      oval(39, 69, 10, 13, const Color(0xFFC58A3E));
      oval(56, 83, 10, 9, const Color(0xFFC58A3E));
      stroke(const Offset(38, 32), const Offset(35, 11), color: fur, width: 6);
      stroke(const Offset(62, 32), const Offset(66, 11), color: fur, width: 6);
      dot(35, 11, 4, const Color(0xFFAD7844));
      dot(66, 11, 4, const Color(0xFFAD7844));
    }
    if (species == 'rabbit') {
      oval(32, 29, 19, 51, fur);
      oval(68, 29, 19, 51, fur);
      oval(32, 27, 7, 33, const Color(0xFFE89FA8));
      oval(68, 27, 7, 33, const Color(0xFFE89FA8));
    } else if (species == 'elephant') {
      oval(24, 51, 36, 51, fur);
      oval(76, 51, 36, 51, fur);
      oval(22, 51, 19, 33, const Color(0xFFB7BEDE));
      oval(78, 51, 19, 33, const Color(0xFFB7BEDE));
    } else if (species != 'penguin') {
      oval(
        27,
        31,
        species == 'giraffe' ? 25 : 22,
        species == 'giraffe' ? 13 : 23,
        species == 'panda' ? const Color(0xFF3F4658) : fur,
      );
      oval(
        73,
        31,
        species == 'giraffe' ? 25 : 22,
        species == 'giraffe' ? 13 : 23,
        species == 'panda' ? const Color(0xFF3F4658) : fur,
      );
      if (species == 'monkey' || species == 'bear') {
        oval(27, 31, 10, 12, const Color(0xFFE6B59B));
        oval(73, 31, 10, 12, const Color(0xFFE6B59B));
      }
    }
    if (species == 'lion') {
      for (var i = 0; i < 12; i++) {
        final angle = i * math.pi / 6;
        dot(
          50 + math.cos(angle) * 28,
          54 + math.sin(angle) * 29,
          13,
          const Color(0xFFBD7639),
        );
      }
    }
    if (species == 'sheep') {
      for (var i = 0; i < 10; i++) {
        final angle = i * math.pi / 5;
        dot(50 + math.cos(angle) * 27, 54 + math.sin(angle) * 26, 13, fur);
      }
      oval(50, 58, 43, 47, const Color(0xFFB9A797));
    } else {
      oval(
        50,
        species == 'giraffe' ? 44 : 55,
        species == 'hippo' ? 68 : 62,
        species == 'giraffe' ? 49 : 63,
        fur,
      );
    }
    if (species == 'monkey') {
      oval(38, 51, 27, 35, const Color(0xFFF0CFAD));
      oval(62, 51, 27, 35, const Color(0xFFF0CFAD));
      oval(50, 69, 45, 30, const Color(0xFFF0CFAD));
    }
    if (species == 'panda') {
      oval(35, 50, 19, 24, const Color(0xFF3F4658));
      oval(65, 50, 19, 24, const Color(0xFF3F4658));
    }
    if (species == 'penguin') {
      oval(50, 67, 42, 48, const Color(0xFFFFF9E6));
      oval(37, 45, 22, 26, const Color(0xFFFFF9E6));
      oval(63, 45, 22, 26, const Color(0xFFFFF9E6));
      oval(32, 89, 21, 10, const Color(0xFFF7AD40));
      oval(68, 89, 21, 10, const Color(0xFFF7AD40));
    }
    if (species == 'tiger' || species == 'zebra') {
      final stripes = species == 'zebra'
          ? const Color(0xFF48505D)
          : const Color(0xFF8B582B);
      stroke(
        const Offset(38, 29),
        const Offset(41, 40),
        color: stripes,
        width: 5,
      );
      stroke(
        const Offset(50, 27),
        const Offset(50, 39),
        color: stripes,
        width: 5,
      );
      stroke(
        const Offset(62, 29),
        const Offset(59, 40),
        color: stripes,
        width: 5,
      );
      for (final x in [24.0, 76.0]) {
        final sign = x < 50 ? 1 : -1;
        stroke(
          Offset(x, 53),
          Offset(x + sign * 8, 57),
          color: stripes,
          width: 4,
        );
        stroke(
          Offset(x, 65),
          Offset(x + sign * 8, 65),
          color: stripes,
          width: 4,
        );
      }
    }
    if (species == 'hippo') {
      oval(50, 69, 58, 31, const Color(0xFFC8B9D3));
      dot(38, 66, 3, const Color(0xFF827696));
      dot(62, 66, 3, const Color(0xFF827696));
    } else if (species == 'giraffe') {
      oval(50, 56, 44, 20, const Color(0xFFF5D995));
    } else if (species != 'elephant' &&
        species != 'penguin' &&
        species != 'sheep') {
      oval(40, 69, 23, 22, const Color(0xFFFFE8C6));
      oval(60, 69, 23, 22, const Color(0xFFFFE8C6));
    }
    final eyeY = species == 'giraffe' ? 40.0 : 51.0;
    final eyeColor = species == 'panda'
        ? Colors.white
        : const Color(0xFF3F3940);
    oval(36, eyeY, 7, 10, eyeColor);
    oval(64, eyeY, 7, 10, eyeColor);
    dot(37, eyeY - 2, 1.5, Colors.white);
    dot(65, eyeY - 2, 1.5, Colors.white);
    if (species == 'elephant') {
      final trunk = Path()
        ..moveTo(50, 60)
        ..cubicTo(50, 72, 65, 88, 49, 92);
      canvas.drawPath(
        trunk,
        Paint()
          ..color = fur
          ..strokeWidth = 16
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
      stroke(
        const Offset(44, 66),
        const Offset(38, 75),
        color: const Color(0xFFFFF7DA),
        width: 5,
      );
      stroke(
        const Offset(56, 66),
        const Offset(62, 75),
        color: const Color(0xFFFFF7DA),
        width: 5,
      );
      stroke(
        const Offset(46, 81),
        const Offset(53, 81),
        color: const Color(0xFF758AA6),
        width: 2,
      );
    } else if (species == 'penguin') {
      final beak = Path()
        ..moveTo(40, 58)
        ..lineTo(60, 58)
        ..lineTo(50, 68)
        ..close();
      canvas.drawPath(beak, Paint()..color = const Color(0xFFF7AD40));
    } else {
      if (species != 'hippo') {
        oval(
          50,
          species == 'giraffe' ? 54 : 64,
          11,
          8,
          species == 'rabbit'
              ? const Color(0xFFCB8196)
              : const Color(0xFF534044),
        );
      }
      final mouth = Path()
        ..moveTo(42, species == 'giraffe' ? 60 : 75)
        ..quadraticBezierTo(
          50,
          species == 'giraffe' ? 66 : 83,
          58,
          species == 'giraffe' ? 60 : 75,
        );
      canvas.drawPath(
        mouth,
        ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AnimalPainter oldDelegate) =>
      oldDelegate.species != species;
}

class _ArkScenePainter extends CustomPainter {
  const _ArkScenePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final bounds = Offset.zero & size;
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(bounds, const Radius.circular(24)),
    );
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFB8EEFF), Color(0xFFEDFCFF)],
        ).createShader(bounds),
    );
    canvas.drawCircle(
      Offset(w * 0.84, h * 0.15),
      h * 0.085,
      Paint()..color = const Color(0xFFFFDF75),
    );
    for (final cloud in [
      Offset(w * 0.15, h * 0.14),
      Offset(w * 0.53, h * 0.09),
    ]) {
      final paint = Paint()..color = Colors.white.withValues(alpha: 0.86);
      canvas.drawOval(
        Rect.fromCenter(center: cloud, width: w * 0.21, height: h * 0.07),
        paint,
      );
      canvas.drawCircle(cloud + Offset(0, -h * 0.025), h * 0.045, paint);
    }
    final hills = Path()
      ..moveTo(0, h * 0.73)
      ..quadraticBezierTo(w * 0.22, h * 0.48, w * 0.5, h * 0.69)
      ..quadraticBezierTo(w * 0.82, h * 0.48, w, h * 0.65)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(hills, Paint()..color = const Color(0xFF87D2AE));
    canvas.drawRect(
      Rect.fromLTWH(0, h * 0.77, w, h * 0.23),
      Paint()..color = const Color(0xFF5CCAD1),
    );
    for (var i = 0; i < 4; i++) {
      final wave = Path()..moveTo(0, h * (0.82 + i * 0.055));
      for (var x = 0.0; x < w; x += w / 5) {
        wave.relativeQuadraticBezierTo(w / 20, -h * 0.013, w / 10, 0);
        wave.relativeQuadraticBezierTo(w / 20, h * 0.013, w / 10, 0);
      }
      canvas.drawPath(
        wave,
        Paint()
          ..color = const Color(0xFFAAEEF0)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    final hull = Path()
      ..moveTo(w * 0.025, h * 0.6)
      ..lineTo(w * 0.975, h * 0.6)
      ..quadraticBezierTo(w * 0.92, h * 0.93, w * 0.75, h * 0.94)
      ..lineTo(w * 0.25, h * 0.94)
      ..quadraticBezierTo(w * 0.08, h * 0.9, w * 0.025, h * 0.6)
      ..close();
    canvas.drawPath(
      hull.shift(Offset(0, h * 0.025)),
      Paint()..color = const Color(0x223A5861),
    );
    canvas.drawPath(
      hull,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFC78342), Color(0xFF8A512C)],
        ).createShader(Rect.fromLTWH(0, h * 0.6, w, h * 0.35)),
    );
    canvas.save();
    canvas.clipPath(hull);
    for (var i = 0; i < 5; i++) {
      final y = h * (0.64 + i * 0.058);
      canvas.drawLine(
        Offset(0, y),
        Offset(w, y),
        Paint()
          ..color = const Color(0xFF9D5B30)
          ..strokeWidth = 2,
      );
      canvas.drawLine(
        Offset(w * (i.isEven ? 0.35 : 0.65), y),
        Offset(w * (i.isEven ? 0.35 : 0.65), y + h * 0.058),
        Paint()
          ..color = const Color(0xFF9D5B30)
          ..strokeWidth = 2,
      );
    }
    canvas.restore();
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.09, h * 0.27, w * 0.82, h * 0.4),
        const Radius.circular(7),
      ),
      Paint()..color = const Color(0xFFEDB874),
    );
    for (var i = 0; i < 6; i++) {
      final y = h * (0.31 + i * 0.058);
      canvas.drawLine(
        Offset(w * 0.09, y),
        Offset(w * 0.91, y),
        Paint()
          ..color = const Color(0xFFD29B5E)
          ..strokeWidth = 1.5,
      );
    }
    final roof = Path()
      ..moveTo(w * 0.045, h * 0.29)
      ..lineTo(w * 0.23, h * 0.18)
      ..lineTo(w * 0.79, h * 0.18)
      ..lineTo(w * 0.955, h * 0.29)
      ..close();
    canvas.drawPath(roof, Paint()..color = const Color(0xFFDE8056));
    canvas.drawLine(
      Offset(w * 0.055, h * 0.3),
      Offset(w * 0.945, h * 0.3),
      Paint()
        ..color = const Color(0xFF985231)
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      Offset(w * 0.09, h * 0.66),
      Offset(w * 0.91, h * 0.66),
      Paint()
        ..color = const Color(0xFF78462D)
        ..strokeWidth = 8
        ..strokeCap = StrokeCap.round,
    );
    final ramp = Path()
      ..moveTo(w * 0.43, h * 0.68)
      ..lineTo(w * 0.57, h * 0.68)
      ..lineTo(w * 0.64, h)
      ..lineTo(w * 0.36, h)
      ..close();
    canvas.drawPath(ramp, Paint()..color = const Color(0xFFE8C291));
    for (var i = 0; i < 6; i++) {
      final y = h * (0.73 + i * 0.05);
      final halfWidth = w * (0.07 + (y / h - 0.68) * 0.21);
      canvas.drawLine(
        Offset(w / 2 - halfWidth, y),
        Offset(w / 2 + halfWidth, y),
        Paint()
          ..color = const Color(0xFFBE955F)
          ..strokeWidth = 2,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ArkScenePainter oldDelegate) => false;
}

import 'dart:collection';

/// A deterministic harvest board. The server replays [result] with the same
/// seed, gravity order, and xorshift32 stream before awarding any progress.
class RuthHarvestModel {
  RuthHarvestModel._({
    required this.seed,
    required this.rows,
    required this.columns,
    required this.grainTypes,
    required this.goals,
    required this.minChain,
    required this.maxChains,
  }) : _random = _HarvestRandom(seed) {
    _board = List.generate(rows * columns, (_) => _nextGrain());
    for (final grain in grainTypes) {
      _collected[grain] = 0;
    }
    _ensureMatch();
  }

  factory RuthHarvestModel.fromConfig(Map<String, dynamic> config) {
    int integer(String key, int minimum, int maximum) {
      final value = config[key];
      if (value is! int || value < minimum || value > maximum) {
        throw FormatException('Invalid harvest $key.');
      }
      return value;
    }

    if (config['mode'] != 'harvest_chain') {
      throw const FormatException('This is not a harvest-chain level.');
    }
    final seed = integer('seed', 1, 0xffffffff);
    final rows = integer('rows', 6, 6);
    final columns = integer('columns', 5, 5);
    final minChain = integer('min_chain', 3, 3);
    final maxChains = integer('max_chains', 1, 100);
    final rawTypes = config['grain_types'];
    if (rawTypes is! List ||
        rawTypes.length != 3 ||
        rawTypes.any((value) => value is! String) ||
        rawTypes.toSet().length != 3 ||
        !rawTypes.toSet().containsAll(const ['wheat', 'barley', 'oats'])) {
      throw const FormatException('The harvest needs wheat, barley, and oats.');
    }
    final grainTypes = List<String>.unmodifiable(rawTypes.cast<String>());
    final rawGoals = config['goals'];
    if (rawGoals is! Map || rawGoals.length != 3) {
      throw const FormatException('The harvest needs three basket goals.');
    }
    final goals = <String, int>{};
    for (final type in grainTypes) {
      final goal = rawGoals[type];
      if (goal is! int || goal < 1 || goal > 200) {
        throw const FormatException('Invalid harvest basket goal.');
      }
      goals[type] = goal;
    }
    return RuthHarvestModel._(
      seed: seed,
      rows: rows,
      columns: columns,
      grainTypes: grainTypes,
      goals: Map.unmodifiable(goals),
      minChain: minChain,
      maxChains: maxChains,
    );
  }

  final int seed;
  final int rows;
  final int columns;
  final List<String> grainTypes;
  final Map<String, int> goals;
  final int minChain;
  final int maxChains;
  final _HarvestRandom _random;
  late final List<String> _board;
  final Map<String, int> _collected = {};
  final List<List<int>> _chains = [];

  List<String> get board => UnmodifiableListView(_board);
  Map<String, int> get collected => UnmodifiableMapView(_collected);
  int get usedChains => _chains.length;
  int get remainingChains => maxChains - usedChains;
  bool get complete =>
      grainTypes.every((grain) => _collected[grain]! >= goals[grain]!);
  bool get exhausted => remainingChains == 0;
  bool get finished => complete || exhausted;
  int get score {
    if (complete) {
      final denominator = maxChains > 1 ? maxChains - 1 : 1;
      final bonus = (20 * remainingChains / denominator + .5).floor();
      return 80 + bonus.clamp(0, 20);
    }
    final mean = grainTypes.fold<double>(
      0,
      (total, grain) =>
          total + (_collected[grain]! / goals[grain]!).clamp(0.0, 1.0),
    );
    return (50 * mean / grainTypes.length).floor();
  }

  Map<String, dynamic> get result => {
    'chains': _chains.map((chain) => List<int>.of(chain)).toList(),
  };

  bool adjacent(int a, int b) =>
      a >= 0 &&
      a < _board.length &&
      b >= 0 &&
      b < _board.length &&
      a != b &&
      (a ~/ columns - b ~/ columns).abs() <= 1 &&
      (a % columns - b % columns).abs() <= 1;

  bool validChain(List<int> chain) {
    if (finished || chain.length < minChain || chain.length > _board.length) {
      return false;
    }
    if (chain.any((index) => index < 0 || index >= _board.length) ||
        chain.toSet().length != chain.length) {
      return false;
    }
    final type = _board[chain.first];
    for (var index = 0; index < chain.length; index++) {
      if (_board[chain[index]] != type ||
          (index > 0 && !adjacent(chain[index - 1], chain[index]))) {
        return false;
      }
    }
    return true;
  }

  /// Returns the first three-cell match for a gentle, optional visual hint.
  List<int>? findMatch() {
    if (finished) return null;
    for (var start = 0; start < _board.length; start++) {
      for (var second = 0; second < _board.length; second++) {
        if (!adjacent(start, second) || _board[start] != _board[second]) {
          continue;
        }
        for (var third = 0; third < _board.length; third++) {
          if (third != start &&
              adjacent(second, third) &&
              _board[start] == _board[third]) {
            return [start, second, third];
          }
        }
      }
    }
    return null;
  }

  RuthHarvestMove? harvest(List<int> chain) {
    if (!validChain(chain)) return null;
    final before = List<String>.unmodifiable(_board);
    final grain = _board[chain.first];
    _chains.add(List<int>.unmodifiable(chain));
    _collected[grain] = _collected[grain]! + chain.length;
    final removed = chain.toSet();
    final drops = <RuthHarvestDrop>[];
    for (var column = 0; column < columns; column++) {
      final survivors = <int>[];
      for (var row = rows - 1; row >= 0; row--) {
        final cell = row * columns + column;
        if (!removed.contains(cell)) survivors.add(cell);
      }
      var destinationRow = rows - 1;
      for (final source in survivors) {
        final target = destinationRow * columns + column;
        _board[target] = before[source];
        drops.add(
          RuthHarvestDrop(grain: before[source], from: source, to: target),
        );
        destinationRow--;
      }
      while (destinationRow >= 0) {
        final target = destinationRow * columns + column;
        final type = _nextGrain();
        _board[target] = type;
        drops.add(RuthHarvestDrop(grain: type, from: null, to: target));
        destinationRow--;
      }
    }
    final repaired = _ensureMatch();
    return RuthHarvestMove(
      grain: grain,
      cells: List.unmodifiable(chain),
      before: before,
      after: List.unmodifiable(_board),
      drops: List.unmodifiable([
        for (final drop in drops)
          RuthHarvestDrop(
            grain: _board[drop.to],
            from: repaired && (drop.to == 1 || drop.to == 2) ? null : drop.from,
            to: drop.to,
          ),
      ]),
    );
  }

  String _nextGrain() => grainTypes[_random.next() % grainTypes.length];

  bool _ensureMatch() {
    // The repair consumes no RNG, and is also performed after the last move.
    // Searching directly avoids [findMatch]'s finished-state guard.
    for (var first = 0; first < _board.length; first++) {
      for (var second = 0; second < _board.length; second++) {
        if (!adjacent(first, second) || _board[first] != _board[second]) {
          continue;
        }
        for (var third = 0; third < _board.length; third++) {
          if (third != first &&
              adjacent(second, third) &&
              _board[first] == _board[third]) {
            return false;
          }
        }
      }
    }
    _board[1] = _board[0];
    _board[2] = _board[0];
    return true;
  }
}

class RuthHarvestMove {
  const RuthHarvestMove({
    required this.grain,
    required this.cells,
    required this.before,
    required this.after,
    required this.drops,
  });
  final String grain;
  final List<int> cells;
  final List<String> before;
  final List<String> after;
  final List<RuthHarvestDrop> drops;
}

class RuthHarvestDrop {
  const RuthHarvestDrop({
    required this.grain,
    required this.from,
    required this.to,
  });
  final String grain;
  final int? from;
  final int to;
}

class _HarvestRandom {
  _HarvestRandom(this._state);
  int _state;

  int next() {
    var value = _state;
    value ^= (value << 13) & 0xffffffff;
    value ^= value >> 17;
    value ^= (value << 5) & 0xffffffff;
    _state = value & 0xffffffff;
    return _state;
  }
}

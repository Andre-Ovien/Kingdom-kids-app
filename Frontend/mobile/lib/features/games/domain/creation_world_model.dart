import 'dart:collection';

const creationFloorKinds = {'water', 'land', 'forest'};
const creationSkyKinds = {'light', 'cloud', 'sun', 'moon'};
const creationDayLabels = [
  'Light',
  'Sky',
  'Land, seas and plants',
  'Sun, moon and stars',
  'Fish and birds',
  'Animals and people',
  'A day of rest',
];

class CreationPiece {
  const CreationPiece(this.id, this.kind, this.day, this.label);
  final String id, kind, label;
  final int day;
  String get layer => creationFloorKinds.contains(kind)
      ? 'ground'
      : creationSkyKinds.contains(kind)
      ? 'sky'
      : 'life';
}

class CreationWorldModel {
  CreationWorldModel.fromConfig(Map<String, dynamic> config) {
    final world = Map<String, dynamic>.from(config['world'] as Map);
    rows = world['rows'] as int;
    columns = world['columns'] as int;
    riverStart = world['river_start'] as int;
    riverEnd = world['river_end'] as int;
    totalDays = (world['days'] as List).length;
    pieces = List.unmodifiable(
      (world['pieces'] as List).map((raw) {
        final p = Map<String, dynamic>.from(raw as Map);
        return CreationPiece(
          p['id'] as String,
          p['kind'] as String,
          p['day'] as int,
          p['label'] as String,
        );
      }),
    );
    if (rows < 2 ||
        rows > 6 ||
        columns < 3 ||
        columns > 6 ||
        !{3, 5, 7}.contains(totalDays) ||
        pieces.length > 50 ||
        pieces.map((p) => p.id).toSet().length != pieces.length) {
      throw const FormatException('This Creation world is not ready.');
    }
  }

  late final int rows, columns, riverStart, riverEnd, totalDays;
  late final List<CreationPiece> pieces;
  final Map<String, int> placements = {};
  final List<Map<String, dynamic>> commands = [];
  int completedDays = 0;
  int get currentDay => (completedDays + 1).clamp(1, totalDays);
  bool get complete =>
      completedDays == totalDays && requirements(totalDays).ready;
  bool get canAdvance =>
      completedDays < totalDays && requirements(currentDay).ready;
  List<CreationPiece> get availablePieces =>
      pieces.where((p) => p.day <= currentDay).toList();
  CreationPiece piece(String id) => pieces.firstWhere((p) => p.id == id);

  bool place(String id, int cell) {
    if (commands.length >= 300 || cell < 0 || cell >= rows * columns) {
      return false;
    }
    final p = piece(id);
    if (p.day > currentDay || (p.layer == 'sky' && cell >= columns)) {
      return false;
    }
    if (placements.entries.any(
      (e) => e.key != id && e.value == cell && piece(e.key).layer == p.layer,
    )) {
      return false;
    }
    placements[id] = cell;
    commands.add({'op': 'place', 'piece_id': id, 'cell': cell});
    return true;
  }

  bool remove(String id) {
    if (commands.length >= 300 || !placements.containsKey(id)) return false;
    placements.remove(id);
    commands.add({'op': 'remove', 'piece_id': id});
    return true;
  }

  bool advanceDay() {
    if (commands.length >= 300 || !canAdvance) return false;
    commands.add({'op': 'advance', 'day': currentDay});
    completedDays++;
    return true;
  }

  Map<String, dynamic> submission(int elapsedSeconds) => {
    'commands': commands.map((c) => Map<String, dynamic>.from(c)).toList(),
    'elapsed_seconds': elapsedSeconds.clamp(0, 1800),
  };

  List<int> neighbors(int cell) {
    final row = cell ~/ columns, col = cell % columns;
    return [
      if (row > 0) cell - columns,
      if (row + 1 < rows) cell + columns,
      if (col > 0) cell - 1,
      if (col + 1 < columns) cell + 1,
    ];
  }

  Set<int> connected(int start, Set<int> allowed) {
    if (!allowed.contains(start)) return {};
    final visited = <int>{start}, queue = Queue<int>()..add(start);
    while (queue.isNotEmpty) {
      for (final cell in neighbors(queue.removeFirst())) {
        if (allowed.contains(cell) && visited.add(cell)) queue.add(cell);
      }
    }
    return visited;
  }

  Map<int, String> get floors => {
    for (final e in placements.entries)
      if (piece(e.key).layer == 'ground') e.value: piece(e.key).kind,
  };

  CreationRequirements requirements(int day) {
    final terrain = floors;
    final water = terrain.entries
        .where((e) => e.value == 'water')
        .map((e) => e.key)
        .toSet();
    final land = terrain.entries
        .where((e) => e.value == 'land')
        .map((e) => e.key)
        .toSet();
    final river = connected(riverStart, water);
    final meadow = land.isEmpty
        ? <int>{}
        : connected(land.reduce((a, b) => a < b ? a : b), land);
    final allPieces = pieces
        .where((p) => p.day <= day)
        .every((p) => placements.containsKey(p.id));
    final riverConnected = river.contains(riverEnd);
    final meadowConnected = land.length >= 4 && meadow.length == land.length;
    bool fishSafe = true, birdsSafe = true, animalsSafe = true;
    for (final e in placements.entries) {
      switch (piece(e.key).kind) {
        case 'fish':
          if (!river.contains(e.value)) fishSafe = false;
        case 'bird':
          if (terrain[e.value] != 'forest') birdsSafe = false;
        case 'goat':
        case 'rabbit':
          if (!meadow.contains(e.value)) animalsSafe = false;
      }
    }
    final ready =
        allPieces &&
        (day < 3 || (riverConnected && meadowConnected)) &&
        (day < 5 || (fishSafe && birdsSafe)) &&
        (day < 6 || animalsSafe);
    return CreationRequirements(
      ready,
      allPieces,
      riverConnected,
      meadowConnected,
      fishSafe,
      birdsSafe,
      animalsSafe,
      river,
      meadow,
    );
  }

  /// A reversible walk through adjacent habitat cells; creatures never cut
  /// across forests or swim across dry tiles when the landscape changes.
  List<int> creaturePath(CreationPiece p) {
    final start = placements[p.id];
    if (start == null) return [];
    final facts = requirements(totalDays);
    final allowed = p.kind == 'fish' ? facts.riverCells : facts.meadowCells;
    if (p.kind == 'bird') {
      if (floors[start] != 'forest') {
        return [start];
      }
      final perches = floors.entries
          .where((e) => e.value == 'forest')
          .map((e) => e.key)
          .toList();
      return [start, ...perches.where((cell) => cell != start), start];
    }
    if (!allowed.contains(start) ||
        (p.kind == 'fish' && !facts.riverConnected) ||
        (p.kind != 'fish' && !facts.meadowConnected)) {
      return [start];
    }
    final previous = <int, int?>{start: null}, queue = Queue<int>()..add(start);
    var end = start;
    while (queue.isNotEmpty) {
      end = queue.removeFirst();
      for (final next in neighbors(end)) {
        if (allowed.contains(next) && !previous.containsKey(next)) {
          previous[next] = end;
          queue.add(next);
        }
      }
    }
    final path = <int>[];
    int? cursor = end;
    while (cursor != null) {
      path.insert(0, cursor);
      cursor = previous[cursor];
    }
    return [...path, ...path.reversed.skip(1)];
  }
}

class CreationRequirements {
  const CreationRequirements(
    this.ready,
    this.allPieces,
    this.riverConnected,
    this.meadowConnected,
    this.fishSafe,
    this.birdsSafe,
    this.animalsSafe,
    this.riverCells,
    this.meadowCells,
  );
  final bool ready,
      allPieces,
      riverConnected,
      meadowConnected,
      fishSafe,
      birdsSafe,
      animalsSafe;
  final Set<int> riverCells, meadowCells;
}

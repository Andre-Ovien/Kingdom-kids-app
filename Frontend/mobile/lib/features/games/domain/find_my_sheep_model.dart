/// The client records attempts. The server replays these against its own round.
class SheepFamily {
  const SheepFamily({
    required this.id,
    required this.matchKey,
    required this.capacity,
  });

  final String id;
  final String matchKey;
  final int capacity;
}

class LostLamb {
  const LostLamb({required this.id, required this.matchKey});

  final String id;
  final String matchKey;
}

enum SheepPlacement { correct, wrong, ignored }

class SheepReunionRun {
  SheepReunionRun(Map<String, dynamic> config)
    : families = _families(config['targets']),
      lambs = _lambs(config['items']) {
    const colors = {'coral', 'teal', 'gold', 'forest', 'sky', 'lilac'};
    const patterns = {'dots', 'stripes', 'zigzag'};
    bool validKey(String value) {
      final parts = value.split('_');
      return parts.length == 2 &&
          colors.contains(parts[0]) &&
          patterns.contains(parts[1]);
    }

    if (config['mode'] != 'sheep_reunion' ||
        families.length != 3 ||
        lambs.length != 6 ||
        families.map((f) => f.id).toSet().length != 3 ||
        families.map((f) => f.matchKey).toSet().length != 3 ||
        lambs.map((l) => l.id).toSet().length != 6 ||
        families.any(
          (f) =>
              f.id.isEmpty ||
              !validKey(f.matchKey) ||
              f.capacity != 2 ||
              lambs.where((l) => l.matchKey == f.matchKey).length != f.capacity,
        ) ||
        lambs.any((l) => l.id.isEmpty || !validKey(l.matchKey))) {
      throw const FormatException('This meadow needs three matching families.');
    }
  }

  final List<SheepFamily> families;
  final List<LostLamb> lambs;
  final Map<String, String> _placed = {};
  final List<Map<String, String>> _actions = [];

  int get matched => _placed.length;
  bool get isComplete => matched == lambs.length;
  bool get exhausted => _actions.length >= 120;
  bool isPlaced(String itemId) => _placed.containsKey(itemId);
  String? familyFor(String itemId) => _placed[itemId];
  int countFor(String familyId) =>
      _placed.values.where((value) => value == familyId).length;
  List<Map<String, String>> get actions => List.unmodifiable(
    _actions.map((action) => Map<String, String>.unmodifiable(action)),
  );

  SheepPlacement place(String itemId, String targetId) {
    if (isComplete || exhausted || isPlaced(itemId)) {
      return SheepPlacement.ignored;
    }
    final lamb = lambs.where((l) => l.id == itemId).firstOrNull;
    final family = families.where((f) => f.id == targetId).firstOrNull;
    if (lamb == null ||
        family == null ||
        countFor(targetId) >= family.capacity) {
      return SheepPlacement.ignored;
    }
    _actions.add({'item_id': itemId, 'target_id': targetId});
    if (lamb.matchKey != family.matchKey) return SheepPlacement.wrong;
    _placed[itemId] = targetId;
    return SheepPlacement.correct;
  }

  Map<String, dynamic> get result => {'actions': actions};

  static List<SheepFamily> _families(Object? value) {
    if (value is! List || value.any((row) => row is! Map)) return const [];
    return List.unmodifiable(
      value.cast<Map>().map((row) {
        return SheepFamily(
          id: row['id'] is String ? row['id'] as String : '',
          matchKey: row['match_key'] is String
              ? row['match_key'] as String
              : '',
          capacity: row['capacity'] is int ? row['capacity'] as int : 0,
        );
      }),
    );
  }

  static List<LostLamb> _lambs(Object? value) {
    if (value is! List || value.any((row) => row is! Map)) return const [];
    return List.unmodifiable(
      value.cast<Map>().map((row) {
        return LostLamb(
          id: row['id'] is String ? row['id'] as String : '',
          matchKey: row['match_key'] is String
              ? row['match_key'] as String
              : '',
        );
      }),
    );
  }
}

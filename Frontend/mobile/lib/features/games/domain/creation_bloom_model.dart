/// Ordered matching attempts are replayed by the server; the client never
/// supplies a score or a trusted completion flag.
class BloomTarget {
  const BloomTarget({
    required this.id,
    required this.matchKey,
    required this.capacity,
  });

  final String id;
  final String matchKey;
  final int capacity;
}

class BloomItem {
  const BloomItem({required this.id, required this.matchKey});

  final String id;
  final String matchKey;
}

enum BloomPlacement { correct, wrong, ignored }

class CreationBloomRun {
  CreationBloomRun(Map<String, dynamic> config)
    : targets = _targets(config['targets']),
      items = _items(config['items']) {
    const habitats = {'sky', 'water', 'forest', 'meadow'};
    const pieces = {'sun', 'bird', 'fish', 'tree', 'flower', 'deer'};
    final validId = RegExp(r'^[a-z][a-z0-9_\-]{0,63}$');
    if (config['mode'] != 'creation_bloom' ||
        config['scene'] != 'creation_garden' ||
        targets.length != 4 ||
        targets.map((target) => target.id).toSet().length != 4 ||
        targets.any(
          (target) =>
              !habitats.contains(target.id) ||
              target.matchKey != target.id ||
              target.capacity < 1 ||
              target.capacity > 6,
        ) ||
        items.length != 6 ||
        items.map((item) => item.id).toSet().length != 6 ||
        items.any(
          (item) =>
              !validId.hasMatch(item.id) ||
              !pieces.contains(item.id) ||
              !habitats.contains(item.matchKey),
        ) ||
        targets.any(
          (target) =>
              items.where((item) => item.matchKey == target.matchKey).length !=
              target.capacity,
        )) {
      throw const FormatException(
        'The garden needs six pieces and four homes.',
      );
    }
  }

  final List<BloomTarget> targets;
  final List<BloomItem> items;
  final Map<String, String> _placed = {};
  final List<Map<String, String>> _actions = [];

  int get matched => _placed.length;
  bool get isComplete => matched == items.length;
  bool get exhausted => _actions.length >= 120;
  bool isUsed(String itemId) => _placed.containsKey(itemId);
  List<BloomItem> itemsIn(String targetId) =>
      List.unmodifiable(items.where((item) => _placed[item.id] == targetId));
  List<Map<String, String>> get actions => List.unmodifiable(
    _actions.map((action) => Map<String, String>.unmodifiable(action)),
  );

  BloomPlacement place(String itemId, String targetId) {
    if (isComplete || exhausted || isUsed(itemId)) {
      return BloomPlacement.ignored;
    }
    final item = items.where((piece) => piece.id == itemId).firstOrNull;
    final target = targets.where((home) => home.id == targetId).firstOrNull;
    if (item == null || target == null) return BloomPlacement.ignored;
    _actions.add({'item_id': itemId, 'target_id': targetId});
    if (item.matchKey != target.matchKey ||
        itemsIn(targetId).length >= target.capacity) {
      return BloomPlacement.wrong;
    }
    _placed[itemId] = targetId;
    return BloomPlacement.correct;
  }

  Map<String, dynamic> get result => {'actions': actions};

  static List<BloomTarget> _targets(Object? raw) {
    if (raw is! List || raw.any((row) => row is! Map)) return const [];
    return List.unmodifiable(
      raw.cast<Map>().map(
        (row) => BloomTarget(
          id: row['id'] is String ? row['id'] as String : '',
          matchKey: row['match_key'] is String
              ? row['match_key'] as String
              : '',
          capacity: row['capacity'] is int ? row['capacity'] as int : 0,
        ),
      ),
    );
  }

  static List<BloomItem> _items(Object? raw) {
    if (raw is! List || raw.any((row) => row is! Map)) return const [];
    return List.unmodifiable(
      raw.cast<Map>().map(
        (row) => BloomItem(
          id: row['id'] is String ? row['id'] as String : '',
          matchKey: row['match_key'] is String
              ? row['match_key'] as String
              : '',
        ),
      ),
    );
  }
}

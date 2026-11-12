/// A banquet is replayed from placement attempts by the server. The client never
/// submits a claimed score or completed flag.
class EstherServingItem {
  const EstherServingItem({required this.id, required this.matchKey});

  final String id;
  final String matchKey;
}

class EstherPlaceSetting {
  const EstherPlaceSetting({
    required this.id,
    required this.matchKey,
    required this.capacity,
  });

  final String id;
  final String matchKey;
  final int capacity;
}

enum EstherPlacement { correct, wrong, ignored }

class EstherTableRun {
  EstherTableRun(Map<String, dynamic> config)
    : items = _items(config['items']),
      targets = _targets(config['targets']) {
    const foods = {'bread', 'grapes', 'figs', 'water', 'flowers', 'dates'};
    final seats = {for (var i = 1; i <= 6; i++) 'seat_$i'};
    if (config['mode'] != 'esther_table' ||
        config['scene'] != 'esther_banquet' ||
        config['round_number'] is! int ||
        !{1, 2, 3}.contains(config['round_number']) ||
        items.length != 6 ||
        targets.length != 6 ||
        items.map((item) => item.id).toSet().length != 6 ||
        items.any(
          (item) => item.id.isEmpty || !foods.contains(item.matchKey),
        ) ||
        targets.map((target) => target.id).toSet().length != 6 ||
        targets.any(
          (target) =>
              !seats.contains(target.id) ||
              target.capacity != 1 ||
              !foods.contains(target.matchKey),
        ) ||
        targets.any(
          (target) =>
              items.where((item) => item.matchKey == target.matchKey).length !=
              1,
        ) ||
        targets.map((target) => target.matchKey).toSet().length != 6) {
      throw const FormatException('The celebration needs six matching dishes.');
    }
  }

  final List<EstherServingItem> items;
  final List<EstherPlaceSetting> targets;
  final Map<String, String> _placements = {};
  final List<Map<String, String>> _actions = [];

  int get matched => _placements.length;
  bool get isComplete => matched == items.length;
  bool get exhausted => _actions.length >= 120;
  bool isFilled(String targetId) => _placements.containsKey(targetId);
  bool isUsed(String itemId) => _placements.containsValue(itemId);

  List<Map<String, String>> get actions => List.unmodifiable(
    _actions.map((action) => Map<String, String>.unmodifiable(action)),
  );

  EstherPlacement place(String itemId, String targetId) {
    if (isComplete || exhausted || isFilled(targetId) || isUsed(itemId)) {
      return EstherPlacement.ignored;
    }
    final item = items.where((item) => item.id == itemId).firstOrNull;
    final target = targets.where((target) => target.id == targetId).firstOrNull;
    if (item == null || target == null) return EstherPlacement.ignored;
    _actions.add({'item_id': itemId, 'target_id': targetId});
    if (item.matchKey != target.matchKey) return EstherPlacement.wrong;
    _placements[targetId] = itemId;
    return EstherPlacement.correct;
  }

  int get score => isComplete
      ? 70 + (30 * items.length / _actions.length).round()
      : (50 * matched / items.length).round();

  Map<String, dynamic> get result => {'actions': actions};

  static List<EstherServingItem> _items(Object? value) {
    if (value is! List) return const [];
    return List.unmodifiable(
      value.whereType<Map>().map(
        (row) => EstherServingItem(
          id: row['id'] is String ? row['id'] as String : '',
          matchKey: row['match_key'] is String
              ? row['match_key'] as String
              : '',
        ),
      ),
    );
  }

  static List<EstherPlaceSetting> _targets(Object? value) {
    if (value is! List) return const [];
    return List.unmodifiable(
      value.whereType<Map>().map(
        (row) => EstherPlaceSetting(
          id: row['id'] is String ? row['id'] as String : '',
          matchKey: row['match_key'] is String
              ? row['match_key'] as String
              : '',
          capacity: row['capacity'] is int ? row['capacity'] as int : 0,
        ),
      ),
    );
  }
}

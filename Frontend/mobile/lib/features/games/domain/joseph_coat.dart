/// A cloth match compares both its colour and its pattern. The run records
/// attempts rather than a claimed score so the server can replay the game.
class CoatFabric {
  const CoatFabric({
    required this.id,
    required this.color,
    required this.pattern,
  });

  final String id;
  final String color;
  final String pattern;

  bool matches(CoatFabric other) =>
      color == other.color && pattern == other.pattern;
}

enum CoatPlacement { correct, wrong, ignored }

class JosephCoatRun {
  JosephCoatRun(Map<String, dynamic> config)
    : panels = _fabrics(config['panels']),
      swatches = _fabrics(config['swatches']) {
    const panelIds = {
      'left_shoulder',
      'right_shoulder',
      'left_body',
      'right_body',
      'left_hem',
      'right_hem',
    };
    const colors = {'coral', 'gold', 'teal', 'forest', 'sky', 'lilac'};
    const patterns = {'dots', 'stripes', 'zigzag'};
    if (panels.length != 6 ||
        swatches.length != 6 ||
        panels.map((p) => p.id).toSet().difference(panelIds).isNotEmpty ||
        panels.map((p) => p.id).toSet().length != 6 ||
        panels.map((p) => '${p.color}/${p.pattern}').toSet().length != 6 ||
        swatches.map((p) => p.id).toSet().length != 6 ||
        [...panels, ...swatches].any(
          (p) => !colors.contains(p.color) || !patterns.contains(p.pattern),
        ) ||
        panels.any((p) => swatches.where(p.matches).length != 1)) {
      throw const FormatException('The coat needs six matching cloth patches.');
    }
  }

  final List<CoatFabric> panels;
  final List<CoatFabric> swatches;
  final Map<String, String> _placed = {};
  final List<Map<String, String>> _actions = [];

  int get matched => _placed.length;
  bool get isComplete => matched == panels.length;
  bool get exhausted => _actions.length >= 120;
  bool isPlaced(String panelId) => _placed.containsKey(panelId);
  bool isUsed(String swatchId) => _placed.containsValue(swatchId);
  List<Map<String, String>> get actions => List.unmodifiable(
    _actions.map((a) => Map<String, String>.unmodifiable(a)),
  );

  CoatPlacement place(String panelId, String swatchId) {
    if (isComplete || exhausted || isPlaced(panelId)) {
      return CoatPlacement.ignored;
    }
    final panel = panels.where((p) => p.id == panelId).firstOrNull;
    final swatch = swatches.where((p) => p.id == swatchId).firstOrNull;
    if (panel == null || swatch == null) return CoatPlacement.ignored;
    _actions.add({'panel_id': panelId, 'swatch_id': swatchId});
    if (!panel.matches(swatch)) return CoatPlacement.wrong;
    _placed[panelId] = swatchId;
    return CoatPlacement.correct;
  }

  Map<String, dynamic> get result => {'actions': actions};

  static List<CoatFabric> _fabrics(Object? value) {
    if (value is! List) return const [];
    return List.unmodifiable(
      value.whereType<Map>().map(
        (row) => CoatFabric(
          id: row['id']?.toString() ?? '',
          color: row['color']?.toString() ?? '',
          pattern: row['pattern']?.toString() ?? '',
        ),
      ),
    );
  }
}

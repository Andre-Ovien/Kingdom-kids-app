class BuildersHouse {
  BuildersHouse(this.id, this.label);
  final String id, label;
  String? foundation;
  final List<String> parts = [];
  bool collapsed = false;
}

class WiseBuildersModel {
  WiseBuildersModel.fromConfig(Map<String, dynamic> config) {
    final builders = Map<String, dynamic>.from(config['builders'] as Map);
    requiredParts = List<String>.from(builders['parts'] as List);
    storm = builders['storm'] as String;
    houses = List.unmodifiable(
      (builders['houses'] as List).map((raw) {
        final h = Map<String, dynamic>.from(raw as Map);
        return BuildersHouse(h['id'] as String, h['label'] as String);
      }),
    );
    if (houses.length != 2 ||
        !['rain', 'wind', 'rain_and_wind'].contains(storm) ||
        requiredParts.length < 5 ||
        requiredParts.length > 6) {
      throw const FormatException('The builders round is not ready.');
    }
  }
  late final List<BuildersHouse> houses;
  late final List<String> requiredParts;
  late final String storm;
  final List<Map<String, dynamic>> commands = [];
  final Map<String, bool> stood = {};
  BuildersHouse house(String id) => houses.firstWhere((h) => h.id == id);
  bool get canStorm => houses.every(
    (h) =>
        h.foundation != null &&
        !h.collapsed &&
        h.parts.length == requiredParts.length,
  );
  bool get complete =>
      stood.length == 2 &&
      houses.map((h) => h.foundation).toSet().containsAll(['rock', 'sand']) &&
      stood.values.any((value) => value) &&
      stood.values.any((value) => !value);
  bool foundation(String id, String material) {
    final h = house(id);
    if (commands.length >= 120 ||
        h.parts.isNotEmpty ||
        h.collapsed ||
        !['rock', 'sand'].contains(material)) {
      return false;
    }
    h.foundation = material;
    stood.clear();
    commands.add({'op': 'foundation', 'house_id': id, 'material': material});
    return true;
  }

  bool canPlace(String id, String part) {
    final h = house(id);
    return commands.length < 120 &&
        h.foundation != null &&
        !h.collapsed &&
        requiredParts.contains(part) &&
        !h.parts.contains(part) &&
        (!['roof', 'brace'].contains(part) ||
            h.parts.toSet().containsAll([
              'back-wall',
              'left-wall',
              'right-wall',
              'front-wall',
            ]));
  }

  bool place(String id, String part) {
    if (!canPlace(id, part)) return false;
    house(id).parts.add(part);
    stood.clear();
    commands.add({'op': 'place', 'house_id': id, 'part': part});
    return true;
  }

  bool remove(String id, String part) {
    final h = house(id);
    if (commands.length >= 120 ||
        h.collapsed ||
        !h.parts.contains(part) ||
        (!['roof', 'brace'].contains(part) &&
            h.parts.any((p) => ['roof', 'brace'].contains(p)))) {
      return false;
    }
    h.parts.remove(part);
    stood.clear();
    commands.add({'op': 'remove', 'house_id': id, 'part': part});
    return true;
  }

  bool reset(String id) {
    if (commands.length >= 120) return false;
    final h = house(id);
    h.foundation = null;
    h.parts.clear();
    h.collapsed = false;
    stood.clear();
    commands.add({'op': 'reset', 'house_id': id});
    return true;
  }

  bool testStorm() {
    if (commands.length >= 120 || !canStorm) return false;
    for (final h in houses) {
      stood[h.id] = h.foundation == 'rock';
      h.collapsed = h.foundation != 'rock';
    }
    commands.add({'op': 'storm'});
    return true;
  }

  Map<String, dynamic> submission(int elapsedSeconds) => {
    'commands': commands.map((c) => Map<String, dynamic>.from(c)).toList(),
    'elapsed_seconds': elapsedSeconds.clamp(0, 1800),
  };
}

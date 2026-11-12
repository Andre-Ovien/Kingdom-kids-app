import 'dart:math' as math;

/// The public graph and the fixed-step replay used by the Ark rescue.
/// Coordinates and animal speeds use the same normalized units on the server.
class ArkTrafficPoint {
  const ArkTrafficPoint(this.x, this.y);
  final double x;
  final double y;
  double distanceTo(ArkTrafficPoint other) =>
      math.sqrt(math.pow(x - other.x, 2) + math.pow(y - other.y, 2));
}

class ArkTrafficNode extends ArkTrafficPoint {
  const ArkTrafficNode(this.id, super.x, super.y);
  final String id;
}

class ArkTrafficEdge {
  const ArkTrafficEdge({
    required this.id,
    required this.a,
    required this.b,
    required this.width,
    required this.terrain,
    this.gate,
    this.routeGroup,
  });
  final String id;
  final String a;
  final String b;
  final double width;
  final String terrain;
  final String? gate;
  final String? routeGroup;
  bool joins(String from, String to) =>
      (a == from && b == to) || (a == to && b == from);
  bool accepts(String species) =>
      width + 1e-9 >= ArkTrafficAnimal.radiusFor(species) * 2 &&
      (terrain != 'rocky' || species == 'goat');
}

class ArkTrafficAnimal {
  const ArkTrafficAnimal({
    required this.id,
    required this.species,
    required this.label,
    required this.startNode,
    required this.route,
    this.startProgress = 0,
  });
  final String id;
  final String species;
  final String label;
  final String startNode;
  final List<String> route;
  final double startProgress;
  static double speedFor(String species) => switch (species) {
    'tortoise' => .0028,
    'elephant' => .0046,
    'goat' => .0072,
    'rabbit' => .0105,
    _ => throw const FormatException('Unknown Ark animal.'),
  };
  static double radiusFor(String species) => switch (species) {
    'tortoise' => .022,
    'elephant' => .038,
    'goat' => .024,
    'rabbit' => .018,
    _ => throw const FormatException('Unknown Ark animal.'),
  };
}

class ArkTrafficCourse {
  ArkTrafficCourse._({
    required this.nodes,
    required this.edges,
    required this.animals,
    required this.gates,
    required this.arkNode,
    required this.timeLimitTicks,
    required this.targetJamTicks,
    required this.levelNumber,
    required this.title,
  });
  final Map<String, ArkTrafficNode> nodes;
  final List<ArkTrafficEdge> edges;
  final List<ArkTrafficAnimal> animals;
  final Map<String, bool> gates;
  final String arkNode;
  final int timeLimitTicks;
  final int targetJamTicks;
  final int levelNumber;
  final String title;
  static const tickMilliseconds = 100;
  static const maximumCommands = 240;

  factory ArkTrafficCourse.fromConfig(Map<String, dynamic> config) {
    if (config['mode'] != 'ark_traffic' || config['traffic'] is! Map) {
      throw const FormatException('This round needs an Ark traffic map.');
    }
    final raw = config['traffic'] as Map;
    String id(Object? value) {
      if (value is! String || value.isEmpty || value.length > 64) {
        throw const FormatException('An Ark map ID is invalid.');
      }
      return value;
    }

    double number(Object? value) {
      if (value is! num || !value.isFinite || value < 0 || value > 1) {
        throw const FormatException('An Ark coordinate is invalid.');
      }
      return value.toDouble();
    }

    int integer(Object? value, int minimum, int maximum) {
      if (value is! int || value < minimum || value > maximum) {
        throw const FormatException('An Ark round limit is invalid.');
      }
      return value;
    }

    final rawNodes = raw['nodes'];
    final rawEdges = raw['edges'];
    final rawAnimals = raw['animals'];
    if (rawNodes is! List ||
        rawNodes.length < 2 ||
        rawNodes.length > 48 ||
        rawEdges is! List ||
        rawEdges.length > 80 ||
        rawAnimals is! List ||
        rawAnimals.isEmpty ||
        rawAnimals.length > 20) {
      throw const FormatException('The Ark map is outside its limits.');
    }
    final nodes = <String, ArkTrafficNode>{};
    for (final value in rawNodes) {
      if (value is! Map) throw const FormatException('Invalid Ark junction.');
      final key = id(value['id']);
      if (nodes.containsKey(key)) {
        throw const FormatException('Duplicate junction.');
      }
      nodes[key] = ArkTrafficNode(key, number(value['x']), number(value['y']));
    }
    final gates = <String, bool>{};
    final rawGates = raw['gates'] ?? const [];
    if (rawGates is! List || rawGates.length > 8) {
      throw const FormatException('Invalid Ark gates.');
    }
    for (final value in rawGates) {
      if (value is! Map || value['open'] is! bool) {
        throw const FormatException('Invalid Ark gate.');
      }
      final key = id(value['id']);
      if (gates.containsKey(key)) {
        throw const FormatException('Duplicate gate.');
      }
      gates[key] = value['open'] as bool;
    }
    final edges = <ArkTrafficEdge>[];
    final edgeIds = <String>{};
    for (final value in rawEdges) {
      if (value is! Map) throw const FormatException('Invalid Ark trail.');
      final key = id(value['id']);
      final a = id(value['a']);
      final b = id(value['b']);
      final width = number(value['width']);
      final terrain = value['terrain'];
      final gate = value['gate'];
      if (!edgeIds.add(key) ||
          !nodes.containsKey(a) ||
          !nodes.containsKey(b) ||
          a == b ||
          nodes[a]!.distanceTo(nodes[b]!) <= 1e-9 ||
          width <= 0 ||
          !const ['trail', 'rocky', 'mud'].contains(terrain) ||
          (gate != null && (gate is! String || !gates.containsKey(gate))) ||
          edges.any((edge) => edge.joins(a, b))) {
        throw const FormatException('The Ark trail is invalid.');
      }
      edges.add(
        ArkTrafficEdge(
          id: key,
          a: a,
          b: b,
          width: width,
          terrain: terrain as String,
          gate: gate as String?,
          routeGroup: value['route_group'] as String?,
        ),
      );
    }
    final animals = <ArkTrafficAnimal>[];
    final animalIds = <String>{};
    for (final value in rawAnimals) {
      if (value is! Map) throw const FormatException('Invalid Ark animal.');
      final key = id(value['id']);
      final species = id(value['species']);
      ArkTrafficAnimal.radiusFor(species);
      final start = id(value['start_node']);
      final rawRoute = value['route'] ?? [start];
      if (rawRoute is! List ||
          rawRoute.isEmpty ||
          rawRoute.length > 24 ||
          !animalIds.add(key) ||
          !nodes.containsKey(start)) {
        throw const FormatException('An animal needs a valid starting trail.');
      }
      final route = rawRoute.map(id).toList(growable: false);
      if (route.first != start ||
          route.any((node) => !nodes.containsKey(node))) {
        throw const FormatException('An animal starts outside its trail.');
      }
      if (route.take(route.length - 1).contains(raw['ark_node'])) {
        throw const FormatException('An animal cannot leave the ark.');
      }
      for (var i = 1; i < route.length; i++) {
        final edge = edges.where((edge) => edge.joins(route[i - 1], route[i]));
        if (edge.isEmpty || !edge.first.accepts(species)) {
          throw const FormatException('An animal cannot use this trail.');
        }
      }
      final progress = number(value['start_progress'] ?? 0);
      if (progress >= 1 || (progress > 0 && route.length < 2)) {
        throw const FormatException('Invalid starting progress.');
      }
      animals.add(
        ArkTrafficAnimal(
          id: key,
          species: species,
          label: value['label'] is String ? value['label'] as String : species,
          startNode: start,
          route: List.unmodifiable(route),
          startProgress: progress,
        ),
      );
    }
    final arkNode = id(raw['ark_node']);
    if (!nodes.containsKey(arkNode) || raw['tick_ms'] != tickMilliseconds) {
      throw const FormatException('Invalid Ark destination or clock.');
    }
    return ArkTrafficCourse._(
      nodes: Map.unmodifiable(nodes),
      edges: List.unmodifiable(edges),
      animals: List.unmodifiable(animals),
      gates: Map.unmodifiable(gates),
      arkNode: arkNode,
      timeLimitTicks: integer(raw['time_limit_ticks'], 100, 2400),
      targetJamTicks: integer(raw['target_jam_ticks'], 1, 10000),
      levelNumber: integer(raw['level_number'] ?? 1, 1, 3),
      title: raw['title'] is String ? raw['title'] as String : 'Animal traffic',
    );
  }

  ArkTrafficEdge? edge(String a, String b) {
    for (final edge in edges) {
      if (edge.joins(a, b)) return edge;
    }
    return null;
  }

  ArkTrafficNode? nearestNode(ArkTrafficPoint point, {double within = .09}) {
    ArkTrafficNode? best;
    var distance = within;
    for (final node in nodes.values) {
      final next = node.distanceTo(point);
      if (next <= distance) {
        best = node;
        distance = next;
      }
    }
    return best;
  }
}

class ArkTrafficAnimalState {
  ArkTrafficAnimalState(this.animal)
    : route = List.of(animal.route),
      progress = animal.startProgress;
  final ArkTrafficAnimal animal;
  List<String> route;
  int segment = 0;
  double progress;
  bool waiting = false;
  bool boarded = false;
  bool blocked = false;
  bool movedLastTick = false;
  int walkTicks = 0;
  final Set<String> routeGroups = {};
  String get currentNode => route[segment];
  String get anchor => progress > 1e-9 && segment + 1 < route.length
      ? route[segment + 1]
      : currentNode;
  ArkTrafficPoint position(ArkTrafficCourse course) {
    final a = course.nodes[currentNode]!;
    if (segment + 1 >= route.length) return a;
    final b = course.nodes[route[segment + 1]]!;
    return ArkTrafficPoint(
      a.x + (b.x - a.x) * progress,
      a.y + (b.y - a.y) * progress,
    );
  }

  double heading(ArkTrafficCourse course) {
    if (segment + 1 >= route.length) return -math.pi / 2;
    final a = course.nodes[currentNode]!;
    final b = course.nodes[route[segment + 1]]!;
    return math.atan2(b.y - a.y, b.x - a.x);
  }
}

/// Input commands, rather than claimed points/completion, form the result.
class ArkTrafficRun {
  ArkTrafficRun(this.course)
    : animals = course.animals.map(ArkTrafficAnimalState.new).toList(),
      gates = Map.of(course.gates);
  final ArkTrafficCourse course;
  final List<ArkTrafficAnimalState> animals;
  final Map<String, bool> gates;
  final List<Map<String, dynamic>> _commands = [];
  int tick = 0;
  int jamTicks = 0;
  bool started = false;
  bool paused = false;
  bool get complete => animals.every((animal) => animal.boarded);
  bool get timedOut => tick >= course.timeLimitTicks;
  bool get finished => complete || timedOut;
  int get boardedCount => animals.where((animal) => animal.boarded).length;
  bool get canCommand =>
      started &&
      !paused &&
      !finished &&
      _commands.length < ArkTrafficCourse.maximumCommands;
  List<Map<String, dynamic>> get commands => List.unmodifiable(_commands);
  void start() {
    if (!finished) started = true;
  }

  ArkTrafficAnimalState? animal(String id) {
    for (final state in animals) {
      if (state.animal.id == id) return state;
    }
    return null;
  }

  bool setRoute(String id, List<String> nodes) {
    final state = animal(id);
    if (!canCommand ||
        state == null ||
        state.boarded ||
        nodes.isEmpty ||
        nodes.length > 24 ||
        nodes.first != state.anchor ||
        nodes.any((id) => !course.nodes.containsKey(id))) {
      return false;
    }
    if (nodes.take(nodes.length - 1).contains(course.arkNode)) return false;
    for (var i = 1; i < nodes.length; i++) {
      final edge = course.edge(nodes[i - 1], nodes[i]);
      if (edge == null || !edge.accepts(state.animal.species)) return false;
    }
    if (state.progress > 1e-9 && state.segment + 1 < state.route.length) {
      state.route = [state.currentNode, ...nodes];
    } else {
      state.route = List.of(nodes);
      state.progress = 0;
    }
    state.segment = 0;
    _commands.add({
      'tick': tick,
      'op': 'route',
      'animal_id': id,
      'nodes': List<String>.of(nodes),
    });
    return true;
  }

  bool setWaiting(String id, bool waiting) {
    final state = animal(id);
    if (!canCommand ||
        state == null ||
        state.boarded ||
        state.waiting == waiting) {
      return false;
    }
    state.waiting = waiting;
    state.blocked = false;
    _commands.add({
      'tick': tick,
      'op': waiting ? 'wait' : 'resume',
      'animal_id': id,
    });
    return true;
  }

  bool toggleGate(String id) {
    if (!canCommand || !gates.containsKey(id)) return false;
    gates[id] = !gates[id]!;
    _commands.add({'tick': tick, 'op': 'gate', 'gate_id': id});
    return true;
  }

  void step() {
    if (!started || paused || finished) return;
    for (final state in animals) {
      state.movedLastTick = false;
      state.blocked = false;
      if (state.boarded ||
          state.waiting ||
          state.segment + 1 >= state.route.length) {
        continue;
      }
      final from = course.nodes[state.currentNode]!;
      final to = course.nodes[state.route[state.segment + 1]]!;
      final edge = course.edge(from.id, to.id)!;
      if (edge.gate != null && !gates[edge.gate]!) {
        state.blocked = true;
        jamTicks += 1;
        continue;
      }
      var speed = ArkTrafficAnimal.speedFor(state.animal.species);
      if (edge.terrain == 'mud') {
        speed *= state.animal.species == 'goat' ? .75 : .45;
      }
      final nextProgress = math.min(
        1.0,
        state.progress + speed / from.distanceTo(to),
      );
      final candidate = ArkTrafficPoint(
        from.x + (to.x - from.x) * nextProgress,
        from.y + (to.y - from.y) * nextProgress,
      );
      final current = state.position(course);
      var blocked = false;
      for (final other in animals) {
        if (identical(state, other) || other.boarded || other.waiting) continue;
        final position = other.position(course);
        final separation =
            (ArkTrafficAnimal.radiusFor(state.animal.species) +
                ArkTrafficAnimal.radiusFor(other.animal.species)) *
            .90;
        final nextDistance = candidate.distanceTo(position);
        if (nextDistance < separation - 1e-9 &&
            nextDistance <= current.distanceTo(position) + 1e-9) {
          blocked = true;
          break;
        }
      }
      if (blocked) {
        state.blocked = true;
        jamTicks += 1;
        continue;
      }
      state.progress = nextProgress;
      state.movedLastTick = true;
      state.walkTicks += 1;
      if (edge.routeGroup != null) state.routeGroups.add(edge.routeGroup!);
      if (nextProgress >= 1 - 1e-9) {
        state.segment += 1;
        state.progress = 0;
        if (state.currentNode == course.arkNode) state.boarded = true;
      }
    }
    tick += 1;
  }

  Map<String, dynamic> get result => {
    'commands': _commands
        .map((command) => Map<String, dynamic>.of(command))
        .toList(),
    'elapsed_ticks': tick,
  };
}

import 'dart:math' as math;

import 'ark_garden_path.dart';

/// Fixed-step contract shared with apps.games.ark_garden. No art is required
/// to validate paths or replay taps; reviewed renders are a separate gate.
const arkGardenSpecies = <String>{
  'elephant',
  'lion',
  'giraffe',
  'zebra',
  'dove',
  'sheep',
  'camel',
  'donkey',
  'deer',
  'rabbit',
};

enum ArkGardenPathPhase { garden, stairs, door, interior }

enum ArkGardenAnimalPhase { idle, walking, climbing, entering, boarded }

class ArkGardenPoint {
  const ArkGardenPoint(this.x, this.y, this.z);
  final double x;
  final double y;
  final double z;

  double distanceTo(ArkGardenPoint other) => math.sqrt(
    math.pow(x - other.x, 2) +
        math.pow(y - other.y, 2) +
        math.pow(z - other.z, 2),
  );

  ArkGardenPoint lerp(ArkGardenPoint other, double amount) => ArkGardenPoint(
    x + (other.x - x) * amount,
    y + (other.y - y) * amount,
    z + (other.z - z) * amount,
  );
}

class ArkGardenWaypoint extends ArkGardenPoint {
  const ArkGardenWaypoint(super.x, super.y, super.z, this.phase);
  final ArkGardenPathPhase phase;
}

class ArkGardenAnimal {
  ArkGardenAnimal._({
    required this.id,
    required this.species,
    required this.label,
    required this.speedUnitsPerSecond,
    required this.bodyLengthUnits,
    required this.bodyWidthUnits,
    required this.bodyRearUnits,
    required this.curved,
    required this.queueGateDistance,
    required List<ArkGardenWaypoint> route,
    List<List<ArkGardenPoint>> approachCurves = const [],
  }) : route = List.unmodifiable(route),
       path = ArkGardenPath(route, approachCurves);
  final String id;
  final String species;
  final String label;
  final double speedUnitsPerSecond;
  final double bodyLengthUnits;
  final double bodyWidthUnits;
  final double bodyRearUnits;
  final bool curved;
  final double queueGateDistance;
  final List<ArkGardenWaypoint> route;
  final ArkGardenPath path;

  double get distance => path.length;
}

class ArkGardenCourse {
  ArkGardenCourse._({
    required this.timeLimitTicks,
    required this.version,
    required this.worldWidth,
    required this.worldHeight,
    required this.groundYScale,
    required this.elevationYScale,
    required List<ArkGardenAnimal> animals,
  }) : animals = List.unmodifiable(animals);
  static const tickMilliseconds = 100;
  static const maximumTaps = 100;
  final int timeLimitTicks;
  final int version;
  final double worldWidth;
  final double worldHeight;
  final double groundYScale;
  final double elevationYScale;
  final List<ArkGardenAnimal> animals;

  factory ArkGardenCourse.fromConfig(Map<String, dynamic> config) {
    _object(config, {'mode', 'garden'}, 'Ark garden config');
    if (config['mode'] != 'ark_garden') {
      throw const FormatException('This level needs an Ark garden course.');
    }
    final raw = _object(config['garden'], {
      'version',
      'tick_ms',
      'time_limit_ticks',
      'world',
      'projection',
      'animals',
    }, 'garden');
    final version = _integer(raw['version'], 1, 2, 'version');
    _integer(raw['tick_ms'], tickMilliseconds, tickMilliseconds, 'clock');
    final limit = _integer(
      raw['time_limit_ticks'],
      100,
      version == 1 ? 1800 : 6000,
      'time limit',
    );
    final world = _object(raw['world'], {'width', 'height'}, 'world');
    final width = _number(world['width'], 1, 100, 'world width');
    final height = _number(world['height'], 1, 100, 'world height');
    final projection = _object(raw['projection'], {
      'ground_y_scale',
      'elevation_y_scale',
    }, 'projection');
    final groundScale = _number(
      projection['ground_y_scale'],
      .01,
      4,
      'ground projection',
    );
    final elevationScale = _number(
      projection['elevation_y_scale'],
      .01,
      4,
      'elevation projection',
    );
    final rawAnimals = raw['animals'];
    if (rawAnimals is! List || rawAnimals.length != arkGardenSpecies.length) {
      throw const FormatException('A garden round needs exactly ten animals.');
    }
    final animals = <ArkGardenAnimal>[];
    final ids = <String>{};
    final species = <String>{};
    for (final value in rawAnimals) {
      final item = _object(value, {
        'id',
        'species',
        'label',
        'speed_units_per_second',
        'body_length_units',
        'route',
        if (version == 2) 'approach_curves',
        if (version == 2) 'body_width_units',
        if (version == 2) 'body_rear_units',
        if (version == 2) 'queue_gate_distance_units',
      }, 'animal');
      final id = _identifier(item['id'], 'animal ID');
      final kind = _identifier(item['species'], 'species');
      final label = item['label'];
      if (!ids.add(id) ||
          !arkGardenSpecies.contains(kind) ||
          !species.add(kind)) {
        throw const FormatException('Each garden species and ID appears once.');
      }
      if (label is! String || label.trim().isEmpty || label.length > 80) {
        throw const FormatException('An animal needs a short label.');
      }
      final speed = _number(item['speed_units_per_second'], .05, 10, 'speed');
      final body = _number(item['body_length_units'], .1, 10, 'body length');
      final bodyWidth = version == 2
          ? _number(item['body_width_units'], .1, 10, 'body width')
          : body * .4;
      final bodyRear = version == 2
          ? _number(item['body_rear_units'], 0, body, 'body rear extent')
          : body / 2;
      final rawRoute = item['route'];
      if (rawRoute is! List || rawRoute.length < 5 || rawRoute.length > 32) {
        throw const FormatException(
          'An animal needs a bounded boarding route.',
        );
      }
      final route = <ArkGardenWaypoint>[];
      for (final point in rawRoute) {
        final waypoint = _object(point, {'x', 'y', 'z', 'phase'}, 'waypoint');
        final phase = ArkGardenPathPhase.values
            .where((phase) => phase.name == waypoint['phase'])
            .firstOrNull;
        if (phase == null) {
          throw const FormatException('Unknown boarding path phase.');
        }
        route.add(
          ArkGardenWaypoint(
            _number(waypoint['x'], 0, width, 'waypoint x'),
            _number(waypoint['y'], 0, height, 'waypoint y'),
            _number(waypoint['z'], 0, 20, 'waypoint z'),
            phase,
          ),
        );
      }
      _validateRoute(route, version == 2 ? bodyRear + .08 : body);
      final curves = version == 2
          ? _parseCurves(item['approach_curves'], route, width, height)
          : <List<ArkGardenPoint>>[];
      final path = ArkGardenPath(route, curves)..validateJoins();
      final distance = path.length;
      final queueGate = version == 2
          ? _number(
              item['queue_gate_distance_units'],
              0,
              math.max(0.0, path.approachLength - (body - bodyRear) - .06),
              'queue gate distance',
            )
          : 0.0;
      if ((distance / (speed * .1) - 1e-9).ceil() > limit) {
        throw const FormatException(
          'Every animal must be able to board in time.',
        );
      }
      animals.add(
        ArkGardenAnimal._(
          id: id,
          species: kind,
          label: label,
          speedUnitsPerSecond: speed,
          bodyLengthUnits: body,
          bodyWidthUnits: bodyWidth,
          bodyRearUnits: bodyRear,
          curved: version == 2,
          queueGateDistance: queueGate,
          route: route,
          approachCurves: curves,
        ),
      );
    }
    return ArkGardenCourse._(
      timeLimitTicks: limit,
      version: version,
      worldWidth: width,
      worldHeight: height,
      groundYScale: groundScale,
      elevationYScale: elevationScale,
      animals: animals,
    );
  }

  static List<List<ArkGardenPoint>> _parseCurves(
    Object? raw,
    List<ArkGardenWaypoint> route,
    double width,
    double height,
  ) {
    if (raw is! List ||
        raw.isEmpty ||
        raw.length > 4 ||
        route[1].phase != ArkGardenPathPhase.garden ||
        route.skip(2).any((p) => p.phase == ArkGardenPathPhase.garden)) {
      throw const FormatException(
        'Curves need bounded garden approach anchors.',
      );
    }
    final curves = <List<ArkGardenPoint>>[];
    for (final controls in raw) {
      if (controls is! List || controls.length < 3 || controls.length > 8) {
        throw const FormatException('A curve needs three to eight controls.');
      }
      curves.add([
        for (final value in controls) _parseCurvePoint(value, width, height),
      ]);
    }
    if (curves.first.first.distanceTo(route.first) > 1e-9 ||
        curves.last.last.distanceTo(route[1]) > 1e-9) {
      throw const FormatException('Curves must preserve garden route anchors.');
    }
    for (var i = 1; i < curves.length; i++) {
      if (curves[i - 1].last.distanceTo(curves[i].first) > 1e-9) {
        throw const FormatException('Garden curves must share their junction.');
      }
    }
    return curves;
  }

  static ArkGardenPoint _parseCurvePoint(
    Object? raw,
    double width,
    double height,
  ) {
    final point = _object(raw, {'x', 'y', 'z'}, 'curve point');
    return ArkGardenPoint(
      _number(point['x'], 0, width, 'curve x'),
      _number(point['y'], 0, height, 'curve y'),
      _number(point['z'], 0, 0, 'curve z'),
    );
  }

  static void _validateRoute(List<ArkGardenWaypoint> route, double body) {
    final stairs = route
        .where((p) => p.phase == ArkGardenPathPhase.stairs)
        .toList();
    final doors = route
        .where((p) => p.phase == ArkGardenPathPhase.door)
        .toList();
    if (route.first.phase != ArkGardenPathPhase.garden ||
        route.first.z != 0 ||
        stairs.length < 2 ||
        doors.length != 1 ||
        route.last.phase != ArkGardenPathPhase.interior ||
        route.where((p) => p.phase == ArkGardenPathPhase.interior).length !=
            1) {
      throw const FormatException(
        'Routes need garden, rising stairs, door, interior.',
      );
    }
    for (var i = 1; i < route.length; i++) {
      final previous = route[i - 1];
      final current = route[i];
      if (current.phase.index < previous.phase.index ||
          previous.distanceTo(current) < .001) {
        throw const FormatException(
          'Route phases must advance along distinct points.',
        );
      }
    }
    for (var i = 1; i < stairs.length; i++) {
      if (stairs[i].z <= stairs[i - 1].z) {
        throw const FormatException('Successive stair waypoints must rise.');
      }
    }
    if ((doors.single.z - stairs.last.z).abs() > 1e-9 ||
        (route.last.z - doors.single.z).abs() > 1e-9 ||
        doors.single.distanceTo(route.last) + 1e-9 < body) {
      throw const FormatException(
        'The route must climb and end fully inside the Ark.',
      );
    }
  }
}

class ArkGardenAnimalState {
  ArkGardenAnimalState(this.animal);
  final ArkGardenAnimal animal;
  int? tappedAtTick;
  int segment = 0;
  double progress = 0;
  bool boarded = false;
  int walkTicks = 0;
  double distanceTravelled = 0;
  bool waiting = false;
  int? _actualArrivalTick;
  int get travelTicks =>
      (animal.distance / (animal.speedUnitsPerSecond * .1) - 1e-9).ceil();
  int? get arrivalTick => animal.curved
      ? _actualArrivalTick
      : tappedAtTick == null
      ? null
      : tappedAtTick! + travelTicks;

  ArkGardenPoint get position {
    if (boarded) return animal.route.last;
    return pathFrame.position;
  }

  double get heading {
    if (boarded) return 0;
    return pathFrame.heading;
  }

  ArkGardenAnimalPhase get phase {
    if (boarded) return ArkGardenAnimalPhase.boarded;
    if (tappedAtTick == null) return ArkGardenAnimalPhase.idle;
    if (pathPhase == ArkGardenPathPhase.door ||
        pathPhase == ArkGardenPathPhase.interior) {
      return ArkGardenAnimalPhase.entering;
    }
    if (pathPhase == ArkGardenPathPhase.stairs) {
      return ArkGardenAnimalPhase.climbing;
    }
    return ArkGardenAnimalPhase.walking;
  }

  ArkGardenPathPhase get pathPhase =>
      boarded ? ArkGardenPathPhase.interior : pathFrame.phase;

  ArkGardenPathFrame get pathFrame => animal.path.sample(distanceTravelled);

  ArkGardenPathFrame sampleAt(double ticks) =>
      animal.path.sample(math.max(0, ticks) * animal.speedUnitsPerSecond * .1);

  void _advanceToTick(int tick) {
    if (tappedAtTick == null || boarded) return;
    walkTicks = tick - tappedAtTick!;
    distanceTravelled = math.min(
      animal.distance,
      walkTicks * animal.speedUnitsPerSecond * .1,
    );
    if (arrivalTick! <= tick) {
      boarded = true;
      segment = animal.route.length - 1;
      progress = 0;
      return;
    }
  }
}

/// Only first-tap timestamps are recorded. The server repeats the same movement.
class ArkGardenRun {
  ArkGardenRun(this.course)
    : animals = course.animals.map(ArkGardenAnimalState.new).toList();
  final ArkGardenCourse course;
  final List<ArkGardenAnimalState> animals;
  final List<Map<String, dynamic>> _taps = [];
  int tick = 0;
  ArkGardenAnimalState? _corridorOwner;
  bool started = false;
  bool paused = false;
  bool get complete => animals.every((animal) => animal.boarded);
  bool get timedOut => tick >= course.timeLimitTicks;
  bool get finished => complete || timedOut;
  int get boardedCount => animals.where((animal) => animal.boarded).length;
  bool get canTap => started && !paused && !finished;

  ArkGardenAnimalState? animal(String id) =>
      animals.where((animal) => animal.animal.id == id).firstOrNull;

  void start() {
    if (!finished) started = true;
  }

  bool tap(String id) {
    final state = animal(id);
    if (!canTap || state == null || state.tappedAtTick != null) return false;
    state.tappedAtTick = tick;
    _taps.add({'tick': tick, 'animal_id': id});
    return true;
  }

  void step() {
    if (!started || paused || finished) return;
    if (course.version == 2) {
      _stepQueue();
      tick += 1;
      return;
    }
    for (final state in animals) {
      if (state.tappedAtTick == null || state.boarded) continue;
      state._advanceToTick(tick + 1);
    }
    tick += 1;
  }

  void _stepQueue() {
    if (_corridorOwner?.boarded == true) _corridorOwner = null;
    final rectangles = <String, _GardenRectangle>{
      for (final state in animals)
        if (!state.boarded)
          state.animal.id: _GardenRectangle(state.pathFrame, state.animal),
    };
    final priority =
        animals.where((state) => state.tappedAtTick != null).toList()
          ..sort((a, b) {
            final taps = a.tappedAtTick!.compareTo(b.tappedAtTick!);
            return taps != 0
                ? taps
                : animals.indexOf(a).compareTo(animals.indexOf(b));
          });
    for (final state in priority) {
      if (state.boarded) continue;
      final animal = state.animal;
      final before = state.distanceTravelled;
      final gate = animal.queueGateDistance;
      var desired = math.min(
        animal.distance,
        before + animal.speedUnitsPerSecond * .1,
      );
      if (_corridorOwner != null && _corridorOwner != state) {
        desired = math.min(desired, gate);
      }
      while (desired - state.distanceTravelled > 1e-9) {
        final next = math.min(desired, state.distanceTravelled + .05);
        final frame = animal.path.sample(next);
        final rectangle = _GardenRectangle(frame, animal);
        if (rectangles.entries.any(
          (entry) => entry.key != animal.id && rectangle.overlaps(entry.value),
        )) {
          break;
        }
        if (next > gate + 1e-9) {
          if (_corridorOwner != null && _corridorOwner != state) break;
          _corridorOwner = state;
        }
        state.distanceTravelled = next;
        rectangles[animal.id] = rectangle;
      }
      state.waiting = state.distanceTravelled - before <= 1e-9;
      state.walkTicks =
          (state.distanceTravelled / (animal.speedUnitsPerSecond * .1)).floor();
      if (state.distanceTravelled + 1e-9 >= animal.distance) {
        state.distanceTravelled = animal.distance;
        state.boarded = true;
        state._actualArrivalTick = tick + 1;
        rectangles.remove(animal.id);
        if (_corridorOwner == state) _corridorOwner = null;
      }
    }
  }

  Map<String, dynamic> get result => {
    'taps': _taps.map((tap) => Map<String, dynamic>.of(tap)).toList(),
    'elapsed_ticks': tick,
  };
}

class _GardenRectangle {
  _GardenRectangle(ArkGardenPathFrame frame, ArkGardenAnimal animal) {
    final forward = (math.cos(frame.heading), math.sin(frame.heading));
    final side = (-forward.$2, forward.$1);
    axes = [forward, side];
    final front = animal.bodyLengthUnits - animal.bodyRearUnits + .06;
    final rear = animal.bodyRearUnits + .06;
    final halfWidth = animal.bodyWidthUnits / 2 + .06;
    corners = [
      for (final a in [-rear, front])
        for (final b in [-1, 1])
          (
            frame.position.x + a * forward.$1 + b * side.$1 * halfWidth,
            frame.position.y + a * forward.$2 + b * side.$2 * halfWidth,
          ),
    ];
  }
  late final List<(double, double)> axes;
  late final List<(double, double)> corners;
  bool overlaps(_GardenRectangle other) {
    for (final axis in [...axes, ...other.axes]) {
      final first = corners
          .map((c) => c.$1 * axis.$1 + c.$2 * axis.$2)
          .toList();
      final second = other.corners
          .map((c) => c.$1 * axis.$1 + c.$2 * axis.$2)
          .toList();
      if (first.reduce(math.max) <= second.reduce(math.min) + 1e-9 ||
          second.reduce(math.max) <= first.reduce(math.min) + 1e-9) {
        return false;
      }
    }
    return true;
  }
}

Map _object(Object? value, Set<String> fields, String label) {
  if (value is! Map ||
      value.keys.toSet().difference(fields).isNotEmpty ||
      !value.keys.toSet().containsAll(fields)) {
    throw FormatException('$label has missing or unknown fields.');
  }
  return value;
}

int _integer(Object? value, int min, int max, String label) {
  if (value is! int || value < min || value > max) {
    throw FormatException('$label must be an integer from $min to $max.');
  }
  return value;
}

double _number(Object? value, double min, double max, String label) {
  if (value is! num || !value.isFinite || value < min || value > max) {
    throw FormatException('$label must be finite and bounded.');
  }
  return value.toDouble();
}

String _identifier(Object? value, String label) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$').hasMatch(value)) {
    throw FormatException('$label must be a short identifier.');
  }
  return value;
}

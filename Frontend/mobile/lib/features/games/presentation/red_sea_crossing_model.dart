import 'dart:collection';
import 'dart:math' as math;

import '../domain/mini_game.dart';

enum RedSeaCrossingPhase {
  ready,
  parting,
  placing,
  walking,
  complete,
  timedOut,
}

class CrossingTraveller {
  const CrossingTraveller({required this.id, required this.label});
  final String id;
  final String label;
}

class CrossingPoint {
  const CrossingPoint(this.x, this.y);
  final double x;
  final double y;
}

class CrossingDropZone {
  const CrossingDropZone({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    this.polygon = const [],
  });

  final double left;
  final double top;
  final double right;
  final double bottom;
  final List<CrossingPoint> polygon;

  bool contains(double x, double y) {
    if (!x.isFinite || !y.isFinite) return false;
    if (polygon.isEmpty) {
      return x >= left && x <= right && y >= top && y <= bottom;
    }
    var side = 0;
    for (var index = 0; index < polygon.length; index++) {
      final a = polygon[index];
      final b = polygon[(index + 1) % polygon.length];
      final cross = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x);
      if (cross.abs() <= 1e-9) continue;
      final nextSide = cross > 0 ? 1 : -1;
      if (side != 0 && side != nextSide) return false;
      side = nextSide;
    }
    return true;
  }
}

class RedSeaCrossingCourse {
  RedSeaCrossingCourse({
    required this.timeLimitSeconds,
    required List<CrossingTraveller> travellers,
    required this.dropZone,
  }) : travellers = UnmodifiableListView(travellers) {
    if (!timeLimitSeconds.isFinite || timeLimitSeconds <= 0) {
      throw const FormatException('A crossing needs a positive time limit.');
    }
    final ids = travellers.map((person) => person.id).toSet();
    if (travellers.isEmpty ||
        travellers.length > 20 ||
        ids.length != travellers.length ||
        ids.any((id) => id.isEmpty)) {
      throw const FormatException('A crossing needs unique travellers.');
    }
    if (![
          dropZone.left,
          dropZone.top,
          dropZone.right,
          dropZone.bottom,
        ].every((value) => value.isFinite && value >= 0 && value <= 1) ||
        dropZone.left >= dropZone.right ||
        dropZone.top >= dropZone.bottom) {
      throw const FormatException('A crossing needs a valid dry lane.');
    }
    final polygon = dropZone.polygon;
    if (polygon.isNotEmpty) {
      if (polygon.length < 3 ||
          polygon.length > 16 ||
          polygon.any(
            (point) =>
                !point.x.isFinite ||
                !point.y.isFinite ||
                point.x < 0 ||
                point.x > 1 ||
                point.y < 0 ||
                point.y > 1,
          )) {
        throw const FormatException(
          'A crossing needs a valid dry-lane polygon.',
        );
      }
      var winding = 0;
      for (var index = 0; index < polygon.length; index++) {
        final a = polygon[index];
        final b = polygon[(index + 1) % polygon.length];
        if ((a.x - b.x).abs() + (a.y - b.y).abs() <= 1e-9) {
          throw const FormatException('A crossing lane has a repeated edge.');
        }
        for (final point in polygon) {
          final cross =
              (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x);
          if (cross.abs() <= 1e-9) continue;
          final side = cross > 0 ? 1 : -1;
          if (winding != 0 && side != winding) {
            throw const FormatException('A crossing lane must be convex.');
          }
          winding = side;
        }
      }
      if (winding == 0) {
        throw const FormatException('A crossing lane needs a nonzero area.');
      }
    }
  }

  factory RedSeaCrossingCourse.fromLevel(GameLevel level) {
    final raw = level.config['crossing'];
    if (raw is! Map || raw['travellers'] is! List || raw['drop_zone'] is! Map) {
      throw const FormatException('This crossing course is unavailable.');
    }
    final zone = raw['drop_zone'] as Map;
    double number(Object? value) {
      if (value is! num || !value.isFinite) {
        throw const FormatException(
          'A crossing value must be a finite number.',
        );
      }
      return value.toDouble();
    }

    final rawPolygon = zone['polygon'];
    if (zone.containsKey('polygon') &&
        (rawPolygon is! List ||
            rawPolygon.length < 3 ||
            rawPolygon.length > 16)) {
      throw const FormatException('A crossing polygon is invalid.');
    }
    final polygon = <CrossingPoint>[
      if (rawPolygon is List)
        for (final point in rawPolygon)
          if (point is List && point.length == 2)
            CrossingPoint(number(point[0]), number(point[1]))
          else
            throw const FormatException('A crossing polygon point is invalid.'),
    ];

    return RedSeaCrossingCourse(
      timeLimitSeconds: number(raw['time_limit_seconds']),
      travellers: [
        for (final person in raw['travellers'] as List)
          if (person is Map && person['id'] is String)
            CrossingTraveller(
              id: person['id'] as String,
              label: person['label'] is String
                  ? person['label'] as String
                  : 'Traveller',
            )
          else
            throw const FormatException('A crossing traveller is invalid.'),
      ],
      dropZone: CrossingDropZone(
        left: number(zone['left']),
        top: number(zone['top']),
        right: number(zone['right']),
        bottom: number(zone['bottom']),
        polygon: List.unmodifiable(polygon),
      ),
    );
  }

  final double timeLimitSeconds;
  final List<CrossingTraveller> travellers;
  final CrossingDropZone dropZone;
}

class CrossingPlacement {
  CrossingPlacement({
    required this.travellerId,
    required this.x,
    required this.y,
    required this.releasedAtMs,
    required this.walkDuration,
  });
  final String travellerId;
  final double x;
  final double y;
  final int releasedAtMs;
  final double walkDuration;
  double _walkElapsed = 0;
  double get walkProgress => (_walkElapsed / walkDuration).clamp(0, 1);
  bool get safe => walkProgress >= 1;
}

/// The task clock begins after the sea opens and stops at the final drop.
/// Walks keep advancing until everyone reaches the far shore; only then is
/// the success payload available. Intro, final walks and pauses earn no time.
class RedSeaCrossingRun {
  RedSeaCrossingRun(this.course);
  static const partingSeconds = 2.6;
  final RedSeaCrossingCourse course;
  RedSeaCrossingPhase phase = RedSeaCrossingPhase.ready;
  double elapsed = 0;
  double _openingElapsed = 0;
  final _placements = <String, CrossingPlacement>{};
  Map<String, CrossingPlacement> get placements =>
      UnmodifiableMapView(_placements);
  double get openingProgress => (_openingElapsed / partingSeconds).clamp(0, 1);
  double get remainingSeconds => math.max(0, course.timeLimitSeconds - elapsed);
  int get placedCount => _placements.length;
  int get safeCount => _placements.values.where((person) => person.safe).length;
  bool get allPlaced => placedCount == course.travellers.length;
  bool get finished =>
      phase == RedSeaCrossingPhase.complete ||
      phase == RedSeaCrossingPhase.timedOut;
  bool get canPlace => phase == RedSeaCrossingPhase.placing;

  void start() {
    if (phase != RedSeaCrossingPhase.ready) return;
    phase = RedSeaCrossingPhase.parting;
  }

  void advance(double deltaSeconds) {
    if (!deltaSeconds.isFinite || deltaSeconds <= 0 || finished) return;
    var remaining = deltaSeconds.clamp(0, .1);
    if (phase == RedSeaCrossingPhase.parting) {
      final openingStep = math.min(remaining, partingSeconds - _openingElapsed);
      _openingElapsed += openingStep;
      remaining -= openingStep;
      if (_openingElapsed >= partingSeconds - .0000001) {
        _openingElapsed = partingSeconds;
        phase = RedSeaCrossingPhase.placing;
      }
    }
    if (remaining <= .0000001 || phase == RedSeaCrossingPhase.ready) return;
    if (phase == RedSeaCrossingPhase.placing) {
      remaining = math.min(remaining, course.timeLimitSeconds - elapsed);
      elapsed += remaining;
    }
    for (final person in _placements.values) {
      person._walkElapsed = math.min(
        person.walkDuration,
        person._walkElapsed + remaining,
      );
    }
    if (allPlaced && safeCount == course.travellers.length) {
      phase = RedSeaCrossingPhase.complete;
    } else if (phase == RedSeaCrossingPhase.placing &&
        elapsed >= course.timeLimitSeconds - .0000001) {
      elapsed = course.timeLimitSeconds;
      phase = RedSeaCrossingPhase.timedOut;
    }
  }

  bool place(String travellerId, double x, double y) {
    if (!canPlace ||
        _placements.containsKey(travellerId) ||
        !course.dropZone.contains(x, y)) {
      return false;
    }
    final index = course.travellers.indexWhere(
      (person) => person.id == travellerId,
    );
    if (index < 0) return false;
    _placements[travellerId] = CrossingPlacement(
      travellerId: travellerId,
      x: x,
      y: y,
      releasedAtMs: (elapsed * 1000).round(),
      walkDuration: 3.8 + index % 4 * .18,
    );
    if (allPlaced) phase = RedSeaCrossingPhase.walking;
    return true;
  }

  Map<String, dynamic> result() {
    if (!finished) {
      throw StateError('The crossing has not reached its outcome yet.');
    }
    return {
      'crossing': {
        'elapsed_ms': (elapsed * 1000).round().clamp(
          0,
          (course.timeLimitSeconds * 1000).round(),
        ),
        'placements': [
          for (final person in _placements.values)
            {
              'traveller_id': person.travellerId,
              'x': person.x,
              'y': person.y,
              'released_at_ms': person.releasedAtMs,
            },
        ],
      },
    };
  }
}

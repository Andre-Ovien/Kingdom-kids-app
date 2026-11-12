import 'dart:math' as math;

import '../domain/mini_game.dart';

class SailingObstacle {
  const SailingObstacle({
    required this.id,
    required this.progress,
    required this.x,
    required this.radius,
  });
  final String id;
  final double progress;
  final double x;
  final double radius;
}

class SailingCourse {
  const SailingCourse({
    this.durationSeconds = 60,
    this.distanceMetres = 1200,
    this.shipRadius = .09,
    this.collisionWindow = .007,
    this.maxHits = 3,
    this.steerSpeed = 1.4,
    this.obstacles = const [],
  });

  factory SailingCourse.fromLevel(GameLevel level) {
    final raw = Map<String, dynamic>.from(level.config['sailing'] as Map);
    double number(String key, double fallback) =>
        (raw[key] as num?)?.toDouble() ?? fallback;
    return SailingCourse(
      durationSeconds: number('duration_seconds', 60),
      distanceMetres: number('distance_m', 1200),
      shipRadius: number('ship_radius', .09),
      collisionWindow: number('collision_window', .007),
      maxHits: (raw['max_hits'] as num?)?.toInt() ?? 3,
      steerSpeed: number('steer_speed', 1.4),
      obstacles: [
        for (final item in raw['obstacles'] as List? ?? const [])
          SailingObstacle(
            id: item['id'] as String,
            progress: (item['progress'] as num).toDouble(),
            x: (item['x'] as num).toDouble(),
            radius: (item['radius'] as num).toDouble(),
          ),
      ],
    );
  }

  final double durationSeconds;
  final double distanceMetres;
  final double shipRadius;
  final double collisionWindow;
  final int maxHits;
  final double steerSpeed;
  final List<SailingObstacle> obstacles;
}

/// A continuous voyage, with actual steering samples shared with the server.
/// Time advances only through active frames, never through a background pause.
class SailingRun {
  SailingRun(this.course);
  final SailingCourse course;
  double elapsed = 0;
  double x = 0;
  double velocity = 0;
  double lastHitAt = -10;
  bool started = false;
  final Set<String> hitIds = {};
  final List<List<num>> _samples = [];
  int _nextSampleMs = 100;

  int get hits => hitIds.length;
  bool get wrecked => hits >= course.maxHits;
  bool get finished => elapsed >= course.durationSeconds;
  double get progress => (elapsed / course.durationSeconds).clamp(0, 1);
  int get remainingMetres => ((1 - progress) * course.distanceMetres).ceil();
  bool get active => started && !wrecked && !finished;

  void start() {
    elapsed = x = velocity = 0;
    lastHitAt = -10;
    hitIds.clear();
    _samples
      ..clear()
      ..add([0, 0.0]);
    _nextSampleMs = 100;
    started = true;
  }

  void advance(double delta, double steering) {
    if (!active || !delta.isFinite || delta <= 0) return;
    // A stalled frame slows play rather than teleporting past a reef.
    var remaining = delta.clamp(0, .1);
    final target =
        (steering.isFinite ? steering.clamp(-1, 1) : 0) * course.steerSpeed;
    while (remaining > .0000001 && active) {
      final sampleBoundary = _nextSampleMs / 1000;
      final step = math.min(
        remaining,
        math.min(
          1 / 60,
          math.min(sampleBoundary, course.durationSeconds) - elapsed,
        ),
      );
      if (step <= .0000001) {
        elapsed = math.min(sampleBoundary, course.durationSeconds);
        _recordSample();
        continue;
      }
      velocity += (target - velocity) * (1 - math.exp(-step * 10));
      final next = (x + velocity * step).clamp(-.96, .96);
      if (next == x && x.abs() >= .96) velocity = 0;
      x = next;
      elapsed = math.min(course.durationSeconds, elapsed + step);
      remaining -= step;
      if (elapsed >= sampleBoundary - .0000001 || finished) {
        elapsed = math.min(sampleBoundary, course.durationSeconds);
        _recordSample();
      }
    }
  }

  void _recordSample() {
    final milliseconds = (elapsed * 1000).round();
    if (_samples.isEmpty || _samples.last.first != milliseconds) {
      _samples.add([milliseconds, x]);
      for (final obstacle in course.obstacles) {
        if (!hitIds.contains(obstacle.id) &&
            (progress - obstacle.progress).abs() <= course.collisionWindow &&
            (x - obstacle.x).abs() < obstacle.radius + course.shipRadius) {
          hitIds.add(obstacle.id);
          lastHitAt = elapsed;
        }
      }
    }
    _nextSampleMs += 100;
  }

  double positionAgo(double seconds) {
    if (_samples.isEmpty) return x;
    final milliseconds = math.max(0.0, (elapsed - seconds) * 1000);
    final index = math.min((milliseconds / 100).floor(), _samples.length - 1);
    final before = _samples[index];
    final after = index + 1 < _samples.length
        ? _samples[index + 1]
        : [elapsed * 1000, x];
    final interval = after[0] - before[0];
    if (interval <= 0) return before[1].toDouble();
    final fraction = ((milliseconds - before[0]) / interval).clamp(0, 1);
    return (before[1] + (after[1] - before[1]) * fraction).toDouble();
  }

  Map<String, dynamic> result() {
    if (!finished || wrecked) {
      throw StateError('Only a finished safe voyage can be submitted.');
    }
    return {
      'voyage': {
        'duration_ms': (course.durationSeconds * 1000).round(),
        'samples': [for (final sample in _samples) List<num>.of(sample)],
      },
    };
  }
}

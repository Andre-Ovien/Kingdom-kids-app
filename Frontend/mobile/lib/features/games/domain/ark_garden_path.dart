import 'dart:math' as math;

import 'ark_garden_model.dart';

/// Matches the reviewed Three.js kernel and the server's v2 replay exactly.
/// Curves carry the authored geometry; the 256-step arc table only converts
/// travel distance to the curve parameter. It does not replace the curve.
class ArkGardenPath {
  ArkGardenPath(
    List<ArkGardenWaypoint> route, [
    List<List<ArkGardenPoint>> curves = const [],
  ]) {
    var length = 0.0;
    var previous = route.first as ArkGardenPoint;
    for (final controls in curves) {
      final curve = _GardenCurve(controls, length);
      previous = controls.first;
      for (var i = 1; i <= samples; i++) {
        final t = i / samples;
        final point = _bezier(controls, t);
        curve.length += previous.distanceTo(point);
        curve.table.add((t, curve.length));
        previous = point;
      }
      _curves.add(curve);
      length += curve.length;
    }
    approachLength = length;
    for (final point in route.skip(curves.isEmpty ? 1 : 2)) {
      final span = previous.distanceTo(point);
      _lines.add(_GardenLine(previous, point, length, span, point.phase));
      length += span;
      previous = point;
    }
    this.length = length;
  }

  static const samples = 256;
  final List<_GardenCurve> _curves = [];
  final List<_GardenLine> _lines = [];
  late final double approachLength;
  late final double length;

  ArkGardenPathFrame curveAt(int index, double t) {
    final curve = _curves[index];
    final tangent = _bezier(curve.first, t);
    final second = _bezier(curve.second, t);
    final speed = math.sqrt(tangent.x * tangent.x + tangent.y * tangent.y);
    if (speed <= 1e-8) {
      throw const FormatException('Garden curves need nonzero tangents.');
    }
    return ArkGardenPathFrame(
      position: _bezier(curve.points, t),
      heading: math.atan2(tangent.y, tangent.x),
      curvature:
          (tangent.x * second.y - tangent.y * second.x) /
          (speed * speed * speed),
      phase: ArkGardenPathPhase.garden,
    );
  }

  ArkGardenPathFrame sample(double travelled) {
    final at = travelled.clamp(0.0, length);
    if (at < approachLength) {
      final index = _curves.indexWhere((c) => at < c.start + c.length);
      final curve = _curves[index];
      final local = at - curve.start;
      var low = 0;
      var high = curve.table.length - 1;
      while (high - low > 1) {
        final middle = (low + high) ~/ 2;
        if (curve.table[middle].$2 <= local) {
          low = middle;
        } else {
          high = middle;
        }
      }
      final a = curve.table[low];
      final b = curve.table[high];
      final ratio = (local - a.$2) / (b.$2 - a.$2);
      return curveAt(index, a.$1 + (b.$1 - a.$1) * ratio);
    }
    final line =
        _lines.where((l) => at + 1e-9 < l.start + l.length).firstOrNull ??
        _lines.last;
    return ArkGardenPathFrame(
      position: line.from.lerp(
        line.to,
        ((at - line.start) / line.length).clamp(0.0, 1.0),
      ),
      heading: math.atan2(line.to.y - line.from.y, line.to.x - line.from.x),
      curvature: 0,
      phase: line.phase,
    );
  }

  /// Mirrors backend authoring validation; runtime clearance certificates
  /// remain the scene packager's responsibility.
  void validateJoins() {
    for (var index = 0; index < _curves.length; index++) {
      for (final entry in _curves[index].table) {
        curveAt(index, entry.$1);
      }
      if (index > 0) {
        final before = curveAt(index - 1, 1);
        final after = curveAt(index, 0);
        if (_angleDelta(before.heading, after.heading).abs() > 1e-6 ||
            (before.curvature - after.curvature).abs() > 1e-6) {
          throw const FormatException('Garden turns must join smoothly.');
        }
      }
    }
    if (_curves.isEmpty) return;
    final end = curveAt(_curves.length - 1, 1);
    final line = _lines.first;
    final heading = math.atan2(
      line.to.y - line.from.y,
      line.to.x - line.from.x,
    );
    if (_angleDelta(end.heading, heading).abs() > 1e-6 ||
        end.curvature.abs() > 1e-6) {
      throw const FormatException('A turn must straighten before the stairs.');
    }
  }
}

class ArkGardenPathFrame {
  const ArkGardenPathFrame({
    required this.position,
    required this.heading,
    required this.curvature,
    required this.phase,
  });
  final ArkGardenPoint position;
  final double heading;
  final double curvature;
  final ArkGardenPathPhase phase;
}

class _GardenCurve {
  _GardenCurve(this.points, this.start)
    : first = _derivative(points),
      second = _derivative(_derivative(points));
  final List<ArkGardenPoint> points;
  final List<ArkGardenPoint> first;
  final List<ArkGardenPoint> second;
  final double start;
  double length = 0;
  final List<(double, double)> table = [(0, 0)];
}

class _GardenLine {
  const _GardenLine(this.from, this.to, this.start, this.length, this.phase);
  final ArkGardenPoint from;
  final ArkGardenPoint to;
  final double start;
  final double length;
  final ArkGardenPathPhase phase;
}

ArkGardenPoint _bezier(List<ArkGardenPoint> points, double amount) {
  var row = points;
  while (row.length > 1) {
    row = [
      for (var i = 0; i < row.length - 1; i++) row[i].lerp(row[i + 1], amount),
    ];
  }
  return row.single;
}

List<ArkGardenPoint> _derivative(List<ArkGardenPoint> points) => [
  for (var i = 0; i < points.length - 1; i++)
    ArkGardenPoint(
      (points[i + 1].x - points[i].x) * (points.length - 1),
      (points[i + 1].y - points[i].y) * (points.length - 1),
      (points[i + 1].z - points[i].z) * (points.length - 1),
    ),
];

double _angleDelta(double a, double b) =>
    math.atan2(math.sin(a - b), math.cos(a - b));

import 'dart:math' as math;

import 'ark_garden_model.dart';

class ArkGardenScreenPoint {
  const ArkGardenScreenPoint(this.x, this.y);
  final double x;
  final double y;
}

/// Orthographic contract for a wide world. Authoring coordinates use +Y toward
/// the viewer and +Z upward. Final scales come from the reviewed Blender camera.
/// The same transform must position art, feet, shadows, masks and tap targets.
class ArkGardenViewport {
  ArkGardenViewport({
    required this.course,
    required this.width,
    required this.height,
    double pan = 0,
  }) {
    if (!width.isFinite ||
        !height.isFinite ||
        !pan.isFinite ||
        width <= 0 ||
        height <= 0) {
      throw const FormatException(
        'A garden viewport must have positive bounds.',
      );
    }
    panPixels = pan.clamp(0.0, maximumPan);
  }
  final ArkGardenCourse course;
  final double width;
  final double height;
  late final double panPixels;

  double get scale => height / (course.worldHeight * course.groundYScale);
  double get worldPixelWidth => course.worldWidth * scale;
  double get maximumPan => math.max(0, worldPixelWidth - width);

  ArkGardenScreenPoint project(ArkGardenPoint point) => ArkGardenScreenPoint(
    point.x * scale - panPixels,
    (point.y * course.groundYScale - point.z * course.elevationYScale) * scale,
  );

  ArkGardenPoint groundAt(ArkGardenScreenPoint point) => ArkGardenPoint(
    (point.x + panPixels) / scale,
    point.y / (course.groundYScale * scale),
    0,
  );

  double depth(ArkGardenPoint point) => point.y * course.groundYScale;

  ArkGardenViewport pannedBy(double screenDelta) => ArkGardenViewport(
    course: course,
    width: width,
    height: height,
    pan: panPixels - screenDelta,
  );
}

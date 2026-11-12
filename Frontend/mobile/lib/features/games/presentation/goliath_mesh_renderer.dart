import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'goliath_motion_model.dart';

/// Anatomical surface strips share smooth joint bands. The two legs never
/// share triangles, and the shield is a separate rigid UV island. Every UV
/// stays fixed in the original illustration; only the skin vertices move.
class GoliathSkinMesh {
  GoliathSkinMesh() {
    _strip(_rightArm, 6, _anatomyWeights);
    _strip(_leftLeg, 8, _anatomyWeights);
    _strip(_rightLeg, 8, _anatomyWeights);
    _strip(_core, 14, _anatomyWeights);
    _strip(_leftArm, 8, _anatomyWeights);
    for (final region in _rigidRegions) {
      final original = <int>[];
      final reconstructed = <int>[];
      final patch = _sections.length;
      for (final triangle in region.triangles) {
        var owned = [triangle];
        for (final previous in _rigidRegions.takeWhile(
          (candidate) => candidate != region,
        )) {
          owned = [
            for (final fragment in owned)
              ..._subtractRegion(
                fragment,
                previous.triangles,
                previous.outline,
              ),
          ];
        }
        for (final fragment in owned) {
          final split = _subtractConvex(fragment, _shieldFootprint);
          for (final outside in split.$1) {
            _polygon(
              outside,
              patch,
              (_) => [_SkinWeight(region.bone, 1)],
              original,
            );
          }
          if (split.$2.length >= 3) {
            _polygon(
              split.$2,
              patch,
              (_) => [_SkinWeight(region.bone, 1)],
              reconstructed,
            );
          }
        }
      }
      _sections.add(
        _MeshSection(
          Uint16List.fromList(original),
          Uint16List.fromList(reconstructed),
          false,
        ),
      );
    }
    final shieldIndices = <int>[];
    final patch = _sections.length;
    final center =
        _shieldOutline.reduce((a, b) => a + b) /
        _shieldOutline.length.toDouble();
    for (var i = 0; i < _shieldOutline.length; i++) {
      _polygon(
        [
          center,
          _shieldOutline[i],
          _shieldOutline[(i + 1) % _shieldOutline.length],
        ],
        patch,
        (_) => const [_SkinWeight(_Bone.rightForearm, 1)],
        shieldIndices,
      );
    }
    _sections.add(
      _MeshSection(Uint16List.fromList(shieldIndices), Uint16List(0), true),
    );
    indices = Uint16List.fromList([
      for (final section in _sections) ...section.original,
      for (final section in _sections) ...section.reconstructed,
    ]);
    assert(
      vertexCount < 4096,
      'Keep the mobile skin mesh bounded ($vertexCount vertices).',
    );
  }

  final List<Offset> _rest = [];
  final List<List<_SkinWeight>> _weights = [];
  final List<_MeshSection> _sections = [];
  final Map<(int, int, int), int> _vertices = {};
  late final Uint16List indices;
  Float32List? _uvs;
  Size? _textureSize;
  int get vertexCount => _rest.length;
  int get triangleCount => indices.length ~/ 3;

  void _strip(
    List<_Row> rows,
    int columns,
    List<_SkinWeight> Function(Offset) weights,
  ) {
    final original = <int>[];
    final reconstructed = <int>[];
    final patch = _sections.length;
    Offset point(int row, int column) => Offset(
      rows[row].left + (rows[row].right - rows[row].left) * column / columns,
      rows[row].y,
    );
    for (var row = 0; row < rows.length - 1; row++) {
      for (var column = 0; column < columns; column++) {
        final a = point(row, column);
        final b = point(row, column + 1);
        final c = point(row + 1, column);
        final d = point(row + 1, column + 1);
        for (final triangle in [
          [a, b, c],
          [b, d, c],
        ]) {
          if (identical(rows, _core) && triangle.every((p) => p.dy >= .64)) {
            continue;
          }
          var owned = [triangle];
          for (final region in _rigidRegions) {
            owned = [
              for (final fragment in owned)
                ..._subtractRegion(fragment, region.triangles, region.outline),
            ];
          }
          if (!identical(rows, _core)) {
            owned = [
              for (final fragment in owned)
                ..._subtractRegion(fragment, _coreTriangles, _coreContour),
            ];
          }
          if (identical(rows, _rightArm) || identical(rows, _leftArm)) {
            for (final leg in [_leftLegContour, _rightLegContour]) {
              final triangles = identical(leg, _leftLegContour)
                  ? _leftLegTriangles
                  : _rightLegTriangles;
              owned = [
                for (final fragment in owned)
                  ..._subtractRegion(fragment, triangles, leg),
              ];
            }
          }
          for (final fragment in owned) {
            final split = _subtractConvex(fragment, _shieldFootprint);
            for (final outside in split.$1) {
              _polygon(outside, patch, weights, original);
            }
            if (split.$2.length >= 3) {
              _polygon(split.$2, patch, weights, reconstructed);
            }
          }
        }
      }
    }
    _sections.add(
      _MeshSection(
        Uint16List.fromList(original),
        Uint16List.fromList(reconstructed),
        false,
      ),
    );
  }

  void _polygon(
    List<Offset> polygon,
    int patch,
    List<_SkinWeight> Function(Offset) weights,
    List<int> triangles,
  ) {
    if (!_hasArea(polygon)) return;
    final vertices = <int>[];
    for (final point in polygon) {
      final key = (patch, (point.dx * 1e10).round(), (point.dy * 1e10).round());
      vertices.add(
        _vertices.putIfAbsent(key, () {
          _rest.add(point);
          _weights.add(weights(point));
          return _rest.length - 1;
        }),
      );
    }
    for (var i = 1; i < vertices.length - 1; i++) {
      // Ownership clipping creates collinear boundary points. They carry no
      // textured area and need not consume a native draw triangle.
      if (_cross(polygon[0], polygon[i], polygon[i + 1]).abs() > 1e-12) {
        triangles.addAll([vertices[0], vertices[i], vertices[i + 1]]);
      }
    }
  }

  Float32List textureCoordinates(Size size) {
    if (_textureSize == size) return _uvs!;
    _textureSize = size;
    final values = Float32List(vertexCount * 2);
    for (var i = 0; i < vertexCount; i++) {
      values[i * 2] = _rest[i].dx * size.width;
      values[i * 2 + 1] = _rest[i].dy * size.height;
    }
    return _uvs = values;
  }

  Float32List deform(GoliathPose pose, Rect bounds) {
    final transforms = [
      for (final bone in _bones)
        _Affine.fromBone(pose.boneTransform(bone.$1, bone.$2)),
    ];
    final values = Float32List(vertexCount * 2);
    for (var i = 0; i < vertexCount; i++) {
      final point = _rest[i];
      var x = 0.0;
      var y = 0.0;
      for (final influence in _weights[i]) {
        final transform = transforms[influence.bone.index];
        x += influence.weight * transform.x(point.dx, point.dy);
        y += influence.weight * transform.y(point.dx, point.dy);
      }
      values[i * 2] = bounds.left + x * bounds.width;
      values[i * 2 + 1] = bounds.top + y * bounds.height;
    }
    return values;
  }

  static List<_SkinWeight> _anatomyWeights(Offset p) {
    // All overlapping UV regions use identical weights. A shoulder pad or
    // apron pixel cannot belong to two moving bones merely because it is
    // covered by both a torso strip and a limb strip.
    // The traced face island omits a few painted beard/hair rim pixels.
    // Carry its narrow surrounding source band with the same rigid head so
    // a controlled neck bend cannot leave those pixels behind on the chest.
    if (_insideOrEdge(p, _headOutline) ||
        (p.dy < .287 && _distanceToContour(p, _headOutline) < .013)) {
      return const [_SkinWeight(_Bone.head, 1)];
    }
    if (_insidePolygon(p, _leftSandal)) {
      return const [_SkinWeight(_Bone.leftFoot, 1)];
    }
    if (_insidePolygon(p, _rightSandal)) {
      return const [_SkinWeight(_Bone.rightFoot, 1)];
    }
    if (_insideOrEdge(p, _apronOutline)) {
      return const [_SkinWeight(_Bone.pelvis, 1)];
    }
    if (_insideOrEdge(p, _leftLegContour)) return _legWeights(p, true);
    if (_insideOrEdge(p, _rightLegContour)) return _legWeights(p, false);
    // The rigid belt starts above the old chest/pelvis blend. Its clipped
    // torso edge must use the same pelvis transform as the apron island;
    // otherwise a bending waist opens a literal gap between the two meshes.
    // Restrict the attachment band to the torso's source ownership so the
    // neighboring bracer and shield arm keep their own limb transforms.
    if (p.dy >= .39 &&
        p.dy <= .49 &&
        p.dx >= .285 &&
        p.dx <= .62 &&
        _insideOrEdge(p, _coreContour)) {
      final pelvis = 1 - _smooth(0, .032, _distanceToContour(p, _apronOutline));
      if (pelvis > .000001) {
        return [
          _SkinWeight(_Bone.chest, 1 - pelvis),
          _SkinWeight(_Bone.pelvis, pelvis),
        ].where((w) => w.weight > .000001).toList();
      }
    }
    if (p.dy >= .436 && p.dy <= .565 && p.dx < .262) {
      return const [_SkinWeight(_Bone.leftForearm, 1)];
    }
    if ((p.dx >= .255 && p.dx <= .392 && p.dy >= .23 && p.dy <= .34) ||
        (p.dx >= .584 && p.dx <= .752 && p.dy >= .219 && p.dy <= .329) ||
        (p.dx >= .306 && p.dx <= .598 && p.dy >= .287 && p.dy <= .445)) {
      return const [_SkinWeight(_Bone.chest, 1)];
    }
    if (p.dy >= .475 && p.dy <= .675 && p.dx >= .222 && p.dx <= .638) {
      return const [_SkinWeight(_Bone.pelvis, 1)];
    }
    if (p.dy > .675) return _legWeights(p, p.dx < .47);
    if (p.dx < .29 && p.dy > .34) return _leftArmWeights(p);
    if (p.dx > .63 && p.dy > .329) return _rightArmWeights(p);
    return _coreWeights(p);
  }

  static List<_SkinWeight> _coreWeights(Offset p) {
    final y = p.dy;
    final head =
        (1 - _smooth(.291, .319, y)) *
        _smooth(.38, .405, p.dx) *
        (1 - _smooth(.54, .565, p.dx));
    final pelvis = _smooth(.445, .478, y);
    final neck =
        (1 - _smooth(.31, .34, y)) *
        (1 - head) *
        _smooth(.36, .395, p.dx) *
        (1 - _smooth(.555, .59, p.dx));
    return [
      _SkinWeight(_Bone.head, head),
      _SkinWeight(_Bone.neck, neck),
      _SkinWeight(_Bone.chest, (1 - head - neck) * (1 - pelvis)),
      _SkinWeight(_Bone.pelvis, (1 - head - neck) * pelvis),
    ].where((w) => w.weight > .000001).toList();
  }

  static List<_SkinWeight> _leftArmWeights(Offset p) {
    final elbow = _smooth(.418, .450, p.dy);
    final palm = _smooth(.566, .589, p.dy);
    return [
      _SkinWeight(_Bone.leftUpperArm, 1 - elbow),
      _SkinWeight(_Bone.leftForearm, elbow * (1 - palm)),
      _SkinWeight(_Bone.leftHand, elbow * palm),
    ].where((w) => w.weight > .000001).toList();
  }

  static List<_SkinWeight> _rightArmWeights(Offset p) {
    final elbow = _smooth(.394, .435, p.dy);
    return [
      _SkinWeight(_Bone.rightUpperArm, 1 - elbow),
      _SkinWeight(_Bone.rightForearm, elbow),
    ].where((w) => w.weight > .000001).toList();
  }

  static List<_SkinWeight> _legWeights(Offset p, bool left) {
    final shinOutline = left ? _leftShinMetal : _rightShinMetal;
    final footOutline = left ? _leftSandal : _rightSandal;
    // Every shared trim vertex gets exactly the rigid island's transform.
    // Exposed skin then carries the articulation between those rigid seams.
    final hemDistance = _distanceToContour(p, _apronOutline);
    final hem = 1 - _smooth(0, .044, hemDistance);
    final knee = _smooth(.714, .77, p.dy);
    final plate = 1 - _smooth(0, .032, _distanceToContour(p, shinOutline));
    final shin = math.max(knee, plate);
    final shinDistance = _distanceToContour(p, shinOutline);
    final attachmentDistance = hemDistance + shinDistance;
    // Match both rigid neighbors exactly, even where the hem sits close to
    // a shin guard. Multiplying by the plate's influence at the hem made
    // the leg-side copy of a garment vertex drift from the apron island.
    final hip =
        hem *
        _smooth(
          0,
          1,
          attachmentDistance < 1e-10 ? 1 : shinDistance / attachmentDistance,
        );
    final footDistance = _distanceToContour(p, footOutline);
    final totalDistance = shinDistance + footDistance;
    // Gold stops before the brown ankle band. Interpolate across that band,
    // with exactly shin100% at the cuff and foot100% at the sandal boundary.
    final foot =
        _smooth(.80, .88, p.dy) *
        _smooth(0, 1, totalDistance < 1e-10 ? 0 : shinDistance / totalDistance);
    return [
      _SkinWeight(_Bone.pelvis, hip),
      _SkinWeight(
        left ? _Bone.leftThigh : _Bone.rightThigh,
        (1 - hip) * (1 - shin),
      ),
      _SkinWeight(
        left ? _Bone.leftShin : _Bone.rightShin,
        (1 - hip) * shin * (1 - foot),
      ),
      _SkinWeight(
        left ? _Bone.leftFoot : _Bone.rightFoot,
        (1 - hip) * shin * foot,
      ),
    ].where((w) => w.weight > .000001).toList();
  }
}

class GoliathMeshPainter extends CustomPainter {
  GoliathMeshPainter({
    required this.image,
    required this.pose,
    required this.mesh,
    required this.bounds,
    this.reconstruction,
  });
  final ui.Image image;
  final ui.Image? reconstruction;
  final GoliathPose pose;
  final GoliathSkinMesh mesh;
  final Rect bounds;

  @override
  void paint(Canvas canvas, Size size) {
    final positions = mesh.deform(pose, bounds);
    final uv = mesh.textureCoordinates(
      Size(image.width.toDouble(), image.height.toDouble()),
    );
    final original = _shader(image);
    final hidden = reconstruction == null ? original : _shader(reconstruction!);
    void draw(Uint16List indices, ui.Shader shader) {
      if (indices.isEmpty) return;
      final vertices = ui.Vertices.raw(
        ui.VertexMode.triangles,
        positions,
        textureCoordinates: uv,
        indices: indices,
      );
      canvas.drawVertices(vertices, BlendMode.src, Paint()..shader = shader);
      vertices.dispose();
    }

    for (final section in mesh._sections) {
      draw(section.original, original);
      if (!section.shield) draw(section.reconstructed, hidden);
    }
    original.dispose();
    if (hidden != original) hidden.dispose();
  }

  static ui.ImageShader _shader(ui.Image image) => ui.ImageShader(
    image,
    TileMode.clamp,
    TileMode.clamp,
    Matrix4.identity().storage,
    filterQuality: FilterQuality.medium,
  );

  @override
  bool shouldRepaint(covariant GoliathMeshPainter oldDelegate) =>
      oldDelegate.pose != pose ||
      oldDelegate.bounds != bounds ||
      oldDelegate.image != image ||
      oldDelegate.reconstruction != reconstruction;
}

class _MeshSection {
  const _MeshSection(this.original, this.reconstructed, this.shield);
  final Uint16List original, reconstructed;
  final bool shield;
}

class _Row {
  const _Row(this.y, this.left, this.right);
  final double y, left, right;
}

// These contours are UV envelopes, not bitmap rectangles. Transparent texture
// margins retain the original silhouette, with denser rows only at joints.
const _core = [
  _Row(0, .295, .655),
  _Row(.12, .295, .655),
  _Row(.21, .295, .705),
  _Row(.235, .255, .75),
  _Row(.25, .255, .75),
  _Row(.27, .255, .75),
  _Row(.285, .28, .695),
  _Row(.296, .264, .735),
  _Row(.31, .258, .75),
  _Row(.325, .263, .755),
  _Row(.34, .27, .745),
  _Row(.4, .28, .71),
  _Row(.43, .28, .69),
  _Row(.445, .275, .688),
  _Row(.46, .269, .685),
  _Row(.478, .26, .68),
  _Row(.50, .254, .68),
  _Row(.54, .248, .674),
  _Row(.59, .232, .67),
  _Row(.64, .222, .666),
  _Row(.675, .248, .645),
  _Row(.700, .31, .60),
];
const _leftArm = [
  _Row(.278, .27, .386),
  _Row(.296, .25, .396),
  _Row(.325, .22, .40),
  _Row(.37, .18, .368),
  _Row(.405, .151, .34),
  _Row(.418, .138, .329),
  _Row(.435, .124, .32),
  _Row(.45, .113, .306),
  _Row(.49, .105, .287),
  _Row(.54, .098, .267),
  _Row(.565, .098, .255),
  _Row(.58, .098, .245),
  _Row(.61, .099, .240),
  _Row(.65, .10, .233),
  _Row(.684, .11, .218),
];
const _rightArm = [
  _Row(.278, .57, .746),
  _Row(.31, .585, .798),
  _Row(.36, .608, .813),
  _Row(.395, .638, .839),
  _Row(.425, .651, .853),
  _Row(.47, .664, .869),
  _Row(.51, .665, .877),
  _Row(.54, .666, .88),
  _Row(.57, .664, .88),
  _Row(.625, .65, .90),
  _Row(.67, .65, .90),
];
const _leftLeg = [
  _Row(.625, .282, .437),
  _Row(.67, .272, .440),
  _Row(.70, .264, .437),
  _Row(.714, .26, .430),
  _Row(.736, .259, .426),
  _Row(.75, .259, .424),
  _Row(.78, .26, .422),
  _Row(.84, .262, .417),
  _Row(.885, .25, .415),
  _Row(.902, .229, .415),
  _Row(.916, .203, .415),
  _Row(.94, .165, .415),
  _Row(.965, .15, .421),
  _Row(.982, .148, .425),
];
const _rightLeg = [
  _Row(.625, .457, .653),
  _Row(.67, .475, .691),
  _Row(.7, .50, .714),
  _Row(.714, .514, .72),
  _Row(.736, .526, .721),
  _Row(.75, .534, .724),
  _Row(.78, .536, .725),
  _Row(.84, .554, .737),
  _Row(.885, .568, .761),
  _Row(.902, .576, .775),
  _Row(.916, .582, .787),
  _Row(.94, .587, .795),
  _Row(.97, .588, .801),
  _Row(.999, .588, .805),
];

// Convex outer border of the original shield. The reconstruction is sampled
// only inside this footprint; all previously visible pixels use the original.
const _shieldOutline = [
  Offset(0.73204420, 0.34185083),
  Offset(0.80684393, 0.35855982),
  Offset(0.86219674, 0.39693367),
  Offset(0.89432166, 0.44312506),
  Offset(0.91142226, 0.48809738),
  Offset(0.91804788, 0.53176796),
  Offset(0.91510707, 0.57612550),
  Offset(0.89893082, 0.62247740),
  Offset(0.86404392, 0.66798043),
  Offset(0.80777338, 0.70566459),
  Offset(0.73204420, 0.71823204),
  Offset(0.65816142, 0.70221272),
  Offset(0.60280786, 0.66521852),
  Offset(0.56792142, 0.62109764),
  Offset(0.54806407, 0.57682431),
  Offset(0.54235727, 0.53176796),
  Offset(0.54806407, 0.48671160),
  Offset(0.56423894, 0.44036565),
  Offset(0.59912819, 0.39417180),
  Offset(0.65631502, 0.35787132),
];

// The painted rim curves between traced shield vertices. Erase its complete
// flattened footprint from the body, while retaining the exact original UV
// outline for the independently rendered rigid shield.
final _shieldFootprint = _shieldOutline
    .map((p) {
      final delta = Offset(p.dx * 1086 - 795, p.dy * 1448 - 770);
      final outward = delta / delta.distance * 6;
      return p + Offset(outward.dx / 1086, outward.dy / 1448);
    })
    .toList(growable: false);

const _headOutline = [
  Offset(0.45764273, 0.00414365),
  Offset(0.48987109, 0.00897790),
  Offset(0.51933702, 0.02693370),
  Offset(0.54880295, 0.08563536),
  Offset(0.55156538, 0.12776243),
  Offset(0.56629834, 0.15538674),
  Offset(0.57918969, 0.17886740),
  Offset(0.60497238, 0.19751381),
  Offset(0.60773481, 0.21754144),
  Offset(0.56998158, 0.22513812),
  Offset(0.54880295, 0.22859116),
  Offset(0.53222836, 0.26035912),
  Offset(0.50644567, 0.27693370),
  Offset(0.45580110, 0.28729282),
  Offset(0.39410681, 0.28176796),
  Offset(0.36187845, 0.26104972),
  Offset(0.34806630, 0.23687845),
  Offset(0.32596685, 0.22237569),
  Offset(0.33057090, 0.20372928),
  Offset(0.34806630, 0.18024862),
  Offset(0.36279926, 0.15331492),
  Offset(0.38674033, 0.13950276),
  Offset(0.38121547, 0.10428177),
  Offset(0.40699816, 0.05524862),
  Offset(0.39871087, 0.02486188),
];

const _leftSandal = [
  Offset(0.25782689, 0.88397790),
  Offset(0.39042357, 0.88397790),
  Offset(0.38950276, 0.89433702),
  Offset(0.39502762, 0.90469613),
  Offset(0.39871087, 0.91505525),
  Offset(0.40423573, 0.92886740),
  Offset(0.40699816, 0.94267956),
  Offset(0.34622468, 0.95649171),
  Offset(0.29005525, 0.96685083),
  Offset(0.24309392, 0.97237569),
  Offset(0.20441989, 0.97237569),
  Offset(0.16758748, 0.96685083),
  Offset(0.15561694, 0.95649171),
  Offset(0.15930018, 0.94267956),
  Offset(0.16758748, 0.92886740),
  Offset(0.18876611, 0.91505525),
  Offset(0.21178637, 0.90469613),
  Offset(0.23756906, 0.89433702),
];

const _rightSandal = [
  Offset(0.59484346, 0.89502762),
  Offset(0.71362799, 0.89502762),
  Offset(0.72007366, 0.90469613),
  Offset(0.72836096, 0.91505525),
  Offset(0.74677716, 0.92886740),
  Offset(0.76335175, 0.94267956),
  Offset(0.77255985, 0.95649171),
  Offset(0.77716390, 0.97030387),
  Offset(0.77255985, 0.98066298),
  Offset(0.73572744, 0.99102210),
  Offset(0.69889503, 0.99447514),
  Offset(0.66206262, 0.99447514),
  Offset(0.63167587, 0.99102210),
  Offset(0.60865562, 0.98066298),
  Offset(0.60220994, 0.97030387),
  Offset(0.59023941, 0.95649171),
  Offset(0.59023941, 0.94267956),
  Offset(0.59392265, 0.92886740),
  Offset(0.59760589, 0.91505525),
  Offset(0.60128913, 0.90469613),
];

const _apronOutline = [
  Offset(323 / 1086, 646 / 1448),
  Offset(385 / 1086, 629 / 1448),
  Offset(451 / 1086, 625 / 1448),
  Offset(583 / 1086, 637 / 1448),
  Offset(653 / 1086, 648 / 1448),
  Offset(663 / 1086, 674 / 1448),
  Offset(662 / 1086, 695 / 1448),
  Offset(671 / 1086, 724 / 1448),
  Offset(707 / 1086, 816 / 1448),
  Offset(746 / 1086, 913 / 1448),
  Offset(750 / 1086, 924 / 1448),
  Offset(749 / 1086, 931 / 1448),
  Offset(736 / 1086, 949 / 1448),
  Offset(720 / 1086, 960 / 1448),
  Offset(709 / 1086, 980 / 1448),
  Offset(705 / 1086, 984 / 1448),
  Offset(693 / 1086, 951 / 1448),
  Offset(650 / 1086, 964 / 1448),
  Offset(548 / 1086, 979 / 1448),
  Offset(559 / 1086, 1016 / 1448),
  Offset(451 / 1086, 1017 / 1448),
  Offset(462 / 1086, 981 / 1448),
  Offset(379 / 1086, 971 / 1448),
  Offset(310 / 1086, 957 / 1448),
  Offset(314 / 1086, 983 / 1448),
  Offset(290 / 1086, 991 / 1448),
  Offset(285 / 1086, 977 / 1448),
  Offset(251 / 1086, 958 / 1448),
  Offset(240 / 1086, 940 / 1448),
  Offset(242 / 1086, 923 / 1448),
  Offset(274 / 1086, 819 / 1448),
  Offset(309 / 1086, 720 / 1448),
  Offset(315 / 1086, 697 / 1448),
  Offset(316 / 1086, 670 / 1448),
];

const _palmOutline = [
  Offset(0.13167590, 0.55248620),
  Offset(0.16022100, 0.55041440),
  Offset(0.17771640, 0.55939230),
  Offset(0.19429100, 0.57527620),
  Offset(0.21270720, 0.60635360),
  Offset(0.22007370, 0.62776240),
  Offset(0.21086560, 0.63743090),
  Offset(0.19429100, 0.63604970),
  Offset(0.18232040, 0.62707180),
  Offset(0.17034990, 0.60773480),
  Offset(0.16298340, 0.62016570),
  Offset(0.16850830, 0.64019340),
  Offset(0.19244940, 0.65676800),
  Offset(0.19613260, 0.66574590),
  Offset(0.18600370, 0.67334250),
  Offset(0.17034990, 0.67196130),
  Offset(0.14180480, 0.66229280),
  Offset(0.11786370, 0.64848070),
  Offset(0.10589320, 0.63328730),
  Offset(0.10405160, 0.61809390),
  Offset(0.10957640, 0.58977900),
  Offset(0.12154700, 0.56491710),
];

const _leftPadOutline = [
  Offset(0.27071820, 0.26243090),
  Offset(0.31215470, 0.24447510),
  Offset(0.35174950, 0.23687850),
  Offset(0.34438310, 0.25759670),
  Offset(0.33977900, 0.28245860),
  Offset(0.33701660, 0.30386740),
  Offset(0.32872930, 0.31422650),
  Offset(0.28084710, 0.32389500),
  Offset(0.26887660, 0.32113260),
  Offset(0.26335170, 0.30939230),
  Offset(0.26243090, 0.28245860),
];

const _rightPadOutline = [
  Offset(0.52302030, 0.28591160),
  Offset(0.53959480, 0.25414360),
  Offset(0.56629830, 0.22997240),
  Offset(0.60128910, 0.21754140),
  Offset(0.62799260, 0.22030390),
  Offset(0.65930020, 0.22582870),
  Offset(0.68968690, 0.23411600),
  Offset(0.69613260, 0.24240330),
  Offset(0.69521180, 0.25000000),
  Offset(0.67679560, 0.25345300),
  Offset(0.65377530, 0.26933700),
  Offset(0.62707180, 0.29834250),
  Offset(0.60589320, 0.31146410),
  Offset(0.52946590, 0.30662980),
  Offset(0.51289130, 0.30179560),
];

bool _insidePolygon(Offset point, List<Offset> polygon) {
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final a = polygon[i];
    final b = polygon[j];
    if ((a.dy > point.dy) != (b.dy > point.dy) &&
        point.dx < (b.dx - a.dx) * (point.dy - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

(List<List<Offset>>, List<Offset>) _subtractConvex(
  List<Offset> polygon,
  List<Offset> outline,
) {
  final outside = <List<Offset>>[];
  var inside = polygon;
  for (var edge = 0; edge < outline.length && inside.isNotEmpty; edge++) {
    final a = outline[edge];
    final b = outline[(edge + 1) % outline.length];
    final removed = _clip(inside, a, b, false);
    if (_hasArea(removed)) outside.add(removed);
    inside = _clip(inside, a, b, true);
    if (!_hasArea(inside)) {
      inside = [];
      break;
    }
  }
  return (outside, inside);
}

List<Offset> _clip(List<Offset> polygon, Offset a, Offset b, bool keepInside) {
  if (polygon.isEmpty) return [];
  double side(Offset p) =>
      (b.dx - a.dx) * (p.dy - a.dy) - (b.dy - a.dy) * (p.dx - a.dx);
  bool kept(double value) => keepInside ? value >= -1e-12 : value <= 1e-12;
  final result = <Offset>[];
  var previous = polygon.last;
  var previousSide = side(previous);
  for (final current in polygon) {
    final currentSide = side(current);
    if (kept(currentSide) != kept(previousSide)) {
      final t = previousSide / (previousSide - currentSide);
      result.add(previous + (current - previous) * t);
    }
    if (kept(currentSide)) result.add(current);
    previous = current;
    previousSide = currentSide;
  }
  return result;
}

enum _Bone {
  head,
  neck,
  chest,
  pelvis,
  leftUpperArm,
  leftForearm,
  leftHand,
  rightUpperArm,
  rightForearm,
  leftThigh,
  leftShin,
  leftFoot,
  rightThigh,
  rightShin,
  rightFoot,
}

const _bones = [
  (GoliathJoint.neck, GoliathJoint.head),
  (GoliathJoint.chest, GoliathJoint.neck),
  (GoliathJoint.leftShoulder, GoliathJoint.rightShoulder),
  (GoliathJoint.leftHip, GoliathJoint.rightHip),
  (GoliathJoint.leftShoulder, GoliathJoint.leftElbow),
  (GoliathJoint.leftElbow, GoliathJoint.leftWrist),
  (GoliathJoint.leftWrist, GoliathJoint.leftPalm),
  (GoliathJoint.rightShoulder, GoliathJoint.rightElbow),
  (GoliathJoint.rightElbow, GoliathJoint.rightWrist),
  (GoliathJoint.leftHip, GoliathJoint.leftKnee),
  (GoliathJoint.leftKnee, GoliathJoint.leftAnkle),
  (GoliathJoint.leftAnkle, GoliathJoint.leftToe),
  (GoliathJoint.rightHip, GoliathJoint.rightKnee),
  (GoliathJoint.rightKnee, GoliathJoint.rightAnkle),
  (GoliathJoint.rightAnkle, GoliathJoint.rightToe),
];

class _RigidRegion {
  _RigidRegion(this.outline, this.bone);
  final List<Offset> outline;
  final _Bone bone;
  late final List<List<Offset>> triangles = _triangulate(outline);
}

const _leftShinMetal = [
  Offset(317 / 1086, 1012 / 1448),
  Offset(343 / 1086, 1014 / 1448),
  Offset(367 / 1086, 1026 / 1448),
  Offset(385 / 1086, 1050 / 1448),
  Offset(396 / 1086, 1081 / 1448),
  Offset(398 / 1086, 1110 / 1448),
  Offset(391 / 1086, 1152 / 1448),
  Offset(382 / 1086, 1191 / 1448),
  Offset(374 / 1086, 1230 / 1448),
  Offset(372 / 1086, 1263 / 1448),
  Offset(361 / 1086, 1273 / 1448),
  Offset(338 / 1086, 1267 / 1448),
  Offset(309 / 1086, 1263 / 1448),
  Offset(293 / 1086, 1270 / 1448),
  Offset(289 / 1086, 1255 / 1448),
  Offset(295 / 1086, 1235 / 1448),
  Offset(291 / 1086, 1195 / 1448),
  Offset(287 / 1086, 1150 / 1448),
  Offset(282 / 1086, 1111 / 1448),
  Offset(284 / 1086, 1070 / 1448),
  Offset(293 / 1086, 1041 / 1448),
  Offset(304 / 1086, 1021 / 1448),
];
const _rightShinMetal = [
  Offset(633 / 1086, 1018 / 1448),
  Offset(659 / 1086, 1021 / 1448),
  Offset(683 / 1086, 1036 / 1448),
  Offset(705 / 1086, 1059 / 1448),
  Offset(718 / 1086, 1091 / 1448),
  Offset(723 / 1086, 1125 / 1448),
  Offset(727 / 1086, 1165 / 1448),
  Offset(734 / 1086, 1205 / 1448),
  Offset(737 / 1086, 1231 / 1448),
  Offset(736 / 1086, 1248 / 1448),
  Offset(737 / 1086, 1256 / 1448),
  Offset(734 / 1086, 1264 / 1448),
  Offset(723 / 1086, 1263 / 1448),
  Offset(705 / 1086, 1263 / 1448),
  Offset(686 / 1086, 1270 / 1448),
  Offset(673 / 1086, 1278 / 1448),
  Offset(665 / 1086, 1284 / 1448),
  Offset(660 / 1086, 1281 / 1448),
  Offset(657 / 1086, 1274 / 1448),
  Offset(657 / 1086, 1261 / 1448),
  Offset(650 / 1086, 1250 / 1448),
  Offset(642 / 1086, 1228 / 1448),
  Offset(626 / 1086, 1191 / 1448),
  Offset(607 / 1086, 1151 / 1448),
  Offset(599 / 1086, 1111 / 1448),
  Offset(600 / 1086, 1071 / 1448),
  Offset(611 / 1086, 1041 / 1448),
  Offset(622 / 1086, 1026 / 1448),
];
final _rigidRegions = [
  _RigidRegion(_headOutline, _Bone.head),
  _RigidRegion(_apronOutline, _Bone.pelvis),
  _RigidRegion(_leftPadOutline, _Bone.chest),
  _RigidRegion(_rightPadOutline, _Bone.chest),
  _RigidRegion(_palmOutline, _Bone.leftHand),
  _RigidRegion(_leftSandal, _Bone.leftFoot),
  _RigidRegion(_rightSandal, _Bone.rightFoot),
  _RigidRegion(_leftShinMetal, _Bone.leftShin),
  _RigidRegion(_rightShinMetal, _Bone.rightShin),
];

List<Offset> _rowContour(List<_Row> rows) => [
  for (final row in rows) Offset(row.right, row.y),
  for (final row in rows.reversed) Offset(row.left, row.y),
];
final _leftLegContour = _rowContour(_leftLeg);
final _rightLegContour = _rowContour(_rightLeg);
final _leftLegTriangles = _triangulate(_leftLegContour);
final _rightLegTriangles = _triangulate(_rightLegContour);

bool _insideOrEdge(Offset p, List<Offset> outline) =>
    _insidePolygon(p, outline) || _distanceToContour(p, outline) < 1e-8;
double _distanceToContour(Offset point, List<Offset> outline) {
  var minimum = double.infinity;
  final p = Offset(point.dx * .75, point.dy);
  for (var i = 0; i < outline.length; i++) {
    final a = Offset(outline[i].dx * .75, outline[i].dy);
    final next = outline[(i + 1) % outline.length];
    final b = Offset(next.dx * .75, next.dy);
    final d = b - a;
    final fraction = d.distanceSquared == 0
        ? 0.0
        : ((p - a).dx * d.dx + (p - a).dy * d.dy) / d.distanceSquared;
    minimum = math.min(
      minimum,
      (p - (a + d * fraction.clamp(0.0, 1.0))).distance,
    );
  }
  return minimum;
}

final _coreContour = [
  for (final row in _core.where((row) => row.y <= .64))
    Offset(row.right, row.y),
  for (final row in _core.where((row) => row.y <= .64).toList().reversed)
    Offset(row.left, row.y),
];
final _coreTriangles = _triangulate(_coreContour);

List<List<Offset>> _subtractRegion(
  List<Offset> polygon,
  List<List<Offset>> region,
  List<Offset> outline,
) {
  if (!_hasArea(polygon)) return [];
  var crossing = false;
  for (var i = 0; i < polygon.length && !crossing; i++) {
    final a = polygon[i];
    final b = polygon[(i + 1) % polygon.length];
    for (var j = 0; j < outline.length; j++) {
      final c = outline[j];
      final d = outline[(j + 1) % outline.length];
      if (_cross(a, b, c) * _cross(a, b, d) < -1e-16 &&
          _cross(c, d, a) * _cross(c, d, b) < -1e-16) {
        crossing = true;
        break;
      }
    }
  }
  if (!crossing) {
    final center = polygon.reduce((a, b) => a + b) / polygon.length.toDouble();
    if (_insidePolygon(center, outline)) return [];
    if (!_insidePolygon(outline.first, polygon)) return [polygon];
  }
  var fragments = [polygon];
  for (final triangle in region) {
    fragments = [
      for (final fragment in fragments)
        if (!_bounds(fragment).overlaps(_bounds(triangle)))
          fragment
        else
          ..._subtractConvex(fragment, triangle).$1,
    ];
    if (fragments.isEmpty) break;
  }
  return fragments;
}

bool _hasArea(List<Offset> polygon) {
  if (polygon.length < 3) return false;
  var area = 0.0;
  for (var i = 0; i < polygon.length; i++) {
    final a = polygon[i];
    final b = polygon[(i + 1) % polygon.length];
    area += a.dx * b.dy - a.dy * b.dx;
  }
  return area.abs() > 1e-12;
}

Rect _bounds(List<Offset> polygon) {
  var bounds = Rect.fromPoints(polygon.first, polygon.first);
  for (final point in polygon.skip(1)) {
    bounds = bounds.expandToInclude(Rect.fromPoints(point, point));
  }
  return bounds;
}

double _cross(Offset a, Offset b, Offset c) =>
    (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);

List<List<Offset>> _triangulate(List<Offset> source) {
  var area = 0.0;
  for (var i = 0; i < source.length; i++) {
    final a = source[i];
    final b = source[(i + 1) % source.length];
    area += a.dx * b.dy - b.dx * a.dy;
  }
  final polygon = area < 0 ? source.reversed.toList() : source.toList();
  final result = <List<Offset>>[];
  while (polygon.length > 3) {
    var cut = false;
    for (var i = 0; i < polygon.length; i++) {
      final a = polygon[(i + polygon.length - 1) % polygon.length];
      final b = polygon[i];
      final c = polygon[(i + 1) % polygon.length];
      if (_cross(a, b, c) <= 1e-12) continue;
      if (polygon.any(
        (p) =>
            p != a &&
            p != b &&
            p != c &&
            _cross(a, b, p) > 1e-12 &&
            _cross(b, c, p) > 1e-12 &&
            _cross(c, a, p) > 1e-12,
      )) {
        continue;
      }
      result.add([a, b, c]);
      polygon.removeAt(i);
      cut = true;
      break;
    }
    if (!cut) throw StateError('Invalid Goliath ownership contour.');
  }
  result.add(polygon);
  return result;
}

class _SkinWeight {
  const _SkinWeight(this.bone, this.weight);
  final _Bone bone;
  final double weight;
}

class _Affine {
  const _Affine(this.a, this.b, this.c, this.d, this.tx, this.ty);
  factory _Affine.fromBone(GoliathBoneTransform transform) {
    final origin = transform.transformPoint(const GoliathPoint(0, 0));
    final x = transform.transformPoint(const GoliathPoint(1, 0));
    final y = transform.transformPoint(const GoliathPoint(0, 1));
    return _Affine(
      x.x - origin.x,
      x.y - origin.y,
      y.x - origin.x,
      y.y - origin.y,
      origin.x,
      origin.y,
    );
  }
  final double a, b, c, d, tx, ty;
  double x(double x, double y) => a * x + c * y + tx;
  double y(double x, double y) => b * x + d * y + ty;
}

double _smooth(double start, double end, double value) {
  final t = ((value - start) / (end - start)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

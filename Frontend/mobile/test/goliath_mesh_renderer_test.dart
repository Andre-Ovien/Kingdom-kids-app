import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/presentation/goliath_mesh_renderer.dart';
import 'package:mobile/features/games/presentation/goliath_motion_model.dart';

void main() {
  test('one bounded UV mesh keeps the face rigid through articulation', () {
    final mesh = GoliathSkinMesh();
    // Keep geometry bounded without retaining zero-area clipping fragments.
    expect(mesh.vertexCount, lessThanOrEqualTo(4096));
    expect(mesh.triangleCount, lessThan(6000));
    final model = GoliathMotionModel(idleMotion: false);
    model.strikeHead();
    for (var i = 0; i < 90; i++) {
      model.advance(1 / 120);
    }
    final uv = mesh.textureCoordinates(const Size(1086, 1448));
    final vertices = mesh.deform(
      model.pose,
      const Rect.fromLTWH(0, 0, 750, 1000),
    );
    final head = model.pose.boneTransform(GoliathJoint.neck, GoliathJoint.head);
    // Rigid islands need only their perimeter triangles; there need not be
    // redundant grid vertices inside the face after ownership clipping.
    for (final source in const [
      Offset(497, 6),
      Offset(532, 13),
      Offset(564, 39),
      Offset(596, 124),
      Offset(599, 185),
      Offset(615, 225),
      Offset(629, 259),
      Offset(578, 377),
      Offset(550, 401),
      Offset(495, 416),
      Offset(428, 408),
      Offset(393, 378),
      Offset(378, 343),
      Offset(354, 322),
      Offset(359, 295),
      Offset(378, 261),
      Offset(394, 222),
      Offset(420, 202),
      Offset(414, 151),
      Offset(442, 80),
    ]) {
      final expected = head.transformPoint(
        GoliathPoint(source.dx / 1086, source.dy / 1448),
      );
      var found = false;
      for (var i = 0; i < mesh.vertexCount; i++) {
        if ((uv[i * 2] - source.dx).abs() < .002 &&
            (uv[i * 2 + 1] - source.dy).abs() < .002 &&
            (vertices[i * 2] - expected.x * 750).abs() < .01 &&
            (vertices[i * 2 + 1] - expected.y * 1000).abs() < .01) {
          found = true;
          break;
        }
      }
      expect(
        found,
        true,
        reason:
            'Original face perimeter $source remains in the rigid head frame.',
      );
    }
  });

  test(
    'waist attachment shares the apron transform without taking arm pixels',
    () {
      final mesh = GoliathSkinMesh();
      final model = GoliathMotionModel(idleMotion: false);
      model.strikeHead(direction: -1);
      for (var i = 0; i < 120; i++) {
        model.advance(1 / 120);
      }
      final uv = mesh.textureCoordinates(const Size(1086, 1448));
      final vertices = mesh.deform(
        model.pose,
        const Rect.fromLTWH(0, 0, 750, 1000),
      );
      final pelvis = model.pose.boneTransform(
        GoliathJoint.leftHip,
        GoliathJoint.rightHip,
      );
      var sharedVertices = 0;
      for (final source in const [
        Offset(323, 646),
        Offset(385, 629),
        Offset(451, 625),
        Offset(583, 637),
        Offset(653, 648),
        Offset(314, 983),
        Offset(285, 977),
        Offset(693, 951),
        Offset(709, 980),
        Offset(750, 924),
      ]) {
        var copies = 0;
        final expected = pelvis.transformPoint(
          GoliathPoint(source.dx / 1086, source.dy / 1448),
        );
        for (var i = 0; i < mesh.vertexCount; i++) {
          if ((uv[i * 2] - source.dx).abs() < .002 &&
              (uv[i * 2 + 1] - source.dy).abs() < .002) {
            copies++;
            expect(vertices[i * 2], closeTo(expected.x * 750, .01));
            expect(vertices[i * 2 + 1], closeTo(expected.y * 1000, .01));
          }
        }
        // The belt shares its corners with the core strip. Some concave hem
        // corners have only the rigid island vertex after zero-area clipping;
        // every copy that remains must still use the same attachment frame.
        expect(copies, greaterThanOrEqualTo(source.dy < 700 ? 2 : 1));
        sharedVertices += copies;
      }
      expect(sharedVertices, greaterThanOrEqualTo(15));

      final forearm = model.pose.boneTransform(
        GoliathJoint.leftElbow,
        GoliathJoint.leftWrist,
      );
      var armVertices = 0;
      for (var i = 0; i < mesh.vertexCount; i++) {
        final x = uv[i * 2];
        final y = uv[i * 2 + 1];
        if (x < 284 && y > 640 && y < 780) {
          final expected = forearm.transformPoint(
            GoliathPoint(x / 1086, y / 1448),
          );
          armVertices++;
          expect(vertices[i * 2], closeTo(expected.x * 750, .01));
          expect(vertices[i * 2 + 1], closeTo(expected.y * 1000, .01));
        }
      }
      expect(armVertices, greaterThan(3));
    },
  );

  testWidgets(
    'native rest raster preserves original visible colors and opaque silhouette',
    (tester) async {
      await tester.runAsync(() async {
        final original = await _decode('goliath-angry-v2.png');
        final reconstruction = await _decode('goliath-body-rig-v3.png');
        final mesh = GoliathSkinMesh();
        final pose = GoliathMotionModel(idleMotion: false).pose;
        const bounds = Rect.fromLTWH(50, 10, 300, 400);
        const size = Size(400, 430);
        final skin = await _raster(
          (canvas) => GoliathMeshPainter(
            image: original,
            reconstruction: reconstruction,
            mesh: mesh,
            pose: pose,
            bounds: bounds,
          ).paint(canvas, size),
          size,
        );
        final reference = await _raster(
          (canvas) => canvas.drawImageRect(
            original,
            const Rect.fromLTWH(0, 0, 1086, 1448),
            bounds,
            Paint()..filterQuality = FilterQuality.medium,
          ),
          size,
        );
        var originalPixels = 0;
        var missing = 0;
        var compared = 0;
        var error = 0;
        for (var i = 0; i < reference.lengthInBytes; i += 4) {
          if (reference.getUint8(i + 3) > 200) {
            originalPixels++;
            if (skin.getUint8(i + 3) < 80) missing++;
            if (skin.getUint8(i + 3) > 200) {
              compared++;
              for (var c = 0; c < 3; c++) {
                error += (reference.getUint8(i + c) - skin.getUint8(i + c))
                    .abs();
              }
            }
          }
        }
        expect(
          missing / originalPixels,
          lessThan(.005),
          reason: 'Original opaque body regions must not become gaps.',
        );
        expect(
          error / (compared * 3),
          lessThan(6),
          reason:
              'Native triangle sampling may differ slightly from drawImageRect; visible source colors stay within 2.4% mean channel error.',
        );
        original.dispose();
        reconstruction.dispose();
      });
    },
  );

  testWidgets(
    'native opaque fall silhouette stays above floor and in view for both directions and all targets',
    (tester) async {
      await tester.runAsync(() async {
        final original = await _decode('goliath-angry-v2.png');
        final reconstruction = await _decode('goliath-body-rig-v3.png');
        final mesh = GoliathSkinMesh();
        const size = Size(390, 844);
        for (final target in const [
          Offset(160, 180),
          Offset(225, 145),
          Offset(148, 92),
        ]) {
          final x = target.dx / 320 * 390;
          final y = target.dy / 420 * 844;
          final width = (390 * .78 * .75).clamp(
            0.0,
            ((382 - x) / .549).clamp(0.0, (x - 8) / .451),
          );
          final bounds = Rect.fromLTWH(
            x - width * .451,
            y - width / .75 * .115,
            width,
            width / .75,
          );
          final floor = bounds.top + bounds.height * GoliathMotionModel.groundY;
          final directions = target.dx == 160
              ? [1.0, -1.0]
              : [target.dx > 160 ? -1.0 : 1.0];
          for (final direction in directions) {
            final model = GoliathMotionModel(
              idleMotion: false,
              minimumX: (8 - bounds.left) / bounds.width,
              maximumX: (382 - bounds.left) / bounds.width,
            );
            model.strikeHead(direction: direction);
            var elapsed = 0.0;
            for (final time in [.35, .75, 1.25, 2.0, 3.5]) {
              while (elapsed + 1 / 120 <= time + .00001) {
                model.advance(1 / 120);
                elapsed += 1 / 120;
              }
              final pixels = await _raster(
                (canvas) => GoliathMeshPainter(
                  image: original,
                  reconstruction: reconstruction,
                  mesh: mesh,
                  pose: model.pose,
                  bounds: bounds,
                ).paint(canvas, size),
                size,
              );
              var bottom = 0;
              var left = 390;
              var right = 0;
              var opaque = 0;
              for (var py = 0; py < 844; py++) {
                for (var px = 0; px < 390; px++) {
                  if (pixels.getUint8((py * 390 + px) * 4 + 3) > 64) {
                    if (py > bottom) bottom = py;
                    if (px < left) left = px;
                    if (px > right) right = px;
                    opaque++;
                  }
                }
              }
              expect(
                opaque,
                greaterThan(12000),
                reason:
                    'The body must remain present, including its armor and limbs.',
              );
              expect(
                bottom,
                lessThanOrEqualTo(floor + 5),
                reason:
                    'target=$target direction=$direction time=$time; real native texture crosses the floor.',
              );
              expect(left, greaterThanOrEqualTo(3));
              expect(right, lessThanOrEqualTo(387));
            }
            while (!model.pose.isSettled && elapsed < 8) {
              model.advance(1 / 120);
              elapsed += 1 / 120;
            }
            expect(
              model.pose.isSettled,
              true,
              reason:
                  'The articulated body must settle within eight active seconds.',
            );
            expect(model.pose.isGrounded, true);
          }
        }
        original.dispose();
        reconstruction.dispose();
      });
    },
  );
  testWidgets(
    'native legs remain visibly attached through both fall directions and every target',
    (tester) async {
      await tester.runAsync(() async {
        final original = await _decode('goliath-angry-v2.png');
        final reconstruction = await _decode('goliath-body-rig-v3.png');
        final mesh = GoliathSkinMesh();
        const size = Size(390, 844);
        for (final target in const [
          Offset(160, 180),
          Offset(225, 145),
          Offset(148, 92),
        ]) {
          final x = target.dx / 320 * 390;
          final y = target.dy / 420 * 844;
          final width = (390 * .78 * .75).clamp(
            0.0,
            ((382 - x) / .549).clamp(0.0, (x - 8) / .451),
          );
          final bounds = Rect.fromLTWH(
            x - width * .451,
            y - width / .75 * .115,
            width,
            width / .75,
          );
          Offset render(GoliathPoint p) => Offset(
            bounds.left + p.x * bounds.width,
            bounds.top + p.y * bounds.height,
          );
          for (final direction in [-1.0, 1.0]) {
            final model = GoliathMotionModel(
              idleMotion: false,
              minimumX: (8 - bounds.left) / bounds.width,
              maximumX: (382 - bounds.left) / bounds.width,
            );
            model.strikeHead(direction: direction);
            var elapsed = 0.0;
            for (var frame = 15; frame <= 90; frame++) {
              final time = frame / 30;
              while (elapsed + 1 / 120 <= time + .00001) {
                model.advance(1 / 120);
                elapsed += 1 / 120;
              }
              final pixels = await _raster(
                (canvas) => GoliathMeshPainter(
                  image: original,
                  reconstruction: reconstruction,
                  mesh: mesh,
                  pose: model.pose,
                  bounds: bounds,
                ).paint(canvas, size),
                size,
              );
              final components = _opaqueComponents(pixels, 390, 844);
              final body = components.largest;
              for (final joint in [
                GoliathJoint.leftKnee,
                GoliathJoint.rightKnee,
                GoliathJoint.leftAnkle,
                GoliathJoint.rightAnkle,
              ]) {
                final point = render(model.pose[joint]);
                expect(
                  components.nearest(point),
                  body,
                  reason:
                      'Visible $joint detached at target=$target direction=$direction time=$time',
                );
              }
              final pelvis = model.pose.boneTransform(
                GoliathJoint.leftHip,
                GoliathJoint.rightHip,
              );
              for (final left in [false, true]) {
                final shin = model.pose.boneTransform(
                  left ? GoliathJoint.leftKnee : GoliathJoint.rightKnee,
                  left ? GoliathJoint.leftAnkle : GoliathJoint.rightAnkle,
                );
                final hem = render(
                  pelvis.transformPoint(
                    GoliathPoint(
                      (left ? 379 : 601) / 1086,
                      (left ? 971 : 971) / 1448,
                    ),
                  ),
                );
                final knee = render(
                  shin.transformPoint(
                    GoliathPoint(
                      (left ? 343 : 611) / 1086,
                      (left ? 1014 : 1041) / 1448,
                    ),
                  ),
                );
                for (final fraction in [.2, .4, .6, .8]) {
                  final point = Offset.lerp(hem, knee, fraction)!;
                  expect(
                    _nearAlpha(pixels, 390, 844, point, 1),
                    greaterThan(64),
                    reason:
                        'Transparent ${left ? 'left' : 'right'} thigh/metal join target=$target direction=$direction time=$time fraction=$fraction at $point',
                  );
                }
              }
              for (final left in [false, true]) {
                final shin = model.pose.boneTransform(
                  left ? GoliathJoint.leftKnee : GoliathJoint.rightKnee,
                  left ? GoliathJoint.leftAnkle : GoliathJoint.rightAnkle,
                );
                final foot = model.pose.boneTransform(
                  left ? GoliathJoint.leftAnkle : GoliathJoint.rightAnkle,
                  left ? GoliathJoint.leftToe : GoliathJoint.rightToe,
                );
                final cuff = render(
                  shin.transformPoint(
                    GoliathPoint(
                      (left ? 338 : 665) / 1086,
                      (left ? 1267 : 1284) / 1448,
                    ),
                  ),
                );
                final sandal = render(
                  foot.transformPoint(
                    GoliathPoint(
                      (left ? 338 : 655) / 1086,
                      (left ? 1285 : 1308) / 1448,
                    ),
                  ),
                );
                for (final fraction in [.25, .5, .75]) {
                  final point = Offset.lerp(cuff, sandal, fraction)!;
                  expect(
                    _nearAlpha(pixels, 390, 844, point, 1),
                    greaterThan(64),
                    reason:
                        'Transparent ${left ? 'left' : 'right'} ankle join target=$target direction=$direction time=$time at $point',
                  );
                }
              }
              expect(
                components.sizes.where((area) => area >= 18).length,
                1,
                reason:
                    'Detached opaque limb fragment target=$target direction=$direction time=$time sizes=${components.sizes}',
              );
            }
          }
        }
        original.dispose();
        reconstruction.dispose();
      });
    },
  );
}

Future<ui.Image> _decode(String asset) async {
  final codec = await ui.instantiateImageCodec(
    await File('assets/images/games/$asset').readAsBytes(),
  );
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

Future<ByteData> _raster(void Function(Canvas) paint, Size size) async {
  final recorder = ui.PictureRecorder();
  paint(Canvas(recorder));
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  final pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  image.dispose();
  picture.dispose();
  return pixels;
}

class _Components {
  _Components(this.labels, this.sizes, this.width, this.height);
  final Int32List labels;
  final List<int> sizes;
  final int width, height;
  int get largest {
    var best = 1;
    for (var i = 1; i < sizes.length; i++) {
      if (sizes[i] > sizes[best - 1]) best = i + 1;
    }
    return best;
  }

  int nearest(Offset point) {
    for (var radius = 0; radius <= 3; radius++) {
      for (var dy = -radius; dy <= radius; dy++) {
        for (var dx = -radius; dx <= radius; dx++) {
          final x = point.dx.round() + dx;
          final y = point.dy.round() + dy;
          if (x >= 0 &&
              x < width &&
              y >= 0 &&
              y < height &&
              labels[y * width + x] > 0) {
            return labels[y * width + x];
          }
        }
      }
    }
    return 0;
  }
}

_Components _opaqueComponents(ByteData pixels, int width, int height) {
  final labels = Int32List(width * height);
  final sizes = <int>[];
  final queue = Int32List(width * height);
  for (var index = 0; index < labels.length; index++) {
    if (labels[index] != 0 || pixels.getUint8(index * 4 + 3) <= 64) continue;
    final label = sizes.length + 1;
    labels[index] = label;
    var head = 0;
    var tail = 1;
    queue[0] = index;
    while (head < tail) {
      final current = queue[head++];
      final x = current % width;
      final y = current ~/ width;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final nx = x + dx;
          final ny = y + dy;
          if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
          final neighbour = ny * width + nx;
          if (labels[neighbour] == 0 &&
              pixels.getUint8(neighbour * 4 + 3) > 64) {
            labels[neighbour] = label;
            queue[tail++] = neighbour;
          }
        }
      }
    }
    sizes.add(tail);
  }
  return _Components(labels, sizes, width, height);
}

int _nearAlpha(
  ByteData pixels,
  int width,
  int height,
  Offset point,
  int radius,
) {
  var maximum = 0;
  for (var dy = -radius; dy <= radius; dy++) {
    for (var dx = -radius; dx <= radius; dx++) {
      final x = point.dx.round() + dx;
      final y = point.dy.round() + dy;
      if (x >= 0 && x < width && y >= 0 && y < height) {
        final alpha = pixels.getUint8((y * width + x) * 4 + 3);
        if (alpha > maximum) maximum = alpha;
      }
    }
  }
  return maximum;
}

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/milestones/presentation/milestone_reveal_graphics.dart';

import 'support/staged_milestone_asset_bundle.dart';

void main() {
  testWidgets('normal app bundle excludes held milestone artwork', (
    tester,
  ) async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    expect(
      manifest.listAssets().where(
        (asset) => asset.startsWith('assets/images/milestones/'),
      ),
      isEmpty,
    );
  });

  testWidgets(
    'transparent box frames retain alpha and stop on the final frame',
    (tester) async {
      await tester.runAsync(() async {
        final bundle = _MemoryBundle(_manifest(), await _atlas());
        final graphics = await MilestoneRevealGraphics.load(
          bundle: bundle,
          manifestAsset: 'reveal.json',
        );
        try {
          expect(graphics.frameCount, 2);
          expect(graphics.badgeEmergenceAnchor, const ui.Offset(0.5, 0.54));
          expect(graphics.badgeAnchor, const ui.Offset(0.46, 0.1));
          expect(graphics.frameIndexAt(-1), 0);
          expect(graphics.frameIndexAt(1), 1);
          expect(graphics.frameIndexAt(20), 1);
          expect(bundle.loads, ['reveal.json', 'atlas.png']);
          for (final progress in [0.0, 1.0]) {
            final recorder = ui.PictureRecorder();
            graphics.drawFrame(
              ui.Canvas(recorder),
              progress,
              const ui.Rect.fromLTWH(0, 0, 8, 8),
            );
            final picture = recorder.endRecording();
            final raster = await picture.toImage(8, 8);
            try {
              final pixels = (await raster.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              expect(pixels.getUint8(3), 0);
              final center = (4 * 8 + 4) * 4;
              expect(pixels.getUint8(center + (progress == 0 ? 0 : 1)), 255);
              expect(pixels.getUint8(center + 3), 255);
            } finally {
              raster.dispose();
              picture.dispose();
            }
          }
        } finally {
          graphics.dispose();
          graphics.dispose();
        }
        expect(graphics.isDisposed, isTrue);
      });
    },
  );

  test(
    'malformed reveal grids and timing fail before loading textures',
    () async {
      for (final change in <Map<String, dynamic>>[
        {'cellWidth': 4097},
        {'columns': 1000},
        {'frameCount': 3},
        {
          'badgeAnchor': [0.5, 2],
        },
        {
          'timings': {'badgeStart': 3, 'badgeEnd': 2},
        },
        {
          'atlases': [
            {'asset': 'atlas.png', 'firstFrame': 1, 'frameCount': 2},
          ],
        },
      ]) {
        final manifest = {..._manifest(), ...change};
        final bundle = _MemoryBundle(manifest);
        await expectLater(
          MilestoneRevealGraphics.load(
            bundle: bundle,
            manifestAsset: 'reveal.json',
          ),
          throwsFormatException,
        );
        expect(bundle.loads, ['reveal.json']);
      }
    },
  );

  testWidgets('staged review gift decodes within the mobile texture budget', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final graphics = await MilestoneRevealGraphics.load(
        bundle: StagedMilestoneAssetBundle(),
      );
      try {
        expect(graphics.cellWidth, 352);
        expect(graphics.cellHeight, 352);
        expect(graphics.columns, 10);
        expect(graphics.frameCount, 80);
        expect(graphics.durationSeconds, 4);
        expect(graphics.frameIndexAt(1), 79);
        expect(graphics.badgeStartSeconds, 2.0);
        expect(graphics.badgeEndSeconds, 2.8);
        expect(graphics.posterAsset, milestoneRevealPosterAsset);
      } finally {
        graphics.dispose();
      }
    });
  });
}

Map<String, dynamic> _manifest() => {
  'version': 1,
  'cellWidth': 8,
  'cellHeight': 8,
  'columns': 2,
  'frameCount': 2,
  'durationSeconds': 4,
  'atlases': [
    {'asset': 'atlas.png', 'firstFrame': 0, 'frameCount': 2},
  ],
};

class _MemoryBundle extends CachingAssetBundle {
  _MemoryBundle(Map<String, dynamic> manifest, [ByteData? atlas])
    : _assets = {
        'reveal.json': ByteData.sublistView(
          Uint8List.fromList(utf8.encode(jsonEncode(manifest))),
        ),
        'atlas.png': ?atlas,
      };

  final Map<String, ByteData> _assets;
  final loads = <String>[];

  @override
  Future<ByteData> load(String key) async {
    loads.add(key);
    return _assets[key] ?? (throw StateError('Missing test asset $key'));
  }
}

Future<ByteData> _atlas() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  for (var frame = 0; frame < 2; frame++) {
    canvas.drawRect(
      ui.Rect.fromLTWH(frame * 8.0 + 2, 2, 4, 4),
      ui.Paint()
        ..color = frame == 0
            ? const ui.Color(0xFFFF0000)
            : const ui.Color(0xFF00FF00),
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(16, 8);
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.png))!;
  } finally {
    image.dispose();
    picture.dispose();
  }
}

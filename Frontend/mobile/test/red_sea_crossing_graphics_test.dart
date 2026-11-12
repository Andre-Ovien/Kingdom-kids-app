import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/red_sea_crossing_engine.dart';
import 'package:mobile/features/games/presentation/red_sea_crossing_graphics.dart';

void main() {
  testWidgets(
    'decoded frames preserve foot position and share one atlas allocation',
    (tester) async {
      await tester.runAsync(() async {
        final bundle = _bundle(await _png(), {
          'once': _clip(),
          'loop': _clip(loop: true),
        });
        final graphics = await RedSeaCrossingGraphics.load(
          'scene.json',
          bundle: bundle,
        );
        try {
          expect(graphics.clipNames.toSet(), {'once', 'loop'});
          expect(graphics.clip('missing'), isNull);
          final once = graphics.clip('once')!;
          final loop = graphics.clip('loop')!;
          expect(once.image, same(loop.image));
          expect(bundle.loads.where((key) => key == 'atlas.png'), hasLength(1));
          expect(graphics.totalDecodedBytes, 16 * 16 * 4);
          expect(once.fps, 4);
          expect(loop.frameIndexAt(1.5), 2);
          expect(once.frameIndexAt(1.5), 3);
          expect(once.frameIndexAt(-1), 0);

          const foot = ui.Offset(20, 20);
          const bodyHeight = 6.0;
          final scale = bodyHeight / once.bodyHeight!;
          final destination = ui.Rect.fromLTWH(
            foot.dx - once.footAnchor!.dx * scale,
            foot.dy - once.footAnchor!.dy * scale,
            once.cellWidth * scale,
            once.cellHeight * scale,
          );
          for (var index = 0; index < 4; index++) {
            final pixels = await _raster((canvas) {
              once.drawFrame(
                canvas,
                index / 4,
                destination,
                paint: ui.Paint()..filterQuality = ui.FilterQuality.none,
              );
            });
            expect(_pixel(pixels, 20, 18), _rgba(_colors[index]));
            expect(_pixel(pixels, 20, 19), [0, 0, 0, 255]);
            expect(_pixel(pixels, 20, 20).last, 0);
            expect(_pixel(pixels, 17, 18).last, 0);
          }
          final image = once.image;
          graphics.dispose();
          expect(image.debugDisposed, isTrue);
          expect(() => graphics.clip('once'), throwsStateError);
          expect(graphics.dispose, returnsNormally);
        } finally {
          graphics.dispose();
        }
      });
    },
  );

  testWidgets('out-of-atlas grids cannot decode or expose adjacent pixels', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final png = await _png();
      for (final bad in [
        {..._clip(), 'columns': 3},
        {..._clip(), 'frameCount': 5},
        {..._clip(), 'cellWidth': 4097},
      ]) {
        final created = <ui.Image>[];
        await _trackImages(created, () async {
          await expectLater(
            RedSeaCrossingGraphics.load(
              'scene.json',
              bundle: _bundle(png, {'bad': bad}),
            ),
            throwsA(isA<FormatException>()),
          );
        });
        expect(created, isEmpty);
      }
    });
  });

  testWidgets('invalid character anchors are rejected before image decoding', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final png = await _png();
      for (final bad in [
        {
          ..._clip(),
          'footAnchor': [-1, 7],
        },
        {
          ..._clip(),
          'footAnchor': [4, 9],
        },
        {
          ..._clip(),
          'footAnchor': [4],
        },
        {..._clip(), 'bodyHeight': 9},
        {..._clip(), 'bodyHeight': 0},
        {..._clip(), 'durationSeconds': 0},
      ]) {
        final created = <ui.Image>[];
        await _trackImages(created, () async {
          await expectLater(
            RedSeaCrossingGraphics.load(
              'scene.json',
              bundle: _bundle(png, {'bad': bad}),
            ),
            throwsA(isA<FormatException>()),
          );
        });
        expect(created, isEmpty);
      }
    });
  });

  testWidgets(
    'decoded memory budget rejects the first atlas before allocation',
    (tester) async {
      await tester.runAsync(() async {
        final bundle = _bundle(await _png(), {'once': _clip()});
        final created = <ui.Image>[];
        await _trackImages(created, () async {
          await expectLater(
            RedSeaCrossingGraphics.load(
              'scene.json',
              bundle: bundle,
              maximumDecodedBytes: 16 * 16 * 4 - 1,
            ),
            throwsA(isA<FormatException>()),
          );
        });
        expect(created, isEmpty);
      });
    },
  );

  testWidgets('a later missing atlas disposes earlier decoded images', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final bundle = _bundle(await _png(), {
        'valid': _clip(),
        'missing': _clip(asset: 'missing.png'),
      });
      final created = <ui.Image>[];
      await _trackImages(created, () async {
        await expectLater(
          RedSeaCrossingGraphics.load('scene.json', bundle: bundle),
          throwsStateError,
        );
      });
      expect(created, hasLength(1));
      expect(created.single.debugDisposed, isTrue);
    });
  });

  testWidgets('a later atlas over budget releases the earlier allocation', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final png = await _png();
      final bundle = _bundle(
        png,
        {'first': _clip(), 'second': _clip(asset: 'second.png')},
        additionalAssets: {'second.png': png},
      );
      final created = <ui.Image>[];
      await _trackImages(created, () async {
        await expectLater(
          RedSeaCrossingGraphics.load(
            'scene.json',
            bundle: bundle,
            maximumDecodedBytes: 16 * 16 * 4,
          ),
          throwsA(isA<FormatException>()),
        );
      });
      expect(created, hasLength(1));
      expect(created.single.debugDisposed, isTrue);
    });
  });

  testWidgets('unmounting an engine preserves caller-owned graphics', (
    tester,
  ) async {
    final graphics = await tester.runAsync(() async {
      return RedSeaCrossingGraphics.load(
        'scene.json',
        bundle: _bundle(await _png(), {'moses_ready': _clip()}),
      );
    });
    expect(graphics, isNotNull);
    final image = graphics!.clip('moses_ready')!.image;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RedSeaCrossingEngine(
              level: _level,
              graphics: graphics,
              onComplete: (_) {},
              onExit: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(image.debugDisposed, isFalse);
      expect(graphics.clip('moses_ready'), isNotNull);
    } finally {
      graphics.dispose();
    }
    expect(image.debugDisposed, isTrue);
  });
}

const _colors = [
  ui.Color(0xFFFF0000),
  ui.Color(0xFF00FF00),
  ui.Color(0xFF0000FF),
  ui.Color(0xFFFFFF00),
];

Map<String, Object> _clip({String asset = 'atlas.png', bool loop = false}) => {
  'asset': asset,
  'cellWidth': 8,
  'cellHeight': 8,
  'columns': 2,
  'frameCount': 4,
  'footAnchor': [4, 7],
  'bodyHeight': 6,
  'durationSeconds': 1,
  'loop': loop,
};

_MemoryBundle _bundle(
  ByteData png,
  Map<String, Object> clips, {
  Map<String, ByteData> additionalAssets = const {},
}) => _MemoryBundle({
  'scene.json': ByteData.sublistView(
    Uint8List.fromList(utf8.encode(jsonEncode({'version': 1, 'clips': clips}))),
  ),
  'atlas.png': png,
  ...additionalAssets,
});

class _MemoryBundle extends CachingAssetBundle {
  _MemoryBundle(this.assets);
  final Map<String, ByteData> assets;
  final loads = <String>[];

  @override
  Future<ByteData> load(String key) async {
    loads.add(key);
    final data = assets[key];
    if (data == null) throw StateError('Missing test asset: $key');
    return data;
  }
}

Future<ByteData> _png() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  for (var index = 0; index < 4; index++) {
    final left = (index % 2 * 8).toDouble();
    final top = (index ~/ 2 * 8).toDouble();
    canvas.drawRect(
      ui.Rect.fromLTWH(left + 2, top + 1, 4, 6),
      ui.Paint()..color = _colors[index],
    );
    canvas.drawRect(
      ui.Rect.fromLTWH(left + 3, top + 6, 2, 1),
      ui.Paint()..color = const ui.Color(0xFF000000),
    );
  }
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(16, 16);
    return (await image.toByteData(format: ui.ImageByteFormat.png))!;
  } finally {
    image?.dispose();
    picture.dispose();
  }
}

Future<ByteData> _raster(void Function(ui.Canvas) draw) async {
  final recorder = ui.PictureRecorder();
  draw(ui.Canvas(recorder));
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(32, 32);
    return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  } finally {
    image?.dispose();
    picture.dispose();
  }
}

List<int> _pixel(ByteData pixels, int x, int y) => [
  for (var channel = 0; channel < 4; channel++)
    pixels.getUint8((y * 32 + x) * 4 + channel),
];

List<int> _rgba(ui.Color color) => [
  (color.r * 255).round(),
  (color.g * 255).round(),
  (color.b * 255).round(),
  (color.a * 255).round(),
];

Future<void> _trackImages(
  List<ui.Image> created,
  Future<void> Function() action,
) async {
  final previous = ui.Image.onCreate;
  ui.Image.onCreate = (image) {
    created.add(image);
    previous?.call(image);
  };
  try {
    await action();
  } finally {
    ui.Image.onCreate = previous;
  }
}

final _level = GameLevel(
  id: 'graphics-ownership',
  number: 1,
  title: 'A way through the sea',
  instructions: 'Help everyone onto the dry path.',
  maxScore: 100,
  config: {
    'crossing': {
      'time_limit_seconds': 45,
      'travellers': [
        for (var index = 1; index <= 6; index++) {'id': 'traveller-$index'},
      ],
      'drop_zone': {'left': .34, 'top': .43, 'right': .66, 'bottom': .70},
    },
  },
);

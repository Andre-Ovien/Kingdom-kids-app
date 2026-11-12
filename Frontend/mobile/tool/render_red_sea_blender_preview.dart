import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/theme.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/red_sea_crossing_engine.dart';
import 'package:mobile/features/games/presentation/red_sea_crossing_graphics.dart';
import 'package:mobile/features/games/presentation/red_sea_crossing_renderer.dart';

// A visual export harness for the real engine, with local fixture results.
// Run through flutter test; it never connects to or writes to the backend.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('render the Blender crossing through real drag gestures', (
    tester,
  ) async {
    const root = '/Volumes/ANDRE_DEV/Projects/Kingdom-kids-app';
    final count = int.parse(
      Platform.environment['RED_SEA_REVIEW_COUNT'] ?? '10',
    );
    if (![10, 15, 20].contains(count)) {
      throw ArgumentError('Review a round with 10, 15, or 20 travellers.');
    }
    final level = _level(count);
    final manifest =
        Platform.environment['RED_SEA_BLENDER_MANIFEST'] ??
        '$root/Motion/red-sea-blender-v1/graphics-manifest.json';
    final openStill = Platform.environment['RED_SEA_BLENDER_STILL'] == 'open';
    final destination = Directory(
      '$root/Motion/red-sea-blender-v1/review/'
      '${openStill ? 'composition-v3-$count' : 'flutter-frames-$count'}',
    );
    late RedSeaCrossingGraphics graphics;
    await tester.runAsync(() async {
      graphics = await RedSeaCrossingGraphics.load(
        manifest,
        bundle: _LocalAssets('$root/Frontend/mobile'),
      );
      await destination.create(recursive: true);
      for (final file in destination.listSync().whereType<File>()) {
        if (RegExp(r'/\d{5}\.png$').hasMatch(file.path)) await file.delete();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      // Widget tests otherwise replace text with the Ahem block font. Use
      // the same native iPhone font family as the app for this Mac export.
      await (FontLoader('Avenir Next')..addFont(
            File(
              '/System/Library/Fonts/Avenir Next.ttc',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundaryKey = GlobalKey();
    final results = <Map<String, dynamic>>[];
    final appTheme = buildKingdomKidsTheme();
    final previewTheme = appTheme.copyWith(
      filledButtonTheme: FilledButtonThemeData(
        style: appTheme.filledButtonTheme.style!.copyWith(
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontFamily: 'Avenir Next', fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: previewTheme,
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              padding: EdgeInsets.only(top: 47, bottom: 34),
            ),
            child: RepaintBoundary(
              key: boundaryKey,
              child: RedSeaCrossingEngine(
                level: level,
                graphics: graphics,
                onComplete: results.add,
                onExit: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    var frame = 0;
    Future<void> capture() async {
      await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${destination.path}/${frame.toString().padLeft(5, '0')}.png',
          ).writeAsBytes(data!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      frame += 1;
    }

    Future<void> step() async {
      await tester.pump(const Duration(microseconds: 41667));
      await capture();
    }

    if (openStill) {
      await tester.tap(find.byKey(const Key('red-sea-open')));
      await tester.pump();
      for (var i = 0; i < 66; i++) {
        await tester.pump(const Duration(microseconds: 41667));
      }
      await capture();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      graphics.dispose();
      return;
    }

    await capture();
    for (var i = 0; i < 18; i++) {
      await step();
    }
    await tester.tap(find.byKey(const Key('red-sea-open')));
    await tester.pump();
    for (var i = 0; i < 64; i++) {
      await step();
    }
    final board = find.byKey(const Key('red-sea-crossing-board'));
    final size = tester.getSize(board);
    final boardOffset = tester.getTopLeft(board);
    const dropTargets = [
      Offset(.30, .61),
      Offset(.70, .61),
      Offset(.40, .54),
      Offset(.60, .54),
      Offset(.47, .65),
      Offset(.54, .65),
    ];
    for (var index = 0; index < count; index++) {
      final foot = RedSeaCrossingPainter.queuePosition(index, count, size);
      final hitCenter = RedSeaCrossingPainter.queueHitCenter(
        index,
        count,
        size,
      );
      final pickupOffset = foot - hitCenter;
      final start = boardOffset + hitCenter;
      final end =
          boardOffset +
          Offset(
            dropTargets[index % dropTargets.length].dx * size.width,
            dropTargets[index % dropTargets.length].dy * size.height,
          ) -
          pickupOffset;
      final gesture = await tester.startGesture(start);
      await step();
      for (var move = 1; move <= 8; move++) {
        await gesture.moveTo(Offset.lerp(start, end, move / 8)!);
        await step();
      }
      await gesture.up();
      await step();
    }
    for (var i = 0; i < 180 && results.isEmpty; i++) {
      await step();
    }
    expect(results, hasLength(1));
    final result = results.single['crossing'] as Map;
    expect(result['placements'], hasLength(count));
    for (var i = 0; i < 16; i++) {
      await step();
    }
    await tester.runAsync(() async {
      await File(
        '${destination.parent.path}/review-metadata-$count.json',
      ).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'fps': 24,
          'frameCount': frame,
          'size': [390, 844],
          'decodedGraphicsBytes': graphics.totalDecodedBytes,
          'source':
              'Real RedSeaCrossingEngine with $count native drag gestures',
          'travellerCount': count,
          'timeLimitSeconds': level.config['crossing']['time_limit_seconds'],
          'backendWrites': false,
          'completedResults': results.length,
        }),
      );
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    graphics.dispose();
  });
}

class _LocalAssets extends CachingAssetBundle {
  _LocalAssets(this.root);
  final String root;
  @override
  Future<ByteData> load(String key) async {
    final bytes = await File(
      key.startsWith('/') ? key : '$root/$key',
    ).readAsBytes();
    return ByteData.sublistView(bytes);
  }
}

GameLevel _level(int count) => GameLevel(
  id: 'blender-crossing-review-$count',
  number: [10, 15, 20].indexOf(count) + 1,
  title: 'Make a way',
  instructions: 'Help everyone onto the dry path.',
  maxScore: 100,
  config: {
    'crossing': {
      'time_limit_seconds': switch (count) {
        10 => 45,
        15 => 30,
        _ => 15,
      },
      'travellers': [
        for (var i = 1; i <= count; i++)
          {'id': 'traveller-$i', 'label': 'Traveller $i'},
      ],
      'drop_zone': {
        'left': .34,
        'top': .43,
        'right': .66,
        'bottom': .70,
        'polygon': [
          [.43, .33],
          [.57, .33],
          [.705, .43],
          [.855, .70],
          [.145, .70],
          [.295, .43],
        ],
      },
    },
  },
);

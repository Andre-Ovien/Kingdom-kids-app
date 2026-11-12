// Review-only harness: GOLIATH_RENDER_REVIEW=true flutter test this file.
// Uses the real native engine, original textures, actual fonts and gestures.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/theme.dart';
import 'package:mobile/features/games/data/david_battle_audio.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/david_sling_engine.dart';
import 'package:mobile/features/games/presentation/goliath_mesh_renderer.dart';

void main() {
  testWidgets(
    'capture Blender fall on all three actual native placements',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.runAsync(() async {
        for (final spec in [
          ('Avenir Next', '/System/Library/Fonts/Avenir Next.ttc'),
          ('Helvetica Neue', '/System/Library/Fonts/HelveticaNeue.ttc'),
          (
            'MaterialIcons',
            '/opt/homebrew/Caskroom/flutter/3.44.1/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ),
        ]) {
          final f = File(spec.$2);
          if (f.existsSync()) {
            final loader = FontLoader(
              spec.$1,
            )..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
            await loader.load();
          }
        }
      });
      final out = Directory(
        '../../Motion/goliath-blender-fall-v1/native-review',
      )..createSync(recursive: true);
      final configs = <Map<String, dynamic>>[
        {
          'canvas': {'width': 320, 'height': 420},
          'target': {'x': 160, 'y': 180, 'radius': 58},
          'max_shots': 3,
          'obstacles': [],
        },
        {
          'canvas': {'width': 320, 'height': 420},
          'target': {'x': 225, 'y': 145, 'radius': 42},
          'max_shots': 3,
          'obstacles': [
            {'shape': 'circle', 'x': 100, 'y': 220, 'radius': 30},
          ],
        },
        {
          'canvas': {'width': 320, 'height': 420},
          'target': {'x': 148, 'y': 92, 'radius': 28},
          'max_shots': 2,
          'obstacles': [
            {'shape': 'circle', 'x': 70, 'y': 185, 'radius': 24},
            {'shape': 'circle', 'x': 255, 'y': 220, 'radius': 24},
          ],
        },
      ];
      final rows = <Map<String, dynamic>>[];
      for (var level = 0; level < configs.length; level++) {
        final dir = Directory('${out.path}/level${level + 1}')
          ..createSync(recursive: true);
        final key = GlobalKey();
        var completed = 0;
        final gameLevel = GameLevel(
          id: 'blender-native-${level + 1}',
          number: level + 1,
          title: 'David',
          instructions: '',
          maxScore: 100,
          config: configs[level],
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: buildKingdomKidsTheme(),
            home: Scaffold(
              body: RepaintBoundary(
                key: key,
                child: DavidSlingEngine(
                  level: gameLevel,
                  audio: const SilentDavidBattleAudio(),
                  onComplete: (_) => completed++,
                ),
              ),
            ),
          ),
        );
        for (var attempt = 0; attempt < 100; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (find
              .byKey(const Key('sling-goliath-mesh'))
              .evaluate()
              .isNotEmpty) {
            break;
          }
        }
        expect(find.byKey(const Key('sling-goliath-mesh')), findsOneWidget);
        GoliathMeshPainter mesh() =>
            tester
                    .widget<CustomPaint>(
                      find.descendant(
                        of: find.byKey(const Key('sling-goliath-mesh')),
                        matching: find.byType(CustomPaint),
                      ),
                    )
                    .painter!
                as GoliathMeshPainter;
        final geometry = DavidSlingGeometry.fromLevel(gameLevel);
        final pull = Offset(
          (geometry.pouch.dx - geometry.target.dx) / 4,
          (geometry.pouch.dy + 420 * .12 - geometry.target.dy) / 4,
        );
        var frame = 0;
        double? impactAt, contactAt, settledAt, completionAt;
        final marks = <String>{};
        Future<void> capture() async {
          final p = mesh().pose;
          final name = 'frame_${frame.toString().padLeft(4, '0')}.png';
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            File('${dir.path}/$name').writeAsBytesSync(
              data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            );
            image.dispose();
          });
          if (p.elapsedSeconds > 0) impactAt ??= frame / 30;
          if (p.isGrounded) contactAt ??= frame / 30;
          if (p.isSettled) settledAt ??= frame / 30;
          if (completed > 0) completionAt ??= frame / 30;
          for (final marker in <String, double>{
            'standing': -1,
            'reaction': .05,
            'buckle': .35,
            'fall': .75,
            'contact': 1.14,
            'landing': 1.50,
            'settled': 2.20,
          }.entries) {
            if (!marks.contains(marker.key) &&
                (marker.value < 0 || p.elapsedSeconds >= marker.value)) {
              marks.add(marker.key);
              File(
                '${dir.path}/$name',
              ).copySync('${out.path}/level${level + 1}-${marker.key}.png');
            }
          }
          frame++;
        }

        await capture();
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(microseconds: 33333));
          await capture();
        }
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('sling-stone-pickup'))),
        );
        await gesture.moveBy(Offset(pull.dx * 390 / 320, pull.dy * 844 / 420));
        await tester.pump();
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(microseconds: 33333));
          await capture();
        }
        await gesture.up();
        await tester.pump();
        for (var i = 0; i < 150; i++) {
          await tester.pump(const Duration(microseconds: 33333));
          await capture();
        }
        expect(mesh().pose.isSettled, true);
        expect(completed, 1);
        rows.add({
          'level': level + 1,
          'target': configs[level]['target'],
          'native_frames': frame,
          'fps': 30,
          'impact_seconds': impactAt,
          'ground_support_seconds': contactAt,
          'settled_seconds': settledAt,
          'completion_seconds': completionAt,
          'actor_bounds': mesh().bounds.toString(),
          'source':
              'Real DavidSlingEngine, actual native mesh, original artwork/background/positions, original gesture and fonts; completion callback recorded without external writes',
        });
        debugPrint(
          'GOLIATH_REVIEW_LEVEL_${level + 1}: $frame native frames saved',
        );
        await tester.pumpWidget(const SizedBox());
      }
      File(
        '${out.path}/native-review-timings.json',
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(rows));
      expect(tester.takeException(), isNull);
    },
    skip: Platform.environment['GOLIATH_RENDER_REVIEW'] != 'true',
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

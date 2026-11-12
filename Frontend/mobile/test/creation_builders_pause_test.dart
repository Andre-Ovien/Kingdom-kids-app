import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/creation_world_engine.dart';
import 'package:mobile/features/games/presentation/creation_world_graphics.dart';
import 'package:mobile/features/games/presentation/wise_builders_engine.dart';

Future<ui.Image> texture() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 32, 32),
    Paint()..color = Colors.green,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(32, 32);
  picture.dispose();
  return image;
}

GameLevel level(Map<String, dynamic> config) => GameLevel(
  id: 'living-test',
  number: 1,
  title: 'Living world',
  instructions: 'Build.',
  config: config,
  maxScore: 100,
);

void main() {
  testWidgets(
    'Creation parent pause blocks placement and day advancement, then resumes',
    (tester) async {
      final config = Map<String, dynamic>.from(
        (jsonDecode(
                  File(
                    'test/fixtures/creation_world_levels.json',
                  ).readAsStringSync(),
                )
                as Map)['1']
            as Map,
      );
      final image = await texture();
      Future<CreationWorldGraphics> loader(int _) async =>
          CreationWorldGraphics({
            for (final name in [
              'background',
              'empty',
              'light',
              'cloud',
              'water',
              'land',
              'forest',
            ])
              name: image.clone(),
          }, {});
      Future<void> pump(bool paused) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CreationWorldEngine(
                level: level(config),
                paused: paused,
                graphicsLoader: loader,
                onComplete: (_) {},
                onExit: () {},
              ),
            ),
          ),
        );
        await tester.pump();
      }

      await pump(true);
      final finish = find.widgetWithText(FilledButton, 'Finish day 1');
      expect(tester.widget<FilledButton>(finish).onPressed, isNull);
      await tester.tap(find.text('light'));
      await tester.tapAt(const Offset(64, 223));
      await tester.pump();
      expect(tester.widget<FilledButton>(finish).onPressed, isNull);
      await pump(false);
      await tester.tap(find.text('light'));
      await tester.tapAt(const Offset(64, 223));
      await tester.pump();
      expect(tester.widget<FilledButton>(finish).onPressed, isNotNull);
      await pump(true);
      expect(tester.widget<FilledButton>(finish).onPressed, isNull);
      await pump(false);
      await tester.tap(finish);
      await tester.pump();
      expect(find.textContaining('Day 2 •'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      image.dispose();
    },
  );
  testWidgets(
    'Builders parent pause freezes foundation input and exit is available',
    (tester) async {
      final image = await texture();
      final config = {
        'mode': 'wise_builders',
        'builders': {
          'houses': [
            {'id': 'house-a', 'label': 'Little house'},
            {'id': 'house-b', 'label': 'Garden house'},
          ],
          'parts': [
            'back-wall',
            'left-wall',
            'right-wall',
            'front-wall',
            'roof',
          ],
          'storm': 'rain',
          'target_moves': 12,
        },
      };
      Future<Map<String, ui.Image>> loader() async => {
        for (final k in [
          'background',
          'rock',
          'sand',
          'back-wall',
          'left-wall',
          'right-wall',
          'front-wall',
          'roof',
          'standing',
          'collapse',
          'storm',
        ])
          k: image.clone(),
      };
      Future<void> pump(bool paused) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WiseBuildersEngine(
                level: level(config),
                paused: paused,
                graphicsLoader: loader,
                onComplete: (_) {},
                onExit: () {},
              ),
            ),
          ),
        );
        await tester.pump();
      }

      await pump(true);
      final rock = find.widgetWithText(ActionChip, 'Rock foundation');
      expect(tester.widget<ActionChip>(rock).onPressed, isNull);
      expect(find.byTooltip('Leave building'), findsOneWidget);
      await pump(false);
      expect(tester.widget<ActionChip>(rock).onPressed, isNotNull);
      await tester.tap(rock);
      await tester.pump();
      expect(find.textContaining('Now add walls'), findsOneWidget);
      await pump(true);
      expect(tester.widget<ActionChip>(rock).onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
      image.dispose();
    },
  );
}

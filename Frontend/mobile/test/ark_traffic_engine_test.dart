import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/theme.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/ark_traffic_engine.dart';
import 'package:mobile/features/games/presentation/ark_traffic_graphics.dart';
import 'package:mobile/features/games/presentation/ark_traffic_renderer.dart';

const _record = bool.fromEnvironment('RUN_ARK_TRAFFIC_VISUAL_REVIEW');

void main() {
  testWidgets('production graphics remain under48MiB and retain eight views', (
    tester,
  ) async {
    final graphics = await tester.runAsync(
      () => ArkTrafficGraphics.load(1, bundle: _FileBundle()),
    );
    expect(graphics!.decodedBytes, lessThan(48 * 1024 * 1024));
    for (final atlas in graphics.animals.values) {
      expect(atlas.directions, 8);
      expect(atlas.frames, 9);
      expect(atlas.image.width, 1440);
      expect(atlas.image.height, 1280);
    }
    expect(graphics.background.width, 960);
    expect(graphics.background.height, 1440);
    graphics.dispose();
    graphics.dispose();
  });
  testWidgets(
    'draw route, wait, parent pause and lifecycle resume keep replay state',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final graphics = await tester.runAsync(
        () => ArkTrafficGraphics.load(1, bundle: _FileBundle()),
      );
      var externallyPaused = false;
      late StateSetter refresh;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              refresh = setState;
              return Scaffold(
                body: ArkTrafficEngine(
                  level: _level(1),
                  paused: externallyPaused,
                  graphicsLoader: (_) => Future.value(graphics!),
                  onComplete: (_) {},
                  onExit: () {},
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('ark-traffic-start')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ark-traffic-start')));
      await tester.pump();
      await _draw(tester, 'goat-1', [
        'home-goat-1',
        'west-hub',
        'rock-in',
        'upper-west',
        'upper-hub',
        'ark',
      ]);
      final run = _painter(tester).run;
      expect(
        run.commands.any(
          (command) =>
              command['op'] == 'route' && command['animal_id'] == 'goat-1',
        ),
        isTrue,
      );
      expect(run.animal('goat-1')!.waiting, isFalse);
      final goat = run.animal('goat-1')!;
      await tester.tapAt(
        ArkTrafficPainter.animalPosition(
          goat,
          run.course,
          const Size(390, 844),
        ),
      );
      await tester.pump();
      expect(goat.waiting, isTrue);
      final tick = run.tick;
      final commands = run.commands.length;
      refresh(() => externallyPaused = true);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(run.tick, tick);
      expect(run.commands.length, commands);
      expect(goat.waiting, isTrue);
      refresh(() => externallyPaused = false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 200));
      expect(run.tick, greaterThan(tick));
      expect(goat.waiting, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      final pausedTick = run.tick;
      await tester.pump(const Duration(seconds: 1));
      expect(run.tick, pausedTick);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('Resume rescue'), findsOneWidget);
      await tester.tap(find.text('Resume rescue'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 200));
      expect(run.tick, greaterThan(pausedTick));
      expect(goat.waiting, isTrue);
      expect(run.result.keys.toSet(), {'commands', 'elapsed_ticks'});
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('parent overlay preserves a route draft and the temporary wait', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final graphics = await tester.runAsync(
      () => ArkTrafficGraphics.load(1, bundle: _FileBundle()),
    );
    var paused = false;
    late StateSetter refresh;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            refresh = setState;
            return Scaffold(
              body: ArkTrafficEngine(
                level: _level(1),
                paused: paused,
                graphicsLoader: (_) => Future.value(graphics!),
                onComplete: (_) {},
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('ark-traffic-start')));
    await tester.pump();
    final run = _painter(tester).run;
    final goat = run.animal('goat-1')!;
    final gesture = await tester.startGesture(
      ArkTrafficPainter.animalPosition(goat, run.course, const Size(390, 844)),
    );
    await gesture.moveBy(const Offset(0, -24));
    await tester.pump();
    await gesture.moveTo(
      ArkTrafficPainter.point(
        run.course.nodes['west-hub']!,
        const Size(390, 844),
      ),
    );
    await tester.pump();
    final draft = List<String>.of(_painter(tester).draft);
    expect(draft.length, greaterThan(1));
    expect(goat.waiting, isTrue);
    refresh(() => paused = true);
    await tester.pump();
    final tick = run.tick;
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
    expect(run.tick, tick);
    expect(_painter(tester).draft, draft);
    expect(goat.waiting, isTrue);
    refresh(() => paused = false);
    await tester.pump();
    expect(_painter(tester).draft, draft);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'record the native full-screen route wait and boarding preview',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final directory = Directory(
        '../../Motion/ark-traffic-blender-v1/review/native',
      );
      final frames = Directory('${directory.path}/frames');
      await tester.runAsync(() => frames.create(recursive: true));
      await tester.runAsync(() async {
        final font = FontLoader('Avenir Next')
          ..addFont(
            File(
              '/System/Library/Fonts/Avenir Next.ttc',
            ).readAsBytes().then(ByteData.sublistView),
          );
        await font.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      });
      final graphics = await tester.runAsync(
        () => ArkTrafficGraphics.load(1, bundle: _FileBundle()),
      );
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildKingdomKidsTheme(),
          home: Scaffold(
            body: RepaintBoundary(
              key: boundary,
              child: ArkTrafficEngine(
                level: _level(1),
                graphicsLoader: (_) => Future.value(graphics!),
                onComplete: (_) {},
                onExit: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await _capture(tester, boundary, '${directory.path}/ready.png');
      await tester.tap(find.byKey(const Key('ark-traffic-start')));
      await tester.pump();
      TestGesture? goatGesture;
      const goatPath = [
        'west-hub',
        'rock-in',
        'upper-west',
        'upper-hub',
        'ark',
      ];
      for (var frame = 0; frame <= 300; frame++) {
        if (frame > 0) await tester.pump(const Duration(milliseconds: 100));
        if (frame == 8) await _tapAnimal(tester, 'elephant-2');
        if (frame == 16) {
          final run = _painter(tester).run;
          goatGesture = await tester.startGesture(
            ArkTrafficPainter.animalPosition(
              run.animal('goat-1')!,
              run.course,
              const Size(390, 844),
            ),
          );
          await goatGesture.moveBy(const Offset(0, -24));
          await tester.pump();
        }
        if (frame >= 18 && frame <= 26 && frame.isEven) {
          final run = _painter(tester).run;
          await goatGesture!.moveTo(
            ArkTrafficPainter.point(
              run.course.nodes[goatPath[(frame - 18) ~/ 2]]!,
              const Size(390, 844),
            ),
          );
          await tester.pump();
        }
        if (frame == 30) {
          await goatGesture!.up();
          await tester.pump();
        }
        if (frame == 38) {
          await _draw(tester, 'elephant-1', [
            'bridge-in',
            'bridge-out',
            'upper-hub',
            'ark',
          ]);
        }
        if (frame == 50) {
          await _draw(tester, 'tortoise-1', ['bridge-out', 'upper-hub', 'ark']);
        }
        if (frame == 70) await _tapAnimal(tester, 'elephant-2');
        if (frame == 85) {
          await _draw(tester, 'rabbit-1', [
            'home-rabbit-1',
            'east-in',
            'east-out',
            'upper-hub',
            'ark',
          ]);
        }
        if (frame == 120 &&
            !_painter(tester).run.animal('elephant-1')!.waiting) {
          await _tapAnimal(tester, 'elephant-1');
        }
        if (frame == 120 && !_painter(tester).run.animal('rabbit-1')!.waiting) {
          await _tapAnimal(tester, 'rabbit-1');
        }
        if (frame == 220 &&
            _painter(tester).run.animal('elephant-1')!.waiting) {
          await _tapAnimal(tester, 'elephant-1');
        }
        if (frame == 265 && _painter(tester).run.animal('rabbit-1')!.waiting) {
          await _tapAnimal(tester, 'rabbit-1');
        }
        await _capture(
          tester,
          boundary,
          '${frames.path}/frame_${frame.toString().padLeft(3, '0')}.png',
        );
        expect(tester.takeException(), isNull);
      }
      final run = _painter(tester).run;
      expect(run.boardedCount, greaterThanOrEqualTo(2));
      await tester.runAsync(
        () => File(
          '${directory.path}/interactive-replay.json',
        ).writeAsString(jsonEncode(run.result)),
      );
      await _capture(tester, boundary, '${directory.path}/boarded.png');
      await tester.pumpWidget(const SizedBox());
    },
    skip: !_record,
  );
  testWidgets(
    'record first and completed native states for all three Ark maps',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final directory = Directory(
        '../../Motion/ark-traffic-blender-v1/review/native',
      );
      await tester.runAsync(() => directory.create(recursive: true));
      await tester.runAsync(() async {
        final font = FontLoader('Avenir Next')
          ..addFont(
            File(
              '/System/Library/Fonts/Avenir Next.ttc',
            ).readAsBytes().then(ByteData.sublistView),
          );
        await font.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      });
      final proof =
          jsonDecode(
                File(
                  '../../Motion/ark-traffic-blender-v1/review/mobile-replay-proof.json',
                ).readAsStringSync(),
              )
              as Map;
      for (var number = 1; number <= 3; number++) {
        final graphics = await tester.runAsync(
          () => ArkTrafficGraphics.load(number, bundle: _FileBundle()),
        );
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildKingdomKidsTheme(),
            home: Scaffold(
              body: RepaintBoundary(
                key: boundary,
                child: ArkTrafficEngine(
                  key: ValueKey(number),
                  level: _level(number),
                  graphicsLoader: (_) => Future.value(graphics!),
                  onComplete: (_) {},
                  onExit: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.tap(find.byKey(const Key('ark-traffic-start')));
        await tester.pump();
        await _capture(
          tester,
          boundary,
          '${directory.path}/level-$number-first.png',
        );
        final run = _painter(tester).run;
        final result = (proof['$number'] as Map)['result'] as Map;
        final commands = (result['commands'] as List).cast<Map>();
        var commandIndex = 0;
        while (run.tick < (result['elapsed_ticks'] as int) - 1) {
          while (commandIndex < commands.length &&
              commands[commandIndex]['tick'] == run.tick) {
            final command = commands[commandIndex++];
            final accepted = switch (command['op']) {
              'route' => run.setRoute(
                command['animal_id'] as String,
                (command['nodes'] as List).cast<String>(),
              ),
              'wait' => run.setWaiting(command['animal_id'] as String, true),
              'resume' => run.setWaiting(command['animal_id'] as String, false),
              _ => run.toggleGate(command['gate_id'] as String),
            };
            expect(accepted, isTrue);
          }
          run.step();
        }
        await tester.pump(const Duration(milliseconds: 100));
        expect(run.complete, isTrue);
        await _capture(
          tester,
          boundary,
          '${directory.path}/level-$number-complete.png',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
    skip: !_record,
  );
}

ArkTrafficPainter _painter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((widget) => widget.painter)
    .whereType<ArkTrafficPainter>()
    .first;
GameLevel _level(int number) {
  final configs =
      jsonDecode(
            File(
              '../../Motion/ark-traffic-blender-v1/traffic-levels.json',
            ).readAsStringSync(),
          )
          as Map;
  return GameLevel(
    id: 'ark-traffic-review-$number',
    number: number,
    title: 'Animal traffic',
    instructions: 'Draw paths to the ark.',
    config: Map<String, dynamic>.from(configs['$number'] as Map),
    maxScore: 100,
  );
}

Future<void> _tapAnimal(WidgetTester tester, String id) async {
  final run = _painter(tester).run;
  await tester.tapAt(
    ArkTrafficPainter.animalPosition(
      run.animal(id)!,
      run.course,
      const Size(390, 844),
    ),
  );
  await tester.pump();
}

Future<void> _draw(
  WidgetTester tester,
  String animalId,
  List<String> route,
) async {
  final run = _painter(tester).run;
  final state = run.animal(animalId)!;
  final gesture = await tester.startGesture(
    ArkTrafficPainter.animalPosition(state, run.course, const Size(390, 844)),
  );
  await gesture.moveBy(const Offset(0, -24));
  await tester.pump(const Duration(milliseconds: 30));
  for (final id in route) {
    await gesture.moveTo(
      ArkTrafficPainter.point(run.course.nodes[id]!, const Size(390, 844)),
    );
    await tester.pump(const Duration(milliseconds: 40));
  }
  await gesture.up();
  await tester.pump();
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey boundary,
  String path,
) async {
  await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 2);
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File(path).writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  });
}

class _FileBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(await File(key).readAsBytes());
}

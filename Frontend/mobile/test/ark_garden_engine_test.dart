import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/ark_garden_model.dart';
import 'package:mobile/features/games/domain/ark_garden_projection.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/ark_garden_engine.dart';
import 'package:mobile/features/games/presentation/ark_garden_scene.dart';
import 'package:mobile/features/games/presentation/game_engines.dart';

void main() {
  testWidgets(
    'held art has no orientation effects; reviewed play restores the host policy',
    (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ArkGardenEngine(level: _level(), onComplete: (_) {}),
          ),
        ),
      );
      await tester.pump();
      expect(
        calls.where(
          (call) => call.method == 'SystemChrome.setPreferredOrientations',
        ),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ArkGardenEngine(
              level: _level(),
              scene: _TestScene(),
              onComplete: (_) {},
              restoreOrientations: const [DeviceOrientation.portraitUp],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(calls.last.arguments, [
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(calls.last.arguments, ['DeviceOrientation.portraitUp']);
    },
  );

  testWidgets(
    'multiple swipe updates between paints accumulate instead of overwriting',
    (tester) async {
      await _pump(tester);
      final gesture = tester.widget<GestureDetector>(
        find
            .ancestor(
              of: _paintFinder(),
              matching: find.byType(GestureDetector),
            )
            .first,
      );
      gesture.onHorizontalDragUpdate!(
        DragUpdateDetails(
          delta: const Offset(-30, 0),
          globalPosition: Offset.zero,
        ),
      );
      gesture.onHorizontalDragUpdate!(
        DragUpdateDetails(
          delta: const Offset(-40, 0),
          globalPosition: Offset.zero,
        ),
      );
      await tester.pump();
      expect(_painter(tester).viewport.panPixels, 70);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('slow foreground frames preserve the sixty-second deadline', (
    tester,
  ) async {
    final outcomes = <Map<String, dynamic>>[];
    await _pump(tester, onComplete: outcomes.add);
    final run = _painter(tester).run;
    await tester.pump(const Duration(seconds: 1));
    expect(run.tick, 10);
    await tester.pump(const Duration(seconds: 59));
    expect(run.tick, 600);
    expect(outcomes.single, {'taps': [], 'elapsed_ticks': 600});
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'normal mode dispatch stays held without reviewed art or a clock',
    (tester) async {
      var submitted = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GameLevelEngine(
              type: GameType.matching,
              level: _level(),
              onComplete: (_) => submitted++,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 70));
      expect(find.byKey(const Key('ark-garden-held')), findsOneWidget);
      expect(find.byKey(const Key('ark-garden-engine')), findsNothing);
      expect(find.textContaining('aboard'), findsNothing);
      expect(submitted, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'unreviewed or incomplete scene adapters cannot activate gameplay',
    (tester) async {
      for (final scene in [
        _TestScene(reviewed: false),
        _TestScene(species: {'elephant'}),
      ]) {
        await _pump(tester, scene: scene);
        await tester.pump(const Duration(seconds: 70));
        expect(find.byKey(const Key('ark-garden-held')), findsOneWidget);
        expect(find.byKey(const Key('ark-garden-engine')), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets(
    'tap starts one animal; horizontal swiping moves tap targets without boarding',
    (tester) async {
      await _pump(tester);
      final run = _painter(tester).run;
      final elephantFrame = _painter(
        tester,
      ).frames.firstWhere((frame) => frame.animal.id == 'elephant');
      await tester.tapAt(elephantFrame.feet);
      await _advance(tester, 2);
      expect(run.animal('elephant')!.tappedAtTick, 0);
      expect(run.animal('elephant')!.position.x, greaterThan(3));
      expect((run.result['taps'] as List).length, 1);
      final beforePan = _painter(tester).viewport.panPixels;
      await tester.drag(_paintFinder(), const Offset(-300, 0));
      await tester.pump();
      expect(_painter(tester).viewport.panPixels, greaterThan(beforePan));
      expect((run.result['taps'] as List).length, 1);
      final lionFrame = _painter(
        tester,
      ).frames.firstWhere((frame) => frame.animal.id == 'lion');
      await tester.tapAt(lionFrame.feet);
      await tester.pump();
      expect(run.animal('lion')!.tappedAtTick, isNotNull);
      expect((run.result['taps'] as List).length, 2);
      expect(run.boardedCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'host save or exit pause and lifecycle pause freeze the same run',
    (tester) async {
      var paused = false;
      late StateSetter refresh;
      _landscape(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              refresh = setState;
              return Scaffold(
                body: ArkGardenEngine(
                  level: _level(),
                  scene: _TestScene(),
                  paused: paused,
                  onComplete: (_) {},
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      final run = _painter(tester).run;
      run.tap('rabbit');
      await _advance(tester, 3);
      final tick = run.tick;
      final position = run.animal('rabbit')!.position;
      refresh(() => paused = true);
      await tester.pump();
      await _advance(tester, 10);
      expect(run.tick, tick);
      expect(run.animal('rabbit')!.position.x, position.x);
      expect(run.tap('lion'), isFalse);
      refresh(() => paused = false);
      await tester.pump();
      await _advance(tester, 3);
      expect(run.tick, greaterThan(tick));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      final lifecycleTick = run.tick;
      await _advance(tester, 10);
      expect(run.tick, lifecycleTick);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byKey(const Key('ark-garden-resume')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ark-garden-resume')));
      await tester.pump();
      await _advance(tester, 3);
      expect(run.tick, greaterThan(lifecycleTick));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'all ten disappear inside before exactly one completion callback',
    (tester) async {
      final outcomes = <Map<String, dynamic>>[];
      await _pump(tester, onComplete: outcomes.add);
      final run = _painter(tester).run;
      for (final animal in run.animals) {
        run.tap(animal.animal.id);
      }
      await _advance(tester, 600);
      expect(run.complete, isTrue);
      expect(_painter(tester).frames, isEmpty);
      expect(outcomes.length, 1);
      expect((outcomes.single['taps'] as List).length, 10);
      expect(outcomes.single['elapsed_ticks'], run.tick);
      await _advance(tester, 20);
      expect(outcomes.length, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'timeout saves a partial replay once and disposal never sends a result',
    (tester) async {
      final outcomes = <Map<String, dynamic>>[];
      await _pump(tester, onComplete: outcomes.add);
      await _advance(tester, 610);
      expect(outcomes.length, 1);
      expect(outcomes.single, {'taps': [], 'elapsed_ticks': 600});
      await tester.pumpWidget(const SizedBox());
      outcomes.clear();
      await _pump(tester, onComplete: outcomes.add);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 70));
      expect(outcomes, isEmpty);
    },
  );

  test(
    'door foreground occludes entry; elevated feet and grounded shadows stay distinct',
    () {
      final run = ArkGardenRun(ArkGardenCourse.fromConfig(_config()))
        ..start()
        ..tap('rabbit');
      while (run.animal('rabbit')!.pathPhase != ArkGardenPathPhase.interior) {
        run.step();
      }
      final scene = _TestScene();
      final viewport = ArkGardenViewport(
        course: run.course,
        width: 1000,
        height: 500,
        pan: 800,
      );
      final painter = ArkGardenPainter(
        run: run,
        scene: scene,
        viewport: viewport,
        reducedMotion: false,
      );
      final rabbit = painter.frames.firstWhere(
        (frame) => frame.animal.id == 'rabbit',
      );
      expect(rabbit.entering, isTrue);
      expect(rabbit.feet.dy, lessThan(rabbit.groundFeet.dy));
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(1000, 500));
      final picture = recorder.endRecording();
      expect(
        scene.events.indexOf('animal:rabbit'),
        lessThan(scene.events.indexOf('door')),
      );
      expect(
        scene.events.indexOf('animal:elephant'),
        greaterThan(scene.events.indexOf('door')),
      );
      expect(scene.events.first, 'world');
      expect(scene.events.last, 'foreground');
      while (!run.animal('rabbit')!.boarded) {
        run.step();
      }
      expect(
        painter.frames.any((frame) => frame.animal.id == 'rabbit'),
        isFalse,
      );
      picture.dispose();
    },
  );
}

Map<String, dynamic> _config() =>
    jsonDecode(File('test/fixtures/ark_garden_course.json').readAsStringSync())
        as Map<String, dynamic>;

GameLevel _level() => GameLevel(
  id: 'held-garden-test',
  number: 1,
  title: 'All aboard',
  instructions: 'Tap each animal to walk aboard.',
  config: _config(),
  maxScore: 100,
);

void _landscape(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _pump(
  WidgetTester tester, {
  ArkGardenScene? scene,
  void Function(Map<String, dynamic>)? onComplete,
}) async {
  _landscape(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ArkGardenEngine(
          level: _level(),
          scene: scene ?? _TestScene(),
          onComplete: onComplete ?? (_) {},
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder _paintFinder() => find.byWidgetPredicate(
  (widget) => widget is CustomPaint && widget.painter is ArkGardenPainter,
);
ArkGardenPainter _painter(WidgetTester tester) =>
    tester.widget<CustomPaint>(_paintFinder()).painter! as ArkGardenPainter;

Future<void> _advance(WidgetTester tester, int ticks) async {
  for (var i = 0; i < ticks; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
}

// Test-only adapter verifies paint ordering without manufacturing public art.
class _TestScene implements ArkGardenScene {
  _TestScene({this.reviewed = true, Set<String>? species})
    : species = species ?? arkGardenSpecies;
  @override
  final bool reviewed;
  @override
  final Set<String> species;
  final List<String> events = [];
  @override
  void paintWorld(Canvas canvas, ArkGardenViewport viewport, int sceneTick) {
    events.add('world');
  }

  @override
  void paintAnimal(Canvas canvas, ArkGardenAnimalFrame animal) {
    events.add('animal:${animal.animal.id}');
  }

  @override
  void paintDoorForeground(Canvas canvas, ArkGardenViewport viewport) {
    events.add('door');
  }

  @override
  void paintForeground(
    Canvas canvas,
    ArkGardenViewport viewport,
    int sceneTick,
  ) {
    events.add('foreground');
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/data/sailing_motion_input.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/storm_sailing_engine.dart';
import 'package:mobile/features/games/presentation/storm_sailing_model.dart';
import 'package:mobile/features/games/presentation/storm_sailing_renderer.dart';

void main() {
  setUpAll(() async {
    if (Platform.environment['SAILING_CAPTURE'] != '1') return;
    const directory =
        '/Users/macbook/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/libreoffice-headless/libreoffice/LibreOfficeDev.app/Contents/Resources/fonts/truetype';
    final font = FontLoader('Roboto');
    for (final name in ['NotoSans-Regular.ttf', 'NotoSans-Bold.ttf']) {
      final data = await File('$directory/$name').readAsBytes();
      font.addFont(Future.value(ByteData.sublistView(data)));
    }
    await font.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  group('continuous sailing run', () {
    test('600 active tenth-second steps record an exact complete minute', () {
      final run = SailingRun(const SailingCourse())..start();
      for (var frame = 0; frame < 600; frame++) {
        run.advance(.1, 0);
      }
      expect(run.elapsed, 60);
      expect(run.finished, isTrue);
      expect(run.remainingMetres, 0);
      final voyage = run.result()['voyage'] as Map;
      final samples = voyage['samples'] as List;
      expect(voyage['duration_ms'], 60000);
      expect(samples, hasLength(601));
      expect(samples.first, [0, 0.0]);
      expect(samples.last, [60000, 0.0]);
      for (var index = 0; index < samples.length; index++) {
        expect(samples[index], [index * 100, 0.0]);
      }
      expect(run.result().keys, ['voyage']);
    });

    test(
      'steering timeline stays finite, in bounds, and within server speed limits',
      () {
        final run = SailingRun(const SailingCourse())..start();
        for (var frame = 0; frame < 600; frame++) {
          run.advance(.1, math.sin(frame / 23) * 2);
          expect(run.x.isFinite, isTrue);
          expect(run.x.abs(), lessThanOrEqualTo(.96));
        }
        final samples = (run.result()['voyage'] as Map)['samples'] as List;
        for (var index = 1; index < samples.length; index++) {
          final previous = samples[index - 1] as List;
          final current = samples[index] as List;
          final seconds = ((current[0] as num) - (previous[0] as num)) / 1000;
          expect(seconds, .1);
          expect(
            ((current[1] as num) - (previous[1] as num)).abs(),
            lessThanOrEqualTo((run.course.steerSpeed + .02) * seconds),
          );
        }
      },
    );

    test('collisions match server evaluation and count each reef once', () {
      const course = SailingCourse(
        obstacles: [
          SailingObstacle(id: 'first', progress: .2, x: 0, radius: .14),
          SailingObstacle(id: 'second', progress: .4, x: 0, radius: .14),
          SailingObstacle(id: 'avoided', progress: .7, x: .75, radius: .14),
        ],
      );
      final run = SailingRun(course)..start();
      for (var frame = 0; frame < 600; frame++) {
        run.advance(.1, 0);
      }
      final samples = (run.result()['voyage'] as Map)['samples'] as List;
      final serverHits = _serverHitIds(course, samples);
      expect(run.hitIds, serverHits);
      expect(run.hitIds, {'first', 'second'});
      expect(run.hits, 2);
      expect(run.finished, isTrue);
    });

    test('a wreck cannot submit, and restarting clears all run state', () {
      final run = SailingRun(
        SailingCourse.fromLevel(_level(reefs: _centreReefs)),
      )..start();
      for (var frame = 0; frame < 60; frame++) {
        run.advance(.1, 0);
      }
      expect(run.wrecked, isTrue);
      final stoppedAt = run.elapsed;
      run.advance(.1, 1);
      expect(run.elapsed, stoppedAt);
      expect(run.result, throwsStateError);
      run.start();
      expect(run.elapsed, 0);
      expect(run.x, 0);
      expect(run.velocity, 0);
      expect(run.hitIds, isEmpty);
      expect(run.active, isTrue);
      expect(run.result, throwsStateError);
    });

    test(
      'an authored-course voyage exports the actual server-bound timeline',
      () {
        final run = SailingRun(
          SailingCourse.fromLevel(_level(reefs: _authoredReefs)),
        )..start();
        for (var frame = 0; frame < 600; frame++) {
          run.advance(.1, (.45 - run.x) * 6);
        }
      expect(run.finished, isTrue);
      expect(run.wrecked, isFalse);
      expect(run.hitIds, {'rock-6', 'rock-8'});
        final result = run.result();
        final samples = (result['voyage'] as Map)['samples'] as List;
        expect(samples, hasLength(601));
        expect(_serverHitIds(run.course, samples), run.hitIds);
        if (Platform.environment['SAILING_CAPTURE'] == '1') {
          File(
            '/tmp/kingdom-kids-sailing-client-result.json',
          ).writeAsStringSync(jsonEncode(result));
        }
      },
    );

    test(
      'a frame hitch slows play and non-finite controls cannot poison movement',
      () {
        final run = SailingRun(const SailingCourse())..start();
        run.advance(45, 1);
        expect(run.elapsed, closeTo(.1, .000001));
        run.advance(double.nan, 1);
        run.advance(-1, 1);
        expect(run.elapsed, closeTo(.1, .000001));
        run.advance(.1, double.nan);
        expect(run.x.isFinite, isTrue);
        expect(run.velocity.isFinite, isTrue);
      },
    );
  });

  group('sailing engine controls and lifecycle', () {
    testWidgets(
      'a full minute completes once after the arrival, never while ready',
      (tester) async {
        final motion = _FakeMotionInput();
        final completed = <Map<String, dynamic>>[];
        await _pumpEngine(tester, motion, completed);
        await _frames(tester, 10);
        expect(_run(tester).elapsed, 0);
        expect(completed, isEmpty);
        await _start(tester);
        await _frames(tester, 599);
        expect(_run(tester).elapsed, closeTo(59.9, .000001));
        expect(completed, isEmpty);
        await _frames(tester, 1);
        expect(_run(tester).elapsed, 60);
        expect(completed, isEmpty);
        await _frames(tester, 14);
        expect(completed, hasLength(1));
        final voyage = completed.single['voyage'] as Map;
        expect(voyage['duration_ms'], 60000);
        expect(voyage['samples'] as List, hasLength(601));
        await _frames(tester, 20);
        expect(completed, hasLength(1));
        expect(motion.cancellations, 1);
        await _dispose(tester, motion);
      },
    );

    testWidgets(
      'pause and app background freeze active time and release the sensor',
      (tester) async {
        final motion = _FakeMotionInput();
        var paused = false;
        late StateSetter change;
        await _pumpEngine(
          tester,
          motion,
          [],
          wrap: (child) => StatefulBuilder(
            builder: (context, setState) {
              change = setState;
              return StormSailingEngine(
                level: _level(),
                motionInput: motion,
                paused: paused,
                onComplete: (_) {},
                onExit: () {},
              );
            },
          ),
        );
        await _start(tester);
        await _frames(tester, 10);
        final beforePause = _run(tester).elapsed;
        change(() => paused = true);
        await tester.pump();
        await _frames(tester, 50);
        expect(_run(tester).elapsed, beforePause);
        expect(motion.cancellations, 1);
        change(() => paused = false);
        await tester.pump();
        await _frames(tester, 1);
        final resumedAt = _run(tester).elapsed;
        expect(resumedAt - beforePause, lessThanOrEqualTo(.100001));
        await _frames(tester, 10);
        expect(_run(tester).elapsed, closeTo(resumedAt + 1, .000001));
        expect(motion.listens, 2);
        addTearDown(
          () => tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          ),
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        final beforeBackground = _run(tester).elapsed;
        await _frames(tester, 40);
        expect(_run(tester).elapsed, beforeBackground);
        expect(motion.cancellations, 2);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await _frames(tester, 1);
        final foregroundAt = _run(tester).elapsed;
        expect(foregroundAt - beforeBackground, lessThanOrEqualTo(.100001));
        await _frames(tester, 10);
        expect(_run(tester).elapsed, closeTo(foregroundAt + 1, .000001));
        expect(motion.listens, 3);
        await _dispose(tester, motion);
        expect(motion.cancellations, 3);
      },
    );

    testWidgets(
      'unsupported motion falls back to a wheel that actually moves the boat',
      (tester) async {
        final motion = _FakeMotionInput();
        await _pumpEngine(tester, motion, []);
        motion.fail();
        await tester.pump();
        await _start(tester);
        expect(find.text('Touch'), findsOneWidget);
        expect(find.text('Drag the wheel to steer'), findsOneWidget);
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('sailing-steering'))),
        );
        await gesture.moveBy(const Offset(110, 0));
        await _frames(tester, 10);
        expect(_run(tester).x, greaterThan(.5));
        await gesture.up();
        await _dispose(tester, motion);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'tilt calibrates the held pose and right or left inputs steer consistently',
      (tester) async {
        final motion = _FakeMotionInput();
        await _pumpEngine(tester, motion, []);
        motion.emit(.22);
        await tester.pump();
        await _start(tester);
        for (var frame = 0; frame < 20; frame++) {
          motion.emit(.22);
          await tester.pump(const Duration(milliseconds: 33));
        }
        expect(_run(tester).x, closeTo(0, .000001));
        for (var frame = 0; frame < 30; frame++) {
          motion.emit(.48);
          await tester.pump(const Duration(milliseconds: 33));
        }
        expect(_run(tester).x, greaterThan(.3));
        final rightPosition = _run(tester).x;
        for (var frame = 0; frame < 50; frame++) {
          motion.emit(-.10);
          await tester.pump(const Duration(milliseconds: 33));
        }
        expect(_run(tester).x, lessThan(rightPosition));
        expect(_run(tester).x, lessThan(0));
        await _dispose(tester, motion);
      },
    );

    testWidgets(
      'a sensor stream ending resets steering and offers touch fallback',
      (tester) async {
        final motion = _FakeMotionInput();
        await _pumpEngine(tester, motion, []);
        motion.emit(0);
        await tester.pump();
        await _start(tester);
        for (var frame = 0; frame < 10; frame++) {
          motion.emit(.3);
          await tester.pump(const Duration(milliseconds: 33));
        }
        await motion.close();
        await tester.pump();
        expect(find.text('Touch'), findsOneWidget);
        await _frames(tester, 10);
        expect(_run(tester).velocity.abs(), lessThan(.001));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('three hits offer a fresh retry without submitting a reward', (
      tester,
    ) async {
      final motion = _FakeMotionInput();
      final completed = <Map<String, dynamic>>[];
      await _pumpEngine(
        tester,
        motion,
        completed,
        level: _level(reefs: _centreReefs),
      );
      await _start(tester);
      await _frames(tester, 60);
      expect(_run(tester).wrecked, isTrue);
      expect(find.byKey(const Key('sailing-retry')), findsOneWidget);
      expect(completed, isEmpty);
      await tester.tap(find.byKey(const Key('sailing-retry')));
      await tester.pump();
      expect(_run(tester).hits, 0);
      expect(_run(tester).elapsed, 0);
      expect(completed, isEmpty);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('sailing-steering'))),
      );
      await gesture.moveBy(const Offset(110, 0));
      await _frames(tester, 10);
      await gesture.up();
      await _frames(tester, 590);
      await _frames(tester, 14);
      expect(completed, hasLength(1));
      expect(_run(tester).hits, 0);
      await _dispose(tester, motion);
    });

    testWidgets(
      'portrait scene fills the screen and captures actual ready and sailing UI',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final motion = _FakeMotionInput();
        final boundary = GlobalKey();
        await _pumpEngine(
          tester,
          motion,
          [],
          boundary: boundary,
          level: _level(reefs: _authoredReefs),
        );
        expect(
          tester.getSize(find.byKey(const Key('sailing-scene'))),
          const Size(390, 844),
        );
        await _capture(tester, boundary, 'ready');
        await _start(tester);
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('sailing-steering'))),
        );
        await gesture.moveBy(const Offset(-50, 0));
        await _frames(tester, 8);
        await gesture.up();
        await _frames(tester, 50);
        await _capture(tester, boundary, 'playing');
        expect(find.byKey(const Key('sailing-start')), findsNothing);
        expect(find.byKey(const Key('sailing-steering')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _dispose(tester, motion);
      },
    );
  });
}

Future<void> _pumpEngine(
  WidgetTester tester,
  _FakeMotionInput motion,
  List<Map<String, dynamic>> completed, {
  GameLevel? level,
  GlobalKey? boundary,
  Widget Function(Widget)? wrap,
}) async {
  Widget engine = StormSailingEngine(
    level: level ?? _level(),
    motionInput: motion,
    onComplete: completed.add,
    onExit: () {},
  );
  if (wrap != null) engine = wrap(engine);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: RepaintBoundary(key: boundary, child: engine),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _start(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('sailing-start')));
  await tester.pump();
}

Future<void> _frames(WidgetTester tester, int count) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

SailingRun _run(WidgetTester tester) =>
    (tester.widget<CustomPaint>(find.byKey(const Key('sailing-scene'))).painter!
            as StormSailingPainter)
        .run;

Future<void> _dispose(WidgetTester tester, _FakeMotionInput motion) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await motion.close();
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (Platform.environment['SAILING_CAPTURE'] != '1') return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '/tmp/kingdom-kids-sailing-$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Set<String> _serverHitIds(SailingCourse course, List samples) => {
  for (final obstacle in course.obstacles)
    if (samples.any(
      (point) =>
          ((point[0] as num) / (course.durationSeconds * 1000) -
                      obstacle.progress)
                  .abs() <=
              course.collisionWindow &&
          ((point[1] as num) - obstacle.x).abs() <
              obstacle.radius + course.shipRadius,
    ))
      obstacle.id,
};

GameLevel _level({List<Map<String, Object>> reefs = const []}) => GameLevel(
  id: 'sailing-level-1',
  number: 1,
  title: 'Storm voyage',
  instructions: 'Steer to harbour.',
  maxScore: 100,
  config: {
    'sailing': {
      'duration_seconds': 60,
      'distance_m': 1200,
      'ship_radius': .09,
      'collision_window': .007,
      'max_hits': 3,
      'steer_speed': 1.4,
      'obstacles': reefs,
    },
  },
);

const _centreReefs = [
  {'id': 'one', 'progress': .04, 'x': 0.0, 'radius': .14},
  {'id': 'two', 'progress': .06, 'x': 0.0, 'radius': .14},
  {'id': 'three', 'progress': .08, 'x': 0.0, 'radius': .14},
];
final _authoredReefs = [
  for (var i = 0; i < 12; i++)
    {
      'id': 'rock-${i + 1}',
      'progress': .15 + .7 * i / 11,
      'x': [0.0, .74, -.74, .2, -.25, .65, -.6, .38, -.38, .8, -.8, .08][i],
      'radius': .14,
    },
];

class _FakeMotionInput implements SailingMotionInput {
  _FakeMotionInput() {
    controller = StreamController<double>.broadcast(
      onListen: () => listens++,
      onCancel: () => cancellations++,
    );
  }
  late final StreamController<double> controller;
  int listens = 0;
  int cancellations = 0;
  @override
  Stream<double> get tilt => controller.stream;
  void emit(double value) => controller.add(value);
  void fail() => controller.addError(UnsupportedError('No sensor'));
  Future<void> close() =>
      controller.isClosed ? Future<void>.value() : controller.close();
}

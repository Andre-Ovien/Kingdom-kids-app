import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/data/david_battle_audio.dart';
import 'package:mobile/features/games/presentation/david_sling_engine.dart';
import 'package:mobile/features/games/presentation/goliath_mesh_renderer.dart';
import 'package:mobile/features/games/presentation/goliath_motion_model.dart';

GameLevel _level({
  int shots = 3,
  List<Map<String, dynamic>> obstacles = const [],
}) => GameLevel(
  id: 'sling-1',
  number: 1,
  title: 'Small stone, giant courage',
  instructions: 'Pull, aim and release.',
  maxScore: 100,
  config: {
    'canvas': {'width': 320, 'height': 420},
    'target': {'x': 160, 'y': 180, 'radius': 28},
    'max_shots': shots,
    'obstacles': obstacles,
  },
);

const _authoredConfigs = [
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

GameLevel _authoredLevel(int index) => GameLevel(
  id: 'authored-$index',
  number: index + 1,
  title: 'David',
  instructions: '',
  maxScore: 100,
  config: _authoredConfigs[index],
);

void main() {
  testWidgets(
    'all authored targets anchor the same continuous mesh and fit before impact',
    (tester) async {
      for (var index = 0; index < _authoredConfigs.length; index++) {
        final level = _authoredLevel(index);
        await _pump(tester, level, (_) {}, reduced: true);
        final geometry = DavidSlingGeometry.fromLevel(level);
        final initial = _mesh(tester);
        final actor = initial.bounds;
        expect(actor.left, greaterThanOrEqualTo(8));
        expect(actor.right, lessThanOrEqualTo(382));
        expect(actor.height, lessThanOrEqualTo(390 * .78));
        expect(actor.width / actor.height, closeTo(.75, .0001));
        expect(
          actor.left + actor.width * .451,
          closeTo(geometry.target.dx / 320 * 390, .01),
        );
        expect(
          actor.top + actor.height * .115,
          closeTo(geometry.target.dy / 420 * 844, .01),
        );
        final pull = Offset(
          (geometry.pouch.dx - geometry.target.dx) / 4,
          (geometry.pouch.dy + 420 * .12 - geometry.target.dy) / 4,
        );
        await _pull(tester, pull);
        await _untilFallen(tester);
        expect(_mesh(tester).bounds, actor);
        expect(identical(_mesh(tester).image, initial.image), true);
        expect(
          identical(_mesh(tester).reconstruction, initial.reconstruction),
          true,
        );
        expect(_mesh(tester).pose.isSettled, true);
        expect(_mesh(tester).pose.isGrounded, true);
        expect(find.byKey(const Key('sling-goliath-fallen')), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
  testWidgets(
    'head, spine and knee articulate independently without changing character textures',
    (tester) async {
      await _pump(tester, _level(), (_) {}, reduced: true);
      final initial = _mesh(tester);
      final restHead = initial.pose[GoliathJoint.head];
      await _pull(tester, const Offset(0, 48.45));
      await _advance(tester, const Duration(milliseconds: 620));
      final reaction = _mesh(tester);
      expect(identical(reaction.image, initial.image), true);
      expect(identical(reaction.reconstruction, initial.reconstruction), true);
      expect(reaction.pose[GoliathJoint.head], isNot(restHead));
      final headAngle = reaction.pose
          .boneTransform(GoliathJoint.neck, GoliathJoint.head)
          .rotationRadians;
      final chestAngle = reaction.pose
          .boneTransform(GoliathJoint.leftShoulder, GoliathJoint.rightShoulder)
          .rotationRadians;
      expect((headAngle - chestAngle).abs(), greaterThan(.02));
      expect(
        reaction.pose[GoliathJoint.leftKnee],
        isNot(initial.pose[GoliathJoint.leftKnee]),
      );
      expect(find.byKey(const Key('sling-goliath-mesh')), findsOneWidget);
      expect(find.byKey(const Key('sling-goliath-standing')), findsNothing);
      expect(find.byKey(const Key('sling-goliath-stagger')), findsNothing);
      expect(find.byKey(const Key('sling-goliath-fallen')), findsNothing);
    },
  );
  test('every live authored David level has a legal clear shot at Goliath', () {
    for (var index = 0; index < _authoredConfigs.length; index++) {
      final geometry = DavidSlingGeometry.fromLevel(
        GameLevel(
          id: 'authored-$index',
          number: index + 1,
          title: 'David',
          instructions: '',
          maxScore: 100,
          config: _authoredConfigs[index],
        ),
      );
      final pull = Offset(
        (geometry.pouch.dx - geometry.target.dx) / 4,
        (geometry.pouch.dy + geometry.size.height * .12 - geometry.target.dy) /
            4,
      );
      expect(geometry.constrainPull(pull), pull);
      expect(pull.dy, greaterThan(geometry.minimumPull));
      final shot = geometry.shot(pull);
      expect(
        shot.flightFraction,
        1,
        reason: 'Level ${index + 1} must have a clear route.',
      );
      expect(shot.hit, true);
      expect(shot.landing.dx, closeTo(geometry.target.dx, .01));
      expect(shot.landing.dy, closeTo(geometry.target.dy, .01));
    }
  });

  test(
    'direction and power determine different actual landing coordinates',
    () {
      final geometry = DavidSlingGeometry.fromLevel(_level());
      final low = geometry.shot(const Offset(0, 20));
      final onTarget = geometry.shot(const Offset(0, 48.45));
      final sideways = geometry.shot(const Offset(-30, 48.45));
      expect(low.hit, false);
      expect(low.landing.dy, closeTo(293.8, .01));
      expect(onTarget.hit, true);
      expect(onTarget.landing.dx, closeTo(160, .01));
      expect(onTarget.landing.dy, closeTo(180, .01));
      expect(sideways.hit, false);
      expect(sideways.landing.dx, closeTo(280, .01));
      expect(
        sideways.position(.5).dy,
        lessThan((sideways.position(0).dy + sideways.landing.dy) / 2),
      );
    },
  );

  test(
    'the first shield collision is the landing, not the intended target',
    () {
      final clear = DavidSlingGeometry.fromLevel(_level());
      final shot = clear.shot(const Offset(0, 48.45));
      final obstruction = shot.position(.5);
      final blocked = DavidSlingGeometry.fromLevel(
        _level(
          obstacles: [
            {
              'shape': 'circle',
              'x': obstruction.dx,
              'y': obstruction.dy,
              'radius': 15,
            },
          ],
        ),
      ).shot(const Offset(0, 48.45));
      expect(blocked.flightFraction, lessThan(.5));
      expect(blocked.hit, false);
      expect((blocked.landing - obstruction).distance, closeTo(15, .01));
      expect(blocked.position(1), blocked.landing);
    },
  );

  test('large sideways pulls stop at a real viewport boundary', () {
    final geometry = DavidSlingGeometry.fromLevel(_level());
    final shot = geometry.shot(const Offset(-70, 35));
    expect(shot.flightFraction, lessThan(1));
    expect(shot.landing.dx, closeTo(320, .01));
    expect(shot.landing.dy, inInclusiveRange(0, 420));
    expect(shot.hit, false);
  });

  testWidgets(
    'battlefield fills the viewport and flags move without any shot',
    (tester) async {
      await _pump(tester, _level(), (_) {});
      expect(
        tester.getSize(find.byKey(const Key('sling-board'))),
        const Size(390, 844),
      );
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(find.text('Small stone, giant courage'), findsNothing);
      final before = _wind(tester);
      await tester.pump(const Duration(milliseconds: 500));
      expect(_wind(tester), isNot(before));
      expect(find.byKey(const Key('sling-phase-ready')), findsOneWidget);
    },
  );

  testWidgets('ordinary taps, distant drags and cancelled pulls use no stone', (
    tester,
  ) async {
    final results = <Map<String, dynamic>>[];
    final audio = _Audio();
    await _pump(tester, _level(), results.add, audio: audio);
    await tester.tapAt(const Offset(195, 340));
    await tester.dragFrom(const Offset(30, 200), const Offset(0, 100));
    await tester.pump();
    final gesture = await tester.startGesture(_pouch(tester));
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump();
    await gesture.cancel();
    await _advance(tester, const Duration(seconds: 5));
    expect(_stones(tester), '3 stones remaining');
    expect(results, isEmpty);
    expect(audio.events, isNot(contains('launch')));
  });

  testWidgets(
    'impact and physical settling precede a clear 900ms grounded hold and one result',
    (tester) async {
      final results = <Map<String, dynamic>>[];
      final audio = _Audio();
      await _pump(tester, _level(), results.add, audio: audio);
      await _pull(tester, const Offset(0, 48.45));
      expect(find.byKey(const Key('sling-phase-flight')), findsOneWidget);
      expect(audio.events.where((e) => e == 'launch'), hasLength(1));
      await _advance(tester, const Duration(milliseconds: 800));
      expect(audio.events, isNot(contains('impact')));
      expect(results, isEmpty);
      await _advance(tester, const Duration(milliseconds: 80));
      expect(find.byKey(const Key('sling-phase-impact')), findsOneWidget);
      expect(audio.events.where((e) => e == 'impact'), hasLength(1));
      expect(audio.events, isNot(contains('victory')));
      await _advance(tester, const Duration(milliseconds: 200));
      expect(find.byKey(const Key('sling-phase-stagger')), findsOneWidget);
      await _advance(tester, const Duration(milliseconds: 400));
      expect(find.byKey(const Key('sling-phase-falling')), findsOneWidget);
      expect(results, isEmpty);
      await _untilFallen(tester);
      expect(_mesh(tester).pose.isSettled, true);
      expect(audio.events.where((e) => e == 'victory'), hasLength(1));
      expect(results, isEmpty);
      await _advance(tester, const Duration(milliseconds: 850));
      expect(results, isEmpty);
      await _advance(tester, const Duration(milliseconds: 100));
      expect(results, hasLength(1));
      expect((results.single['shots'] as List).single['x'], closeTo(160, .01));
      expect((results.single['shots'] as List).single['y'], closeTo(180, .01));
      await _advance(tester, const Duration(seconds: 2));
      expect(results, hasLength(1));
    },
  );
  testWidgets('pull back then upward flick launches the actual armed shot', (
    tester,
  ) async {
    final results = <Map<String, dynamic>>[];
    final audio = _Audio();
    await _pump(tester, _level(), results.add, audio: audio);
    final start = _pouch(tester);
    final delta = const Offset(0, 48.45) * (844 / 420);
    final gesture = await tester.startGesture(start);
    await gesture.moveTo(
      start + delta * .5,
      timeStamp: const Duration(milliseconds: 150),
    );
    await gesture.moveTo(
      start + delta,
      timeStamp: const Duration(milliseconds: 250),
    );
    await tester.pump();
    expect(
      tester.getCenter(find.byKey(const Key('sling-stone-pickup'))).dy,
      closeTo(start.dy + delta.dy, .01),
    );
    await gesture.moveTo(
      start + delta * .5,
      timeStamp: const Duration(milliseconds: 280),
    );
    await gesture.moveTo(start, timeStamp: const Duration(milliseconds: 310));
    await tester.pump();
    expect(
      tester.getCenter(find.byKey(const Key('sling-stone-pickup'))).dy,
      closeTo(start.dy, .01),
    );
    await gesture.up(timeStamp: const Duration(milliseconds: 320));
    await tester.pump();
    expect(find.byKey(const Key('sling-phase-flight')), findsOneWidget);
    expect(audio.events, contains('launch'));
    expect(results, isEmpty);
    await _untilFallen(tester);
    expect(results, isEmpty);
    await _advance(tester, const Duration(milliseconds: 1000));
    expect(results, hasLength(1));
    expect((results.single['shots'] as List).single['y'], closeTo(180, .01));
  });

  testWidgets('slowly returning an armed pouch to neutral cancels the shot', (
    tester,
  ) async {
    final results = <Map<String, dynamic>>[];
    await _pump(tester, _level(), results.add);
    final start = _pouch(tester);
    final gesture = await tester.startGesture(start);
    await gesture.moveTo(
      start + const Offset(0, 100),
      timeStamp: const Duration(milliseconds: 300),
    );
    await tester.pump();
    await gesture.moveTo(
      start + const Offset(0, 50),
      timeStamp: const Duration(milliseconds: 900),
    );
    await gesture.moveTo(start, timeStamp: const Duration(milliseconds: 1500));
    await gesture.up(timeStamp: const Duration(milliseconds: 1900));
    await _advance(tester, const Duration(seconds: 5));
    expect(_stones(tester), '3 stones remaining');
    expect(results, isEmpty);
  });

  testWidgets('misses keep Goliath standing and use the real shot budget', (
    tester,
  ) async {
    final results = <Map<String, dynamic>>[];
    final audio = _Audio();
    await _pump(tester, _level(shots: 2), results.add, audio: audio);
    await _pull(tester, const Offset(0, 20));
    await _advance(tester, const Duration(milliseconds: 1200));
    expect(results, isEmpty);
    expect(_stones(tester), '1 stones remaining');
    expect(_mesh(tester).pose.phase, GoliathMotionPhase.standing);
    expect(find.byKey(const Key('sling-phase-miss')), findsOneWidget);
    await _pull(tester, const Offset(0, 20));
    await _advance(tester, const Duration(milliseconds: 1200));
    expect(results, hasLength(1));
    for (final shot in results.single['shots'] as List) {
      expect(shot['y'], closeTo(293.8, .01));
    }
    expect(audio.events, isNot(contains('victory')));
    expect(find.byKey(const Key('sling-goliath-fallen')), findsNothing);
  });

  testWidgets(
    'background freezes flags and flight then resumes without skipping fall',
    (tester) async {
      final results = <Map<String, dynamic>>[];
      final audio = _Audio();
      await _pump(tester, _level(), results.add, audio: audio);
      await _pull(tester, const Offset(0, 48.45));
      await _advance(tester, const Duration(milliseconds: 300));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      final wind = _wind(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(_wind(tester), wind);
      expect(results, isEmpty);
      expect(audio.events, isNot(contains('impact')));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await _advance(tester, const Duration(milliseconds: 400));
      expect(find.byKey(const Key('sling-phase-flight')), findsOneWidget);
      await _advance(tester, const Duration(milliseconds: 850));
      expect(find.byKey(const Key('sling-phase-falling')), findsOneWidget);
      expect(results, isEmpty);
      await _untilFallen(tester);
      expect(results, isEmpty);
      await _advance(tester, const Duration(milliseconds: 1000));
      expect(results, hasLength(1));
    },
  );

  testWidgets(
    'parent paused dialog freezes the battle and cannot complete behind it',
    (tester) async {
      final results = <Map<String, dynamic>>[];
      final audio = _Audio();
      final key = GlobalKey();
      final level = _level();
      await _pump(tester, level, results.add, audio: audio, key: key);
      await _pull(tester, const Offset(0, 48.45));
      await _advance(tester, const Duration(milliseconds: 1350));
      await _pump(
        tester,
        level,
        results.add,
        audio: audio,
        key: key,
        paused: true,
      );
      final wind = _wind(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(results, isEmpty);
      expect(_wind(tester), wind);
      expect(audio.events, isNot(contains('victory')));
      await _pump(
        tester,
        level,
        results.add,
        audio: audio,
        key: key,
        paused: false,
      );
      await _untilFallen(tester);
      expect(find.byKey(const Key('sling-phase-fallen')), findsOneWidget);
      expect(results, isEmpty);
      await _advance(tester, const Duration(seconds: 1));
      expect(results, hasLength(1));
    },
  );

  testWidgets('hidden ticker mode and disposal suppress battle completion', (
    tester,
  ) async {
    final results = <Map<String, dynamic>>[];
    final audio = _Audio();
    final key = GlobalKey();
    final level = _level();
    await _pump(tester, level, results.add, audio: audio, key: key);
    await _pull(tester, const Offset(0, 48.45));
    await _advance(tester, const Duration(milliseconds: 400));
    await _pump(
      tester,
      level,
      results.add,
      audio: audio,
      key: key,
      visible: false,
    );
    await tester.pump(const Duration(seconds: 5));
    expect(results, isEmpty);
    expect(audio.events, isNot(contains('impact')));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await _advance(tester, const Duration(seconds: 5));
    expect(results, isEmpty);
    expect(audio.events, contains('dispose'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reduced motion keeps wind still but still shows real settling and grounded hold',
    (tester) async {
      final results = <Map<String, dynamic>>[];
      await _pump(tester, _level(), results.add, reduced: true);
      final wind = _wind(tester);
      await _pull(tester, const Offset(0, 48.45));
      await _untilFallen(tester);
      expect(_mesh(tester).pose.isSettled, true);
      expect(_mesh(tester).pose.isGrounded, true);
      expect(results, isEmpty);
      expect(_wind(tester), wind);
      await _advance(tester, const Duration(milliseconds: 950));
      expect(results, hasLength(1));
    },
  );
  testWidgets(
    'asset decode failure disables shots and exposes a retry without a substitute actor',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final audio = _Audio();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DavidSlingEngine(
              level: _level(),
              onComplete: (_) {},
              audio: audio,
              goliathAsset: 'missing.png',
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(find.byKey(const Key('sling-retry-skin')), findsOneWidget);
      await _pull(tester, const Offset(0, 48.45));
      expect(audio.events, isNot(contains('launch')));
      expect(_stones(tester), '3 stones remaining');
      expect(find.byKey(const Key('sling-goliath-mesh')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'keyboard chooses real direction and power, enter alone cannot hit',
    (tester) async {
      final results = <Map<String, dynamic>>[];
      await _pump(tester, _level(shots: 1), results.add);
      final focus = tester.widget<Focus>(
        find
            .ancestor(
              of: find.byKey(const Key('sling-board')),
              matching: find.byType(Focus),
            )
            .first,
      );
      focus.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(_stones(tester), '1 stones remaining');
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await _advance(tester, const Duration(milliseconds: 1200));
      expect(results, hasLength(1));
      final actual = (results.single['shots'] as List).single;
      expect(actual['x'], greaterThan(160));
      expect(actual['y'], greaterThan(180));
    },
  );

  testWidgets('compact controls, sound and exit stay usable with larger text', (
    tester,
  ) async {
    final audio = _Audio();
    var exits = 0;
    await _pump(
      tester,
      _level(),
      (_) {},
      audio: audio,
      scale: 1.6,
      onExit: () => exits++,
    );
    await tester.tap(find.byKey(const Key('sling-toggle-controls')));
    await tester.pump();
    expect(find.byKey(const Key('sling-angle')), findsOneWidget);
    expect(find.byKey(const Key('sling-power')), findsOneWidget);
    final release = tester.widget<FilledButton>(
      find.byKey(const Key('sling-release')),
    );
    expect(release.onPressed, isNull);
    await tester.tap(find.byKey(const Key('sling-sound')));
    await tester.pump();
    expect(audio.events, contains('mute:true'));
    await tester.tap(find.byKey(const Key('sling-exit')));
    expect(exits, 1);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester,
  GameLevel level,
  void Function(Map<String, dynamic>) complete, {
  _Audio? audio,
  Key? key,
  bool paused = false,
  bool visible = true,
  bool reduced = false,
  double scale = 1,
  VoidCallback? onExit,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(
            size: const Size(390, 844),
            disableAnimations: reduced,
            textScaler: TextScaler.linear(scale),
          ),
          child: TickerMode(
            enabled: visible,
            child: DavidSlingEngine(
              key: key,
              level: level,
              onComplete: complete,
              audio: audio ?? const SilentDavidBattleAudio(),
              paused: paused,
              onExit: onExit,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  for (
    var attempt = 0;
    attempt < 10 &&
        find.byKey(const Key('sling-goliath-mesh')).evaluate().isEmpty;
    attempt++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(find.byKey(const Key('sling-goliath-mesh')), findsOneWidget);
}

Offset _pouch(WidgetTester tester) =>
    tester.getCenter(find.byKey(const Key('sling-stone-pickup')));
String _stones(WidgetTester tester) => tester
    .widget<Semantics>(find.byKey(const Key('sling-stones')))
    .properties
    .label!;
double _wind(WidgetTester tester) =>
    (tester
                    .widget<CustomPaint>(
                      find.byKey(const Key('sling-living-battlefield')),
                    )
                    .painter
                as dynamic)
            .phase
        as double;
Future<void> _pull(WidgetTester tester, Offset canvasPull) async {
  final size = tester.getSize(find.byKey(const Key('sling-board')));
  final gesture = await tester.startGesture(_pouch(tester));
  await gesture.moveBy(
    Offset(canvasPull.dx * size.width / 320, canvasPull.dy * size.height / 420),
  );
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

class _Audio implements DavidBattleAudio {
  final List<String> events = [];
  @override
  Future<void> setActive(bool active) async {
    events.add('active:$active');
  }

  @override
  Future<void> setMuted(bool muted) async {
    events.add('mute:$muted');
  }

  @override
  Future<void> playLaunch() async {
    events.add('launch');
  }

  @override
  Future<void> playImpact() async {
    events.add('impact');
  }

  @override
  Future<void> playVictory() async {
    events.add('victory');
  }

  @override
  Future<void> dispose() async {
    events.add('dispose');
  }
}

GoliathMeshPainter _mesh(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.descendant(
                of: find.byKey(const Key('sling-goliath-mesh')),
                matching: find.byType(CustomPaint),
              ),
            )
            .painter!
        as GoliathMeshPainter;
Future<void> _advance(WidgetTester tester, Duration duration) async {
  var remaining = duration.inMicroseconds;
  while (remaining > 0) {
    final step = remaining > 16000 ? 16000 : remaining;
    await tester.pump(Duration(microseconds: step));
    remaining -= step;
  }
}

Future<void> _untilFallen(WidgetTester tester) async {
  for (var frame = 0; frame < 400; frame++) {
    if (find.byKey(const Key('sling-phase-fallen')).evaluate().isNotEmpty) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 16));
  }
  fail('The physical body did not settle and become grounded.');
}

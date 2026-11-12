import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/ark_garden_model.dart';
import 'package:mobile/features/games/domain/ark_garden_projection.dart';

Map<String, dynamic> _config() =>
    jsonDecode(File('test/fixtures/ark_garden_course.json').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  final golden =
      jsonDecode(
            File('test/fixtures/ark_garden_replay.json').readAsStringSync(),
          )
          as Map;
  for (final rejection in golden['rejections'] as List) {
    test('deadline input is rejected before emitting ${rejection['name']}', () {
      final run = ArkGardenRun(ArkGardenCourse.fromConfig(_config()))..start();
      final result = rejection['result'] as Map;
      while (run.tick < result['elapsed_ticks']) {
        run.step();
      }
      for (final tap in result['taps'] as List) {
        expect(run.tap(tap['animal_id'] as String), isFalse);
        expect(run.animal(tap['animal_id'] as String)!.tappedAtTick, isNull);
      }
      expect(run.result['taps'], isEmpty);
      expect(run.timedOut, isTrue);
    });
  }
  for (final scenario in golden['scenarios'] as List) {
    test('Python/Dart replay agrees for ${scenario['name']}', () {
      final run = ArkGardenRun(ArkGardenCourse.fromConfig(_config()))..start();
      final result = scenario['result'] as Map;
      final expected = scenario['expected'] as Map;
      final taps = result['taps'] as List;
      final limit = result['elapsed_ticks'] as int;
      for (var tick = 0; tick <= limit; tick++) {
        for (final tap in taps.where((tap) => tap['tick'] == tick)) {
          run.tap(tap['animal_id'] as String);
        }
        if (tick < limit) run.step();
      }
      expect(run.complete, expected['completed']);
      expect(run.boardedCount, expected['animals_boarded']);
      for (final state in run.animals) {
        final id = state.animal.id;
        final position = expected['positions'][id] as List;
        _expectPoint(
          state.position,
          ArkGardenPoint(
            (position[0] as num).toDouble(),
            (position[1] as num).toDouble(),
            (position[2] as num).toDouble(),
          ),
        );
        final phase = state.boarded
            ? 'boarded'
            : state.tappedAtTick == null
            ? 'idle'
            : state.pathPhase.name;
        expect(phase, expected['phases'][id]);
        expect(state.tappedAtTick, expected['first_tap_ticks'][id]);
        if (state.boarded) {
          expect(state.arrivalTick, expected['arrival_ticks'][id]);
        }
      }
    });
  }
  test('cross-language golden fixture stays identical to the backend copy', () {
    expect(
      golden,
      jsonDecode(
        File(
          '../../Backend/Core/apps/games/content/ark_garden_replay_v1.json',
        ).readAsStringSync(),
      ),
    );
  });
  test(
    'one held 60-second course contains each of the ten requested species',
    () {
      final config = _config();
      final canonical = jsonDecode(
        File(
          '../../Backend/Core/apps/games/content/ark_garden_course_v1.json',
        ).readAsStringSync(),
      );
      expect(config, canonical);
      final course = ArkGardenCourse.fromConfig(config);
      expect(
        course.animals.map((animal) => animal.species).toSet(),
        arkGardenSpecies,
      );
      expect(course.animals.length, 10);
      expect(course.timeLimitTicks, 600);
      expect(config.keys.toSet(), {'mode', 'garden'});
    },
  );

  test('the clock can run while every untapped animal stays in its garden', () {
    final run = ArkGardenRun(ArkGardenCourse.fromConfig(_config()))..start();
    final original = run.animals.map((animal) => animal.position).toList();
    for (var i = 0; i < 50; i++) {
      run.step();
    }
    for (var i = 0; i < run.animals.length; i++) {
      _expectPoint(run.animals[i].position, original[i]);
      expect(run.animals[i].phase, ArkGardenAnimalPhase.idle);
      expect(run.animals[i].walkTicks, 0);
    }
    expect(run.tick, 50);
    expect(run.boardedCount, 0);
    expect(run.result['taps'], isEmpty);
  });

  test(
    'only the first tap starts movement and repeat taps never reset a route',
    () {
      final run = ArkGardenRun(ArkGardenCourse.fromConfig(_config()));
      expect(run.tap('elephant'), isFalse);
      run.start();
      expect(run.tap('unknown'), isFalse);
      expect(run.tap('elephant'), isTrue);
      _expectPoint(
        run.animal('elephant')!.position,
        run.animal('elephant')!.animal.route.first,
      );
      run.step();
      final position = run.animal('elephant')!.position;
      expect(position.x, greaterThan(3));
      expect(run.tap('elephant'), isFalse);
      _expectPoint(run.animal('elephant')!.position, position);
      expect(run.result['taps'], [
        {'tick': 0, 'animal_id': 'elephant'},
      ]);
      expect(run.animal('elephant')!.tappedAtTick, 0);
      expect(run.animal('lion')!.phase, ArkGardenAnimalPhase.idle);
    },
  );

  test(
    'stairs rise; crossing the threshold does not board an animal early',
    () {
      final run = ArkGardenRun(ArkGardenCourse.fromConfig(_config()))
        ..start()
        ..tap('rabbit');
      final rabbit = run.animal('rabbit')!;
      var climbed = false;
      var entered = false;
      while (run.tick < rabbit.arrivalTick! - 1) {
        run.step();
        if (rabbit.phase == ArkGardenAnimalPhase.climbing &&
            rabbit.position.z > 0) {
          climbed = true;
          expect(rabbit.position.z, lessThanOrEqualTo(4.3));
        }
        if (rabbit.pathPhase == ArkGardenPathPhase.interior) {
          entered = true;
          expect(rabbit.phase, ArkGardenAnimalPhase.entering);
          expect(rabbit.boarded, isFalse);
        }
      }
      expect(climbed, isTrue);
      expect(entered, isTrue);
      expect(rabbit.boarded, isFalse);
      expect(
        rabbit.position.distanceTo(rabbit.animal.route.last),
        greaterThan(0),
      );
      run.step();
      expect(rabbit.boarded, isTrue);
      _expectPoint(rabbit.position, rabbit.animal.route.last);
      expect(run.boardedCount, 1);
      expect(run.complete, isFalse);
    },
  );

  test(
    'distance carries through waypoint joins and exactly ten arrivals finish early',
    () {
      final run = ArkGardenRun(ArkGardenCourse.fromConfig(_config()))..start();
      for (final animal in run.animals) {
        run.tap(animal.animal.id);
      }
      final arrival = run.animals
          .map((animal) => animal.arrivalTick!)
          .reduce((a, b) => a > b ? a : b);
      while (!run.finished) {
        run.step();
      }
      expect(run.tick, arrival);
      expect(run.tick, lessThan(run.course.timeLimitTicks));
      expect(run.complete, isTrue);
      expect(run.boardedCount, 10);
      for (final animal in run.animals) {
        _expectPoint(animal.position, animal.animal.route.last);
        expect(animal.phase, ArkGardenAnimalPhase.boarded);
        expect(run.tap(animal.animal.id), isFalse);
      }
      final finishedTick = run.tick;
      run.step();
      expect(run.tick, finishedTick);
      expect(run.result.keys.toSet(), {'taps', 'elapsed_ticks'});
      expect((run.result['taps'] as List).length, 10);
    },
  );

  test(
    'pause freezes movement and deadline prevents taps or late arrivals',
    () {
      final run = ArkGardenRun(ArkGardenCourse.fromConfig(_config()))..start();
      for (var i = 0; i < 590; i++) {
        run.step();
      }
      run.tap('elephant');
      run.paused = true;
      final position = run.animal('elephant')!.position;
      for (var i = 0; i < 10; i++) {
        run.step();
      }
      expect(run.tick, 590);
      _expectPoint(run.animal('elephant')!.position, position);
      expect(run.tap('lion'), isFalse);
      run.paused = false;
      while (!run.finished) {
        run.step();
      }
      expect(run.tick, 600);
      expect(run.timedOut, isTrue);
      expect(run.complete, isFalse);
      expect(run.boardedCount, 0);
      expect(run.tap('lion'), isFalse);
    },
  );

  test(
    'malformed species, phases, stairs, interior clearance and clocks are rejected',
    () {
      final changes = <void Function(Map<String, dynamic>)>[
        (c) => c['garden']['version'] = 1.0,
        (c) => c['garden']['tick_ms'] = true,
        (c) => c['garden']['time_limit_ticks'] = 99,
        (c) => c['garden']['animals'][0]['species'] = 'lion',
        (c) => c['garden']['animals'][0]['route'][3]['z'] = 0,
        (c) => c['garden']['animals'][0]['route'][4]['z'] = 3,
        (c) => c['garden']['animals'][0]['route'][5]['y'] = 9.1,
        (c) => c['garden']['animals'][0]['route'][0]['z'] = 1,
        (c) => c['garden']['animals'][0]['speed_units_per_second'] = .05,
        (c) => c['garden']['animals'][0]['route'][2]['phase'] = 'door',
        (c) => c['garden']['animals'][0]['route'][0]['x'] = double.nan,
      ];
      for (final change in changes) {
        final config = _config();
        change(config);
        expect(() => ArkGardenCourse.fromConfig(config), throwsFormatException);
      }
    },
  );

  test(
    'projection raises feet while panning moves all world anchors equally',
    () {
      final course = ArkGardenCourse.fromConfig(_config());
      final viewport = ArkGardenViewport(
        course: course,
        width: 1000,
        height: 500,
      );
      const point = ArkGardenPoint(28, 8, 4.3);
      final raised = viewport.project(point);
      final grounded = viewport.project(const ArkGardenPoint(28, 8, 0));
      expect(
        grounded.y - raised.y,
        closeTo(4.3 * course.elevationYScale * viewport.scale, 1e-9),
      );
      final panned = viewport.pannedBy(-300);
      expect(panned.project(point).x, closeTo(raised.x - 300, 1e-9));
      expect(panned.project(point).y, raised.y);
      final restored = panned.groundAt(
        panned.project(const ArkGardenPoint(17, 10, 0)),
      );
      _expectPoint(restored, const ArkGardenPoint(17, 10, 0));
      expect(viewport.pannedBy(1000).panPixels, 0);
      expect(viewport.pannedBy(-10000).panPixels, viewport.maximumPan);
      expect(
        viewport.depth(point),
        viewport.depth(const ArkGardenPoint(28, 8, 0)),
      );
    },
  );
}

void _expectPoint(ArkGardenPoint actual, ArkGardenPoint expected) {
  expect(actual.x, closeTo(expected.x, 1e-8));
  expect(actual.y, closeTo(expected.y, 1e-8));
  expect(actual.z, closeTo(expected.z, 1e-8));
}

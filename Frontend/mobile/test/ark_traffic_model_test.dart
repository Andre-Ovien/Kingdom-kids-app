import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/ark_traffic_model.dart';

void main() {
  final authored =
      jsonDecode(
            File(
              '../../Motion/ark-traffic-blender-v1/traffic-levels.json',
            ).readAsStringSync(),
          )
          as Map;
  test(
    'all three rounds need child drawn routes and preserve paired species',
    () {
      for (final (number, count, limit) in [
        (1, 8, 1200),
        (2, 10, 1500),
        (3, 12, 1800),
      ]) {
        final course = ArkTrafficCourse.fromConfig(
          Map<String, dynamic>.from(authored['$number'] as Map),
        );
        expect(course.animals.length, count);
        expect(course.timeLimitTicks, limit);
        final run = ArkTrafficRun(course)..start();
        for (var tick = 0; tick < limit; tick++) {
          run.step();
        }
        expect(run.boardedCount, 0);
        expect(run.complete, isFalse);
        expect(run.timedOut, isTrue);
      }
    },
  );
  test('slow tortoise and two elephants share the introductory approach', () {
    final course = ArkTrafficCourse.fromConfig(
      Map<String, dynamic>.from(authored['1'] as Map),
    );
    final run = ArkTrafficRun(course)..start();
    final tortoise = run.animal('tortoise-1')!;
    final elephant = run.animal('elephant-1')!;
    expect(tortoise.progress, .5);
    expect(elephant.progress, .65);
    expect(run.animal('elephant-2')!.progress, .05);
    for (var tick = 0; tick < 12; tick++) {
      run.step();
    }
    expect(elephant.currentNode, 'bridge-in');
    expect(tortoise.currentNode, 'bridge-in');
    expect(tortoise.progress, greaterThan(.5));
    expect(tortoise.progress, lessThan(1));
  });
  test('goats use rocks and elephants refuse narrow unsuitable routes', () {
    final course = ArkTrafficCourse.fromConfig(
      Map<String, dynamic>.from(authored['1'] as Map),
    );
    final run = ArkTrafficRun(course)..start();
    expect(
      run.setRoute('goat-1', [
        'home-goat-1',
        'west-hub',
        'rock-in',
        'upper-west',
        'upper-hub',
        'ark',
      ]),
      isTrue,
    );
    expect(
      run.setRoute('elephant-1', [
        'bridge-in',
        'lower-hub',
        'west-hub',
        'rock-in',
      ]),
      isFalse,
    );
    expect(
      ArkTrafficAnimal.speedFor('tortoise'),
      lessThan(ArkTrafficAnimal.speedFor('elephant')),
    );
    expect(
      ArkTrafficAnimal.speedFor('rabbit'),
      greaterThan(ArkTrafficAnimal.speedFor('goat')),
    );
  });
  test(
    'mid-edge redraw preserves the current position and upcoming junction',
    () {
      final run = ArkTrafficRun(
        ArkTrafficCourse.fromConfig(_simple(progress: .5)),
      )..start();
      final before = run.animal('friend')!.position(run.course);
      expect(run.setRoute('friend', ['home', 'junction', 'ark']), isFalse);
      expect(run.setRoute('friend', ['junction', 'ark']), isTrue);
      expect(run.animal('friend')!.position(run.course).x, before.x);
      run.step();
      expect(
        run.animal('friend')!.position(run.course).x,
        closeTo(.2105, 1e-9),
      );
    },
  );
  test('wait steps aside to recover a merge and resume rejoins safely', () {
    final config = _simple();
    ((config['traffic'] as Map)['animals'] as List).add({
      'id': 'blocker',
      'species': 'elephant',
      'start_node': 'junction',
    });
    final run = ArkTrafficRun(ArkTrafficCourse.fromConfig(config))..start();
    for (var i = 0; i < 20; i++) {
      run.step();
    }
    expect(run.animal('friend')!.blocked, isTrue);
    expect(run.setWaiting('blocker', true), isTrue);
    for (var i = 0; i < 40; i++) {
      run.step();
    }
    expect(run.animal('friend')!.boarded, isTrue);
    expect(run.setRoute('blocker', ['junction', 'ark']), isTrue);
    expect(run.setWaiting('blocker', false), isTrue);
    for (var i = 0; i < 60; i++) {
      run.step();
    }
    expect(run.complete, isTrue);
    expect(run.jamTicks, greaterThan(0));
  });
  test('closed gates hold movement and mud changes species speed', () {
    final config = _simple(gate: true);
    final run = ArkTrafficRun(ArkTrafficCourse.fromConfig(config))..start();
    run.step();
    expect(run.jamTicks, 1);
    expect(run.animal('friend')!.position(run.course).x, .1);
    expect(run.toggleGate('gate-a'), isTrue);
    run.step();
    expect(run.animal('friend')!.position(run.course).x, closeTo(.1105, 1e-9));
    final rabbit =
        ArkTrafficRun(ArkTrafficCourse.fromConfig(_simple(terrain: 'mud')))
          ..start()
          ..step();
    final goat =
        ArkTrafficRun(
            ArkTrafficCourse.fromConfig(
              _simple(terrain: 'mud', species: 'goat'),
            ),
          )
          ..start()
          ..step();
    expect(
      rabbit.animal('friend')!.position(rabbit.course).x,
      closeTo(.1 + .0105 * .45, 1e-9),
    );
    expect(
      goat.animal('friend')!.position(goat.course).x,
      closeTo(.1 + .0072 * .75, 1e-9),
    );
  });
  test('pause freezes time and inputs; replay has bounded commands only', () {
    final run = ArkTrafficRun(ArkTrafficCourse.fromConfig(_simple()))..start();
    run.paused = true;
    run.step();
    expect(run.tick, 0);
    expect(run.setWaiting('friend', true), isFalse);
    run.paused = false;
    for (var i = 0; i < 240; i++) {
      expect(run.setWaiting('friend', i.isEven), isTrue);
    }
    expect(run.setWaiting('friend', true), isFalse);
    expect(run.result.keys.toSet(), {'commands', 'elapsed_ticks'});
    expect((run.result['commands'] as List).length, 240);
  });
  test('recorded solutions complete every authored round in bounded time', () {
    final proof =
        jsonDecode(
              File(
                '../../Motion/ark-traffic-blender-v1/review/mobile-replay-proof.json',
              ).readAsStringSync(),
            )
            as Map;
    for (final value in proof.values) {
      final caseData = value as Map;
      final run = ArkTrafficRun(
        ArkTrafficCourse.fromConfig(
          Map<String, dynamic>.from(caseData['config'] as Map),
        ),
      )..start();
      final result = caseData['result'] as Map;
      final commands = (result['commands'] as List).cast<Map>();
      var index = 0;
      while (run.tick < (result['elapsed_ticks'] as int)) {
        while (index < commands.length && commands[index]['tick'] == run.tick) {
          final command = commands[index++];
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
      expect(run.complete, isTrue);
      expect(run.jamTicks, (caseData['mobile'] as Map)['jam_ticks']);
      expect(run.commands.length, lessThanOrEqualTo(240));
    }
  });
}

Map<String, dynamic> _simple({
  String species = 'rabbit',
  String terrain = 'trail',
  bool gate = false,
  double progress = 0,
}) => {
  'mode': 'ark_traffic',
  'traffic': {
    'tick_ms': 100,
    'time_limit_ticks': 1800,
    'target_jam_ticks': 100,
    'nodes': [
      {'id': 'home', 'x': .1, 'y': .5},
      {'id': 'junction', 'x': .3, 'y': .5},
      {'id': 'ark', 'x': .5, 'y': .5},
    ],
    'edges': [
      {
        'id': 'first',
        'a': 'home',
        'b': 'junction',
        'width': .12,
        'terrain': terrain,
        'gate': gate ? 'gate-a' : null,
      },
      {
        'id': 'last',
        'a': 'junction',
        'b': 'ark',
        'width': .12,
        'terrain': 'trail',
        'gate': null,
      },
    ],
    'animals': [
      {
        'id': 'friend',
        'species': species,
        'start_node': 'home',
        'route': ['home', 'junction', 'ark'],
        'start_progress': progress,
      },
    ],
    'gates': gate
        ? [
            {'id': 'gate-a', 'open': false},
          ]
        : [],
    'ark_node': 'ark',
  },
};

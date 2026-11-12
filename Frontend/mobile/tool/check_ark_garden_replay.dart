import 'dart:convert';
import 'dart:io';

import 'package:mobile/features/games/domain/ark_garden_model.dart';

/// Cross-language golden replay verification that needs no sockets, renderer,
/// Flutter SDK cache writes or live account/database. Fails on any drift.
void main() {
  var checks = 0;
  for (final pair in [
    ('ark_garden_course.json', 'ark_garden_replay.json'),
    ('ark_garden_curve_contract_v2.json', 'ark_garden_curve_replay_v2.json'),
    if (File('test/fixtures/ark_garden_course_v2.json').existsSync())
      ('ark_garden_course_v2.json', 'ark_garden_replay_v2.json'),
  ]) {
    final config = _read(pair.$1);
    final golden = _read(pair.$2);
    for (final scenario in golden['scenarios'] as List) {
      final run = ArkGardenRun(ArkGardenCourse.fromConfig(config))..start();
      final result = scenario['result'] as Map;
      final expected = scenario['expected'] as Map;
      final taps = result['taps'] as List;
      for (var tick = 0; tick <= result['elapsed_ticks']; tick++) {
        for (final tap in taps.where((tap) => tap['tick'] == tick)) {
          run.tap(tap['animal_id'] as String);
        }
        if (tick < result['elapsed_ticks']) run.step();
      }
      _equal(
        run.boardedCount,
        expected['animals_boarded'],
        '${scenario['name']} count',
      );
      _equal(
        run.complete,
        expected['completed'],
        '${scenario['name']} complete',
      );
      for (final animal in run.animals) {
        final id = animal.animal.id;
        final actual = [
          animal.position.x,
          animal.position.y,
          animal.position.z,
        ];
        final coordinates = expected['positions'][id] as List;
        for (var i = 0; i < 3; i++) {
          if ((actual[i] - (coordinates[i] as num)).abs() > 1e-8) {
            throw StateError('${scenario['name']} $id position drift');
          }
        }
        final phase = animal.boarded
            ? 'boarded'
            : animal.tappedAtTick == null
            ? 'idle'
            : animal.pathPhase.name;
        _equal(phase, expected['phases'][id], '${scenario['name']} $id phase');
        _equal(animal.tappedAtTick, expected['first_tap_ticks'][id], '$id tap');
        if (animal.boarded) {
          _equal(
            animal.arrivalTick,
            expected['arrival_ticks'][id],
            '$id arrival',
          );
        }
      }
      checks++;
    }
  }
  final run =
      ArkGardenRun(
          ArkGardenCourse.fromConfig(
            _read('ark_garden_curve_contract_v2.json'),
          ),
        )
        ..start()
        ..tap('elephant')
        ..tap('lion');
  run.step();
  final distance = run.animal('elephant')!.distanceTravelled;
  _equal(run.animal('lion')!.distanceTravelled, 0.0, 'waiting animal');
  run.paused = true;
  for (var i = 0; i < 50; i++) {
    run.step();
  }
  _equal(run.tick, 1, 'paused tick');
  _equal(run.animal('elephant')!.distanceTravelled, distance, 'paused root');
  if (run.tap('rabbit')) throw StateError('Paused tap was accepted');
  stdout.writeln(
    '${checks + 1} cross-language replay and pause checks passed.',
  );
}

Map<String, dynamic> _read(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

void _equal(Object? actual, Object? expected, String context) {
  if (actual != expected) throw StateError('$context: $actual != $expected');
}

// Pure Dart replay validation; no Flutter engine or device is started.
import 'dart:convert';
import 'dart:io';

import 'package:mobile/features/games/domain/ark_traffic_model.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

List<String> routeTo(
  ArkTrafficCourse course,
  String from,
  String to,
  String species,
) {
  final pending = <List<String>>[
    [from],
  ];
  final seen = <String>{from};
  while (pending.isNotEmpty) {
    final path = pending.removeAt(0);
    if (path.last == to) return path;
    for (final edge in course.edges) {
      if (!edge.accepts(species)) continue;
      final next = edge.a == path.last
          ? edge.b
          : edge.b == path.last
          ? edge.a
          : null;
      if (next != null && seen.add(next)) pending.add([...path, next]);
    }
  }
  throw StateError('No $species route from $from to $to');
}

void main(List<String> arguments) {
  final root = Directory.current.path.endsWith('/Frontend/mobile')
      ? '../..'
      : '.';
  final raw =
      jsonDecode(
            File(
              '$root/Motion/ark-traffic-blender-v1/traffic-levels.json',
            ).readAsStringSync(),
          )
          as Map;
  final proof = <String, dynamic>{};
  for (var number = 1; number <= 3; number++) {
    final config = Map<String, dynamic>.from(raw['$number'] as Map);
    final course = ArkTrafficCourse.fromConfig(config);
    final idle = ArkTrafficRun(course)..start();
    for (var i = 0; i < course.timeLimitTicks; i++) {
      idle.step();
    }
    check(idle.boardedCount == 0, 'Round $number must require drawn routes.');
    final run = ArkTrafficRun(course)..start();
    for (final id in course.gates.keys) {
      if (!run.gates[id]!) check(run.toggleGate(id), 'Open gate');
    }
    for (final state in run.animals) {
      final species = state.animal.species;
      final via = switch (species) {
        'goat' => ['west-hub', 'rock-in', 'upper-west', 'upper-hub', 'ark'],
        'rabbit' => ['east-in', 'east-out', 'upper-hub', 'ark'],
        _ => ['bridge-in', 'bridge-out', 'upper-hub', 'ark'],
      };
      final anchor = state.anchor;
      List<String> path;
      if (via.contains(anchor)) {
        path = via.sublist(via.indexOf(anchor));
      } else {
        path = [...routeTo(course, anchor, via.first, species), ...via.skip(1)];
      }
      check(
        run.setRoute(state.animal.id, path),
        'Draw valid ${state.animal.id} trail',
      );
    }
    final resumeAt = <String, int>{};
    final blockedTicks = <String, int>{};
    while (!run.finished) {
      for (final state in run.animals) {
        final id = state.animal.id;
        if (state.boarded) continue;
        if (state.waiting &&
            resumeAt[id] != null &&
            run.tick >= resumeAt[id]!) {
          check(run.setWaiting(id, false), 'Resume $id');
          resumeAt.remove(id);
        }
        blockedTicks[id] = state.blocked ? (blockedTicks[id] ?? 0) + 1 : 0;
        if (!state.waiting && blockedTicks[id]! >= 3) {
          check(
            run.setWaiting(id, true),
            'Yield $id at ${run.tick}, ${run.commands.length} commands',
          );
          resumeAt[id] = run.tick + 40 + run.animals.indexOf(state) * 8;
          blockedTicks[id] = 0;
        }
      }
      run.step();
    }
    check(
      run.complete,
      'Round $number must be completable with valid commands.',
    );
    check(
      run.commands.length <= ArkTrafficCourse.maximumCommands,
      'Bounded command replay',
    );
    final positions = <String, List<double>>{
      for (final state in run.animals)
        state.animal.id: [state.position(course).x, state.position(course).y],
    };
    proof['$number'] = {
      'config': config,
      'result': run.result,
      'mobile': {
        'animals_boarded': run.boardedCount,
        'jam_ticks': run.jamTicks,
        'positions': positions,
      },
    };
    stdout.writeln(
      'Ark $number: ${run.boardedCount}/${run.animals.length} aboard, '
      '${run.tick} ticks, ${run.jamTicks} blocked animal ticks, ${run.commands.length} commands.',
    );
  }
  final path = arguments.isNotEmpty
      ? arguments.first
      : '$root/Motion/ark-traffic-blender-v1/review/mobile-replay-proof.json';
  File(
    path,
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(proof));
  stdout.writeln('Replay proof written to $path');
}

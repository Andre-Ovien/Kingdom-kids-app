import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/creation_world_model.dart';

Map<String, dynamic> fixture(int level) => Map<String, dynamic>.from(
  (jsonDecode(
            File('test/fixtures/creation_world_levels.json').readAsStringSync(),
          )
          as Map)['$level']
      as Map,
);

void buildDay(CreationWorldModel world) {
  const cells = {
    'light': [0],
    'cloud': [1],
    'water': [0, 5, 10, 15, 1, 2],
    'land': [3, 4, 8, 9, 13, 14, 18, 19],
    'forest': [6, 11],
    'sun': [2],
    'moon': [3],
    'fish': [5],
    'bird': [6],
    'goat': [3],
    'rabbit': [19],
  };
  for (final piece in world.pieces.where((p) => p.day == world.currentDay)) {
    final index = int.parse(piece.id.split('-').last) - 1;
    expect(world.place(piece.id, cells[piece.kind]![index]), isTrue);
  }
}

void main() {
  test('three authored worlds complete only in Bible day order', () {
    for (final level in [1, 2, 3]) {
      final world = CreationWorldModel.fromConfig(fixture(level));
      expect(world.advanceDay(), isFalse);
      while (world.completedDays < world.totalDays) {
        buildDay(world);
        expect(world.advanceDay(), isTrue);
      }
      expect(world.complete, isTrue);
      expect(
        world.submission(120).keys,
        unorderedEquals(['commands', 'elapsed_seconds']),
      );
    }
  });
  test('fish and animals follow adjacent habitat cells', () {
    final world = CreationWorldModel.fromConfig(fixture(3));
    while (world.completedDays < world.totalDays) {
      buildDay(world);
      world.advanceDay();
    }
    for (final id in ['fish-1', 'goat-1', 'rabbit-1']) {
      final path = world.creaturePath(world.piece(id));
      expect(path.length, greaterThan(1));
      for (var i = 0; i + 1 < path.length; i++) {
        expect(world.neighbors(path[i]), contains(path[i + 1]));
      }
    }
    expect(world.remove('water-2'), isTrue);
    expect(world.requirements(7).riverConnected, isFalse);
    expect(world.creaturePath(world.piece('fish-1')), [5]);
    expect(world.complete, isFalse);
  });
  test('future pieces and occupied ground cannot be placed', () {
    final world = CreationWorldModel.fromConfig(fixture(3));
    expect(world.place('fish-1', 0), isFalse);
    expect(world.place('light-1', 9), isFalse);
    buildDay(world);
    world.advanceDay();
    buildDay(world);
    world.advanceDay();
    expect(world.place('water-1', 0), isTrue);
    expect(world.place('land-1', 0), isFalse);
    expect(world.place('water-1', 5), isTrue);
  });
}

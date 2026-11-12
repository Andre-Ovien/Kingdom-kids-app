import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/wise_builders_model.dart';

Map<String, dynamic> fixture([bool braces = true]) => {
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
      if (braces) 'brace',
    ],
    'storm': 'rain_and_wind',
    'target_moves': 16,
  },
};
void build(WiseBuildersModel world, String id, String foundation) {
  expect(world.foundation(id, foundation), isTrue);
  for (final part in world.requiredParts) {
    expect(world.place(id, part), isTrue);
  }
}

void main() {
  test(
    'children build both houses and server-compatible rock/sand contrast',
    () {
      final world = WiseBuildersModel.fromConfig(fixture());
      build(world, 'house-a', 'rock');
      build(world, 'house-b', 'sand');
      expect(world.canStorm, isTrue);
      expect(world.testStorm(), isTrue);
      expect(world.complete, isTrue);
      expect(world.stood, {'house-a': true, 'house-b': false});
      expect(
        world.submission(90).keys,
        unorderedEquals(['commands', 'elapsed_seconds']),
      );
    },
  );
  test('roof needs four walls and sand collapse needs rebuilding', () {
    final world = WiseBuildersModel.fromConfig(fixture());
    expect(world.place('house-a', 'roof'), isFalse);
    expect(world.foundation('house-a', 'rock'), isTrue);
    expect(world.place('house-a', 'roof'), isFalse);
    for (final part in world.requiredParts) {
      expect(world.place('house-a', part), isTrue);
    }
    expect(world.remove('house-a', 'front-wall'), isFalse);
    build(world, 'house-b', 'sand');
    world.testStorm();
    expect(world.testStorm(), isFalse);
    expect(world.reset('house-b'), isTrue);
    build(world, 'house-b', 'sand');
    expect(world.testStorm(), isTrue);
    expect(world.complete, isTrue);
  });
  test('two rock foundations do not complete the comparison', () {
    final world = WiseBuildersModel.fromConfig(fixture(false));
    build(world, 'house-a', 'rock');
    build(world, 'house-b', 'rock');
    world.testStorm();
    expect(world.complete, isFalse);
  });
}

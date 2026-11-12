import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/ruth_harvest_model.dart';

final _goldens =
    (jsonDecode(
              File(
                'test/fixtures/ruth_harvest_golden_v1.json',
              ).readAsStringSync(),
            )
            as Map)['rounds']
        as List;

Map<String, dynamic> config(int index) =>
    Map<String, dynamic>.from((_goldens[index] as Map)['config'] as Map);

List<int> indices(Object? value) => (value as List).cast<int>();

void main() {
  for (var round = 0; round < 3; round++) {
    test('round ${round + 1} matches independently authored server golden', () {
      final fixture = _goldens[round] as Map;
      final field = RuthHarvestModel.fromConfig(config(round));
      final initial = fixture['initial'] as Map;
      expect(field.board, initial['board']);
      expect(field.collected, initial['collected']);
      expect(field.score, initial['score']);
      final first = field.harvest(indices(fixture['first_chain']));
      expect(first, isNotNull);
      final after = fixture['after_first'] as Map;
      expect(field.board, after['board']);
      expect(field.collected, after['collected']);
      expect(field.score, after['score']);
      expect(field.usedChains, after['chains_used']);

      final replay = RuthHarvestModel.fromConfig(config(round));
      final result = fixture['winning_result'] as Map;
      for (final chain in result['chains'] as List) {
        final move = replay.harvest(indices(chain));
        expect(move, isNotNull);
        expect(move!.after, replay.board);
        expect(move.drops.map((drop) => drop.to).toSet().length, 30);
      }
      final expected = fixture['winning_outcome'] as Map;
      expect(replay.complete, expected['completed']);
      expect(replay.score, expected['score']);
      expect(replay.collected, expected['collected']);
      expect(replay.board, expected['board']);
      expect(replay.usedChains, expected['chains_used']);
      expect(replay.result, result);
      expect(replay.findMatch(), isNull);
      expect(replay.harvest([0, 1, 2]), isNull);
    });
  }

  test(
    'invalid chains consume neither moves, grain, nor refill randomness',
    () {
      final field = RuthHarvestModel.fromConfig(config(0));
      final initial = List.of(field.board);
      for (final chain in [
        <int>[],
        [0, 5],
        [0, 5, 0],
        [-1, 0, 5],
        [0, 5, 30],
        [0, 1, 2],
        [0, 20, 25],
      ]) {
        expect(field.harvest(chain), isNull, reason: '$chain');
        expect(field.board, initial);
        expect(field.usedChains, 0);
        expect(field.collected.values, everyElement(0));
      }
      expect(field.harvest([0, 5, 6]), isNotNull);
      expect(field.board, (_goldens[0] as Map)['after_first']['board']);
    },
  );

  test('diagonal neighbours work while row wrapping does not', () {
    final field = RuthHarvestModel.fromConfig(config(0));
    expect(field.adjacent(0, 6), isTrue);
    expect(field.adjacent(4, 8), isTrue);
    expect(field.adjacent(4, 5), isFalse);
    expect(field.adjacent(0, 0), isFalse);
    expect(field.adjacent(-1, 0), isFalse);
    expect(field.validChain([0, 6, 5]), isTrue);
  });

  test(
    'gravity preserves survivor order and refills the lowest empty first',
    () {
      final field = RuthHarvestModel.fromConfig(config(0));
      final before = List.of(field.board);
      final move = field.harvest([0, 5, 6])!;
      // Column zero loses its first two cells; lower pieces do not move.
      for (final cell in [10, 15, 20, 25]) {
        expect(field.board[cell], before[cell]);
        expect(move.drops.singleWhere((drop) => drop.to == cell).from, cell);
      }
      // Column one loses row one; its row-zero wheat settles into row one.
      expect(move.drops.singleWhere((drop) => drop.to == 6).from, 1);
      expect(field.board[6], before[1]);
      expect(move.drops.singleWhere((drop) => drop.to == 1).from, isNull);
      expect(move.before, before);
      expect(move.grain, 'oats');
      expect(move.cells, [0, 5, 6]);
    },
  );

  test('running out of gathers produces one final partial result', () {
    final field = RuthHarvestModel.fromConfig({
      ...config(0),
      'max_chains': 1,
      'goals': {'wheat': 100, 'barley': 100, 'oats': 100},
    });
    expect(field.harvest([0, 5, 6]), isNotNull);
    expect(field.complete, isFalse);
    expect(field.exhausted, isTrue);
    expect(field.finished, isTrue);
    expect(field.remainingChains, 0);
    final result = field.result;
    expect(field.harvest([2, 7, 12]), isNull);
    expect(field.result, result);
    expect(field.result.keys, ['chains']);
  });

  test('read-only views and submitted history cannot mutate replay state', () {
    final field = RuthHarvestModel.fromConfig(config(0));
    expect(() => field.board[0] = 'barley', throwsUnsupportedError);
    expect(() => field.collected['oats'] = 999, throwsUnsupportedError);
    field.harvest([0, 5, 6]);
    final result = field.result;
    (result['chains'] as List).clear();
    expect(field.usedChains, 1);
    expect(field.result['chains'], [
      [0, 5, 6],
    ]);
  });

  test(
    'hints provide legal chains and never change a board or use a gather',
    () {
      final field = RuthHarvestModel.fromConfig(config(0));
      final before = List.of(field.board);
      final hint = field.findMatch();
      expect(hint, isNotNull);
      expect(field.validChain(hint!), isTrue);
      expect(field.board, before);
      expect(field.usedChains, 0);
    },
  );

  test('bad public configuration is rejected before play', () {
    for (final change in [
      {'mode': 'matching'},
      {'seed': 0},
      {'seed': 0x100000000},
      {'rows': 7},
      {'columns': 0},
      {'min_chain': 2},
      {'max_chains': 0},
      {
        'grain_types': ['wheat', 'wheat', 'oats'],
      },
      {
        'goals': {'wheat': 0, 'barley': 6, 'oats': 6},
      },
    ]) {
      expect(
        () => RuthHarvestModel.fromConfig({...config(0), ...change}),
        throwsFormatException,
        reason: '$change',
      );
    }
  });
}

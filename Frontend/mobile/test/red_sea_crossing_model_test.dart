import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/red_sea_crossing_model.dart';

void main() {
  test(
    'authored courses preserve traveller identities and visible dry zone',
    () {
      for (final (count, seconds) in [(10, 45), (15, 30), (20, 15)]) {
        final course = RedSeaCrossingCourse.fromLevel(
          _level(count: count, seconds: seconds),
        );
        expect(course.timeLimitSeconds, seconds);
        expect(course.travellers, hasLength(count));
        expect(course.travellers.last.id, 'traveller-$count');
        expect(course.dropZone.contains(.34, .43), isTrue);
        expect(course.dropZone.contains(.66, .70), isTrue);
        expect(course.dropZone.contains(.33, .50), isFalse);
      }
    },
  );

  test('authored lane polygon accepts visible dry sand beyond the old box', () {
    for (final count in [10, 15, 20]) {
      final course = RedSeaCrossingCourse.fromLevel(
        _withPolygon(_lanePolygon, count: count),
      );
      expect(course.dropZone.contains(.25, .60), isTrue);
      expect(course.dropZone.contains(.75, .60), isTrue);
      expect(course.dropZone.contains(.10, .60), isFalse);
      expect(course.dropZone.contains(.90, .60), isFalse);
      expect(course.dropZone.contains(.5, .75), isFalse);
      for (var index = 0; index < _lanePolygon.length; index++) {
        final a = _lanePolygon[index];
        final b = _lanePolygon[(index + 1) % _lanePolygon.length];
        expect(course.dropZone.contains(a[0], a[1]), isTrue);
        expect(
          course.dropZone.contains((a[0] + b[0]) / 2, (a[1] + b[1]) / 2),
          isTrue,
        );
      }
      final run = RedSeaCrossingRun(course)..start();
      _advance(run, 2.6);
      expect(run.place('traveller-1', .10, .60), isFalse);
      expect(run.place('traveller-1', .25, .60), isTrue);
      expect(run.placements['traveller-1']!.x, .25);
    }
    final reversed = RedSeaCrossingCourse.fromLevel(
      _withPolygon(_lanePolygon.reversed.toList()),
    );
    expect(reversed.dropZone.contains(.25, .60), isTrue);
    expect(reversed.dropZone.contains(.10, .60), isFalse);
  });

  test('malformed, concave and degenerate lane polygons are refused', () {
    final invalid = <Object?>[
      null,
      [],
      [
        [.4, .4],
        [.6, .6],
      ],
      List.generate(17, (index) => [.4, .4]),
      [
        [.4, .4],
        [.6, .4],
        [double.nan, .6],
      ],
      [
        [.4, .4],
        [.6, .4],
        [1.1, .6],
      ],
      [
        [.4, .4],
        [.6, .4],
        ['bad', .6],
      ],
      [
        [.4, .4],
        [.6, .4],
        [.5],
      ],
      [
        [.2, .2],
        [.8, .2],
        [.5, .5],
        [.8, .8],
        [.2, .8],
      ],
      [
        [.2, .2],
        [.8, .8],
        [.8, .2],
        [.2, .8],
      ],
      [
        [.2, .2],
        [.5, .5],
        [.8, .8],
      ],
      [
        [.2, .2],
        [.8, .2],
        [.8, .2],
        [.2, .8],
      ],
    ];
    for (final polygon in invalid) {
      expect(
        () => RedSeaCrossingCourse.fromLevel(_withPolygon(polygon)),
        throwsFormatException,
        reason: 'Invalid polygon: $polygon',
      );
    }
  });

  test('timer and placement stay locked until the sea has actually opened', () {
    final run = RedSeaCrossingRun(RedSeaCrossingCourse.fromLevel(_level()));
    _advance(run, 1);
    expect(run.phase, RedSeaCrossingPhase.ready);
    run.start();
    _advance(run, 2.5);
    expect(run.phase, RedSeaCrossingPhase.parting);
    expect(run.elapsed, 0);
    expect(run.place('traveller-1', .5, .6), isFalse);
    run.advance(.1);
    expect(run.phase, RedSeaCrossingPhase.placing);
    expect(run.openingProgress, 1);
    expect(run.elapsed, closeTo(0, .00001));
    run.advance(.1);
    expect(run.elapsed, closeTo(.1, .00001));
  });

  test(
    'water drops, unknown people, and duplicate releases spend no traveller',
    () {
      final run = _opened();
      expect(run.place('traveller-1', .20, .6), isFalse);
      expect(run.place('traveller-1', .5, .8), isFalse);
      expect(run.place('traveller-1', double.nan, .6), isFalse);
      expect(run.place('someone-else', .5, .6), isFalse);
      expect(run.placedCount, 0);
      expect(run.place('traveller-1', .5, .6), isTrue);
      run.advance(.1);
      expect(run.place('traveller-1', .6, .6), isFalse);
      expect(run.placedCount, 1);
      expect(run.placements['traveller-1']!.x, .5);
    },
  );

  test(
    'final drop stops the timer but success waits for actual shore arrivals',
    () {
      final run = _opened();
      _advance(run, 1);
      for (final person in run.course.travellers) {
        expect(run.place(person.id, .5, .6), isTrue);
        run.advance(.1);
      }
      expect(run.phase, RedSeaCrossingPhase.walking);
      expect(run.safeCount, 0);
      expect(() => run.result(), throwsStateError);
      final taskElapsed = run.elapsed;
      _advance(run, 3);
      expect(run.finished, isFalse);
      expect(run.elapsed, taskElapsed);
      _advance(run, 2);
      expect(run.phase, RedSeaCrossingPhase.complete);
      expect(run.safeCount, run.course.travellers.length);
      final outcome = run.result()['crossing'] as Map;
      expect(outcome['elapsed_ms'], (taskElapsed * 1000).round());
      expect(outcome['placements'], hasLength(6));
      final times = (outcome['placements'] as List)
          .map((person) => (person as Map)['released_at_ms'] as int)
          .toList();
      expect(times, orderedEquals([...times]..sort()));
      expect(times.last, lessThanOrEqualTo(outcome['elapsed_ms'] as int));
    },
  );

  test(
    'all family rounds allow every final drop before their own deadline',
    () {
      for (final (count, seconds) in [(10, 45), (15, 30), (20, 15)]) {
        final run = RedSeaCrossingRun(
          RedSeaCrossingCourse.fromLevel(
            _level(count: count, seconds: seconds),
          ),
        )..start();
        _advance(run, 2.6);
        _advance(run, seconds - .1);
        for (final person in run.course.travellers) {
          expect(run.place(person.id, .5, .6), isTrue);
        }
        final placementElapsed = run.elapsed;
        expect(run.phase, RedSeaCrossingPhase.walking);
        expect(run.placedCount, count);
        _advance(run, 5);
        expect(run.phase, RedSeaCrossingPhase.complete);
        expect(run.safeCount, count);
        expect(run.elapsed, placementElapsed);
        final outcome = run.result()['crossing'] as Map;
        expect(outcome['elapsed_ms'], seconds * 1000 - 100);
        expect(outcome['placements'], hasLength(count));
      }
    },
  );

  test('shorter rounds time out with truthful partial placement counts', () {
    for (final (count, seconds) in [(10, 45), (15, 30), (20, 15)]) {
      final run = RedSeaCrossingRun(
        RedSeaCrossingCourse.fromLevel(_level(count: count, seconds: seconds)),
      )..start();
      _advance(run, 2.6);
      expect(run.place('traveller-1', .5, .6), isTrue);
      _advance(run, seconds.toDouble());
      expect(run.phase, RedSeaCrossingPhase.timedOut);
      expect(run.remainingSeconds, 0);
      expect(run.place('traveller-$count', .5, .6), isFalse);
      final outcome = run.result()['crossing'] as Map;
      expect(outcome['elapsed_ms'], seconds * 1000);
      expect(outcome['placements'], hasLength(1));
    }
  });

  test(
    'timeout preserves truthful partial drops for authoritative failure',
    () {
      final run = _opened();
      _advance(run, 1);
      run.place('traveller-2', .6, .55);
      _advance(run, 45);
      expect(run.phase, RedSeaCrossingPhase.timedOut);
      expect(run.remainingSeconds, 0);
      expect(run.place('traveller-1', .5, .6), isFalse);
      final outcome = run.result()['crossing'] as Map;
      expect(outcome['elapsed_ms'], 45000);
      expect(outcome['placements'], [
        {
          'traveller_id': 'traveller-2',
          'x': .6,
          'y': .55,
          'released_at_ms': 1000,
        },
      ]);
      final elapsed = run.elapsed;
      run.advance(.1);
      expect(run.elapsed, elapsed);
    },
  );

  test('invalid and stalled frames cannot jump the timer or crossing walk', () {
    final run = _opened();
    run.place('traveller-1', .5, .6);
    for (final delta in [double.nan, double.infinity, -1.0, 0.0]) {
      run.advance(delta);
    }
    expect(run.elapsed, closeTo(0, .00001));
    expect(run.placements['traveller-1']!.walkProgress, 0);
    run.advance(30);
    expect(run.elapsed, closeTo(.1, .00001));
    expect(run.placements['traveller-1']!.walkProgress, lessThan(.04));
  });

  test(
    'course cannot silently omit malformed or repeated traveller identities',
    () {
      final json = _level().config['crossing'] as Map;
      for (final people in [
        List.generate(
          21,
          (index) => {'id': 'traveller-$index', 'label': 'Traveller $index'},
        ),
        [
          {'id': 'same', 'label': 'One'},
          {'id': 'same', 'label': 'Two'},
        ],
        [
          {'id': 'ok', 'label': 'One'},
          {'label': 'Missing identity'},
        ],
      ]) {
        expect(
          () => RedSeaCrossingCourse.fromLevel(
            GameLevel(
              id: 'invalid',
              number: 1,
              title: '',
              instructions: '',
              maxScore: 100,
              config: {
                'crossing': {...json, 'travellers': people},
              },
            ),
          ),
          throwsFormatException,
        );
      }
    },
  );
}

RedSeaCrossingRun _opened() {
  final run = RedSeaCrossingRun(RedSeaCrossingCourse.fromLevel(_level()));
  run.start();
  _advance(run, 2.6);
  return run;
}

void _advance(RedSeaCrossingRun run, double seconds) {
  for (var index = 0; index < (seconds * 10).round(); index++) {
    run.advance(.1);
  }
}

GameLevel _level({int count = 6, int seconds = 45}) => GameLevel(
  id: 'crossing-$count',
  number: 1,
  title: 'A way through the sea',
  instructions: 'Help everyone onto the dry path.',
  maxScore: 100,
  config: {
    'crossing': {
      'time_limit_seconds': seconds,
      'travellers': [
        for (var index = 1; index <= count; index++)
          {'id': 'traveller-$index', 'label': 'Traveller $index'},
      ],
      'drop_zone': {'left': .34, 'top': .43, 'right': .66, 'bottom': .70},
    },
  },
);

const _lanePolygon = <List<double>>[
  [.43, .33],
  [.57, .33],
  [.705, .43],
  [.855, .70],
  [.145, .70],
  [.295, .43],
];

GameLevel _withPolygon(Object? polygon, {int count = 6}) {
  final level = _level(count: count);
  final crossing = level.config['crossing'] as Map;
  return GameLevel(
    id: level.id,
    number: level.number,
    title: level.title,
    instructions: level.instructions,
    maxScore: level.maxScore,
    config: {
      'crossing': {
        ...crossing,
        'drop_zone': {...crossing['drop_zone'] as Map, 'polygon': polygon},
      },
    },
  );
}

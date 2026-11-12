import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/storybook_game_engines.dart';

void main() {
  testWidgets(
    'quiz requires an answer for each question and sends its payload once',
    (tester) async {
      final results = <Map<String, dynamic>>[];
      await _pumpEngine(
        tester,
        StoryQuizEngine(level: _level('quiz', _quiz), onComplete: results.add),
      );
      await _tap(tester, 'quiz-continue');
      expect(find.text('Who helped Esther?'), findsOneWidget);
      expect(results, isEmpty);
      await _tap(tester, 'quiz-option-a');
      await _tap(tester, 'quiz-continue');
      expect(find.text('What does courage look like?'), findsOneWidget);
      await _tap(tester, 'quiz-continue');
      expect(results, isEmpty);
      await _tap(tester, 'quiz-option-b');
      await _tap(tester, 'quiz-continue');
      expect(results, [
        {
          'answers': [
            {'question_id': 'q1', 'option_id': 'a'},
            {'question_id': 'q2', 'option_id': 'b'},
          ],
        },
      ]);
      await _tap(tester, 'quiz-continue');
      expect(results, hasLength(1));
    },
  );

  testWidgets(
    'creation tap replacement returns displaced tile and guards incomplete submit',
    (tester) async {
      final results = <Map<String, dynamic>>[];
      await _pumpEngine(
        tester,
        CreationStudioEngine(
          level: _level('creation', _creation),
          onComplete: results.add,
        ),
      );
      await _tap(tester, 'ordering-check');
      expect(results, isEmpty);
      await _tap(tester, 'creation-tile-day-3');
      await _tap(tester, 'creation-day-0');
      await _tap(tester, 'creation-tile-day-1');
      await _tap(tester, 'creation-day-0');
      expect(find.byKey(const Key('creation-tile-day-3')), findsOneWidget);
      expect(find.byKey(const Key('creation-tile-day-1')), findsNothing);
      await _tap(tester, 'creation-tile-day-2');
      await _tap(tester, 'creation-day-1');
      await _tap(tester, 'ordering-check');
      expect(results, isEmpty);
      await _tap(tester, 'creation-tile-day-3');
      await _tap(tester, 'creation-day-2');
      await _tap(tester, 'ordering-check');
      expect(results, [
        {
          'sequence': ['day-1', 'day-2', 'day-3'],
        },
      ]);
      await _tap(tester, 'ordering-check');
      expect(results, hasLength(1));
    },
  );

  testWidgets(
    'creation dragging an existing tile swaps occupied days without duplicates',
    (tester) async {
      final results = <Map<String, dynamic>>[];
      await _pumpEngine(
        tester,
        CreationStudioEngine(
          level: _level('creation', _creation),
          onComplete: results.add,
        ),
      );
      await _drag(tester, 'creation-tile-day-2', 'creation-day-0');
      await _drag(tester, 'creation-tile-day-1', 'creation-day-1');
      // A placed tile can be picked up directly; occupied days swap.
      await _drag(tester, 'creation-day-0', 'creation-day-1');
      await _drag(tester, 'creation-tile-day-3', 'creation-day-2');
      await _tap(tester, 'ordering-check');
      expect(results.single['sequence'], ['day-1', 'day-2', 'day-3']);
      expect((results.single['sequence'] as List).toSet(), hasLength(3));
    },
  );

  testWidgets(
    'memory opens its preview automatically and hides treasure semantics after peek',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final results = <Map<String, dynamic>>[];
      await _pumpEngine(
        tester,
        LanternMemoryEngine(
          level: _level('memory', _memory),
          onComplete: results.add,
        ),
      );
      expect(find.text('A little peek · 3'), findsOneWidget);
      expect(find.bySemanticsLabel('Lion, revealed'), findsNWidgets(2));
      await _tap(tester, 'memory-card-lion-a');
      await tester.pump(const Duration(seconds: 3));
      // The visible closing animation must not leak the face to screen readers.
      expect(find.bySemanticsLabel('Lion, revealed'), findsNothing);
      expect(find.bySemanticsLabel('Hidden treasure'), findsNWidgets(6));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Lion'), findsNothing);
      expect(find.text('0 moves'), findsOneWidget);
      expect(results, isEmpty);
      semantics.dispose();
    },
  );

  testWidgets('memory cards are shuffled without adjacent matching faces', (
    tester,
  ) async {
    await _pumpEngine(
      tester,
      LanternMemoryEngine(level: _level('memory', _memory), onComplete: (_) {}),
    );
    final cards = tester
        .widgetList(
          find.descendant(
            of: find.byKey(const Key('memory-grid')),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget.key is ValueKey<String> &&
                  (widget.key! as ValueKey<String>).value.startsWith(
                    'memory-card-',
                  ),
            ),
          ),
        )
        .toList();
    final species = cards
        .map((widget) => (widget.key! as ValueKey<String>).value.split('-')[2])
        .toList();
    expect(species, hasLength(6));
    for (var index = 1; index < species.length; index++) {
      expect(species[index], isNot(species[index - 1]));
    }
  });

  testWidgets(
    'memory mismatch waits in active time while backgrounded and resumes explicitly',
    (tester) async {
      final results = <Map<String, dynamic>>[];
      await _pumpEngine(
        tester,
        LanternMemoryEngine(
          level: _level('memory', _memory),
          onComplete: results.add,
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 350));
      await _tap(tester, 'memory-card-lion-a', elapsed: Duration.zero);
      await _tap(tester, 'memory-card-scroll-a', elapsed: Duration.zero);
      expect(find.text('1 move'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pump(const Duration(seconds: 60));
      expect(find.text('Your lantern hunt is paused.'), findsOneWidget);
      expect(results, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byKey(const Key('memory-resume')), findsOneWidget);
      await _tap(tester, 'memory-resume', elapsed: Duration.zero);
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.text('Remember those treasures. You can try again.'),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 51));
      expect(
        find.text('Remember those treasures. You can try again.'),
        findsOneWidget,
      );
      expect(results, isEmpty);
    },
  );

  testWidgets(
    'memory matches complete once with moves and active gameplay time',
    (tester) async {
      final results = <Map<String, dynamic>>[];
      await _pumpEngine(
        tester,
        LanternMemoryEngine(
          level: _level('memory', _memory),
          onComplete: results.add,
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 350));
      for (final species in ['lion', 'scroll', 'prayer']) {
        await _tap(tester, 'memory-card-$species-a', elapsed: Duration.zero);
        await _tap(tester, 'memory-card-$species-b', elapsed: Duration.zero);
        await tester.pump(const Duration(milliseconds: 651));
      }
      expect(results, hasLength(1));
      expect(results.single['matched_pairs'], [
        ['lion-a', 'lion-b'],
        ['scroll-a', 'scroll-b'],
        ['prayer-a', 'prayer-b'],
      ]);
      expect(results.single['moves'], 3);
      expect(results.single['elapsed_seconds'], 2);
      await _tap(tester, 'memory-card-lion-a');
      await tester.pump(const Duration(seconds: 30));
      expect(results, hasLength(1));
    },
  );

  testWidgets(
    'disposing memory during a pending pair never submits or resolves afterward',
    (tester) async {
      final results = <Map<String, dynamic>>[];
      await _pumpEngine(
        tester,
        LanternMemoryEngine(
          level: _level('memory', {..._memory, 'preview_seconds': 0}),
          onComplete: results.add,
        ),
      );
      await _tap(tester, 'memory-card-lion-a', elapsed: Duration.zero);
      await _tap(tester, 'memory-card-lion-b', elapsed: Duration.zero);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 30));
      expect(results, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Moses drag links one item once and replacement clears the displaced partner',
    (tester) async {
      final results = <Map<String, dynamic>>[];
      await _pumpEngine(
        tester,
        StoryMatchingEngine(
          level: _level('moses', _matching),
          onComplete: results.add,
        ),
      );
      await _tap(tester, 'matching-check');
      expect(results, isEmpty);
      await _drag(tester, 'match-left-basket', 'match-right-nile');
      await _drag(tester, 'match-left-river', 'match-right-nile');
      await _tap(tester, 'matching-check');
      expect(results, isEmpty);
      await _tap(tester, 'match-left-basket');
      await _tap(tester, 'match-right-floated');
      await _tap(tester, 'matching-check');
      expect(results, [
        {
          'pairs': [
            {'left_id': 'river', 'right_id': 'nile'},
            {'left_id': 'basket', 'right_id': 'floated'},
          ],
        },
      ]);
      await _tap(tester, 'matching-check');
      expect(results, hasLength(1));
    },
  );

  testWidgets(
    'all creation days and source wonders fit together for real phone dragging',
    (tester) async {
      for (final config in [_creation, _creationWeek]) {
        final results = <Map<String, dynamic>>[];
        await _pumpEngine(
          tester,
          CreationStudioEngine(
            key: ValueKey(config),
            level: _level('creation', config),
            onComplete: results.add,
          ),
          size: const Size(390, 844),
          topInset: 116,
        );
        final items = config['items']! as List;
        for (final item in items) {
          final id = (item as Map)['id'] as String;
          final index = int.parse(id.substring(4)) - 1;
          final source = find.byKey(Key('creation-tile-$id'));
          final target = find.byKey(Key('creation-day-$index'));
          expect(tester.getRect(source).bottom, lessThanOrEqualTo(844));
          expect(tester.getRect(target).top, greaterThanOrEqualTo(116));
          await _drag(
            tester,
            'creation-tile-$id',
            'creation-day-$index',
            scroll: false,
          );
        }
        await _tap(tester, 'ordering-check');
        expect(results.single['sequence'], [
          for (var i = 1; i <= items.length; i++) 'day-$i',
        ]);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('largest memory deck fits beside its HUD on a normal phone', (
    tester,
  ) async {
    await _pumpEngine(
      tester,
      LanternMemoryEngine(
        level: _level('memory', _largestMemory),
        onComplete: (_) {},
      ),
      size: const Size(390, 844),
      topInset: 116,
    );
    final cards = find.descendant(
      of: find.byKey(const Key('memory-grid')),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith('memory-card-'),
      ),
    );
    expect(cards, findsNWidgets(10));
    for (final element in cards.evaluate()) {
      final rect = tester.getRect(find.byWidget(element.widget));
      expect(rect.top, greaterThanOrEqualTo(116));
      expect(rect.bottom, lessThanOrEqualTo(844));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'all five Moses clues and moments stay visible for level three dragging',
    (tester) async {
      final results = <Map<String, dynamic>>[];
      await _pumpEngine(
        tester,
        StoryMatchingEngine(
          level: _level('moses', _matchingFive),
          onComplete: results.add,
        ),
        size: const Size(390, 844),
        topInset: 116,
      );
      const matches = {
        'passover': 'remember',
        'sea': 'opened',
        'manna': 'food',
        'tablets': 'commandments',
        'cloud': 'guided',
      };
      for (final entry in matches.entries) {
        final source = find.byKey(Key('match-left-${entry.key}'));
        final target = find.byKey(Key('match-right-${entry.value}'));
        expect(tester.getRect(source).top, greaterThanOrEqualTo(116));
        expect(tester.getRect(source).bottom, lessThanOrEqualTo(844));
        expect(tester.getRect(target).bottom, lessThanOrEqualTo(844));
        await _drag(
          tester,
          'match-left-${entry.key}',
          'match-right-${entry.value}',
          scroll: false,
        );
      }
      await _tap(tester, 'matching-check');
      expect(results, [
        {
          'pairs': [
            for (final entry in matches.entries)
              {'left_id': entry.key, 'right_id': entry.value},
          ],
        },
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'storybook game screens lay out on a compact phone with larger text',
    (tester) async {
      for (final engine in <Widget>[
        StoryQuizEngine(level: _level('quiz', _quiz), onComplete: (_) {}),
        CreationStudioEngine(
          level: _level('creation', _creation),
          onComplete: (_) {},
        ),
        LanternMemoryEngine(
          level: _level('memory', _memory),
          onComplete: (_) {},
        ),
        StoryMatchingEngine(
          level: _level('moses', _matchingFive),
          onComplete: (_) {},
        ),
      ]) {
        await _pumpEngine(
          tester,
          engine,
          size: const Size(320, 700),
          scale: 1.5,
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
      }
    },
  );
}

GameLevel _level(String id, Map<String, dynamic> config) => GameLevel(
  id: '$id-test',
  number: 1,
  title: id,
  instructions: 'Story challenge',
  config: config,
  maxScore: 100,
);

Future<void> _pumpEngine(
  WidgetTester tester,
  Widget engine, {
  Size size = const Size(430, 1500),
  double scale = 1,
  double topInset = 0,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            if (topInset > 0) SizedBox(height: topInset),
            Expanded(
              child: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(scale),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: engine,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _tap(
  WidgetTester tester,
  String key, {
  Duration elapsed = const Duration(milliseconds: 260),
}) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pump();
  if (elapsed != Duration.zero) await tester.pump(elapsed);
}

Future<void> _drag(
  WidgetTester tester,
  String sourceKey,
  String targetKey, {
  bool scroll = true,
}) async {
  final source = find.byKey(Key(sourceKey));
  final target = find.byKey(Key(targetKey));
  if (scroll) await tester.ensureVisible(source);
  final from = tester.getCenter(source);
  if (scroll) await tester.ensureVisible(target);
  final to = tester.getCenter(target);
  final drag = await tester.startGesture(from);
  await drag.moveBy(const Offset(0, -30));
  await tester.pump();
  await drag.moveTo(to);
  await tester.pump();
  await drag.up();
  await tester.pump(const Duration(milliseconds: 200));
}

const _quiz = <String, dynamic>{
  'questions': [
    {
      'id': 'q1',
      'prompt': 'Who helped Esther?',
      'options': [
        {'id': 'a', 'text': 'Mordecai'},
        {'id': 'b', 'text': 'Goliath'},
      ],
    },
    {
      'id': 'q2',
      'prompt': 'What does courage look like?',
      'options': [
        {'id': 'a', 'text': 'Ignoring someone'},
        {'id': 'b', 'text': 'Helping someone in need'},
      ],
    },
  ],
};
const _creation = <String, dynamic>{
  'items': [
    {'id': 'day-3', 'label': 'Land and plants', 'asset_key': '🌱'},
    {'id': 'day-1', 'label': 'Light and darkness', 'asset_key': '💡'},
    {'id': 'day-2', 'label': 'Sky and waters', 'asset_key': '☁️'},
  ],
};
const _creationWeek = <String, dynamic>{
  'items': [
    {'id': 'day-6', 'label': 'Animals and people', 'asset_key': '🧑🏾‍🤝‍🧑🏾'},
    {'id': 'day-3', 'label': 'Land and plants', 'asset_key': '🌱'},
    {'id': 'day-7', 'label': 'God rested', 'asset_key': '😌'},
    {'id': 'day-1', 'label': 'Light and darkness', 'asset_key': '💡'},
    {'id': 'day-5', 'label': 'Birds and sea creatures', 'asset_key': '🐋'},
    {'id': 'day-2', 'label': 'Sky and waters', 'asset_key': '☁️'},
    {'id': 'day-4', 'label': 'Sun, moon, and stars', 'asset_key': '🌞'},
  ],
};
const _memory = <String, dynamic>{
  'preview_seconds': 3,
  'cards': [
    {'id': 'lion-a', 'label': 'Lion', 'asset_key': '🦁', 'match_key': 'lion'},
    {'id': 'lion-b', 'label': 'Lion', 'asset_key': '🦁', 'match_key': 'lion'},
    {
      'id': 'scroll-a',
      'label': 'Scroll',
      'asset_key': '📜',
      'match_key': 'scroll',
    },
    {
      'id': 'scroll-b',
      'label': 'Scroll',
      'asset_key': '📜',
      'match_key': 'scroll',
    },
    {
      'id': 'prayer-a',
      'label': 'Prayer',
      'asset_key': '🙏🏾',
      'match_key': 'prayer',
    },
    {
      'id': 'prayer-b',
      'label': 'Prayer',
      'asset_key': '🙏🏾',
      'match_key': 'prayer',
    },
  ],
};
const _matching = <String, dynamic>{
  'left_items': [
    {'id': 'basket', 'label': 'Basket', 'asset_key': '🧺'},
    {'id': 'river', 'label': 'River', 'asset_key': '🌊'},
  ],
  'right_items': [
    {'id': 'nile', 'label': 'The Nile', 'asset_key': '🏞️'},
    {'id': 'floated', 'label': 'Floated safely', 'asset_key': '🛟'},
  ],
};
const _matchingFive = <String, dynamic>{
  'left_items': [
    {'id': 'passover', 'label': 'Passover', 'asset_key': '🕯️'},
    {'id': 'sea', 'label': 'Red Sea', 'asset_key': '🌊'},
    {'id': 'manna', 'label': 'Manna', 'asset_key': '🍞'},
    {'id': 'tablets', 'label': 'Stone tablets', 'asset_key': '🪨'},
    {'id': 'cloud', 'label': 'Cloud', 'asset_key': '☁️'},
  ],
  'right_items': [
    {'id': 'food', 'label': 'Food in the wilderness', 'asset_key': '😋'},
    {'id': 'commandments', 'label': 'God’s commandments', 'asset_key': '🔟'},
    {'id': 'opened', 'label': 'A path opened', 'asset_key': '🛤️'},
    {'id': 'guided', 'label': 'Guided the people', 'asset_key': '🧭'},
    {'id': 'remember', 'label': 'A rescue remembered', 'asset_key': '💛'},
  ],
};
final _largestMemory = <String, dynamic>{
  'preview_seconds': 3,
  'cards': [
    ..._memory['cards']! as List,
    {'id': 'king-a', 'label': 'King', 'asset_key': '👑', 'match_key': 'king'},
    {'id': 'king-b', 'label': 'King', 'asset_key': '👑', 'match_key': 'king'},
    {
      'id': 'sunrise-a',
      'label': 'Morning',
      'asset_key': '🌅',
      'match_key': 'sunrise',
    },
    {
      'id': 'sunrise-b',
      'label': 'Morning',
      'asset_key': '🌅',
      'match_key': 'sunrise',
    },
  ],
};

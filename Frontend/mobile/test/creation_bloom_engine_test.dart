import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/creation_bloom_model.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/creation_bloom_engine.dart';

Map<String, dynamic> get _config => {
  'mode': 'creation_bloom',
  'scene': 'creation_garden',
  'round_number': 1,
  'targets': [
    {'id': 'sky', 'match_key': 'sky', 'capacity': 2},
    {'id': 'water', 'match_key': 'water', 'capacity': 1},
    {'id': 'forest', 'match_key': 'forest', 'capacity': 1},
    {'id': 'meadow', 'match_key': 'meadow', 'capacity': 2},
  ],
  'items': [
    {'id': 'fish', 'match_key': 'water'},
    {'id': 'sun', 'match_key': 'sky'},
    {'id': 'flower', 'match_key': 'meadow'},
    {'id': 'bird', 'match_key': 'sky'},
    {'id': 'tree', 'match_key': 'forest'},
    {'id': 'deer', 'match_key': 'meadow'},
  ],
};

GameLevel get _level => GameLevel(
  id: 'creation-bloom-1',
  number: 1,
  title: 'Creation: Match & Bloom',
  instructions: '',
  maxScore: 100,
  config: _config,
);

void main() {
  setUpAll(() async {
    if (const bool.fromEnvironment('BLOOM_CAPTURE')) {
      final font = FontLoader('ReviewRoboto')
        ..addFont(
          File(
            '/opt/homebrew/share/flutter/engine/src/flutter/txt/third_party/fonts/Roboto-Regular.ttf',
          ).readAsBytes().then((value) => ByteData.sublistView(value)),
        );
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });

  test('all three authored garden replays agree with the backend fixture', () {
    final fixture =
        jsonDecode(
              File(
                '../../Backend/Core/apps/games/content/matching_collection_v1.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final cases = (fixture['golden'] as List).where(
      (row) => row['config']['mode'] == 'creation_bloom',
    );
    expect(cases, hasLength(3));
    for (final row in cases) {
      final run = CreationBloomRun(
        Map<String, dynamic>.from(row['config'] as Map),
      );
      for (final action in row['result']['actions'] as List) {
        expect(
          run.place(action['item_id'] as String, action['target_id'] as String),
          BloomPlacement.correct,
        );
      }
      expect(run.isComplete, row['outcome']['completed']);
      expect(run.matched, row['outcome']['correct_placements']);
      expect(run.actions.length, row['outcome']['attempts']);
      expect(run.result, row['result']);
      for (final placement in (row['outcome']['placements'] as Map).entries) {
        expect(
          run.itemsIn(placement.value as String).map((item) => item.id),
          contains(placement.key),
        );
      }
    }
  });

  test('garden records ordered attempts and consumes only a correct piece', () {
    final run = CreationBloomRun(_config);
    expect(run.place('fish', 'sky'), BloomPlacement.wrong);
    expect(run.isUsed('fish'), isFalse);
    expect(run.itemsIn('sky'), isEmpty);
    expect(run.place('fish', 'water'), BloomPlacement.correct);
    expect(run.place('fish', 'water'), BloomPlacement.ignored);
    expect(run.place('unknown', 'water'), BloomPlacement.ignored);
    expect(run.place('sun', 'unknown'), BloomPlacement.ignored);
    expect(run.place('sun', 'water'), BloomPlacement.wrong);
    expect(run.actions, [
      {'item_id': 'fish', 'target_id': 'sky'},
      {'item_id': 'fish', 'target_id': 'water'},
      {'item_id': 'sun', 'target_id': 'water'},
    ]);
    for (final item in run.items.where((item) => item.id != 'fish')) {
      expect(run.place(item.id, item.matchKey), BloomPlacement.correct);
    }
    expect(run.isComplete, isTrue);
    expect(run.itemsIn('sky'), hasLength(2));
    expect(run.itemsIn('meadow'), hasLength(2));
    expect(run.result.keys, ['actions']);
    expect(() => run.actions.add({}), throwsUnsupportedError);
    expect(
      () => run.actions.first['item_id'] = 'spoof',
      throwsUnsupportedError,
    );
    expect(run.place('sun', 'sky'), BloomPlacement.ignored);
  });

  test('invalid habitats, capacities and duplicate pieces cannot start', () {
    var config = _config;
    (config['targets'] as List).first['capacity'] = 1;
    expect(() => CreationBloomRun(config), throwsFormatException);
    config = _config;
    (config['items'] as List).last['id'] = 'sun';
    expect(() => CreationBloomRun(config), throwsFormatException);
    config = _config;
    (config['items'] as List).last['match_key'] = 'pond';
    expect(() => CreationBloomRun(config), throwsFormatException);
    config = _config;
    (config['targets'] as List).first['capacity'] = '2';
    expect(() => CreationBloomRun(config), throwsFormatException);
    config = _config;
    config['items'] = [...config['items'] as List, null];
    expect(() => CreationBloomRun(config), throwsFormatException);
  });

  test('wrong attempts are capped without inventing a completed garden', () {
    final run = CreationBloomRun(_config);
    for (var i = 0; i < 125; i++) {
      run.place('fish', 'sky');
    }
    expect(run.exhausted, isTrue);
    expect(run.actions, hasLength(120));
    expect(run.matched, 0);
    expect(run.isComplete, isFalse);
    expect(run.place('fish', 'water'), BloomPlacement.ignored);
  });

  testWidgets('tap matching and drag matching both grow the right habitat', (
    tester,
  ) async {
    await _pump(
      tester,
      CreationBloomEngine(level: _level, onComplete: (_) {}, onExit: () {}),
    );
    await _capture(tester, 'creation-bloom-phone');
    final fish = find.byKey(const Key('bloom-piece-fish'));
    final sky = find.byKey(const Key('bloom-target-sky'));
    await tester.dragFrom(
      tester.getCenter(fish),
      tester.getCenter(sky) - tester.getCenter(fish),
    );
    await tester.pumpAndSettle();
    expect(find.text('0 / 6'), findsOneWidget);
    expect(find.text('Try the river.'), findsOneWidget);
    expect(find.byKey(const Key('bloom-life-fish-alive')), findsNothing);
    await tester.tap(find.byKey(const Key('bloom-target-water')));
    await tester.pumpAndSettle();
    expect(find.text('1 / 6'), findsOneWidget);
    expect(find.byKey(const Key('bloom-life-fish-alive')), findsOneWidget);
    final tree = find.byKey(const Key('bloom-piece-tree'));
    final forest = find.byKey(const Key('bloom-target-forest'));
    await tester.dragFrom(
      tester.getCenter(tree),
      tester.getCenter(forest) - tester.getCenter(tree),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 / 6'), findsOneWidget);
    expect(find.byKey(const Key('bloom-life-tree-alive')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pause blocks matching and freezes the final living reveal', (
    tester,
  ) async {
    var paused = false;
    late StateSetter update;
    final results = <Map<String, dynamic>>[];
    await _pump(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return CreationBloomEngine(
            level: _level,
            paused: paused,
            onComplete: results.add,
          );
        },
      ),
    );
    update(() => paused = true);
    await tester.pump();
    await tester.tap(find.byKey(const Key('bloom-piece-fish')));
    await tester.tap(find.byKey(const Key('bloom-target-water')));
    await tester.pump();
    expect(find.text('0 / 6'), findsOneWidget);
    update(() => paused = false);
    await tester.pump();
    for (final item in _config['items'] as List) {
      await tester.tap(find.byKey(Key('bloom-piece-${item['id']}')));
      await tester.pump();
      await tester.tap(find.byKey(Key('bloom-target-${item['match_key']}')));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('6 / 6'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 900));
    await _capture(tester, 'creation-bloom-finished');
    expect(results, isEmpty);
    update(() => paused = true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(results, isEmpty);
    update(() => paused = false);
    await tester.pumpAndSettle();
    expect(results, hasLength(1));
    expect(results.single['actions'], hasLength(6));
    await tester.pump(const Duration(seconds: 3));
    expect(results, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('backgrounding blocks input until the garden resumes', (
    tester,
  ) async {
    await _pump(tester, CreationBloomEngine(level: _level, onComplete: (_) {}));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await tester.tap(find.byKey(const Key('bloom-piece-fish')));
    await tester.tap(find.byKey(const Key('bloom-target-water')));
    await tester.pumpAndSettle();
    expect(find.text('0 / 6'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.tap(find.byKey(const Key('bloom-piece-fish')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('bloom-target-water')));
    await tester.pumpAndSettle();
    expect(find.text('1 / 6'), findsOneWidget);
  });

  testWidgets(
    'small portrait and large text retain six pieces and four homes',
    (tester) async {
      await _pump(
        tester,
        CreationBloomEngine(level: _level, onComplete: (_) {}, onExit: () {}),
        size: const Size(320, 568),
        textScale: 1.7,
      );
      await _capture(tester, 'creation-bloom-small-phone');
      for (final item in _config['items'] as List) {
        final bounds = tester.getRect(
          find.byKey(Key('bloom-piece-${item['id']}')),
        );
        expect(bounds.height, greaterThanOrEqualTo(44));
        expect(bounds.width, greaterThanOrEqualTo(44));
        expect(bounds.bottom, lessThanOrEqualTo(568 - 34));
      }
      for (final target in _config['targets'] as List) {
        final bounds = tester.getRect(
          find.byKey(Key('bloom-target-${target['id']}')),
        );
        expect(bounds.height, greaterThanOrEqualTo(44));
        expect(bounds.width, greaterThanOrEqualTo(44));
      }
      expect(find.byType(Scrollable), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('bloom-piece-sun')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('bloom-target-sky')));
      await tester.pumpAndSettle();
      expect(find.text('1 / 6'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: const bool.fromEnvironment('BLOOM_CAPTURE')
          ? ThemeData(fontFamily: 'ReviewRoboto')
          : null,
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData.fromView(tester.view).copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: const EdgeInsets.only(top: 47, bottom: 34),
            viewPadding: const EdgeInsets.only(top: 47, bottom: 34),
          ),
          child: RepaintBoundary(key: const Key('bloom-capture'), child: child),
        ),
      ),
    ),
  );
  await tester.pump();
  if (const bool.fromEnvironment('BLOOM_CAPTURE')) {
    final context = tester.element(find.byKey(const Key('bloom-capture')));
    await tester.runAsync(
      () => precacheImage(
        const AssetImage('assets/images/games/matching/creation_garden.png'),
        context,
      ),
    );
    await tester.pump();
  }
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('BLOOM_CAPTURE')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('bloom-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final output = Directory('/private/tmp/kingdom-kids-matching-review');
    await output.create(recursive: true);
    await File(
      '${output.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

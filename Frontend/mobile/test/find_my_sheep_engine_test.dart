import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/find_my_sheep_model.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/find_my_sheep_engine.dart';

Map<String, dynamic> get _config => {
  'mode': 'sheep_reunion',
  'scene': 'sheep_meadow',
  'round_number': 1,
  'targets': [
    {'id': 'coral', 'match_key': 'coral_dots', 'capacity': 2},
    {'id': 'teal', 'match_key': 'teal_stripes', 'capacity': 2},
    {'id': 'gold', 'match_key': 'gold_zigzag', 'capacity': 2},
  ],
  'items': [
    {'id': 'lamb_1', 'match_key': 'coral_dots'},
    {'id': 'lamb_2', 'match_key': 'teal_stripes'},
    {'id': 'lamb_3', 'match_key': 'gold_zigzag'},
    {'id': 'lamb_4', 'match_key': 'teal_stripes'},
    {'id': 'lamb_5', 'match_key': 'coral_dots'},
    {'id': 'lamb_6', 'match_key': 'gold_zigzag'},
  ],
};

GameLevel get _level => GameLevel(
  id: 'sheep-1',
  number: 1,
  title: 'Find My Sheep',
  instructions: '',
  maxScore: 100,
  config: _config,
);

void main() {
  setUpAll(() async {
    if (const bool.fromEnvironment('SHEEP_CAPTURE')) {
      final loader = FontLoader('ReviewRoboto')
        ..addFont(
          File(
            '/opt/homebrew/share/flutter/engine/src/flutter/txt/third_party/fonts/Roboto-Regular.ttf',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await icons.load();
    }
  });

  test('matching records ordered attempts and consumes a lamb only once', () {
    final run = SheepReunionRun(_config);
    expect(run.place('lamb_1', 'teal'), SheepPlacement.wrong);
    expect(run.matched, 0);
    expect(run.place('lamb_1', 'coral'), SheepPlacement.correct);
    expect(run.place('lamb_1', 'coral'), SheepPlacement.ignored);
    expect(run.place('missing', 'coral'), SheepPlacement.ignored);
    expect(run.actions, [
      {'item_id': 'lamb_1', 'target_id': 'teal'},
      {'item_id': 'lamb_1', 'target_id': 'coral'},
    ]);
    expect(run.countFor('coral'), 1);
    for (final lamb in run.lambs.where((lamb) => !run.isPlaced(lamb.id))) {
      run.place(
        lamb.id,
        run.families
            .singleWhere((family) => family.matchKey == lamb.matchKey)
            .id,
      );
    }
    expect(run.isComplete, isTrue);
    expect(run.matched, 6);
    expect(run.result.keys, ['actions']);
    expect(run.actions, hasLength(7));
  });

  test('same colour with a different pattern remains a different family', () {
    final config = _config;
    final targets = config['targets'] as List;
    final items = config['items'] as List;
    targets[1]['match_key'] = 'coral_stripes';
    items[1]['match_key'] = 'coral_stripes';
    items[3]['match_key'] = 'coral_stripes';
    final run = SheepReunionRun(config);
    expect(run.place('lamb_1', 'teal'), SheepPlacement.wrong);
    expect(run.place('lamb_1', 'coral'), SheepPlacement.correct);
    expect(run.place('lamb_2', 'teal'), SheepPlacement.correct);
  });

  test('ambiguous families and unbalanced capacities fail before gameplay', () {
    final ambiguous = _config;
    (ambiguous['targets'] as List)[1]['match_key'] = 'coral_dots';
    expect(() => SheepReunionRun(ambiguous), throwsFormatException);
    final unbalanced = _config;
    (unbalanced['targets'] as List)[0]['capacity'] = 3;
    expect(() => SheepReunionRun(unbalanced), throwsFormatException);
    final missing = _config;
    (missing['items'] as List)[0]['match_key'] = 'invalid';
    expect(() => SheepReunionRun(missing), throwsFormatException);
  });

  test('attempt cap bounds payload without inventing a reunion', () {
    final run = SheepReunionRun(_config);
    for (var i = 0; i < 130; i++) {
      run.place('lamb_1', 'teal');
    }
    expect(run.exhausted, isTrue);
    expect(run.isComplete, isFalse);
    expect(run.actions, hasLength(120));
    expect(run.place('lamb_1', 'coral'), SheepPlacement.ignored);
  });

  testWidgets('wrong drag returns lamb; tap matching reunites the family', (
    tester,
  ) async {
    await _pump(
      tester,
      FindMySheepEngine(level: _level, onComplete: (_) {}, onExit: () {}),
    );
    await _capture(tester, 'find-my-sheep-phone');
    final lamb = find.byKey(const Key('sheep-lamb-lamb_1'));
    final wrong = find.byKey(const Key('sheep-family-teal'));
    await tester.dragFrom(
      tester.getCenter(lamb),
      tester.getCenter(wrong) - tester.getCenter(lamb),
    );
    await tester.pumpAndSettle();
    expect(find.text('0 / 6'), findsOneWidget);
    expect(lamb, findsOneWidget);
    // Wrong matching leaves the lamb selected, making a tap retry possible.
    await tester.tap(find.byKey(const Key('sheep-family-coral')));
    await tester.pumpAndSettle();
    expect(find.text('1 / 6'), findsOneWidget);
    expect(lamb, findsNothing);
    await tester.tap(find.byKey(const Key('sheep-lamb-lamb_2')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sheep-family-teal')));
    await tester.pumpAndSettle();
    expect(find.text('2 / 6'), findsOneWidget);
    await _capture(tester, 'find-my-sheep-reunion');
  });

  testWidgets(
    'pause blocks matching and freezes the arrival before one completion',
    (tester) async {
      var paused = false;
      late StateSetter update;
      final results = <Map<String, dynamic>>[];
      await _pump(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return FindMySheepEngine(
              level: _level,
              onComplete: results.add,
              paused: paused,
            );
          },
        ),
      );
      update(() => paused = true);
      await tester.pump();
      await tester.tap(find.byKey(const Key('sheep-lamb-lamb_1')));
      await tester.tap(find.byKey(const Key('sheep-family-coral')));
      await tester.pump();
      expect(find.text('0 / 6'), findsOneWidget);
      update(() => paused = false);
      await tester.pump();
      const homes = ['coral', 'teal', 'gold', 'teal', 'coral', 'gold'];
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.byKey(Key('sheep-lamb-lamb_${i + 1}')));
        await tester.pump();
        await tester.tap(find.byKey(Key('sheep-family-${homes[i]}')));
        await tester.pump(const Duration(milliseconds: 100));
        if (i < 5) await tester.pumpAndSettle();
      }
      expect(find.text('6 / 6'), findsOneWidget);
      update(() => paused = true);
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(results, isEmpty);
      update(() => paused = false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pump(const Duration(milliseconds: 700));
      await _capture(tester, 'find-my-sheep-finished');
      await tester.pumpAndSettle();
      expect(results, hasLength(1));
      expect(results.single['actions'], hasLength(6));
      await tester.pump(const Duration(seconds: 4));
      expect(results, hasLength(1));
    },
  );

  testWidgets('backgrounding freezes a moving lamb and prevents completion', (
    tester,
  ) async {
    final results = <Map<String, dynamic>>[];
    await _pump(
      tester,
      FindMySheepEngine(level: _level, onComplete: results.add),
    );
    await tester.tap(find.byKey(const Key('sheep-lamb-lamb_1')));
    await tester.tap(find.byKey(const Key('sheep-family-coral')));
    await tester.pump(const Duration(milliseconds: 100));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    // The first arrival must remain in progress, so a second lamb cannot move.
    await tester.tap(find.byKey(const Key('sheep-lamb-lamb_2')));
    await tester.tap(find.byKey(const Key('sheep-family-teal')));
    await tester.pump();
    expect(find.text('1 / 6'), findsOneWidget);
    expect(results, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sheep-lamb-lamb_2')));
    await tester.tap(find.byKey(const Key('sheep-family-teal')));
    await tester.pumpAndSettle();
    expect(find.text('2 / 6'), findsOneWidget);
  });

  testWidgets('meadow fits a small portrait with safe area and larger text', (
    tester,
  ) async {
    await _pump(
      tester,
      FindMySheepEngine(level: _level, onComplete: (_) {}, onExit: () {}),
      size: const Size(320, 568),
      textScale: 1.7,
      padding: const EdgeInsets.only(top: 24, bottom: 20),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(Scrollable), findsNothing);
    for (var i = 1; i <= 6; i++) {
      final bounds = tester.getRect(find.byKey(Key('sheep-lamb-lamb_$i')));
      expect(bounds.width, greaterThanOrEqualTo(44));
      expect(bounds.height, greaterThanOrEqualTo(44));
      expect(bounds.left, greaterThanOrEqualTo(0));
      expect(bounds.right, lessThanOrEqualTo(320));
    }
    for (final id in ['coral', 'teal', 'gold']) {
      final bounds = tester.getRect(find.byKey(Key('sheep-family-$id')));
      expect(bounds.bottom, lessThanOrEqualTo(548));
      expect(bounds.width, greaterThanOrEqualTo(44));
    }
    await _capture(tester, 'find-my-sheep-small-phone');
    await tester.tap(find.byKey(const Key('sheep-lamb-lamb_1')));
    await tester.tap(find.byKey(const Key('sheep-family-coral')));
    await tester.pumpAndSettle();
    expect(find.text('1 / 6'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(390, 844),
  double textScale = 1,
  EdgeInsets padding = EdgeInsets.zero,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: const bool.fromEnvironment('SHEEP_CAPTURE')
          ? ThemeData(fontFamily: 'ReviewRoboto')
          : null,
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData.fromView(tester.view).copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: padding,
          ),
          child: RepaintBoundary(key: const Key('sheep-capture'), child: child),
        ),
      ),
    ),
  );
  await tester.pump();
  if (const bool.fromEnvironment('SHEEP_CAPTURE')) {
    final context = tester.element(find.byKey(const Key('sheep-capture')));
    await tester.runAsync(
      () => Future.wait([
        precacheImage(
          const AssetImage('assets/images/games/matching/sheep_meadow.png'),
          context,
        ),
        precacheImage(
          const AssetImage('assets/images/games/matching/sheep_lamb.png'),
          context,
        ),
      ]),
    );
    await tester.pump();
  }
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('SHEEP_CAPTURE')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('sheep-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('/private/tmp/kingdom-kids-matching-review');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

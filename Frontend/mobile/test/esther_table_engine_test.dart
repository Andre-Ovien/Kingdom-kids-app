import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/esther_table_model.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/esther_table_engine.dart';

const _foods = ['bread', 'grapes', 'figs', 'water', 'flowers', 'dates'];

Map<String, dynamic> _config([int round = 1]) => {
  'mode': 'esther_table',
  'scene': 'esther_banquet',
  'round_number': round,
  'targets': [
    for (var i = 0; i < 6; i++)
      {
        'id': 'seat_${i + 1}',
        'match_key': _foods[(i + round - 1) % 6],
        'capacity': 1,
      },
  ],
  'items': [
    for (final food in _foods) {'id': food, 'match_key': food},
  ],
};

GameLevel _level([int round = 1]) => GameLevel(
  id: 'esther-$round',
  number: round,
  title: 'Esther’s Celebration Table',
  instructions: '',
  config: _config(round),
  maxScore: 100,
);

void main() {
  setUpAll(() async {
    if (const bool.fromEnvironment('ESTHER_CAPTURE')) {
      final font = FontLoader('ReviewRoboto')
        ..addFont(
          File(
            '/opt/homebrew/share/flutter/engine/src/flutter/txt/third_party/fonts/Roboto-Regular.ttf',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await icons.load();
    }
  });

  test(
    'all three table arrangements score exact matches and preserve replay order',
    () {
      for (var round = 1; round <= 3; round++) {
        final run = EstherTableRun(_config(round));
        final first = run.targets.first;
        final wrong = run.items.firstWhere(
          (item) => item.matchKey != first.matchKey,
        );
        expect(run.place(wrong.id, first.id), EstherPlacement.wrong);
        expect(run.matched, 0);
        for (final target in run.targets) {
          final item = run.items.singleWhere(
            (item) => item.matchKey == target.matchKey,
          );
          expect(run.place(item.id, target.id), EstherPlacement.correct);
        }
        expect(run.isComplete, isTrue);
        expect(run.actions.length, 7);
        expect(run.actions.first, {'item_id': wrong.id, 'target_id': first.id});
        expect(run.score, 96);
        expect(run.result.keys, ['actions']);
        expect(run.place(wrong.id, first.id), EstherPlacement.ignored);
        expect(run.actions.length, 7);
      }
    },
  );

  test(
    'a dish cannot be served twice and invalid placements do not invent attempts',
    () {
      final run = EstherTableRun(_config());
      expect(run.place('bread', 'seat_1'), EstherPlacement.correct);
      expect(run.place('bread', 'seat_2'), EstherPlacement.ignored);
      expect(run.place('grapes', 'seat_1'), EstherPlacement.ignored);
      expect(run.place('missing', 'seat_2'), EstherPlacement.ignored);
      expect(run.place('grapes', 'missing'), EstherPlacement.ignored);
      expect(run.actions, hasLength(1));
      expect(run.score, 8);
      expect(() => run.actions.add({}), throwsUnsupportedError);
      expect(
        () => run.actions.first['item_id'] = 'changed',
        throwsUnsupportedError,
      );
    },
  );

  test(
    'duplicate requests, unsupported foods and invalid capacity fail closed',
    () {
      for (final bad in [
        {..._config(), 'round_number': 4},
        {..._config(), 'scene': 'unknown'},
        {
          ..._config(),
          'items': [
            {'id': 'bread', 'match_key': 'bread'},
          ],
        },
        {
          ..._config(),
          'targets': [
            for (var i = 1; i <= 6; i++)
              {'id': 'seat_$i', 'match_key': 'bread', 'capacity': 1},
          ],
        },
        {
          ..._config(),
          'targets': [
            for (var i = 0; i < 6; i++)
              {
                'id': 'seat_${i + 1}',
                'match_key': _foods[i],
                'capacity': i == 0 ? 2 : 1,
              },
          ],
        },
      ]) {
        expect(() => EstherTableRun(bad), throwsFormatException);
      }
    },
  );

  test('wrong matches stop at the replay cap without completing', () {
    final run = EstherTableRun(_config());
    for (var i = 0; i < 130; i++) {
      run.place('bread', 'seat_2');
    }
    expect(run.exhausted, isTrue);
    expect(run.actions, hasLength(120));
    expect(run.isComplete, isFalse);
    expect(run.score, 0);
  });

  testWidgets(
    'wrong drag keeps the dish; correct tap and drag fill two settings',
    (tester) async {
      await _pump(
        tester,
        EstherTableEngine(level: _level(), onComplete: (_) {}, onExit: () {}),
      );
      await _capture(tester, 'esther-table-phone');
      final bread = find.byKey(const Key('esther-item-bread'));
      final wrong = find.byKey(const Key('esther-target-seat_2'));
      await tester.dragFrom(
        tester.getCenter(bread),
        tester.getCenter(wrong) - tester.getCenter(bread),
      );
      await tester.pumpAndSettle();
      expect(find.text('0 / 6'), findsOneWidget);
      await tester.tap(find.byKey(const Key('esther-target-seat_1')));
      await tester.pumpAndSettle();
      expect(find.text('1 / 6'), findsOneWidget);
      expect(find.bySemanticsLabel('Served Bread'), findsOneWidget);
      final grapes = find.byKey(const Key('esther-item-grapes'));
      final destination = find.byKey(const Key('esther-target-seat_2'));
      await tester.dragFrom(
        tester.getCenter(grapes),
        tester.getCenter(destination) - tester.getCenter(grapes),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 / 6'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(tester, 'esther-table-matching');
    },
  );

  testWidgets(
    'exit and background pause the reveal and completion submits once',
    (tester) async {
      var paused = false;
      late StateSetter update;
      final results = <Map<String, dynamic>>[];
      await _pump(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return EstherTableEngine(
              level: _level(),
              onComplete: results.add,
              paused: paused,
            );
          },
        ),
      );
      update(() => paused = true);
      await tester.pump();
      await tester.tap(find.byKey(const Key('esther-item-bread')));
      await tester.tap(find.byKey(const Key('esther-target-seat_1')));
      await tester.pump();
      expect(find.text('0 / 6'), findsOneWidget);
      update(() => paused = false);
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.byKey(Key('esther-item-${_foods[i]}')));
        await tester.pump();
        await tester.tap(find.byKey(Key('esther-target-seat_${i + 1}')));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('6 / 6'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      await _capture(tester, 'esther-table-complete');
      update(() => paused = true);
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(results, isEmpty);
      update(() => paused = false);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 3));
      expect(results, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(results, hasLength(1));
      expect(results.single['actions'], hasLength(6));
      await tester.pump(const Duration(seconds: 3));
      expect(results, hasLength(1));
    },
  );

  testWidgets(
    'entry instructions block play, dismiss without exiting, and show once per round',
    (tester) async {
      var paused = false;
      var round = 1;
      var exits = 0;
      late StateSetter update;
      await _pump(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return EstherTableEngine(
              level: _level(round),
              onComplete: (_) {},
              onExit: () => exits++,
              paused: paused,
            );
          },
        ),
        dismissInstructions: false,
      );
      expect(
        find.byKey(const Key('esther-instructions-overlay')),
        findsOneWidget,
      );
      await _capture(tester, 'esther-table-instructions');
      await tester.tap(
        find.byKey(const Key('esther-item-bread')),
        warnIfMissed: false,
      );
      await tester.tap(
        find.byKey(const Key('esther-target-seat_1')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(find.text('0 / 6'), findsOneWidget);
      update(() => paused = true);
      await tester.pump();
      await tester.tap(find.byKey(const Key('esther-instructions-close')));
      await tester.pump();
      expect(
        find.byKey(const Key('esther-instructions-overlay')),
        findsOneWidget,
      );
      update(() => paused = false);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('esther-instructions-play')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('esther-instructions-overlay')),
        findsNothing,
      );
      expect(
        find.text('Match each dish to its place at the table.'),
        findsNothing,
      );
      expect(find.text('Celebration Table'), findsNothing);
      expect(exits, 0);
      update(() {});
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(
        find.byKey(const Key('esther-instructions-overlay')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('esther-exit')));
      expect(exits, 1);
      update(() => round = 2);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('esther-instructions-overlay')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('esther-instructions-close')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('esther-instructions-overlay')),
        findsNothing,
      );
      expect(exits, 1);
    },
  );

  testWidgets(
    'banquet art covers the viewport while settings clear the floating controls',
    (tester) async {
      for (final scenario in [
        (const Size(390, 844), const EdgeInsets.fromLTRB(0, 47, 0, 34), 1.0),
        (const Size(320, 568), const EdgeInsets.fromLTRB(0, 24, 0, 16), 1.7),
      ]) {
        await _pump(
          tester,
          EstherTableEngine(level: _level(), onComplete: (_) {}, onExit: () {}),
          size: scenario.$1,
          padding: scenario.$2,
          textScale: scenario.$3,
        );
        final background = tester.getRect(
          find.byKey(const Key('esther-banquet-background')),
        );
        expect(background, Offset.zero & scenario.$1);
        final image = tester.widget<Image>(
          find.byKey(const Key('esther-banquet-background')),
        );
        expect(image.fit, BoxFit.cover);
        expect(image.alignment, Alignment.topCenter);
        expect(
          (image.image as AssetImage).assetName,
          'assets/images/games/matching/esther_banquet_fullscreen_v2.png',
        );
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Image &&
                widget.image is AssetImage &&
                (widget.image as AssetImage).assetName.contains(
                  'esther_banquet',
                ),
          ),
          findsOneWidget,
        );
        final back = tester.getRect(find.byKey(const Key('esther-exit')));
        final badge = tester.getRect(
          find.byKey(const Key('esther-progress-badge')),
        );
        final tray = tester.getRect(
          find.byKey(const Key('esther-floating-tray')),
        );
        final trayPaint = tester.getRect(
          find
              .descendant(
                of: find.byKey(const Key('esther-floating-tray')),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        expect(back.top, greaterThanOrEqualTo(scenario.$2.top));
        expect(badge.top, greaterThanOrEqualTo(scenario.$2.top));
        expect(back.overlaps(badge), isFalse);
        expect(find.byKey(const Key('esther-floating-header')), findsNothing);
        expect(trayPaint.left, greaterThan(0));
        expect(trayPaint.right, lessThan(scenario.$1.width));
        expect(
          trayPaint.bottom,
          lessThanOrEqualTo(scenario.$1.height - scenario.$2.bottom),
        );
        final plates = <Rect>[];
        for (var index = 1; index <= 6; index++) {
          final bounds = tester.getRect(
            find.byKey(Key('esther-target-seat_$index')),
          );
          expect(bounds.shortestSide, greaterThanOrEqualTo(44));
          expect(bounds.top, greaterThan(math.max(back.bottom, badge.bottom)));
          expect(bounds.bottom, lessThan(tray.top));
          expect(background.contains(bounds.topLeft), isTrue);
          expect(background.contains(bounds.bottomRight), isTrue);
          expect(plates.any((previous) => previous.overlaps(bounds)), isFalse);
          plates.add(bounds);
        }
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'small phone with enlarged text keeps every dish and setting reachable',
    (tester) async {
      await _pump(
        tester,
        EstherTableEngine(level: _level(), onComplete: (_) {}, onExit: () {}),
        size: const Size(320, 568),
        textScale: 1.7,
        padding: const EdgeInsets.fromLTRB(0, 24, 0, 16),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(Scrollable), findsNothing);
      final scene = tester.getRect(
        find.byKey(const Key('esther-banquet-scene')),
      );
      for (final food in _foods) {
        final bounds = tester.getRect(find.byKey(Key('esther-item-$food')));
        expect(bounds.height, greaterThanOrEqualTo(44));
        expect(bounds.bottom, lessThanOrEqualTo(568));
      }
      for (var i = 1; i <= 6; i++) {
        final bounds = tester.getRect(find.byKey(Key('esther-target-seat_$i')));
        expect(bounds.height, greaterThanOrEqualTo(44));
        expect(bounds.bottom, lessThanOrEqualTo(568));
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(320));
        expect(bounds.bottom, lessThanOrEqualTo(scene.bottom + .01));
      }
      await _capture(tester, 'esther-table-small-before');
      await tester.tap(find.byKey(const Key('esther-item-bread')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('esther-target-seat_1')));
      await tester.pumpAndSettle();
      expect(find.text('1 / 6'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(tester, 'esther-table-small-phone');
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(390, 844),
  double textScale = 1,
  EdgeInsets padding = const EdgeInsets.fromLTRB(0, 47, 0, 34),
  bool dismissInstructions = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: const bool.fromEnvironment('ESTHER_CAPTURE')
          ? ThemeData(fontFamily: 'ReviewRoboto')
          : null,
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData.fromView(tester.view).copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: padding,
          ),
          child: RepaintBoundary(
            key: const Key('esther-capture'),
            child: child,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  if (const bool.fromEnvironment('ESTHER_CAPTURE')) {
    final context = tester.element(find.byKey(const Key('esther-capture')));
    await tester.runAsync(
      () => Future.wait([
        precacheImage(
          const AssetImage(
            'assets/images/games/matching/esther_banquet_fullscreen_v2.png',
          ),
          context,
        ),
        precacheImage(
          const AssetImage('assets/images/games/matching/banquet_feast.png'),
          context,
        ),
      ]),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
  if (dismissInstructions &&
      find
          .byKey(const Key('esther-instructions-close'))
          .evaluate()
          .isNotEmpty) {
    await tester.tap(find.byKey(const Key('esther-instructions-close')));
    await tester.pumpAndSettle();
  }
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('ESTHER_CAPTURE')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('esther-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory(
      '/Volumes/ANDRE_DEV/Projects/Kingdom-kids-app/output/esther-fullscreen-20261101/revision-3',
    );
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

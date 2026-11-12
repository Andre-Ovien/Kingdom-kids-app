import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/joseph_coat.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/joseph_coat_engine.dart';

const _panels = [
  {'id': 'left_shoulder', 'color': 'coral', 'pattern': 'dots'},
  {'id': 'right_shoulder', 'color': 'coral', 'pattern': 'stripes'},
  {'id': 'left_body', 'color': 'teal', 'pattern': 'zigzag'},
  {'id': 'right_body', 'color': 'forest', 'pattern': 'dots'},
  {'id': 'left_hem', 'color': 'sky', 'pattern': 'stripes'},
  {'id': 'right_hem', 'color': 'lilac', 'pattern': 'zigzag'},
];

Map<String, dynamic> get _config => {
  'mode': 'coat_studio',
  'panels': _panels,
  'swatches': [
    for (var i = 0; i < _panels.length; i++)
      {..._panels[i], 'id': 'fabric_${i + 1}'},
  ],
};

GameLevel get _level => GameLevel(
  id: 'coat-1',
  number: 1,
  title: 'Joseph’s Coat Studio',
  instructions: '',
  maxScore: 100,
  config: _config,
);

void main() {
  setUpAll(() async {
    if (const bool.fromEnvironment('COAT_CAPTURE')) {
      final font = FontLoader('ReviewRoboto')
        ..addFont(
          File(
            '/opt/homebrew/share/flutter/engine/src/flutter/txt/third_party/fonts/Roboto-Regular.ttf',
          ).readAsBytes().then((value) => ByteData.sublistView(value)),
        );
      await font.load();
    }
  });
  test(
    'cloth matches colour and pattern; server receives every valid attempt',
    () {
      final run = JosephCoatRun(_config);
      expect(run.place('right_shoulder', 'fabric_1'), CoatPlacement.wrong);
      expect(run.matched, 0);
      expect(run.place('left_shoulder', 'fabric_1'), CoatPlacement.correct);
      expect(run.place('left_shoulder', 'fabric_1'), CoatPlacement.ignored);
      expect(run.place('unknown', 'fabric_2'), CoatPlacement.ignored);
      expect(run.actions, [
        {'panel_id': 'right_shoulder', 'swatch_id': 'fabric_1'},
        {'panel_id': 'left_shoulder', 'swatch_id': 'fabric_1'},
      ]);
      for (var i = 1; i < _panels.length; i++) {
        expect(
          run.place(_panels[i]['id']!, 'fabric_${i + 1}'),
          CoatPlacement.correct,
        );
      }
      expect(run.isComplete, isTrue);
      expect(run.result.keys, ['actions']);
      expect(run.place('right_hem', 'fabric_2'), CoatPlacement.ignored);
      expect(run.actions.length, 7);
    },
  );

  test('bad or ambiguous cloth configuration cannot start a false game', () {
    final config = _config;
    config['swatches'] = [
      for (var i = 0; i < 6; i++)
        {'id': 'fabric_${i + 1}', 'color': 'coral', 'pattern': 'dots'},
    ];
    expect(() => JosephCoatRun(config), throwsFormatException);
  });

  test(
    'attempt cap does not fabricate completion or allow unbounded payload',
    () {
      final run = JosephCoatRun(_config);
      for (var i = 0; i < 130; i++) {
        run.place('right_shoulder', 'fabric_1');
      }
      expect(run.exhausted, isTrue);
      expect(run.isComplete, isFalse);
      expect(run.actions, hasLength(120));
    },
  );

  testWidgets(
    'dragging wrong fabric returns it; tap placement sews the right patch',
    (tester) async {
      await _pump(tester, JosephCoatEngine(level: _level, onComplete: (_) {}));
      await _capture(tester, 'joseph-studio-phone');
      final source = find.byKey(const Key('coat-swatch-fabric_1'));
      final wrong = find.byKey(const Key('coat-panel-right_shoulder'));
      await tester.dragFrom(
        tester.getCenter(source),
        tester.getCenter(wrong) - tester.getCenter(source),
      );
      await tester.pumpAndSettle();
      expect(find.text('0 / 6'), findsOneWidget);
      expect(source, findsOneWidget);
      // An incorrect drop keeps the same fabric selected for a tap retry.
      await tester.tap(find.byKey(const Key('coat-panel-left_shoulder')));
      await tester.pumpAndSettle();
      expect(find.text('1 / 6'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Sewn left shoulder patch, coral dots'),
        findsOneWidget,
      );
      final next = find.byKey(const Key('coat-swatch-fabric_2'));
      final target = find.byKey(const Key('coat-panel-right_shoulder'));
      await tester.dragFrom(
        tester.getCenter(next),
        tester.getCenter(target) - tester.getCenter(next),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 / 6'), findsOneWidget);
    },
  );

  testWidgets(
    'pause blocks input and suspends final reveal; completion fires once',
    (tester) async {
      final results = <Map<String, dynamic>>[];
      var paused = false;
      late StateSetter update;
      await _pump(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return JosephCoatEngine(
              level: _level,
              onComplete: results.add,
              paused: paused,
            );
          },
        ),
      );
      update(() => paused = true);
      await tester.pump();
      await tester.tap(find.byKey(const Key('coat-swatch-fabric_1')));
      await tester.tap(find.byKey(const Key('coat-panel-left_shoulder')));
      await tester.pump();
      expect(find.text('0 / 6'), findsOneWidget);
      update(() => paused = false);
      await tester.pump();
      for (var i = 0; i < _panels.length; i++) {
        await tester.tap(find.byKey(Key('coat-swatch-fabric_${i + 1}')));
        await tester.pump();
        await tester.tap(find.byKey(Key('coat-panel-${_panels[i]['id']}')));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('6 / 6'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 800));
      await _capture(tester, 'joseph-studio-finished');
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
    },
  );

  testWidgets(
    'studio fits small portrait and enlarged text without game scrolling',
    (tester) async {
      await _pump(
        tester,
        JosephCoatEngine(level: _level, onComplete: (_) {}, onExit: () {}),
        textScale: 1.7,
        size: const Size(320, 568),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(Scrollable), findsNothing);
      for (var i = 1; i <= 6; i++) {
        final bounds = tester.getRect(find.byKey(Key('coat-swatch-fabric_$i')));
        expect(bounds.top, greaterThanOrEqualTo(0));
        expect(bounds.bottom, lessThanOrEqualTo(568));
        expect(bounds.height, greaterThanOrEqualTo(42));
      }
      await tester.tap(find.byKey(const Key('coat-swatch-fabric_1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('coat-panel-left_shoulder')));
      await tester.pumpAndSettle();
      expect(find.text('1 / 6'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double textScale = 1,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: const bool.fromEnvironment('COAT_CAPTURE')
          ? ThemeData(fontFamily: 'ReviewRoboto')
          : null,
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData.fromView(
            tester.view,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: RepaintBoundary(key: const Key('coat-capture'), child: child),
        ),
      ),
    ),
  );
  await tester.pump();
  if (const bool.fromEnvironment('COAT_CAPTURE')) {
    final context = tester.element(find.byKey(const Key('coat-capture')));
    await tester.runAsync(
      () => Future.wait([
        precacheImage(
          const AssetImage('assets/images/games/matching/joseph_atelier.png'),
          context,
        ),
        precacheImage(
          const AssetImage('assets/images/games/matching/joseph_character.png'),
          context,
        ),
      ]),
    );
    await tester.pump();
  }
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('COAT_CAPTURE')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('coat-capture')),
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

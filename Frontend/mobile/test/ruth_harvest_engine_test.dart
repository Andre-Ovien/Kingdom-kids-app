import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/ruth_harvest_engine.dart';

final _fixture =
    (jsonDecode(
              File(
                'test/fixtures/ruth_harvest_golden_v1.json',
              ).readAsStringSync(),
            )
            as Map)['rounds'][0]
        as Map;

GameLevel _level({String id = 'ruth-1', Map<String, dynamic>? overrides}) =>
    GameLevel(
      id: id,
      number: 1,
      title: 'A Little Kindness',
      instructions: 'Join matching grain for Naomi.',
      config: {
        ...Map<String, dynamic>.from(_fixture['config'] as Map),
        ...?overrides,
      },
      maxScore: 100,
    );

Future<void> _load(
  WidgetTester tester, {
  bool paused = false,
  bool reducedMotion = false,
  GameLevel? level,
  void Function(Map<String, dynamic>)? onComplete,
  VoidCallback? onExit,
  Size size = const Size(390, 844),
  EdgeInsets padding = EdgeInsets.zero,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: const bool.fromEnvironment('RUTH_CAPTURE')
          ? ThemeData(fontFamily: 'ReviewRoboto')
          : null,
      home: MediaQuery(
        data: MediaQueryData(
          size: tester.view.physicalSize,
          disableAnimations: reducedMotion,
          padding: padding,
        ),
        child: Scaffold(
          body: RepaintBoundary(
            key: const Key('ruth-capture'),
            child: RuthHarvestEngine(
              level: level ?? _level(),
              paused: paused,
              onComplete: onComplete ?? (_) {},
              onExit: onExit ?? () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  if (const bool.fromEnvironment('RUTH_CAPTURE')) {
    final context = tester.element(find.byKey(const Key('ruth-capture')));
    await tester.runAsync(
      () => Future.wait([
        for (final name in [
          'ruth_field',
          'grain_wheat',
          'grain_barley',
          'grain_oats',
        ])
          precacheImage(
            AssetImage('assets/images/games/matching/$name.png'),
            context,
          ),
      ]),
    );
    await tester.pump();
  }
}

Future<void> _tapChain(WidgetTester tester, List<int> chain) async {
  for (final cell in chain) {
    await tester.tap(find.byKey(Key('ruth-cell-$cell')));
    await tester.pump();
  }
}

Finder get _harvest => find.byKey(const Key('ruth-harvest-button'));

void main() {
  setUpAll(() async {
    if (const bool.fromEnvironment('RUTH_CAPTURE')) {
      final font = FontLoader('ReviewRoboto')
        ..addFont(
          File(
            '/opt/homebrew/share/flutter/engine/src/flutter/txt/third_party/fonts/Roboto-Regular.ttf',
          ).readAsBytes().then((value) => ByteData.sublistView(value)),
        );
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then((value) => ByteData.sublistView(value)),
        );
      await icons.load();
    }
  });
  testWidgets('portrait layout fits a small phone with readable goals', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _load(tester, size: const Size(320, 568));
    await _capture(tester, 'ruth-harvest-small-phone');
    expect(tester.takeException(), isNull);
    expect(find.text('Ruth’s Harvest'), findsOneWidget);
    expect(find.text('18 gathers'), findsOneWidget);
    expect(find.text('Wheat  0/9'), findsOneWidget);
    expect(find.text('Barley  0/6'), findsOneWidget);
    expect(find.text('Oats  0/6'), findsOneWidget);
    final last = tester.getRect(find.byKey(const Key('ruth-cell-29')));
    final button = tester.getRect(_harvest);
    expect(last.bottom, lessThan(button.top));
    expect(last.width, greaterThanOrEqualTo(44));
    expect(last.height, greaterThanOrEqualTo(44));
    expect(button.bottom, lessThanOrEqualTo(568));
  });

  testWidgets(
    'small-phone safe areas still leave forty-four-pixel grain targets',
    (tester) async {
      await _load(
        tester,
        size: const Size(320, 568),
        padding: const EdgeInsets.only(top: 20),
      );
      expect(tester.takeException(), isNull);
      for (var cell = 0; cell < 30; cell++) {
        final bounds = tester.getRect(find.byKey(Key('ruth-cell-$cell')));
        expect(bounds.width, greaterThanOrEqualTo(44));
        expect(bounds.height, greaterThanOrEqualTo(44));
      }
      await _tapChain(tester, [0, 5, 6]);
      await tester.tap(_harvest);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      expect(find.text('17 gathers'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tap-to-chain harvests without requiring a drag gesture', (
    tester,
  ) async {
    await _load(tester);
    await _capture(tester, 'ruth-harvest-phone');
    await _tapChain(tester, [0, 5, 6]);
    await _capture(tester, 'ruth-harvest-chain');
    expect(find.text('Harvest 3 bundles'), findsOneWidget);
    await tester.tap(_harvest);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.text('17 gathers'), findsOneWidget);
    expect(find.text('Oats  3/6'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('drag remembers the down cell and supports stepping back', (
    tester,
  ) async {
    await _load(tester);
    final p0 = tester.getCenter(find.byKey(const Key('ruth-cell-0')));
    final p5 = tester.getCenter(find.byKey(const Key('ruth-cell-5')));
    final p6 = tester.getCenter(find.byKey(const Key('ruth-cell-6')));
    final gesture = await tester.startGesture(p0);
    await gesture.moveTo(p5);
    await tester.pump();
    await gesture.moveTo(p6);
    await tester.pump();
    expect(find.text('Harvest 3 bundles'), findsOneWidget);
    await gesture.moveTo(p5);
    await tester.pump();
    expect(find.text('Harvest 3 bundles'), findsNothing);
    await gesture.moveTo(p6);
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.text('Oats  3/6'), findsOneWidget);
    expect(find.text('17 gathers'), findsOneWidget);
  });

  testWidgets('short and wrong-grain trails do not use a gather', (
    tester,
  ) async {
    await _load(tester);
    await _tapChain(tester, [0, 1]);
    expect(
      find.text('Stay with the same grain, one neighbour at a time.'),
      findsOneWidget,
    );
    expect(find.text('18 gathers'), findsOneWidget);
    final p0 = tester.getCenter(find.byKey(const Key('ruth-cell-0')));
    final p5 = tester.getCenter(find.byKey(const Key('ruth-cell-5')));
    final gesture = await tester.startGesture(p0);
    await gesture.moveTo(p5);
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(
      find.text('Nearly! Join at least 3 matching bundles.'),
      findsOneWidget,
    );
    expect(find.text('18 gathers'), findsOneWidget);
  });

  testWidgets(
    'host pause blocks interaction and freezes an in-flight harvest',
    (tester) async {
      final level = _level();
      var completions = 0;
      void complete(Map<String, dynamic> _) => completions++;
      await _load(tester, level: level, paused: true, onComplete: complete);
      await _tapChain(tester, [0, 5, 6]);
      expect(find.text('Harvest 3 bundles'), findsNothing);
      await _load(tester, level: level, onComplete: complete);
      await _tapChain(tester, [0, 5, 6]);
      await tester.tap(_harvest);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));
      await _load(tester, level: level, paused: true, onComplete: complete);
      final position = tester.getTopLeft(
        find.byKey(const Key('ruth-flying-0')),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(
        tester.getTopLeft(find.byKey(const Key('ruth-flying-0'))),
        position,
      );
      expect(completions, 0);
      await _load(tester, level: level, onComplete: complete);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('17 gathers'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('all goals submit the exact replay once after the last harvest', (
    tester,
  ) async {
    final submissions = <Map<String, dynamic>>[];
    await _load(tester, onComplete: submissions.add);
    final result = _fixture['winning_result'] as Map;
    for (final chain in result['chains'] as List) {
      await _tapChain(tester, (chain as List).cast<int>());
      await tester.tap(_harvest);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
    }
    expect(submissions, [result]);
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(_harvest);
    await tester.pump();
    expect(submissions.length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('backgrounding freezes harvest; reduced motion still submits', (
    tester,
  ) async {
    final level = _level(
      overrides: {
        'max_chains': 1,
        'goals': {'wheat': 100, 'barley': 100, 'oats': 100},
      },
    );
    final submissions = <Map<String, dynamic>>[];
    await _load(tester, level: level, onComplete: submissions.add);
    await _tapChain(tester, [0, 5, 6]);
    await tester.tap(_harvest);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 2));
    expect(submissions, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(submissions.length, 1);
    await _load(
      tester,
      level: _level(id: 'ruth-reduced', overrides: {'max_chains': 1}),
      reducedMotion: true,
      onComplete: submissions.add,
    );
    await _tapChain(tester, [0, 5, 6]);
    await tester.tap(_harvest);
    await tester.pump();
    expect(submissions.length, 2);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('RUTH_CAPTURE')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('ruth-capture')),
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

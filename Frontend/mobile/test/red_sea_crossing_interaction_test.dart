import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/red_sea_crossing_engine.dart';
import 'package:mobile/features/games/presentation/red_sea_crossing_model.dart';
import 'package:mobile/features/games/presentation/red_sea_crossing_renderer.dart';

void main() {
  setUpAll(() async {
    if (!_captureEnabled) return;
    const directory =
        '/Users/macbook/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/libreoffice-headless/libreoffice/LibreOfficeDev.app/Contents/Resources/fonts/truetype';
    final font = FontLoader('Roboto');
    for (final name in ['NotoSans-Regular.ttf', 'NotoSans-Bold.ttf']) {
      final bytes = await File('$directory/$name').readAsBytes();
      font.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await font.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets('actual ready, opening, dry path and walking scene previews', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boundary = GlobalKey();
    final completed = <Map<String, dynamic>>[];
    await _pumpEngine(
      tester,
      completed,
      boundary: boundary,
      level: _level(polygon: true),
    );
    await _capture(tester, boundary, 'ready');
    await _start(tester);
    await _frames(tester, 13);
    expect(_run(tester).phase, RedSeaCrossingPhase.parting);
    expect(_run(tester).elapsed, 0);
    await _capture(tester, boundary, 'parting');
    await _frames(tester, 13);
    expect(_run(tester).phase, RedSeaCrossingPhase.placing);
    await _capture(tester, boundary, 'parted');
    for (var index = 0; index < 6; index++) {
      await _drag(tester, index, _authoredDrop(index));
    }
    expect(_run(tester).phase, RedSeaCrossingPhase.walking);
    await _frames(tester, 20);
    await _capture(tester, boundary, 'walking');
    expect(completed, isEmpty);
    expect(tester.takeException(), isNull);
    await _dispose(tester);
  });

  testWidgets('the timer begins only after the 2.6 second sea opening', (
    tester,
  ) async {
    await _pumpEngine(tester, []);
    await _frames(tester, 10);
    expect(_run(tester).phase, RedSeaCrossingPhase.ready);
    expect(find.text('45s'), findsOneWidget);
    await _start(tester);
    await _frames(tester, 25);
    expect(_run(tester).phase, RedSeaCrossingPhase.parting);
    expect(_run(tester).elapsed, 0);
    expect(
      find.byKey(const Key('red-sea-traveller-traveller-1')),
      findsNothing,
    );
    await _frames(tester, 1);
    expect(_run(tester).phase, RedSeaCrossingPhase.placing);
    expect(_run(tester).elapsed, closeTo(0, .000001));
    expect(
      find.byKey(const Key('red-sea-traveller-traveller-1')),
      findsOneWidget,
    );
    await _frames(tester, 10);
    expect(_run(tester).elapsed, closeTo(1, .000001));
    await _dispose(tester);
  });

  testWidgets(
    'fast single-move releases accept land; water and repeats stay rejected',
    (tester) async {
      await _pumpEngine(tester, []);
      await _open(tester);
      final held = await _pickup(tester, 0);
      await held.moveTo(_dropPointer(tester, const Offset(.5, .6)));
      await tester.pump();
      expect(_painter(tester).draggedTravellerId(), 'traveller-1');
      final size = tester.getSize(
        find.byKey(const Key('red-sea-crossing-board')),
      );
      expect(
        _painter(tester).draggedPosition()!.dy,
        closeTo(size.height * .6, .000001),
      );
      expect(_run(tester).placedCount, 0);
      await held.up();
      await tester.pump();
      expect(_run(tester).placedCount, 1);
      final placement = _run(tester).placements['traveller-1']!;
      expect(placement.x, closeTo(.5, .000001));
      expect(placement.y, closeTo(.6, .000001));
      expect(
        find.byKey(const Key('red-sea-traveller-traveller-1')),
        findsNothing,
      );
      await _drag(tester, 0, const Offset(.55, .55));
      expect(_run(tester).placedCount, 1);
      expect(_run(tester).placements['traveller-1'], same(placement));
      await _drag(tester, 1, const Offset(.10, .6));
      expect(_run(tester).placedCount, 1);
      expect(find.text('Drop them on the dry path.'), findsOneWidget);
      await _frames(tester, 4);
      expect(_painter(tester).draggedTravellerId(), isNull);
      await _drag(tester, 1, const Offset(.57, .58));
      expect(_run(tester).placedCount, 2);
      expect(_run(tester).placements['traveller-2']!.x, closeTo(.57, .000001));
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    },
  );

  testWidgets(
    'polygon accepts both visible dry edges and rejects real water with fast releases',
    (tester) async {
      await _pumpEngine(tester, [], level: _level(polygon: true));
      await _open(tester);
      final left = await _pickup(tester, 0);
      await left.moveTo(_dropPointer(tester, const Offset(.25, .60)));
      await tester.pump();
      await left.up();
      await tester.pump();
      expect(_run(tester).placedCount, 1);
      expect(_run(tester).placements['traveller-1']!.x, closeTo(.25, .000001));
      expect(_run(tester).placements['traveller-1']!.y, closeTo(.60, .000001));
      final right = await _pickup(tester, 1);
      await right.moveTo(_dropPointer(tester, const Offset(.75, .60)));
      await tester.pump();
      await right.up();
      await tester.pump();
      expect(_run(tester).placedCount, 2);
      expect(_run(tester).placements['traveller-2']!.x, closeTo(.75, .000001));
      final wet = await _pickup(tester, 2);
      await wet.moveTo(_dropPointer(tester, const Offset(.10, .60)));
      await tester.pump();
      await wet.up();
      await tester.pump();
      expect(_run(tester).placedCount, 2);
      expect(_run(tester).placements.containsKey('traveller-3'), isFalse);
      expect(find.text('Drop them on the dry path.'), findsOneWidget);
      await _frames(tester, 4);
      expect(_painter(tester).draggedTravellerId(), isNull);
      await _dispose(tester);
    },
  );

  testWidgets(
    'a successful gesture crossing waits for every walk and saves once',
    (tester) async {
      final completed = <Map<String, dynamic>>[];
      await _pumpEngine(tester, completed, level: _level(polygon: true));
      await _open(tester);
      await _frames(tester, 10);
      for (var index = 0; index < 6; index++) {
        await _drag(tester, index, _authoredDrop(index));
        await _frames(tester, 1);
      }
      final run = _run(tester);
      expect(run.phase, RedSeaCrossingPhase.walking);
      expect(run.placedCount, 6);
      expect(run.safeCount, 0);
      final lastDropTime = run.elapsed;
      await _frames(tester, 30);
      expect(run.phase, RedSeaCrossingPhase.walking);
      expect(completed, isEmpty);
      expect(run.elapsed, lastDropTime);
      await _frames(tester, 15);
      expect(run.phase, RedSeaCrossingPhase.complete);
      expect(run.safeCount, 6);
      expect(completed, isEmpty);
      await _frames(tester, 10);
      expect(completed, hasLength(1));
      final result = completed.single;
      expect(result.keys, ['crossing']);
      final crossing = result['crossing'] as Map;
      final placements = crossing['placements'] as List;
      expect(placements, hasLength(6));
      expect(
        placements.map((person) => (person as Map)['traveller_id']).toSet(),
        {for (var index = 1; index <= 6; index++) 'traveller-$index'},
      );
      expect(crossing['elapsed_ms'], (lastDropTime * 1000).round());
      for (final placement in placements.cast<Map>()) {
        expect(
          run.course.dropZone.contains(
            placement['x'] as double,
            placement['y'] as double,
          ),
          isTrue,
        );
        expect(
          placement['released_at_ms'],
          lessThanOrEqualTo(crossing['elapsed_ms'] as int),
        );
      }
      if (_captureEnabled) {
        await tester.runAsync(() async {
          for (final path in [
            '/tmp/kingdom-kids-red-sea-client-result.json',
            '/tmp/kingdom-kids-red-sea-gesture-result.json',
          ]) {
            await File(path).writeAsString(jsonEncode(result));
          }
        });
      }
      await _frames(tester, 20);
      expect(completed, hasLength(1));
      await _dispose(tester);
    },
  );

  testWidgets('timeout submits the actual partial placement exactly once', (
    tester,
  ) async {
    final completed = <Map<String, dynamic>>[];
    await _pumpEngine(tester, completed, level: _level(seconds: 2));
    await _open(tester);
    await _frames(tester, 5);
    await _drag(tester, 1, const Offset(.52, .57));
    await _frames(tester, 15);
    expect(_run(tester).phase, RedSeaCrossingPhase.timedOut);
    expect(_run(tester).placedCount, 1);
    expect(_run(tester).safeCount, 0);
    expect(completed, isEmpty);
    await _frames(tester, 8);
    expect(completed, hasLength(1));
    final crossing = completed.single['crossing'] as Map;
    expect(crossing['elapsed_ms'], 2000);
    expect(crossing['placements'], [
      {
        'traveller_id': 'traveller-2',
        'x': .52,
        'y': .57,
        'released_at_ms': 500,
      },
    ]);
    await _frames(tester, 20);
    await _drag(tester, 2, const Offset(.52, .57));
    expect(completed, hasLength(1));
    expect(_run(tester).placedCount, 1);
    await _dispose(tester);
  });

  testWidgets(
    'covered and backgrounded play freeze time and cancel held people',
    (tester) async {
      var paused = false;
      late StateSetter change;
      await _pumpEngine(
        tester,
        [],
        wrap: (_) => StatefulBuilder(
          builder: (context, setState) {
            change = setState;
            return RedSeaCrossingEngine(
              level: _level(),
              paused: paused,
              onComplete: (_) {},
              onExit: () {},
            );
          },
        ),
      );
      await _open(tester);
      await _frames(tester, 10);
      final gesture = await _pickup(tester, 0);
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      await gesture.moveTo(_dropPointer(tester, const Offset(.5, .6)));
      await tester.pump();
      expect(_painter(tester).draggedTravellerId(), 'traveller-1');
      change(() => paused = true);
      await tester.pump();
      expect(_painter(tester).draggedTravellerId(), isNull);
      final stoppedAt = _run(tester).elapsed;
      await _frames(tester, 30);
      expect(_run(tester).elapsed, stoppedAt);
      await gesture.up();
      change(() => paused = false);
      await tester.pump();
      await _frames(tester, 1);
      expect(_run(tester).elapsed - stoppedAt, lessThanOrEqualTo(.100001));
      expect(_run(tester).placedCount, 0);
      await _frames(tester, 10);
      final secondGesture = await _pickup(tester, 0);
      await secondGesture.moveBy(const Offset(0, -30));
      await tester.pump();
      await secondGesture.moveTo(_dropPointer(tester, const Offset(.5, .6)));
      await tester.pump();
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(_painter(tester).draggedTravellerId(), isNull);
      final backgroundAt = _run(tester).elapsed;
      await _frames(tester, 30);
      expect(_run(tester).elapsed, backgroundAt);
      await secondGesture.up();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await _frames(tester, 1);
      final foregroundAt = _run(tester).elapsed;
      expect(foregroundAt - backgroundAt, lessThanOrEqualTo(.100001));
      await _frames(tester, 10);
      expect(_run(tester).elapsed, closeTo(foregroundAt + 1, .000001));
      expect(_run(tester).placedCount, 0);
      await _drag(tester, 0, const Offset(.5, .6));
      expect(_run(tester).placedCount, 1);
      await _dispose(tester);
    },
  );

  testWidgets(
    'TickerMode suspension cancels a held finger without a clock jump',
    (tester) async {
      var enabled = true;
      late StateSetter change;
      await _pumpEngine(
        tester,
        [],
        wrap: (engine) => StatefulBuilder(
          builder: (_, setState) {
            change = setState;
            return TickerMode(enabled: enabled, child: engine);
          },
        ),
      );
      await _open(tester);
      final held = await _pickup(tester, 0);
      await held.moveTo(_dropPointer(tester, const Offset(.5, .6)));
      await tester.pump();
      change(() => enabled = false);
      await tester.pump();
      final stoppedAt = _run(tester).elapsed;
      expect(_painter(tester).draggedTravellerId(), isNull);
      await _frames(tester, 30);
      expect(_run(tester).elapsed, stoppedAt);
      await held.up();
      change(() => enabled = true);
      await tester.pump();
      await _frames(tester, 1);
      expect(_run(tester).elapsed - stoppedAt, lessThanOrEqualTo(.100001));
      expect(_run(tester).placedCount, 0);
      await _dispose(tester);
    },
  );

  testWidgets('320 by 568 at double text size keeps ready and play usable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpEngine(
      tester,
      [],
      level: _level(count: 10, polygon: true),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    final button = tester.getRect(find.byKey(const Key('red-sea-open')));
    expect(button.left, greaterThanOrEqualTo(0));
    expect(button.right, lessThanOrEqualTo(320));
    expect(button.bottom, lessThanOrEqualTo(568));
    await _open(tester);
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const Key('red-sea-traveller-traveller-10')),
      findsOneWidget,
    );
    await _drag(tester, 9, const Offset(.5, .6));
    expect(_run(tester).placedCount, 1);
    expect(tester.takeException(), isNull);
    await _dispose(tester);
  });

  for (final surface in [const Size(390, 844), const Size(320, 568)]) {
    for (final count in [10, 15, 20]) {
      testWidgets(
        'every person in a $count-person crowd can be picked and placed on $surface',
        (tester) async {
          await tester.binding.setSurfaceSize(surface);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final completed = <Map<String, dynamic>>[];
          await _pumpEngine(
            tester,
            completed,
            level: _level(count: count, polygon: true),
          );
          await _open(tester);
          // Reverse visual depth so rear people must remain reachable while
          // foreground people still stand in front of them.
          final indices = List<int>.generate(count, (index) => index)
            ..sort(
              (a, b) => RedSeaCrossingPainter.queuePosition(a, count, surface)
                  .dy
                  .compareTo(
                    RedSeaCrossingPainter.queuePosition(b, count, surface).dy,
                  ),
            );
          for (final index in indices) {
            final key = Key('red-sea-traveller-traveller-${index + 1}');
            final bounds = tester.getRect(find.byKey(key));
            expect(bounds.left, greaterThanOrEqualTo(0));
            expect(bounds.top, greaterThanOrEqualTo(0));
            expect(bounds.right, lessThanOrEqualTo(surface.width));
            expect(bounds.bottom, lessThanOrEqualTo(surface.height));
            expect(bounds.width, closeTo(44, .000001));
            expect(bounds.height, closeTo(44, .000001));
            final held = await _pickup(tester, index);
            expect(
              _painter(tester).draggedTravellerId(),
              'traveller-${index + 1}',
            );
            await held.moveBy(const Offset(0, -30));
            await tester.pump();
            await held.moveTo(_dropPointer(tester, _authoredDrop(index)));
            await tester.pump();
            await held.up();
            await tester.pump();
            expect(_run(tester).placements, contains('traveller-${index + 1}'));
          }
          expect(_run(tester).placedCount, count);
          expect(_run(tester).phase, RedSeaCrossingPhase.walking);
          await _frames(tester, 55);
          expect(completed, hasLength(1));
          final result = completed.single['crossing'] as Map;
          expect(result['placements'], hasLength(count));
          expect(tester.takeException(), isNull);
          await _dispose(tester);
        },
      );
    }
  }

  testWidgets(
    'all twenty crowded people retain individual accessibility actions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final semantics = tester.ensureSemantics();
      try {
        await _pumpEngine(tester, [], level: _level(count: 20), textScale: 2);
        await _open(tester);
        for (var index = 0; index < 20; index++) {
          final finder = find.byKey(
            Key('red-sea-traveller-traveller-${index + 1}'),
          );
          final node = tester.getSemantics(finder);
          expect(
            node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
            isTrue,
          );
          node.owner!.performAction(node.id, ui.SemanticsAction.tap);
          await tester.pump();
          expect(
            _painter(tester).draggedTravellerId(),
            'traveller-${index + 1}',
          );
          // A semantic pickup still accepts the ordinary tap-to-place route.
          final board = find.byKey(const Key('red-sea-crossing-board'));
          final size = tester.getSize(board);
          await tester.tapAt(
            tester.getTopLeft(board) +
                Offset(size.width * .5, size.height * .6),
          );
          await tester.pump();
          expect(_run(tester).placements, contains('traveller-${index + 1}'));
        }
        expect(_run(tester).placedCount, 20);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await _dispose(tester);
      }
    },
  );
}

bool get _captureEnabled => Platform.environment['RED_SEA_CAPTURE'] == '1';

Future<void> _pumpEngine(
  WidgetTester tester,
  List<Map<String, dynamic>> completed, {
  GameLevel? level,
  GlobalKey? boundary,
  double textScale = 1,
  Widget Function(Widget)? wrap,
}) async {
  Widget engine = RedSeaCrossingEngine(
    level: level ?? _level(),
    onComplete: completed.add,
    onExit: () {},
  );
  if (wrap != null) engine = wrap(engine);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(
            size: tester.view.physicalSize / tester.view.devicePixelRatio,
            textScaler: TextScaler.linear(textScale),
          ),
          child: RepaintBoundary(key: boundary, child: engine),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _start(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('red-sea-open')));
  await tester.pump();
}

Future<void> _open(WidgetTester tester) async {
  await _start(tester);
  await _frames(tester, 26);
  expect(_run(tester).phase, RedSeaCrossingPhase.placing);
}

Future<void> _frames(WidgetTester tester, int count) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

RedSeaCrossingPainter _painter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.byKey(const Key('red-sea-crossing-scene')),
            )
            .painter!
        as RedSeaCrossingPainter;

RedSeaCrossingRun _run(WidgetTester tester) => _painter(tester).run;

Offset _pickupOffset(WidgetTester tester) {
  final size = tester.getSize(find.byKey(const Key('red-sea-crossing-board')));
  final run = _run(tester);
  final index = run.course.travellers.indexWhere(
    (person) => person.id == _painter(tester).draggedTravellerId(),
  );
  if (index < 0) return Offset.zero;
  return RedSeaCrossingPainter.queuePosition(
        index,
        run.course.travellers.length,
        size,
      ) -
      RedSeaCrossingPainter.queueHitCenter(
        index,
        run.course.travellers.length,
        size,
      );
}

Offset _dropPointer(WidgetTester tester, Offset normalizedFoot) {
  final board = find.byKey(const Key('red-sea-crossing-board'));
  final size = tester.getSize(board);
  return tester.getTopLeft(board) +
      Offset(normalizedFoot.dx * size.width, normalizedFoot.dy * size.height) -
      _pickupOffset(tester);
}

Future<TestGesture> _pickup(WidgetTester tester, int index) async {
  final board = find.byKey(const Key('red-sea-crossing-board'));
  final center = RedSeaCrossingPainter.queueHitCenter(
    index,
    _run(tester).course.travellers.length,
    tester.getSize(board),
  );
  final gesture = await tester.startGesture(tester.getTopLeft(board) + center);
  await tester.pump();
  return gesture;
}

Future<void> _drag(
  WidgetTester tester,
  int index,
  Offset normalizedFoot,
) async {
  final gesture = await _pickup(tester, index);
  await gesture.moveBy(const Offset(0, -30));
  await tester.pump();
  await gesture.moveTo(_dropPointer(tester, normalizedFoot));
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!_captureEnabled) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory(
      '/Users/macbook/.cache/kingdom-kids/red-sea-crossing-review',
    );
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

Offset _authoredDrop(int index) => switch (index) {
  0 => const Offset(.25, .60),
  1 => const Offset(.75, .60),
  _ => Offset(.43 + (index % 3) * .07, .61),
};

GameLevel _level({int count = 6, int seconds = 45, bool polygon = false}) =>
    GameLevel(
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
          'drop_zone': {
            'left': .34,
            'top': .43,
            'right': .66,
            'bottom': .70,
            if (polygon)
              'polygon': [
                [.43, .33],
                [.57, .33],
                [.705, .43],
                [.855, .70],
                [.145, .70],
                [.295, .43],
              ],
          },
        },
      },
    );

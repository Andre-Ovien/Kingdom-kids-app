import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/ark_boarding_engine.dart';

void main() {
  testWidgets('ship bays refill and wrong partners never count as boarded', (
    tester,
  ) async {
    final results = <Map<String, dynamic>>[];
    await _pumpArk(tester, results.add);
    expect(find.text('0 / 8'), findsOneWidget);
    expect(find.byType(ArkAnimalPortrait), findsNWidgets(9));
    await _tapPair(tester, 'rabbit-1', 'panda-2');
    expect(find.text('0 / 8'), findsOneWidget);
    expect(
      find.text('That panda is waiting for another panda.'),
      findsOneWidget,
    );
    await _tapPair(tester, 'panda-1', 'panda-2');
    expect(find.text('1 / 8'), findsOneWidget);
    expect(find.byKey(const Key('ark-animal-panda-1')), findsNothing);
    expect(find.byKey(const Key('ark-bay-panda-2')), findsNothing);
    expect(find.byKey(const Key('ark-bay-sheep-2')), findsOneWidget);
    expect(results, isEmpty);
  });

  testWidgets('dragging an animal onto its mate boards a real pair', (
    tester,
  ) async {
    final results = <Map<String, dynamic>>[];
    await _pumpArk(tester, results.add);
    final source = tester.getCenter(
      find.byKey(const Key('ark-animal-panda-1')),
    );
    final target = tester.getCenter(find.byKey(const Key('ark-bay-panda-2')));
    final drag = await tester.startGesture(source);
    await drag.moveBy(const Offset(0, -30));
    await tester.pump();
    await drag.moveTo(target);
    await tester.pump();
    await drag.up();
    await tester.pump();
    expect(find.text('1 / 8'), findsOneWidget);
    expect(results, isEmpty);
  });

  testWidgets(
    'timed round sends only the boarded pairs and measured elapsed once',
    (tester) async {
      final results = <Map<String, dynamic>>[];
      await _pumpArk(tester, results.add);
      await _tapPair(tester, 'panda-1', 'panda-2');
      await _tapPair(tester, 'rabbit-1', 'rabbit-2');
      await tester.pump(const Duration(seconds: 45));
      expect(results, hasLength(1));
      expect(results.single, {
        'pairs': [
          {'left_id': 'panda-1', 'right_id': 'panda-2'},
          {'left_id': 'rabbit-1', 'right_id': 'rabbit-2'},
        ],
        'elapsed_seconds': 45,
      });
      await tester.pump(const Duration(seconds: 5));
      expect(results, hasLength(1));
      expect(find.text('0s'), findsOneWidget);
    },
  );

  testWidgets(
    'boarding everyone finishes early without waiting for the timer',
    (tester) async {
      final results = <Map<String, dynamic>>[];
      await _pumpArk(tester, results.add);
      for (final species in _animals.keys.toList().reversed) {
        await _tapPair(tester, '$species-1', '$species-2');
      }
      expect(results, hasLength(1));
      expect(results.single['pairs'], hasLength(8));
      expect(results.single['elapsed_seconds'], lessThan(45));
      await tester.pump(const Duration(seconds: 50));
      expect(results, hasLength(1));
    },
  );

  testWidgets('pausing freezes time and blocks boarding until resumed', (
    tester,
  ) async {
    final results = <Map<String, dynamic>>[];
    await _pumpArk(tester, results.add);
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('35s'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ark-pause')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 60));
    expect(find.text('35s'), findsOneWidget);
    expect(find.byKey(const Key('ark-paused-overlay')), findsOneWidget);
    expect(results, isEmpty);
    await tester.tap(find.byKey(const Key('ark-resume')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('30s'), findsOneWidget);
    await _tapPair(tester, 'panda-1', 'panda-2');
    expect(find.text('1 / 8'), findsOneWidget);
  });

  testWidgets(
    'backgrounding cancels a stale drag and requires explicit resume',
    (tester) async {
      final results = <Map<String, dynamic>>[];
      await _pumpArk(tester, results.add);
      final source = tester.getCenter(
        find.byKey(const Key('ark-animal-panda-1')),
      );
      final target = tester.getCenter(find.byKey(const Key('ark-bay-panda-2')));
      final drag = await tester.startGesture(source);
      await drag.moveBy(const Offset(0, -30));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pump(const Duration(seconds: 50));
      expect(results, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byKey(const Key('ark-paused-overlay')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ark-resume')));
      await tester.pump();
      await drag.moveTo(target);
      await tester.pump();
      await drag.up();
      await tester.pump();
      expect(find.text('0 / 8'), findsOneWidget);
      await _tapPair(tester, 'panda-1', 'panda-2');
      expect(find.text('1 / 8'), findsOneWidget);
    },
  );

  testWidgets('disposed round never submits a delayed completion', (
    tester,
  ) async {
    final results = <Map<String, dynamic>>[];
    await _pumpArk(tester, results.add);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(seconds: 60));
    expect(results, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact screen and large text keep boarding controls usable', (
    tester,
  ) async {
    final results = <Map<String, dynamic>>[];
    await _pumpArk(tester, results.add, size: const Size(320, 640), scale: 1.5);
    await tester.ensureVisible(find.byKey(const Key('ark-animal-panda-1')));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('ark-bay-panda-2')), findsOneWidget);
  });

  testWidgets('invalid animal catalogue fails safely without a ticking round', (
    tester,
  ) async {
    final results = <Map<String, dynamic>>[];
    await _pumpArk(tester, results.add, config: {..._config, 'goal_pairs': 99});
    expect(
      find.text(
        'This animal round is taking a little rest. Try another level.',
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 60));
    expect(results, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpArk(
  WidgetTester tester,
  void Function(Map<String, dynamic>) onComplete, {
  Size size = const Size(430, 900),
  double scale = 1,
  Map<String, dynamic>? config,
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
        body: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ArkBoardingEngine(
              level: GameLevel(
                id: 'ark-test',
                number: 1,
                title: 'All Aboard',
                instructions: 'Drag animal friends aboard.',
                config: config ?? _config,
                maxScore: 100,
              ),
              onComplete: onComplete,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _tapPair(WidgetTester tester, String left, String right) async {
  final source = find.byKey(Key('ark-animal-$left'));
  await tester.ensureVisible(source);
  await tester.tap(source);
  await tester.pump();
  final target = find.byKey(Key('ark-bay-$right'));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 250));
}

const _animals = {
  'lion': 'Lion',
  'elephant': 'Elephant',
  'giraffe': 'Giraffe',
  'zebra': 'Zebra',
  'sheep': 'Sheep',
  'monkey': 'Monkey',
  'rabbit': 'Rabbit',
  'panda': 'Panda',
};

final _config = <String, dynamic>{
  'mode': 'ark_boarding',
  'time_limit_seconds': 45,
  'goal_pairs': 5,
  'left_items': [
    for (final entry in _animals.entries)
      {
        'id': '${entry.key}-1',
        'label': entry.value,
        'asset_key': 'animal:${entry.key}',
      },
  ],
  'right_items': [
    for (final entry in _animals.entries.toList().reversed)
      {
        'id': '${entry.key}-2',
        'label': entry.value,
        'asset_key': 'animal:${entry.key}',
      },
  ],
};

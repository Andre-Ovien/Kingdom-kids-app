import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/data/ark_garden_assets.dart';
import 'package:mobile/features/games/data/ark_garden_viewer.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/ark_garden_native_engine.dart';

void main() {
  testWidgets(
    'bundled viewer readiness gates time and requests landscape automatically',
    (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final viewer = _Viewer(ready: false);
      await _pump(tester, viewer);
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('1:00'), findsOneWidget);
      expect(viewer.states, isEmpty);
      expect(
        calls.any(
          (call) =>
              call.method == 'SystemChrome.setPreferredOrientations' &&
              (call.arguments as List).contains(
                'DeviceOrientation.landscapeLeft',
              ),
        ),
        isTrue,
      );
      viewer.ready();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(viewer.states.last['tick'], 2);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(viewer.closed, isTrue);
      expect(calls.last.arguments, ['DeviceOrientation.portraitUp']);
    },
  );

  testWidgets(
    'only host taps move animals; a renderer arrival or result cannot complete a game',
    (tester) async {
      final viewer = _Viewer();
      final outcomes = <Map<String, dynamic>>[];
      await _pump(tester, viewer, outcomes: outcomes);
      viewer.emit({'type': 'animalTapped', 'id': 'elephant'});
      viewer.emit({'type': 'animalTapped', 'id': 'lion'});
      viewer.emit({'type': 'animalTapped', 'id': 'unicorn'});
      viewer.emit({'type': 'animalEntered', 'id': 'lion'});
      viewer.emit({'type': 'result', 'completed': true, 'score': 100});
      await tester.pump(const Duration(seconds: 1));
      expect((viewer.states.last['taps'] as Map).keys.toSet(), {
        'elephant',
        'lion',
      });
      expect(viewer.states.last['distances']['elephant'], greaterThan(0));
      expect(viewer.states.last['distances']['lion'], 0);
      expect(outcomes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'host pause and background freeze timer, queue and input until resume',
    (tester) async {
      final viewer = _Viewer();
      var paused = false;
      late StateSetter refresh;
      _landscape(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              refresh = setState;
              return Scaffold(
                body: ArkGardenNativeEngine(
                  level: _level(),
                  onComplete: (_) {},
                  viewerFactory: () => viewer,
                  originFactory: () async => _Origin(),
                  paused: paused,
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      viewer.emit({'type': 'animalTapped', 'id': 'elephant'});
      await tester.pump(const Duration(seconds: 1));
      refresh(() => paused = true);
      await tester.pump();
      final frozen = jsonEncode(viewer.states.last);
      await tester.pump(const Duration(seconds: 10));
      viewer.emit({'type': 'animalTapped', 'id': 'lion'});
      await tester.pump();
      expect(jsonEncode(viewer.states.last), frozen);
      refresh(() => paused = false);
      await tester.pump();
      // didUpdateWidget restarts the ticker during this rebuild. Give its
      // first frame an elapsed-time baseline before advancing active time.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        viewer.states.last['tick'],
        greaterThan(jsonDecode(frozen)['tick']),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      final tick = viewer.states.last['tick'];
      await tester.pump(const Duration(seconds: 10));
      expect(viewer.states.last['tick'], tick);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byKey(const Key('ark-garden-resume')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ark-garden-resume')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(viewer.states.last['tick'], greaterThan(tick));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'ten full-body queued arrivals submit once after final viewer step, disposal closes its origin',
    (tester) async {
      final viewer = _Viewer();
      final origin = _Origin();
      final outcomes = <Map<String, dynamic>>[];
      await _pump(tester, viewer, outcomes: outcomes, origin: origin);
      for (final animal in _config()['garden']['animals'] as List) {
        viewer.emit({'type': 'animalTapped', 'id': animal['id']});
      }
      await tester.pump(const Duration(seconds: 40));
      expect(viewer.states.last['finished'], isTrue);
      expect(viewer.states.last['tick'], 379);
      expect(outcomes, isEmpty);
      await tester.pump(const Duration(milliseconds: 150));
      expect(outcomes.single['elapsed_ticks'], 379);
      expect((outcomes.single['taps'] as List).length, 10);
      await tester.pump(const Duration(seconds: 5));
      expect(outcomes.length, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(viewer.closed, isTrue);
      expect(origin.closed, isTrue);
    },
  );

  testWidgets('loading failure never starts a hidden clock or sends a result', (
    tester,
  ) async {
    final viewer = _Viewer(ready: false);
    final outcomes = <Map<String, dynamic>>[];
    await _pump(tester, viewer, outcomes: outcomes);
    viewer.emit({'type': 'failure', 'message': 'not displayed raw'});
    await tester.pump(const Duration(seconds: 70));
    expect(find.byKey(const Key('ark-garden-retry')), findsOneWidget);
    expect(outcomes, isEmpty);
    expect(viewer.states, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'retry after a final render failure submits the preserved terminal run once',
    (tester) async {
      final first = _Viewer();
      final retry = _Viewer();
      var created = 0;
      final outcomes = <Map<String, dynamic>>[];
      _landscape(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ArkGardenNativeEngine(
              level: _level(),
              onComplete: outcomes.add,
              viewerFactory: () => created++ == 0 ? first : retry,
              originFactory: () async => _Origin(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      for (final animal in _config()['garden']['animals'] as List) {
        first.emit({'type': 'animalTapped', 'id': animal['id']});
      }
      await tester.pump(const Duration(seconds: 40));
      first.emit({'type': 'failure'});
      await tester.pump(const Duration(milliseconds: 150));
      expect(outcomes, isEmpty);
      await tester.tap(find.byKey(const Key('ark-garden-retry')));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(outcomes.single['elapsed_ticks'], 379);
      expect(retry.states.last['finished'], isTrue);
      expect(retry.states.last['paused'], isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'stale configure/state failures cannot corrupt a replacement viewer',
    (tester) async {
      final configureGate = Completer<void>();
      final stateGate = Completer<void>();
      final first = _Viewer(configureGate: configureGate, stateGate: stateGate);
      final replacement = _Viewer();
      var created = 0;
      _landscape(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ArkGardenNativeEngine(
              level: _level(),
              onComplete: (_) {},
              viewerFactory: () => created++ == 0 ? first : replacement,
              originFactory: () async => _Origin(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      first.emit({'type': 'failure'});
      await tester.pump();
      await tester.tap(find.byKey(const Key('ark-garden-retry')));
      await tester.pump();
      await tester.pump();
      configureGate.completeError(StateError('old configure'));
      stateGate.completeError(StateError('old state'));
      await tester.pump();
      expect(find.byKey(const Key('ark-garden-retry')), findsNothing);
      await tester.tap(find.byKey(const Key('ark-garden-resume')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(replacement.states.last['tick'], greaterThan(0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a delayed final viewer state cannot submit before delivery', (
    tester,
  ) async {
    final finalGate = Completer<void>();
    final viewer = _Viewer(finalGate: finalGate);
    final outcomes = <Map<String, dynamic>>[];
    await _pump(tester, viewer, outcomes: outcomes);
    for (final animal in _config()['garden']['animals'] as List) {
      viewer.emit({'type': 'animalTapped', 'id': animal['id']});
    }
    await tester.pump(const Duration(seconds: 40));
    await tester.pump(const Duration(milliseconds: 150));
    expect(outcomes, isEmpty);
    finalGate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(outcomes.single['elapsed_ticks'], 379);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'slow visual arrivals gate success and reject early invalid duplicate acknowledgements',
    (tester) async {
      final viewer = _Viewer(renderArrivals: false);
      final outcomes = <Map<String, dynamic>>[];
      await _pump(tester, viewer, outcomes: outcomes);
      final ids = (_config()['garden']['animals'] as List)
          .map((animal) => animal['id'] as String)
          .toList();
      // Matching IDs alone cannot acknowledge an animal that has not boarded.
      for (final id in ids) {
        viewer.arrived(id);
        viewer.emit({'type': 'animalTapped', 'id': id});
      }
      await tester.pump(const Duration(seconds: 40));
      await tester.pump(const Duration(milliseconds: 500));
      expect(outcomes, isEmpty);
      expect(viewer.states.last['finished'], isTrue);
      for (final id in ids.take(9)) {
        viewer.arrived(id);
        viewer.arrived(id);
      }
      viewer.arrived('unicorn');
      viewer.emit({'type': 'animalEntered', 'id': ids.last});
      viewer.emit({
        'type': 'animalEntered',
        'id': ids.last,
        'visualOnly': false,
      });
      await tester.pump(const Duration(milliseconds: 500));
      expect(outcomes, isEmpty);
      viewer.arrived(ids.last);
      viewer.arrived(ids.last);
      await tester.pump(const Duration(milliseconds: 150));
      expect(outcomes.single['elapsed_ticks'], 379);
      expect(outcomes.single['taps'], hasLength(10));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'missing render arrivals retry the terminal run and old viewer acknowledgements are ignored',
    (tester) async {
      final first = _Viewer(renderArrivals: false);
      final retry = _Viewer(renderArrivals: false);
      var created = 0;
      final outcomes = <Map<String, dynamic>>[];
      _landscape(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ArkGardenNativeEngine(
              level: _level(),
              onComplete: outcomes.add,
              viewerFactory: () => created++ == 0 ? first : retry,
              originFactory: () async => _Origin(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      final ids = (_config()['garden']['animals'] as List)
          .map((animal) => animal['id'] as String)
          .toList();
      for (final id in ids) {
        first.emit({'type': 'animalTapped', 'id': id});
      }
      await tester.pump(const Duration(seconds: 40));
      for (final id in ids.take(9)) {
        first.arrived(id);
      }
      await tester.pump(const Duration(seconds: 6));
      expect(outcomes, isEmpty);
      expect(find.byKey(const Key('ark-garden-retry')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ark-garden-retry')));
      await tester.pump();
      await tester.pump();
      for (final id in ids) {
        first.arrived(id);
      }
      await tester.pump(const Duration(milliseconds: 500));
      expect(outcomes, isEmpty);
      for (final id in ids.take(9)) {
        retry.arrived(id);
      }
      await tester.pump(const Duration(milliseconds: 500));
      expect(outcomes, isEmpty);
      retry.arrived(ids.last);
      await tester.pump(const Duration(milliseconds: 150));
      expect(outcomes.single['elapsed_ticks'], 379);
      expect(outcomes.single['taps'], hasLength(10));
      expect(retry.states.last['paused'], isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(outcomes.length, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('partial timeout only awaits animals that actually boarded', (
    tester,
  ) async {
    final viewer = _Viewer(renderArrivals: false);
    final outcomes = <Map<String, dynamic>>[];
    await _pump(tester, viewer, outcomes: outcomes);
    viewer.emit({'type': 'animalTapped', 'id': 'elephant'});
    await tester.pump(const Duration(seconds: 60));
    await tester.pump(const Duration(milliseconds: 500));
    expect(outcomes, isEmpty);
    viewer.arrived('elephant');
    await tester.pump(const Duration(milliseconds: 150));
    expect(outcomes.single['taps'], hasLength(1));
    expect(outcomes.single['elapsed_ticks'], 600);
    await tester.pumpWidget(const SizedBox());
  });
}

Map<String, dynamic> _config() => jsonDecode(
  File('test/fixtures/ark_garden_curve_contract_v2.json').readAsStringSync(),
);
GameLevel _level() => GameLevel(
  id: 'native-garden-test',
  number: 1,
  title: 'All aboard',
  instructions: 'Tap the animals.',
  config: _config(),
  maxScore: 100,
);
void _landscape(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _pump(
  WidgetTester tester,
  _Viewer viewer, {
  List<Map<String, dynamic>>? outcomes,
  _Origin? origin,
}) async {
  _landscape(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ArkGardenNativeEngine(
          level: _level(),
          onComplete: outcomes?.add ?? (_) {},
          viewerFactory: () => viewer,
          originFactory: () async => origin ?? _Origin(),
          restoreOrientations: const [DeviceOrientation.portraitUp],
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

class _Viewer implements ArkGardenViewer {
  _Viewer({
    bool ready = true,
    this.configureGate,
    this.stateGate,
    this.finalGate,
    this.renderArrivals = true,
  }) : _ready = ready;
  final bool _ready;
  final Completer<void>? configureGate;
  final Completer<void>? stateGate;
  final Completer<void>? finalGate;
  final bool renderArrivals;
  late void Function(String) _message;
  Map<String, dynamic>? config;
  final List<Map<String, dynamic>> states = [];
  bool closed = false;
  void emit(Map<String, dynamic> event) => _message(jsonEncode(event));
  void arrived(String id) =>
      emit({'type': 'animalEntered', 'id': id, 'visualOnly': true});
  void ready() => emit({
    'type': 'ready',
    'version': 2,
    'animalIds': (config!['garden']['animals'] as List)
        .map((a) => a['id'])
        .toList(),
  });
  @override
  Widget get view => const SizedBox.expand(key: Key('fake-native-garden-view'));
  @override
  Future<void> load({
    required Uri uri,
    required bool Function(String) allowsNavigation,
    required void Function(String) onMessage,
    required void Function() onFailure,
  }) async {
    _message = onMessage;
    emit({'type': 'bridgeReady'});
  }

  @override
  Future<void> configure(Map<String, dynamic> config) async {
    this.config = config;
    if (_ready) ready();
    await configureGate?.future;
  }

  @override
  Future<void> state(Map<String, dynamic> state) async {
    states.add(jsonDecode(jsonEncode(state)));
    await stateGate?.future;
    if (state['finished'] == true) await finalGate?.future;
    if (renderArrivals &&
        state['finished'] == true &&
        state['paused'] == false) {
      for (final animal in config!['garden']['animals'] as List) {
        arrived(animal['id'] as String);
      }
    }
  }

  @override
  Future<void> close() async => closed = true;
}

class _Origin implements ArkGardenAssetOrigin {
  bool closed = false;
  @override
  Uri get entryPoint => Uri.parse('http://127.0.0.1:1/garden.html?host=1');
  @override
  bool allowsNavigation(String url) => url == entryPoint.toString();
  @override
  Future<void> close() async => closed = true;
}

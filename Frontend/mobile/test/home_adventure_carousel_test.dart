import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/app_route_observer.dart';
import 'package:mobile/features/home/presentation/home_adventure_carousel.dart';

void main() {
  testWidgets(
    'counter fills through the same six seconds that trigger a glide',
    (tester) async {
      await tester.pumpWidget(_app());
      expect(_progress(tester, 1), 0);
      await _pumpFor(tester, const Duration(seconds: 3));
      expect(_progress(tester, 1), closeTo(0.5, 0.01));
      expect(_page(tester), 0);

      // An unrelated parent rebuild must not restart the active countdown.
      await tester.pumpWidget(_app());
      expect(_progress(tester, 1), closeTo(0.5, 0.01));
      await _pumpFor(tester, const Duration(seconds: 3));
      expect(_progress(tester, 1), 1);
      await tester.pump();
      await _pumpFor(tester, const Duration(milliseconds: 325));
      expect(_page(tester), greaterThan(0));
      expect(_page(tester), lessThan(1));
      await _pumpFor(tester, const Duration(milliseconds: 350));
      await tester.pump();
      expect(_page(tester), closeTo(1, 0.001));
      expect(_progress(tester, 2), closeTo(0, 0.01));
      await _pumpFor(tester, const Duration(seconds: 3));
      expect(_progress(tester, 2), closeTo(0.5, 0.01));
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpFor(tester, const Duration(seconds: 10));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pauses the existing clock under pointer, inactive Home and background',
    (tester) async {
      await tester.pumpWidget(_app());
      await _pumpFor(tester, const Duration(seconds: 2));
      final partial = _progress(tester, 1);
      final gesture = await tester.startGesture(tester.getCenter(_pages));
      await _pumpFor(tester, const Duration(seconds: 10));
      expect(_progress(tester, 1), partial);
      expect(_page(tester), 0);
      await gesture.cancel();
      await tester.pump();

      await tester.pumpWidget(_app(active: false));
      await _pumpFor(tester, const Duration(seconds: 10));
      expect(_progress(tester, 1), closeTo(partial, 0.01));
      await tester.pumpWidget(_app());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await _pumpFor(tester, const Duration(seconds: 10));
      expect(_progress(tester, 1), closeTo(partial, 0.01));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await _pumpFor(tester, const Duration(seconds: 4));
      await tester.pump();
      await _pumpFor(tester, const Duration(milliseconds: 700));
      await tester.pump();
      expect(_page(tester), closeTo(1, 0.001));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('covered routes stop both ring and advance until returning', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(_app(navigator: navigator));
    await _pumpFor(tester, const Duration(seconds: 2));
    final before = _progress(tester, 1);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Cover')),
      ),
    );
    await _pumpFor(tester, const Duration(milliseconds: 350));
    await _pumpFor(tester, const Duration(seconds: 10));
    expect(_progress(tester, 1, offstage: true), before);
    expect(_page(tester, offstage: true), 0);
    navigator.currentState!.pop();
    await _pumpFor(tester, const Duration(milliseconds: 350));
    await tester.pump();
    await _pumpFor(tester, const Duration(seconds: 1));
    expect(_progress(tester, 1), greaterThan(before));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'manual page selection starts a new full dwell without double advance',
    (tester) async {
      await tester.pumpWidget(_app());
      await _pumpFor(tester, const Duration(seconds: 3));
      await tester.drag(_pages, const Offset(-700, 0));
      await tester.pump();
      await _pumpFor(tester, const Duration(milliseconds: 700));
      await tester.pump();
      expect(_page(tester), closeTo(1, 0.001));
      expect(_progress(tester, 2), closeTo(0, 0.02));
      await _pumpFor(tester, const Duration(seconds: 3));
      expect(_page(tester), closeTo(1, 0.001));
      expect(_progress(tester, 2), closeTo(0.5, 0.02));
      await _pumpFor(tester, const Duration(seconds: 3));
      await tester.pump();
      await _pumpFor(tester, const Duration(milliseconds: 700));
      await tester.pump();
      expect(_page(tester), closeTo(0, 0.001));
      expect(_progress(tester, 1), closeTo(0, 0.02));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final accessibility in [false, true]) {
    testWidgets(
      'motion/accessibility freezes the ring but preserves manual actions $accessibility',
      (tester) async {
        var read = 0;
        var play = 0;
        await tester.pumpWidget(
          _app(
            reduceMotion: !accessibility,
            accessible: accessibility,
            onRead: () => read++,
            onPlay: () => play++,
          ),
        );
        await _pumpFor(tester, const Duration(seconds: 20));
        expect(_progress(tester, 1), 0);
        expect(_page(tester), 0);
        await tester.tap(find.byKey(const Key('home-adventure-read')));
        expect(read, 1);
        await tester.drag(_pages, const Offset(-700, 0));
        await tester.pumpAndSettle();
        expect(_page(tester), closeTo(1, 0.001));
        expect(_progress(tester, 2), 0);
        await tester.tap(find.byKey(const Key('home-adventure-play')));
        expect(play, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }
}

final _pages = find.byKey(const Key('home-adventure-pages'));

double _page(WidgetTester tester, {bool offstage = false}) => tester
    .widget<PageView>(
      find.byKey(const Key('home-adventure-pages'), skipOffstage: !offstage),
    )
    .controller!
    .page!;

double _progress(WidgetTester tester, int page, {bool offstage = false}) =>
    tester
        .widget<CircularProgressIndicator>(
          find.byKey(
            Key('home-adventure-countdown-$page'),
            skipOffstage: !offstage,
          ),
        )
        .value!;

Widget _app({
  bool active = true,
  bool reduceMotion = false,
  bool accessible = false,
  VoidCallback? onRead,
  VoidCallback? onPlay,
  GlobalKey<NavigatorState>? navigator,
}) => MaterialApp(
  navigatorKey: navigator,
  navigatorObservers: [appRouteObserver],
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduceMotion,
      accessibleNavigation: accessible,
    ),
    child: child!,
  ),
  home: Scaffold(
    body: HomeAdventureCarousel(
      isActive: active,
      onRead: onRead ?? () {},
      onPlay: onPlay ?? () {},
    ),
  ),
);

// A countdown can start the next page animation from its completion tick.
// Advance actual frames so that nested animations receive their first tick.
Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  await tester.pump();
  var remaining = duration;
  const frame = Duration(milliseconds: 25);
  while (remaining > Duration.zero) {
    final step = remaining < frame ? remaining : frame;
    await tester.pump(step);
    remaining -= step;
  }
}

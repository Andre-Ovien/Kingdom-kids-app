import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/app_route_observer.dart';
import 'package:mobile/features/profile/domain/progress_summary.dart';
import 'package:mobile/features/profile/presentation/profile_progress_carousel.dart';

final _stats = ProfileStats.fromJson({
  'completed_game_levels': 3,
  'total_game_levels': 24,
  'game_stars': 10,
  'max_game_stars': 72,
  'games_started': 2,
  'earned_badges': 1,
  'total_stories': 8,
  'stories_started': 2,
  'stories_completed': 1,
});

void main() {
  testWidgets('shows one metric and loops sixth to first by moving forward', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    final view = tester.widget<PageView>(_pages);
    final controller = view.controller!;
    final start = controller.page!;
    expect(find.text('3/24'), findsOneWidget);
    expect(find.text('Stars'), findsNothing);
    for (var step = 1; step <= 6; step++) {
      await tester.pump(const Duration(seconds: 7));
      await tester.pump(const Duration(milliseconds: 300));
      final mid = controller.page!;
      expect(mid, greaterThan(start + step - 1));
      expect(mid, lessThan(start + step));
      await tester.pumpAndSettle();
      expect(controller.page, start + step);
    }
    expect(find.text('3/24'), findsOneWidget);
    expect(find.text('Stories completed'), findsNothing);
    expect(tester.getSize(_pages).height, lessThan(150));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pauses while covered, backgrounded, and under pointer', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(_app(navigator: navigator));
    await tester.pumpAndSettle();
    final controller = tester.widget<PageView>(_pages).controller!;
    final start = controller.page!;
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Cover')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 12));
    expect(controller.page, start);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 12));
    expect(controller.page, start);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final gesture = await tester.startGesture(tester.getCenter(_pages));
    await tester.pump(const Duration(seconds: 12));
    expect(controller.page, start);
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(controller.page, start + 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Reduce Motion and accessibility pause auto but allow manual swipe',
    (tester) async {
      for (final accessible in [false, true]) {
        await tester.pumpWidget(
          _app(reduceMotion: !accessible, accessible: accessible),
        );
        await tester.pumpAndSettle();
        final controller = tester.widget<PageView>(_pages).controller!;
        final start = controller.page!;
        await tester.pump(const Duration(seconds: 18));
        expect(controller.page, start);
        await tester.drag(_pages, const Offset(-400, 0));
        await tester.pumpAndSettle();
        expect(find.text('Stars'), findsOneWidget);
        expect(find.text('10/72'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets(
    'large-text cards expose actual metrics and refresh for a new child',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_app(scale: 2, reduceMotion: true));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Progress overview'), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Progress overview')).value,
        '1 of 6. Levels won, 3/24',
      );
      for (var step = 0; step < 6; step++) {
        expect(tester.takeException(), isNull);
        await tester.drag(_pages, const Offset(-400, 0));
        await tester.pumpAndSettle();
      }
      final changed = ProfileStats.fromJson({
        'completed_game_levels': 9,
        'total_game_levels': 18,
      });
      await tester.pumpWidget(
        _app(
          stats: changed,
          childId: 'next-child',
          scale: 2,
          reduceMotion: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('9/18'), findsOneWidget);
      expect(find.text('3/24'), findsNothing);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );
}

final _pages = find.byKey(const Key('profile-progress-pages'));

Widget _app({
  GlobalKey<NavigatorState>? navigator,
  ProfileStats? stats,
  String childId = 'child',
  bool reduceMotion = false,
  bool accessible = false,
  double scale = 1,
}) => MaterialApp(
  navigatorKey: navigator,
  navigatorObservers: [appRouteObserver],
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduceMotion,
      accessibleNavigation: accessible,
      textScaler: TextScaler.linear(scale),
    ),
    child: child!,
  ),
  home: Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ProfileProgressCarousel(
          key: ValueKey(childId),
          stats: stats ?? _stats,
          badgeCount: 2,
        ),
      ),
    ),
  ),
);

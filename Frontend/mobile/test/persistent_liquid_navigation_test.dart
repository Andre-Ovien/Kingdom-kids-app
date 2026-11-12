import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/presentation/kid_profile_avatar.dart';
import 'package:mobile/shared/widgets/floating_liquid_nav.dart';
import 'package:mobile/shared/widgets/liquid_navigation_controller.dart';
import 'package:mobile/shared/widgets/persistent_liquid_navigation_host.dart';

void main() {
  testWidgets(
    'pages glide together in both directions under an unmoving persistent bar',
    (tester) async {
      final harness = _Harness();
      addTearDown(harness.controller.dispose);
      await tester.pumpWidget(harness.app());
      await tester.pumpAndSettle();
      final nav = find.byKey(const Key('persistent-liquid-navigation'));
      final navElement = tester.element(nav);
      final navRect = tester.getRect(nav);
      final initial = tester.getRect(find.byKey(const ValueKey('tab-page-/')));
      const path = [
        AppRoutes.home,
        AppRoutes.stories,
        AppRoutes.games,
        AppRoutes.profile,
        AppRoutes.games,
        AppRoutes.stories,
        AppRoutes.home,
      ];
      for (var i = 1; i < path.length; i++) {
        final source = path[i - 1];
        final target = path[i];
        final forward = AppRoutes.tabIndex(target) > AppRoutes.tabIndex(source);
        final sourcePage = find.byKey(ValueKey('tab-page-$source'));
        final targetPage = find.byKey(ValueKey('tab-page-$target'));
        expect(harness.controller.select(target), isTrue);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        final incoming = tester.getRect(targetPage);
        final outgoing = tester.getRect(sourcePage);
        if (forward) {
          expect(incoming.left, greaterThan(0));
          expect(incoming.left, lessThan(initial.width));
          expect(outgoing.left, lessThan(0));
          expect(outgoing.left, greaterThan(-initial.width));
          expect(incoming.left, closeTo(outgoing.right, 0.001));
        } else {
          expect(incoming.left, lessThan(0));
          expect(incoming.left, greaterThan(-initial.width));
          expect(outgoing.left, greaterThan(0));
          expect(incoming.right, closeTo(outgoing.left, 0.001));
        }
        expect(incoming.top, initial.top);
        expect(incoming.width, initial.width);
        expect(tester.getRect(nav), navRect);
        expect(tester.element(nav), same(navElement));
        expect(
          harness.controller.select(source),
          isFalse,
          reason: 'New tab requests wait for the current glide to settle.',
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.getRect(targetPage).left, 0);
        expect(sourcePage, findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'reduced motion switches pages immediately without an intermediate slide',
    (tester) async {
      final harness = _Harness(reducedMotion: true);
      addTearDown(harness.controller.dispose);
      await tester.pumpWidget(harness.app());
      await tester.pumpAndSettle();
      expect(harness.controller.select(AppRoutes.stories), isTrue);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('tab-page-/')), findsNothing);
      expect(
        tester.getRect(find.byKey(const ValueKey('tab-page-/stories'))).left,
        0,
      );
      expect(harness.controller.select(AppRoutes.games), isTrue);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'one persistent capsule glides across replaced routes and guards duplicate input',
    (tester) async {
      final harness = _Harness();
      addTearDown(harness.controller.dispose);
      await tester.pumpWidget(harness.app());
      await tester.pumpAndSettle();
      final persistentElement = tester.element(
        find.byKey(const Key('persistent-liquid-navigation')),
      );
      final capsule = find.byKey(const Key('bottom-nav-sliding-capsule'));
      final start = tester.getRect(capsule);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Watch'), findsNothing);
      expect(find.byKey(const Key('bottom-nav-main-dock')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('bottom-nav-profile'))).height,
        69,
      );

      expect(harness.controller.select(AppRoutes.home), isFalse);
      expect(harness.controller.select(AppRoutes.videos), isFalse);
      expect(harness.controller.select(AppRoutes.games), isTrue);
      expect(harness.controller.select(AppRoutes.games), isFalse);
      expect(harness.controller.select(AppRoutes.stories), isFalse);
      await tester.pump();
      await tester.pump();
      final afterReplacement = tester.getRect(capsule);
      expect(afterReplacement.left, start.left);
      expect(harness.controller.selectedRoute, AppRoutes.games);
      expect(
        tester.element(find.byKey(const Key('persistent-liquid-navigation'))),
        same(persistentElement),
      );
      await tester.pump(const Duration(milliseconds: 120));
      final midpoint = tester.getRect(capsule);
      await tester.pump(const Duration(milliseconds: 250));
      final end = tester.getRect(capsule);
      expect(midpoint.left, greaterThan(start.left));
      expect(midpoint.left, lessThan(end.left));
      expect(end.top, start.top);
      expect(end.width, closeTo(start.width, 0.001));
      expect(end.height, start.height);
      expect(harness.cues, 1);
      expect(harness.controller.select(AppRoutes.games), isFalse);
      expect(harness.cues, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'dialog, detail and auth hide the same host; Reduce Motion snaps',
    (tester) async {
      final harness = _Harness(reducedMotion: true);
      addTearDown(harness.controller.dispose);
      await tester.pumpWidget(harness.app());
      await tester.pumpAndSettle();
      final surface = find.byKey(
        const Key('persistent-liquid-navigation'),
        skipOffstage: false,
      );
      final element = tester.element(surface);
      final capsule = find.byKey(const Key('bottom-nav-sliding-capsule'));
      final start = tester.getRect(capsule);
      harness.controller.select(AppRoutes.stories);
      await tester.pumpAndSettle();
      final end = tester.getRect(capsule);
      expect(end.left, greaterThan(start.left));
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.getRect(capsule), end);

      unawaited(
        showDialog<void>(
          context: harness.navigator.currentContext!,
          builder: (_) => const AlertDialog(title: Text('Parent dialog')),
        ),
      );
      await tester.pumpAndSettle();
      expect(harness.controller.visible, isFalse);
      expect(
        find.byKey(const Key('bottom-nav-main-dock')).hitTestable(),
        findsNothing,
      );
      expect(tester.element(surface), same(element));
      expect(harness.controller.select(AppRoutes.games), isFalse);
      harness.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(harness.controller.visible, isTrue);
      expect(tester.element(surface), same(element));

      unawaited(
        harness.navigator.currentState!.pushNamed<void>(AppRoutes.storyDetail),
      );
      await tester.pumpAndSettle();
      expect(harness.controller.visible, isFalse);
      harness.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(harness.controller.visible, isTrue);
      unawaited(
        harness.navigator.currentState!.pushReplacementNamed<void, void>(
          AppRoutes.login,
        ),
      );
      await tester.pumpAndSettle();
      expect(harness.controller.visible, isFalse);
      expect(harness.controller.activeProfile, isNull);
      expect(tester.element(surface), same(element));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'only the current profile load may update the persistent avatar',
    (tester) async {
      final first = Completer<KidProfile?>();
      final second = Completer<KidProfile?>();
      var loads = 0;
      final harness = _Harness(
        loadProfile: () => (++loads == 1 ? first : second).future,
      );
      addTearDown(harness.controller.dispose);
      await tester.pumpWidget(harness.app());
      await tester.pump();
      harness.controller.select(AppRoutes.games);
      await tester.pump();
      await tester.pump();
      second.complete(_zuri);
      await tester.pumpAndSettle();
      expect(harness.controller.activeProfile?.id, _zuri.id);
      first.complete(_kai);
      await tester.pumpAndSettle();
      expect(harness.controller.activeProfile?.id, _zuri.id);
      final avatar = tester.widget<KidProfileAvatar>(
        find.descendant(
          of: find.byKey(const Key('bottom-nav-profile')),
          matching: find.byType(KidProfileAvatar),
        ),
      );
      expect(avatar.profile.id, _zuri.id);

      unawaited(
        harness.navigator.currentState!.pushReplacementNamed<void, void>(
          AppRoutes.login,
        ),
      );
      await tester.pumpAndSettle();
      expect(harness.controller.activeProfile, isNull);
      expect(harness.controller.visible, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _Harness {
  _Harness({
    this.reducedMotion = false,
    Future<KidProfile?> Function()? loadProfile,
  }) {
    controller = LiquidNavigationController(
      navigatorKey: navigator,
      onAcceptedSelection: () => cues++,
      loadProfile: loadProfile ?? () async => null,
    );
    observer = LiquidNavigationObserver(controller);
  }

  final navigator = GlobalKey<NavigatorState>();
  final bool reducedMotion;
  late final LiquidNavigationController controller;
  late final LiquidNavigationObserver observer;
  int cues = 0;

  Widget app() => MaterialApp(
    navigatorKey: navigator,
    initialRoute: AppRoutes.home,
    navigatorObservers: [observer],
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
      child: PersistentLiquidNavigationHost(
        controller: controller,
        child: child!,
      ),
    ),
    onGenerateRoute: (settings) {
      Widget page(BuildContext context) => Scaffold(
        body: SizedBox.expand(
          key: ValueKey('tab-page-${settings.name!}'),
          child: const Text('Tab content'),
        ),
        bottomNavigationBar: FloatingLiquidNav(selectedRoute: settings.name!),
      );
      final transition = settings.arguments;
      return transition is TabRouteTransition
          ? TabGlideRoute(
              settings: settings,
              builder: page,
              fromRoute: transition.fromRoute,
            )
          : MaterialPageRoute<void>(settings: settings, builder: page);
    },
  );
}

const _kai = KidProfile(
  id: 'kai-child',
  parentId: 'parent',
  displayName: 'Ada',
  avatarKey: 'lion',
);
const _zuri = KidProfile(
  id: 'zuri-child',
  parentId: 'parent',
  displayName: 'Maya',
  avatarKey: 'rainbow',
);

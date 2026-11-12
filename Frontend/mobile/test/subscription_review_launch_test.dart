import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/auth/presentation/adult_gate.dart';
import 'package:mobile/features/splash/data/startup_destination_resolver.dart';
import 'package:mobile/features/subscription/data/subscription_review_launch.dart';
import 'package:mobile/features/subscription/domain/subscription_plan.dart';
import 'package:mobile/features/subscription/presentation/subscription_review_screen.dart';
import 'package:mobile/features/subscription/presentation/subscription_screen.dart';

const _kid = KidProfile(
  id: 'saved-child',
  parentId: 'parent',
  displayName: 'Saved explorer',
  avatarKey: 'lion',
);
const _session = AuthSession(
  parent: ParentAccount(id: 'parent', email: 'parent@example.test'),
  accessToken: 'saved-access',
  refreshToken: 'saved-refresh',
  profiles: [_kid],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'display preserves full 30-day monthly and calendar-anniversary yearly access',
    () {
      const month = SubscriptionBillingPeriod.monthly;
      const year = SubscriptionBillingPeriod.yearly;
      expect((month.amountMinor, year.amountMinor), (999, 9990));
      expect(
        month.exampleRenewal(DateTime.utc(2026, 11, 12)),
        DateTime.utc(2026, 12, 12),
      );
      expect(
        month.exampleRenewal(DateTime.utc(2026, 11, 28)),
        DateTime.utc(2026, 12, 28),
      );
      expect(
        month.exampleRenewal(DateTime.utc(2026, 12, 31)),
        DateTime.utc(2027, 1, 30),
      );
      expect(
        month.exampleRenewal(DateTime.utc(2028, 2, 1)),
        DateTime.utc(2028, 3, 2),
      );
      final paidAt = DateTime.parse('2026-10-25T12:00:00-07:00');
      expect(
        month.exampleRenewal(paidAt).difference(paidAt),
        const Duration(days: 30),
      );
      expect(
        year.exampleRenewal(DateTime.utc(2026, 11, 12)),
        DateTime.utc(2027, 11, 12),
      );
      expect(
        year.exampleRenewal(DateTime.utc(2028, 2, 29)),
        DateTime.utc(2029, 2, 28),
      );
      expect(
        year.exampleRenewal(DateTime.utc(2027, 2, 28)),
        DateTime.utc(2028, 2, 28),
      );
      final localPayment = DateTime(2026, 11, 12, 0, 15);
      expect(year.exampleRenewal(localPayment), DateTime(2027, 11, 12, 0, 15));
    },
  );

  test(
    'review consumes only separate marker once and preserves exact saved session and child',
    () async {
      final sessions = await _store();
      final markers = MemorySubscriptionReviewStore();
      final normal = _Normal(const StartupDestination(AppRoutes.home));
      SubscriptionReviewDestinationResolver resolver() =>
          SubscriptionReviewDestinationResolver(
            normalStartup: normal,
            authRepository: AuthRepository(sessionStore: sessions),
            reviewStore: markers,
            reviewId: 'subscription-light-test',
          );
      final first = await resolver().resolve();
      expect(first.route, AppRoutes.subscriptionReview);
      final arguments = first.arguments! as SubscriptionReviewArguments;
      expect(arguments.parentId, 'parent');
      expect(arguments.returnRoute, AppRoutes.home);
      expect(markers.consumed, 'subscription-light-test');
      expect((await resolver().resolve()).route, AppRoutes.home);
      expect(await sessions.readSession(), same(_session));
      expect(await sessions.readSelectedKidId(), _kid.id);
      expect(normal.calls, 2);
    },
  );

  test('empty or disabled review never touches review storage', () async {
    for (final scenario in ['', 'disabled']) {
      final markers = MemorySubscriptionReviewStore();
      final result = await SubscriptionReviewDestinationResolver(
        normalStartup: _Normal(const StartupDestination(AppRoutes.home)),
        authRepository: AuthRepository(sessionStore: await _store()),
        reviewStore: markers,
        reviewId: scenario,
        allowReview: scenario != 'disabled',
      ).resolve();
      expect(result.route, AppRoutes.home);
      expect(markers.consumed, isNull);
    }
  });

  test(
    'missing parent, known expired JWT and signed-out startup never consume preview',
    () async {
      final now = DateTime.utc(2026, 11, 12);
      final expired =
          'header.${base64Url.encode(utf8.encode(jsonEncode({'exp': now.millisecondsSinceEpoch ~/ 1000 - 1}))).replaceAll('=', '')}.signature';
      for (final session in [
        null,
        _session.copyWith(accessToken: expired),
        _session.copyWith(
          parent: const ParentAccount(id: '', email: ''),
        ),
      ]) {
        final sessions = MemoryAuthSessionStore();
        if (session != null) await sessions.writeSession(session);
        final markers = MemorySubscriptionReviewStore();
        final result = await SubscriptionReviewDestinationResolver(
          normalStartup: _Normal(const StartupDestination(AppRoutes.home)),
          authRepository: AuthRepository(sessionStore: sessions),
          reviewStore: markers,
          reviewId: 'test',
          now: () => now,
        ).resolve();
        expect(result.route, AppRoutes.home);
        expect(markers.consumed, isNull);
      }
      final markers = MemorySubscriptionReviewStore();
      final result = await SubscriptionReviewDestinationResolver(
        normalStartup: _Normal(const StartupDestination(AppRoutes.login)),
        authRepository: AuthRepository(sessionStore: await _store()),
        reviewStore: markers,
        reviewId: 'test',
      ).resolve();
      expect(result.route, AppRoutes.login);
      expect(markers.consumed, isNull);
    },
  );

  test(
    'review storage failure resumes exact profile-picker arguments without auth reset',
    () async {
      final sessions = await _store();
      final args = [_kid];
      final normal = StartupDestination(
        AppRoutes.profilePicker,
        arguments: args,
      );
      final result = await SubscriptionReviewDestinationResolver(
        normalStartup: _Normal(normal),
        authRepository: AuthRepository(sessionStore: sessions),
        reviewStore: _BrokenMarker(),
        reviewId: 'test',
      ).resolve();
      expect(result, same(normal));
      expect(result.arguments, same(args));
      expect(await sessions.readSession(), same(_session));
      expect(await sessions.readSelectedKidId(), _kid.id);
    },
  );

  test(
    'real secure review marker leaves auth and selection keys intact',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'kingdom_kids.auth_session': 'untouched-auth',
        'kingdom_kids.selected_kid_id': 'untouched-child',
      });
      final store = SecureSubscriptionReviewStore();
      expect(await store.claim('oneoff'), isTrue);
      expect(await SecureSubscriptionReviewStore().claim('oneoff'), isFalse);
      const secure = FlutterSecureStorage();
      expect(
        await secure.read(key: 'kingdom_kids.auth_session'),
        'untouched-auth',
      );
      expect(
        await secure.read(key: 'kingdom_kids.selected_kid_id'),
        'untouched-child',
      );
    },
  );

  testWidgets(
    'normal subscription route and unconfigured dev URL require AdultGate',
    (tester) async {
      for (final route in [
        AppRoutes.subscription,
        AppRoutes.subscriptionReview,
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            onGenerateRoute: AppRouter.onGenerateRoute,
            onGenerateInitialRoutes: (_) => [
              AppRouter.onGenerateRoute(RouteSettings(name: route)),
            ],
            initialRoute: route,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AdultGate), findsOneWidget);
        expect(find.byType(SubscriptionScreen), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets(
    'compile-defined one-off route shows only read-only saved-parent review',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final scopedStore = SecureAuthSessionStore();
      await scopedStore.writeSession(_session);
      await scopedStore.writeSelectedKidId(_kid.id);
      await tester.pumpWidget(
        MaterialApp(
          onGenerateInitialRoutes: (_) => [
            AppRouter.onGenerateRoute(
              RouteSettings(
                name: AppRoutes.subscriptionReview,
                arguments: SubscriptionReviewArguments(
                  reviewId: subscriptionReviewBuildId,
                  parentId: 'parent',
                  returnRoute: AppRoutes.home,
                ),
              ),
            ),
          ],
          onGenerateRoute: AppRouter.onGenerateRoute,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AdultGate), findsNothing);
      expect(
        find.byKey(const Key('subscription-review-notice')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('subscription-parent-continue')),
            )
            .onPressed,
        isNull,
      );
      final restored = await SecureAuthSessionStore().readSession();
      expect(restored!.parent.id, _session.parent.id);
      expect(await SecureAuthSessionStore().readSelectedKidId(), _kid.id);
      expect(tester.takeException(), isNull);
    },
    skip: subscriptionReviewBuildId.isEmpty,
  );

  testWidgets(
    'one-time review closes to normal destination without clearing profile',
    (tester) async {
      final sessions = await _store();
      await tester.pumpWidget(
        MaterialApp(
          onGenerateInitialRoutes: (_) => [
            MaterialPageRoute<void>(
              settings: const RouteSettings(name: '/review'),
              builder: (_) => SubscriptionReviewScreen(
                arguments: const SubscriptionReviewArguments(
                  reviewId: 'test',
                  parentId: 'parent',
                  returnRoute: AppRoutes.home,
                ),
                authRepository: AuthRepository(sessionStore: sessions),
              ),
            ),
          ],
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Normal saved startup')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('subscription-review-notice')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('subscription-back')));
      await tester.pumpAndSettle();
      expect(find.text('Normal saved startup'), findsOneWidget);
      expect(await sessions.readSession(), same(_session));
      expect(await sessions.readSelectedKidId(), _kid.id);
    },
  );
}

Future<MemoryAuthSessionStore> _store() async {
  final store = MemoryAuthSessionStore();
  await store.writeSession(_session);
  await store.writeSelectedKidId(_kid.id);
  return store;
}

class _Normal implements SplashDestinationResolver {
  _Normal(this.destination);
  final StartupDestination destination;
  int calls = 0;
  @override
  Future<StartupDestination> resolve() async {
    calls++;
    return destination;
  }
}

class _BrokenMarker implements SubscriptionReviewStore {
  @override
  Future<bool> claim(String _) async =>
      throw StateError('synthetic locked marker');
}

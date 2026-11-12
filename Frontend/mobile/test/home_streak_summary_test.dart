import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/app_route_observer.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/auth/presentation/adult_gate.dart';
import 'package:mobile/features/home/presentation/home_screen.dart';
import 'package:mobile/features/home/presentation/home_streak_strip.dart';
import 'package:mobile/features/profile/data/profile_repository.dart';
import 'package:mobile/features/profile/domain/progress_summary.dart';
import 'package:mobile/features/stories/data/story_repository.dart';
import 'package:mobile/features/stories/data/story_reading_bookmark_store.dart';
import 'package:mobile/features/stories/domain/story_detail.dart';
import 'package:mobile/features/streak/data/streak_repository.dart';
import 'package:mobile/features/streak/data/streak_reminder_service.dart';
import 'package:mobile/features/streak/domain/streak_claim_receipt.dart';
import 'package:mobile/features/streak/domain/streak_presentation.dart';

void main() {
  testWidgets(
    'the plain bell reads reminder status and settings remain parent gated',
    (tester) async {
      final store = await _store();
      final reminders = _Reminder(enabled: true);
      await tester.pumpWidget(
        _app(
          store,
          _Claim(),
          _Summary((_) async => _summary(_kid, 3)),
          reminders: reminders,
          darkParent: true,
        ),
      );
      await tester.pumpAndSettle();
      final finder = find.byKey(const Key('home-notifications'));
      final bell = tester.widget<IconButton>(finder);
      expect((bell.icon as Icon).icon, Icons.notifications_none_rounded);
      expect(bell.tooltip, 'Notifications');
      expect(bell.style?.backgroundColor?.resolve({}), Colors.transparent);
      expect(bell.style?.side?.resolve({}), BorderSide.none);
      expect(tester.getSize(finder), const Size(52, 52));
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(find.text('Daily reminders are on'), findsOneWidget);
      final sheetTheme = Theme.of(
        tester.element(find.byKey(const Key('home-reminder-status'))),
      );
      expect(sheetTheme.brightness, Brightness.light);
      expect(sheetTheme.textTheme.bodyMedium?.color, const Color(0xFF171421));
      expect(reminders.reads, 1);
      expect(reminders.toggles, 0);
      await tester.tap(find.byKey(const Key('home-manage-reminders')));
      await tester.pumpAndSettle();
      expect(find.byType(AdultGate), findsOneWidget);
      expect(reminders.toggles, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a current summary auth expiry follows the existing sign-in flow',
    (tester) async {
      final store = await _store();
      final claim = _Claim();
      await tester.pumpWidget(
        _app(
          store,
          claim,
          _Summary((_) async {
            await store.clear();
            throw const AppException(
              'Session expired',
              code: 'session_expired',
            );
          }),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Parent sign-in'), findsOneWidget);
      expect(find.byKey(const Key('home-streak-strip')), findsNothing);
      expect(claim.calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a refreshed child B keeps its count when child A finishes late',
    (tester) async {
      final store = await _store();
      final pending = Completer<ProfileProgressSummary>();
      final claim = _Claim();
      final repo = _Summary(
        (id) =>
            id == _kid.id ? pending.future : Future.value(_summary(_other, 2)),
      );
      await tester.pumpWidget(_app(store, claim, repo));
      await tester.pumpAndSettle();
      final navigator = Navigator.of(tester.element(find.byType(HomeScreen)));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('Covered')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await store.writeSelectedKidId(_other.id);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.text('Hey, Nia!'), findsOneWidget);
      expect(find.text("You're on a 2-day streak!"), findsOneWidget);
      pending.complete(_summary(_kid, 99));
      await tester.pumpAndSettle();
      expect(find.text("You're on a 2-day streak!"), findsOneWidget);
      expect(find.text("You're on a 99-day streak!"), findsNothing);
      expect(claim.calls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'the read-only summary supplies real weekdays on a repeat visit',
    (tester) async {
      final store = await _store();
      final data = ProfileProgressSummary.fromJson({
        'profile': {
          'id': _kid.id,
          'display_name': _kid.displayName,
          'avatar_key': _kid.avatarKey,
        },
        'activity_streak': {'current_days': 3, 'longest_days': 8},
        'streak_week': {
          'local_date': '2026-11-11',
          'days': [
            for (var i = 0; i < 7; i++)
              {
                'date': DateTime(
                  2026,
                  11,
                  9 + i,
                ).toIso8601String().split('T').first,
                'active': i < 3,
              },
          ],
        },
      });
      final claim = _Claim();
      await tester.pumpWidget(_app(store, claim, _Summary((_) async => data)));
      await tester.pumpAndSettle();
      expect(find.text("You're on a 3-day streak!"), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('home-streak-weekdays')),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsNWidgets(3),
      );
      expect(claim.calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'repeat-day summary is read once after the existing claim, without another reward',
    (tester) async {
      final store = await _store();
      final claim = _Claim();
      final summary = _Summary((id) async {
        expect(claim.calls, 1);
        return _summary(_kid, 12, includeParent: false);
      });
      await tester.pumpWidget(_app(store, claim, summary));
      await tester.pumpAndSettle();
      expect(find.text("You're on a 12-day streak!"), findsOneWidget);
      expect(find.byKey(const Key('streak-screen')), findsNothing);
      expect(find.byKey(const Key('home-streak-count-only')), findsOneWidget);
      expect(claim.calls, 1);
      expect(summary.calls, 1);
      expect(await store.readSelectedKidId(), _kid.id);
      expect((await store.readSession())?.accessToken, 'unchanged-test-token');
      final header = tester.getRect(find.byKey(const Key('home-child-name')));
      final strip = tester.getRect(find.byKey(const Key('home-streak-strip')));
      final hero = tester.getRect(
        find.byKey(const Key('home-adventure-carousel')),
      );
      expect(strip.top, greaterThan(header.bottom));
      expect(strip.bottom, lessThan(hero.top));
      expect(strip.height, 97);
      expect(strip.width, hero.width);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('unavailable progress never fabricates a streak', (tester) async {
    final store = await _store();
    final claim = _Claim();
    await tester.pumpWidget(
      _app(
        store,
        claim,
        _Summary((_) async {
          throw const AppException(
            'Temporarily unavailable',
            code: 'network_error',
          );
        }),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-streak-strip')), findsNothing);
    expect(claim.calls, 1);
    expect(find.text('Hey, Ada!'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('changing stored selected child rejects a delayed old summary', (
    tester,
  ) async {
    final store = await _store();
    final pending = Completer<ProfileProgressSummary>();
    await tester.pumpWidget(
      _app(store, _Claim(), _Summary((_) => pending.future)),
    );
    await tester.pumpAndSettle();
    await store.writeSelectedKidId(_other.id);
    pending.complete(_summary(_kid, 99));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-streak-strip')), findsNothing);
    expect(await store.readSelectedKidId(), _other.id);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('explicit wrong response parent cannot supply a count', (
    tester,
  ) async {
    final store = await _store();
    await tester.pumpWidget(
      _app(
        store,
        _Claim(),
        _Summary(
          (_) async => _summary(_kid.copyWith(parentId: 'another-parent'), 99),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-streak-strip')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('real receipt is retained if the optional read fails', (
    tester,
  ) async {
    final store = await _store();
    final receipt = StreakPresentation(
      profile: _kid,
      state: StreakPresentationState.continued,
      currentDays: 7,
      longestDays: 8,
      localDate: DateTime(2026, 11, 11),
      recentDays: const [],
    );
    final claim = _Claim(receipt: StreakClaimReceipt(presentation: receipt));
    await tester.pumpWidget(
      _app(
        store,
        claim,
        _Summary((_) async {
          throw const AppException('Offline', code: 'network_error');
        }),
      ),
    );
    await tester.pumpAndSettle();
    final count = tester.widget<Text>(
      find.byKey(const Key('home-streak-count'), skipOffstage: false),
    );
    expect(count.data, "You're on a 7-day streak!");
    expect(claim.calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('strip checks only supplied real weekday dates, not the count', (
    tester,
  ) async {
    final monday = DateTime(2026, 11, 9);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 353,
            child: HomeStreakStrip(
              currentDays: 5,
              localDate: monday.add(const Duration(days: 2)),
              recentDays: [
                StreakDay(date: monday, active: true),
                StreakDay(
                  date: monday.add(const Duration(days: 1)),
                  active: false,
                ),
                StreakDay(
                  date: monday.add(const Duration(days: 2)),
                  active: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));
    expect(
      tester.getSize(find.byKey(const Key('home-streak-strip'))).height,
      97,
    );
    final material = tester.widget<Material>(
      find.descendant(
        of: find.byKey(const Key('home-streak-strip')),
        matching: find.byType(Material),
      ),
    );
    expect(material.shape, isA<RoundedSuperellipseBorder>());
    expect(material.color, const Color(0xFFE8E7FC));
    expect(tester.takeException(), isNull);
  });

  testWidgets('count-only strip remains compact and fits enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(20),
            child: HomeStreakStrip(currentDays: 123),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    expect(find.byKey(const Key('home-streak-weekdays')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<MemoryAuthSessionStore> _store() async {
  final store = MemoryAuthSessionStore();
  await store.writeSession(
    const AuthSession(
      parent: ParentAccount(id: 'parent', email: 'test@example.com'),
      accessToken: 'unchanged-test-token',
      profiles: [_kid, _other],
    ),
  );
  await store.writeSelectedKidId(_kid.id);
  return store;
}

Widget _app(
  MemoryAuthSessionStore store,
  _Claim claim,
  _Summary summary, {
  _Reminder? reminders,
  bool darkParent = false,
}) => MaterialApp(
  theme: darkParent ? ThemeData.dark() : null,
  navigatorObservers: [appRouteObserver],
  onGenerateRoute: (settings) => settings.name == AppRoutes.login
      ? MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => const Scaffold(body: Text('Parent sign-in')),
        )
      : AppRouter.onGenerateRoute(settings),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: HomeScreen(
    authRepository: AuthRepository(sessionStore: store),
    storyRepository: _Stories(),
    streakRepository: claim,
    profileRepository: summary,
    streakReminderService: reminders ?? _Reminder(),
    bookmarkStore: MemoryStoryReadingBookmarkStore(),
    streakPresentationDelay: Duration.zero,
  ),
);

ProfileProgressSummary _summary(
  KidProfile profile,
  int count, {
  bool includeParent = true,
}) => ProfileProgressSummary.fromJson({
  'profile': {
    'id': profile.id,
    if (includeParent) 'parent_id': profile.parentId,
    'display_name': profile.displayName,
    'avatar_key': profile.avatarKey,
  },
  'activity_streak': {'current_days': count, 'longest_days': count},
});

const _kid = KidProfile(
  id: 'kid',
  parentId: 'parent',
  displayName: 'Ada',
  avatarKey: 'lion',
);
const _other = KidProfile(
  id: 'other',
  parentId: 'parent',
  displayName: 'Nia',
  avatarKey: 'dove',
);

class _Summary implements ProfileRepository {
  _Summary(this.load);
  final Future<ProfileProgressSummary> Function(String) load;
  int calls = 0;
  @override
  Future<ProfileProgressSummary> fetchSummary({required String profileId}) {
    calls++;
    return load(profileId);
  }
}

class _Claim implements StreakRepository {
  _Claim({this.receipt = const StreakClaimReceipt()});
  final StreakClaimReceipt receipt;
  int calls = 0;
  @override
  Future<StreakClaimReceipt> claimPresentation({
    required String profileId,
  }) async {
    calls++;
    return receipt;
  }
}

class _Stories implements StoryRepository {
  @override
  Future<List<StoryDetail>> fetchStories({
    String? search,
    String? category,
  }) async => const [
    StoryDetail(
      id: 'ruth',
      slug: 'ruth',
      title: 'Ruth',
      author: 'Kingdom Kids',
      category: 'Kindness',
    ),
  ];
  @override
  Future<StoryDetail> fetchStory(String slug) => throw UnimplementedError();
}

class _Reminder implements StreakReminderService {
  _Reminder({this.enabled = false});
  final bool enabled;
  int reads = 0;
  int toggles = 0;
  @override
  Future<bool> isEnabled() async {
    reads++;
    return enabled;
  }

  @override
  Future<bool> enable({required KidProfile profile}) async {
    toggles++;
    return true;
  }

  @override
  Future<void> disable() async {
    toggles++;
  }

  @override
  Future<void> refreshAfterAppOpen({required KidProfile profile}) async {}
}

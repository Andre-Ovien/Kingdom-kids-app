import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/errors/app_exception.dart';
import 'package:mobile/features/auth/data/auth_api.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/auth/presentation/kid_character_pose.dart';
import 'package:mobile/features/profile/data/profile_repository.dart';
import 'package:mobile/features/profile/domain/progress_summary.dart';
import 'package:mobile/features/profile/presentation/profile_screen.dart';

void main() {
  testWidgets('renders backend progress instead of the legacy demo profile', (
    tester,
  ) async {
    final auth = await _createAuthHarness();
    final progress = _FakeProfileRepository(summary: _summary());

    await tester.pumpWidget(_profileApp(auth.repository, progress));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('profile-live-hero')), findsOneWidget);
    expect(find.text('Backend Maya'), findsOneWidget);
    expect(find.text('Level 2  •  Little Explorer'), findsOneWidget);
    expect(find.text('3/24'), findsOneWidget);
    expect(find.text('10/72'), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('2/8'), findsOneWidget);
    expect(find.text('1/8'), findsOneWidget);
    expect(find.text('Stories explored'), findsOneWidget);
    expect(find.text('Stories completed'), findsOneWidget);
    expect(find.text('2 stories • 2 games'), findsOneWidget);
    expect(find.text('First Quest'), findsNothing);
    expect(find.text('2 days'), findsOneWidget);
    expect(find.text('Quest activity'), findsOneWidget);
    expect(find.byKey(const Key('bottom-nav-main-dock')), findsOneWidget);
    expect(find.byKey(const Key('bottom-nav-profile')), findsOneWidget);
    expect(progress.profileIds, ['kid-1']);

    final heroPose = tester.widget<KidProfileCharacterPose>(
      find.byKey(const Key('profile-hero-character-pose')),
    );
    expect(heroPose.profile.id, _kidProfile.id);
    expect(heroPose.profile.avatarKey, _kidProfile.avatarKey);
    expect(heroPose.pose, KidCharacterPose.wave);
    expect(
      find.bySemanticsLabel('Nia waving on Backend Maya\'s profile'),
      findsOneWidget,
    );

    final profileScroll = find.byKey(const Key('profile-scroll'));
    expect(
      find.descendant(
        of: profileScroll,
        matching: find.text('Stories explored'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: profileScroll, matching: find.text('Read time')),
      findsNothing,
    );
    expect(find.text('Ethan the Reader'), findsNothing);
    expect(find.text('Level 7 Story Explorer'), findsNothing);
  });

  testWidgets('keeps the loading state visible until progress arrives', (
    tester,
  ) async {
    final auth = await _createAuthHarness();
    final response = Completer<ProfileProgressSummary>();
    final progress = _FakeProfileRepository(
      summary: _summary(),
      pendingResponse: response,
    );

    await tester.pumpWidget(_profileApp(auth.repository, progress));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('profile-loading')), findsOneWidget);
    expect(find.byKey(const Key('profile-live-hero')), findsNothing);
    expect(progress.calls, 1);

    response.complete(_summary());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('profile-loading')), findsNothing);
    expect(find.byKey(const Key('profile-live-hero')), findsOneWidget);
    expect(find.text('Backend Maya'), findsOneWidget);
  });

  for (final xp in [4200, 9000]) {
    testWidgets('shows the achieved final rank with $xp lifetime XP', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final auth = await _createAuthHarness();
        final progress = _FakeProfileRepository(
          summary: _summary(
            level: {
              'number': 15,
              'title': 'Kingdom Champion',
              'xp': xp,
              'next_level_xp': 4200,
              'max_level': 15,
              'is_max_level': true,
            },
          ),
        );

        await tester.pumpWidget(_profileApp(auth.repository, progress));
        await tester.pumpAndSettle();

        expect(find.text('Level 15  •  Kingdom Champion'), findsOneWidget);
        expect(
          find.text('Maximum level achieved • $xp total XP'),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel(
            'Maximum level achieved. $xp total experience points',
          ),
          findsOneWidget,
        );
        final bar = tester.widget<LinearProgressIndicator>(
          find.byKey(const Key('profile-level-progress')),
        );
        expect(bar.value, 1);
        expect(find.textContaining('of 300 XP'), findsNothing);
        expect(find.textContaining('Level 16'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets('shows a backend failure and retries successfully', (
    tester,
  ) async {
    final auth = await _createAuthHarness();
    final progress = _FakeProfileRepository(
      summary: _summary(),
      failuresRemaining: 1,
    );

    await tester.pumpWidget(_profileApp(auth.repository, progress));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('profile-error')), findsOneWidget);
    expect(find.text('Progress service is taking a nap.'), findsOneWidget);
    expect(find.byKey(const Key('profile-live-hero')), findsNothing);
    expect(progress.calls, 1);

    await tester.tap(find.byKey(const Key('profile-retry')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('profile-error')), findsNothing);
    expect(find.byKey(const Key('profile-live-hero')), findsOneWidget);
    expect(find.text('3/24'), findsOneWidget);
    expect(progress.calls, 2);
  });

  testWidgets('shows an honest state when no child profile is selected', (
    tester,
  ) async {
    final auth = await _createAuthHarness(selectKid: false);
    final progress = _FakeProfileRepository(summary: _summary());

    await tester.pumpWidget(_profileApp(auth.repository, progress));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('profile-no-selection')), findsOneWidget);
    expect(find.text('Choose your explorer'), findsOneWidget);
    expect(find.text('Choose a profile'), findsOneWidget);
    expect(find.byKey(const Key('profile-live-hero')), findsNothing);
    expect(progress.calls, 0);
    expect(await auth.store.readSelectedKidId(), isNull);
  });

  testWidgets(
    'keeps live profile content and editing usable on a compact large-text phone',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(320, 568));
      final auth = await _createAuthHarness();
      final progress = _FakeProfileRepository(
        summary: _summary(includeXpBreakdown: true),
      );

      await tester.pumpWidget(
        _profileApp(
          auth.repository,
          progress,
          textScaler: const TextScaler.linear(2),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('profile-live-hero')), findsOneWidget);
      expect(find.text('Backend Maya'), findsOneWidget);
      expect(find.text('Level 2  •  Little Explorer'), findsOneWidget);
      expect(find.text('3/24'), findsOneWidget);
      expect(find.text('10/72'), findsOneWidget);
      expect(find.text('1/2'), findsOneWidget);
      expect(find.byKey(const Key('profile-settings')), findsOneWidget);
      expect(find.byKey(const Key('profile-edit')), findsOneWidget);
      expect(find.byKey(const Key('profile-switch')), findsOneWidget);
      final xpSources = find.byKey(const Key('profile-xp-sources'));
      final xpParagraph = tester.renderObject<RenderParagraph>(xpSources);
      expect(xpParagraph.didExceedMaxLines, isFalse);
      expect(tester.getRect(xpSources).left, greaterThanOrEqualTo(0));
      expect(tester.getRect(xpSources).right, lessThanOrEqualTo(320));

      await tester.tap(find.byKey(const Key('profile-edit')));
      await tester.pumpAndSettle();
      await _completeAdultGate(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Make it yours'), findsOneWidget);
      expect(find.byKey(const Key('profile-name-field')), findsOneWidget);
      expect(find.byKey(const Key('profile-save')), findsOneWidget);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('profile-scroll')),
        const Offset(0, -1600),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Quest activity'), findsOneWidget);
      expect(find.text('My badges'), findsNothing);
      expect(find.text('First Quest'), findsNothing);
      expect(progress.profileIds, ['kid-1']);
    },
  );

  testWidgets('exposes profile actions and visual progress to assistive tech', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final auth = await _createAuthHarness();
      final progress = _FakeProfileRepository(summary: _summary());

      await tester.pumpWidget(_profileApp(auth.repository, progress));
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Parent settings'), findsOneWidget);
      expect(find.bySemanticsLabel('Edit profile'), findsOneWidget);
      expect(find.bySemanticsLabel('Switch child'), findsOneWidget);
      expect(
        find.bySemanticsLabel('200 of 300 experience points'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'Jul 14: 5 learning activities; 4 game attempts and 1 story completion',
        ),
        findsOneWidget,
      );

      expect(find.text('My badges'), findsNothing);
      expect(find.byKey(const Key('profile-badges')), findsNothing);
      expect(find.bySemanticsLabel(RegExp(r'^Showing badge ')), findsNothing);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('edits the selected name and avatar through PATCH', (
    tester,
  ) async {
    final auth = await _createAuthHarness();
    final progress = _FakeProfileRepository(summary: _summary());

    await tester.pumpWidget(_profileApp(auth.repository, progress));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('profile-edit')));
    await tester.pumpAndSettle();
    await _completeAdultGate(tester);
    expect(find.text('Make it yours'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('profile-name-field')),
      '  Maya   Joy  ',
    );
    await tester.tap(find.byKey(const Key('profile-avatar-rainbow')));
    await tester.ensureVisible(find.byKey(const Key('profile-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-save')));
    await tester.pumpAndSettle();

    final patchRequests = auth.requests
        .where((request) => request.method == 'PATCH')
        .toList(growable: false);
    expect(patchRequests, hasLength(1));
    expect(patchRequests.single.url.path, '/api/accounts/kid-profiles/kid-1/');
    expect(
      patchRequests.single.headers['authorization'],
      'Bearer reauthenticated-access',
    );
    expect(jsonDecode(patchRequests.single.body), {
      'display_name': 'Maya Joy',
      'avatar_key': 'rainbow',
    });
    expect(find.text('Maya Joy'), findsOneWidget);
    expect(find.text('Profile updated! Looking great.'), findsOneWidget);

    final cached = await auth.repository.currentKid();
    expect(cached?.displayName, 'Maya Joy');
    expect(cached?.avatarKey, 'rainbow');
    expect(cached?.parentId, 'parent-1');
    expect(await auth.store.readSelectedKidId(), 'kid-1');
  });

  testWidgets('profile editing stays hidden until parent reauthentication', (
    tester,
  ) async {
    final auth = await _createAuthHarness();
    final progress = _FakeProfileRepository(summary: _summary());

    await tester.pumpWidget(_profileApp(auth.repository, progress));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-edit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('adult-gate-dialog')), findsOneWidget);
    expect(find.text('Make it yours'), findsNothing);
    expect(find.text('parent@example.com'), findsNothing);

    await tester.enterText(
      find.byKey(const Key('adult-gate-password')),
      'wrong-password',
    );
    await tester.tap(find.byKey(const Key('adult-gate-submit')));
    await tester.pumpAndSettle();

    expect(
      find.text('That password did not match. Please try again.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('adult-gate-dialog')), findsOneWidget);
    expect(find.text('Make it yours'), findsNothing);

    await _completeAdultGate(tester);
    expect(find.byKey(const Key('adult-gate-dialog')), findsNothing);
    expect(find.text('Make it yours'), findsOneWidget);
  });
}

Future<void> _completeAdultGate(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('adult-gate-password')),
    'parent-password',
  );
  final submit = find.byKey(const Key('adult-gate-submit'));
  await tester.ensureVisible(submit);
  await tester.pumpAndSettle();
  await tester.tap(submit);
  await tester.pumpAndSettle();
}

Widget _profileApp(
  AuthRepository authRepository,
  ProfileRepository profileRepository, {
  TextScaler? textScaler,
  bool disableAnimations = false,
}) {
  return MaterialApp(
    builder: textScaler == null && !disableAnimations
        ? null
        : (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: textScaler,
              disableAnimations: disableAnimations,
            ),
            child: child!,
          ),
    home: ProfileScreen(
      authRepository: authRepository,
      profileRepository: profileRepository,
    ),
    onGenerateRoute: (settings) => MaterialPageRoute<void>(
      builder: (_) => Scaffold(body: Text('Route: ${settings.name}')),
      settings: settings,
    ),
  );
}

Future<_AuthHarness> _createAuthHarness({bool selectKid = true}) async {
  final requests = <http.Request>[];
  final store = MemoryAuthSessionStore();
  await store.writeSession(
    const AuthSession(
      parent: ParentAccount(id: 'parent-1', email: 'parent@example.com'),
      accessToken: 'access-token',
      refreshToken: 'refresh-token',
      profiles: [_kidProfile],
    ),
  );
  if (selectKid) {
    await store.writeSelectedKidId('kid-1');
  }

  final api = HttpAuthApi(
    baseUrl: 'https://kingdom-kids.test/api',
    client: MockClient((request) async {
      requests.add(request);
      if (request.method == 'POST' &&
          request.url.path.endsWith('/accounts/login/')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['password'] != 'parent-password') {
          return http.Response(
            jsonEncode({'detail': 'Invalid credentials.'}),
            401,
          );
        }
        return http.Response(
          jsonEncode({
            'user': {
              'id': 'parent-1',
              'email': 'parent@example.com',
              'kid_profiles': [_kidProfile.toJson()],
            },
            'access': 'reauthenticated-access',
            'refresh': 'reauthenticated-refresh',
          }),
          200,
        );
      }
      if (request.method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'id': 'kid-1',
            'display_name': body['display_name'],
            'avatar_key': body['avatar_key'],
            'created_at': '2026-07-14T10:00:00Z',
            'updated_at': '2026-07-15T15:00:00Z',
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode([
          {
            'id': _kidProfile.id,
            'display_name': _kidProfile.displayName,
            'avatar_key': _kidProfile.avatarKey,
            'created_at': '2026-07-14T10:00:00Z',
            'updated_at': '2026-07-15T12:00:00Z',
          },
        ]),
        200,
      );
    }),
  );
  return _AuthHarness(
    repository: AuthRepository(api: api, sessionStore: store),
    store: store,
    requests: requests,
  );
}

const _kidProfile = KidProfile(
  id: 'kid-1',
  parentId: 'parent-1',
  displayName: 'Backend Maya',
  avatarKey: 'dove',
);

ProfileProgressSummary _summary({
  bool includeXpBreakdown = false,
  Map<String, dynamic>? level,
}) => ProfileProgressSummary.fromJson({
  'profile': {
    'id': 'kid-1',
    'display_name': 'Backend Maya',
    'avatar_key': 'dove',
  },
  'level':
      level ??
      {
        'number': 2,
        'title': 'Little Explorer',
        'xp': 500,
        'next_level_xp': 600,
      },
  if (includeXpBreakdown)
    'xp_breakdown': {'quests': 260, 'stories': 200, 'streaks': 40},
  'stats': {
    'completed_game_levels': 3,
    'total_game_levels': 24,
    'game_stars': 10,
    'max_game_stars': 72,
    'games_started': 2,
    'games_completed': 1,
    'earned_badges': 1,
    'total_stories': 8,
    'stories_started': 2,
    'stories_completed': 1,
  },
  'badges': [
    {
      'key': 'first-quest',
      'title': 'First Quest',
      'description': 'Finish a first game round.',
      'icon_key': 'play-spark',
      'target': 1,
      'earned': true,
      'progress': 1,
    },
    {
      'key': 'star-climber',
      'title': 'Star Climber',
      'description': 'Collect twenty game stars.',
      'icon_key': 'stars',
      'target': 20,
      'earned': false,
      'progress': 10,
    },
  ],
  'activity_streak': {'current_days': 2, 'longest_days': 4},
  'weekly_activity': [
    {
      'week_start': '2026-06-16',
      'label': 'Jun 16',
      'attempts': 1,
      'story_completions': 0,
      'activities': 1,
    },
    {
      'week_start': '2026-06-23',
      'label': 'Jun 23',
      'attempts': 0,
      'story_completions': 0,
      'activities': 0,
    },
    {
      'week_start': '2026-06-30',
      'label': 'Jun 30',
      'attempts': 2,
      'story_completions': 1,
      'activities': 3,
    },
    {
      'week_start': '2026-07-07',
      'label': 'Jul 7',
      'attempts': 3,
      'story_completions': 1,
      'activities': 4,
    },
    {
      'week_start': '2026-07-14',
      'label': 'Jul 14',
      'attempts': 4,
      'story_completions': 1,
      'activities': 5,
    },
  ],
  'last_activity_at': '2026-07-15T08:00:00Z',
});

final class _FakeProfileRepository implements ProfileRepository {
  _FakeProfileRepository({
    required this.summary,
    this.failuresRemaining = 0,
    this.pendingResponse,
  });

  final ProfileProgressSummary summary;
  int failuresRemaining;
  final Completer<ProfileProgressSummary>? pendingResponse;
  int calls = 0;
  final List<String> profileIds = [];

  @override
  Future<ProfileProgressSummary> fetchSummary({
    required String profileId,
  }) async {
    calls += 1;
    profileIds.add(profileId);
    if (failuresRemaining > 0) {
      failuresRemaining -= 1;
      throw const AppException('Progress service is taking a nap.');
    }
    if (pendingResponse != null && calls == 1) {
      return pendingResponse!.future;
    }
    return summary;
  }
}

final class _AuthHarness {
  const _AuthHarness({
    required this.repository,
    required this.store,
    required this.requests,
  });

  final AuthRepository repository;
  final MemoryAuthSessionStore store;
  final List<http.Request> requests;
}

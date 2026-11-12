import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/milestones/data/level_milestone_store.dart';
import 'package:mobile/features/milestones/domain/level_milestone.dart';
import 'package:mobile/features/milestones/presentation/level_milestone_presenter.dart';
import 'package:mobile/features/milestones/presentation/level_milestone_screen.dart';
import 'package:mobile/features/profile/domain/progress_summary.dart';

void main() {
  testWidgets('final rank celebrates once and never presents level 16', (
    tester,
  ) async {
    final host = await _pumpHost(tester);
    final store = MemoryLevelMilestoneStore();
    final presenter = LevelMilestonePresenter(
      authRepository: _ProfileAuth(_ada),
      store: store,
    );
    const champion = LevelMilestone(
      previousLevel: 14,
      level: ProfileLevel(
        number: 15,
        title: 'Kingdom Champion',
        xp: 4200,
        nextLevelXp: 4200,
        isMaxLevel: true,
      ),
    );
    final result = presenter.present(
      host.context,
      profileId: _ada.id,
      milestone: champion,
      canPresent: () => true,
    );
    await tester.pumpAndSettle();
    expect(find.text('You reached\nlevel 15!'), findsOneWidget);
    expect(find.text('Kingdom Champion'), findsOneWidget);
    expect(find.text('MAXIMUM LEVEL ACHIEVED'), findsOneWidget);
    expect(
      tester
          .widget<LevelMilestoneScreen>(find.byType(LevelMilestoneScreen))
          .previewGiftReveal,
      isFalse,
    );
    expect(find.byKey(const Key('level-milestone-box')), findsNothing);
    await _continue(tester);
    expect(await result, LevelMilestonePresentationResult.presented);
    expect(await store.highestPresentedLevel(_ada.id), 15);

    for (final milestone in [
      champion,
      const LevelMilestone(
        previousLevel: 15,
        level: ProfileLevel(
          number: 16,
          title: 'Kingdom Champion',
          xp: 4500,
          nextLevelXp: 4800,
        ),
      ),
    ]) {
      expect(
        await presenter.present(
          host.context,
          profileId: _ada.id,
          milestone: milestone,
          canPresent: () => true,
        ),
        LevelMilestonePresentationResult.skipped,
      );
    }
    expect(host.observer.pagesOpened, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'racing quest and story presenters open one page, then streak replay skips',
    (tester) async {
      final host = await _pumpHost(tester);
      final auth = _ProfileAuth(_ada);
      final store = MemoryLevelMilestoneStore();
      final quest = LevelMilestonePresenter(authRepository: auth, store: store);
      final story = LevelMilestonePresenter(authRepository: auth, store: store);
      final streak = LevelMilestonePresenter(
        authRepository: auth,
        store: store,
      );
      final hookCalls = <String>[];

      // Both sources start before either can finish its asynchronous lookups.
      final questResult = quest.present(
        host.context,
        profileId: _ada.id,
        milestone: _levelEight,
        canPresent: () => true,
        beforePresent: () => hookCalls.add('quest-before'),
        afterPresent: () => hookCalls.add('quest-after'),
      );
      final storyResult = story.present(
        host.context,
        profileId: _ada.id,
        milestone: _levelEight,
        canPresent: () => true,
        beforePresent: () => hookCalls.add('story-before'),
        afterPresent: () => hookCalls.add('story-after'),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('level-milestone-screen')), findsOneWidget);
      expect(host.observer.pagesOpened, 1);
      expect(await storyResult, LevelMilestonePresentationResult.deferred);
      expect(await store.highestPresentedLevel(_ada.id), 8);
      expect(hookCalls, ['quest-before']);
      await _continue(tester);
      expect(await questResult, LevelMilestonePresentationResult.presented);
      expect(hookCalls, ['quest-before', 'quest-after']);

      for (final presenter in [story, streak]) {
        expect(
          await presenter.present(
            host.context,
            profileId: _ada.id,
            milestone: _levelEight,
            canPresent: () => true,
          ),
          LevelMilestonePresentationResult.skipped,
        );
      }
      expect(host.observer.pagesOpened, 1);

      // Suppressing the shared transition must not suppress a later level.
      final nextLevel = streak.present(
        host.context,
        profileId: _ada.id,
        milestone: _levelNine,
        canPresent: () => true,
      );
      await tester.pumpAndSettle();
      expect(find.text('You reached\nlevel 9!'), findsOneWidget);
      await _continue(tester);
      expect(await nextLevel, LevelMilestonePresentationResult.presented);
      expect(await store.highestPresentedLevel(_ada.id), 9);
      expect(host.observer.pagesOpened, 2);
    },
  );

  testWidgets(
    'first-frame secure watermark suppresses another source before a failing write ends',
    (tester) async {
      const profile = KidProfile(
        id: 'presenter-pending-secure-write',
        parentId: 'parent-1',
        displayName: 'Ada',
        avatarKey: 'kai',
      );
      final storage = _BlockedWriteStorage();
      final store = SecureLevelMilestoneStore(storage: storage);
      final auth = _ProfileAuth(profile);
      final host = await _pumpHost(tester);
      final story = LevelMilestonePresenter(authRepository: auth, store: store);
      final quest = LevelMilestonePresenter(authRepository: auth, store: store);
      final result = story.present(
        host.context,
        profileId: profile.id,
        milestone: _levelEight,
        canPresent: () => true,
      );
      await tester.pumpAndSettle();
      expect(storage.writeCalls, 1);
      expect(storage.writeReleased.isCompleted, isFalse);
      expect(await store.highestPresentedLevel(profile.id), 8);
      await _continue(tester);
      expect(await result, LevelMilestonePresentationResult.presented);

      expect(
        await quest.present(
          host.context,
          profileId: profile.id,
          milestone: _levelEight,
          canPresent: () => true,
        ),
        LevelMilestonePresentationResult.skipped,
      );
      // Disk failures and new store instances retain the process-local mark.
      storage.writeReleased.complete();
      await tester.pump();
      final reopened = LevelMilestonePresenter(
        authRepository: auth,
        store: SecureLevelMilestoneStore(storage: storage),
      );
      expect(
        await reopened.present(
          host.context,
          profileId: profile.id,
          milestone: _levelEight,
          canPresent: () => true,
        ),
        LevelMilestonePresentationResult.skipped,
      );
      expect(host.observer.pagesOpened, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a route covered during the lookup defers without consuming the receipt',
    (tester) async {
      final host = await _pumpHost(tester);
      final store = _LookupStore()..firstRead = Completer<int>();
      final presenter = LevelMilestonePresenter(
        authRepository: _ProfileAuth(_ada),
        store: store,
      );
      var before = 0;
      final pending = presenter.present(
        host.context,
        profileId: _ada.id,
        milestone: _levelEight,
        canPresent: () => true,
        beforePresent: () => before += 1,
      );
      unawaited(
        host.navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('Another activity')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      store.firstRead!.complete(0);
      await tester.pumpAndSettle();
      expect(await pending, LevelMilestonePresentationResult.deferred);
      expect(before, 0);
      expect(store.marked, isEmpty);
      expect(host.observer.pagesOpened, 0);

      host.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      final retry = presenter.present(
        host.context,
        profileId: _ada.id,
        milestone: _levelEight,
        canPresent: () => true,
      );
      await tester.pumpAndSettle();
      await _continue(tester);
      expect(await retry, LevelMilestonePresentationResult.presented);
      expect(store.marked, {_ada.id: 8});
    },
  );

  testWidgets(
    'backgrounding during profile lookup defers until a foreground retry',
    (tester) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final host = await _pumpHost(tester);
      final auth = _ProfileAuth(_ada)
        ..pendingProfile = Completer<KidProfile?>();
      final store = MemoryLevelMilestoneStore();
      final presenter = LevelMilestonePresenter(
        authRepository: auth,
        store: store,
      );
      final pending = presenter.present(
        host.context,
        profileId: _ada.id,
        milestone: _levelEight,
        canPresent: () => true,
      );
      await tester.pump();
      expect(auth.readCalls, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      auth.pendingProfile!.complete(_ada);
      await tester.pump();
      expect(await pending, LevelMilestonePresentationResult.deferred);
      expect(await store.highestPresentedLevel(_ada.id), 0);
      expect(host.observer.pagesOpened, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final retry = presenter.present(
        host.context,
        profileId: _ada.id,
        milestone: _levelEight,
        canPresent: () => true,
      );
      await tester.pumpAndSettle();
      await _continue(tester);
      expect(await retry, LevelMilestonePresentationResult.presented);
      expect(await store.highestPresentedLevel(_ada.id), 8);
    },
  );

  testWidgets('caller eligibility is rechecked after asynchronous lookup', (
    tester,
  ) async {
    final host = await _pumpHost(tester);
    final store = _LookupStore()..firstRead = Completer<int>();
    final presenter = LevelMilestonePresenter(
      authRepository: _ProfileAuth(_ada),
      store: store,
    );
    var eligible = true;
    var before = 0;
    var after = 0;
    final pending = presenter.present(
      host.context,
      profileId: _ada.id,
      milestone: _levelEight,
      canPresent: () => eligible,
      beforePresent: () => before += 1,
      afterPresent: () => after += 1,
    );
    eligible = false;
    store.firstRead!.complete(0);
    await tester.pumpAndSettle();
    expect(await pending, LevelMilestonePresentationResult.deferred);
    expect(store.marked, isEmpty);
    expect(before, 0);
    expect(after, 0);

    eligible = true;
    final retry = presenter.present(
      host.context,
      profileId: _ada.id,
      milestone: _levelEight,
      canPresent: () => eligible,
      beforePresent: () => before += 1,
      afterPresent: () => after += 1,
    );
    await tester.pumpAndSettle();
    await _continue(tester);
    expect(await retry, LevelMilestonePresentationResult.presented);
    expect(before, 1);
    expect(after, 1);
  });

  testWidgets('an unmounted lookup cannot open or consume a celebration', (
    tester,
  ) async {
    final host = await _pumpHost(tester);
    final auth = _ProfileAuth(_ada)..pendingProfile = Completer<KidProfile?>();
    final store = MemoryLevelMilestoneStore();
    final presenter = LevelMilestonePresenter(
      authRepository: auth,
      store: store,
    );
    final pending = presenter.present(
      host.context,
      profileId: _ada.id,
      milestone: _levelEight,
      canPresent: () => true,
    );
    await tester.pump();
    expect(auth.readCalls, 1);
    await tester.pumpWidget(const SizedBox());
    auth.pendingProfile!.complete(_ada);
    await tester.pump();
    expect(await pending, LevelMilestonePresentationResult.deferred);
    expect(await store.highestPresentedLevel(_ada.id), 0);
    expect(host.observer.pagesOpened, 0);
    expect(tester.takeException(), isNull);

    final nextHost = await _pumpHost(tester);
    final retry = presenter.present(
      nextHost.context,
      profileId: _ada.id,
      milestone: _levelEight,
      canPresent: () => true,
    );
    await tester.pumpAndSettle();
    await _continue(tester);
    expect(await retry, LevelMilestonePresentationResult.presented);
  });

  testWidgets('changed or missing profile never marks another child’s level', (
    tester,
  ) async {
    final host = await _pumpHost(tester);
    final auth = _ProfileAuth(null);
    final store = MemoryLevelMilestoneStore();
    final presenter = LevelMilestonePresenter(
      authRepository: auth,
      store: store,
    );
    for (final selected in <KidProfile?>[null, _nia]) {
      auth.profile = selected;
      expect(
        await presenter.present(
          host.context,
          profileId: _ada.id,
          milestone: _levelEight,
          canPresent: () => true,
        ),
        LevelMilestonePresentationResult.skipped,
      );
    }
    expect(await store.highestPresentedLevel(_ada.id), 0);
    expect(await store.highestPresentedLevel(_nia.id), 0);
    expect(host.observer.pagesOpened, 0);

    final niaResult = presenter.present(
      host.context,
      profileId: _nia.id,
      milestone: _levelEight,
      canPresent: () => true,
    );
    await tester.pumpAndSettle();
    expect(find.text('Amazing work, Nia!'), findsOneWidget);
    await _continue(tester);
    expect(await niaResult, LevelMilestonePresentationResult.presented);
    expect(await store.highestPresentedLevel(_ada.id), 0);
    expect(await store.highestPresentedLevel(_nia.id), 8);

    auth.profile = _ada;
    final adaResult = presenter.present(
      host.context,
      profileId: _ada.id,
      milestone: _levelEight,
      canPresent: () => true,
    );
    await tester.pumpAndSettle();
    expect(find.text('Amazing work, Ada!'), findsOneWidget);
    await _continue(tester);
    expect(await adaResult, LevelMilestonePresentationResult.presented);
    expect(await store.highestPresentedLevel(_ada.id), 8);
  });

  testWidgets(
    'failed lookup releases the guard and leaves caller hooks alone',
    (tester) async {
      final host = await _pumpHost(tester);
      final auth = _ProfileAuth(_ada);
      final store = _LookupStore()..failReads = true;
      final presenter = LevelMilestonePresenter(
        authRepository: auth,
        store: store,
      );
      var before = 0;
      var after = 0;
      Future<LevelMilestonePresentationResult> present() => presenter.present(
        host.context,
        profileId: _ada.id,
        milestone: _levelEight,
        canPresent: () => true,
        beforePresent: () => before += 1,
        afterPresent: () => after += 1,
      );

      expect(await present(), LevelMilestonePresentationResult.skipped);
      store.failReads = false;
      auth.failReads = true;
      expect(await present(), LevelMilestonePresentationResult.skipped);
      expect(before, 0);
      expect(after, 0);
      expect(store.marked, isEmpty);
      expect(host.observer.pagesOpened, 0);
      expect(tester.takeException(), isNull);

      auth.failReads = false;
      final retry = present();
      await tester.pumpAndSettle();
      await _continue(tester);
      expect(await retry, LevelMilestonePresentationResult.presented);
      expect(before, 1);
      expect(after, 1);
    },
  );
}

Future<_Host> _pumpHost(WidgetTester tester) async {
  final host = _Host();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: host.navigator,
      navigatorObservers: [host.observer],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: Builder(
        builder: (context) {
          host.context = context;
          return const Scaffold(body: Text('Saved activity'));
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return host;
}

Future<void> _continue(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('level-milestone-continue')));
  await tester.pumpAndSettle();
}

class _Host {
  final navigator = GlobalKey<NavigatorState>();
  final observer = _PageObserver();
  late BuildContext context;
}

class _PageObserver extends NavigatorObserver {
  var pagesOpened = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.settings.name == AppRoutes.levelMilestone) {
      pagesOpened += 1;
    }
  }
}

class _ProfileAuth extends AuthRepository {
  _ProfileAuth(this.profile) : super(sessionStore: MemoryAuthSessionStore());

  KidProfile? profile;
  Completer<KidProfile?>? pendingProfile;
  bool failReads = false;
  var readCalls = 0;

  @override
  Future<KidProfile?> currentKid() async {
    readCalls += 1;
    if (failReads) {
      throw StateError('Profile session temporarily unavailable');
    }
    if (pendingProfile != null) return pendingProfile!.future;
    return profile;
  }
}

class _LookupStore implements LevelMilestoneStore {
  Completer<int>? firstRead;
  bool failReads = false;
  var readCalls = 0;
  final marked = <String, int>{};

  @override
  Future<int> highestPresentedLevel(String profileId) async {
    readCalls += 1;
    if (failReads) {
      throw StateError('Presentation store unavailable');
    }
    if (readCalls == 1 && firstRead != null) return firstRead!.future;
    return marked[profileId] ?? 0;
  }

  @override
  Future<void> markPresented(String profileId, int level) async {
    marked[profileId] = level;
  }
}

class _BlockedWriteStorage extends FlutterSecureStorage {
  final writeReleased = Completer<void>();
  var writeCalls = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => null;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writeCalls += 1;
    await writeReleased.future;
    throw StateError('Secure disk unavailable');
  }
}

const _ada = KidProfile(
  id: 'presenter-ada',
  parentId: 'parent-1',
  displayName: 'Ada',
  avatarKey: 'kai',
);
const _nia = KidProfile(
  id: 'presenter-nia',
  parentId: 'parent-1',
  displayName: 'Nia',
  avatarKey: 'nia',
);
const _levelEight = LevelMilestone(
  previousLevel: 7,
  level: ProfileLevel(
    number: 8,
    title: 'Faithful Adventurer',
    xp: 2100,
    nextLevelXp: 2400,
  ),
);
const _levelNine = LevelMilestone(
  previousLevel: 8,
  level: ProfileLevel(
    number: 9,
    title: 'Faithful Adventurer',
    xp: 2400,
    nextLevelXp: 2700,
  ),
);

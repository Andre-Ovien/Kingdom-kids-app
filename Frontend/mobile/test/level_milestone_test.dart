import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/milestones/data/level_milestone_store.dart';
import 'package:mobile/features/milestones/domain/level_milestone.dart';
import 'package:mobile/features/milestones/presentation/level_milestone_screen.dart';
import 'package:mobile/features/milestones/presentation/milestone_reveal_graphics.dart';

import 'support/staged_milestone_asset_bundle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an authoritative 7 to 8 transition keeps its rank and XP', () {
    final milestone = LevelMilestone.tryParse(_milestoneJson());

    expect(milestone, isNotNull);
    expect(milestone!.isLevelUp, isTrue);
    expect(milestone.previousLevel, 7);
    expect(milestone.level.number, 8);
    expect(milestone.level.title, 'Faithful Adventurer');
    expect(milestone.level.xp, 2100);
    expect(milestone.level.nextLevelXp, 2400);
  });

  test('missing, malformed, unchanged and lower levels are not milestones', () {
    for (final value in <Object?>[
      null,
      [],
      {},
      {'previous_level': 7, 'level': 8},
      {..._milestoneJson(), 'previous_level': 0},
      {..._milestoneJson(), 'previous_level': '7'},
      {..._milestoneJson(), 'previous_level': 8},
      {..._milestoneJson(), 'previous_level': 9},
      {
        'previous_level': 7,
        'level': {'number': '8', 'title': 'Faithful Adventurer'},
      },
      {
        'previous_level': 7,
        'level': {'number': 8, 'title': '   '},
      },
    ]) {
      expect(LevelMilestone.tryParse(value), isNull, reason: '$value');
    }
  });

  test('receipt parsing adds a milestone without changing quest rewards', () {
    final payload = _submissionJson();
    final original = GameSubmission.fromJson(payload);
    final withMilestone = GameSubmission.fromJson({
      ...payload,
      'level_milestone': _milestoneJson(),
      'idempotent_replay': true,
    });
    expect(original.levelMilestone, isNull);
    expect(withMilestone.levelMilestone!.level.number, 8);
    expect(withMilestone.idempotentReplay, isTrue);
    expect(withMilestone.starsAwarded, original.starsAwarded);
    expect(withMilestone.score, original.score);
    expect(withMilestone.progress.starsEarned, original.progress.starsEarned);
    expect(
      GameSubmission.fromJson({
        ...payload,
        'level_milestone': {'previous_level': 8},
      }).levelMilestone,
      isNull,
    );
  });

  test('only the transition into level 15 can celebrate the final rank', () {
    final champion = {
      'number': 15,
      'title': 'Kingdom Champion',
      'xp': 4200,
      'next_level_xp': 4200,
      'max_level': 15,
      'is_max_level': true,
    };
    final milestone = LevelMilestone.tryParse({
      'previous_level': 14,
      'level': champion,
    });
    expect(milestone, isNotNull);
    expect(milestone!.level.isMaxLevel, isTrue);
    expect(milestone.level.progress, 1);

    for (final receipt in [
      {
        'previous_level': 15,
        'level': {...champion, 'xp': 9000},
      },
      {
        'previous_level': 15,
        'level': {...champion, 'number': 16},
      },
      {
        'previous_level': 14,
        'level': {...champion, 'number': 16},
      },
    ]) {
      expect(LevelMilestone.tryParse(receipt), isNull);
    }
  });

  test('memory watermark is monotonic and isolated for each child', () async {
    final store = MemoryLevelMilestoneStore();
    expect(await store.highestPresentedLevel('kai-profile'), 0);
    await store.markPresented('kai-profile', 8);
    await store.markPresented('nia-profile', 2);
    await store.markPresented('kai-profile', 7);
    expect(await store.highestPresentedLevel('kai-profile'), 8);
    expect(await store.highestPresentedLevel('nia-profile'), 2);
    await store.markPresented('kai-profile', 9);
    expect(await store.highestPresentedLevel('kai-profile'), 9);
  });

  test(
    'secure watermark restores persisted levels and serializes updates',
    () async {
      const storage = FlutterSecureStorage();
      FlutterSecureStorage.setMockInitialValues({
        'kingdom_kids.level_milestone.persisted-kai': '8',
        'kingdom_kids.level_milestone.persisted-nia': '3',
      });
      final store = SecureLevelMilestoneStore(storage: storage);
      expect(await store.highestPresentedLevel('persisted-kai'), 8);
      await Future.wait([
        store.markPresented('persisted-kai', 10),
        store.markPresented('persisted-kai', 9),
        store.markPresented('persisted-nia', 4),
      ]);
      final reopened = SecureLevelMilestoneStore(storage: storage);
      expect(await reopened.highestPresentedLevel('persisted-kai'), 10);
      expect(await reopened.highestPresentedLevel('persisted-nia'), 4);
      expect(
        await storage.read(key: 'kingdom_kids.level_milestone.persisted-kai'),
        '10',
      );
    },
  );

  test('a stale secure read cannot undo a newly presented level', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = _DeferredFirstReadStorage();
    final store = SecureLevelMilestoneStore(storage: storage);
    final staleRead = store.highestPresentedLevel('stale-read-profile');
    await store.markPresented('stale-read-profile', 8);
    storage.firstRead.complete('7');
    expect(await staleRead, 8);
    expect(await store.highestPresentedLevel('stale-read-profile'), 8);
  });

  testWidgets('compact large-text celebration remains readable and closable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.reset);
    var presented = 0;
    var continued = 0;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: LevelMilestoneScreen(
          profile: _profile,
          level: 8,
          levelTitle: 'Faithful Adventurer',
          onPresented: () => presented += 1,
          onContinue: () => continued += 1,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(presented, 1);
    expect(find.byKey(const Key('level-milestone-screen')), findsOneWidget);
    expect(find.text('You reached\nlevel 8!'), findsOneWidget);
    expect(find.text('Amazing work, Ada!'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.byKey(const Key('level-milestone-confetti')), findsNothing);
    expect(find.bySemanticsLabel(RegExp('Level 8 medal')), findsOneWidget);
    final button = find.byKey(const Key('level-milestone-continue'));
    expect(tester.getRect(button).bottom, lessThanOrEqualTo(568));
    expect(button.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(button);
    await tester.pump();
    expect(continued, 1);
    await tester.tap(button);
    expect(continued, 1);
    expect(presented, 1);
    semantics.dispose();
  });

  testWidgets(
    'box reveal pauses in the background and reveals the actual rank',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      addTearDown(() {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      });
      final graphics = (await tester.runAsync(
        () =>
            MilestoneRevealGraphics.load(bundle: StagedMilestoneAssetBundle()),
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          home: LevelMilestoneScreen(
            profile: _profile,
            level: 14,
            levelTitle: 'Kingdom Guardian',
            previewGiftReveal: true,
            graphicsLoader: () async => graphics,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      double badgeOpacity() => tester
          .widget<Opacity>(
            find
                .ancestor(
                  of: find.byKey(const Key('level-milestone-badge-number')),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity;

      expect(badgeOpacity(), 0);
      await tester.pump(
        Duration(
          milliseconds: (graphics.badgeStartSeconds * 1000 - 200).round(),
        ),
      );
      expect(badgeOpacity(), 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 2));
      expect(badgeOpacity(), 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(
        Duration(
          milliseconds:
              ((graphics.badgeEndSeconds - graphics.badgeStartSeconds + .3) *
                      1000)
                  .round(),
        ),
      );
      expect(badgeOpacity(), 1);
      expect(find.byKey(const Key('level-milestone-confetti')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('14'), findsOneWidget);
      expect(find.text('You reached\nlevel 14!'), findsOneWidget);
      expect(find.text('Kingdom Guardian'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('missing artwork immediately reveals the earned level', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    var continued = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: LevelMilestoneScreen(
          profile: _profile,
          level: 14,
          levelTitle: 'Kingdom Hero',
          previewGiftReveal: true,
          onContinue: () => continued++,
          graphicsLoader: () => Future<MilestoneRevealGraphics>.error(
            StateError('Unavailable artwork'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final badge = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.byKey(const Key('level-milestone-badge-number')),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(badge.opacity, 1);
    expect(find.text('14'), findsOneWidget);
    expect(find.text('Kingdom Hero'), findsOneWidget);
    await tester.tap(find.byKey(const Key('level-milestone-continue')));
    expect(continued, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion reveals immediately without decoding the atlas', (
    tester,
  ) async {
    var loads = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: LevelMilestoneScreen(
          profile: _profile,
          level: 15,
          levelTitle: 'Kingdom Champion',
          isMaxLevel: true,
          previewGiftReveal: true,
          graphicsLoader: () {
            loads++;
            return Future<MilestoneRevealGraphics>.error(
              StateError('Reduced motion must skip this loader'),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(loads, 0);
    expect(find.text('15'), findsOneWidget);
    expect(find.text('Kingdom Champion'), findsOneWidget);
    expect(find.text('MAXIMUM LEVEL ACHIEVED'), findsOneWidget);
    expect(find.byKey(const Key('level-milestone-confetti')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'default final-rank screen loads no gift graphics and closes once',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.reset);
      var loads = 0;
      var continued = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: LevelMilestoneScreen(
            profile: _profile,
            level: 15,
            levelTitle: 'Kingdom Champion',
            isMaxLevel: true,
            onContinue: () => continued++,
            graphicsLoader: () {
              loads++;
              return Future<MilestoneRevealGraphics>.error(
                StateError('The default screen must not load gift artwork'),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(loads, 0);
      expect(find.text('15'), findsOneWidget);
      expect(find.text('You reached\nlevel 15!'), findsOneWidget);
      expect(find.text('MAXIMUM LEVEL ACHIEVED'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      for (final key in [
        'level-milestone-box',
        'level-milestone-spotlight',
        'level-milestone-confetti',
      ]) {
        expect(find.byKey(Key(key)), findsNothing);
      }
      await tester.ensureVisible(find.text('Kingdom Champion'));
      expect(find.text('Kingdom Champion').hitTestable(), findsOneWidget);
      final button = find.byKey(const Key('level-milestone-continue'));
      expect(tester.getRect(button).bottom, lessThanOrEqualTo(568));
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('level-milestone-close')));
      await tester.tap(button);
      expect(continued, 1);
      expect(loads, 0);
    },
  );
}

Map<String, dynamic> _milestoneJson() => {
  'previous_level': 7,
  'level': {
    'number': 8,
    'title': 'Faithful Adventurer',
    'xp': 2100,
    'next_level_xp': 2400,
  },
};

Map<String, dynamic> _submissionJson() => {
  'attempt_id': 'attempt-1',
  'operation_id': 'operation-1',
  'game_slug': 'esther-quiz',
  'profile_id': 'kid-1',
  'level_number': 1,
  'completed': true,
  'correct': true,
  'score': 10,
  'max_score': 10,
  'stars_awarded': 3,
  'feedback': 'Well done!',
  'progress': {
    'profile_id': 'kid-1',
    'highest_completed_level': 1,
    'current_level': 1,
    'completed_levels': 1,
    'total_levels': 1,
    'stars_earned': 3,
    'max_stars': 3,
    'percent': 1,
  },
};

const _profile = KidProfile(
  id: 'kid-1',
  parentId: 'parent-1',
  displayName: 'Ada',
  avatarKey: 'kai',
);

class _DeferredFirstReadStorage extends FlutterSecureStorage {
  final firstRead = Completer<String?>();
  var _readCalls = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (_readCalls++ == 0) return firstRead.future;
    return super.read(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }
}

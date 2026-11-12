import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/streak/domain/streak_presentation.dart';
import 'package:mobile/features/streak/presentation/streak_screen.dart';
import 'package:mobile/shared/audio/app_audio_controller.dart';
import 'package:mobile/shared/audio/app_audio_scope.dart';
import 'package:mobile/shared/audio/app_sound_cue.dart';

void main() {
  testWidgets(
    'streak cue is once per presentation across pulses and rebuilds',
    (tester) async {
      final audio = _RecordingAudioController();
      addTearDown(audio.dispose);
      final key = GlobalKey();
      var reducedMotion = false;
      Widget host() => AppAudioScope(
        controller: audio,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: reducedMotion,
              textScaler: TextScaler.linear(reducedMotion ? 1.3 : 1),
            ),
            child: child!,
          ),
          home: StreakScreen(
            key: key,
            presentation: _presentation(
              state: StreakPresentationState.continued,
              currentDays: 7,
              longestDays: 7,
            ),
          ),
        ),
      );

      await tester.pumpWidget(host());
      final mountedPresentation = key.currentState;
      expect(audio.cues, [AppSoundCue.streak]);
      await tester.pump(const Duration(seconds: 5));
      audio.notifyListeners();
      await tester.pump();
      reducedMotion = true;
      await tester.pumpWidget(host());
      await tester.pump();
      reducedMotion = false;
      await tester.pumpWidget(host());
      await tester.pump(const Duration(seconds: 5));
      expect(key.currentState, same(mountedPresentation));
      expect(audio.cues, [AppSoundCue.streak]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a streak disposed before its queued frame does not request audio',
    (tester) async {
      final audio = _RecordingAudioController();
      addTearDown(audio.dispose);
      final key = GlobalKey();
      final binding = tester.binding;
      // Build without pumping the scheduler: initState queues its first-frame
      // callback, then we dispose the mounted subtree before that callback runs.
      binding.attachRootWidget(
        binding.wrapWithDefaultView(
          AppAudioScope(
            controller: audio,
            child: MaterialApp(
              home: StreakScreen(
                key: key,
                presentation: _presentation(
                  state: StreakPresentationState.firstStreak,
                  currentDays: 1,
                  longestDays: 1,
                ),
              ),
            ),
          ),
        ),
      );
      binding.buildOwner!.buildScope(binding.rootElement!);
      expect(key.currentState, isNotNull);
      expect(audio.cues, isEmpty);
      binding.attachRootWidget(
        binding.wrapWithDefaultView(const SizedBox.shrink()),
      );
      binding.buildOwner!.buildScope(binding.rootElement!);
      binding.buildOwner!.finalizeTree();
      expect(key.currentState, isNull);
      await tester.pump();
      expect(audio.cues, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a route covering the first streak frame prevents the cue', (
    tester,
  ) async {
    final audio = _RecordingAudioController();
    addTearDown(audio.dispose);
    final navigatorKey = GlobalKey<NavigatorState>();
    final binding = tester.binding;
    binding.attachRootWidget(
      binding.wrapWithDefaultView(
        AppAudioScope(
          controller: audio,
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: StreakScreen(
              presentation: _presentation(
                state: StreakPresentationState.firstStreak,
                currentDays: 1,
                longestDays: 1,
              ),
            ),
          ),
        ),
      ),
    );
    binding.buildOwner!.buildScope(binding.rootElement!);
    navigatorKey.currentState!.push<void>(
      MaterialPageRoute(
        builder: (_) => const Scaffold(body: Text('Covering route')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Covering route'), findsOneWidget);
    expect(audio.cues, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('daily XP is shown only when a saved reward is supplied', (
    tester,
  ) async {
    final presentation = _presentation(
      state: StreakPresentationState.continued,
      currentDays: 7,
      longestDays: 7,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: StreakScreen(presentation: presentation, xpAwarded: 20),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('+20 XP for today’s visit'), findsOneWidget);
    await tester.pumpWidget(
      MaterialApp(home: StreakScreen(presentation: presentation)),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const Key('streak-xp-reward')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('celebrates a first app-open streak with the orange flame', (
    tester,
  ) async {
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: StreakScreen(
          presentation: _presentation(
            state: StreakPresentationState.firstStreak,
            currentDays: 1,
            longestDays: 1,
          ),
          onClose: () => closed = true,
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('1 day streak!'), findsOneWidget);
    expect(find.text('A NEW SPARK'), findsOneWidget);
    expect(
      find.text(
        'Maya, you showed up today. Come back tomorrow to keep your flame glowing.',
      ),
      findsOneWidget,
    );
    final flame = tester.widget<Icon>(
      find.byKey(const Key('streak-flame-icon-hero')),
    );
    expect(flame.icon, Icons.local_fire_department_rounded);
    expect(flame.color, const Color(0xFFFF6B35));
    expect(find.byKey(const Key('streak-character')), findsNothing);
    expect(find.byKey(const Key('streak-flame-counter')), findsNothing);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      const Color(0xFFF3F6FF),
    );
    expect(find.byKey(const Key('streak-recent-days')), findsOneWidget);

    await tester.tap(find.byKey(const Key('streak-continue-button')));
    expect(closed, isTrue);
  });

  testWidgets('only the flame flickers and Reduce Motion freezes it', (
    tester,
  ) async {
    final key = GlobalKey();
    Widget host({required bool reducedMotion}) => MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
        child: child!,
      ),
      home: StreakScreen(
        key: key,
        presentation: _presentation(
          state: StreakPresentationState.firstStreak,
          currentDays: 1,
          longestDays: 1,
        ),
        xpAwarded: 20,
        onClose: () {},
      ),
    );
    await tester.pumpWidget(host(reducedMotion: false));
    final retainedGeometry = <String, Rect>{
      for (final name in [
        'streak-character-stage',
        'streak-title',
        'streak-message',
        'streak-xp-reward',
        'streak-recent-days',
        'streak-continue-button',
        'streak-close-button',
      ])
        name: tester.getRect(find.byKey(Key(name))),
    };
    List<double> flicker() => tester
        .widget<Transform>(find.byKey(const Key('streak-flame-flicker')))
        .transform
        .storage
        .toList();
    final initial = flicker();
    await tester.pump(const Duration(milliseconds: 450));
    expect(flicker(), isNot(orderedEquals(initial)));
    for (final entry in retainedGeometry.entries) {
      expect(tester.getRect(find.byKey(Key(entry.key))), entry.value);
    }
    await tester.pumpWidget(host(reducedMotion: true));
    final reduced = flicker();
    expect(reduced, orderedEquals(Matrix4.identity().storage));
    await tester.pump(const Duration(seconds: 3));
    expect(flicker(), orderedEquals(reduced));
    expect(tester.takeException(), isNull);
  });

  testWidgets('continued copy is plural and reports a real personal best', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StreakScreen(
          presentation: _presentation(
            state: StreakPresentationState.continued,
            currentDays: 7,
            longestDays: 7,
          ),
          onClose: () {},
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('7 days streak!'), findsOneWidget);
    expect(find.text('YOUR BEST STREAK'), findsOneWidget);
    expect(
      find.text(
        'That’s your best yet, Maya! Come back tomorrow to keep your flame glowing.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('streak remains scrollable with reduced motion and large text', (
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
            disableAnimations: true,
            textScaler: const TextScaler.linear(2),
          ),
          child: child!,
        ),
        home: StreakScreen(
          presentation: _presentation(
            state: StreakPresentationState.continued,
            currentDays: 4,
            longestDays: 6,
          ),
          onClose: () {},
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('streak-scroll')), findsOneWidget);
    expect(find.byKey(const Key('streak-continue-button')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('announces the streak without an at-risk page state', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: StreakScreen(
          presentation: _presentation(
            state: StreakPresentationState.continued,
            currentDays: 2,
            longestDays: 5,
          ),
          onClose: () {},
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));

    expect(
      find.bySemanticsLabel(
        '2 days streak! Maya, you showed up today. Just 1 more day to a 3-day streak.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('at risk', findRichText: true), findsNothing);
    semantics.dispose();
  });
}

class _RecordingAudioController extends AppAudioController {
  final cues = <AppSoundCue>[];

  @override
  void playEffect(AppSoundCue cue) => cues.add(cue);
}

StreakPresentation _presentation({
  required StreakPresentationState state,
  required int currentDays,
  required int longestDays,
}) {
  return StreakPresentation(
    profile: const KidProfile(
      id: 'kid-1',
      parentId: 'parent-1',
      displayName: 'Maya',
      avatarKey: 'dove',
    ),
    state: state,
    currentDays: currentDays,
    longestDays: longestDays,
    localDate: DateTime(2026, 7, 25),
    recentDays: [
      for (var offset = 6; offset >= 0; offset--)
        StreakDay(
          date: DateTime(2026, 7, 25).subtract(Duration(days: offset)),
          active: offset < currentDays,
        ),
    ],
  );
}

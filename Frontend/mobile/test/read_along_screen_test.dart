import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/auth/data/auth_session_store.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/kid_profile.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';
import 'package:mobile/features/auth/presentation/kid_character_pose.dart';
import 'package:mobile/features/parental_controls/data/parental_controls_repository.dart';
import 'package:mobile/features/parental_controls/domain/parent_settings.dart';
import 'package:mobile/features/progress/data/progress_repository.dart';
import 'package:mobile/features/progress/domain/story_activity_event.dart';
import 'package:mobile/features/stories/data/story_narration_service.dart';
import 'package:mobile/features/stories/domain/story_detail.dart';
import 'package:mobile/features/stories/presentation/read_along_screen.dart';

void main() {
  testWidgets('records a start only after native narration really starts', (
    tester,
  ) async {
    final service = _FakeNarrationService(autoStart: false);
    final progress = _FakeProgressRepository();

    await tester.pumpWidget(
      _testApp(
        story: _story(id: 'story-1'),
        service: service,
        authRepository: await _selectedKidRepository(),
        settings: _FakeSettingsRepository(_settings()),
        progressRepository: progress,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pump();
    expect(service.speakCalls, 1);
    expect(progress.calls, isEmpty);

    service.emitStarted();
    await tester.pump();
    expect(progress.calls, hasLength(1));
    expect(progress.calls.single.eventType, StoryActivityType.storyStarted);
  });

  testWidgets('records one logical start across pause, resume, and restart', (
    tester,
  ) async {
    final service = _FakeNarrationService();
    final progress = _FakeProgressRepository();
    final operationIds = <String>[
      '00000000-0000-4000-8000-000000000001',
      '00000000-0000-4000-8000-000000000002',
    ].iterator;

    await tester.pumpWidget(
      _testApp(
        story: _story(id: 'story-1'),
        service: service,
        authRepository: await _selectedKidRepository(),
        settings: _FakeSettingsRepository(_settings()),
        progressRepository: progress,
        operationIdFactory: () {
          operationIds.moveNext();
          return operationIds.current;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('read-along-replay')));
    await tester.pumpAndSettle();

    final starts = progress.calls
        .where((call) => call.eventType == StoryActivityType.storyStarted)
        .toList();
    expect(starts, hasLength(1));
    expect(starts.single.operationId, '00000000-0000-4000-8000-000000000001');
  });

  testWidgets('retries a failed start with its stable id', (tester) async {
    final service = _FakeNarrationService();
    final progress = _FakeProgressRepository(
      failuresRemaining: {StoryActivityType.storyStarted: 1},
    );
    var operationIndex = 0;
    const operationIds = [
      '00000000-0000-4000-8000-000000000011',
      '00000000-0000-4000-8000-000000000012',
    ];

    await tester.pumpWidget(
      _testApp(
        story: _story(id: 'story-1'),
        service: service,
        authRepository: await _selectedKidRepository(),
        settings: _FakeSettingsRepository(_settings()),
        progressRepository: progress,
        operationIdFactory: () => operationIds[operationIndex++],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('read-along-replay')));
    await tester.pumpAndSettle();

    final starts = progress.calls
        .where((call) => call.eventType == StoryActivityType.storyStarted)
        .toList();
    expect(starts, hasLength(2));
    expect(starts[1].operationId, starts[0].operationId);
  });

  testWidgets('records a fully heard story and celebrates without waiting', (
    tester,
  ) async {
    final service = _FakeNarrationService();
    final progress = _FakeProgressRepository(
      failuresRemaining: {StoryActivityType.storyCompleted: 1},
    );

    await tester.pumpWidget(
      _testApp(
        story: _story(id: 'story-1'),
        service: service,
        authRepository: await _selectedKidRepository(),
        settings: _FakeSettingsRepository(_settings()),
        progressRepository: progress,
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();

    await _completeNarration(tester, service);

    expect(find.byKey(const Key('story-completion-screen')), findsOneWidget);
    expect(
      progress.calls.where(
        (call) => call.eventType == StoryActivityType.storyCompleted,
      ),
      hasLength(1),
    );
  });

  testWidgets('a late-passage shortcut cannot earn story completion', (
    tester,
  ) async {
    final service = _FakeNarrationService();
    final progress = _FakeProgressRepository();

    await tester.pumpWidget(
      _testApp(
        story: _story(id: 'story-1'),
        service: service,
        authRepository: await _selectedKidRepository(),
        settings: _FakeSettingsRepository(_settings()),
        progressRepository: progress,
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('read-along-next')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pump();
    service.emitCompleteProgress();
    service.emitCompleted();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('story-completion-screen')), findsNothing);
    expect(find.byKey(const Key('read-along-screen')), findsOneWidget);
    expect(
      find.text(
        'A few parts are still waiting. Tap play to hear them from the beginning.',
      ),
      findsOneWidget,
    );
    expect(
      progress.calls.where(
        (call) => call.eventType == StoryActivityType.storyCompleted,
      ),
      isEmpty,
    );
  });

  testWidgets('missing story id never sends progress but does not block joy', (
    tester,
  ) async {
    final service = _FakeNarrationService();
    final progress = _FakeProgressRepository();

    await tester.pumpWidget(
      _testApp(
        story: _story(),
        service: service,
        authRepository: await _selectedKidRepository(),
        settings: _FakeSettingsRepository(_settings()),
        progressRepository: progress,
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();
    await _completeNarration(tester, service);

    expect(progress.calls, isEmpty);
    expect(find.byKey(const Key('story-completion-screen')), findsOneWidget);
  });

  testWidgets('missing profile id never sends a native-start callback', (
    tester,
  ) async {
    final service = _FakeNarrationService(autoStart: false);
    final progress = _FakeProgressRepository();

    await tester.pumpWidget(
      _testApp(
        story: _story(id: 'story-1'),
        service: service,
        authRepository: AuthRepository(sessionStore: MemoryAuthSessionStore()),
        settings: _FakeSettingsRepository(_settings()),
        progressRepository: progress,
      ),
    );
    await tester.pumpAndSettle();

    service.emitStarted();
    await tester.pump();

    expect(progress.calls, isEmpty);
  });

  testWidgets(
    'shows the reference player and highlights profile narration progress',
    (tester) async {
      final service = _FakeNarrationService();
      final story = _story();

      await tester.pumpWidget(
        _testApp(
          story: story,
          service: service,
          authRepository: await _selectedKidRepository(avatarKey: 'dove'),
          settings: _FakeSettingsRepository(_settings()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('read-along-story-header')), findsNothing);
      expect(find.byKey(const Key('read-along-artwork')), findsOneWidget);
      expect(find.byKey(const Key('read-along-title')), findsOneWidget);
      expect(find.text(story.title), findsOneWidget);
      final title = tester.widget<Text>(
        find.byKey(const Key('read-along-title')),
      );
      expect(title.maxLines, 1);
      expect(title.style?.fontSize, lessThanOrEqualTo(16));
      expect(find.text('Who should read?'), findsNothing);
      expect(find.byKey(const Key('read-along-voice-lion')), findsNothing);
      expect(find.byKey(const Key('read-along-voice-dove')), findsNothing);
      expect(find.byKey(const Key('read-along-voice-rainbow')), findsNothing);

      const controlKeys = [
        Key('read-along-replay'),
        Key('read-along-previous'),
        Key('read-along-play-pause'),
        Key('read-along-next'),
        Key('read-along-stop'),
      ];
      for (final key in controlKeys) {
        expect(find.byKey(key), findsOneWidget);
      }
      expect(
        find.descendant(
          of: find.byKey(const Key('read-along-controls')),
          matching: find.byType(IconButton),
        ),
        findsNWidgets(5),
      );

      await tester.tap(find.byKey(const Key('read-along-play-pause')));
      await tester.pump();

      expect(service.spokenText, story.body);
      expect(service.spokenNarration?.characterName, 'Nia');

      final start = story.body.indexOf('trusted');
      final end = start + 'trusted'.length;
      service.emitProgress(story.body, start, end, 'trusted');
      await tester.pump();

      final text = tester.widget<Text>(
        find.byKey(const Key('read-along-story-text')),
      );
      final spans = (text.textSpan! as TextSpan).children!;
      final activeSpan = spans.cast<TextSpan>().singleWhere(
        (span) => span.text == 'trusted',
      );
      expect(activeSpan.style?.color, const Color(0xFFF15F43));
      expect(activeSpan.style?.backgroundColor, const Color(0xFFFFE1D7));

      final expectedProgress = end / story.body.length;
      final progress = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('read-along-progress')),
      );
      expect(progress.value, closeTo(expectedProgress, 0.0001));
      expect(progress.color, const Color(0xFFF15F43));
      expect(find.text('3:00'), findsOneWidget);
      final semanticsHandle = tester.ensureSemantics();
      try {
        final progressSemantics = tester
            .getSemantics(find.bySemanticsLabel('Story progress'))
            .getSemanticsData();
        expect(progressSemantics.label, 'Story progress');
        expect(
          progressSemantics.value,
          '${(expectedProgress * 100).round()} percent',
        );
      } finally {
        semanticsHandle.dispose();
      }

      await tester.tap(find.byKey(const Key('read-along-play-pause')));
      await tester.pump();
      expect(service.pauseCalls, 1);
      expect(find.text('Paused.'), findsOneWidget);
    },
  );

  testWidgets('restart, previous, next, and stop control narration', (
    tester,
  ) async {
    final service = _FakeNarrationService();
    final story = _story();
    final secondPassageStart = story.body.indexOf('He stepped');

    await tester.pumpWidget(
      _testApp(
        story: story,
        service: service,
        authRepository: await _selectedKidRepository(),
        settings: _FakeSettingsRepository(_settings()),
      ),
    );
    await tester.pumpAndSettle();

    final previous = find.byKey(const Key('read-along-previous'));
    final next = find.byKey(const Key('read-along-next'));
    expect(
      _transportIconButton(tester, const Key('read-along-previous')).onPressed,
      isNull,
    );
    expect(
      _transportIconButton(tester, const Key('read-along-next')).onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pumpAndSettle();
    expect(service.spokenText, story.body);

    final braveStart = story.body.indexOf('brave');
    service.emitProgress(
      story.body,
      braveStart,
      braveStart + 'brave'.length,
      'brave',
    );
    await tester.pump();
    expect(
      _transportIconButton(tester, const Key('read-along-previous')).onPressed,
      isNotNull,
    );
    expect(
      _transportIconButton(tester, const Key('read-along-next')).onPressed,
      isNull,
    );

    await tester.tap(previous);
    await tester.pumpAndSettle();
    expect(service.stopCalls, 1);
    expect(service.speakCalls, 2);
    expect(service.spokenText, story.body);

    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(service.stopCalls, 2);
    expect(service.speakCalls, 3);
    expect(service.spokenText, story.body.substring(secondPassageStart));

    await tester.tap(find.byKey(const Key('read-along-replay')));
    await tester.pumpAndSettle();
    expect(service.stopCalls, 3);
    expect(service.speakCalls, 4);
    expect(service.spokenText, story.body);

    await tester.tap(find.byKey(const Key('read-along-stop')));
    await tester.pumpAndSettle();
    expect(service.stopCalls, 4);
    expect(service.speakCalls, 4);
    final progress = tester.widget<LinearProgressIndicator>(
      find.byKey(const Key('read-along-progress')),
    );
    expect(progress.value, 0);
    expect(find.text('0:00'), findsOneWidget);
  });

  testWidgets(
    'natural completion swaps the player for the selected character celebration',
    (tester) async {
      final service = _FakeNarrationService();
      final story = _story();

      await tester.pumpWidget(
        _testApp(
          story: story,
          service: service,
          authRepository: await _selectedKidRepository(avatarKey: 'rainbow'),
          settings: _FakeSettingsRepository(_settings()),
          disableAnimations: true,
        ),
      );
      await tester.pumpAndSettle();

      await _completeNarration(tester, service);

      expect(find.byKey(const Key('read-along-screen')), findsNothing);
      expect(find.byKey(const Key('story-completion-screen')), findsOneWidget);
      expect(find.byKey(const Key('story-completion-stars')), findsOneWidget);
      final characterPose = tester.widget<KidProfileCharacterPose>(
        find.byKey(const Key('story-completion-avatar')),
      );
      expect(characterPose.profile.avatarKey, 'rainbow');
      expect(characterPose.pose, KidCharacterPose.celebrate);
      final characterImage = tester.widget<Image>(
        find.descendant(
          of: find.byKey(const Key('story-completion-avatar')),
          matching: find.byType(Image),
        ),
      );
      expect(
        (characterImage.image as AssetImage).assetName,
        'assets/images/characters/poses/zuri-medal.png',
      );
      expect(
        tester
            .widget<Scaffold>(find.byKey(const Key('story-completion-screen')))
            .backgroundColor,
        const Color(0xFFE77772),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('story-completion-title')))
            .data,
        'You did it!',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('story-completion-message')))
            .data,
        'Zuri is proud of you. You followed every word!',
      );
    },
  );

  testWidgets('completion keeps every profile character exact', (tester) async {
    const characters = <String, ({String name, Color color, String asset})>{
      'lion': (
        name: 'Kai',
        color: Color(0xFF46A994),
        asset: 'assets/images/mascot/mascot_badge.png',
      ),
      'dove': (
        name: 'Nia',
        color: Color(0xFF9870C7),
        asset: 'assets/images/characters/poses/nia-medal.png',
      ),
      'rainbow': (
        name: 'Zuri',
        color: Color(0xFFE77772),
        asset: 'assets/images/characters/poses/zuri-medal.png',
      ),
    };

    for (final entry in characters.entries) {
      final service = _FakeNarrationService();
      await tester.pumpWidget(
        _testApp(
          story: _story(),
          service: service,
          authRepository: await _selectedKidRepository(avatarKey: entry.key),
          settings: _FakeSettingsRepository(_settings()),
          disableAnimations: true,
        ),
      );
      await tester.pumpAndSettle();

      await _completeNarration(tester, service);

      final characterPose = tester.widget<KidProfileCharacterPose>(
        find.byKey(const Key('story-completion-avatar')),
      );
      expect(characterPose.profile.avatarKey, entry.key);
      expect(characterPose.pose, KidCharacterPose.celebrate);
      final characterImage = tester.widget<Image>(
        find.descendant(
          of: find.byKey(const Key('story-completion-avatar')),
          matching: find.byType(Image),
        ),
      );
      expect((characterImage.image as AssetImage).assetName, entry.value.asset);
      expect(
        tester
            .widget<Scaffold>(find.byKey(const Key('story-completion-screen')))
            .backgroundColor,
        entry.value.color,
      );
      expect(
        find.text(
          '${entry.value.name} is proud of you. You followed every word!',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
  });

  testWidgets('stop and cancellation never open the completion screen', (
    tester,
  ) async {
    final service = _FakeNarrationService();

    await tester.pumpWidget(
      _testApp(
        story: _story(),
        service: service,
        authRepository: await _selectedKidRepository(),
        settings: _FakeSettingsRepository(_settings()),
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('read-along-stop')));
    await tester.pumpAndSettle();

    expect(service.stopCalls, 1);
    expect(find.byKey(const Key('story-completion-screen')), findsNothing);
    expect(find.byKey(const Key('read-along-screen')), findsOneWidget);

    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pump();
    service.emitCancelled();
    await tester.pump();

    expect(find.byKey(const Key('story-completion-screen')), findsNothing);
    expect(find.byKey(const Key('read-along-screen')), findsOneWidget);
  });

  testWidgets('cancellation and errors cannot persist a completion', (
    tester,
  ) async {
    final service = _FakeNarrationService();
    final progress = _FakeProgressRepository();

    await tester.pumpWidget(
      _testApp(
        story: _story(id: 'story-1'),
        service: service,
        authRepository: await _selectedKidRepository(),
        settings: _FakeSettingsRepository(_settings()),
        progressRepository: progress,
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pump();
    service.emitCompleteProgress();
    service.emitCancelled();
    service.emitCompleted();
    await tester.pump();

    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pump();
    service.emitCompleteProgress();
    service.emitError();
    service.emitCompleted();
    await tester.pump();

    expect(find.byKey(const Key('story-completion-screen')), findsNothing);
    expect(
      progress.calls.where(
        (call) => call.eventType == StoryActivityType.storyCompleted,
      ),
      isEmpty,
    );
  });

  testWidgets('duplicate completion callbacks keep one completion screen', (
    tester,
  ) async {
    final service = _FakeNarrationService();

    await tester.pumpWidget(
      _testApp(
        story: _story(),
        service: service,
        authRepository: await _selectedKidRepository(),
        settings: _FakeSettingsRepository(_settings()),
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pump();

    service.emitCompleteProgress();
    service.emitCompleted();
    service.emitCompleted();
    await tester.pump();

    expect(find.byKey(const Key('story-completion-screen')), findsOneWidget);
    expect(find.byKey(const Key('story-completion-title')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Continue pops cleanly to the route below Read Along', (
    tester,
  ) async {
    final service = _FakeNarrationService();
    final authRepository = await _selectedKidRepository(avatarKey: 'dove');
    final settings = _FakeSettingsRepository(_settings());

    await tester.pumpWidget(
      _navigationTestApp(
        story: _story(),
        service: service,
        authRepository: authRepository,
        settings: settings,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('completion-prior-route')), findsOneWidget);

    await tester.tap(find.byKey(const Key('open-read-along')));
    await tester.pumpAndSettle();
    await _completeNarration(tester, service);
    expect(find.byKey(const Key('story-completion-screen')), findsOneWidget);

    await tester.tap(find.byKey(const Key('story-completion-continue')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('completion-prior-route')), findsOneWidget);
    expect(find.byKey(const Key('story-completion-screen')), findsNothing);
    expect(find.byKey(const Key('read-along-screen')), findsNothing);
    expect(service.disposeCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'completion fits a compact large-text screen with reduced motion',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final service = _FakeNarrationService();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              disableAnimations: true,
              accessibleNavigation: true,
            ),
            child: child!,
          ),
          home: ReadAlongScreen(
            story: _story(),
            narrationService: service,
            authRepository: await _selectedKidRepository(),
            settingsRepository: _FakeSettingsRepository(_settings()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _completeNarration(tester, service);

      final screen = find.byKey(const Key('story-completion-screen'));
      final stage = find.byKey(const Key('story-completion-stage'));
      final characterPose = find.byKey(const Key('story-completion-avatar'));
      final continueButton = find.byKey(const Key('story-completion-continue'));
      expect(screen, findsOneWidget);
      expect(find.byKey(const Key('story-completion-scroll')), findsOneWidget);
      expect(stage, findsOneWidget);
      expect(characterPose, findsOneWidget);
      expect(continueButton, findsOneWidget);
      expect(continueButton.hitTestable(), findsOneWidget);

      final screenRect = tester.getRect(screen);
      final stageRect = tester.getRect(stage);
      final characterRect = tester.getRect(characterPose);
      final buttonRect = tester.getRect(continueButton);
      expect(stageRect.width, lessThanOrEqualTo(screenRect.width));
      expect(stageRect.height, greaterThan(stageRect.width));
      expect(characterRect, stageRect);
      expect(buttonRect.left, greaterThanOrEqualTo(screenRect.left));
      expect(buttonRect.right, lessThanOrEqualTo(screenRect.right));
      expect(buttonRect.top, greaterThanOrEqualTo(screenRect.top));
      expect(buttonRect.bottom, lessThanOrEqualTo(screenRect.bottom));
      expect(buttonRect.height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('completion announces itself and exposes an accessible CTA', (
    tester,
  ) async {
    final service = _FakeNarrationService();
    final story = _story();

    await tester.pumpWidget(
      _testApp(
        story: story,
        service: service,
        authRepository: await _selectedKidRepository(avatarKey: 'dove'),
        settings: _FakeSettingsRepository(_settings()),
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();
    await _completeNarration(tester, service);

    final semanticsHandle = tester.ensureSemantics();
    try {
      await tester.pump();
      final announcement = tester
          .getSemantics(find.byKey(const Key('story-completion-announcement')))
          .getSemanticsData();
      expect(
        announcement.label,
        'Story complete. Nia is proud of you for finishing ${story.title}.',
      );
      expect(announcement.flagsCollection.isLiveRegion, isTrue);

      final continueSemantics = tester
          .getSemantics(
            find.bySemanticsLabel('Continue after finishing ${story.title}'),
          )
          .getSemanticsData();
      expect(
        continueSemantics.label,
        'Continue after finishing ${story.title}',
      );
      expect(continueSemantics.flagsCollection.isButton, isTrue);
    } finally {
      semanticsHandle.dispose();
    }

    final buttonRect = tester.getRect(
      find.byKey(const Key('story-completion-continue')),
    );
    expect(buttonRect.width, greaterThanOrEqualTo(48));
    expect(buttonRect.height, greaterThanOrEqualTo(48));
  });

  testWidgets('does not substitute another voice for a legacy profile buddy', (
    tester,
  ) async {
    final service = _FakeNarrationService();

    await tester.pumpWidget(
      _testApp(
        story: _story(),
        service: service,
        authRepository: await _selectedKidRepository(avatarKey: 'star'),
        settings: _FakeSettingsRepository(_settings()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Your buddy’s reading voice isn’t ready yet.'),
      findsOneWidget,
    );
    final playButton = tester.widget<IconButton>(
      find.byKey(const Key('read-along-play-pause')),
    );
    expect(playButton.onPressed, isNull);
    expect(service.speakCalls, 0);
  });

  testWidgets('honours a parent setting that turns narration off', (
    tester,
  ) async {
    final service = _FakeNarrationService();

    await tester.pumpWidget(
      _testApp(
        story: _story(),
        service: service,
        authRepository: await _selectedKidRepository(),
        settings: _FakeSettingsRepository(_settings(narrationEnabled: false)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Narration is off in Parent settings.'), findsOneWidget);
    final playButton = tester.widget<IconButton>(
      find.byKey(const Key('read-along-play-pause')),
    );
    expect(playButton.onPressed, isNull);
    expect(service.speakCalls, 0);
  });

  testWidgets('resume continues from the highlighted word', (tester) async {
    final service = _FakeNarrationService();
    final story = _story();

    await tester.pumpWidget(
      _testApp(
        story: story,
        service: service,
        authRepository: await _selectedKidRepository(),
        settings: _FakeSettingsRepository(_settings()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pump();
    final wordStart = story.body.indexOf('trusted');
    final wordEnd = wordStart + 'trusted'.length;
    service.emitProgress(story.body, wordStart, wordEnd, 'trusted');
    await tester.pump();

    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pumpAndSettle();

    final resumedText = story.body.substring(wordStart);
    expect(service.spokenText, resumedText);
    expect(service.speakCalls, 2);
    expect(service.stopCalls, 1);

    service.emitProgress(resumedText, 0, 'trusted'.length, 'trusted');
    await tester.pump();
    final text = tester.widget<Text>(
      find.byKey(const Key('read-along-story-text')),
    );
    final spans = (text.textSpan! as TextSpan).children!;
    expect((spans[1] as TextSpan).text, 'trusted');
  });

  testWidgets('shows a safe unavailable state when story text is missing', (
    tester,
  ) async {
    final service = _FakeNarrationService();

    await tester.pumpWidget(
      _testApp(
        story: _story(body: ''),
        service: service,
        authRepository: AuthRepository(sessionStore: MemoryAuthSessionStore()),
        settings: _FakeSettingsRepository(_settings()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('read-along-empty-story')), findsOneWidget);
    expect(find.text('This story is still getting ready.'), findsOneWidget);
    final playButton = tester.widget<IconButton>(
      find.byKey(const Key('read-along-play-pause')),
    );
    expect(playButton.onPressed, isNull);
  });

  testWidgets('remains usable on a compact phone with large reading text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: ReadAlongScreen(
          story: _story(),
          narrationService: _FakeNarrationService(),
          authRepository: await _selectedKidRepository(),
          settingsRepository: _FakeSettingsRepository(
            _settings(storyTextScale: StoryTextScale.extraLarge),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('read-along-story-header')), findsNothing);
    expect(find.text('Who should read?'), findsNothing);
    expect(find.byKey(const Key('read-along-artwork')), findsOneWidget);
    expect(find.byKey(const Key('read-along-title')), findsOneWidget);
    const compactKeys = [
      Key('read-along-replay'),
      Key('read-along-previous'),
      Key('read-along-play-pause'),
      Key('read-along-next'),
      Key('read-along-stop'),
    ];
    final screenRect = tester.getRect(
      find.byKey(const Key('read-along-screen')),
    );
    for (final key in compactKeys) {
      final finder = find.byKey(key);
      expect(finder, findsOneWidget);
      final controlRect = tester.getRect(finder);
      expect(controlRect.left, greaterThanOrEqualTo(screenRect.left));
      expect(controlRect.right, lessThanOrEqualTo(screenRect.right));
      expect(controlRect.top, greaterThanOrEqualTo(screenRect.top));
      expect(controlRect.bottom, lessThanOrEqualTo(screenRect.bottom));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('auto-scrolls toward later words and disposes narration', (
    tester,
  ) async {
    final service = _FakeNarrationService();
    final longBody = List.generate(
      55,
      (index) => 'Faith helped David take brave step ${index + 1}.',
    ).join(' ');
    final story = _story(body: longBody);

    await tester.pumpWidget(
      _testApp(
        story: story,
        service: service,
        authRepository: await _selectedKidRepository(),
        settings: _FakeSettingsRepository(_settings()),
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();

    final wordStart = story.body.lastIndexOf('brave');
    service.emitProgress(
      story.body,
      wordStart,
      wordStart + 'brave'.length,
      'brave',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final textScroll = tester.widget<SingleChildScrollView>(
      find.byKey(const Key('read-along-text-scroll')),
    );
    expect(textScroll.controller!.offset, greaterThan(0));

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(service.disposeCalls, 1);
  });
}

IconButton _transportIconButton(WidgetTester tester, Key key) {
  return tester.widget<IconButton>(
    find.descendant(of: find.byKey(key), matching: find.byType(IconButton)),
  );
}

Future<void> _completeNarration(
  WidgetTester tester,
  _FakeNarrationService service,
) async {
  await tester.tap(find.byKey(const Key('read-along-play-pause')));
  await tester.pump();
  service.emitCompleteProgress();
  service.emitCompleted();
  await tester.pumpAndSettle();
}

Widget _navigationTestApp({
  required StoryDetail story,
  required _FakeNarrationService service,
  required AuthRepository authRepository,
  required ParentalControlsRepository settings,
}) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        key: const Key('completion-prior-route'),
        body: Center(
          child: FilledButton(
            key: const Key('open-read-along'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ReadAlongScreen(
                  story: story,
                  narrationService: service,
                  authRepository: authRepository,
                  settingsRepository: settings,
                ),
              ),
            ),
            child: const Text('Open Read Along'),
          ),
        ),
      ),
    ),
  );
}

Widget _testApp({
  required StoryDetail story,
  required _FakeNarrationService service,
  required AuthRepository authRepository,
  required ParentalControlsRepository settings,
  ProgressRepository? progressRepository,
  StoryProgressOperationIdFactory operationIdFactory =
      newStoryProgressOperationId,
  bool disableAnimations = false,
}) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: disableAnimations),
      child: child!,
    ),
    home: ReadAlongScreen(
      story: story,
      narrationService: service,
      authRepository: authRepository,
      settingsRepository: settings,
      progressRepository: progressRepository,
      operationIdFactory: operationIdFactory,
    ),
  );
}

StoryDetail _story({
  String id = '',
  String body = 'David trusted God. He stepped forward with brave faith.',
}) {
  return StoryDetail(
    id: id,
    slug: 'david-and-goliath',
    title: 'David & Goliath',
    author: 'Kingdom Kids',
    category: 'Courage',
    summary: 'A brave story.',
    body: body,
    estimatedReadSeconds: 180,
    narrations: [
      StoryNarration(
        avatarKey: 'lion',
        voiceKey: 'kai',
        characterName: 'Kai',
        voiceDescription: 'Warm and adventurous',
        locale: 'en-GB',
        speechRate: 0.42,
        pitch: 0.92,
        status: 'device_tts',
        audioAvailable: false,
      ),
      StoryNarration(
        avatarKey: 'dove',
        voiceKey: 'nia',
        characterName: 'Nia',
        voiceDescription: 'Gentle and bright',
        locale: 'en-GB',
        speechRate: 0.4,
        pitch: 1.08,
        status: 'device_tts',
        audioAvailable: false,
      ),
      StoryNarration(
        avatarKey: 'rainbow',
        voiceKey: 'zuri',
        characterName: 'Zuri',
        voiceDescription: 'Joyful and playful',
        locale: 'en-GB',
        speechRate: 0.44,
        pitch: 1.16,
        status: 'device_tts',
        audioAvailable: false,
      ),
    ],
  );
}

Future<AuthRepository> _selectedKidRepository({
  String avatarKey = 'lion',
}) async {
  final store = MemoryAuthSessionStore();
  await store.writeSession(
    AuthSession(
      parent: const ParentAccount(id: 'parent-1', email: 'parent@example.com'),
      accessToken: 'access-token',
      profiles: [
        KidProfile(
          id: 'kid-1',
          parentId: 'parent-1',
          displayName: 'Ada',
          avatarKey: avatarKey,
        ),
      ],
    ),
  );
  await store.writeSelectedKidId('kid-1');
  return AuthRepository(sessionStore: store);
}

ParentSettings _settings({
  bool narrationEnabled = true,
  StoryTextScale storyTextScale = StoryTextScale.comfortable,
}) {
  return ParentSettings(
    profileId: 'kid-1',
    storyTextScale: storyTextScale,
    narrationEnabled: narrationEnabled,
    updatedAt: DateTime.utc(2026, 7, 15, 12),
  );
}

final class _FakeSettingsRepository implements ParentalControlsRepository {
  _FakeSettingsRepository(this.settings);

  final ParentSettings settings;

  @override
  Future<ParentSettings> fetchSettings({required String profileId}) async {
    return settings;
  }

  @override
  Future<ParentSettings> updateSettings({
    required String profileId,
    StoryTextScale? storyTextScale,
    bool? narrationEnabled,
  }) {
    throw UnimplementedError();
  }
}

final class _FakeNarrationService implements StoryNarrationService {
  _FakeNarrationService({this.autoStart = true});

  final bool autoStart;
  VoidCallback? _onStarted;
  VoidCallback? _onCompleted;
  VoidCallback? _onPaused;
  VoidCallback? _onCancelled;
  NarrationErrorCallback? _onError;
  NarrationProgressCallback? _onProgress;
  String? spokenText;
  StoryNarration? spokenNarration;
  int speakCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;

  @override
  void setCallbacks({
    VoidCallback? onStarted,
    VoidCallback? onCompleted,
    VoidCallback? onPaused,
    VoidCallback? onCancelled,
    NarrationErrorCallback? onError,
    NarrationProgressCallback? onProgress,
  }) {
    _onStarted = onStarted;
    _onCompleted = onCompleted;
    _onPaused = onPaused;
    _onCancelled = onCancelled;
    _onError = onError;
    _onProgress = onProgress;
  }

  void emitStarted() => _onStarted?.call();

  void emitProgress(String text, int start, int end, String word) {
    _onProgress?.call(text, start, end, word);
  }

  void emitCompleted() => _onCompleted?.call();

  void emitCancelled() => _onCancelled?.call();

  void emitError([String message = 'Narration stopped.']) =>
      _onError?.call(message);

  void emitCompleteProgress() {
    final text = spokenText;
    if (text == null) return;
    for (final match in RegExp(r'[A-Za-z0-9]+').allMatches(text)) {
      emitProgress(text, match.start, match.end, match.group(0)!);
    }
  }

  @override
  Future<void> speak({
    required String text,
    required StoryNarration narration,
  }) async {
    speakCalls++;
    spokenText = text;
    spokenNarration = narration;
    if (autoStart) _onStarted?.call();
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _onPaused?.call();
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _onCancelled?.call();
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

typedef _ProgressCall = ({
  String profileId,
  String storyId,
  StoryActivityType eventType,
  String operationId,
});

final class _FakeProgressRepository implements ProgressRepository {
  _FakeProgressRepository({Map<StoryActivityType, int>? failuresRemaining})
    : failuresRemaining = {...?failuresRemaining};

  final Map<StoryActivityType, int> failuresRemaining;
  final List<_ProgressCall> calls = [];

  @override
  Future<StoryActivityEvent> recordStoryActivity({
    required String profileId,
    required String storyId,
    required StoryActivityType eventType,
    required String operationId,
  }) async {
    calls.add((
      profileId: profileId,
      storyId: storyId,
      eventType: eventType,
      operationId: operationId,
    ));
    final failures = failuresRemaining[eventType] ?? 0;
    if (failures > 0) {
      failuresRemaining[eventType] = failures - 1;
      throw StateError('offline');
    }
    return StoryActivityEvent(
      eventId: 'event-${calls.length}',
      operationId: operationId,
      profileId: profileId,
      type: eventType,
      storyId: storyId,
      recordedAt: DateTime.utc(2026, 7, 17, 12),
      isIdempotentReplay: false,
    );
  }
}

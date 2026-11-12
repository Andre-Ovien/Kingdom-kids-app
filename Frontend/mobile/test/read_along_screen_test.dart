import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/app_route_observer.dart';
import 'package:mobile/features/auth/data/auth_repository.dart';
import 'package:mobile/features/milestones/data/level_milestone_store.dart';
import 'package:mobile/features/milestones/domain/level_milestone.dart';
import 'package:mobile/features/profile/domain/progress_summary.dart';
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
import 'package:mobile/features/stories/data/story_reading_bookmark_store.dart';
import 'package:mobile/features/stories/domain/story_reading_bookmark.dart';
import 'package:mobile/features/stories/domain/story_detail.dart';
import 'package:mobile/features/stories/presentation/read_along_screen.dart';

void main() {
  group('saved story reading places', () {
    testWidgets(
      'restart restores cursor without autoplay and finishes heard remainder',
      (tester) async {
        final store = MemoryStoryReadingBookmarkStore();
        final auth = await _selectedKidRepository();
        final story = _story(
          id: 'resume-story',
          body: 'David trusted God. He stepped forward with brave faith.',
        );
        final first = _FakeNarrationService();
        final progress = _FakeProgressRepository();
        await tester.pumpWidget(
          _testApp(
            story: story,
            service: first,
            authRepository: auth,
            settings: _FakeSettingsRepository(_settings()),
            bookmarkStore: store,
            progressRepository: progress,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('read-along-play-pause')));
        await tester.pump();
        final split = story.body.indexOf('He');
        for (final word in RegExp(
          r'[A-Za-z0-9]+',
        ).allMatches(story.body.substring(0, split))) {
          first.emitProgress(story.body, word.start, word.end, word.group(0)!);
        }
        first.emitProgress(story.body, split, split + 2, 'He');
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        final saved = await store.readAll(
          parentId: 'parent-1',
          profileId: 'kid-1',
        );
        expect(saved.single.textOffset, split);
        expect(saved.single.heardRanges.first.start, 0);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        final second = _FakeNarrationService();
        await tester.pumpWidget(
          _testApp(
            story: story,
            service: second,
            authRepository: auth,
            settings: _FakeSettingsRepository(_settings()),
            bookmarkStore: store,
            resumeReading: true,
            disableAnimations: true,
            progressRepository: progress,
          ),
        );
        await tester.pumpAndSettle();
        expect(second.speakCalls, 0);
        expect(
          find.text('Your place is saved. Tap play when you’re ready.'),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('read-along-play-pause')));
        await tester.pump();
        expect(second.startOffset, split);
        expect(second.spokenNarration?.characterName, 'Kai');
        second.emitCompleteProgress();
        second.emitCompleted();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('story-completion-screen')),
          findsOneWidget,
        );
        expect(
          await store.readAll(parentId: 'parent-1', profileId: 'kid-1'),
          isEmpty,
        );
        expect(
          progress.calls.where(
            (call) => call.eventType == StoryActivityType.storyCompleted,
          ),
          hasLength(1),
        );
      },
    );

    testWidgets('a saved seek never invents heard coverage or completion XP', (
      tester,
    ) async {
      final store = MemoryStoryReadingBookmarkStore();
      final story = _story(
        id: 'skipped-story',
        body: 'David trusted God. He stepped forward with brave faith.',
      );
      final split = story.body.indexOf('He');
      await store.save(
        parentId: 'parent-1',
        profileId: 'kid-1',
        bookmark: StoryReadingBookmark.forStory(
          story: story,
          textOffset: split,
          updatedAt: DateTime.utc(2026, 11, 8),
        ),
      );
      final service = _FakeNarrationService();
      final progress = _FakeProgressRepository();
      await tester.pumpWidget(
        _testApp(
          story: story,
          service: service,
          authRepository: await _selectedKidRepository(),
          settings: _FakeSettingsRepository(_settings()),
          bookmarkStore: store,
          resumeReading: true,
          progressRepository: progress,
        ),
      );
      await tester.pumpAndSettle();
      await _completeNarration(tester, service);
      expect(find.byKey(const Key('story-completion-screen')), findsNothing);
      expect(
        progress.calls.where(
          (call) => call.eventType == StoryActivityType.storyCompleted,
        ),
        isEmpty,
      );
      expect(
        find.text(
          'A few parts are still waiting. Tap play to hear them from the beginning.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'changed story body resets a saved cursor and heard coverage safely',
      (tester) async {
        final store = MemoryStoryReadingBookmarkStore();
        final oldStory = _story(id: 'edited-story');
        await store.save(
          parentId: 'parent-1',
          profileId: 'kid-1',
          bookmark: StoryReadingBookmark.forStory(
            story: oldStory,
            textOffset: 20,
            updatedAt: DateTime.utc(2026, 11, 8),
            heardRanges: [StoryHeardRange(0, oldStory.body.length)],
          ),
        );
        final service = _FakeNarrationService();
        final story = _story(
          id: 'edited-story',
          body: 'A new edition begins. God is kind.',
        );
        await tester.pumpWidget(
          _testApp(
            story: story,
            service: service,
            authRepository: await _selectedKidRepository(),
            settings: _FakeSettingsRepository(_settings()),
            bookmarkStore: store,
            resumeReading: true,
            progressRepository: _FakeProgressRepository(),
          ),
        );
        await tester.pumpAndSettle();
        expect(service.speakCalls, 0);
        await tester.tap(find.byKey(const Key('read-along-play-pause')));
        await tester.pump();
        expect(service.startOffset, 0);
      },
    );

    testWidgets(
      'removed cached stories cannot read, play or create bookmarks',
      (tester) async {
        final store = MemoryStoryReadingBookmarkStore();
        final source = _story(id: 'removed-story');
        final story = StoryDetail(
          id: source.id,
          slug: 'lost-sheep',
          title: 'The Lost Sheep',
          author: source.author,
          category: source.category,
          body: 'This cached body must stay hidden.',
          narrations: source.narrations,
        );
        final service = _FakeNarrationService();
        await tester.pumpWidget(
          _testApp(
            story: story,
            service: service,
            authRepository: await _selectedKidRepository(),
            settings: _FakeSettingsRepository(_settings()),
            bookmarkStore: store,
            resumeReading: true,
            progressRepository: _FakeProgressRepository(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Story unavailable'), findsOneWidget);
        expect(find.textContaining('cached body'), findsNothing);
        expect(find.byKey(const Key('read-along-play-pause')), findsNothing);
        expect(service.speakCalls, 0);
        expect(
          await store.readAll(parentId: 'parent-1', profileId: 'kid-1'),
          isEmpty,
        );
      },
    );

    testWidgets('manual reading scroll stores a paragraph without heard credit', (
      tester,
    ) async {
      final store = MemoryStoryReadingBookmarkStore();
      final story = _story(
        id: 'manual-story',
        body: List.generate(
          12,
          (index) =>
              'Paragraph $index. David trusted God and stepped forward with brave faith.',
        ).join('\n\n'),
      );
      final service = _FakeNarrationService();
      await tester.pumpWidget(
        _testApp(
          story: story,
          service: service,
          authRepository: await _selectedKidRepository(),
          settings: _FakeSettingsRepository(_settings()),
          bookmarkStore: store,
          disableAnimations: true,
          progressRepository: _FakeProgressRepository(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('read-along-text-scroll')),
        const Offset(0, -500),
      );
      await tester.pumpAndSettle();
      final saved = await store.readAll(
        parentId: 'parent-1',
        profileId: 'kid-1',
      );
      expect(saved, hasLength(1));
      expect(saved.single.textOffset, greaterThan(0));
      expect(saved.single.heardRanges, isEmpty);
      expect(service.speakCalls, 0);
    });

    testWidgets(
      'continuous word updates are throttled and pause saves immediately',
      (tester) async {
        final store = _CountingBookmarkStore();
        final story = _story(id: 'throttle-story');
        final service = _FakeNarrationService();
        await tester.pumpWidget(
          _testApp(
            story: story,
            service: service,
            authRepository: await _selectedKidRepository(),
            settings: _FakeSettingsRepository(_settings()),
            bookmarkStore: store,
            progressRepository: _FakeProgressRepository(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('read-along-play-pause')));
        await tester.pump();
        final words = RegExp(r'[A-Za-z0-9]+').allMatches(story.body).toList();
        for (var index = 0; index < words.length; index++) {
          final word = words[index];
          service.emitProgress(
            story.body,
            word.start,
            word.end,
            word.group(0)!,
          );
          await tester.pump(const Duration(milliseconds: 400));
        }
        expect(store.saves, 0);
        await tester.pump(const Duration(seconds: 2));
        expect(store.saves, 1);
        service.emitProgress(story.body, 0, 5, 'David');
        await tester.pump();
        await tester.tap(find.byKey(const Key('read-along-play-pause')));
        await tester.pumpAndSettle();
        expect(store.saves, 2);
      },
    );
  });

  group('story XP and overall level milestones', () {
    testWidgets('confirmed story XP can advance the overall level', (
      tester,
    ) async {
      final service = _FakeNarrationService();
      final store = MemoryLevelMilestoneStore();
      final progress = _FakeProgressRepository(
        completionXp: 100,
        levelMilestone: _storyLevelEight,
      );
      await tester.pumpWidget(
        _testApp(
          story: _story(id: 'story-1'),
          service: service,
          authRepository: await _selectedKidRepository(),
          settings: _FakeSettingsRepository(_settings()),
          progressRepository: progress,
          milestoneStore: store,
          disableAnimations: true,
        ),
      );
      await tester.pumpAndSettle();
      await _completeNarration(tester, service);
      expect(find.byKey(const Key('level-milestone-screen')), findsOneWidget);
      expect(await store.highestPresentedLevel('kid-1'), 8);
      await tester.tap(find.byKey(const Key('level-milestone-continue')));
      await tester.pumpAndSettle();
      expect(find.text('+100 XP earned'), findsOneWidget);
      expect(find.byKey(const Key('story-completion-screen')), findsOneWidget);
      service.emitCompleted();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('level-milestone-screen')), findsNothing);
      expect(
        progress.calls.where(
          (call) => call.eventType == StoryActivityType.storyCompleted,
        ),
        hasLength(1),
      );
    });

    testWidgets('a replay with zero XP keeps the normal completion', (
      tester,
    ) async {
      final service = _FakeNarrationService();
      await tester.pumpWidget(
        _testApp(
          story: _story(id: 'story-1'),
          service: service,
          authRepository: await _selectedKidRepository(),
          settings: _FakeSettingsRepository(_settings()),
          progressRepository: _FakeProgressRepository(),
          milestoneStore: MemoryLevelMilestoneStore(),
          disableAnimations: true,
        ),
      );
      await tester.pumpAndSettle();
      await _completeNarration(tester, service);
      expect(find.byKey(const Key('story-completion-screen')), findsOneWidget);
      expect(find.byKey(const Key('story-completion-xp')), findsNothing);
      expect(find.byKey(const Key('level-milestone-screen')), findsNothing);
    });

    testWidgets(
      'Continue retries a lost receipt with the same operation and awaits its milestone',
      (tester) async {
        final service = _FakeNarrationService();
        final progress = _FakeProgressRepository(
          failuresRemaining: {StoryActivityType.storyCompleted: 1},
          completionXp: 100,
          levelMilestone: _storyLevelEight,
        );
        await tester.pumpWidget(
          _navigationTestApp(
            story: _story(id: 'story-1'),
            service: service,
            authRepository: await _selectedKidRepository(),
            settings: _FakeSettingsRepository(_settings()),
            progressRepository: progress,
            milestoneStore: MemoryLevelMilestoneStore(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('open-read-along')));
        await tester.pumpAndSettle();
        await _completeNarration(tester, service);
        expect(find.byKey(const Key('story-completion-xp')), findsNothing);
        await tester.tap(find.byKey(const Key('story-completion-continue')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('level-milestone-screen')), findsOneWidget);
        final saves = progress.calls
            .where((call) => call.eventType == StoryActivityType.storyCompleted)
            .toList();
        expect(saves, hasLength(2));
        expect(saves.first.operationId, saves.last.operationId);
        await tester.tap(find.byKey(const Key('level-milestone-continue')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('completion-prior-route')), findsOneWidget);
        expect(find.byKey(const Key('story-completion-screen')), findsNothing);
      },
    );

    testWidgets(
      'Continue waits for one in-flight completion and prevents double taps',
      (tester) async {
        final service = _FakeNarrationService();
        final barrier = Completer<void>();
        final progress = _FakeProgressRepository(
          completionXp: 100,
          levelMilestone: _storyLevelEight,
          completionBarrier: barrier.future,
        );
        await tester.pumpWidget(
          _navigationTestApp(
            story: _story(id: 'story-1'),
            service: service,
            authRepository: await _selectedKidRepository(),
            settings: _FakeSettingsRepository(_settings()),
            progressRepository: progress,
            milestoneStore: MemoryLevelMilestoneStore(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('open-read-along')));
        await tester.pumpAndSettle();
        await _completeNarration(tester, service);
        expect(
          find.byKey(const Key('story-completion-screen')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('story-completion-xp')), findsNothing);
        await tester.tap(find.byKey(const Key('story-completion-continue')));
        await tester.pump();
        expect(find.text('Saving your progress…'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('story-completion-continue')),
              )
              .onPressed,
          isNull,
        );
        expect(
          progress.calls.where(
            (call) => call.eventType == StoryActivityType.storyCompleted,
          ),
          hasLength(1),
        );
        barrier.complete();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('level-milestone-screen')), findsOneWidget);
        await tester.tap(find.byKey(const Key('level-milestone-continue')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('completion-prior-route')), findsOneWidget);
      },
    );

    testWidgets(
      'a selected-child change cannot show another child’s story XP or milestone',
      (tester) async {
        final service = _FakeNarrationService();
        final barrier = Completer<void>();
        final store = MemoryLevelMilestoneStore();
        final auth = _MutableReaderAuth(
          const KidProfile(
            id: 'kid-1',
            parentId: 'parent-1',
            displayName: 'Ada',
            avatarKey: 'lion',
          ),
        );
        await tester.pumpWidget(
          _testApp(
            story: _story(id: 'story-1'),
            service: service,
            authRepository: auth,
            settings: _FakeSettingsRepository(_settings()),
            progressRepository: _FakeProgressRepository(
              completionXp: 100,
              levelMilestone: _storyLevelEight,
              completionBarrier: barrier.future,
            ),
            milestoneStore: store,
            disableAnimations: true,
          ),
        );
        await tester.pumpAndSettle();
        await _completeNarration(tester, service);
        auth.profile = const KidProfile(
          id: 'kid-2',
          parentId: 'parent-1',
          displayName: 'Nia',
          avatarKey: 'dove',
        );
        barrier.complete();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('level-milestone-screen')), findsNothing);
        expect(find.byKey(const Key('story-completion-xp')), findsNothing);
        expect(await store.highestPresentedLevel('kid-1'), 0);
      },
    );

    testWidgets(
      'a covered story receipt celebrates after the covering route is closed',
      (tester) async {
        final service = _FakeNarrationService();
        final barrier = Completer<void>();
        final store = MemoryLevelMilestoneStore();
        await tester.pumpWidget(
          _navigationTestApp(
            story: _story(id: 'story-1'),
            service: service,
            authRepository: await _selectedKidRepository(),
            settings: _FakeSettingsRepository(_settings()),
            progressRepository: _FakeProgressRepository(
              completionXp: 100,
              levelMilestone: _storyLevelEight,
              completionBarrier: barrier.future,
            ),
            milestoneStore: store,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('open-read-along')));
        await tester.pumpAndSettle();
        await _completeNarration(tester, service);
        final navigator = Navigator.of(
          tester.element(find.byKey(const Key('story-completion-screen'))),
        );
        unawaited(
          navigator.push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('Another page')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        barrier.complete();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('level-milestone-screen')), findsNothing);
        expect(await store.highestPresentedLevel('kid-1'), 0);
        navigator.pop();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('level-milestone-screen')), findsOneWidget);
        expect(await store.highestPresentedLevel('kid-1'), 8);
      },
    );

    testWidgets('a background story receipt waits for resume', (tester) async {
      final service = _FakeNarrationService();
      final barrier = Completer<void>();
      final store = MemoryLevelMilestoneStore();
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      await tester.pumpWidget(
        _testApp(
          story: _story(id: 'story-1'),
          service: service,
          authRepository: await _selectedKidRepository(),
          settings: _FakeSettingsRepository(_settings()),
          progressRepository: _FakeProgressRepository(
            completionXp: 100,
            levelMilestone: _storyLevelEight,
            completionBarrier: barrier.future,
          ),
          milestoneStore: store,
          disableAnimations: true,
        ),
      );
      await tester.pumpAndSettle();
      await _completeNarration(tester, service);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      barrier.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('level-milestone-screen')), findsNothing);
      expect(await store.highestPresentedLevel('kid-1'), 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('level-milestone-screen')), findsOneWidget);
      expect(await store.highestPresentedLevel('kid-1'), 8);
    });
  });

  testWidgets(
    'hosted clock follows native position without passages and freezes across pause and stale callbacks',
    (tester) async {
      final service = _FakeNarrationService();
      final story = _hostedStory();
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
      final play = find.byKey(const Key('read-along-play-pause'));
      await tester.tap(play);
      await tester.pumpAndSettle();
      const duration = Duration(milliseconds: 12345);
      service.emitPosition(const Duration(milliseconds: 1234), duration);
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('read-along-elapsed-time')))
            .data,
        '0:01',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('read-along-total-time')))
            .data,
        '0:12',
      );
      expect(_displayedProgress(tester), closeTo(1234 / 12345, .000001));
      service.emitPosition(const Duration(milliseconds: 2710), duration);
      await tester.pump();
      expect(_displayedProgress(tester), closeTo(2710 / 12345, .000001));
      await tester.tap(play);
      await tester.pumpAndSettle();
      service.emitPosition(const Duration(seconds: 9), duration);
      service.emitPositionForSpeak(0, const Duration(seconds: 8), duration);
      await tester.pump(const Duration(seconds: 2));
      expect(_displayedProgress(tester), closeTo(2710 / 12345, .000001));
      expect(
        tester
            .widget<Text>(find.byKey(const Key('read-along-elapsed-time')))
            .data,
        '0:02',
      );
      await tester.tap(play);
      await tester.pumpAndSettle();
      expect(service.resume, isTrue);
      service.emitPosition(const Duration(milliseconds: 2710), duration);
      service.emitPositionForSpeak(0, const Duration(seconds: 10), duration);
      await tester.pump();
      expect(_displayedProgress(tester), closeTo(2710 / 12345, .000001));
      await tester.tap(find.byKey(const Key('read-along-next')));
      await tester.pumpAndSettle();
      expect(service.startOffset, 19);
      service.emitPosition(const Duration(seconds: 5), duration);
      await tester.pump();
      expect(_displayedProgress(tester), closeTo(5000 / 12345, .000001));
      expect(
        tester
            .widget<Text>(find.byKey(const Key('read-along-elapsed-time')))
            .data,
        '0:05',
      );
      service.emitCompleted();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('story-completion-screen')), findsNothing);
    },
  );

  testWidgets(
    'hosted word highlights follow measured cues, clear in silence and never highlight a whole passage',
    (tester) async {
      final service = _FakeNarrationService();
      final story = _hostedStory();
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
      await tester.tap(find.byKey(const Key('read-along-play-pause')));
      await tester.pumpAndSettle();
      service.emitPassage(story.body, 0, 18);
      await tester.pump();
      expect(_highlightedText(tester), isEmpty);
      service.emitWord(_hostedWords[0]);
      service.emitPosition(
        const Duration(milliseconds: 1300),
        const Duration(seconds: 10),
      );
      await tester.pump();
      expect(_highlightedText(tester), 'David');
      service.emitPosition(
        const Duration(milliseconds: 1600),
        const Duration(seconds: 10),
      );
      await tester.pump();
      expect(_highlightedText(tester), 'David');
      service.emitWord(null);
      await tester.pump();
      expect(_highlightedText(tester), isEmpty);
      service.emitWord(_hostedWords[1]);
      await tester.pump();
      expect(_highlightedText(tester), 'trusted');
      service.emitWord(_hostedWords[2]);
      await tester.pump();
      expect(_highlightedText(tester), 'God.');
      service.emitProgress(story.body, 0, 18, '');
      await tester.pump();
      expect(_highlightedText(tester), 'God.');
    },
  );

  testWidgets(
    'ready hosted narration uses the selected buddy and measured passages',
    (tester) async {
      final service = _FakeNarrationService();
      final progress = _FakeProgressRepository();
      final story = _hostedStory();
      await tester.pumpWidget(
        _testApp(
          story: story,
          service: service,
          authRepository: await _selectedKidRepository(avatarKey: 'dove'),
          settings: _FakeSettingsRepository(_settings()),
          progressRepository: progress,
          disableAnimations: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('read-along-play-pause')));
      await tester.pumpAndSettle();
      expect(service.spokenNarration?.characterName, 'Nia');
      expect(service.fullText, story.body);
      expect(service.startOffset, 0);
      expect(find.text('Nia is reading.'), findsOneWidget);
      expect(find.text('0:10'), findsOneWidget);
      service.emitPassage(story.body, 0, 18);
      await tester.pump();
      expect(_highlightedText(tester), isEmpty);
      service.emitWord(_hostedWords.first);
      await tester.pump();
      expect(_highlightedText(tester), 'David');
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const Key('read-along-progress')),
            )
            .value,
        0,
      );
      service.emitProgress(story.body, 0, 18, '');
      service.emitPassage(story.body, 19, story.body.length);
      service.emitProgress(story.body, 19, story.body.length, '');
      service.emitCompleted();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('story-completion-screen')), findsOneWidget);
      expect(
        progress.calls.where(
          (call) => call.eventType == StoryActivityType.storyCompleted,
        ),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'hosted pause resumes the player without stopping or restarting the track',
    (tester) async {
      final service = _FakeNarrationService();
      final story = _hostedStory();
      await tester.pumpWidget(
        _testApp(
          story: story,
          service: service,
          authRepository: await _selectedKidRepository(),
          settings: _FakeSettingsRepository(_settings()),
        ),
      );
      await tester.pumpAndSettle();
      final play = find.byKey(const Key('read-along-play-pause'));
      await tester.tap(play);
      await tester.pumpAndSettle();
      service.emitPassage(story.body, 19, story.body.length);
      await tester.pump();
      await tester.tap(play);
      await tester.pumpAndSettle();
      expect(service.pauseCalls, 1);
      await tester.tap(play);
      await tester.pumpAndSettle();
      expect(service.stopCalls, 0);
      expect(service.speakCalls, 2);
      expect(service.resume, isTrue);
      expect(service.startOffset, 19);
      expect(service.fullText, story.body);
      await tester.tap(find.byKey(const Key('read-along-replay')));
      await tester.pumpAndSettle();
      expect(service.stopCalls, 1);
      expect(service.startOffset, 0);
      expect(service.resume, isFalse);
    },
  );

  testWidgets('hosted highlights and skipped passages cannot earn completion', (
    tester,
  ) async {
    final service = _FakeNarrationService();
    final progress = _FakeProgressRepository();
    final story = _hostedStory();
    await tester.pumpWidget(
      _testApp(
        story: story,
        service: service,
        authRepository: await _selectedKidRepository(),
        settings: _FakeSettingsRepository(_settings()),
        progressRepository: progress,
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pumpAndSettle();
    service.emitPassage(story.body, 0, 18);
    await tester.pump();
    await tester.tap(find.byKey(const Key('read-along-next')));
    await tester.pumpAndSettle();
    expect(service.startOffset, 19);
    expect(service.spokenText, story.body.substring(19));
    service.emitPassage(story.body, 19, story.body.length);
    service.emitProgress(story.body, 19, story.body.length, '');
    service.emitCompleted();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('story-completion-screen')), findsNothing);
    expect(
      progress.calls.where(
        (call) => call.eventType == StoryActivityType.storyCompleted,
      ),
      isEmpty,
    );
    expect(
      find.text(
        'A few parts are still waiting. Tap play to hear them from the beginning.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'uncued hosted playback disables passage guesses and shows retry errors',
    (tester) async {
      final service = _FakeNarrationService();
      final story = _hostedStory(withCues: false);
      await tester.pumpWidget(
        _testApp(
          story: story,
          service: service,
          authRepository: await _selectedKidRepository(),
          settings: _FakeSettingsRepository(_settings()),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        _transportIconButton(
          tester,
          const Key('read-along-previous'),
        ).onPressed,
        isNull,
      );
      expect(
        _transportIconButton(tester, const Key('read-along-next')).onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('read-along-play-pause')));
      await tester.pumpAndSettle();
      service.emitError(
        'This character’s story audio could not play. Check your connection and try again.',
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'This character’s story audio could not play. Check your connection and try again.',
        ),
        findsOneWidget,
      );
      expect(find.text("Kai's voice is still warming up."), findsNothing);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('read-along-play-pause')))
            .onPressed,
        isNotNull,
      );
    },
  );

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
    expect(find.text('Kai is getting ready…'), findsOneWidget);
    expect(find.text('Kai is reading.'), findsNothing);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('read-along-play-pause')))
          .tooltip,
      'Starting story',
    );
    service.emitProgress(_story().body, 0, 'David'.length, 'David');
    await tester.pump();
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('read-along-progress')),
          )
          .value,
      0,
    );

    service.emitStarted();
    await tester.pump();
    expect(progress.calls, hasLength(1));
    expect(progress.calls.single.eventType, StoryActivityType.storyStarted);
    expect(find.text('Kai is reading.'), findsOneWidget);
  });

  testWidgets('a voice that never starts returns to a retryable state', (
    tester,
  ) async {
    final service = _FakeNarrationService(autoStart: false);

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
    expect(find.text('Kai is getting ready…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 8));
    await tester.pump();

    expect(
      find.text('This voice took too long to start. Tap play to try again.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('read-along-play-pause')))
          .tooltip,
      'Play story',
    );
    expect(service.stopCalls, 1);
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

  testWidgets(
    'late callbacks from a replaced utterance cannot change the new session',
    (tester) async {
      final service = _FakeNarrationService();
      final story = _story();

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

      await tester.tap(find.byKey(const Key('read-along-play-pause')));
      await tester.pump();
      expect(service.speakSessions, hasLength(1));

      await tester.tap(find.byKey(const Key('read-along-replay')));
      await tester.pumpAndSettle();
      expect(service.speakSessions, hasLength(2));
      expect(find.text('Kai is reading.'), findsOneWidget);

      final currentWordEnd = 'David'.length;
      service.emitProgressForSpeak(1, story.body, 0, currentWordEnd, 'David');
      await tester.pump();
      final progressBeforeStaleCallbacks = tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('read-along-progress')),
          )
          .value;

      final staleWordStart = story.body.lastIndexOf('faith');
      service.emitProgressForSpeak(
        0,
        story.body,
        staleWordStart,
        staleWordStart + 'faith'.length,
        'faith',
      );
      service.emitCancelledForSpeak(0);
      service.emitErrorForSpeak(0, 'Old narration failed.');
      service.emitCompletedForSpeak(0);
      service.emitStartedForSpeak(0);
      await tester.pump();

      expect(find.text('Kai is reading.'), findsOneWidget);
      expect(find.text('Old narration failed.'), findsNothing);
      expect(find.byKey(const Key('story-completion-screen')), findsNothing);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const Key('read-along-progress')),
            )
            .value,
        progressBeforeStaleCallbacks,
      );

      service.emitCompleteProgressForSpeak(1);
      service.emitCompletedForSpeak(1);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('story-completion-screen')), findsOneWidget);
    },
  );

  testWidgets('late callbacks after stop leave narration safely stopped', (
    tester,
  ) async {
    final service = _FakeNarrationService();
    final story = _story();

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

    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('read-along-stop')));
    await tester.pumpAndSettle();

    service.emitCompleteProgressForSpeak(0);
    service.emitCompletedForSpeak(0);
    service.emitCancelledForSpeak(0);
    service.emitErrorForSpeak(0, 'Old narration failed.');
    service.emitStartedForSpeak(0);
    await tester.pump();

    expect(find.text('Tap play to begin.'), findsOneWidget);
    expect(find.text('Old narration failed.'), findsNothing);
    expect(find.byKey(const Key('story-completion-screen')), findsNothing);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('read-along-progress')),
          )
          .value,
      0,
    );
  });

  testWidgets(
    'backgrounding stops narration and never resumes it automatically',
    (tester) async {
      final service = _FakeNarrationService();

      await tester.pumpWidget(
        _testApp(
          story: _story(),
          service: service,
          authRepository: await _selectedKidRepository(),
          settings: _FakeSettingsRepository(_settings()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('read-along-play-pause')));
      await tester.pump();
      expect(find.text('Kai is reading.'), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();

      expect(service.stopCalls, 1);
      expect(
        find.text(
          'Reading paused when the app went into the background. Tap play when you’re ready.',
        ),
        findsOneWidget,
      );
      expect(service.speakCalls, 1);
      service.emitStartedForSpeak(0);
      await tester.pump();
      expect(find.text('Kai is reading.'), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(service.speakCalls, 1);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('read-along-play-pause')))
            .tooltip,
        'Play story',
      );

      await tester.tap(find.byKey(const Key('read-along-play-pause')));
      await tester.pump();
      expect(service.speakCalls, 2);
      expect(find.text('Kai is reading.'), findsOneWidget);
    },
  );

  testWidgets('covering the reader stops audio and ignores stale completion', (
    tester,
  ) async {
    final service = _FakeNarrationService();
    final progress = _FakeProgressRepository();
    await tester.pumpWidget(
      _navigationTestApp(
        story: _story(id: 'story-1'),
        service: service,
        authRepository: await _selectedKidRepository(),
        settings: _FakeSettingsRepository(_settings()),
        progressRepository: progress,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-read-along')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pump();
    service.emitProgress(_story().body, 0, 5, 'David');
    final context = tester.element(find.byType(ReadAlongScreen));
    final navigator = Navigator.of(context);
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Covering page')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(service.stopCalls, 1);
    service.emitCompleteProgressForSpeak(0);
    service.emitCompletedForSpeak(0);
    await tester.pump();
    expect(
      progress.calls.where(
        (call) => call.eventType == StoryActivityType.storyCompleted,
      ),
      isEmpty,
    );
    navigator.pop();
    await tester.pumpAndSettle();
    expect(service.speakCalls, 1);
    expect(find.byKey(const Key('story-completion-screen')), findsNothing);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('read-along-play-pause')))
          .tooltip,
      'Play story',
    );
    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pump();
    expect(service.speakCalls, 2);
    expect(service.startOffset, 0);
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

  testWidgets(
    'centers the first, middle and last paragraphs using laid-out text bounds',
    (tester) async {
      _setReadAlongViewport(tester, const Size(600, 1100));
      final service = _FakeNarrationService();
      const paragraphs = [
        'A brave child listened.',
        'David took a steady breath. Then he walked forward with brave faith.',
        'Together they thanked God for the courage to keep going.',
      ];
      final story = _story(body: paragraphs.join('\n\n'));
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
      await tester.tap(find.byKey(const Key('read-along-play-pause')));
      await tester.pumpAndSettle();

      for (final paragraph in paragraphs) {
        final start = story.body.indexOf(paragraph);
        final word = paragraph.split(' ').first;
        service.emitProgress(story.body, start, start + word.length, word);
        await tester.pumpAndSettle();

        _expectTextRangeCentered(tester, start, start + paragraph.length);
        expect(_highlightedText(tester), word);
      }

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'centers exact hosted paragraph segments across sentence punctuation',
    (tester) async {
      _setReadAlongViewport(tester, const Size(600, 1100));
      final service = _FakeNarrationService();
      const paragraphs = [
        'David listened.',
        'He took a breath. Then he moved forward with faith.',
        'His friends smiled and gave thanks together.',
      ];
      final story = _hostedParagraphStory(paragraphs, separator: ' ');
      final segments = story.narrations.first.segments;
      await tester.pumpWidget(
        _testApp(
          story: story,
          service: service,
          authRepository: await _selectedKidRepository(),
          settings: _FakeSettingsRepository(_settings()),
          progressRepository: _FakeProgressRepository(),
          disableAnimations: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('read-along-play-pause')));
      await tester.pumpAndSettle();

      for (final segment in segments) {
        service.emitPassage(story.body, segment.startOffset, segment.endOffset);
        await tester.pumpAndSettle();

        _expectTextRangeCentered(
          tester,
          segment.startOffset,
          segment.endOffset,
        );
        expect(_highlightedText(tester), isEmpty);
        final text = tester.widget<Text>(
          find.byKey(const Key('read-along-story-text')),
        );
        final readableText = (text.textSpan! as TextSpan).children!
            .cast<TextSpan>()
            .where(
              (span) =>
                  span.style?.color ==
                  const Color(0xFF2B2523).withValues(alpha: .92),
            )
            .map((span) => span.text ?? '')
            .join();
        expect(readableText, segment.text);
      }
    },
  );

  testWidgets(
    'word updates within one paragraph preserve a manually chosen scroll position',
    (tester) async {
      _setReadAlongViewport(tester, const Size(600, 1100));
      final service = _FakeNarrationService();
      const middle =
          'David took a steady breath. Then he walked forward with brave faith.';
      final story = _story(
        body: 'His friends waited.\n\n$middle\n\nThey gave thanks together.',
      );
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
      await tester.tap(find.byKey(const Key('read-along-play-pause')));
      await tester.pumpAndSettle();
      final middleStart = story.body.indexOf(middle);
      service.emitProgress(
        story.body,
        middleStart,
        middleStart + 'David'.length,
        'David',
      );
      await tester.pumpAndSettle();
      _expectTextRangeCentered(
        tester,
        middleStart,
        middleStart + middle.length,
      );

      final controller = _readAlongTextController(tester);
      final centeredOffset = controller.offset;
      controller.jumpTo(centeredOffset + 40);
      await tester.pumpAndSettle();
      final chosenOffset = controller.offset;
      expect(chosenOffset, greaterThan(centeredOffset));

      final nextSentenceStart = story.body.indexOf('Then');
      service.emitProgress(
        story.body,
        nextSentenceStart,
        nextSentenceStart + 'Then'.length,
        'Then',
      );
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(chosenOffset, 0.01));
      expect(_highlightedText(tester), 'Then');

      final laterWordStart = story.body.indexOf('faith');
      service.emitProgress(
        story.body,
        laterWordStart,
        laterWordStart + 'faith'.length,
        'faith',
      );
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(chosenOffset, 0.01));
      expect(_highlightedText(tester), 'faith');
    },
  );

  testWidgets(
    'pause and resume retain paragraph focus and next centers the following paragraph',
    (tester) async {
      _setReadAlongViewport(tester, const Size(600, 1100));
      final service = _FakeNarrationService();
      final story = _hostedParagraphStory(const [
        'His friends waited.',
        'David listened. Then he walked forward with brave faith.',
        'Everyone gave thanks together.',
      ]);
      final segments = story.narrations.first.segments;
      await tester.pumpWidget(
        _testApp(
          story: story,
          service: service,
          authRepository: await _selectedKidRepository(),
          settings: _FakeSettingsRepository(_settings()),
          progressRepository: _FakeProgressRepository(),
          disableAnimations: true,
        ),
      );
      await tester.pumpAndSettle();
      final play = find.byKey(const Key('read-along-play-pause'));
      await tester.tap(play);
      await tester.pumpAndSettle();
      final middle = segments[1];
      service.emitPassage(story.body, middle.startOffset, middle.endOffset);
      service.emitWord(_wordCue(story.body, 'David'));
      await tester.pumpAndSettle();
      _expectTextRangeCentered(tester, middle.startOffset, middle.endOffset);
      final offset = _readAlongTextController(tester).offset;

      await tester.tap(play);
      await tester.pumpAndSettle();
      service.emitPassage(
        story.body,
        segments.last.startOffset,
        segments.last.endOffset,
      );
      service.emitWord(_wordCue(story.body, 'Everyone'));
      await tester.pumpAndSettle();
      expect(_readAlongTextController(tester).offset, closeTo(offset, 0.01));
      expect(_highlightedText(tester), 'David');

      await tester.tap(play);
      await tester.pumpAndSettle();
      expect(service.resume, isTrue);
      expect(service.startOffset, middle.startOffset);
      expect(service.stopCalls, 0);
      expect(_readAlongTextController(tester).offset, closeTo(offset, 0.01));
      _expectTextRangeCentered(tester, middle.startOffset, middle.endOffset);

      await tester.tap(find.byKey(const Key('read-along-next')));
      await tester.pumpAndSettle();
      expect(service.startOffset, segments.last.startOffset);
      expect(service.resume, isFalse);
      expect(service.stopCalls, 1);
      _expectTextRangeCentered(
        tester,
        segments.last.startOffset,
        segments.last.endOffset,
      );
    },
  );

  testWidgets(
    'a tall paragraph keeps active words visible above the fade with large text',
    (tester) async {
      _setReadAlongViewport(tester, const Size(320, 568));
      final service = _FakeNarrationService();
      final paragraph = List.generate(
        30,
        (index) => 'I go on with brave faith step ${index + 1}',
      ).join(' ');
      final story = _story(
        body: 'Friends waited.\n\n$paragraph.\n\nThey gave thanks.',
      );
      await tester.pumpWidget(
        _testApp(
          story: story,
          service: service,
          authRepository: await _selectedKidRepository(),
          settings: _FakeSettingsRepository(
            _settings(storyTextScale: StoryTextScale.extraLarge),
          ),
          disableAnimations: true,
          textScaler: const TextScaler.linear(1.5),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('read-along-play-pause')));
      await tester.pumpAndSettle();
      final start = story.body.indexOf(paragraph);
      service.emitProgress(story.body, start, start + 'I'.length, 'I');
      await tester.pumpAndSettle();

      final viewport = _readAlongTextViewport(tester);
      final bounds = _textRangeRect(tester, start, start + paragraph.length);
      expect(bounds.height, greaterThan(viewport.height));
      _expectWordCenteredAboveFade(tester, start, start + 'I'.length);
      final text = tester.widget<Text>(
        find.byKey(const Key('read-along-story-text')),
      );
      expect(text.textSpan!.style!.fontSize, closeTo(29 * 1.32, 0.001));
      expect(_storyRenderParagraph(tester).textScaler.scale(10), 15);

      final firstOffset = _readAlongTextController(tester).offset;
      final nextWordStart = start + 'I '.length;
      service.emitProgress(
        story.body,
        nextWordStart,
        nextWordStart + 'go'.length,
        'go',
      );
      await tester.pumpAndSettle();
      _expectWordCenteredAboveFade(
        tester,
        nextWordStart,
        nextWordStart + 'go'.length,
      );
      expect(
        _readAlongTextController(tester).offset,
        closeTo(firstOffset, 0.01),
      );

      final finalWordStart = story.body.lastIndexOf('go');
      service.emitProgress(
        story.body,
        finalWordStart,
        finalWordStart + 'go'.length,
        'go',
      );
      await tester.pumpAndSettle();
      _expectWordCenteredAboveFade(
        tester,
        finalWordStart,
        finalWordStart + 'go'.length,
      );
      expect(_readAlongTextController(tester).offset, greaterThan(firstOffset));
      final pausedOffset = _readAlongTextController(tester).offset;
      final play = find.byKey(const Key('read-along-play-pause'));
      await tester.tap(play);
      await tester.pumpAndSettle();
      await tester.tap(play);
      await tester.pumpAndSettle();
      expect(service.resume, isTrue);
      expect(
        _readAlongTextController(tester).offset,
        closeTo(pausedOffset, .01),
      );
      service.emitProgress(service.spokenText!, 0, 'go'.length, 'go');
      await tester.pumpAndSettle();
      _expectWordCenteredAboveFade(tester, finalWordStart, finalWordStart + 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'remeasures the current paragraph after viewport and text scaling changes',
    (tester) async {
      _setReadAlongViewport(tester, const Size(600, 1100));
      final service = _FakeNarrationService();
      final authRepository = await _selectedKidRepository();
      final settings = _FakeSettingsRepository(_settings());
      const paragraph = 'David listened. Then he stepped forward.';
      final story = _story(
        body: 'His friends waited.\n\n$paragraph\n\nThey gave thanks.',
      );
      await tester.pumpWidget(
        _testApp(
          story: story,
          service: service,
          authRepository: authRepository,
          settings: settings,
          disableAnimations: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('read-along-play-pause')));
      await tester.pumpAndSettle();
      final start = story.body.indexOf(paragraph);
      service.emitProgress(story.body, start, start + 'David'.length, 'David');
      await tester.pumpAndSettle();
      _expectTextRangeCentered(tester, start, start + paragraph.length);

      tester.view.physicalSize = const Size(430, 932);
      await tester.pumpAndSettle();
      _expectTextRangeCentered(tester, start, start + paragraph.length);
      final beforeScaling = _textRangeRect(
        tester,
        start,
        start + paragraph.length,
      );

      await tester.pumpWidget(
        _testApp(
          story: story,
          service: service,
          authRepository: authRepository,
          settings: settings,
          disableAnimations: true,
          textScaler: const TextScaler.linear(1.25),
        ),
      );
      await tester.pumpAndSettle();
      _expectTextRangeCentered(tester, start, start + paragraph.length);
      final afterScaling = _textRangeRect(
        tester,
        start,
        start + paragraph.length,
      );
      expect(afterScaling.height, greaterThan(beforeScaling.height));
      expect(_highlightedText(tester), 'David');
      expect(service.speakCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

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

    await tester.tap(find.byKey(const Key('read-along-play-pause')));
    await tester.pump();
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

void _setReadAlongViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

ScrollController _readAlongTextController(WidgetTester tester) => tester
    .widget<SingleChildScrollView>(
      find.byKey(const Key('read-along-text-scroll')),
    )
    .controller!;

Rect _readAlongTextViewport(WidgetTester tester) =>
    tester.getRect(find.byKey(const Key('read-along-text-scroll')));

RenderParagraph _storyRenderParagraph(WidgetTester tester) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byKey(const Key('read-along-story-text')),
        matching: find.byType(RichText),
      ),
    );

Rect _textRangeRect(WidgetTester tester, int start, int end) {
  final paragraph = _storyRenderParagraph(tester);
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: end),
  );
  expect(boxes, isNotEmpty);
  return boxes
      .map(
        (box) => Rect.fromPoints(
          paragraph.localToGlobal(box.toRect().topLeft),
          paragraph.localToGlobal(box.toRect().bottomRight),
        ),
      )
      .reduce((bounds, box) => bounds.expandToInclude(box));
}

void _expectTextRangeCentered(WidgetTester tester, int start, int end) {
  final viewport = _readAlongTextViewport(tester);
  final paragraph = _textRangeRect(tester, start, end);
  expect(paragraph.height, lessThan(viewport.height - 136));
  expect(paragraph.center.dy, closeTo(viewport.center.dy, 1));
}

void _expectWordCenteredAboveFade(WidgetTester tester, int start, int end) {
  final viewport = _readAlongTextViewport(tester);
  final word = _textRangeRect(tester, start, end);
  final topInset = math.min(16.0, viewport.height * .06);
  final bottomInset = math.min(68.0, viewport.height * .45);
  final readableCenter =
      viewport.top + (topInset + viewport.height - bottomInset) / 2;
  expect(word.center.dy, closeTo(readableCenter, 1));
  expect(word.top, greaterThanOrEqualTo(viewport.top + topInset - 1));
  expect(word.bottom, lessThanOrEqualTo(viewport.bottom - bottomInset + 1));
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
  ProgressRepository? progressRepository,
  LevelMilestoneStore? milestoneStore,
}) {
  return MaterialApp(
    navigatorObservers: [appRouteObserver],
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
                  progressRepository: progressRepository,
                  milestoneStore: milestoneStore,
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
  LevelMilestoneStore? milestoneStore,
  StoryReadingBookmarkStore? bookmarkStore,
  bool resumeReading = false,
  StoryProgressOperationIdFactory operationIdFactory =
      newStoryProgressOperationId,
  bool disableAnimations = false,
  TextScaler? textScaler,
}) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: disableAnimations, textScaler: textScaler),
      child: child!,
    ),
    home: ReadAlongScreen(
      story: story,
      narrationService: service,
      authRepository: authRepository,
      settingsRepository: settings,
      progressRepository: progressRepository,
      milestoneStore: milestoneStore,
      bookmarkStore: bookmarkStore ?? MemoryStoryReadingBookmarkStore(),
      resumeReading: resumeReading,
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

StoryDetail _hostedStory({
  bool withCues = true,
  String body = 'David trusted God. He stepped forward.',
  List<StoryNarrationSegment>? segments,
  List<StoryNarrationSegment>? words,
}) {
  return StoryDetail(
    id: 'story-1',
    slug: 'david-and-goliath',
    title: 'David & Goliath',
    author: 'Kingdom Kids',
    category: 'Courage',
    body: body,
    narrations: [
      for (final character in const [
        ('lion', 'Kai'),
        ('dove', 'Nia'),
        ('rainbow', 'Zuri'),
      ])
        StoryNarration(
          avatarKey: character.$1,
          voiceKey: character.$2.toLowerCase(),
          characterName: character.$2,
          voiceDescription: 'Their own reading voice',
          locale: 'en-GB',
          speechRate: 0.42,
          pitch: 1,
          status: 'ready',
          audioAvailable: true,
          audioUrl:
              'https://audio.kingdom-kids.test/${character.$2.toLowerCase()}.mp3',
          durationSeconds: 10,
          words: withCues ? words ?? _hostedWords : const [],
          segments: withCues
              ? segments ??
                    [
                      const StoryNarrationSegment(
                        text: 'David trusted God.',
                        startOffset: 0,
                        endOffset: 18,
                        startTime: Duration.zero,
                        endTime: Duration(seconds: 5),
                      ),
                      StoryNarrationSegment(
                        text: 'He stepped forward.',
                        startOffset: 19,
                        endOffset: body.length,
                        startTime: Duration(seconds: 5),
                        endTime: Duration(seconds: 10),
                      ),
                    ]
              : const [],
        ),
    ],
  );
}

StoryDetail _hostedParagraphStory(
  List<String> paragraphs, {
  String separator = '\n\n',
}) {
  final body = paragraphs.join(separator);
  var offset = 0;
  final segments = <StoryNarrationSegment>[];
  for (var index = 0; index < paragraphs.length; index++) {
    final paragraph = paragraphs[index];
    segments.add(
      StoryNarrationSegment(
        text: paragraph,
        startOffset: offset,
        endOffset: offset + paragraph.length,
        startTime: Duration(seconds: index * 3),
        endTime: Duration(seconds: (index + 1) * 3),
      ),
    );
    offset += paragraph.length + separator.length;
  }
  return _hostedStory(body: body, segments: segments, words: const []);
}

StoryNarrationSegment _wordCue(String body, String word) {
  final start = body.indexOf(word);
  assert(start >= 0);
  return StoryNarrationSegment(
    text: word,
    startOffset: start,
    endOffset: start + word.length,
    startTime: Duration.zero,
    endTime: const Duration(milliseconds: 100),
  );
}

const _hostedWords = [
  StoryNarrationSegment(
    text: 'David',
    startOffset: 0,
    endOffset: 5,
    startTime: Duration(seconds: 1),
    endTime: Duration(milliseconds: 1800),
  ),
  StoryNarrationSegment(
    text: 'trusted',
    startOffset: 6,
    endOffset: 13,
    startTime: Duration(milliseconds: 2200),
    endTime: Duration(milliseconds: 3600),
  ),
  StoryNarrationSegment(
    text: 'God.',
    startOffset: 14,
    endOffset: 18,
    startTime: Duration(seconds: 4),
    endTime: Duration(milliseconds: 4800),
  ),
];

double? _displayedProgress(WidgetTester tester) => tester
    .widget<LinearProgressIndicator>(
      find.byKey(const Key('read-along-progress')),
    )
    .value;

String _highlightedText(WidgetTester tester) {
  final text = tester.widget<Text>(
    find.byKey(const Key('read-along-story-text')),
  );
  return (text.textSpan! as TextSpan).children!
      .cast<TextSpan>()
      .where((span) => span.style?.backgroundColor == const Color(0xFFFFE1D7))
      .map((span) => span.text ?? '')
      .join();
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
  _FakeNarrationCallbacks _callbacks = const _FakeNarrationCallbacks();
  final List<_FakeNarrationCallbacks> speakSessions = [];
  final List<String> spokenTexts = [];
  String? spokenText;
  StoryNarration? spokenNarration;
  String? fullText;
  int startOffset = 0;
  bool resume = false;
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
    NarrationPassageCallback? onPassage,
    NarrationPositionCallback? onPosition,
    NarrationWordCallback? onWord,
  }) {
    _callbacks = _FakeNarrationCallbacks(
      onStarted: onStarted,
      onCompleted: onCompleted,
      onPaused: onPaused,
      onCancelled: onCancelled,
      onError: onError,
      onProgress: onProgress,
      onPassage: onPassage,
      onPosition: onPosition,
      onWord: onWord,
    );
  }

  void emitStarted() => _callbacks.onStarted?.call();

  void emitProgress(String text, int start, int end, String word) {
    _callbacks.onProgress?.call(text, start, end, word);
  }

  void emitPassage(String text, int start, int end) =>
      _callbacks.onPassage?.call(text, start, end);

  void emitPosition(Duration position, Duration? duration) =>
      _callbacks.onPosition?.call(position, duration);

  void emitWord(StoryNarrationSegment? word) => _callbacks.onWord?.call(word);

  void emitPositionForSpeak(int index, Duration position, Duration? duration) =>
      speakSessions[index].onPosition?.call(position, duration);

  void emitCompleted() => _callbacks.onCompleted?.call();

  void emitCancelled() => _callbacks.onCancelled?.call();

  void emitError([String message = 'Narration stopped.']) =>
      _callbacks.onError?.call(message);

  void emitStartedForSpeak(int index) => speakSessions[index].onStarted?.call();

  void emitProgressForSpeak(
    int index,
    String text,
    int start,
    int end,
    String word,
  ) {
    speakSessions[index].onProgress?.call(text, start, end, word);
  }

  void emitCompletedForSpeak(int index) =>
      speakSessions[index].onCompleted?.call();

  void emitCancelledForSpeak(int index) =>
      speakSessions[index].onCancelled?.call();

  void emitErrorForSpeak(int index, String message) =>
      speakSessions[index].onError?.call(message);

  void emitCompleteProgress() {
    final text = spokenText;
    if (text == null) return;
    for (final match in RegExp(r'[A-Za-z0-9]+').allMatches(text)) {
      emitProgress(text, match.start, match.end, match.group(0)!);
    }
  }

  void emitCompleteProgressForSpeak(int index) {
    final text = spokenTexts[index];
    for (final match in RegExp(r'[A-Za-z0-9]+').allMatches(text)) {
      emitProgressForSpeak(
        index,
        text,
        match.start,
        match.end,
        match.group(0)!,
      );
    }
  }

  @override
  Future<void> speak({
    required String text,
    required StoryNarration narration,
    String? fullText,
    int startOffset = 0,
    bool resume = false,
  }) async {
    speakCalls++;
    spokenText = text;
    spokenNarration = narration;
    this.fullText = fullText;
    this.startOffset = startOffset;
    this.resume = resume;
    spokenTexts.add(text);
    final session = _callbacks;
    speakSessions.add(session);
    if (autoStart) session.onStarted?.call();
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _callbacks.onPaused?.call();
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _callbacks.onCancelled?.call();
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

final class _FakeNarrationCallbacks {
  const _FakeNarrationCallbacks({
    this.onStarted,
    this.onCompleted,
    this.onPaused,
    this.onCancelled,
    this.onError,
    this.onProgress,
    this.onPassage,
    this.onPosition,
    this.onWord,
  });

  final VoidCallback? onStarted;
  final VoidCallback? onCompleted;
  final VoidCallback? onPaused;
  final VoidCallback? onCancelled;
  final NarrationErrorCallback? onError;
  final NarrationProgressCallback? onProgress;
  final NarrationPassageCallback? onPassage;
  final NarrationPositionCallback? onPosition;
  final NarrationWordCallback? onWord;
}

typedef _ProgressCall = ({
  String profileId,
  String storyId,
  StoryActivityType eventType,
  String operationId,
});

final class _FakeProgressRepository implements ProgressRepository {
  _FakeProgressRepository({
    Map<StoryActivityType, int>? failuresRemaining,
    this.completionXp = 0,
    this.levelMilestone,
    this.completionBarrier,
  }) : failuresRemaining = {...?failuresRemaining};

  final int completionXp;
  final LevelMilestone? levelMilestone;
  final Future<void>? completionBarrier;
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
    if (eventType == StoryActivityType.storyCompleted &&
        completionBarrier != null) {
      await completionBarrier;
    }
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
      xpAwarded: eventType == StoryActivityType.storyCompleted
          ? completionXp
          : 0,
      levelMilestone: eventType == StoryActivityType.storyCompleted
          ? levelMilestone
          : null,
    );
  }
}

const _storyLevelEight = LevelMilestone(
  previousLevel: 7,
  level: ProfileLevel(
    number: 8,
    title: 'Faithful Adventurer',
    xp: 2100,
    nextLevelXp: 2400,
  ),
);

final class _MutableReaderAuth extends AuthRepository {
  _MutableReaderAuth(this.profile);
  KidProfile? profile;
  @override
  Future<KidProfile?> currentKid() async => profile;
}

class _CountingBookmarkStore extends MemoryStoryReadingBookmarkStore {
  int saves = 0;
  @override
  Future<void> save({
    required String parentId,
    required String profileId,
    required StoryReadingBookmark bookmark,
  }) async {
    saves++;
    await super.save(
      parentId: parentId,
      profileId: profileId,
      bookmark: bookmark,
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/app.dart';
import 'package:mobile/app/router.dart';
import 'package:mobile/shared/audio/app_audio_channel.dart';
import 'package:mobile/shared/audio/app_audio_controller.dart';
import 'package:mobile/shared/audio/app_audio_preferences.dart';
import 'package:mobile/shared/audio/app_audio_route_observer.dart';
import 'package:mobile/shared/audio/app_audio_scope.dart';
import 'package:mobile/shared/audio/app_audio_session.dart';
import 'package:mobile/shared/audio/app_sound_cue.dart';

void main() {
  test(
    'splash and onboarding stay completely silent even when every cue is requested',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      harness.audio.setRoute('/splash');
      harness.audio.setForeground(true);
      await harness.audio.initialize();
      for (final cue in AppSoundCue.values) {
        harness.audio.playEffect(cue);
        await _drain();
      }
      expect(harness.music.loads, isEmpty);
      expect(harness.effects.loads, isEmpty);
      expect(harness.session.activations, 0);
      harness.audio.setRoute('/onboarding');
      for (final cue in AppSoundCue.values) {
        harness.audio.playEffect(cue);
      }
      await _drain();
      expect(harness.music.loads, isEmpty);
      expect(harness.effects.loads, isEmpty);
      expect(harness.session.activations, 0);
      harness.audio.setRoute('/');
      await _drain();
      expect(harness.music.loads, [AppAudioController.musicAsset]);
      expect(harness.music.loops, [true]);
    },
  );

  test('general screens allow tap, selection and success cues only', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await harness.start();
    for (final cue in [
      AppSoundCue.tap,
      AppSoundCue.select,
      AppSoundCue.success,
    ]) {
      harness.audio.playEffect(cue);
      await _drain();
    }
    expect(harness.effects.loads, [
      'assets/audio/app/tap.wav',
      'assets/audio/app/select.wav',
      'assets/audio/app/success.wav',
    ]);
    final plays = harness.effects.plays;
    for (final cue in [
      AppSoundCue.splash,
      AppSoundCue.streak,
      AppSoundCue.levelUp,
    ]) {
      harness.audio.playEffect(cue);
      await _drain();
    }
    expect(harness.effects.loads, hasLength(3));
    expect(harness.effects.plays, plays);
    expect(harness.effects.playing, isTrue);
  });

  test(
    'approved streak mix is five seconds and restricted to the streak route',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.start();
      for (final route in ['/', '/onboarding', '/stories', '/splash', null]) {
        harness.audio.setRoute(route);
        harness.audio.playEffect(AppSoundCue.streak);
        await _drain();
      }
      expect(harness.effects.loads, isEmpty);
      harness.audio.setRoute('/streak');
      harness.audio.playEffect(AppSoundCue.streak);
      await _drain();
      expect(AppSoundCue.streak.duration, const Duration(seconds: 5));
      expect(harness.effects.loads, ['assets/audio/app/streak.wav']);
      expect(harness.effects.loops, [false]);
      expect(harness.effects.plays, 1);
      harness.audio.playEffect(AppSoundCue.splash);
      harness.audio.playEffect(AppSoundCue.levelUp);
      await _drain();
      expect(harness.effects.loads, hasLength(1));
    },
  );

  testWidgets('streak mix smoothly takes the music stage for five seconds', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await harness.start();
    await tester.pump(const Duration(milliseconds: 300));
    expect(harness.music.volumes.last, AppAudioController.musicVolume);
    harness.audio.setRoute('/streak');
    harness.audio.playEffect(AppSoundCue.streak);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(harness.music.volumes.last, 0);
    expect(harness.effects.playing, isTrue);
    await tester.pump(const Duration(milliseconds: 4700));
    expect(harness.music.volumes.last, 0);
    expect(harness.effects.playing, isTrue);
    await tester.pump(const Duration(milliseconds: 50));
    expect(harness.effects.playing, isFalse);
    await tester.pump(const Duration(milliseconds: 250));
    expect(harness.music.volumes.last, AppAudioController.musicVolume);
    expect(harness.music.loads, hasLength(1));
    expect(harness.music.plays, 1);
  });

  testWidgets('early dismissal cancels Yay even when returning to Home', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await harness.start();
    harness.audio.setRoute('/streak');
    harness.audio.playEffect(AppSoundCue.streak);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(harness.effects.playing, isTrue);
    expect(harness.music.volumes.last, 0);
    harness.audio.setRoute('/');
    await tester.pump();
    expect(harness.effects.playing, isFalse);
    await tester.pump(const Duration(milliseconds: 250));
    expect(harness.music.volumes.last, AppAudioController.musicVolume);
    await tester.pump(const Duration(seconds: 6));
    expect(harness.effects.plays, 1);
    expect(harness.effects.playing, isFalse);
    expect(harness.music.plays, 1);
  });

  test('a streak asset finishing after early dismissal stays silent', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await harness.start();
    final loading = Completer<void>();
    harness.effects.nextLoad = loading.future;
    harness.audio.setRoute('/streak');
    harness.audio.playEffect(AppSoundCue.streak);
    await _drain();
    expect(harness.effects.loads, ['assets/audio/app/streak.wav']);
    harness.audio.setRoute('/');
    loading.complete();
    await _drain();
    expect(harness.effects.plays, 0);
    expect(harness.music.plays, 1);
  });

  testWidgets('streak never repeats on the same entry or after foregrounding', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await harness.start();
    harness.audio.setRoute('/streak');
    harness.audio.playEffect(AppSoundCue.streak);
    harness.audio.playEffect(AppSoundCue.streak);
    await tester.pump();
    expect(harness.effects.plays, 1);
    harness.audio.setForeground(false);
    await tester.pump();
    expect(harness.effects.playing, isFalse);
    harness.audio.setForeground(true);
    harness.audio.playEffect(AppSoundCue.streak);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(harness.effects.plays, 1);
    harness.audio.setRoute('/');
    harness.audio.setRoute('/streak');
    harness.audio.playEffect(AppSoundCue.streak);
    await tester.pump();
    expect(harness.effects.plays, 2);
    harness.audio.setForeground(false);
    await tester.pump();
  });

  testWidgets('muting streak restores only eligible enabled background music', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await harness.start();
    harness.audio.setRoute('/streak');
    harness.audio.playEffect(AppSoundCue.streak);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await harness.audio.setEffectsEnabled(false);
    await tester.pump(const Duration(milliseconds: 250));
    expect(harness.effects.playing, isFalse);
    expect(harness.music.volumes.last, AppAudioController.musicVolume);
    await harness.audio.setMusicEnabled(false);
    harness.audio.setRoute('/stories/read-along');
    await tester.pump(const Duration(seconds: 6));
    expect(harness.music.playing, isFalse);
    expect(harness.effects.plays, 1);
  });

  test(
    'ordinary navigation leaves the loop playing without reload or restart',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.start();
      final musicPauses = harness.music.pauses;
      for (final route in [
        '/stories',
        '/games',
        '/profile',
        '/parental-controls',
      ]) {
        harness.audio.setRoute(route);
        await _drain();
      }
      expect(harness.music.loads, [AppAudioController.musicAsset]);
      expect(harness.music.loops, [true]);
      expect(harness.music.plays, 1);
      expect(harness.music.pauses, musicPauses);
      expect(harness.music.playing, isTrue);
    },
  );

  test(
    'onboarding and account entry stop active audio across focus and foreground changes',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.start();
      harness.audio.playEffect(AppSoundCue.select);
      await _drain();
      expect(harness.music.playing, isTrue);
      expect(harness.effects.playing, isTrue);
      final musicPlays = harness.music.plays;
      final effectPlays = harness.effects.plays;
      for (final route in [
        '/onboarding',
        '/auth/login',
        '/auth/register',
        '/auth',
        '/auth/verify-email',
        '/auth/password-reset',
        '/auth/kid-profile',
        '/auth/profiles',
      ]) {
        harness.audio.setRoute(route);
        harness.audio.playEffect(AppSoundCue.tap);
        harness.audio.setForeground(false);
        harness.audio.setForeground(true);
        harness.session.emit(AppAudioFocusEvent.resumed);
        await _drain();
        expect(harness.music.playing, isFalse, reason: route);
        expect(harness.effects.playing, isFalse, reason: route);
        expect(harness.music.plays, musicPlays);
        expect(harness.effects.plays, effectPlays);
      }
      harness.audio.setRoute('/');
      await _drain();
      expect(harness.music.playing, isTrue);
      expect(harness.music.plays, musicPlays + 1);
    },
  );

  test('a delayed app sound cannot start after signing out', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await harness.start();
    final loading = Completer<void>();
    harness.effects.nextLoad = loading.future;
    harness.audio.playEffect(AppSoundCue.success);
    await _drain();
    harness.audio.setRoute('/auth/login');
    loading.complete();
    await _drain();
    expect(harness.effects.plays, 0);
    expect(harness.music.playing, isFalse);
    expect(harness.effects.playing, isFalse);
  });

  for (final route in ['/onboarding', '/auth/kid-profile', '/auth/profiles']) {
    test(
      'entering $route cancels pending audio until the main app opens',
      () async {
        final harness = _Harness();
        addTearDown(harness.dispose);
        final musicLoad = Completer<void>();
        final effectLoad = Completer<void>();
        harness.music.nextLoad = musicLoad.future;
        harness.effects.nextLoad = effectLoad.future;
        await harness.start();
        harness.audio.playEffect(AppSoundCue.select);
        await _drain();
        expect(harness.music.loads, hasLength(1));
        expect(harness.effects.loads, hasLength(1));
        harness.audio.setRoute(route);
        harness.audio.setForeground(false);
        harness.audio.setForeground(true);
        harness.session.emit(AppAudioFocusEvent.resumed);
        harness.audio.playEffect(AppSoundCue.tap);
        musicLoad.complete();
        effectLoad.complete();
        await _drain();
        expect(harness.music.plays, 0);
        expect(harness.effects.plays, 0);
        expect(harness.music.playing, isFalse);
        expect(harness.effects.playing, isFalse);
        harness.audio.setRoute('/stories');
        harness.audio.playEffect(AppSoundCue.select);
        await _drain();
        expect(harness.music.plays, 1);
        expect(harness.effects.plays, 1);
      },
    );
  }

  test(
    'a selected navigation cue survives the ordinary route change',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.start();
      harness.audio.playEffect(AppSoundCue.select);
      harness.audio.setRoute('/profile');
      await _drain();
      expect(harness.effects.plays, 1);
      expect(harness.effects.loads, ['assets/audio/app/select.wav']);
      expect(harness.music.plays, 1);
    },
  );

  test('saved mute preferences prevent the first startup sound', () async {
    final harness = _Harness(store: _Store(music: false, effects: false));
    addTearDown(harness.dispose);
    harness.audio.setRoute('/');
    harness.audio.setForeground(true);
    harness.audio.playEffect(AppSoundCue.select);
    await harness.audio.initialize();
    await _drain();
    expect(harness.audio.musicEnabled, isFalse);
    expect(harness.audio.effectsEnabled, isFalse);
    expect(harness.music.loads, isEmpty);
    expect(harness.effects.loads, isEmpty);
    expect(harness.session.activations, 0);
  });

  test(
    'matching feedback allows only three approved cues without game music',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.start();
      harness.audio.setRoute('/games/play');
      final feedback = harness.audio.createMatchingFeedback();
      harness.audio.playEffect(AppSoundCue.select);
      await _drain();
      expect(harness.effects.loads, isEmpty);
      for (final cue in [
        AppSoundCue.tap,
        AppSoundCue.select,
        AppSoundCue.success,
      ]) {
        feedback.play(cue);
        await _drain();
      }
      expect(harness.effects.loads, [
        AppSoundCue.tap.assetPath,
        AppSoundCue.select.assetPath,
        AppSoundCue.success.assetPath,
      ]);
      for (final cue in [
        AppSoundCue.splash,
        AppSoundCue.streak,
        AppSoundCue.levelUp,
      ]) {
        feedback.play(cue);
        await _drain();
      }
      expect(harness.effects.loads, hasLength(3));
      expect(harness.effects.plays, 3);
      expect(harness.music.playing, isFalse);
      expect(harness.music.plays, 1);
      feedback.dispose();
    },
  );

  test('matching feedback stays silent outside the gameplay route', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await harness.start();
    final feedback = harness.audio.createMatchingFeedback();
    for (final route in [
      '/',
      '/stories/read-along',
      '/videos/detail',
      '/splash',
      null,
    ]) {
      harness.audio.setRoute(route);
      feedback.play(AppSoundCue.success);
      await _drain();
    }
    expect(harness.effects.loads, isEmpty);
    feedback.dispose();
  });

  test(
    'pausing matching cancels its pending load and resume never replays it',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.start();
      harness.audio.setRoute('/games/play');
      final feedback = harness.audio.createMatchingFeedback();
      final loading = Completer<void>();
      harness.effects.nextLoad = loading.future;
      feedback.play(AppSoundCue.select);
      await _drain();
      feedback.setPaused(true);
      loading.complete();
      await _drain();
      feedback.play(AppSoundCue.tap);
      feedback.setPaused(false);
      await _drain();
      expect(harness.effects.plays, 0);
      feedback.play(AppSoundCue.select);
      await _drain();
      expect(harness.effects.plays, 1);
      feedback.setPaused(true);
      await _drain();
      expect(harness.effects.playing, isFalse);
      feedback.dispose();
    },
  );

  test(
    'old matching handle disposal cannot stop a newer matching cue',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.start();
      harness.audio.setRoute('/games/play');
      final old = harness.audio.createMatchingFeedback();
      final current = harness.audio.createMatchingFeedback();
      old.play(AppSoundCue.select);
      await _drain();
      current.play(AppSoundCue.success);
      await _drain();
      old.setPaused(true);
      old.dispose();
      await _drain();
      expect(harness.effects.playing, isTrue);
      expect(harness.effects.plays, 2);
      current.dispose();
      await _drain();
      expect(harness.effects.playing, isFalse);
      current.play(AppSoundCue.tap);
      await _drain();
      expect(harness.effects.plays, 2);
    },
  );

  test(
    'matching pending cues cannot survive mute background route exit or disposal',
    () async {
      for (final cancellation in ['mute', 'background', 'route', 'dispose']) {
        final harness = _Harness();
        await harness.start();
        harness.audio.setRoute('/games/play');
        final feedback = harness.audio.createMatchingFeedback();
        final loading = Completer<void>();
        harness.effects.nextLoad = loading.future;
        feedback.play(AppSoundCue.success);
        await _drain();
        switch (cancellation) {
          case 'mute':
            await harness.audio.setEffectsEnabled(false);
            await harness.audio.setEffectsEnabled(true);
          case 'background':
            harness.audio.setForeground(false);
            harness.audio.setForeground(true);
          case 'route':
            harness.audio.setRoute(null);
            harness.audio.setRoute('/games/play');
          case 'dispose':
            feedback.dispose();
        }
        loading.complete();
        await _drain();
        expect(harness.effects.plays, 0, reason: cancellation);
        expect(harness.music.playing, isFalse, reason: cancellation);
        feedback.dispose();
        harness.dispose();
      }
    },
  );

  test(
    'matching interruptions cancel cues and do not resume game music',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.start();
      harness.audio.setRoute('/games/play');
      final feedback = harness.audio.createMatchingFeedback();
      feedback.play(AppSoundCue.select);
      await _drain();
      harness.session.emit(AppAudioFocusEvent.interrupted);
      feedback.play(AppSoundCue.success);
      await _drain();
      expect(harness.effects.playing, isFalse);
      expect(harness.effects.plays, 1);
      harness.session.emit(AppAudioFocusEvent.resumed);
      await _drain();
      expect(harness.effects.plays, 1);
      feedback.play(AppSoundCue.success);
      await _drain();
      expect(harness.effects.plays, 2);
      harness.session.emit(AppAudioFocusEvent.headphonesRemoved);
      feedback.play(AppSoundCue.tap);
      await _drain();
      expect(harness.effects.playing, isFalse);
      expect(harness.effects.plays, 2);
      expect(harness.music.playing, isFalse);
      expect(harness.music.plays, 1);
      feedback.dispose();
    },
  );

  test('reader, video, gameplay and unknown routes suspend ambience', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await harness.start();
    expect(harness.music.plays, 1);
    for (final route in [
      '/stories/read-along',
      '/videos/detail',
      '/games/detail',
      '/games/play',
      null,
    ]) {
      harness.audio.setRoute(route);
      harness.audio.playEffect(AppSoundCue.success);
      await _drain();
      expect(harness.music.playing, isFalse);
      expect(harness.effects.loads, isEmpty);
    }
    expect(harness.session.releases, greaterThanOrEqualTo(5));
    harness.audio.setRoute('/stories');
    await _drain();
    expect(harness.music.plays, 2);
    expect(harness.music.loads, hasLength(1));
  });

  test(
    'music asset finishing after navigation cannot restart playback',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final loading = Completer<void>();
      harness.music.nextLoad = loading.future;
      await harness.start();
      expect(harness.music.loads, hasLength(1));
      harness.audio.setRoute('/stories/read-along');
      loading.complete();
      await _drain();
      expect(harness.music.plays, 0);
      harness.audio.setRoute('/');
      await _drain();
      expect(harness.music.loads, hasLength(1));
      expect(harness.music.plays, 1);
    },
  );

  test(
    'muting during a pending effect load permanently cancels that cue',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.start();
      final loading = Completer<void>();
      harness.effects.nextLoad = loading.future;
      harness.audio.playEffect(AppSoundCue.tap);
      await _drain();
      await harness.audio.setEffectsEnabled(false);
      loading.complete();
      await _drain();
      expect(harness.effects.plays, 0);
      await harness.audio.setEffectsEnabled(true);
      await _drain();
      expect(harness.effects.plays, 0);
    },
  );

  test(
    'inactivity stops both channels and stale effects do not replay',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.start();
      harness.audio.playEffect(AppSoundCue.select);
      await _drain();
      expect(harness.effects.plays, 1);
      harness.audio.setForeground(false);
      await _drain();
      expect(harness.music.playing, isFalse);
      expect(harness.effects.playing, isFalse);
      harness.audio.playEffect(AppSoundCue.tap);
      harness.audio.setForeground(true);
      await _drain();
      expect(harness.music.plays, 2);
      expect(harness.effects.plays, 1);
    },
  );

  test(
    'restore cannot overwrite an explicit preference changed while reading',
    () async {
      final store = _Store(music: true, effects: false);
      final musicRead = Completer<bool?>();
      store.pendingMusicRead = musicRead.future;
      final harness = _Harness(store: store);
      addTearDown(harness.dispose);
      harness.audio.setRoute('/');
      harness.audio.setForeground(true);
      final initializing = harness.audio.initialize();
      await harness.audio.setMusicEnabled(false);
      await harness.audio.setEffectsEnabled(true);
      musicRead.complete(true);
      await initializing;
      await _drain();
      expect(harness.audio.musicEnabled, isFalse);
      expect(harness.audio.effectsEnabled, isTrue);
      expect(harness.music.loads, isEmpty);
      expect(store.music, isFalse);
      expect(store.effects, isTrue);
    },
  );

  test(
    'rapid toggles persist the latest value even when the first write is slow',
    () async {
      final store = _Store();
      final pendingWrite = Completer<void>();
      store.pendingMusicWrite = pendingWrite.future;
      final harness = _Harness(store: store);
      addTearDown(harness.dispose);
      final first = harness.audio.setMusicEnabled(false);
      await _drain();
      final last = harness.audio.setMusicEnabled(true);
      pendingWrite.complete();
      await Future.wait([first, last]);
      expect(store.musicWrites, [false, true]);
      expect(store.music, isTrue);
    },
  );

  test(
    'interruptions resume music only on an eligible foreground route',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.start();
      harness.session.emit(AppAudioFocusEvent.interrupted);
      await _drain();
      expect(harness.music.playing, isFalse);
      harness.session.emit(AppAudioFocusEvent.resumed);
      await _drain();
      expect(harness.music.plays, 2);
      harness.audio.setRoute('/games/play');
      harness.session.emit(AppAudioFocusEvent.resumed);
      await _drain();
      expect(harness.music.plays, 2);
      harness.session.emit(AppAudioFocusEvent.headphonesRemoved);
      harness.audio.setRoute('/');
      await _drain();
      harness.session.emit(AppAudioFocusEvent.headphonesRemoved);
      await _drain();
      expect(harness.music.playing, isFalse);
      harness.audio.setRoute('/stories');
      await _drain();
      expect(harness.music.playing, isFalse);
      await harness.audio.setMusicEnabled(true);
      await _drain();
      expect(harness.music.playing, isTrue);
    },
  );

  test('disposing during a pending load leaves all channels stopped', () async {
    final harness = _Harness();
    final loading = Completer<void>();
    harness.music.nextLoad = loading.future;
    await harness.start();
    harness.dispose();
    harness.dispose();
    loading.complete();
    await _drain();
    harness.audio.setForeground(true);
    harness.audio.playEffect(AppSoundCue.success);
    expect(harness.music.plays, 0);
    expect(harness.music.disposals, 1);
    expect(harness.effects.disposals, 1);
    expect(harness.session.disposals, 1);
  });

  test(
    'optional storage and audio failures do not escape into app actions',
    () async {
      final harness = _Harness(store: _Store()..fail = true);
      addTearDown(harness.dispose);
      harness.music.fail = true;
      harness.effects.fail = true;
      await harness.start();
      await harness.audio.setMusicEnabled(false);
      await harness.audio.setMusicEnabled(true);
      await harness.audio.setEffectsEnabled(false);
      await harness.audio.setEffectsEnabled(true);
      harness.audio.playEffect(AppSoundCue.success);
      await _drain();
      harness.audio.setForeground(false);
      await _drain();
    },
  );

  testWidgets('scope is optional and notifies controls when music changes', (
    tester,
  ) async {
    AppAudioController? found;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          found = AppAudioScope.maybeOf(context);
          return const SizedBox();
        },
      ),
    );
    expect(found, isNull);
    final harness = _Harness();
    addTearDown(harness.dispose);
    await tester.pumpWidget(
      AppAudioScope(
        controller: harness.audio,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) {
              final audio = AppAudioScope.maybeOf(context)!;
              return Text(audio.musicEnabled ? 'Music on' : 'Music off');
            },
          ),
        ),
      ),
    );
    expect(find.text('Music on'), findsOneWidget);
    await harness.audio.setMusicEnabled(false);
    await tester.pump();
    expect(find.text('Music off'), findsOneWidget);
  });

  testWidgets(
    'app root provides the controller and forwards background lifecycle',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final harness = _Harness();
      addTearDown(harness.dispose);
      await tester.pumpWidget(
        KingdomKidsApp(
          initialRoute: AppRoutes.onboarding,
          audioController: harness.audio,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(harness.music.plays, 0);
      expect(
        AppAudioScope.maybeOf(tester.element(find.byType(Scaffold).first)),
        same(harness.audio),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(harness.music.playing, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(harness.music.plays, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(harness.music.playing, isFalse);
    },
  );

  test(
    'route observer restores underlying policy after an unnamed sheet closes',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      harness.audio.setForeground(true);
      await harness.audio.initialize();
      final observer = AppAudioRouteObserver(harness.audio);
      final home = MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/'),
        builder: (_) => const SizedBox(),
      );
      final sheet = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      observer.didPush(home, null);
      await _drain();
      expect(harness.music.plays, 1);
      observer.didPush(sheet, home);
      await _drain();
      expect(harness.music.playing, isFalse);
      observer.didPop(sheet, home);
      await _drain();
      expect(harness.music.plays, 2);
    },
  );
}

Future<void> _drain() async {
  for (var i = 0; i < 20; ++i) {
    await Future<void>.value();
  }
}

class _Harness {
  _Harness({_Store? store}) {
    audio = AppAudioController(
      musicChannel: music,
      effectsChannel: effects,
      preferenceStore: store ?? _Store(),
      audioSession: session,
    );
  }
  final music = _Channel();
  final effects = _Channel();
  final session = _Session();
  late final AppAudioController audio;
  Future<void> start() async {
    audio.setRoute('/');
    audio.setForeground(true);
    await audio.initialize();
    await _drain();
  }

  void dispose() => audio.dispose();
}

class _Channel implements AppAudioChannel {
  final loads = <String>[];
  final loops = <bool>[];
  final volumes = <double>[];
  int plays = 0;
  int pauses = 0;
  int disposals = 0;
  bool playing = false;
  bool fail = false;
  Future<void>? nextLoad;
  @override
  Future<void> load(String assetPath, {required bool loop}) async {
    loads.add(assetPath);
    loops.add(loop);
    final pending = nextLoad;
    nextLoad = null;
    if (pending != null) await pending;
    if (fail) throw StateError('Missing test asset');
  }

  @override
  Future<void> setVolume(double volume) async {
    if (fail) throw StateError('Missing test plugin');
    volumes.add(volume);
  }

  @override
  Future<void> pause() async {
    pauses++;
    playing = false;
  }

  @override
  Future<void> play() async {
    if (fail) throw StateError('Missing test plugin');
    plays++;
    playing = true;
  }

  @override
  Future<void> dispose() async {
    disposals++;
    playing = false;
  }
}

class _Store implements AppAudioPreferenceStore {
  _Store({this.music, this.effects});
  bool? music;
  bool? effects;
  bool fail = false;
  Future<bool?>? pendingMusicRead;
  Future<void>? pendingMusicWrite;
  final musicWrites = <bool>[];
  @override
  Future<bool?> readMusicEnabled() async {
    if (fail) throw StateError('Missing test storage');
    return pendingMusicRead ?? music;
  }

  @override
  Future<bool?> readEffectsEnabled() async {
    if (fail) throw StateError('Missing test storage');
    return effects;
  }

  @override
  Future<void> writeMusicEnabled(bool enabled) async {
    if (fail) throw StateError('Missing test storage');
    final pending = pendingMusicWrite;
    pendingMusicWrite = null;
    if (pending != null) await pending;
    musicWrites.add(enabled);
    music = enabled;
  }

  @override
  Future<void> writeEffectsEnabled(bool enabled) async {
    if (fail) throw StateError('Missing test storage');
    effects = enabled;
  }
}

class _Session implements AppAudioSessionGateway {
  final _events = StreamController<AppAudioFocusEvent>.broadcast(sync: true);
  int activations = 0;
  int releases = 0;
  int disposals = 0;
  void emit(AppAudioFocusEvent event) => _events.add(event);
  @override
  Stream<AppAudioFocusEvent> get events => _events.stream;
  @override
  Future<bool> activate(bool Function() stillAllowed) async {
    activations++;
    return stillAllowed();
  }

  @override
  Future<void> release({bool deactivate = false}) async => releases++;
  @override
  Future<void> dispose() async {
    disposals++;
    await _events.close();
  }
}

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/games/data/david_battle_audio.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );

  test(
    'idle game stays silent, and pausing preserves the prepared ambience',
    () async {
      final ambience = _Channel();
      final effects = _Channel();
      final audio = AssetDavidBattleAudio(
        ambienceChannel: ambience,
        effectsChannel: effects,
      );
      await audio.playLaunch();
      expect(effects.loads, isEmpty);
      expect(ambience.loads, isEmpty);
      await audio.setActive(true);
      expect(ambience.loads.single.asset, AssetDavidBattleAudio.ambienceAsset);
      expect(ambience.loads.single.loop, isTrue);
      expect(
        ambience.loads.single.volume,
        AssetDavidBattleAudio.ambienceVolume,
      );
      expect(ambience.plays, 1);
      await audio.setActive(false);
      expect(ambience.pauses, 1);
      expect(effects.pauses, 1);
      await audio.playImpact();
      expect(effects.loads, isEmpty);
      await audio.setActive(true);
      expect(ambience.loads, hasLength(1));
      expect(ambience.plays, 2);
      await audio.dispose();
    },
  );

  test('mute stops both channels and unmute resumes only ambience', () async {
    final ambience = _Channel();
    final effects = _Channel();
    final audio = AssetDavidBattleAudio(
      ambienceChannel: ambience,
      effectsChannel: effects,
    );
    await audio.setActive(true);
    await audio.playLaunch();
    await audio.setMuted(true);
    await audio.playImpact();
    await audio.playVictory();
    expect(effects.loads, hasLength(1));
    expect(effects.pauses, 1);
    await audio.setMuted(false);
    expect(ambience.plays, 2);
    expect(effects.plays, 1);
    await audio.dispose();
  });

  test(
    'cue playback uses only the original local assets at bounded volume',
    () async {
      final effects = _Channel();
      final audio = AssetDavidBattleAudio(
        ambienceChannel: _Channel(),
        effectsChannel: effects,
      );
      await audio.setActive(true);
      await audio.playLaunch();
      await audio.playImpact();
      await audio.playVictory();
      expect(effects.loads.map((load) => load.asset), [
        AssetDavidBattleAudio.launchAsset,
        AssetDavidBattleAudio.impactAsset,
        AssetDavidBattleAudio.landingAsset,
      ]);
      expect(
        effects.loads.every(
          (load) => !load.loop && load.volume > 0 && load.volume < 1,
        ),
        isTrue,
      );
      expect(effects.plays, 3);
      await audio.dispose();
    },
  );

  test(
    'an ambience load completing after pause cannot start playback',
    () async {
      final pending = Completer<void>();
      final ambience = _Channel()..nextLoad = pending.future;
      final audio = AssetDavidBattleAudio(
        ambienceChannel: ambience,
        effectsChannel: _Channel(),
      );
      final startup = audio.setActive(true);
      await Future<void>.value();
      await audio.setActive(false);
      pending.complete();
      await startup;
      expect(ambience.plays, 0);
      await audio.setActive(true);
      expect(ambience.loads, hasLength(1));
      expect(ambience.plays, 1);
      await audio.dispose();
    },
  );

  test('muting during an effect load cancels that cue permanently', () async {
    final effects = _Channel();
    final audio = AssetDavidBattleAudio(
      ambienceChannel: _Channel(),
      effectsChannel: effects,
    );
    await audio.setActive(true);
    final pending = Completer<void>();
    effects.nextLoad = pending.future;
    final launch = audio.playLaunch();
    await Future<void>.value();
    await audio.setMuted(true);
    pending.complete();
    await launch;
    expect(effects.plays, 0);
    await audio.setMuted(false);
    expect(effects.plays, 0);
    await audio.dispose();
  });

  test('older effect loading cannot retrigger a newer collision cue', () async {
    final effects = _Channel();
    final audio = AssetDavidBattleAudio(
      ambienceChannel: _Channel(),
      effectsChannel: effects,
    );
    await audio.setActive(true);
    final pending = Completer<void>();
    effects.nextLoad = pending.future;
    final launch = audio.playLaunch();
    await Future<void>.value();
    await audio.playImpact();
    expect(effects.plays, 1);
    pending.complete();
    await launch;
    expect(effects.plays, 1);
    await audio.dispose();
  });

  test(
    'background audio never starts and foreground playback honors active state',
    () async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final ambience = _Channel();
      final effects = _Channel();
      final audio = AssetDavidBattleAudio(
        ambienceChannel: ambience,
        effectsChannel: effects,
      );
      await audio.setActive(true);
      await audio.playLaunch();
      expect(ambience.loads, isEmpty);
      expect(effects.loads, isEmpty);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(ambience.plays, 1);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await Future<void>.delayed(Duration.zero);
      expect(ambience.pauses, greaterThanOrEqualTo(2));
      await audio.setActive(false);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(ambience.plays, 1);
      await audio.dispose();
    },
  );

  test(
    'disposing during a pending load prevents playback and disposes once',
    () async {
      final pending = Completer<void>();
      final ambience = _Channel()..nextLoad = pending.future;
      final effects = _Channel();
      final audio = AssetDavidBattleAudio(
        ambienceChannel: ambience,
        effectsChannel: effects,
      );
      final startup = audio.setActive(true);
      await Future<void>.value();
      await audio.dispose();
      await audio.dispose();
      pending.complete();
      await startup;
      await audio.setActive(true);
      await audio.playVictory();
      expect(ambience.plays, 0);
      expect(ambience.disposals, 1);
      expect(effects.disposals, 1);
      expect(effects.loads, isEmpty);
    },
  );

  test(
    'missing assets or plugins cannot throw into gameplay and loads can retry',
    () async {
      final ambience = _Channel()..fail = true;
      final effects = _Channel()..fail = true;
      final audio = AssetDavidBattleAudio(
        ambienceChannel: ambience,
        effectsChannel: effects,
      );
      await audio.setActive(true);
      await audio.setActive(true);
      expect(ambience.loads, hasLength(2));
      await audio.playLaunch();
      await audio.playImpact();
      await audio.playVictory();
      await audio.setMuted(true);
      await audio.setActive(false);
      await audio.dispose();
    },
  );
}

class _Load {
  const _Load(this.asset, this.loop, this.volume);
  final String asset;
  final bool loop;
  final double volume;
}

class _Channel implements DavidBattleAudioChannel {
  final loads = <_Load>[];
  int plays = 0;
  int pauses = 0;
  int disposals = 0;
  bool fail = false;
  Future<void>? nextLoad;
  @override
  Future<void> load(
    String assetPath, {
    required bool loop,
    required double volume,
  }) async {
    loads.add(_Load(assetPath, loop, volume));
    final pending = nextLoad;
    nextLoad = null;
    if (pending != null) await pending;
    if (fail) throw StateError('Unavailable test audio');
  }

  @override
  Future<void> play() async {
    if (fail) throw StateError('Unavailable test audio');
    plays++;
  }

  @override
  Future<void> pause() async {
    if (fail) throw StateError('Unavailable test audio');
    pauses++;
  }

  @override
  Future<void> dispose() async {
    if (fail) throw StateError('Unavailable test audio');
    disposals++;
  }
}

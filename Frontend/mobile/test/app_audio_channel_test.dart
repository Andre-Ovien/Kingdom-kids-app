import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mobile/shared/audio/app_audio_channel.dart';
import 'package:mobile/shared/audio/app_audio_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'ambience uses one native repeating source, without a restart timer',
    () async {
      final player = _Player();
      final channel = JustAudioAppChannel(playerFactory: () => player);
      await channel.load(AppAudioController.musicAsset, loop: true);
      expect(player.modes, [LoopMode.one]);
      expect(player.assets, [AppAudioController.musicAsset]);
      expect(player.plays, 0);
      await channel.setVolume(AppAudioController.musicVolume);
      await channel.play();
      expect(player.plays, 1);
      // play's native future stays pending for an infinite loop. The adapter
      // returns immediately and never needs to load/seek the next repetition.
      expect(player.playCompletion.isCompleted, isFalse);
      await channel.pause();
      await channel.play();
      expect(player.assets, hasLength(1));
      expect(player.modes, [LoopMode.one]);
      expect(player.plays, 2);
      await channel.dispose();
    },
  );

  test(
    'action cues never inherit looping mode or autoplay during a load',
    () async {
      final player = _Player();
      final channel = JustAudioAppChannel(playerFactory: () => player);
      await channel.load('assets/audio/app/tap.wav', loop: false);
      expect(player.modes, [LoopMode.off]);
      expect(player.plays, 0);
      expect(player.volumes.last, 0);
      await channel.play();
      expect(player.plays, 1);
      await channel.dispose();
      await channel.play();
      expect(player.plays, 1);
    },
  );
}

final class _Player extends AudioPlayer {
  final modes = <LoopMode>[];
  final assets = <String>[];
  final volumes = <double>[];
  final playCompletion = Completer<void>();
  int plays = 0;

  @override
  Future<void> setLoopMode(LoopMode loopMode) async => modes.add(loopMode);
  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<Duration?> setAsset(
    String assetPath, {
    String? package,
    bool preload = true,
    Duration? initialPosition,
    dynamic tag,
  }) async {
    assets.add(assetPath);
    return const Duration(seconds: 30);
  }

  @override
  Future<void> play() {
    ++plays;
    return playCompletion.future;
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> dispose() async {
    if (!playCompletion.isCompleted) playCompletion.complete();
  }
}

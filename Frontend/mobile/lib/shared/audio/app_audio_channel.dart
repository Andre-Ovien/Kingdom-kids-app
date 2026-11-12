import 'dart:async';

import 'package:just_audio/just_audio.dart';

abstract interface class AppAudioChannel {
  Future<void> load(String assetPath, {required bool loop});
  Future<void> setVolume(double volume);
  Future<void> play();
  Future<void> pause();
  Future<void> dispose();
}

/// Loading never autoplays. The controller alone decides when it is safe to
/// start, including after asynchronous asset loads and audio focus changes.
class JustAudioAppChannel implements AppAudioChannel {
  JustAudioAppChannel({AudioPlayer Function()? playerFactory})
    : _playerFactory = playerFactory ?? _createPlayer;

  static AudioPlayer _createPlayer() => AudioPlayer(
    handleInterruptions: false,
    handleAudioSessionActivation: false,
  );

  final AudioPlayer Function() _playerFactory;
  AudioPlayer? _player;
  bool _disposed = false;

  @override
  Future<void> load(String assetPath, {required bool loop}) async {
    if (_disposed) return;
    final player = _player ??= _playerFactory();
    await player.pause();
    if (_disposed) return;
    await player.setVolume(0);
    if (_disposed) return;
    await player.setLoopMode(loop ? LoopMode.one : LoopMode.off);
    if (_disposed) return;
    await player.setAsset(assetPath);
  }

  @override
  Future<void> setVolume(double volume) async {
    if (!_disposed) await _player?.setVolume(volume);
  }

  @override
  Future<void> play() async {
    if (_disposed) return;
    final player = _player;
    if (player != null) {
      // A looping player's play future completes only after playback stops.
      unawaited(player.play().catchError((Object _) {}));
    }
  }

  @override
  Future<void> pause() async {
    if (!_disposed) await _player?.pause();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final player = _player;
    _player = null;
    await player?.dispose();
  }
}

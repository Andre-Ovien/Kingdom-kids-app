import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';

/// Game-owned audio. A supplied instance is disposed when the battle closes.
abstract interface class DavidBattleAudio {
  Future<void> setActive(bool active);
  Future<void> setMuted(bool muted);
  Future<void> playLaunch();
  Future<void> playImpact();

  /// The soft landing cue, timed to Goliath reaching the ground.
  Future<void> playVictory();
  Future<void> dispose();
}

/// Widget tests and previews can stay silent without opening audio plugins.
class SilentDavidBattleAudio implements DavidBattleAudio {
  const SilentDavidBattleAudio();
  @override
  Future<void> setActive(bool active) async {}
  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> playLaunch() async {}
  @override
  Future<void> playImpact() async {}
  @override
  Future<void> playVictory() async {}
  @override
  Future<void> dispose() async {}
}

/// Small channel boundary for testing loading and lifecycle races without a
/// platform player. [play] starts playback and returns immediately.
abstract interface class DavidBattleAudioChannel {
  Future<void> load(
    String assetPath, {
    required bool loop,
    required double volume,
  });
  Future<void> play();
  Future<void> pause();
  Future<void> dispose();
}

class AssetDavidBattleAudio
    with WidgetsBindingObserver
    implements DavidBattleAudio {
  AssetDavidBattleAudio({
    DavidBattleAudioChannel? ambienceChannel,
    DavidBattleAudioChannel? effectsChannel,
  }) : _ambience = ambienceChannel ?? _JustAudioBattleChannel(),
       _effects = effectsChannel ?? _JustAudioBattleChannel() {
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  static const ambienceAsset = 'assets/audio/david/battle_ambience.wav';
  static const launchAsset = 'assets/audio/david/sling_launch.wav';
  static const impactAsset = 'assets/audio/david/stone_impact.wav';
  static const landingAsset = 'assets/audio/david/body_land.wav';
  static const ambienceVolume = 0.55;
  static const effectVolume = 0.65;

  final DavidBattleAudioChannel _ambience;
  final DavidBattleAudioChannel _effects;
  bool _active = false;
  bool _muted = false;
  bool _foreground = true;
  bool _disposed = false;
  bool _ambienceReady = false;
  Future<bool>? _ambienceLoading;
  int _ambienceRequest = 0;
  int _effectRequest = 0;

  bool get _audible => !_disposed && _active && !_muted && _foreground;

  @override
  Future<void> setActive(bool active) async {
    if (_disposed) return;
    _active = active;
    await _applyState();
  }

  @override
  Future<void> setMuted(bool muted) async {
    if (_disposed) return;
    _muted = muted;
    await _applyState();
  }

  Future<void> _applyState() async {
    final request = ++_ambienceRequest;
    if (!_audible) {
      ++_effectRequest;
      await Future.wait([_safely(_ambience.pause), _safely(_effects.pause)]);
      return;
    }
    if (!await _prepareAmbience()) return;
    if (!_audible || request != _ambienceRequest) return;
    await _safely(_ambience.play);
  }

  Future<bool> _prepareAmbience() async {
    if (_ambienceReady) return true;
    final pending = _ambienceLoading;
    if (pending != null) return pending;
    final loading = _safely(
      () => _ambience.load(ambienceAsset, loop: true, volume: ambienceVolume),
    );
    _ambienceLoading = loading;
    final ready = await loading;
    if (identical(_ambienceLoading, loading)) {
      _ambienceLoading = null;
      _ambienceReady = ready && !_disposed;
    }
    return ready;
  }

  @override
  Future<void> playLaunch() => _playEffect(launchAsset);
  @override
  Future<void> playImpact() => _playEffect(impactAsset);
  @override
  Future<void> playVictory() => _playEffect(landingAsset);

  Future<void> _playEffect(String asset) async {
    if (!_audible) return;
    final request = ++_effectRequest;
    final ready = await _safely(
      () => _effects.load(asset, loop: false, volume: effectVolume),
    );
    if (!ready || !_audible || request != _effectRequest) return;
    await _safely(_effects.play);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    _foreground = state == AppLifecycleState.resumed;
    unawaited(_applyState());
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_ambienceRequest;
    ++_effectRequest;
    WidgetsBinding.instance.removeObserver(this);
    await Future.wait([_safely(_ambience.dispose), _safely(_effects.dispose)]);
  }

  static Future<bool> _safely(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } catch (_) {
      // Sound is optional. Missing assets/plugins or an interrupted load must
      // never interrupt a child's battle or create an unhandled async error.
      return false;
    }
  }
}

class _JustAudioBattleChannel implements DavidBattleAudioChannel {
  AudioPlayer? _player;
  bool _disposed = false;

  @override
  Future<void> load(
    String assetPath, {
    required bool loop,
    required double volume,
  }) async {
    if (_disposed) return;
    final player = _player ??= AudioPlayer();
    // Completed just_audio clips retain playing=true. Pause before replacing
    // a cue so loading cannot autoplay a stale effect before the game checks
    // its latest lifecycle and mute state.
    await player.pause();
    if (_disposed) return;
    await player.setVolume(volume);
    if (_disposed) return;
    await player.setLoopMode(loop ? LoopMode.one : LoopMode.off);
    if (_disposed) return;
    await player.setAsset(assetPath);
  }

  @override
  Future<void> play() async {
    final player = _player;
    if (_disposed || player == null) return;
    // just_audio's play future lasts for the whole clip (forever for a loop).
    // Catch it here so game actions do not wait for audio to finish.
    unawaited(player.play().catchError((Object _) {}));
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    await _player?.pause();
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

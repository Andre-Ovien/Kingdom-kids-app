import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_audio_channel.dart';
import 'app_audio_preferences.dart';
import 'app_audio_session.dart';
import 'app_sound_cue.dart';

/// Optional, device-wide app ambience. Narration and gameplay own their audio.
class AppAudioController extends ChangeNotifier {
  AppAudioController({
    AppAudioChannel? musicChannel,
    AppAudioChannel? effectsChannel,
    AppAudioPreferenceStore? preferenceStore,
    AppAudioSessionGateway? audioSession,
  }) : _music = musicChannel ?? JustAudioAppChannel(),
       _effects = effectsChannel ?? JustAudioAppChannel(),
       _preferences = preferenceStore ?? SecureAppAudioPreferenceStore(),
       _session = audioSession ?? AmbientAppAudioSession() {
    _focusSubscription = _session.events.listen(_onFocusEvent);
  }

  static const musicAsset = 'assets/audio/app/app_theme.wav';
  static const musicVolume = 0.16;
  static const duckedMusicVolume = 0.055;
  static const effectsVolume = 0.55;
  // Only auditions explicitly approved by the user may reach a live player.
  static const approvedEffects = {
    AppSoundCue.tap,
    AppSoundCue.select,
    AppSoundCue.success,
    AppSoundCue.streak,
  };

  static const _matchingEffects = {
    AppSoundCue.tap,
    AppSoundCue.select,
    AppSoundCue.success,
  };

  static const _musicRoutes = {
    '/',
    '/streak',
    '/milestones/level',
    '/stories',
    '/stories/detail',
    '/videos',
    '/games',
    '/bible',
    // Onboarding, account entry, registration, verification and recovery stay silent.
    // Audio starts after account and child-profile setup, inside the main app.
    '/profile',
    '/parental-controls',
  };

  final AppAudioChannel _music;
  final AppAudioChannel _effects;
  final AppAudioPreferenceStore _preferences;
  final AppAudioSessionGateway _session;
  late final StreamSubscription<AppAudioFocusEvent> _focusSubscription;
  Future<void>? _initialization;
  Future<void> _musicQueue = Future.value();
  Future<void> _effectsQueue = Future.value();
  Future<void> _musicWrites = Future.value();
  Future<void> _effectsWrites = Future.value();
  Timer? _fadeTimer;
  Timer? _duckTimer;
  bool _musicEnabled = true;
  bool _effectsEnabled = true;
  bool _initialized = false;
  bool _foreground = false;
  bool _interrupted = false;
  bool _headphonesRemoved = false;
  bool _disposed = false;
  bool _musicPrepared = false;
  bool _musicPlaying = false;
  bool _effectPlaying = false;
  bool _streakCueRequested = false;
  AppSoundCue? _requestedCue;
  MatchingGameFeedback? _requestedMatchingFeedback;
  final Set<MatchingGameFeedback> _matchingFeedback = {};
  String? _route;
  int _musicGeneration = 0;
  int _effectsGeneration = 0;
  int _musicPreferenceRevision = 0;
  int _effectsPreferenceRevision = 0;
  double _currentMusicVolume = 0;

  bool get musicEnabled => _musicEnabled;
  bool get effectsEnabled => _effectsEnabled;

  bool get _canUseAudio =>
      !_disposed &&
      _initialized &&
      _foreground &&
      !_interrupted &&
      !_headphonesRemoved;
  bool get _shouldPlayMusic =>
      _canUseAudio && _musicEnabled && _musicRoutes.contains(_route);
  bool _canPlayEffect(
    AppSoundCue cue, {
    MatchingGameFeedback? matchingFeedback,
  }) =>
      _canUseAudio &&
      _effectsEnabled &&
      approvedEffects.contains(cue) &&
      (matchingFeedback == null
          ? _musicRoutes.contains(_route) &&
                (cue != AppSoundCue.streak || _route == '/streak')
          : _route == '/games/play' &&
                _matchingEffects.contains(cue) &&
                _matchingFeedback.contains(matchingFeedback) &&
                matchingFeedback._canRequest);

  /// A matching engine owns this short-lived feedback handle. Pause it with
  /// gameplay and dispose it on exit; neither operation can affect game audio
  /// owned by the Ark, David or narration players. App music remains suspended.
  MatchingGameFeedback createMatchingFeedback({bool paused = false}) {
    final feedback = MatchingGameFeedback._(this, paused: paused);
    if (!_disposed) _matchingFeedback.add(feedback);
    return feedback;
  }

  void _pauseMatchingFeedback(MatchingGameFeedback feedback) {
    if (identical(feedback, _requestedMatchingFeedback)) _cancelEffects();
  }

  void _releaseMatchingFeedback(MatchingGameFeedback feedback) {
    _matchingFeedback.remove(feedback);
    _pauseMatchingFeedback(feedback);
  }

  double get _targetMusicVolume => !_effectPlaying
      ? musicVolume
      : _requestedCue == AppSoundCue.streak
      ? 0
      : duckedMusicVolume;

  /// Preferences settle before any sound plays. Startup never needs to await it.
  Future<void> initialize() => _initialization ??= _restorePreferences();

  Future<void> _restorePreferences() async {
    final musicRevision = _musicPreferenceRevision;
    final effectsRevision = _effectsPreferenceRevision;
    final restored = await Future.wait([
      _readSafely(_preferences.readMusicEnabled),
      _readSafely(_preferences.readEffectsEnabled),
    ]);
    if (_disposed) return;
    if (musicRevision == _musicPreferenceRevision && restored[0] != null) {
      _musicEnabled = restored[0]!;
    }
    if (effectsRevision == _effectsPreferenceRevision && restored[1] != null) {
      _effectsEnabled = restored[1]!;
    }
    _initialized = true;
    notifyListeners();
    _reconcileMusic();
  }

  Future<void> setMusicEnabled(bool enabled) async {
    if (_disposed) return;
    ++_musicPreferenceRevision;
    _musicEnabled = enabled;
    if (enabled) _headphonesRemoved = false;
    notifyListeners();
    _reconcileMusic(force: true);
    if (!enabled && !_effectsEnabled) {
      unawaited(_quietly(() => _session.release(deactivate: true)));
    }
    // Serialize independent settings so rapid toggles cannot persist old values.
    _musicWrites = _musicWrites.then(
      (_) => _quietly(() => _preferences.writeMusicEnabled(enabled)),
    );
    await _musicWrites;
  }

  Future<void> setEffectsEnabled(bool enabled) async {
    if (_disposed) return;
    ++_effectsPreferenceRevision;
    _effectsEnabled = enabled;
    if (enabled) _headphonesRemoved = false;
    notifyListeners();
    _cancelEffects();
    if (!enabled && !_musicEnabled) {
      unawaited(_quietly(() => _session.release(deactivate: true)));
    }
    _effectsWrites = _effectsWrites.then(
      (_) => _quietly(() => _preferences.writeEffectsEnabled(enabled)),
    );
    await _effectsWrites;
  }

  /// Unnamed routes (including voice sample sheets) conservatively stay silent.
  void setRoute(String? route) {
    if (_disposed || _route == route) return;
    final wasMusicRoute = _musicRoutes.contains(_route);
    final leavingStreak = _route == '/streak' && route != '/streak';
    if (leavingStreak) _streakCueRequested = false;
    _route = route;
    final isMusicRoute = _musicRoutes.contains(route);
    // Navigation taps may finish while moving between ordinary screens. A
    // media/splash/unknown route immediately cancels any pending or active cue.
    if (!wasMusicRoute || !isMusicRoute || leavingStreak) _cancelEffects();
    _reconcileMusic();
    if (!isMusicRoute) {
      _interrupted = false;
      unawaited(_quietly(_session.release));
    }
  }

  void setForeground(bool foreground) {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    _cancelEffects();
    if (foreground) {
      _headphonesRemoved = false;
      _interrupted = false;
    }
    _reconcileMusic(force: true);
    if (!foreground) {
      unawaited(_quietly(() => _session.release(deactivate: true)));
    }
  }

  void _onFocusEvent(AppAudioFocusEvent event) {
    if (_disposed || !_foreground) return;
    // Session events from narration/gameplay must not restart app music.
    if (!_musicRoutes.contains(_route) &&
        !(_route == '/games/play' && _matchingFeedback.isNotEmpty)) {
      return;
    }
    switch (event) {
      case AppAudioFocusEvent.interrupted:
        _interrupted = true;
      case AppAudioFocusEvent.resumed:
        _interrupted = false;
      case AppAudioFocusEvent.headphonesRemoved:
        _headphonesRemoved = true;
    }
    _cancelEffects();
    _reconcileMusic(force: true);
  }

  void _reconcileMusic({bool force = false}) {
    if (_disposed) return;
    if (!_shouldPlayMusic) {
      ++_musicGeneration;
      _musicPlaying = false;
      _fadeTimer?.cancel();
      _fadeTimer = null;
      _currentMusicVolume = 0;
      unawaited(_quietly(_music.pause));
      return;
    }
    if (_musicPlaying && !force) return;
    final generation = ++_musicGeneration;
    _musicQueue = _musicQueue.then((_) async {
      bool valid() => generation == _musicGeneration && _shouldPlayMusic;
      if (!valid()) return;
      try {
        if (!await _session.activate(valid) || !valid()) return;
        if (!_musicPrepared) {
          await _music.load(musicAsset, loop: true);
          if (_disposed) return;
          _musicPrepared = true;
        }
        if (!valid()) return;
        await _music.setVolume(0);
        if (!valid()) return;
        await _music.play();
        if (!valid()) {
          await _quietly(_music.pause);
          return;
        }
        _musicPlaying = true;
        _currentMusicVolume = 0;
        _fadeTo(_targetMusicVolume);
      } catch (_) {
        // Audio is optional; another foreground transition can retry a load.
        _musicPrepared = false;
        _musicPlaying = false;
      }
    });
  }

  void playEffect(AppSoundCue cue) => _playEffect(cue);

  void _playEffect(AppSoundCue cue, {MatchingGameFeedback? matchingFeedback}) {
    if (_disposed ||
        !approvedEffects.contains(cue) ||
        !_effectsEnabled ||
        !_foreground) {
      return;
    }
    if (matchingFeedback != null &&
        (_route != '/games/play' ||
            !_matchingEffects.contains(cue) ||
            !_matchingFeedback.contains(matchingFeedback) ||
            !matchingFeedback._canRequest)) {
      return;
    }
    if (cue == AppSoundCue.streak &&
        (_route != '/streak' || _streakCueRequested)) {
      return;
    }
    _cancelEffects();
    _requestedCue = cue;
    _requestedMatchingFeedback = matchingFeedback;
    if (cue == AppSoundCue.streak) _streakCueRequested = true;
    final generation = _effectsGeneration;
    _effectsQueue = _effectsQueue.then((_) async {
      await initialize();
      bool valid() =>
          generation == _effectsGeneration &&
          _canPlayEffect(cue, matchingFeedback: matchingFeedback);
      if (!valid()) return;
      try {
        if (!await _session.activate(valid) || !valid()) return;
        await _effects.load(cue.assetPath, loop: false);
        if (!valid()) return;
        await _effects.setVolume(effectsVolume);
        if (!valid()) return;
        await _effects.play();
        if (!valid()) {
          await _quietly(_effects.pause);
          return;
        }
        _effectPlaying = true;
        _fadeTo(_targetMusicVolume);
        _duckTimer = Timer(cue.duration, () {
          if (_disposed || generation != _effectsGeneration) return;
          _effectPlaying = false;
          _requestedCue = null;
          _requestedMatchingFeedback = null;
          if (cue == AppSoundCue.streak) {
            unawaited(_quietly(_effects.pause));
          }
          _fadeTo(musicVolume);
        });
      } catch (_) {
        // Missing plugins, assets or audio focus do not interrupt actions.
      }
    });
  }

  void _cancelEffects() {
    ++_effectsGeneration;
    _duckTimer?.cancel();
    _duckTimer = null;
    _effectPlaying = false;
    _requestedCue = null;
    _requestedMatchingFeedback = null;
    unawaited(_quietly(_effects.pause));
    _fadeTo(musicVolume);
  }

  void _fadeTo(double target) {
    _fadeTimer?.cancel();
    if (!_musicPlaying || !_shouldPlayMusic) return;
    final start = _currentMusicVolume;
    var step = 0;
    _fadeTimer = Timer.periodic(const Duration(milliseconds: 25), (timer) {
      if (_disposed || !_musicPlaying || !_shouldPlayMusic) {
        timer.cancel();
        return;
      }
      ++step;
      _currentMusicVolume = start + (target - start) * (step / 10);
      unawaited(_quietly(() => _music.setVolume(_currentMusicVolume)));
      if (step >= 10) timer.cancel();
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final feedback in _matchingFeedback) {
      feedback._disposed = true;
    }
    _matchingFeedback.clear();
    ++_musicGeneration;
    ++_effectsGeneration;
    _fadeTimer?.cancel();
    _duckTimer?.cancel();
    unawaited(_focusSubscription.cancel());
    unawaited(_quietly(_music.dispose));
    unawaited(_quietly(_effects.dispose));
    unawaited(_quietly(_session.dispose));
    super.dispose();
  }

  static Future<bool?> _readSafely(Future<bool?> Function() read) async {
    try {
      return await read();
    } catch (_) {
      return null;
    }
  }

  static Future<void> _quietly(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // Device-wide sound is an optional enhancement, never an app dependency.
    }
  }
}

/// Scoped feedback for a matching game that owns no separate audio player.
/// Only the approved tap, select and success cues can play, and only while the
/// matching engine is active on the gameplay route. Resuming never replays cues.
class MatchingGameFeedback {
  MatchingGameFeedback._(this._controller, {required bool paused})
    : _paused = paused;

  final AppAudioController _controller;
  bool _paused;
  bool _disposed = false;

  bool get _canRequest => !_disposed && !_paused;

  void play(AppSoundCue cue) {
    if (!_canRequest) return;
    _controller._playEffect(cue, matchingFeedback: this);
  }

  void setPaused(bool paused) {
    if (_disposed || _paused == paused) return;
    _paused = paused;
    if (paused) _controller._pauseMatchingFeedback(this);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _controller._releaseMatchingFeedback(this);
  }
}

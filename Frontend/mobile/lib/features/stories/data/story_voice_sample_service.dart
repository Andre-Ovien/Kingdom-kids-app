import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

typedef VoiceSampleErrorCallback = void Function(String message);

/// Plays the short, hosted character samples returned by the story API.
///
/// This deliberately lives beside, rather than inside, device narration. A
/// preview never changes the selected reader or the read-along TTS progress.
abstract interface class StoryVoiceSampleService {
  void setCallbacks({
    VoidCallback? onStarted,
    VoidCallback? onCompleted,
    VoiceSampleErrorCallback? onError,
  });

  Future<void> play({required String sampleUrl});

  Future<void> stop();

  Future<void> dispose();
}

/// A single-player implementation so two character previews cannot overlap.
class HostedStoryVoiceSampleService implements StoryVoiceSampleService {
  HostedStoryVoiceSampleService({AudioPlayer? audioPlayer})
    : _player = audioPlayer ?? AudioPlayer() {
    _stateSubscription = _player.playerStateStream.listen(_handlePlayerState);
    _errorSubscription = _player.errorStream.listen(_handlePlayerError);
  }

  final AudioPlayer _player;
  late final StreamSubscription<PlayerState> _stateSubscription;
  late final StreamSubscription<PlayerException> _errorSubscription;

  VoidCallback? _onStarted;
  VoidCallback? _onCompleted;
  VoiceSampleErrorCallback? _onError;
  bool _startedReported = false;
  bool _completedReported = false;
  bool _errorReported = false;
  bool _disposed = false;

  @override
  void setCallbacks({
    VoidCallback? onStarted,
    VoidCallback? onCompleted,
    VoiceSampleErrorCallback? onError,
  }) {
    _onStarted = onStarted;
    _onCompleted = onCompleted;
    _onError = onError;
  }

  @override
  Future<void> play({required String sampleUrl}) async {
    if (_disposed) return;
    final uri = Uri.tryParse(sampleUrl);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('Voice preview URL is invalid.');
    }

    _startedReported = false;
    _completedReported = false;
    _errorReported = false;
    await _player.stop();
    await _player.setUrl(sampleUrl);
    unawaited(_playPreparedSample());
  }

  Future<void> _playPreparedSample() async {
    try {
      await _player.play();
    } on PlayerException catch (error) {
      _handlePlayerError(error);
    } catch (_) {
      _reportPlaybackError();
    }
  }

  void _handlePlayerState(PlayerState state) {
    if (_disposed) return;
    if (state.playing && !_startedReported) {
      _startedReported = true;
      _onStarted?.call();
    }
    if (state.processingState == ProcessingState.completed &&
        !_completedReported) {
      _completedReported = true;
      _startedReported = false;
      _onCompleted?.call();
    }
  }

  void _handlePlayerError(PlayerException error) {
    _reportPlaybackError();
  }

  void _reportPlaybackError() {
    if (_disposed || _errorReported) return;
    _errorReported = true;
    _startedReported = false;
    _completedReported = true;
    _onError?.call(
      'This voice preview could not play. Check your connection and try again.',
    );
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    _startedReported = false;
    _completedReported = true;
    _errorReported = true;
    await _player.stop();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _onStarted = null;
    _onCompleted = null;
    _onError = null;
    await _stateSubscription.cancel();
    await _errorSubscription.cancel();
    await _player.dispose();
  }
}

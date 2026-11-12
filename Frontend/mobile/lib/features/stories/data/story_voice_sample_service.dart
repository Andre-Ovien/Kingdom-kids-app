import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/config/app_config.dart';
import '../../../core/media/content_media_fetcher.dart';
import 'story_narration_service.dart';

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
  HostedStoryVoiceSampleService({
    AudioPlayer? audioPlayer,
    ContentMediaPolicy mediaPolicy = AppConfig.contentMediaPolicy,
    ContentMediaFetcher? mediaFetcher,
    StoryAudioCacheScopeResolver? cacheScopeResolver,
    Future<void> Function()? scopeValidator,
    ScopedStoryAudioCache? audioCache,
  }) : _player = audioPlayer ?? AudioPlayer(),
       _mediaPolicy = mediaPolicy,
       _cacheScopeResolver = cacheScopeResolver,
       _scopeValidator = scopeValidator,
       _audioCache = audioCache ?? _voiceSampleAudioCache {
    if (mediaFetcher != null) {
      _mediaFetcher = mediaFetcher;
    } else {
      final owned = HttpContentMediaFetcher(policy: mediaPolicy);
      _ownedMediaFetcher = owned;
      _mediaFetcher = owned;
    }
    _stateSubscription = _player.playerStateStream.listen(_handlePlayerState);
    _errorSubscription = _player.errorStream.listen(_handlePlayerError);
  }

  final AudioPlayer _player;
  final ContentMediaPolicy _mediaPolicy;
  final StoryAudioCacheScopeResolver? _cacheScopeResolver;
  final Future<void> Function()? _scopeValidator;
  final ScopedStoryAudioCache _audioCache;
  late final ContentMediaFetcher _mediaFetcher;
  HttpContentMediaFetcher? _ownedMediaFetcher;
  late final StreamSubscription<PlayerState> _stateSubscription;
  late final StreamSubscription<PlayerException> _errorSubscription;

  VoidCallback? _onStarted;
  VoidCallback? _onCompleted;
  VoiceSampleErrorCallback? _onError;
  bool _startedReported = false;
  bool _completedReported = false;
  bool _errorReported = false;
  bool _disposed = false;
  int _playRequestId = 0;
  Directory? _preparedSampleDirectory;

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
    final requestId = ++_playRequestId;

    _startedReported = false;
    _completedReported = false;
    _errorReported = false;

    try {
      await _player.stop();
      await _deletePreparedSample();
      final media = await _audioCache.fetch(
        source: sampleUrl,
        policy: _mediaPolicy,
        fetcher: _mediaFetcher,
        scopeResolver: _cacheScopeResolver,
        scopeValidator: _scopeValidator,
      );
      if (_disposed || requestId != _playRequestId) return;
      final directory = await Directory.systemTemp.createTemp(
        'kingdom_kids_voice_',
      );
      final sampleFile = File(
        '${directory.path}/sample${_audioExtension(media.contentType)}',
      );
      await sampleFile.writeAsBytes(media.bytes, flush: true);
      if (_disposed || requestId != _playRequestId) {
        await _deleteDirectory(directory);
        return;
      }
      _preparedSampleDirectory = directory;
      await _player.setFilePath(sampleFile.path);
      if (_disposed || requestId != _playRequestId) return;
      await _scopeValidator?.call();
      if (_disposed || requestId != _playRequestId) return;
      unawaited(_playPreparedSample(requestId));
    } on PlayerException catch (error) {
      if (requestId == _playRequestId) _handlePlayerError(error);
    } catch (_) {
      if (requestId == _playRequestId) {
        _reportPlaybackError();
        unawaited(_deletePreparedSample());
      }
    }
  }

  Future<void> _playPreparedSample(int requestId) async {
    if (_disposed || requestId != _playRequestId) return;
    try {
      await _player.play();
    } on PlayerException catch (error) {
      if (requestId == _playRequestId) _handlePlayerError(error);
    } catch (_) {
      if (requestId == _playRequestId) _reportPlaybackError();
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
      unawaited(_deletePreparedSample());
    }
  }

  void _handlePlayerError(PlayerException error) {
    _reportPlaybackError();
    unawaited(_deletePreparedSample());
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
    _playRequestId += 1;
    _startedReported = false;
    _completedReported = true;
    _errorReported = true;
    await _player.stop();
    await _deletePreparedSample();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _playRequestId += 1;
    _onStarted = null;
    _onCompleted = null;
    _onError = null;
    await _stateSubscription.cancel();
    await _errorSubscription.cancel();
    _ownedMediaFetcher?.close();
    await _player.dispose();
    await _deletePreparedSample();
  }

  Future<void> _deletePreparedSample() async {
    final directory = _preparedSampleDirectory;
    _preparedSampleDirectory = null;
    if (directory != null) await _deleteDirectory(directory);
  }
}

final _voiceSampleAudioCache = ScopedStoryAudioCache(maxBytes: 8 * 1024 * 1024);

String _audioExtension(String? contentType) {
  return switch (contentType) {
    'audio/mp4' || 'audio/x-m4a' => '.m4a',
    'audio/ogg' => '.ogg',
    'audio/wav' || 'audio/x-wav' => '.wav',
    _ => '.mp3',
  };
}

Future<void> _deleteDirectory(Directory directory) async {
  try {
    if (await directory.exists()) await directory.delete(recursive: true);
  } on FileSystemException {
    // The operating system also reclaims app temp storage. Cleanup failure
    // must not turn a completed or cancelled preview into a user-facing error.
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/config/app_config.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/media/content_media_fetcher.dart';
import '../domain/story_detail.dart';

typedef NarrationErrorCallback = void Function(String message);
typedef NarrationProgressCallback =
    void Function(String text, int startOffset, int endOffset, String word);
typedef NarrationPassageCallback =
    void Function(String text, int startOffset, int endOffset);
typedef NarrationPositionCallback =
    void Function(Duration position, Duration? duration);
typedef NarrationWordCallback = void Function(StoryNarrationSegment? word);

abstract interface class StoryNarrationService {
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
  });

  Future<void> speak({
    required String text,
    required StoryNarration narration,
    String? fullText,
    int startOffset = 0,
    bool resume = false,
  });

  Future<void> pause();

  Future<void> stop();

  Future<void> dispose();
}

/// Selects the backend-declared narration mode. A failed hosted character track
/// remains a playback error rather than silently substituting a device voice.
class CharacterStoryNarrationService implements StoryNarrationService {
  CharacterStoryNarrationService({
    StoryNarrationService? deviceService,
    StoryNarrationService? hostedService,
  }) : _device = deviceService ?? DeviceStoryNarrationService(),
       _hosted = hostedService ?? HostedStoryNarrationService();

  final StoryNarrationService _device;
  final StoryNarrationService _hosted;
  StoryNarrationService? _active;
  _NarrationCallbacks _callbacks = const _NarrationCallbacks();
  int _requestId = 0;

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
    _callbacks = _NarrationCallbacks(
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
    final active = _active;
    if (active != null) _callbacks.bind(active);
  }

  @override
  Future<void> speak({
    required String text,
    required StoryNarration narration,
    String? fullText,
    int startOffset = 0,
    bool resume = false,
  }) async {
    final requestId = ++_requestId;
    final StoryNarrationService next;
    switch (narration.status.trim().toLowerCase()) {
      case 'device_tts':
        next = _device;
      case 'ready' when narration.audioAvailable && narration.audioUrl != null:
        next = _hosted;
      default:
        throw const AppException(
          'This character’s reading voice is not ready yet.',
        );
    }
    final previous = _active;
    if (previous != null && previous != next) {
      previous.setCallbacks();
      await previous.stop();
    }
    if (requestId != _requestId) return;
    _active = next;
    _callbacks.bind(next);
    await next.speak(
      text: text,
      narration: narration,
      fullText: fullText,
      startOffset: startOffset,
      resume: resume,
    );
  }

  @override
  Future<void> pause() async => _active?.pause();

  @override
  Future<void> stop() async {
    _requestId++;
    await _active?.stop();
  }

  @override
  Future<void> dispose() async {
    _requestId++;
    await Future.wait([_device.dispose(), _hosted.dispose()]);
  }
}

/// Downloads media through the validated redirect-aware fetcher, then gives
/// just_audio a local file. Measured passage cues support seeking and highlight
/// the current passage; only passages actually heard count toward completion.
class HostedStoryNarrationService implements StoryNarrationService {
  HostedStoryNarrationService({
    AudioPlayer? audioPlayer,
    ContentMediaPolicy mediaPolicy = AppConfig.contentMediaPolicy,
    ContentMediaFetcher? mediaFetcher,
  }) : _player = audioPlayer ?? AudioPlayer(),
       _mediaPolicy = mediaPolicy {
    _positionUpdates = _player.createPositionStream(
      minPeriod: const Duration(milliseconds: 50),
      maxPeriod: const Duration(milliseconds: 50),
    );
    if (mediaFetcher != null) {
      _mediaFetcher = mediaFetcher;
    } else {
      final owned = HttpContentMediaFetcher(
        policy: mediaPolicy,
        maxBytes: 32 * 1024 * 1024,
      );
      _ownedMediaFetcher = owned;
      _mediaFetcher = owned;
    }
  }

  final AudioPlayer _player;
  late final Stream<Duration> _positionUpdates;
  final ContentMediaPolicy _mediaPolicy;
  late final ContentMediaFetcher _mediaFetcher;
  HttpContentMediaFetcher? _ownedMediaFetcher;
  StreamSubscription<PlayerState>? _stateSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<PlayerException>? _errorSubscription;
  _NarrationCallbacks _callbacks = const _NarrationCallbacks();
  Directory? _preparedDirectory;
  String? _preparedPath;
  String? _preparedUrl;
  Duration? _trackDuration;
  String _fullText = '';
  List<StoryNarrationSegment> _segments = const [];
  List<StoryNarrationSegment> _words = const [];
  final Set<int> _reportedSegments = {};
  Duration _heardFrom = Duration.zero;
  Duration _heardThrough = Duration.zero;
  int _highlightedSegment = -1;
  int _highlightedWord = -2;
  Duration _lastPosition = Duration.zero;
  int _requestId = 0;
  bool _active = false;
  bool _paused = false;
  bool _startedReported = false;
  bool _clockRunning = false;
  bool _disposed = false;

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
    _callbacks = _NarrationCallbacks(
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

  @override
  Future<void> speak({
    required String text,
    required StoryNarration narration,
    String? fullText,
    int startOffset = 0,
    bool resume = false,
  }) async {
    if (_disposed) return;
    final body = fullText ?? text;
    final source = _mediaPolicy.sanitize(narration.audioUrl);
    if (narration.status.trim().toLowerCase() != 'ready' ||
        !narration.audioAvailable ||
        source == null) {
      throw const AppException(
        'This character’s reading voice is not ready yet.',
      );
    }
    if (body.trim().isEmpty || startOffset < 0 || startOffset >= body.length) {
      throw const AppException('This story does not have narration text yet.');
    }
    final shouldResume =
        resume && _paused && _preparedUrl == source && _fullText == body;
    final requestId = ++_requestId;
    _active = false;
    _startedReported = false;
    _clockRunning = false;
    await _detachSubscriptions();
    try {
      if (!shouldResume) {
        _paused = false;
        await _player.stop();
        if (!_isCurrent(requestId)) return;
        await _prepareSource(source, requestId);
        if (!_isCurrent(requestId)) return;
        _fullText = body;
        _segments = _boundedCues(narration.segmentsForText(body));
        _words = _boundedCues(narration.wordsForText(body));
        final seekPosition = _positionForOffset(startOffset);
        await _player.seek(seekPosition);
        if (!_isCurrent(requestId)) return;
        _heardFrom = seekPosition;
        _heardThrough = seekPosition;
        _lastPosition = seekPosition;
        _reportedSegments.clear();
      }
      if (!_isCurrent(requestId)) return;
      _paused = false;
      _highlightedSegment = -1;
      _highlightedWord = -2;
      _active = true;
      _attachSubscriptions(requestId);
      unawaited(_playPrepared(requestId));
    } on AppException {
      if (_isCurrent(requestId)) _active = false;
      rethrow;
    } catch (_) {
      if (!_isCurrent(requestId)) return;
      _active = false;
      throw const AppException(
        'This character’s story audio could not play. Check your connection and try again.',
      );
    }
  }

  List<StoryNarrationSegment> _boundedCues(List<StoryNarrationSegment> cues) {
    final duration = _trackDuration;
    if (duration == null) return cues;
    if (cues.any(
      (cue) =>
          cue.startTime >= duration ||
          cue.endTime > duration + const Duration(milliseconds: 50),
    )) {
      return const [];
    }
    // Preserve measured offsets while accepting a small decoder padding tail.
    return [
      for (final cue in cues)
        if (cue.endTime > duration)
          StoryNarrationSegment(
            text: cue.text,
            startOffset: cue.startOffset,
            endOffset: cue.endOffset,
            startTime: cue.startTime,
            endTime: duration,
          )
        else
          cue,
    ];
  }

  Future<void> _prepareSource(String source, int requestId) async {
    if (_preparedUrl == source && _preparedPath != null) {
      _trackDuration = await _player.setFilePath(_preparedPath!);
      return;
    }
    await _deletePreparedSource();
    final media = await _mediaFetcher.fetch(source);
    if (!_isCurrent(requestId)) return;
    final directory = await Directory.systemTemp.createTemp(
      'kingdom_kids_story_',
    );
    final file = File(
      '${directory.path}/story${_audioExtension(media.contentType)}',
    );
    try {
      await file.writeAsBytes(media.bytes, flush: true);
    } catch (_) {
      await _deleteDirectory(directory);
      rethrow;
    }
    if (!_isCurrent(requestId)) {
      await _deleteDirectory(directory);
      return;
    }
    _preparedDirectory = directory;
    _preparedPath = file.path;
    _preparedUrl = source;
    _trackDuration = await _player.setFilePath(file.path);
  }

  Duration _positionForOffset(int offset) {
    if (offset == 0) return Duration.zero;
    for (final segment in _segments) {
      if (segment.endOffset > offset) return segment.startTime;
    }
    if (_segments.isEmpty) {
      // With no measured cues, only the beginning or the actual paused player
      // position is meaningful. Never guess a seek time from the text length.
      return Duration.zero;
    }
    return _segments.last.startTime;
  }

  void _attachSubscriptions(int requestId) {
    _stateSubscription = _player.playerStateStream.listen((state) {
      if (!_isCurrent(requestId) || !_active) return;
      _clockRunning =
          state.playing && state.processingState == ProcessingState.ready;
      if (_clockRunning && !_startedReported) {
        _startedReported = true;
        _callbacks.onStarted?.call();
      }
      if (_clockRunning && _startedReported) {
        _updatePosition(_player.position);
      }
      if (state.processingState == ProcessingState.completed &&
          _startedReported) {
        _updatePosition(_trackDuration ?? _player.position);
        if (_segments.isEmpty && _heardFrom == Duration.zero) {
          _callbacks.onProgress?.call(_fullText, 0, _fullText.length, '');
        }
        _active = false;
        _paused = false;
        _clockRunning = false;
        _callbacks.onCompleted?.call();
      }
    });
    _positionSubscription = _positionUpdates.listen((position) {
      if (_isCurrent(requestId) && _clockRunning) _updatePosition(position);
    });
    _durationSubscription = _player.durationStream.listen((duration) {
      if (!_isCurrent(requestId) || !_active || duration == null) return;
      _trackDuration = duration;
      _segments = _boundedCues(_segments);
      _words = _boundedCues(_words);
      if (_startedReported) {
        _callbacks.onPosition?.call(_lastPosition, duration);
      }
    });
    _errorSubscription = _player.errorStream.listen((_) {
      if (_isCurrent(requestId)) _reportError();
    });
  }

  Future<void> _playPrepared(int requestId) async {
    try {
      await _player.play();
    } catch (_) {
      if (_isCurrent(requestId)) _reportError();
    }
  }

  void _updatePosition(Duration position) {
    if (!_active || !_startedReported) return;
    if (position < Duration.zero) position = Duration.zero;
    final duration = _trackDuration;
    if (duration != null && position > duration) position = duration;
    _lastPosition = position;
    _callbacks.onPosition?.call(position, duration);
    if (position < _heardFrom) return;
    if (position > _heardThrough) _heardThrough = position;
    for (var index = 0; index < _segments.length; index++) {
      final segment = _segments[index];
      if (segment.startTime >= _heardFrom &&
          segment.endTime <= _heardThrough &&
          _reportedSegments.add(index)) {
        _callbacks.onProgress?.call(
          _fullText,
          segment.startOffset,
          segment.endOffset,
          '',
        );
      }
      if (position >= segment.startTime &&
          position < segment.endTime &&
          _highlightedSegment != index) {
        _highlightedSegment = index;
        _callbacks.onPassage?.call(
          _fullText,
          segment.startOffset,
          segment.endOffset,
        );
      }
    }
    // Focus the paragraph first so its cursor cannot replace the spoken word.
    var wordIndex = -1;
    for (var index = 0; index < _words.length; index++) {
      final word = _words[index];
      if (position >= word.startTime && position < word.endTime) {
        wordIndex = index;
        break;
      }
    }
    if (_highlightedWord != wordIndex) {
      _highlightedWord = wordIndex;
      _callbacks.onWord?.call(wordIndex < 0 ? null : _words[wordIndex]);
    }
  }

  void _reportError() {
    if (!_active || _disposed) return;
    _active = false;
    _paused = false;
    _callbacks.onError?.call(
      'This character’s story audio could not play. Check your connection and try again.',
    );
  }

  bool _isCurrent(int requestId) => !_disposed && requestId == _requestId;

  @override
  Future<void> pause() async {
    if (_disposed || !_active) return;
    _updatePosition(_player.position);
    final wasRunning = _clockRunning;
    final requestId = ++_requestId;
    _active = false;
    _clockRunning = false;
    await _detachSubscriptions();
    try {
      await _player.pause();
      if (!_isCurrent(requestId)) return;
      // Report the native position once the pause has actually settled.
      _active = true;
      _updatePosition(_player.position);
      _active = false;
      _paused = true;
      _callbacks.onPaused?.call();
    } catch (_) {
      _paused = false;
      if (_isCurrent(requestId)) {
        // A native pause failure can leave audio playing. Keep observing that
        // same run so a retry, stop, or genuine completion still works.
        _active = true;
        _clockRunning = wasRunning;
        _attachSubscriptions(requestId);
      }
      throw const AppException('Narration could not be paused.');
    }
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    final requestId = ++_requestId;
    _active = false;
    _paused = false;
    _clockRunning = false;
    await _detachSubscriptions();
    try {
      await _player.stop();
      if (_isCurrent(requestId)) _callbacks.onCancelled?.call();
    } catch (_) {
      throw const AppException('Narration could not be stopped.');
    }
  }

  Future<void> _detachSubscriptions() async {
    final state = _stateSubscription;
    final position = _positionSubscription;
    final duration = _durationSubscription;
    final error = _errorSubscription;
    _stateSubscription = null;
    _positionSubscription = null;
    _durationSubscription = null;
    _errorSubscription = null;
    await Future.wait([
      if (state != null) state.cancel(),
      if (position != null) position.cancel(),
      if (duration != null) duration.cancel(),
      if (error != null) error.cancel(),
    ]);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _requestId++;
    _active = false;
    _callbacks = const _NarrationCallbacks();
    await _detachSubscriptions();
    _ownedMediaFetcher?.close();
    try {
      await _player.dispose();
    } finally {
      await _deletePreparedSource();
    }
  }

  Future<void> _deletePreparedSource() async {
    final directory = _preparedDirectory;
    _preparedDirectory = null;
    _preparedPath = null;
    _preparedUrl = null;
    _trackDuration = null;
    if (directory != null) await _deleteDirectory(directory);
  }
}

class _NarrationCallbacks {
  const _NarrationCallbacks({
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

  void bind(StoryNarrationService service) => service.setCallbacks(
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

String _audioExtension(String? contentType) => switch (contentType) {
  'audio/mp4' || 'audio/x-m4a' => '.m4a',
  'audio/ogg' => '.ogg',
  'audio/wav' || 'audio/x-wav' => '.wav',
  _ => '.mp3',
};

Future<void> _deleteDirectory(Directory directory) async {
  try {
    if (await directory.exists()) await directory.delete(recursive: true);
  } on FileSystemException {
    // Temp cleanup must not turn a completed or cancelled read into an error.
  }
}

/// Uses the best suitable English voice already installed on the device, then
/// applies the narrator's backend-controlled reading pace and pitch.
///
/// Device voice inventories vary. Multiple narrators can therefore share the
/// same installed voice; the service never assumes that three distinct voices
/// are available.
class DeviceStoryNarrationService implements StoryNarrationService {
  DeviceStoryNarrationService({FlutterTts? flutterTts})
    : _flutterTts = flutterTts ?? FlutterTts();

  final FlutterTts _flutterTts;
  Future<_DeviceVoiceCatalog>? _voiceCatalog;
  bool _callbacksBound = false;

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
    _flutterTts.setStartHandler(() => onStarted?.call());
    _flutterTts.setCompletionHandler(() => onCompleted?.call());
    _flutterTts.setPauseHandler(() => onPaused?.call());
    _flutterTts.setCancelHandler(() => onCancelled?.call());
    _flutterTts.setErrorHandler(
      (_) => onError?.call(
        'This voice stopped unexpectedly. Tap play when you’re ready to try again.',
      ),
    );
    _flutterTts.setProgressHandler(
      (text, startOffset, endOffset, word) =>
          onProgress?.call(text, startOffset, endOffset, word),
    );
    _callbacksBound = true;
  }

  @override
  Future<void> speak({
    required String text,
    required StoryNarration narration,
    String? fullText,
    int startOffset = 0,
    bool resume = false,
  }) async {
    final readableText = text.trim();
    if (readableText.isEmpty) {
      throw const AppException('This story does not have narration text yet.');
    }
    if (!_callbacksBound) {
      setCallbacks();
    }

    try {
      await _flutterTts.awaitSpeakCompletion(false);
      await _flutterTts.setVolume(1);
      await _flutterTts.setSpeechRate(narration.speechRate.clamp(0.1, 1));
      await _flutterTts.setPitch(narration.pitch.clamp(0.5, 2));
      await _selectInstalledVoice(narration);
      final result = await _flutterTts.speak(readableText, focus: true);
      if (result != 1) {
        throw const AppException(
          'Narration could not start on this device. Try another installed voice.',
        );
      }
    } on AppException {
      rethrow;
    } catch (_) {
      throw const AppException(
        'Narration is not available on this device right now.',
      );
    }
  }

  Future<void> _selectInstalledVoice(StoryNarration narration) async {
    final catalog = await (_voiceCatalog ??= _loadVoiceCatalog());
    final rankedVoices = catalog.rankedFor(narration.locale);
    if (rankedVoices.isEmpty) {
      if (catalog.hasUnsafeEnglishVoice) {
        throw const AppException(
          'Install an offline English reading voice to use narration.',
        );
      }
      await _setFirstAvailableLanguage(_preferredLocales(narration.locale));
      return;
    }

    for (final voice in rankedVoices) {
      final languageResult = await _flutterTts.setLanguage(voice.locale);
      if (_platformRejected(languageResult)) {
        continue;
      }

      final voiceResult = await _flutterTts.setVoice(voice.platformArguments);
      if (_platformRejected(voiceResult)) {
        // setLanguage selects the platform's default voice for this locale.
        // Retain that safe fallback rather than leaking a stale prior voice or
        // preventing narration because one advertised identifier disappeared.
        final fallbackResult = await _flutterTts.setLanguage(voice.locale);
        if (_platformRejected(fallbackResult)) {
          continue;
        }
      }
      return;
    }

    throw const AppException(
      'Narration is not available for an installed English voice.',
    );
  }

  Future<_DeviceVoiceCatalog> _loadVoiceCatalog() async {
    Object? rawVoices;
    try {
      rawVoices = await _flutterTts.getVoices;
    } catch (_) {
      return const _DeviceVoiceCatalog();
    }
    return _DeviceVoiceCatalog.fromPlatform(rawVoices);
  }

  Future<void> _setFirstAvailableLanguage(List<String> locales) async {
    for (final locale in locales) {
      final result = await _flutterTts.setLanguage(locale);
      if (!_platformRejected(result)) return;
    }
    throw const AppException(
      'Narration is not available for an installed English voice.',
    );
  }

  bool _platformRejected(Object? result) =>
      result == false ||
      (result is num && result <= 0) ||
      (result is String &&
          const {'0', 'false', 'failed'}.contains(result.trim().toLowerCase()));

  @override
  Future<void> pause() async {
    try {
      final result = await _flutterTts.pause();
      if (_platformRejected(result)) {
        throw const AppException('Narration could not be paused.');
      }
    } on AppException {
      rethrow;
    } catch (_) {
      throw const AppException('Narration could not be paused.');
    }
  }

  @override
  Future<void> stop() async {
    try {
      final result = await _flutterTts.stop();
      if (_platformRejected(result)) {
        throw const AppException('Narration could not be stopped.');
      }
    } on AppException {
      rethrow;
    } catch (_) {
      throw const AppException('Narration could not be stopped.');
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await _flutterTts.stop();
    } catch (_) {
      // The platform channel may already be gone while the app is closing.
    }
  }
}

class _DeviceVoiceCatalog {
  const _DeviceVoiceCatalog({
    this.voices = const [],
    this.hasUnsafeEnglishVoice = false,
  });

  factory _DeviceVoiceCatalog.fromPlatform(Object? rawVoices) {
    if (rawVoices is! Iterable) {
      return const _DeviceVoiceCatalog();
    }

    final voices = <_DeviceVoice>[];
    var hasUnsafeEnglishVoice = false;
    for (final rawVoice in rawVoices) {
      if (rawVoice is! Map) continue;
      final voice = _DeviceVoice.fromPlatform(rawVoice);
      if (voice == null || voice.language != 'en') continue;
      if (!voice.isOfflineSuitable) {
        hasUnsafeEnglishVoice = true;
        continue;
      }
      voices.add(voice);
    }
    return _DeviceVoiceCatalog(
      voices: List<_DeviceVoice>.unmodifiable(voices),
      hasUnsafeEnglishVoice: hasUnsafeEnglishVoice,
    );
  }

  final List<_DeviceVoice> voices;
  final bool hasUnsafeEnglishVoice;

  List<_DeviceVoice> rankedFor(String requestedLocale) {
    final preferredLocales = _preferredLocales(requestedLocale);
    final ranked = [...voices]
      ..sort((left, right) {
        final localeComparison = _localeRank(
          left.locale,
          preferredLocales,
        ).compareTo(_localeRank(right.locale, preferredLocales));
        if (localeComparison != 0) return localeComparison;

        final offlineComparison = right.offlineConfidence.compareTo(
          left.offlineConfidence,
        );
        if (offlineComparison != 0) return offlineComparison;

        final qualityComparison = right.qualityScore.compareTo(
          left.qualityScore,
        );
        if (qualityComparison != 0) return qualityComparison;

        final latencyComparison = right.latencyScore.compareTo(
          left.latencyScore,
        );
        if (latencyComparison != 0) return latencyComparison;

        return left.stableKey.compareTo(right.stableKey);
      });
    return List<_DeviceVoice>.unmodifiable(ranked);
  }

  int _localeRank(String locale, List<String> preferredLocales) {
    final exactIndex = preferredLocales.indexOf(locale);
    return exactIndex >= 0 ? exactIndex : preferredLocales.length;
  }
}

class _DeviceVoice {
  const _DeviceVoice({
    required this.name,
    required this.identifier,
    required this.locale,
    required this.networkMetadataPresent,
    required this.qualityScore,
    required this.latencyScore,
  });

  static _DeviceVoice? fromPlatform(Map<dynamic, dynamic> rawVoice) {
    final metadata = <String, Object?>{};
    for (final entry in rawVoice.entries) {
      final key = entry.key?.toString().trim().toLowerCase() ?? '';
      if (key.isNotEmpty) metadata[key] = entry.value;
    }

    final locale = _normalizeLocale(_metadataText(metadata['locale']));
    final name = _metadataText(metadata['name']);
    final identifier = _metadataText(metadata['identifier']);
    if (locale.isEmpty || (name.isEmpty && identifier.isEmpty)) {
      return null;
    }

    final networkMetadataPresent = metadata.containsKey('network_required');
    final networkRequired = _metadataBool(metadata['network_required']);
    final notInstalled = _featureIsNotInstalled(metadata['features']);
    if (networkRequired || notInstalled) {
      return _DeviceVoice._unsafe(
        name: name,
        identifier: identifier,
        locale: locale,
        networkMetadataPresent: networkMetadataPresent,
      );
    }

    return _DeviceVoice(
      name: name,
      identifier: identifier,
      locale: locale,
      networkMetadataPresent: networkMetadataPresent,
      qualityScore: _qualityScore(metadata['quality']),
      latencyScore: _latencyScore(metadata['latency']),
    );
  }

  const _DeviceVoice._unsafe({
    required this.name,
    required this.identifier,
    required this.locale,
    required this.networkMetadataPresent,
  }) : qualityScore = -1,
       latencyScore = -1;

  final String name;
  final String identifier;
  final String locale;
  final bool networkMetadataPresent;
  final int qualityScore;
  final int latencyScore;

  String get language => locale.split('-').first.toLowerCase();
  bool get isOfflineSuitable => qualityScore >= 0;
  int get offlineConfidence => networkMetadataPresent ? 1 : 0;
  String get stableKey =>
      '${identifier.isEmpty ? name : identifier}|$name|$locale'.toLowerCase();

  Map<String, String> get platformArguments => {
    if (name.isNotEmpty) 'name': name,
    'locale': locale,
    if (identifier.isNotEmpty) 'identifier': identifier,
  };
}

List<String> _preferredLocales(String requestedLocale) {
  final preferred = <String>[];
  for (final locale in [requestedLocale, 'en-NG', 'en-GB', 'en-US']) {
    final normalized = _normalizeLocale(locale);
    if (normalized.isNotEmpty && !preferred.contains(normalized)) {
      preferred.add(normalized);
    }
  }
  return List<String>.unmodifiable(preferred);
}

String _normalizeLocale(String rawLocale) {
  final parts = rawLocale
      .trim()
      .replaceAll('_', '-')
      .split('-')
      .where((part) => part.trim().isNotEmpty)
      .map((part) => part.trim())
      .toList(growable: false);
  if (parts.isEmpty) return '';

  return [
    parts.first.toLowerCase(),
    for (final part in parts.skip(1))
      if (part.length == 4)
        '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}'
      else
        part.toUpperCase(),
  ].join('-');
}

String _metadataText(Object? value) {
  if (value == null) return '';
  if (value is Iterable) {
    return value.map((item) => item.toString()).join('\t').trim();
  }
  return value.toString().trim();
}

bool _metadataBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  return const {
    '1',
    'true',
    'yes',
    'required',
  }.contains(_metadataText(value).toLowerCase());
}

bool _featureIsNotInstalled(Object? value) {
  final normalized = _metadataText(
    value,
  ).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  return normalized.contains('notinstalled');
}

int _qualityScore(Object? value) {
  return switch (_normalizedMetadataLabel(value)) {
    'premium' || 'veryhigh' => 5,
    'enhanced' || 'high' => 4,
    'default' || 'normal' => 3,
    'low' => 2,
    'verylow' => 1,
    _ => 0,
  };
}

int _latencyScore(Object? value) {
  return switch (_normalizedMetadataLabel(value)) {
    'verylow' => 5,
    'low' => 4,
    'normal' => 3,
    'high' => 2,
    'veryhigh' => 1,
    _ => 0,
  };
}

String _normalizedMetadataLabel(Object? value) =>
    _metadataText(value).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

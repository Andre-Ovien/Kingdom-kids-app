import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/errors/app_exception.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/kid_profile.dart';
import '../../parental_controls/data/parental_controls_repository.dart';
import '../../parental_controls/domain/parent_settings.dart';
import '../../progress/data/progress_repository.dart';
import '../../progress/domain/story_activity_event.dart';
import '../data/story_narration_service.dart';
import '../domain/story_detail.dart';
import 'story_completion_view.dart';
import 'story_cover_image.dart';

typedef StoryProgressOperationIdFactory = String Function();

String newStoryProgressOperationId() {
  final random = math.Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-'
      '${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

/// A focused, child-friendly reading surface that follows device narration.
///
/// The regular story detail remains the place for unhurried reading. This
/// screen deliberately behaves more like a music lyrics view: the active
/// profile's chosen story buddy reads one large piece of text while the spoken
/// phrase stays in view.
class ReadAlongScreen extends StatefulWidget {
  const ReadAlongScreen({
    required this.story,
    super.key,
    this.narrationService,
    this.authRepository,
    this.settingsRepository,
    this.progressRepository,
    this.operationIdFactory = newStoryProgressOperationId,
  });

  final StoryDetail story;
  final StoryNarrationService? narrationService;
  final AuthRepository? authRepository;
  final ParentalControlsRepository? settingsRepository;
  final ProgressRepository? progressRepository;
  final StoryProgressOperationIdFactory operationIdFactory;

  @override
  State<ReadAlongScreen> createState() => _ReadAlongScreenState();
}

enum _PlaybackState { idle, playing, paused, completed }

class _ReadAlongScreenState extends State<ReadAlongScreen> {
  late final StoryNarrationService _narrationService;
  late final AuthRepository _authRepository;
  late final ParentalControlsRepository _settingsRepository;
  late final ProgressRepository _progressRepository;
  late final String _storyStartedOperationId;
  late final String _storyCompletedOperationId;
  final ScrollController _textController = ScrollController();
  final List<_NarratedRange> _narratedRanges = [];

  KidProfile? _activeProfile;
  StoryNarration? _selectedNarration;
  ParentSettings? _readerSettings;
  _PlaybackState _playback = _PlaybackState.idle;
  String? _settingsMessage;
  String? _playbackMessage;
  bool _settingsResolved = false;
  bool _settingsFailed = false;
  bool _narrationBusy = false;
  bool _ignoreCancellation = false;
  bool _completionPresented = false;
  bool _narrationIsActive = false;
  bool _storyStartedRecorded = false;
  bool _storyStartedRecording = false;
  bool _storyCompletedRecorded = false;
  bool _storyCompletedRecording = false;
  int _activeStart = 0;
  int _activeEnd = 0;
  int _cursorOffset = 0;
  int _spokenBaseOffset = 0;

  @override
  void initState() {
    super.initState();
    _narrationService =
        widget.narrationService ?? DeviceStoryNarrationService();
    _authRepository = widget.authRepository ?? AuthRepository();
    _settingsRepository =
        widget.settingsRepository ??
        RemoteParentalControlsRepository(authRepository: _authRepository);
    _progressRepository =
        widget.progressRepository ??
        RemoteProgressRepository(authRepository: _authRepository);
    _storyStartedOperationId = widget.operationIdFactory();
    _storyCompletedOperationId = widget.operationIdFactory();
    _bindNarrationCallbacks();
    unawaited(_loadReadingPreferences());
  }

  void _bindNarrationCallbacks() {
    _narrationService.setCallbacks(
      onStarted: _handleNarrationStarted,
      onCompleted: _handleNarrationCompleted,
      onPaused: () {
        _narrationIsActive = false;
        _setPlayback(_PlaybackState.paused);
      },
      onCancelled: () {
        _narrationIsActive = false;
        if (_ignoreCancellation) return;
        _setPlayback(_PlaybackState.idle);
      },
      onError: (message) {
        _narrationIsActive = false;
        if (!mounted) return;
        setState(() {
          _playback = _PlaybackState.idle;
          _playbackMessage = message;
        });
      },
      onProgress: _handleNarrationProgress,
    );
  }

  void _handleNarrationStarted() {
    _narrationIsActive = true;
    _setPlayback(_PlaybackState.playing);
    unawaited(_recordStoryStarted());
  }

  void _handleNarrationCompleted() {
    if (!mounted || _completionPresented || !_narrationIsActive) return;
    _narrationIsActive = false;
    if (!_hasTruthfulCompletionCoverage) {
      setState(() {
        _playback = _PlaybackState.idle;
        _activeStart = 0;
        _activeEnd = 0;
        _cursorOffset = 0;
        _spokenBaseOffset = 0;
        _playbackMessage =
            'A few parts are still waiting. Tap play to hear them from the beginning.';
      });
      _scrollTextTo(0);
      return;
    }
    final profile = _activeProfile;
    setState(() {
      _playback = _PlaybackState.completed;
      _activeStart = widget.story.body.length;
      _activeEnd = widget.story.body.length;
      _cursorOffset = widget.story.body.length;
      _completionPresented = profile != null;
    });
    unawaited(_recordStoryCompleted());
    if (profile == null) {
      _scrollTextTo(1);
      return;
    }
    unawaited(HapticFeedback.mediumImpact());
  }

  Future<void> _recordStoryStarted() async {
    final profileId = _activeProfile?.id.trim() ?? '';
    final storyId = widget.story.id.trim();
    if (_storyStartedRecorded ||
        _storyStartedRecording ||
        profileId.isEmpty ||
        storyId.isEmpty) {
      return;
    }

    _storyStartedRecording = true;
    try {
      await _progressRepository.recordStoryActivity(
        profileId: profileId,
        storyId: storyId,
        eventType: StoryActivityType.storyStarted,
        operationId: _storyStartedOperationId,
      );
      _storyStartedRecorded = true;
    } catch (_) {
      // Playback is the primary experience. A later native start callback can
      // retry this exact idempotent operation without interrupting the child.
    } finally {
      _storyStartedRecording = false;
    }
  }

  Future<void> _recordStoryCompleted() async {
    final profileId = _activeProfile?.id.trim() ?? '';
    final storyId = widget.story.id.trim();
    if (_storyCompletedRecorded ||
        _storyCompletedRecording ||
        profileId.isEmpty ||
        storyId.isEmpty) {
      return;
    }

    _storyCompletedRecording = true;
    try {
      await _progressRepository.recordStoryActivity(
        profileId: profileId,
        storyId: storyId,
        eventType: StoryActivityType.storyCompleted,
        operationId: _storyCompletedOperationId,
      );
      _storyCompletedRecorded = true;
    } catch (_) {
      // An earned celebration is never held hostage by connectivity. Continue
      // retries this same operation id once more before the route is closed.
    } finally {
      _storyCompletedRecording = false;
    }
  }

  void _continueAfterCompletion() {
    if (!_storyCompletedRecorded) {
      unawaited(_recordStoryCompleted());
    }
    Navigator.of(context).maybePop();
  }

  Future<void> _loadReadingPreferences() async {
    try {
      final profile = await _authRepository.currentKid();
      if (!mounted) return;

      if (profile == null) {
        setState(() {
          _settingsResolved = true;
          _settingsMessage = 'Choose a kid profile before starting Read Along.';
        });
        return;
      }

      final profileVoice = _narrationForAvatar(profile.avatarKey);
      setState(() {
        _activeProfile = profile;
        _selectedNarration = profileVoice;
        if (profileVoice == null) {
          _settingsMessage = 'Your buddy’s reading voice isn’t ready yet.';
        }
      });

      try {
        final settings = await _settingsRepository.fetchSettings(
          profileId: profile.id,
        );
        if (!mounted) return;
        setState(() {
          _readerSettings = settings;
          _settingsResolved = true;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _settingsResolved = true;
          _settingsFailed = true;
          _settingsMessage =
              'Ask a grown-up to check the narration setting, then try again.';
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _settingsResolved = true;
        _settingsFailed = true;
        _settingsMessage =
            'We could not check the parent narration setting right now.';
      });
    }
  }

  StoryNarration? _narrationForAvatar(String avatarKey) {
    final normalizedAvatarKey = avatarKey.trim().toLowerCase();
    for (final narration in widget.story.narrations) {
      if (narration.avatarKey.trim().toLowerCase() == normalizedAvatarKey) {
        return narration;
      }
    }
    return null;
  }

  void _handleNarrationProgress(
    String spokenText,
    int startOffset,
    int endOffset,
    String word,
  ) {
    if (!mounted || widget.story.body.isEmpty) return;
    final body = widget.story.body;
    final callbackUsesFullStory = spokenText == body;
    final base = callbackUsesFullStory ? 0 : _spokenBaseOffset;
    var start = base + startOffset;
    var end = base + endOffset;

    if (start < 0 || start >= body.length || end <= start) {
      final searchFrom = _activeEnd.clamp(0, body.length);
      final found = word.trim().isEmpty
          ? -1
          : body.toLowerCase().indexOf(word.toLowerCase(), searchFrom);
      if (found >= 0) {
        start = found;
        end = found + word.length;
      }
    }

    start = start.clamp(0, body.length);
    end = end.clamp(start, body.length);
    if (end == start) return;

    if (_narrationIsActive) {
      _rememberNarratedRange(start, end);
    }

    setState(() {
      _activeStart = start;
      _activeEnd = end;
      _cursorOffset = start;
      if (_narrationIsActive) {
        _playback = _PlaybackState.playing;
        _playbackMessage = null;
      }
    });
    _scrollTextTo(end / body.length);
  }

  void _rememberNarratedRange(int start, int end) {
    final body = widget.story.body;
    if (body.isEmpty) return;
    final incoming = _NarratedRange(
      start.clamp(0, body.length),
      end.clamp(0, body.length),
    );
    if (incoming.end <= incoming.start) return;

    final ranges = [..._narratedRanges, incoming]
      ..sort((left, right) => left.start.compareTo(right.start));
    _narratedRanges.clear();
    for (final range in ranges) {
      if (_narratedRanges.isEmpty) {
        _narratedRanges.add(range);
        continue;
      }
      final previous = _narratedRanges.last;
      final overlaps = range.start <= previous.end;
      final formattingOnlyGap =
          range.start > previous.end &&
          !_containsStoryCharacter(body.substring(previous.end, range.start));
      if (overlaps || formattingOnlyGap) {
        _narratedRanges[_narratedRanges.length - 1] = _NarratedRange(
          previous.start,
          math.max(previous.end, range.end),
        );
      } else {
        _narratedRanges.add(range);
      }
    }
  }

  bool get _hasTruthfulCompletionCoverage {
    final body = widget.story.body;
    if (body.isEmpty || _narratedRanges.isEmpty) return false;

    final totalStoryCharacters = _countStoryCharacters(body);
    if (totalStoryCharacters == 0) return false;
    var narratedStoryCharacters = 0;
    for (final range in _narratedRanges) {
      narratedStoryCharacters += _countStoryCharacters(
        body.substring(range.start, range.end),
      );
    }

    final coverage = narratedStoryCharacters / totalStoryCharacters;
    final beginsNearStart =
        _narratedRanges.first.start <= (body.length * 0.05).ceil();
    final reachesNearEnd =
        _narratedRanges.last.end >= (body.length * 0.95).floor();
    return coverage >= 0.9 && beginsNearStart && reachesNearEnd;
  }

  bool _containsStoryCharacter(String text) =>
      RegExp(r'[A-Za-z0-9]').hasMatch(text);

  int _countStoryCharacters(String text) =>
      RegExp(r'[A-Za-z0-9]').allMatches(text).length;

  void _scrollTextTo(double fraction) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_textController.hasClients) return;
      final media = MediaQuery.maybeOf(context);
      if (media?.accessibleNavigation ?? false) return;

      final position = _textController.position;
      final target =
          (position.maxScrollExtent * fraction -
                  position.viewportDimension * 0.22)
              .clamp(0.0, position.maxScrollExtent);
      if ((position.pixels - target).abs() < 12) return;

      if (media?.disableAnimations ?? false) {
        _textController.jumpTo(target);
      } else {
        unawaited(
          _textController.animateTo(
            target,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          ),
        );
      }
    });
  }

  void _setPlayback(_PlaybackState playback) {
    if (mounted) setState(() => _playback = playback);
  }

  Future<void> _togglePlayback() async {
    if (_narrationBusy || !_canNarrate) return;
    if (_playback == _PlaybackState.playing) {
      await _pauseNarration();
      return;
    }
    final body = widget.story.body;
    final offset = _playback == _PlaybackState.completed
        ? 0
        : _cursorOffset.clamp(0, body.length - 1);
    await _playFromOffset(
      offset,
      stopCurrent: _playback == _PlaybackState.paused,
    );
  }

  Future<void> _playFromOffset(
    int requestedOffset, {
    required bool stopCurrent,
  }) async {
    final narration = _selectedNarration;
    final body = widget.story.body;
    if (_narrationBusy ||
        narration == null ||
        body.trim().isEmpty ||
        !_canNarrate) {
      return;
    }
    final offset = requestedOffset.clamp(0, body.length - 1);

    setState(() {
      _narrationBusy = true;
      _playbackMessage = null;
    });
    try {
      if (stopCurrent) {
        await _stopForReplacement();
      }
      if (!mounted) return;
      setState(() {
        _cursorOffset = offset;
        _activeStart = offset;
        _activeEnd = offset;
        _spokenBaseOffset = offset;
        _playback = _PlaybackState.idle;
      });
      _scrollTextTo(offset / body.length);
      await _narrationService.speak(
        text: body.substring(offset),
        narration: narration,
      );
      _setPlayback(_PlaybackState.playing);
    } on AppException catch (error) {
      _narrationIsActive = false;
      if (mounted) {
        setState(() {
          _playback = _PlaybackState.idle;
          _playbackMessage = error.message;
        });
      }
    } catch (_) {
      _narrationIsActive = false;
      if (mounted) {
        setState(() {
          _playback = _PlaybackState.idle;
          _playbackMessage = 'This voice cannot read on this device right now.';
        });
      }
    } finally {
      if (mounted) setState(() => _narrationBusy = false);
    }
  }

  Future<void> _stopForReplacement() async {
    _ignoreCancellation = true;
    _narrationIsActive = false;
    try {
      await _narrationService.stop();
      await Future<void>.delayed(Duration.zero);
    } finally {
      _ignoreCancellation = false;
    }
  }

  Future<void> _pauseNarration() async {
    setState(() => _narrationBusy = true);
    try {
      await _narrationService.pause();
      _narrationIsActive = false;
      _setPlayback(_PlaybackState.paused);
    } on AppException catch (error) {
      if (mounted) setState(() => _playbackMessage = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _playbackMessage = 'This voice could not pause.');
      }
    } finally {
      if (mounted) setState(() => _narrationBusy = false);
    }
  }

  Future<void> _restartNarration() async {
    if (_narrationBusy || !_canNarrate) return;
    await _playFromOffset(0, stopCurrent: _playback != _PlaybackState.idle);
  }

  Future<void> _jumpPassage(int direction) async {
    if (_narrationBusy || !_canNarrate || direction == 0) return;
    final offsets = _passageOffsets;
    if (offsets.length < 2) return;

    final current = _currentNarrationOffset;
    var currentIndex = 0;
    for (var index = 0; index < offsets.length; index++) {
      if (offsets[index] > current) break;
      currentIndex = index;
    }
    final targetIndex = (currentIndex + direction).clamp(0, offsets.length - 1);
    final target = offsets[targetIndex];
    if (target == current) return;

    if (_playback == _PlaybackState.playing) {
      await _playFromOffset(target, stopCurrent: true);
      return;
    }

    setState(() => _narrationBusy = true);
    try {
      if (_playback == _PlaybackState.paused) {
        await _stopForReplacement();
      }
      if (!mounted) return;
      setState(() {
        _cursorOffset = target;
        _activeStart = target;
        _activeEnd = target;
        _spokenBaseOffset = target;
        _playback = _PlaybackState.idle;
        _playbackMessage = null;
      });
      _scrollTextTo(target / widget.story.body.length);
    } on AppException catch (error) {
      if (mounted) setState(() => _playbackMessage = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _playbackMessage = 'We could not move through this story.',
        );
      }
    } finally {
      if (mounted) setState(() => _narrationBusy = false);
    }
  }

  Future<void> _stopNarration() async {
    if (_narrationBusy || !_canNarrate) return;
    setState(() => _narrationBusy = true);
    try {
      if (_playback != _PlaybackState.idle) {
        await _stopForReplacement();
      }
      if (!mounted) return;
      setState(() {
        _playback = _PlaybackState.idle;
        _playbackMessage = null;
        _resetProgress();
      });
      if (_textController.hasClients) _textController.jumpTo(0);
    } on AppException catch (error) {
      if (mounted) setState(() => _playbackMessage = error.message);
    } finally {
      if (mounted) setState(() => _narrationBusy = false);
    }
  }

  void _resetProgress() {
    _activeStart = 0;
    _activeEnd = 0;
    _cursorOffset = 0;
    _spokenBaseOffset = 0;
    _narratedRanges.clear();
  }

  bool _isDeviceNarration(StoryNarration narration) {
    return narration.status.trim().toLowerCase() == 'device_tts';
  }

  bool get _parentAllowsNarration {
    return _settingsResolved &&
        !_settingsFailed &&
        (_readerSettings?.narrationEnabled ?? true);
  }

  bool get _canNarrate {
    final narration = _selectedNarration;
    return widget.story.body.trim().isNotEmpty &&
        narration != null &&
        _isDeviceNarration(narration) &&
        _parentAllowsNarration;
  }

  List<int> get _passageOffsets {
    final body = widget.story.body;
    if (body.trim().isEmpty) return const [0];
    final offsets = <int>[0];
    for (final match in RegExp(r'[.!?]+\s+|\n{2,}').allMatches(body)) {
      if (match.end < body.length && match.end > offsets.last) {
        offsets.add(match.end);
      }
    }
    return offsets;
  }

  int get _currentNarrationOffset {
    if (widget.story.body.isEmpty) return 0;
    return _cursorOffset.clamp(0, widget.story.body.length);
  }

  int get _currentPassageIndex {
    final offsets = _passageOffsets;
    var currentIndex = 0;
    for (var index = 0; index < offsets.length; index++) {
      if (offsets[index] > _currentNarrationOffset) break;
      currentIndex = index;
    }
    return currentIndex;
  }

  bool get _canGoToPreviousPassage => _canNarrate && _currentPassageIndex > 0;

  bool get _canGoToNextPassage =>
      _canNarrate && _currentPassageIndex < _passageOffsets.length - 1;

  double get _progress {
    if (widget.story.body.isEmpty) return 0;
    final progressOffset = _activeEnd > _cursorOffset
        ? _activeEnd
        : _cursorOffset;
    return (progressOffset / widget.story.body.length).clamp(0, 1);
  }

  int get _estimatedDurationSeconds {
    if (widget.story.estimatedReadSeconds > 0) {
      return widget.story.estimatedReadSeconds;
    }
    final wordCount = RegExp(r'\S+').allMatches(widget.story.body).length;
    return (wordCount / 2.3).ceil().clamp(1, 60 * 60);
  }

  double get _textScaleMultiplier => switch (_readerSettings?.storyTextScale) {
    StoryTextScale.large => 1.16,
    StoryTextScale.extraLarge => 1.32,
    _ => 1,
  };

  String get _statusMessage {
    if (widget.story.body.trim().isEmpty) {
      return 'This story is still getting ready.';
    }
    if (!_settingsResolved) {
      return 'Getting your story buddy ready…';
    }
    if (_settingsMessage != null) return _settingsMessage!;
    if (!(_readerSettings?.narrationEnabled ?? true)) {
      return 'Narration is off in Parent settings.';
    }
    if (widget.story.narrations.isEmpty) {
      return 'The character voices for this story are still warming up.';
    }
    final narration = _selectedNarration;
    if (narration == null) {
      return 'Your buddy’s reading voice isn’t ready yet.';
    }
    if (!_isDeviceNarration(narration)) {
      return '${narration.characterName}\'s voice is still warming up.';
    }
    if (_playbackMessage != null) return _playbackMessage!;
    return switch (_playback) {
      _PlaybackState.playing => '${narration.characterName} is reading.',
      _PlaybackState.paused => 'Paused.',
      _PlaybackState.completed => 'Story complete!',
      _ => 'Tap play to begin.',
    };
  }

  @override
  void dispose() {
    _textController.dispose();
    unawaited(_narrationService.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeProfile = _activeProfile;
    if (_completionPresented && activeProfile != null) {
      return StoryCompletionView(
        story: widget.story,
        profile: activeProfile,
        onContinue: _continueAfterCompletion,
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        key: const Key('read-along-screen'),
        backgroundColor: const Color(0xFFFFFAF6),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxHeight < 620;
                    return Column(
                      children: [
                        _ReadAlongTopBar(title: widget.story.title),
                        SizedBox(height: compact ? 6 : 12),
                        Expanded(
                          flex: compact ? 3 : 4,
                          child: _StoryArtwork(
                            story: widget.story,
                            compact: compact,
                          ),
                        ),
                        SizedBox(height: compact ? 4 : 10),
                        Expanded(
                          flex: compact ? 4 : 5,
                          child: _ReadAlongTextPanel(
                            storyText: widget.story.body,
                            activeStart: _activeStart,
                            activeEnd: _activeEnd,
                            cursorOffset: _cursorOffset,
                            textScaleMultiplier: _textScaleMultiplier,
                            controller: _textController,
                          ),
                        ),
                        _PlaybackStatus(
                          key: const Key('read-along-status'),
                          message: _statusMessage,
                          loading: !_settingsResolved,
                          isError: _settingsFailed || _playbackMessage != null,
                          compact: compact,
                        ),
                        SizedBox(height: compact ? 4 : 8),
                        _ReadAlongControls(
                          progress: _progress,
                          totalSeconds: _estimatedDurationSeconds,
                          playback: _playback,
                          busy: _narrationBusy,
                          enabled: _canNarrate,
                          canGoPrevious: _canGoToPreviousPassage,
                          canGoNext: _canGoToNextPassage,
                          onRestart: _restartNarration,
                          onPrevious: () => _jumpPassage(-1),
                          onPlayPause: _togglePlayback,
                          onNext: () => _jumpPassage(1),
                          onStop: _stopNarration,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NarratedRange {
  const _NarratedRange(this.start, this.end);

  final int start;
  final int end;
}

class _ReadAlongTopBar extends StatelessWidget {
  const _ReadAlongTopBar({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              key: const Key('read-along-back-button'),
              tooltip: 'Back to story',
              onPressed: () => Navigator.of(context).maybePop(),
              style: IconButton.styleFrom(
                foregroundColor: const Color(0xFF201C1B),
                minimumSize: const Size.square(48),
              ),
              icon: const Icon(Icons.arrow_back_rounded, size: 25),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 58),
            child: Text(
              title,
              key: const Key('read-along-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF332C2A),
                fontSize: 15,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StoryArtwork extends StatelessWidget {
  const _StoryArtwork({required this.story, required this.compact});

  final StoryDetail story;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: 'Illustration for ${story.title}',
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: compact ? 190 : 280,
            maxHeight: compact ? 145 : 235,
          ),
          child: AspectRatio(
            aspectRatio: 1,
            child: StoryCoverImage(
              key: const Key('read-along-artwork'),
              story: story,
              fit: BoxFit.contain,
              borderRadius: BorderRadius.circular(24),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReadAlongTextPanel extends StatelessWidget {
  const _ReadAlongTextPanel({
    required this.storyText,
    required this.activeStart,
    required this.activeEnd,
    required this.cursorOffset,
    required this.textScaleMultiplier,
    required this.controller,
  });

  final String storyText;
  final int activeStart;
  final int activeEnd;
  final int cursorOffset;
  final double textScaleMultiplier;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (storyText.trim().isEmpty)
            const _EmptyReadAlongText()
          else
            Semantics(
              container: true,
              readOnly: true,
              label: 'Story text. $storyText',
              child: SingleChildScrollView(
                key: const Key('read-along-text-scroll'),
                controller: controller,
                physics: const ClampingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(8, 20, 8, 90),
                child: ExcludeSemantics(
                  child: _HighlightedStoryText(
                    storyText: storyText,
                    activeStart: activeStart,
                    activeEnd: activeEnd,
                    cursorOffset: cursorOffset,
                    textScaleMultiplier: textScaleMultiplier,
                  ),
                ),
              ),
            ),
          if (storyText.trim().isNotEmpty)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 68,
              child: IgnorePointer(child: _ReadingFade()),
            ),
        ],
      ),
    );
  }
}

class _HighlightedStoryText extends StatelessWidget {
  const _HighlightedStoryText({
    required this.storyText,
    required this.activeStart,
    required this.activeEnd,
    required this.cursorOffset,
    required this.textScaleMultiplier,
  });

  final String storyText;
  final int activeStart;
  final int activeEnd;
  final int cursorOffset;
  final double textScaleMultiplier;

  @override
  Widget build(BuildContext context) {
    final start = activeStart.clamp(0, storyText.length);
    final end = activeEnd.clamp(start, storyText.length);
    final focusOffset = (end > start ? start : cursorOffset).clamp(
      0,
      storyText.length,
    );
    final focusStart = _passageStart(storyText, focusOffset);
    final focusEnd = _passageEnd(storyText, focusOffset);
    final baseStyle = TextStyle(
      color: const Color(0xFF2B2523),
      fontSize: 29 * textScaleMultiplier,
      height: 1.34,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.65,
    );
    final distantStyle = baseStyle.copyWith(
      color: const Color(0xFF2B2523).withValues(alpha: 0.13),
    );
    final focusStyle = baseStyle.copyWith(
      color: const Color(0xFF2B2523).withValues(alpha: 0.92),
    );
    final activeStyle = baseStyle.copyWith(
      color: const Color(0xFFF15F43),
      backgroundColor: const Color(0xFFFFE1D7),
      fontWeight: FontWeight.w900,
    );
    final hasActiveWord = end > start;
    final activeWordStart = hasActiveWord ? start : focusStart;
    final activeWordEnd = hasActiveWord ? end : focusStart;

    return Text.rich(
      key: const Key('read-along-story-text'),
      TextSpan(
        style: baseStyle,
        children: [
          if (focusStart > 0)
            TextSpan(
              text: storyText.substring(0, focusStart),
              style: distantStyle,
            ),
          if (activeWordStart > focusStart)
            TextSpan(
              text: storyText.substring(focusStart, activeWordStart),
              style: focusStyle,
            ),
          if (activeWordEnd > activeWordStart)
            TextSpan(
              text: storyText.substring(activeWordStart, activeWordEnd),
              style: activeStyle,
            ),
          if (focusEnd > activeWordEnd)
            TextSpan(
              text: storyText.substring(activeWordEnd, focusEnd),
              style: focusStyle,
            ),
          if (focusEnd < storyText.length)
            TextSpan(text: storyText.substring(focusEnd), style: distantStyle),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }

  int _passageStart(String text, int offset) {
    if (offset <= 0) return 0;
    for (var index = offset - 1; index >= 0; index--) {
      final character = text[index];
      if (character == '.' ||
          character == '!' ||
          character == '?' ||
          character == '\n') {
        var start = index + 1;
        while (start < text.length && text[start].trim().isEmpty) {
          start++;
        }
        return start;
      }
    }
    return 0;
  }

  int _passageEnd(String text, int offset) {
    if (text.isEmpty) return 0;
    for (
      var index = offset.clamp(0, text.length - 1);
      index < text.length;
      index++
    ) {
      final character = text[index];
      if (character == '.' || character == '!' || character == '?') {
        return index + 1;
      }
      if (character == '\n' && index > offset) {
        return index;
      }
    }
    return text.length;
  }
}

class _ReadingFade extends StatelessWidget {
  const _ReadingFade();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFFFFFAF6).withValues(alpha: 0),
            const Color(0xFFFFFAF6),
          ],
        ),
      ),
    );
  }
}

class _EmptyReadAlongText extends StatelessWidget {
  const _EmptyReadAlongText();

  @override
  Widget build(BuildContext context) {
    return const Center(
      key: Key('read-along-empty-story'),
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_stories_rounded,
              color: Color(0xFFF15F43),
              size: 40,
            ),
            SizedBox(height: 12),
            Text(
              'This read-along is still getting ready.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFF332C2A),
                fontSize: 17,
                height: 1.2,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaybackStatus extends StatelessWidget {
  const _PlaybackStatus({
    required this.message,
    required this.loading,
    required this.isError,
    required this.compact,
    super.key,
  });

  final String message;
  final bool loading;
  final bool isError;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      liveRegion: isError,
      label: message,
      child: SizedBox(
        height: compact ? 20 : 26,
        child: ExcludeSemantics(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (loading) ...[
                const SizedBox.square(
                  dimension: 13,
                  child: CircularProgressIndicator(
                    key: Key('read-along-settings-loading'),
                    strokeWidth: 2,
                    color: Color(0xFFF15F43),
                  ),
                ),
                const SizedBox(width: 7),
              ] else if (isError) ...[
                const Icon(
                  Icons.info_outline_rounded,
                  color: Color(0xFFC44531),
                  size: 16,
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isError
                        ? const Color(0xFFC44531)
                        : const Color(0xFF746A66),
                    fontSize: compact ? 10.5 : 11.5,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadAlongControls extends StatelessWidget {
  const _ReadAlongControls({
    required this.progress,
    required this.totalSeconds,
    required this.playback,
    required this.busy,
    required this.enabled,
    required this.canGoPrevious,
    required this.canGoNext,
    required this.onRestart,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
    required this.onStop,
  });

  final double progress;
  final int totalSeconds;
  final _PlaybackState playback;
  final bool busy;
  final bool enabled;
  final bool canGoPrevious;
  final bool canGoNext;
  final VoidCallback onRestart;
  final VoidCallback onPrevious;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final percent = (progress * 100).round();
    final elapsedSeconds = (totalSeconds * progress).round();
    final controlsEnabled = enabled && !busy;
    final playLabel = playback == _PlaybackState.playing
        ? 'Pause story'
        : playback == _PlaybackState.paused
        ? 'Resume story'
        : 'Play story';

    return Column(
      key: const Key('read-along-controls'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: 'Story progress',
          value: '$percent percent',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              key: const Key('read-along-progress'),
              minHeight: 5,
              value: progress,
              color: const Color(0xFFF15F43),
              backgroundColor: const Color(0xFFE7DEDA),
            ),
          ),
        ),
        const SizedBox(height: 5),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _formatDuration(elapsedSeconds),
              key: const Key('read-along-elapsed-time'),
              style: _timeStyle,
            ),
            Text(
              _formatDuration(totalSeconds),
              key: const Key('read-along-total-time'),
              style: _timeStyle,
            ),
          ],
        ),
        const SizedBox(height: 5),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _TransportButton(
              key: const Key('read-along-replay'),
              tooltip: 'Start story again',
              icon: Icons.restart_alt_rounded,
              onPressed: controlsEnabled ? onRestart : null,
            ),
            _TransportButton(
              key: const Key('read-along-previous'),
              tooltip: 'Previous passage',
              icon: Icons.skip_previous_rounded,
              onPressed: controlsEnabled && canGoPrevious ? onPrevious : null,
            ),
            Semantics(
              button: true,
              enabled: controlsEnabled,
              label: playLabel,
              child: IconButton.filled(
                key: const Key('read-along-play-pause'),
                tooltip: playLabel,
                onPressed: controlsEnabled ? onPlayPause : null,
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFFF15F43),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFFD6C9C4),
                  disabledForegroundColor: Colors.white,
                  minimumSize: const Size.square(64),
                  maximumSize: const Size.square(64),
                ),
                icon: busy
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        playback == _PlaybackState.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 36,
                      ),
              ),
            ),
            _TransportButton(
              key: const Key('read-along-next'),
              tooltip: 'Next passage',
              icon: Icons.skip_next_rounded,
              onPressed: controlsEnabled && canGoNext ? onNext : null,
            ),
            _TransportButton(
              key: const Key('read-along-stop'),
              tooltip: 'Stop story',
              icon: Icons.stop_rounded,
              onPressed: controlsEnabled ? onStop : null,
            ),
          ],
        ),
      ],
    );
  }

  static const _timeStyle = TextStyle(
    color: Color(0xFF8A7F7A),
    fontSize: 10.5,
    fontWeight: FontWeight.w600,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  String _formatDuration(int seconds) {
    final safeSeconds = seconds.clamp(0, 60 * 60);
    final minutes = safeSeconds ~/ 60;
    final remainder = safeSeconds % 60;
    return '$minutes:${remainder.toString().padLeft(2, '0')}';
  }
}

class _TransportButton extends StatelessWidget {
  const _TransportButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        foregroundColor: const Color(0xFF332C2A),
        disabledForegroundColor: const Color(0xFFC8BBB6),
        minimumSize: const Size.square(48),
        maximumSize: const Size.square(48),
      ),
      icon: Icon(icon, size: 27),
    );
  }
}

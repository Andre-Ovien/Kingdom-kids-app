import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../../app/app_route_observer.dart';
import '../../../core/errors/app_exception.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/kid_profile.dart';
import '../../milestones/data/level_milestone_store.dart';
import '../../milestones/domain/level_milestone.dart';
import '../../milestones/presentation/level_milestone_presenter.dart';
import '../../parental_controls/data/parental_controls_repository.dart';
import '../../parental_controls/domain/parent_settings.dart';
import '../../progress/data/progress_repository.dart';
import '../../progress/domain/story_activity_event.dart';
import '../data/story_narration_service.dart';
import '../data/story_narration_metadata_refresher.dart';
import '../data/story_repository.dart';
import '../data/story_reading_bookmark_store.dart';
import '../domain/story_detail.dart';
import '../domain/story_availability.dart';
import '../domain/story_reading_bookmark.dart';
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
    this.storyRepository,
    this.authRepository,
    this.settingsRepository,
    this.progressRepository,
    this.milestoneStore,
    this.bookmarkStore,
    this.resumeReading = false,
    this.operationIdFactory = newStoryProgressOperationId,
  });

  final StoryDetail story;
  final StoryNarrationService? narrationService;
  final StoryRepository? storyRepository;
  final AuthRepository? authRepository;
  final ParentalControlsRepository? settingsRepository;
  final ProgressRepository? progressRepository;
  final LevelMilestoneStore? milestoneStore;
  final StoryReadingBookmarkStore? bookmarkStore;
  final bool resumeReading;
  final StoryProgressOperationIdFactory operationIdFactory;

  @override
  State<ReadAlongScreen> createState() => _ReadAlongScreenState();
}

enum _PlaybackState { idle, starting, playing, paused, completed }

class _ReadAlongScreenState extends State<ReadAlongScreen>
    with WidgetsBindingObserver, RouteAware {
  late final StoryNarrationService _narrationService;
  late final AuthRepository _authRepository;
  late final ParentalControlsRepository _settingsRepository;
  late final ProgressRepository _progressRepository;
  late final LevelMilestonePresenter _milestonePresenter;
  late final StoryReadingBookmarkStore _bookmarkStore;
  Timer? _bookmarkTimer;
  bool _bookmarkEngaged = false;
  bool _bookmarkCompleted = false;
  String? _lastBookmarkSignature;
  bool _userScrolling = false;
  late final String _storyStartedOperationId;
  late final String _storyCompletedOperationId;
  final ScrollController _textController = ScrollController();
  final GlobalKey _textLayoutKey = GlobalKey();
  final GlobalKey _textViewportKey = GlobalKey();
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
  bool _appIsActive = true;
  bool _routeIsActive = true;
  bool _lifecycleStopInFlight = false;
  bool _completionPresented = false;
  bool _narrationIsActive = false;
  bool _storyStartedRecorded = false;
  bool _storyStartedRecording = false;
  bool _storyCompletedRecorded = false;
  bool _storyCompletedRecording = false;
  Future<void>? _storyCompletedFuture;
  Future<void>? _milestonePresentationFuture;
  LevelMilestone? _pendingMilestone;
  int _storyXpAwarded = 0;
  bool _continuingAfterCompletion = false;
  ModalRoute<dynamic>? _observedRoute;
  int _activeStart = 0;
  int _activeEnd = 0;
  int _cursorOffset = 0;
  int _spokenBaseOffset = 0;
  int _narrationGeneration = 0;
  int? _activeNarrationGeneration;
  Timer? _narrationStartTimer;
  Duration _hostedPosition = Duration.zero;
  Duration? _hostedDuration;
  int? _pendingScrollOffset;
  int? _pendingScrollEnd;
  bool _pendingCenterParagraph = false;
  bool _scrollScheduled = false;
  _NarratedRange? _centeredParagraph;
  double? _centeredParagraphHeight;
  double? _centeredLineCenter;
  Size? _textViewportSize;
  TextScaler? _systemTextScaler;
  double? _layoutTextScale;
  double? _scrollDestination;
  int _scrollAnimation = 0;

  @override
  void initState() {
    super.initState();
    _authRepository = widget.authRepository ?? AuthRepository();
    final metadata = widget.narrationService == null
        ? StoryNarrationMetadataRefresher(
            story: widget.story,
            authRepository: _authRepository,
            storyRepository: widget.storyRepository,
          )
        : null;
    _narrationService =
        widget.narrationService ??
        CharacterStoryNarrationService(
          hostedMetadataResolver: metadata!.resolve,
          hostedScopeValidator: metadata.validateScope,
        );
    _settingsRepository =
        widget.settingsRepository ??
        RemoteParentalControlsRepository(authRepository: _authRepository);
    _progressRepository =
        widget.progressRepository ??
        RemoteProgressRepository(authRepository: _authRepository);
    _bookmarkStore = widget.bookmarkStore ?? SecureStoryReadingBookmarkStore();
    _milestonePresenter = LevelMilestonePresenter(
      authRepository: _authRepository,
      store: widget.milestoneStore ?? SecureLevelMilestoneStore(),
    );
    _storyStartedOperationId = widget.operationIdFactory();
    _storyCompletedOperationId = widget.operationIdFactory();
    _appIsActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _bindNarrationCallbacks(_narrationGeneration);
    if (isStoryAvailable(widget.story.slug)) {
      unawaited(_loadReadingPreferences());
    } else {
      _settingsResolved = true;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (identical(route, _observedRoute)) return;
    if (_observedRoute != null) appRouteObserver.unsubscribe(this);
    _observedRoute = route;
    if (route != null) appRouteObserver.subscribe(this, route);
  }

  @override
  void didPopNext() {
    _routeIsActive = true;
    unawaited(_presentMilestone());
  }

  @override
  void didPushNext() {
    _routeIsActive = false;
    unawaited(_stopNarrationForLifecycle(routeCovered: true));
  }

  void _bindNarrationCallbacks(int generation) {
    _narrationService.setCallbacks(
      onStarted: () => _handleNarrationStarted(generation),
      onCompleted: () => _handleNarrationCompleted(generation),
      onPaused: () => _handleNarrationPaused(generation),
      onCancelled: () => _handleNarrationCancelled(generation),
      onError: (message) => _handleNarrationError(generation, message),
      onProgress: (spokenText, startOffset, endOffset, word) =>
          _handleNarrationProgress(
            generation,
            spokenText,
            startOffset,
            endOffset,
            word,
          ),
      onPassage: (spokenText, startOffset, endOffset) =>
          _handleNarrationPassage(
            generation,
            spokenText,
            startOffset,
            endOffset,
          ),
      onPosition: (position, duration) =>
          _handleNarrationPosition(generation, position, duration),
      onWord: (word) => _handleNarrationWord(generation, word),
    );
  }

  int _beginNarrationSession() {
    final generation = ++_narrationGeneration;
    _activeNarrationGeneration = generation;
    _bindNarrationCallbacks(generation);
    return generation;
  }

  void _invalidateNarrationSession({bool rebind = true}) {
    _narrationStartTimer?.cancel();
    _narrationStartTimer = null;
    _activeNarrationGeneration = null;
    _narrationIsActive = false;
    final generation = ++_narrationGeneration;
    if (rebind) {
      _bindNarrationCallbacks(generation);
    }
  }

  bool _isCurrentNarrationSession(int generation) {
    return mounted && _activeNarrationGeneration == generation;
  }

  void _handleNarrationStarted(int generation) {
    if (!_isCurrentNarrationSession(generation) ||
        _playback != _PlaybackState.starting) {
      return;
    }
    _narrationStartTimer?.cancel();
    _narrationStartTimer = null;
    _narrationIsActive = true;
    _bookmarkEngaged = true;
    if (_bookmarkCompleted) _lastBookmarkSignature = null;
    _bookmarkCompleted = false;
    _queueBookmarkSave();
    _setPlayback(_PlaybackState.playing);
    unawaited(_recordStoryStarted());
  }

  void _handleNarrationPaused(int generation) {
    if (!_isCurrentNarrationSession(generation)) return;
    _invalidateNarrationSession();
    _setPlayback(_PlaybackState.paused);
    unawaited(_saveBookmark());
  }

  void _handleNarrationCancelled(int generation) {
    if (!_isCurrentNarrationSession(generation)) return;
    _invalidateNarrationSession();
    _setPlayback(_PlaybackState.idle);
  }

  void _handleNarrationError(int generation, String message) {
    if (!_isCurrentNarrationSession(generation)) return;
    _invalidateNarrationSession();
    setState(() {
      _playback = _PlaybackState.idle;
      _playbackMessage = message;
    });
  }

  void _handleNarrationCompleted(int generation) {
    if (!_isCurrentNarrationSession(generation) ||
        _completionPresented ||
        !_narrationIsActive) {
      return;
    }
    _invalidateNarrationSession();
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
      _scrollTextToOffset(0, centerParagraph: true);
      unawaited(_saveBookmark());
      return;
    }
    _bookmarkCompleted = true;
    _bookmarkTimer?.cancel();
    unawaited(_removeBookmark());
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
      _scrollTextToOffset(widget.story.body.length - 1, centerParagraph: true);
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

  Future<void> _recordStoryCompleted() {
    if (_storyCompletedRecorded) return Future<void>.value();
    if (_storyCompletedFuture != null) return _storyCompletedFuture!;
    final future = _saveStoryCompleted();
    _storyCompletedFuture = future;
    return future.whenComplete(() {
      if (identical(_storyCompletedFuture, future)) {
        _storyCompletedFuture = null;
      }
    });
  }

  Future<void> _saveStoryCompleted() async {
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
      final receipt = await _progressRepository.recordStoryActivity(
        profileId: profileId,
        storyId: storyId,
        eventType: StoryActivityType.storyCompleted,
        operationId: _storyCompletedOperationId,
      );
      _storyCompletedRecorded = true;
      final selectedProfile = await _authRepository.currentKid();
      if (mounted &&
          selectedProfile?.id == receipt.profileId &&
          _activeProfile?.id == receipt.profileId) {
        setState(() {
          _storyXpAwarded = receipt.xpAwarded;
          _pendingMilestone = receipt.levelMilestone;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_presentMilestone());
        });
      }
    } catch (_) {
      // An earned celebration is never held hostage by connectivity. Continue
      // retries this same operation id once more before the route is closed.
    } finally {
      _storyCompletedRecording = false;
    }
  }

  bool get _canPresentMilestone =>
      mounted &&
      _completionPresented &&
      _appIsActive &&
      ModalRoute.of(context)?.isCurrent == true;

  Future<void> _presentMilestone() {
    if (_milestonePresentationFuture != null) {
      return _milestonePresentationFuture!;
    }
    if (_pendingMilestone == null || !_canPresentMilestone) {
      return Future<void>.value();
    }
    final future = _presentPendingMilestone();
    _milestonePresentationFuture = future;
    return future.whenComplete(() {
      if (identical(_milestonePresentationFuture, future)) {
        _milestonePresentationFuture = null;
      }
    });
  }

  Future<void> _presentPendingMilestone() async {
    final milestone = _pendingMilestone;
    final profileId = _activeProfile?.id;
    if (milestone == null || profileId == null || !_canPresentMilestone) return;
    final result = await _milestonePresenter.present(
      context,
      profileId: profileId,
      milestone: milestone,
      canPresent: () => _canPresentMilestone,
    );
    if (result != LevelMilestonePresentationResult.deferred &&
        identical(_pendingMilestone, milestone)) {
      _pendingMilestone = null;
    }
  }

  Future<void> _continueAfterCompletion() async {
    if (_continuingAfterCompletion) return;
    setState(() => _continuingAfterCompletion = true);
    try {
      await _recordStoryCompleted();
      if (!mounted) return;
      await _presentMilestone();
      if (!mounted) return;
      if (_canPresentMilestone && _pendingMilestone == null) {
        await Navigator.of(context).maybePop();
      }
    } finally {
      if (mounted) setState(() => _continuingAfterCompletion = false);
    }
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
      await _restoreBookmark(profile);
      if (!mounted) return;
      _scrollTextToOffset(_cursorOffset, centerParagraph: true);

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

  Future<void> _restoreBookmark(KidProfile profile) async {
    if (!widget.resumeReading ||
        profile.parentId.isEmpty ||
        !isStoryAvailable(widget.story.slug)) {
      return;
    }
    try {
      final bookmarks = await _bookmarkStore.readAll(
        parentId: profile.parentId,
        profileId: profile.id,
      );
      if (!mounted) return;
      StoryReadingBookmark? saved;
      for (final bookmark in bookmarks) {
        if (bookmark.isForStory(widget.story)) {
          saved = bookmark;
          break;
        }
      }
      if (saved == null) return;
      final bookmark = saved;
      final offset = bookmark.resumeOffsetFor(widget.story);
      if (bookmark.hasCurrentBody(widget.story)) {
        for (final range in bookmark.heardRanges) {
          if (range.end <= widget.story.body.length) {
            _rememberNarratedRange(range.start, range.end);
          }
        }
      }
      setState(() {
        _cursorOffset = offset;
        _activeStart = offset;
        _activeEnd = offset;
        _spokenBaseOffset = offset;
        _bookmarkEngaged = true;
        _playbackMessage = 'Your place is saved. Tap play when you’re ready.';
      });
    } catch (_) {
      // A missing or unreadable local bookmark still opens the fresh story.
    }
  }

  void _queueBookmarkSave() {
    if (!_bookmarkEngaged ||
        _bookmarkCompleted ||
        _bookmarkTimer != null ||
        widget.story.id.isEmpty) {
      return;
    }
    // A throttle, rather than a debounce: continuous word callbacks still
    // produce a checkpoint, while secure storage is never written per word.
    _bookmarkTimer = Timer(const Duration(seconds: 5), () {
      _bookmarkTimer = null;
      unawaited(_saveBookmark());
    });
  }

  Future<void> _saveBookmark() async {
    _bookmarkTimer?.cancel();
    _bookmarkTimer = null;
    final profile = _activeProfile;
    if (!_bookmarkEngaged ||
        _bookmarkCompleted ||
        profile == null ||
        profile.parentId.isEmpty ||
        widget.story.id.isEmpty ||
        !isStoryAvailable(widget.story.slug) ||
        widget.story.body.isEmpty) {
      return;
    }
    final signature =
        '$_cursorOffset|${_narratedRanges.map((range) => '${range.start}:${range.end}').join(',')}';
    if (signature == _lastBookmarkSignature) return;
    _lastBookmarkSignature = signature;
    final bookmark = StoryReadingBookmark.forStory(
      story: widget.story,
      textOffset: _cursorOffset.clamp(0, widget.story.body.length - 1),
      updatedAt: DateTime.now().toUtc(),
      heardRanges: _narratedRanges
          .map((range) => StoryHeardRange(range.start, range.end))
          .toList(),
    );
    try {
      await _bookmarkStore.save(
        parentId: profile.parentId,
        profileId: profile.id,
        bookmark: bookmark,
      );
    } catch (_) {
      // Continue reading even when local storage is temporarily unavailable.
    }
  }

  Future<void> _removeBookmark() async {
    final profile = _activeProfile;
    if (profile == null || profile.parentId.isEmpty) return;
    try {
      await _bookmarkStore.remove(
        parentId: profile.parentId,
        profileId: profile.id,
        storyId: widget.story.id,
      );
    } catch (_) {
      // Completion and XP remain independent from the local resume shortcut.
    }
  }

  bool _handleReadingScroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _userScrolling = true;
    }
    if (notification is! ScrollEndNotification || !_userScrolling) return false;
    _userScrolling = false;
    if (_playback == _PlaybackState.playing ||
        _playback == _PlaybackState.starting ||
        _bookmarkCompleted) {
      return false;
    }
    final text = _textLayoutKey.currentContext?.findRenderObject();
    final viewport = _textViewportKey.currentContext?.findRenderObject();
    if (text is! RenderParagraph ||
        viewport is! RenderBox ||
        widget.story.body.isEmpty) {
      return false;
    }
    final center = viewport.localToGlobal(viewport.size.center(Offset.zero));
    final position = text.getPositionForOffset(text.globalToLocal(center));
    final offset = _paragraphForOffset(position.offset).start;
    setState(() {
      _cursorOffset = offset;
      _activeStart = offset;
      _activeEnd = offset;
      _spokenBaseOffset = offset;
      _playback = _PlaybackState.idle;
      _bookmarkEngaged = true;
    });
    unawaited(_saveBookmark());
    return false;
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
    int generation,
    String spokenText,
    int startOffset,
    int endOffset,
    String word,
  ) {
    if (!_isCurrentNarrationSession(generation) ||
        !_narrationIsActive ||
        _playback != _PlaybackState.playing ||
        widget.story.body.isEmpty) {
      return;
    }
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

    _rememberNarratedRange(start, end);
    _queueBookmarkSave();

    // Hosted audio confirms coverage only after a measured passage is heard.
    // Word highlighting and the player clock are separate from that coverage.
    if (_selectedNarration case final narration?
        when _isHostedNarration(narration)) {
      return;
    }

    setState(() {
      _activeStart = start;
      _activeEnd = end;
      _cursorOffset = start;
      _playbackMessage = null;
    });
    _queueBookmarkSave();
    _scrollTextToOffset(start, endOffset: end);
  }

  void _handleNarrationPassage(
    int generation,
    String spokenText,
    int start,
    int end,
  ) {
    final body = widget.story.body;
    if (!_isCurrentNarrationSession(generation) ||
        !_narrationIsActive ||
        _playback != _PlaybackState.playing ||
        spokenText != body ||
        start < 0 ||
        start >= body.length ||
        end <= start ||
        end > body.length) {
      return;
    }
    setState(() {
      _cursorOffset = start;
      _playbackMessage = null;
    });
    _queueBookmarkSave();
    _scrollTextToOffset(start);
  }

  void _handleNarrationPosition(
    int generation,
    Duration position,
    Duration? duration,
  ) {
    final narration = _selectedNarration;
    if (!_isCurrentNarrationSession(generation) ||
        !_narrationIsActive ||
        _playback != _PlaybackState.playing ||
        narration == null ||
        !_isHostedNarration(narration) ||
        position < Duration.zero ||
        (duration != null && duration <= Duration.zero)) {
      return;
    }
    final bounded = duration != null && position > duration
        ? duration
        : position;
    if (_hostedPosition == bounded && _hostedDuration == duration) return;
    setState(() {
      _hostedPosition = bounded;
      _hostedDuration = duration;
    });
  }

  void _handleNarrationWord(int generation, StoryNarrationSegment? word) {
    final body = widget.story.body;
    final narration = _selectedNarration;
    if (!_isCurrentNarrationSession(generation) ||
        !_narrationIsActive ||
        _playback != _PlaybackState.playing ||
        narration == null ||
        !_isHostedNarration(narration)) {
      return;
    }
    if (word == null) {
      if (_activeEnd > _activeStart) {
        setState(() => _activeEnd = _activeStart);
      }
      return;
    }
    if (word.startOffset < 0 ||
        word.endOffset <= word.startOffset ||
        word.endOffset > body.length ||
        body.substring(word.startOffset, word.endOffset) != word.text) {
      return;
    }
    setState(() {
      _activeStart = word.startOffset;
      _activeEnd = word.endOffset;
      _cursorOffset = word.startOffset;
      _playbackMessage = null;
    });
    _queueBookmarkSave();
    _scrollTextToOffset(word.startOffset, endOffset: word.endOffset);
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

  _NarratedRange _paragraphForOffset(int offset) {
    final body = widget.story.body;
    if (body.isEmpty) return const _NarratedRange(0, 0);
    final position = offset.clamp(0, body.length - 1);
    final narration = _selectedNarration;
    if (narration != null && _isHostedNarration(narration)) {
      for (final paragraph in narration.segmentsForText(body)) {
        if (position >= paragraph.startOffset &&
            position < paragraph.endOffset) {
          return _NarratedRange(paragraph.startOffset, paragraph.endOffset);
        }
      }
    }
    // Device speech and recordings without cues still have real paragraphs.
    // Sentence punctuation does not create a new paragraph.
    _NarratedRange? lastParagraph;
    for (final match in RegExp(r'[^\n]+').allMatches(body)) {
      var start = match.start;
      var end = match.end;
      while (start < end && body[start].trim().isEmpty) {
        start++;
      }
      while (end > start && body[end - 1].trim().isEmpty) {
        end--;
      }
      if (start == end) continue;
      final paragraph = _NarratedRange(start, end);
      if (position < end) return paragraph;
      lastParagraph = paragraph;
    }
    return lastParagraph ?? _NarratedRange(0, body.length);
  }

  void _handleTextLayout(Size viewport, TextScaler textScaler) {
    if (_textViewportSize == viewport &&
        _systemTextScaler == textScaler &&
        _layoutTextScale == _textScaleMultiplier) {
      return;
    }
    _textViewportSize = viewport;
    _systemTextScaler = textScaler;
    _layoutTextScale = _textScaleMultiplier;
    _scrollTextToOffset(
      _activeEnd > _activeStart ? _activeStart : _cursorOffset,
      endOffset: _activeEnd > _activeStart ? _activeEnd : null,
      centerParagraph: true,
    );
  }

  Rect? _selectionBounds(
    RenderParagraph text,
    RenderBox viewport,
    int start,
    int end, {
    bool firstLineOnly = false,
  }) {
    if (end <= start) return null;
    final boxes = text.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
    );
    Rect? bounds;
    for (final box in boxes) {
      if (firstLineOnly && box.top != boxes.first.top) continue;
      final rect = box.toRect();
      final mapped = Rect.fromPoints(
        text.localToGlobal(rect.topLeft, ancestor: viewport),
        text.localToGlobal(rect.bottomRight, ancestor: viewport),
      );
      bounds = bounds?.expandToInclude(mapped) ?? mapped;
    }
    return bounds;
  }

  void _scrollTextToOffset(
    int offset, {
    int? endOffset,
    bool centerParagraph = false,
  }) {
    _pendingScrollOffset = offset;
    _pendingScrollEnd = endOffset;
    _pendingCenterParagraph |= centerParagraph;
    if (_scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      final targetOffset = _pendingScrollOffset;
      final targetEnd = _pendingScrollEnd;
      final forceCenter = _pendingCenterParagraph;
      _pendingScrollOffset = null;
      _pendingScrollEnd = null;
      _pendingCenterParagraph = false;
      if (!mounted || !_textController.hasClients) return;
      if (targetOffset == null || widget.story.body.isEmpty) return;
      final media = MediaQuery.maybeOf(context);
      if (media?.accessibleNavigation ?? false) return;
      final text = _textLayoutKey.currentContext?.findRenderObject();
      final viewport = _textViewportKey.currentContext?.findRenderObject();
      if (text is! RenderParagraph || viewport is! RenderBox) return;
      final paragraph = _paragraphForOffset(targetOffset);
      final bounds = _selectionBounds(
        text,
        viewport,
        paragraph.start,
        paragraph.end,
      );
      if (bounds == null) return;
      final paragraphChanged =
          _centeredParagraph?.start != paragraph.start ||
          _centeredParagraph?.end != paragraph.end;
      final word = targetEnd == null
          ? null
          : _selectionBounds(
              text,
              viewport,
              targetOffset,
              targetEnd,
              firstLineOnly: true,
            );
      final position = _textController.position;
      final height = viewport.size.height;
      final topInset = math.min(16.0, height * .06);
      final bottomInset = math.min(68.0, height * .45);
      final fitsAtCenter = bounds.height <= height - 2 * bottomInset;
      final paragraphReflowed =
          _centeredParagraphHeight != null &&
          (_centeredParagraphHeight! - bounds.height).abs() >= 1;
      var target = _scrollDestination ?? position.pixels;
      if (fitsAtCenter) {
        if (paragraphChanged || forceCenter || paragraphReflowed) {
          target = position.pixels + bounds.center.dy - height / 2;
        }
        _centeredLineCenter = null;
      } else if (word != null || paragraphChanged || forceCenter) {
        // A tall paragraph cannot fit at the center. Follow its spoken line
        // through the middle of the readable area, above the bottom fade.
        final line =
            word ??
            _selectionBounds(
              text,
              viewport,
              paragraph.start,
              paragraph.start + 1,
            );
        if (line != null) {
          final lineCenter = position.pixels + line.center.dy;
          final lineChanged =
              _centeredLineCenter == null ||
              (_centeredLineCenter! - lineCenter).abs() >= 1;
          if (paragraphChanged || forceCenter || lineChanged) {
            target = lineCenter - (topInset + height - bottomInset) / 2;
          }
          // Successive words on this laid-out line keep the same destination.
          _centeredLineCenter = lineCenter;
        }
      }
      _centeredParagraph = paragraph;
      _centeredParagraphHeight = bounds.height;
      target = target.clamp(position.minScrollExtent, position.maxScrollExtent);
      if ((target - (_scrollDestination ?? position.pixels)).abs() < 1) return;
      final animation = ++_scrollAnimation;
      if (media?.disableAnimations ?? false) {
        _scrollDestination = null;
        _textController.jumpTo(target);
      } else {
        _scrollDestination = target;
        unawaited(
          _textController
              .animateTo(
                target,
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
              )
              .whenComplete(() {
                if (_scrollAnimation == animation) _scrollDestination = null;
              }),
        );
      }
    });
  }

  void _setPlayback(_PlaybackState playback) {
    if (mounted) setState(() => _playback = playback);
  }

  Future<void> _togglePlayback() async {
    if (_narrationBusy ||
        !_appIsActive ||
        !_routeIsActive ||
        _lifecycleStopInFlight ||
        _playback == _PlaybackState.starting ||
        !_canNarrate) {
      return;
    }
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
      stopCurrent:
          _playback == _PlaybackState.paused &&
          !_isHostedNarration(_selectedNarration!),
      resume: _playback == _PlaybackState.paused,
    );
  }

  Future<void> _playFromOffset(
    int requestedOffset, {
    required bool stopCurrent,
    bool resume = false,
  }) async {
    final narration = _selectedNarration;
    final body = widget.story.body;
    if (_narrationBusy ||
        !_appIsActive ||
        !_routeIsActive ||
        _lifecycleStopInFlight ||
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
    int? generation;
    try {
      if (stopCurrent) {
        await _stopForReplacement();
      }
      if (!mounted || !_appIsActive || !_routeIsActive) return;
      setState(() {
        _cursorOffset = offset;
        _activeStart = offset;
        _activeEnd = offset;
        _spokenBaseOffset = offset;
        _playback = _PlaybackState.starting;
      });
      if (!resume) _scrollTextToOffset(offset, centerParagraph: true);
      generation = _beginNarrationSession();
      await _narrationService.speak(
        text: body.substring(offset),
        narration: narration,
        fullText: body,
        startOffset: offset,
        resume: resume,
      );
      _armNarrationStartTimeout(generation);
    } on AppException catch (error) {
      if (mounted &&
          (generation == null || _isCurrentNarrationSession(generation))) {
        _invalidateNarrationSession();
        setState(() {
          _playback = _PlaybackState.idle;
          _playbackMessage = error.userMessage;
        });
      }
    } catch (_) {
      if (mounted &&
          (generation == null || _isCurrentNarrationSession(generation))) {
        _invalidateNarrationSession();
        setState(() {
          _playback = _PlaybackState.idle;
          _playbackMessage = 'This voice cannot read on this device right now.';
        });
      }
    } finally {
      if (mounted) setState(() => _narrationBusy = false);
    }
  }

  void _armNarrationStartTimeout(int generation) {
    if (!_isCurrentNarrationSession(generation) ||
        _playback != _PlaybackState.starting) {
      return;
    }
    _narrationStartTimer?.cancel();
    _narrationStartTimer = Timer(const Duration(seconds: 8), () {
      if (!_isCurrentNarrationSession(generation) ||
          _playback != _PlaybackState.starting) {
        return;
      }
      _invalidateNarrationSession();
      setState(() {
        _playback = _PlaybackState.idle;
        _playbackMessage =
            'This voice took too long to start. Tap play to try again.';
      });
      unawaited(_stopAfterStartTimeout());
    });
  }

  Future<void> _stopAfterStartTimeout() async {
    try {
      await _narrationService.stop();
    } catch (_) {
      // The session is already invalidated; this is cleanup only.
    }
  }

  Future<void> _stopForReplacement() async {
    _invalidateNarrationSession();
    await _narrationService.stop();
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> _pauseNarration() async {
    setState(() => _narrationBusy = true);
    final generation = _activeNarrationGeneration;
    try {
      await _narrationService.pause();
      if (generation != null && _activeNarrationGeneration == generation) {
        _invalidateNarrationSession();
      }
      _setPlayback(_PlaybackState.paused);
      await _saveBookmark();
    } on AppException catch (error) {
      if (mounted) setState(() => _playbackMessage = error.userMessage);
    } catch (_) {
      if (mounted) {
        setState(() => _playbackMessage = 'This voice could not pause.');
      }
    } finally {
      if (mounted) setState(() => _narrationBusy = false);
    }
  }

  Future<void> _restartNarration() async {
    if (_narrationBusy ||
        _playback == _PlaybackState.starting ||
        !_canNarrate) {
      return;
    }
    await _playFromOffset(0, stopCurrent: _playback != _PlaybackState.idle);
  }

  Future<void> _jumpPassage(int direction) async {
    if (_narrationBusy ||
        _playback == _PlaybackState.starting ||
        !_canNarrate ||
        direction == 0) {
      return;
    }
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
      _bookmarkEngaged = true;
      unawaited(_saveBookmark());
      _scrollTextToOffset(target, centerParagraph: true);
    } on AppException catch (error) {
      if (mounted) setState(() => _playbackMessage = error.userMessage);
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
      unawaited(_saveBookmark());
      _scrollTextToOffset(0, centerParagraph: true);
    } on AppException catch (error) {
      if (mounted) setState(() => _playbackMessage = error.userMessage);
    } finally {
      if (mounted) setState(() => _narrationBusy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _appIsActive = true;
      unawaited(_presentMilestone());
      return;
    }
    _appIsActive = false;
    unawaited(_saveBookmark());
    unawaited(_stopNarrationForLifecycle());
  }

  Future<void> _stopNarrationForLifecycle({bool routeCovered = false}) async {
    unawaited(_saveBookmark());
    if (_lifecycleStopInFlight) return;
    final shouldStop =
        _activeNarrationGeneration != null ||
        _playback == _PlaybackState.starting ||
        _playback == _PlaybackState.playing ||
        _playback == _PlaybackState.paused;
    if (!shouldStop) return;

    _lifecycleStopInFlight = true;
    _invalidateNarrationSession();
    if (mounted) {
      setState(() {
        _playback = _PlaybackState.idle;
        _playbackMessage = routeCovered
            ? 'Reading paused while you opened another page. Tap play when you’re ready.'
            : 'Reading paused when the app went into the background. Tap play when you’re ready.';
      });
    }
    try {
      await _narrationService.stop();
    } catch (_) {
      // The active session is already invalidated, so a native stop failure
      // cannot restart narration or corrupt the visible playback state.
    } finally {
      _lifecycleStopInFlight = false;
    }
  }

  void _resetProgress() {
    _activeStart = 0;
    _activeEnd = 0;
    _cursorOffset = 0;
    _spokenBaseOffset = 0;
    _narratedRanges.clear();
    _hostedPosition = Duration.zero;
    _hostedDuration = null;
    _centeredParagraph = null;
    _centeredParagraphHeight = null;
    _centeredLineCenter = null;
  }

  bool _isDeviceNarration(StoryNarration narration) {
    return narration.status.trim().toLowerCase() == 'device_tts';
  }

  bool _isHostedNarration(StoryNarration narration) {
    return narration.status.trim().toLowerCase() == 'ready' &&
        narration.audioAvailable &&
        narration.audioUrl != null;
  }

  bool get _parentAllowsNarration {
    return _settingsResolved &&
        !_settingsFailed &&
        (_readerSettings?.narrationEnabled ?? true);
  }

  bool get _canNarrate {
    final narration = _selectedNarration;
    return isStoryAvailable(widget.story.slug) &&
        widget.story.body.trim().isNotEmpty &&
        narration != null &&
        (_isDeviceNarration(narration) || _isHostedNarration(narration)) &&
        _parentAllowsNarration;
  }

  List<int> get _passageOffsets {
    final body = widget.story.body;
    if (body.trim().isEmpty) return const [0];
    final narration = _selectedNarration;
    if (narration != null && _isHostedNarration(narration)) {
      final segments = narration.segmentsForText(body);
      return [
        0,
        ...segments
            .map((segment) => segment.startOffset)
            .where((offset) => offset > 0),
      ];
    }
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
    final narration = _selectedNarration;
    if (narration != null && _isHostedNarration(narration)) {
      final duration =
          _hostedDuration ?? Duration(seconds: _estimatedDurationSeconds);
      if (duration <= Duration.zero) return 0;
      return (_hostedPosition.inMicroseconds / duration.inMicroseconds).clamp(
        0,
        1,
      );
    }
    final progressOffset = _activeEnd > _cursorOffset
        ? _activeEnd
        : _cursorOffset;
    return (progressOffset / widget.story.body.length).clamp(0, 1);
  }

  int get _estimatedDurationSeconds {
    final narration = _selectedNarration;
    if (narration != null && _isHostedNarration(narration)) {
      if (_hostedDuration != null) return _hostedDuration!.inSeconds;
      if ((narration.durationSeconds ?? 0) > 0) {
        return narration.durationSeconds!;
      }
    }
    if (widget.story.estimatedReadSeconds > 0) {
      return widget.story.estimatedReadSeconds;
    }
    final wordCount = RegExp(r'\S+').allMatches(widget.story.body).length;
    return (wordCount / 2.3).ceil().clamp(1, 60 * 60);
  }

  int get _elapsedSeconds {
    final narration = _selectedNarration;
    if (narration != null && _isHostedNarration(narration)) {
      return _hostedPosition.inSeconds;
    }
    return (_estimatedDurationSeconds * _progress).round();
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
    if (!_isDeviceNarration(narration) && !_isHostedNarration(narration)) {
      return '${narration.characterName}\'s voice is still warming up.';
    }
    if (_playbackMessage != null) return _playbackMessage!;
    return switch (_playback) {
      _PlaybackState.starting => '${narration.characterName} is getting ready…',
      _PlaybackState.playing => '${narration.characterName} is reading.',
      _PlaybackState.paused => 'Paused.',
      _PlaybackState.completed => 'Story complete!',
      _ => 'Tap play to begin.',
    };
  }

  @override
  void dispose() {
    if (_observedRoute != null) appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_saveBookmark());
    _bookmarkTimer?.cancel();
    _invalidateNarrationSession(rebind: false);
    _textController.dispose();
    unawaited(_narrationService.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!isStoryAvailable(widget.story.slug)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Story unavailable')),
        body: const SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'This story is no longer in the library. Choose another adventure.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }
    final activeProfile = _activeProfile;
    if (_completionPresented && activeProfile != null) {
      return StoryCompletionView(
        story: widget.story,
        profile: activeProfile,
        onContinue: _continueAfterCompletion,
        xpAwarded: _storyXpAwarded,
        isContinuing: _continuingAfterCompletion,
      );
    }
    final focusParagraph = _paragraphForOffset(
      _activeEnd > _activeStart ? _activeStart : _cursorOffset,
    );

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
                          child: NotificationListener<ScrollNotification>(
                            onNotification: _handleReadingScroll,
                            child: _ReadAlongTextPanel(
                              storyText: widget.story.body,
                              activeStart: _activeStart,
                              activeEnd: _activeEnd,
                              focusStart: focusParagraph.start,
                              focusEnd: focusParagraph.end,
                              textScaleMultiplier: _textScaleMultiplier,
                              controller: _textController,
                              textLayoutKey: _textLayoutKey,
                              viewportKey: _textViewportKey,
                              onLayout: _handleTextLayout,
                            ),
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
                          elapsedSeconds: _elapsedSeconds,
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
    required this.focusStart,
    required this.focusEnd,
    required this.textScaleMultiplier,
    required this.controller,
    required this.textLayoutKey,
    required this.viewportKey,
    required this.onLayout,
  });

  final String storyText;
  final int activeStart;
  final int activeEnd;
  final int focusStart;
  final int focusEnd;
  final double textScaleMultiplier;
  final ScrollController controller;
  final GlobalKey textLayoutKey;
  final GlobalKey viewportKey;
  final void Function(Size, TextScaler) onLayout;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        onLayout(constraints.biggest, MediaQuery.textScalerOf(context));
        return ClipRect(
          key: viewportKey,
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
                    // Leave enough room to center the first and last paragraph.
                    padding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: constraints.maxHeight / 2,
                    ),
                    child: ExcludeSemantics(
                      child: KeyedSubtree(
                        key: textLayoutKey,
                        child: _HighlightedStoryText(
                          storyText: storyText,
                          activeStart: activeStart,
                          activeEnd: activeEnd,
                          focusStart: focusStart,
                          focusEnd: focusEnd,
                          textScaleMultiplier: textScaleMultiplier,
                        ),
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
      },
    );
  }
}

class _HighlightedStoryText extends StatelessWidget {
  const _HighlightedStoryText({
    required this.storyText,
    required this.activeStart,
    required this.activeEnd,
    required this.focusStart,
    required this.focusEnd,
    required this.textScaleMultiplier,
  });

  final String storyText;
  final int activeStart;
  final int activeEnd;
  final int focusStart;
  final int focusEnd;
  final double textScaleMultiplier;

  @override
  Widget build(BuildContext context) {
    final start = activeStart.clamp(0, storyText.length);
    final end = activeEnd.clamp(start, storyText.length);
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
    required this.elapsedSeconds,
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
  final int elapsedSeconds;
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
    final controlsEnabled = enabled && !busy;
    final isStarting = playback == _PlaybackState.starting;
    final playEnabled = controlsEnabled && !isStarting;
    final playLabel = switch (playback) {
      _PlaybackState.starting => 'Starting story',
      _PlaybackState.playing => 'Pause story',
      _PlaybackState.paused => 'Resume story',
      _ => 'Play story',
    };

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
              onPressed: controlsEnabled && !isStarting ? onRestart : null,
            ),
            _TransportButton(
              key: const Key('read-along-previous'),
              tooltip: 'Previous passage',
              icon: Icons.skip_previous_rounded,
              onPressed: controlsEnabled && !isStarting && canGoPrevious
                  ? onPrevious
                  : null,
            ),
            Semantics(
              button: true,
              enabled: playEnabled,
              label: playLabel,
              child: IconButton.filled(
                key: const Key('read-along-play-pause'),
                tooltip: playLabel,
                onPressed: playEnabled ? onPlayPause : null,
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFFF15F43),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFFD6C9C4),
                  disabledForegroundColor: Colors.white,
                  minimumSize: const Size.square(64),
                  maximumSize: const Size.square(64),
                ),
                icon: busy || isStarting
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
              onPressed: controlsEnabled && !isStarting && canGoNext
                  ? onNext
                  : null,
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

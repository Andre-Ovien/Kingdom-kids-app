import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import '../../../shared/widgets/scoped_feature_page.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../../app/app_route_observer.dart';
import '../../../app/router.dart';
import '../../../core/errors/app_exception.dart';
import '../../../shared/widgets/liquid_glass.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/kid_profile.dart';
import '../../auth/presentation/session_expiry_navigation.dart';
import '../../parental_controls/data/parental_controls_repository.dart';
import '../../parental_controls/domain/parent_settings.dart';
import '../data/story_repository.dart';
import '../data/story_reading_bookmark_store.dart';
import '../domain/story_availability.dart';
import '../domain/story_detail.dart';
import '../domain/story_reading_bookmark.dart';
import 'story_cover_image.dart';

class StoryDetailScreen extends StatefulWidget {
  const StoryDetailScreen({
    required this.story,
    super.key,
    this.repository,
    this.authRepository,
    this.settingsRepository,
    this.bookmarkStore,
    this.resumeReading = false,
  });

  final StoryDetail story;
  final StoryRepository? repository;
  final AuthRepository? authRepository;
  final ParentalControlsRepository? settingsRepository;
  final StoryReadingBookmarkStore? bookmarkStore;
  final bool resumeReading;

  @override
  State<StoryDetailScreen> createState() => _StoryDetailScreenState();
}

class _StoryDetailScreenState extends State<StoryDetailScreen>
    with WidgetsBindingObserver, RouteAware {
  late StoryDetail _story;
  late final StoryRepository _repository;
  late final AuthRepository _authRepository;
  late final ParentalControlsRepository _settingsRepository;
  late final StoryReadingBookmarkStore _bookmarkStore;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _bodyKey = GlobalKey();
  ModalRoute<dynamic>? _observedRoute;
  Timer? _bookmarkTimer;
  StoryReadingBookmark? _savedBookmark;
  bool _bookmarkMetadataResolved = false;
  bool _preferencesResolved = false;
  bool _resumeApplied = false;
  bool _routeIsActive = true;
  bool _userScrolling = false;
  bool _bookmarkDirty = false;
  bool _bookmarkFinished = false;
  bool _captureScheduled = false;
  bool _flushAfterCapture = false;
  int _textOffset = 0;
  DateTime? _lastReadingInteraction;
  KidProfile? _activeProfile;
  ParentSettings? _readerSettings;
  String? _syncMessage;
  late bool _isLoading;
  Map<String, Object?>? _viewMemory;
  Object? _viewScope;
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    _story = isStoryAvailable(widget.story.slug)
        ? widget.story
        : StoryDetail.unavailable;
    if (!isStoryAvailable(widget.story.slug)) {
      _syncMessage =
          'This story is no longer in the library. Choose another adventure.';
    }
    _authRepository = widget.authRepository ?? AuthRepository();
    _repository =
        widget.repository ??
        RemoteStoryRepository(authRepository: _authRepository);
    _settingsRepository =
        widget.settingsRepository ??
        RemoteParentalControlsRepository(authRepository: _authRepository);
    _bookmarkStore = widget.bookmarkStore ?? SecureStoryReadingBookmarkStore();
    WidgetsBinding.instance.addObserver(this);
    _isLoading = _story.slug.isNotEmpty;
    _loadStory();
    _loadActiveProfile();
  }

  Future<void> _loadActiveProfile() async {
    try {
      final profile = await _authRepository.currentKid();
      if (mounted) {
        setState(() {
          _activeProfile = profile;
        });
      }
      if (profile == null) return;
      unawaited(_refreshBookmarkMetadata());
      try {
        final settings = await _settingsRepository.fetchSettings(
          profileId: profile.id,
        );
        if (mounted && _activeProfile?.id == profile.id) {
          setState(() {
            _readerSettings = settings;
          });
        }
      } catch (_) {
        // The story stays readable at the default comfortable size when a
        // parent's saved reading preference cannot be checked.
      }
    } catch (_) {
      // A saved preview remains readable before a profile is selected.
    } finally {
      _preferencesResolved = true;
      _scheduleResume();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_seeded) {
      _seeded = true;
      _viewMemory = FeatureViewMemory.maybeOf(context);
      _viewScope = FeatureViewMemory.scopeOf(context);
      final story = _viewScope == null ? null : _viewMemory?['story'];
      if (story is StoryDetail &&
          story.slug == widget.story.slug &&
          isStoryAvailable(story.slug)) {
        _story = story;
      }
    }
    final route = ModalRoute.of(context);
    if (!identical(route, _observedRoute)) {
      if (_observedRoute != null) appRouteObserver.unsubscribe(this);
      _observedRoute = route;
      if (route != null) appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    unawaited(_saveBookmark());
    _routeIsActive = false;
    _userScrolling = false;
  }

  @override
  void didPopNext() {
    _routeIsActive = true;
    _bookmarkDirty = false;
    _userScrolling = false;
    // A narrated session above this page may have advanced or completed. Its
    // newer cursor/coverage must not be replaced by this page's old viewport.
    unawaited(_refreshBookmarkMetadata());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_saveBookmark());
      _userScrolling = false;
    }
  }

  Future<bool> _scopeStillActive(KidProfile profile) async {
    final session = await _authRepository.restoreSession();
    final selected = await _authRepository.currentKid();
    return session?.parent.id == profile.parentId &&
        selected?.id == profile.id &&
        selected?.parentId == profile.parentId;
  }

  Future<void> _refreshBookmarkMetadata() async {
    final profile = _activeProfile;
    if (profile == null || profile.parentId.isEmpty) return;
    try {
      if (!await _scopeStillActive(profile)) return;
      final bookmarks = await _bookmarkStore.readAll(
        parentId: profile.parentId,
        profileId: profile.id,
      );
      if (!mounted || _activeProfile?.id != profile.id) return;
      _savedBookmark = null;
      for (final saved in bookmarks) {
        if (saved.isForStory(_story)) {
          _savedBookmark = saved;
          break;
        }
      }
    } catch (_) {
      // The story is readable even when local storage is unavailable.
    } finally {
      _bookmarkMetadataResolved = true;
      _scheduleResume();
    }
  }

  void _scheduleResume() {
    if (!mounted ||
        !widget.resumeReading ||
        _resumeApplied ||
        !_preferencesResolved ||
        !_bookmarkMetadataResolved ||
        _isLoading ||
        _story.body.isEmpty) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _resumeApplied || !_scrollController.hasClients) return;
      final paragraph = _bodyKey.currentContext?.findRenderObject();
      if (paragraph is! RenderParagraph || !paragraph.attached) return;
      final offset = _savedBookmark?.resumeOffsetFor(_story) ?? 0;
      final caret = paragraph.getOffsetForCaret(
        TextPosition(offset: offset),
        Rect.zero,
      );
      final top = MediaQuery.paddingOf(context).top + 72;
      final target =
          _scrollController.offset + paragraph.localToGlobal(caret).dy - top;
      _resumeApplied = true;
      _textOffset = offset;
      _scrollController.jumpTo(
        target.clamp(0.0, _scrollController.position.maxScrollExtent),
      );
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  bool _onReadingScroll(ScrollNotification notification) {
    if (!_routeIsActive || notification.depth != 0) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _userScrolling = true;
      _resumeApplied = true;
    }
    if (notification is ScrollUpdateNotification && _userScrolling) {
      _scheduleReadingCapture();
    }
    if (notification is ScrollEndNotification && _userScrolling) {
      _userScrolling = false;
      _scheduleReadingCapture(flush: true);
    }
    return false;
  }

  void _scheduleReadingCapture({bool flush = false}) {
    _flushAfterCapture |= flush;
    if (_captureScheduled) return;
    _captureScheduled = true;
    // Scroll notifications arrive before the viewport has laid out its new
    // offset. Measure the visible text after that frame, not its old position.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _captureScheduled = false;
      final shouldFlush = _flushAfterCapture;
      _flushAfterCapture = false;
      if (!mounted || !_routeIsActive) return;
      _captureReadingPosition();
      if (shouldFlush) unawaited(_saveBookmark());
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _captureReadingPosition() {
    if (_story.id.isEmpty || !isStoryAvailable(_story.slug)) return;
    final paragraph = _bodyKey.currentContext?.findRenderObject();
    if (paragraph is! RenderParagraph || !paragraph.attached) return;
    final padding = MediaQuery.paddingOf(context);
    final top = padding.top + 72;
    final bottom = MediaQuery.sizeOf(context).height - padding.bottom;
    final bodyTop = paragraph.localToGlobal(Offset.zero).dy;
    final bodyBottom = bodyTop + paragraph.size.height;
    if (bodyTop >= bottom || bodyBottom <= top) return;
    final localTop = (top - bodyTop).clamp(0.0, paragraph.size.height);
    _textOffset = paragraph
        .getPositionForOffset(Offset(0, localTop))
        .offset
        .clamp(0, _story.body.length - 1);
    _bookmarkFinished = bodyBottom <= bottom;
    _bookmarkDirty = true;
    _lastReadingInteraction = DateTime.now().toUtc();
    _bookmarkTimer ??= Timer(const Duration(seconds: 5), () {
      _bookmarkTimer = null;
      unawaited(_saveBookmark());
    });
  }

  Future<void> _saveBookmark() async {
    _bookmarkTimer?.cancel();
    _bookmarkTimer = null;
    final profile = _activeProfile;
    if (!_bookmarkDirty ||
        !_routeIsActive ||
        profile == null ||
        profile.parentId.isEmpty ||
        _story.id.isEmpty ||
        _story.body.isEmpty ||
        !isStoryAvailable(_story.slug)) {
      return;
    }
    _bookmarkDirty = false;
    final story = _story;
    final finished = _bookmarkFinished;
    final offset = _textOffset;
    final updatedAt = _lastReadingInteraction ?? DateTime.now().toUtc();
    try {
      if (!await _scopeStillActive(profile)) return;
      // Read the latest coverage even if the page's initial bookmark lookup
      // was still in flight when the child began scrolling.
      final saved = await _bookmarkStore.readAll(
        parentId: profile.parentId,
        profileId: profile.id,
      );
      StoryReadingBookmark? previous;
      for (final bookmark in saved) {
        if (bookmark.isForStory(story)) {
          previous = bookmark;
          break;
        }
      }
      if (previous != null && previous.updatedAt.isAfter(updatedAt)) return;
      final bookmark = StoryReadingBookmark.forStory(
        story: story,
        textOffset: offset,
        updatedAt: updatedAt,
        readingMode: StoryReadingMode.read,
        heardRanges: previous?.hasCurrentBody(story) == true
            ? previous!.heardRanges
            : const [],
      );
      if (finished) {
        await _bookmarkStore.remove(
          parentId: profile.parentId,
          profileId: profile.id,
          storyId: story.id,
        );
      } else {
        await _bookmarkStore.save(
          parentId: profile.parentId,
          profileId: profile.id,
          bookmark: bookmark,
        );
        _savedBookmark = bookmark;
      }
    } catch (_) {
      // Bookmark failures never prevent reading or navigating away.
    }
  }

  Future<void> _loadStory() async {
    if (_story.slug.isEmpty) {
      setState(() => _isLoading = false);
      return;
    }
    try {
      final story = await _repository.fetchStory(_story.slug);
      if (mounted) {
        setState(() {
          _story = story;
          _syncMessage = story.body.trim().isEmpty
              ? 'This story adventure is still being prepared. Please check back soon.'
              : null;
        });
        if (_viewScope != null) _viewMemory?['story'] = story;
      }
    } on AppException catch (error) {
      if (_story.body.isEmpty &&
          mounted &&
          returnToSignInIfSessionExpired(context, error)) {
        return;
      }
      if (mounted) {
        setState(() {
          _syncMessage = _story.body.isEmpty
              ? error.userMessage
              : 'Showing the saved preview. Connect to refresh this story and its voices.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _syncMessage = _story.body.isEmpty
              ? 'We could not open this story. Please try again.'
              : 'Showing the saved preview. Connect to refresh this story and its voices.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
        _scheduleResume();
      }
    }
  }

  Future<void> _openReadAlong() async {
    if (_story.body.trim().isEmpty) return;
    await _saveBookmark();
    if (!mounted || !_routeIsActive) return;
    Navigator.of(
      context,
    ).pushNamed(AppRoutes.storyReadAlong, arguments: _story);
  }

  @override
  Widget build(BuildContext context) {
    final viewPadding = MediaQuery.paddingOf(context);
    final hasFullStory = _story.body.trim().isNotEmpty;

    // The intro glow extends beyond its layout. A viewport skips clipping when
    // all content fits, so contain the page during native push/pop transitions.
    return ClipRect(
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: _detailOverlayStyle(context),
        child: Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: Stack(
            children: [
              NotificationListener<ScrollNotification>(
                onNotification: _onReadingScroll,
                child: CustomScrollView(
                  key: const Key('story-detail-scroll'),
                  controller: _scrollController,
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        24,
                        viewPadding.top,
                        24,
                        viewPadding.bottom + 36,
                      ),
                      sliver: SliverList.list(
                        children: [
                          _StoryIntro(story: _story),
                          if (_isLoading && _story.body.isEmpty) ...[
                            const LinearProgressIndicator(
                              minHeight: 2,
                              color: Color(0xFFFF7043),
                            ),
                            const SizedBox(height: 15),
                          ],
                          if (_syncMessage != null) ...[
                            _StorySyncNotice(
                              message: _syncMessage!,
                              isBlocking: !hasFullStory,
                              onRetry: _loadStory,
                            ),
                            const SizedBox(height: 17),
                          ],
                          _StoryTextHeader(
                            story: _story,
                            label: hasFullStory ? 'The story' : 'Summary',
                          ),
                          const SizedBox(height: 15),
                          if (hasFullStory)
                            KeyedSubtree(
                              key: _bodyKey,
                              child: Text(
                                _story.body,
                                key: const Key('story-reading-text'),
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(
                                      color: _mutedText(context),
                                      fontSize: 16 * _storyTextScaleMultiplier,
                                      height: 1.68,
                                      letterSpacing: 0,
                                    ),
                              ),
                            )
                          else ...[
                            if (_story.summary.trim().isNotEmpty) ...[
                              Text(
                                _story.summary,
                                key: const Key('story-summary-text'),
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(
                                      color: _mutedText(context),
                                      fontSize: 16 * _storyTextScaleMultiplier,
                                      height: 1.68,
                                      letterSpacing: 0,
                                    ),
                              ),
                              const SizedBox(height: 18),
                            ],
                            if (_syncMessage == null)
                              _MissingStoryBody(
                                isLoading: _isLoading,
                                canRetry: _story.slug.isNotEmpty,
                                onRetry: _loadStory,
                              ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: viewPadding.top,
                left: 24,
                right: 24,
                child: _StoryDetailTopBar(
                  readAlongEnabled: hasFullStory,
                  isLoading: _isLoading && !hasFullStory,
                  onReadAlongPressed: _openReadAlong,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  double get _storyTextScaleMultiplier =>
      switch (_readerSettings?.storyTextScale) {
        StoryTextScale.large => 1.2,
        StoryTextScale.extraLarge => 1.4,
        _ => 1,
      };

  @override
  void dispose() {
    unawaited(_saveBookmark());
    _bookmarkTimer?.cancel();
    if (_observedRoute != null) appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }
}

class _StoryIntro extends StatelessWidget {
  const _StoryIntro({required this.story});

  final StoryDetail story;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 312,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: -54,
            left: -180,
            right: -180,
            height: 420,
            child: _StoryCoverGlow(story: story),
          ),
          Positioned(
            top: 54,
            left: 0,
            right: 0,
            child: _StoryCover(story: story),
          ),
          Positioned(
            top: 250,
            left: 0,
            right: 0,
            child: Text(
              story.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 17,
                fontWeight: FontWeight.w700,
                height: 1.08,
              ),
            ),
          ),
          Positioned(
            top: 275,
            left: 0,
            right: 0,
            child: Text(
              story.author,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: _softText(context),
                fontSize: 10,
              ),
            ),
          ),
          Positioned(
            top: 291,
            left: 0,
            right: 0,
            child: _StoryMetadata(story: story),
          ),
        ],
      ),
    );
  }
}

class _StoryDetailTopBar extends StatelessWidget {
  const _StoryDetailTopBar({
    required this.readAlongEnabled,
    required this.isLoading,
    required this.onReadAlongPressed,
  });

  final bool readAlongEnabled;
  final bool isLoading;
  final VoidCallback onReadAlongPressed;

  @override
  Widget build(BuildContext context) {
    final glassOpacity = Theme.of(context).brightness == Brightness.dark
        ? 0.08
        : 0.18;
    final glassBorderOpacity = Theme.of(context).brightness == Brightness.dark
        ? 0.34
        : 0.58;

    return Row(
      children: [
        LiquidGlass(
          borderRadius: 28,
          opacity: glassOpacity,
          blur: 28,
          borderOpacity: glassBorderOpacity,
          child: SizedBox.square(
            dimension: 48,
            child: IconButton(
              tooltip: 'Back',
              padding: EdgeInsets.zero,
              onPressed: () => Navigator.of(context).maybePop(),
              icon: Icon(
                Icons.arrow_back_ios_new_rounded,
                color: _iconText(context),
                size: 23,
                shadows: _iconShadows(context),
              ),
            ),
          ),
        ),
        const Spacer(),
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: readAlongEnabled
                ? const [
                    BoxShadow(
                      color: Color(0x2B1F1930),
                      blurRadius: 0,
                      offset: Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: IconButton(
            key: const Key('story-read-along-button'),
            tooltip: readAlongEnabled
                ? 'Open Read Along'
                : isLoading
                ? 'Read Along is loading'
                : 'Read Along is unavailable',
            padding: EdgeInsets.zero,
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFFFFD23F),
              disabledBackgroundColor: const Color(0xFFE5DDD0),
              fixedSize: const Size.square(48),
              minimumSize: const Size.square(48),
              maximumSize: const Size.square(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: readAlongEnabled
                      ? const Color(0xFF1F1930)
                      : const Color(0xFFAAA19A),
                  width: 1.5,
                ),
              ),
            ),
            onPressed: readAlongEnabled ? onReadAlongPressed : null,
            icon: isLoading
                ? const SizedBox.square(
                    dimension: 21,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Color(0xFF1F1930),
                    ),
                  )
                : Icon(
                    Icons.graphic_eq_rounded,
                    color: readAlongEnabled
                        ? const Color(0xFF1F1930)
                        : const Color(0xFF847A76),
                    size: 27,
                  ),
          ),
        ),
      ],
    );
  }
}

class _StoryCover extends StatelessWidget {
  const _StoryCover({required this.story});

  final StoryDetail story;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 168,
        height: 186,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: const Color(0xFFF4ECE9),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: StoryCoverImage(story: story),
      ),
    );
  }
}

class _StoryCoverGlow extends StatelessWidget {
  const _StoryCoverGlow({required this.story});

  final StoryDetail story;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Opacity(
        opacity: 0.32,
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 38, sigmaY: 38),
          child: Transform.scale(
            scale: 1.22,
            child: StoryCoverImage(story: story),
          ),
        ),
      ),
    );
  }
}

class _StoryMetadata extends StatelessWidget {
  const _StoryMetadata({required this.story});

  final StoryDetail story;

  @override
  Widget build(BuildContext context) {
    final minutes = (story.estimatedReadSeconds / 60).ceil().clamp(1, 99);
    final metadata = [
      if (story.category.trim().isNotEmpty) story.category.trim(),
      if (story.estimatedReadSeconds > 0) '$minutes min read',
    ];
    return Text(
      metadata.join('  •  '),
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: const Color(0xFF9E9293),
        fontSize: 9.5,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _StoryTextHeader extends StatelessWidget {
  const _StoryTextHeader({required this.story, required this.label});

  final StoryDetail story;
  final String label;

  @override
  Widget build(BuildContext context) {
    final minutes = (story.estimatedReadSeconds / 60).ceil().clamp(1, 99);
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: 19,
            fontWeight: FontWeight.w800,
          ),
        ),
        if (story.estimatedReadSeconds > 0) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFFF7043).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text(
              '$minutes min read',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: const Color(0xFFCF5B37),
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _StorySyncNotice extends StatelessWidget {
  const _StorySyncNotice({
    required this.message,
    required this.isBlocking,
    required this.onRetry,
  });

  final String message;
  final bool isBlocking;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onErrorContainer,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: const Key('story-detail-retry-button'),
            onPressed: onRetry,
            child: Text(isBlocking ? 'Try again' : 'Refresh'),
          ),
        ],
      ),
    );
  }
}

class _MissingStoryBody extends StatelessWidget {
  const _MissingStoryBody({
    required this.isLoading,
    required this.canRetry,
    required this.onRetry,
  });

  final bool isLoading;
  final bool canRetry;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: OutlinedButton.icon(
        key: const Key('story-detail-load-button'),
        onPressed: isLoading || !canRetry ? null : onRetry,
        icon: isLoading
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.refresh_rounded),
        label: Text(
          isLoading
              ? 'Loading full story…'
              : canRetry
              ? 'Load the full story'
              : 'Full story unavailable',
        ),
      ),
    );
  }
}

Color _iconText(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFFF8F3EF)
      : const Color(0xFF2A1307);
}

SystemUiOverlayStyle _detailOverlayStyle(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemStatusBarContrastEnforced: false,
    statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
    statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
  );
}

List<Shadow> _iconShadows(BuildContext context) {
  if (Theme.of(context).brightness == Brightness.dark) {
    return [Shadow(color: Colors.black.withValues(alpha: 0.38), blurRadius: 8)];
  }
  return [
    Shadow(color: Colors.white.withValues(alpha: 0.82), blurRadius: 8),
    Shadow(
      color: Colors.black.withValues(alpha: 0.14),
      blurRadius: 2,
      offset: const Offset(0, 1),
    ),
  ];
}

Color _mutedText(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFFC9C0BD)
      : const Color(0xFF746B6B);
}

Color _softText(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF9EA8A6)
      : const Color(0xFFA99E9E);
}

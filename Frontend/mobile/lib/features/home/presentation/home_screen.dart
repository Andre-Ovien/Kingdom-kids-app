import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_route_observer.dart';
import '../../../app/router.dart';
import '../../../core/errors/app_exception.dart';
import '../../../shared/widgets/floating_liquid_nav.dart';
import '../../../shared/widgets/category_filter_pill.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/kid_profile.dart';
import '../../auth/presentation/kid_profile_avatar.dart';
import '../../auth/presentation/session_expiry_navigation.dart';
import '../../milestones/data/level_milestone_store.dart';
import '../../milestones/domain/level_milestone.dart';
import '../../milestones/presentation/level_milestone_presenter.dart';
import '../../profile/data/profile_repository.dart';
import '../../stories/data/story_repository.dart';
import '../../stories/data/story_reading_bookmark_store.dart';
import '../../stories/domain/story_detail.dart';
import '../../stories/domain/story_read_along_arguments.dart';
import '../../stories/domain/story_reading_arguments.dart';
import '../../stories/domain/story_reading_bookmark.dart';
import '../../streak/data/streak_reminder_service.dart';
import '../../streak/data/streak_repository.dart';
import '../../streak/domain/streak_presentation.dart';
import '../../streak/presentation/streak_screen.dart';
import 'continue_reading_carousel.dart';
import 'home_story_card.dart';
import 'home_adventure_carousel.dart';
import 'home_streak_strip.dart';
import '../domain/home_story_selection.dart';

const _homeInk = Color(0xFF171421);
const _homePaper = Color(0xFFFFFCF6);
const _homePurple = Color(0xFFB7A5FF);
const _homePink = Color(0xFFFF9DCF);
const _homeGreen = Color(0xFF6FDB9A);
const _homeCoral = Color(0xFFFF795F);

Color _homeBackground(BuildContext context) => Colors.white;

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.authRepository,
    this.storyRepository,
    this.streakRepository,
    this.profileRepository,
    this.streakReminderService,
    this.milestoneStore,
    this.bookmarkStore,
    this.streakPresentationDelay = const Duration(milliseconds: 700),
  });

  final AuthRepository? authRepository;
  final StoryRepository? storyRepository;
  final StreakRepository? streakRepository;
  final ProfileRepository? profileRepository;
  final StreakReminderService? streakReminderService;
  final LevelMilestoneStore? milestoneStore;
  final StoryReadingBookmarkStore? bookmarkStore;
  final Duration streakPresentationDelay;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, RouteAware {
  late final AuthRepository _authRepository;
  late final StoryRepository _storyRepository;
  late final StreakRepository _streakRepository;
  late final ProfileRepository _profileRepository;
  late final StreakReminderService _streakReminderService;
  late final LevelMilestonePresenter _milestonePresenter;
  late final StoryReadingBookmarkStore _bookmarkStore;
  List<StoryReadingBookmark> _bookmarks = const [];
  String? _openingStoryId;
  String? _resumeError;
  int _bookmarkLoadGeneration = 0;
  bool _routeIsCurrent = true;
  LevelMilestone? _pendingMilestone;
  String? _pendingMilestoneProfileId;
  Future<void>? _milestonePresentationFuture;
  bool _streakPageOpen = false;
  int? _currentStreakDays;
  List<StreakDay> _recentStreakDays = const [];
  DateTime? _streakLocalDate;
  int _streakSummaryGeneration = 0;
  KidProfile? _activeProfile;
  List<StoryDetail> _stories = const [];
  Object? _storiesError;
  bool _isLoadingStories = true;
  String _selectedCategory = 'All';
  bool _streakClaimInFlight = false;
  bool _streakClaimQueued = false;
  int _streakPresentationCycle = 0;
  bool _appIsActive = true;
  ModalRoute<dynamic>? _observedRoute;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appIsActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _authRepository = widget.authRepository ?? AuthRepository();
    _storyRepository =
        widget.storyRepository ??
        RemoteStoryRepository(authRepository: _authRepository);
    _streakRepository =
        widget.streakRepository ??
        RemoteStreakRepository(authRepository: _authRepository);
    _profileRepository =
        widget.profileRepository ??
        RemoteProfileRepository(authRepository: _authRepository);
    _streakReminderService =
        widget.streakReminderService ?? DeviceStreakReminderService();
    _bookmarkStore = widget.bookmarkStore ?? SecureStoryReadingBookmarkStore();
    _milestonePresenter = LevelMilestonePresenter(
      authRepository: _authRepository,
      store: widget.milestoneStore ?? SecureLevelMilestoneStore(),
    );
    _loadActiveProfile();
    _loadStories();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (identical(route, _observedRoute)) return;
    if (_observedRoute != null) {
      appRouteObserver.unsubscribe(this);
    }
    _observedRoute = route;
    _routeIsCurrent = route?.isCurrent ?? true;
    if (route != null) {
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appIsActive = state == AppLifecycleState.resumed;
    if (mounted) setState(() {});
    if (_appIsActive) {
      unawaited(_refreshActiveProfile(refreshReminder: true));
    } else {
      _streakClaimQueued = false;
      _streakPresentationCycle += 1;
    }
  }

  @override
  void didPopNext() {
    setState(() => _routeIsCurrent = true);
    unawaited(_refreshActiveProfile());
  }

  @override
  void didPushNext() {
    setState(() => _routeIsCurrent = false);
  }

  @override
  void dispose() {
    if (_observedRoute != null) {
      appRouteObserver.unsubscribe(this);
    }
    WidgetsBinding.instance.removeObserver(this);
    _streakPresentationCycle += 1;
    _streakSummaryGeneration += 1;
    super.dispose();
  }

  Future<void> _loadActiveProfile() async {
    await _refreshActiveProfile(refreshReminder: true);
  }

  Future<void> _openNotifications(BuildContext homeContext) async {
    final status = Future<bool>.sync(_streakReminderService.isEnabled)
        .then<bool?>(
          (enabled) => enabled,
          onError: (Object _, StackTrace _) => null,
        );
    final manage = await showModalBottomSheet<bool>(
      context: homeContext,
      backgroundColor: Colors.white,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      shape: RoundedSuperellipseBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Notifications',
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              FutureBuilder<bool?>(
                future: status,
                builder: (context, snapshot) {
                  final String title;
                  final String detail;
                  if (snapshot.connectionState != ConnectionState.done) {
                    title = 'Checking reminder settings…';
                    detail = 'Your reminder preference will appear here.';
                  } else if (snapshot.hasError || snapshot.data == null) {
                    title = 'Reminder status is unavailable';
                    detail = 'A parent can check reminders in settings.';
                  } else if (snapshot.data == true) {
                    title = 'Daily reminders are on';
                    detail = 'A gentle nudge for your daily discoveries.';
                  } else {
                    title = 'Daily reminders are off';
                    detail = 'A parent can manage reminders in settings.';
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        key: const Key('home-reminder-status'),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        detail,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('home-manage-reminders'),
                  onPressed: () => Navigator.of(sheetContext).pop(true),
                  child: const Text('Manage reminders'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (manage == true && mounted) {
      await Navigator.of(context).pushNamed(AppRoutes.parentalControls);
    }
  }

  Future<void> _refreshActiveProfile({bool refreshReminder = false}) async {
    try {
      final profile = await _authRepository.currentKid();
      if (!mounted) return;
      if (!identical(_activeProfile, profile)) {
        setState(() {
          if (_activeProfile?.id != profile?.id ||
              _activeProfile?.parentId != profile?.parentId) {
            _bookmarks = const [];
            _resumeError = null;
            _openingStoryId = null;
            _streakSummaryGeneration += 1;
            _currentStreakDays = null;
            _recentStreakDays = const [];
            _streakLocalDate = null;
          }
          _activeProfile = profile;
        });
      }
      unawaited(_loadBookmarks(profile));
      if (profile == null) return;
      await _presentMilestone();
      if (!mounted || _activeProfile?.id != profile.id) return;
      if (refreshReminder) {
        unawaited(
          _streakReminderService
              .refreshAfterAppOpen(profile: profile)
              .catchError((Object _) {}),
        );
      }
      _requestStreakClaim(profile);
    } catch (_) {
      // The story catalogue remains usable without an active child profile.
    }
  }

  Future<void> _loadBookmarks(KidProfile? profile) async {
    final generation = ++_bookmarkLoadGeneration;
    if (profile == null) {
      if (mounted) setState(() => _bookmarks = const []);
      return;
    }
    try {
      final session = await _authRepository.restoreSession();
      if (session?.parent.id != profile.parentId ||
          profile.parentId.trim().isEmpty) {
        if (mounted && generation == _bookmarkLoadGeneration) {
          setState(() => _bookmarks = const []);
        }
        return;
      }
      final bookmarks = await _bookmarkStore.readAll(
        parentId: profile.parentId,
        profileId: profile.id,
      );
      final selected = await _authRepository.currentKid();
      if (!mounted ||
          generation != _bookmarkLoadGeneration ||
          selected?.id != profile.id ||
          selected?.parentId != profile.parentId ||
          _activeProfile?.id != profile.id ||
          _activeProfile?.parentId != profile.parentId) {
        return;
      }
      setState(() => _bookmarks = bookmarks);
    } catch (_) {
      // Optional local reading history must never block the Home catalogue.
      if (mounted && generation == _bookmarkLoadGeneration) {
        setState(() => _bookmarks = const []);
      }
    }
  }

  List<StoryDetail> get _unfinishedStories =>
      unfinishedHomeStories(stories: _stories, bookmarks: _bookmarks);

  StoryDetail? get _dailyStory => selectDailyHomeStory(
    stories: _stories,
    profileId: _activeProfile?.id ?? '',
    localDate: DateTime.now(),
  );

  Future<void> _continueStory(StoryDetail story) async {
    final profile = _activeProfile;
    if (profile == null || _openingStoryId != null) return;
    StoryReadingMode mode = StoryReadingMode.readAlong;
    for (final bookmark in _bookmarks) {
      if (bookmark.isForStory(story)) {
        mode = bookmark.readingMode;
        break;
      }
    }
    setState(() {
      _openingStoryId = story.id;
      _resumeError = null;
    });
    try {
      // Catalogue cards omit the body and narration tracks. Fetch only the
      // selected story, rather than loading every unfinished story on Home.
      final detail = await _storyRepository.fetchStory(story.slug);
      final selected = await _authRepository.currentKid();
      final session = await _authRepository.restoreSession();
      if (!mounted ||
          !_appIsActive ||
          !_routeIsCurrent ||
          selected?.id != profile.id ||
          selected?.parentId != profile.parentId ||
          session?.parent.id != profile.parentId) {
        return;
      }
      if (detail.id != story.id || detail.slug != story.slug) {
        setState(() {
          _resumeError = 'This story changed. Open it from Explore stories.';
        });
        return;
      }
      if (detail.body.trim().isEmpty) {
        setState(() {
          _resumeError =
              'This story is not ready to read yet. Try again later.';
        });
        return;
      }
      await Navigator.of(context).pushNamed(
        mode == StoryReadingMode.read
            ? AppRoutes.storyDetail
            : AppRoutes.storyReadAlong,
        arguments: mode == StoryReadingMode.read
            ? StoryReadingArguments(story: detail, resumeReading: true)
            : StoryReadAlongArguments(story: detail, resumeReading: true),
      );
    } on AppException catch (error) {
      if (!mounted) return;
      if (returnToSignInIfSessionExpired(context, error)) return;
      setState(() => _resumeError = error.userMessage);
    } catch (_) {
      if (mounted) {
        setState(() {
          _resumeError = 'We could not open your story. Please try again.';
        });
      }
    } finally {
      if (mounted && _openingStoryId == story.id) {
        setState(() => _openingStoryId = null);
      }
    }
  }

  void _requestStreakClaim(KidProfile profile) {
    if (!_appIsActive) return;
    if (_streakClaimInFlight) {
      _streakClaimQueued = true;
      return;
    }
    final presentationCycle = ++_streakPresentationCycle;
    unawaited(_claimStreakPresentation(profile, presentationCycle));
  }

  bool _matchesStreakProfile(KidProfile profile) =>
      _activeProfile?.id == profile.id &&
      _activeProfile?.parentId == profile.parentId;

  Future<bool> _storedStreakProfileMatches(KidProfile profile) async {
    final session = await _authRepository.restoreSession();
    final selected = await _authRepository.currentKid();
    return session?.parent.id == profile.parentId &&
        selected?.id == profile.id &&
        selected?.parentId == profile.parentId;
  }

  void _clearStreakSummary() {
    _currentStreakDays = null;
    _recentStreakDays = const [];
    _streakLocalDate = null;
  }

  Future<void> _acceptStreakReceipt(
    KidProfile profile,
    StreakPresentation? presentation,
  ) async {
    // Invalidate an older same-child GET as soon as a newer receipt arrives.
    final generation = ++_streakSummaryGeneration;
    if (!mounted ||
        !_matchesStreakProfile(profile) ||
        presentation == null ||
        presentation.profile.id != profile.id ||
        presentation.profile.parentId != profile.parentId) {
      return;
    }
    try {
      final current = await _storedStreakProfileMatches(profile);
      if (!mounted ||
          generation != _streakSummaryGeneration ||
          !_matchesStreakProfile(profile)) {
        return;
      }
      setState(() {
        if (!current) {
          _clearStreakSummary();
          return;
        }
        _currentStreakDays = presentation.currentDays;
        _recentStreakDays = presentation.recentDays;
        _streakLocalDate = presentation.localDate;
      });
    } catch (_) {
      // Optional summary UI must never interfere with the existing reward flow.
    }
  }

  Future<void> _loadStreakSummary(KidProfile profile) async {
    final generation = ++_streakSummaryGeneration;
    if (!mounted || !_matchesStreakProfile(profile)) return;
    try {
      final permitted = await _storedStreakProfileMatches(profile);
      if (!mounted ||
          generation != _streakSummaryGeneration ||
          !_matchesStreakProfile(profile)) {
        return;
      }
      if (!permitted) {
        setState(_clearStreakSummary);
        return;
      }
      final summary = await _profileRepository.fetchSummary(
        profileId: profile.id,
      );
      final current = await _storedStreakProfileMatches(profile);
      if (!mounted ||
          generation != _streakSummaryGeneration ||
          !_matchesStreakProfile(profile)) {
        return;
      }
      if (!current) {
        setState(_clearStreakSummary);
        return;
      }
      // Summary GET currently omits parent_id; reject an explicit wrong parent.
      if (summary.profile.id != profile.id ||
          (summary.profile.parentId.isNotEmpty &&
              summary.profile.parentId != profile.parentId)) {
        return;
      }
      setState(() {
        _currentStreakDays = summary.activityStreak.currentDays;
        _recentStreakDays = summary.streakWeek?.days ?? const [];
        _streakLocalDate = summary.streakWeek?.localDate;
      });
    } on AppException catch (error) {
      if (mounted &&
          generation == _streakSummaryGeneration &&
          _matchesStreakProfile(profile) &&
          returnToSignInIfSessionExpired(context, error)) {
        if (mounted) setState(_clearStreakSummary);
      }
    } catch (_) {
      // Keep a genuine receipt count if available. Unknown counts stay hidden.
    }
  }

  Future<void> _refreshStreakSummaryFromReceipt(
    KidProfile profile,
    StreakPresentation? presentation,
  ) async {
    await _acceptStreakReceipt(profile, presentation);
    if (mounted && _matchesStreakProfile(profile)) {
      await _loadStreakSummary(profile);
    }
  }

  Future<void> _claimStreakPresentation(
    KidProfile profile,
    int presentationCycle,
  ) async {
    if (!mounted ||
        !_appIsActive ||
        ModalRoute.of(context)?.isCurrent != true ||
        _activeProfile?.id != profile.id) {
      return;
    }
    _streakClaimInFlight = true;
    var summaryLoadStarted = false;
    try {
      final receipt = await _streakRepository.claimPresentation(
        profileId: profile.id,
      );
      final presentation = receipt.presentation;
      summaryLoadStarted = true;
      // Count reads must never delay or replace the existing celebration flow.
      unawaited(_refreshStreakSummaryFromReceipt(profile, presentation));
      if (mounted &&
          _activeProfile?.id == profile.id &&
          receipt.levelMilestone != null) {
        _pendingMilestone = receipt.levelMilestone;
        _pendingMilestoneProfileId = profile.id;
      }
      if (presentation != null &&
          widget.streakPresentationDelay > Duration.zero) {
        await Future<void>.delayed(widget.streakPresentationDelay);
      }
      if (!mounted ||
          presentationCycle != _streakPresentationCycle ||
          !_appIsActive ||
          ModalRoute.of(context)?.isCurrent != true ||
          _activeProfile?.id != profile.id) {
        return;
      }
      if (presentation != null) {
        _streakPageOpen = true;
        try {
          await Navigator.of(context).push<void>(
            MaterialPageRoute(
              settings: const RouteSettings(name: AppRoutes.streak),
              builder: (_) => StreakScreen(
                presentation: presentation,
                xpAwarded: receipt.xpAwarded,
              ),
            ),
          );
        } finally {
          _streakPageOpen = false;
        }
      }
      await _presentMilestone();
    } on AppException catch (error) {
      if (mounted) returnToSignInIfSessionExpired(context, error);
    } catch (_) {
      // Streak presentation is celebratory and must never block Home.
    } finally {
      if (!summaryLoadStarted &&
          mounted &&
          _appIsActive &&
          _matchesStreakProfile(profile)) {
        unawaited(_loadStreakSummary(profile));
      }
      _streakClaimInFlight = false;
      if (_streakClaimQueued && mounted && _appIsActive) {
        _streakClaimQueued = false;
        final activeProfile = _activeProfile;
        if (activeProfile != null &&
            ModalRoute.of(context)?.isCurrent == true) {
          _requestStreakClaim(activeProfile);
        }
      }
    }
  }

  bool get _canPresentMilestone =>
      mounted &&
      _appIsActive &&
      !_streakPageOpen &&
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
    final profileId = _pendingMilestoneProfileId;
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
      _pendingMilestoneProfileId = null;
    }
  }

  Future<void> _loadStories() async {
    setState(() {
      _isLoadingStories = true;
      _storiesError = null;
    });

    try {
      final stories = await _storyRepository.fetchStories();
      if (!mounted) return;
      final availableCategories = stories
          .where((story) => !story.isFeatured)
          .map((story) => story.category.trim())
          .where((category) => category.isNotEmpty)
          .toSet();
      setState(() {
        _stories = stories;
        _isLoadingStories = false;
        if (_selectedCategory != 'All' &&
            !availableCategories.contains(_selectedCategory)) {
          _selectedCategory = 'All';
        }
      });
    } catch (error) {
      if (!mounted) return;
      if (error is AppException &&
          returnToSignInIfSessionExpired(context, error)) {
        return;
      }
      setState(() {
        _storiesError = error;
        _isLoadingStories = false;
      });
    }
  }

  List<StoryDetail> get _catalogueStories =>
      _stories.where((story) => !story.isFeatured).toList(growable: false);

  List<String> get _categories {
    final categories =
        _catalogueStories
            .map((story) => story.category.trim())
            .where((category) => category.isNotEmpty)
            .toSet()
            .toList(growable: false)
          ..sort(
            (left, right) => left.toLowerCase().compareTo(right.toLowerCase()),
          );
    return ['All', ...categories];
  }

  List<StoryDetail> get _filteredStories => _selectedCategory == 'All'
      ? _catalogueStories
      : _catalogueStories
            .where((story) => story.category == _selectedCategory)
            .toList(growable: false);

  List<StoryDetail> get _storyPicks => _filteredStories.take(2).toList();

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: Theme.of(context).colorScheme.copyWith(
          brightness: Brightness.light,
          surface: Colors.white,
          onSurface: _homeInk,
          primary: _homeInk,
          onPrimary: Colors.white,
        ),
        textTheme: Theme.of(
          context,
        ).textTheme.apply(bodyColor: _homeInk, displayColor: _homeInk),
        iconTheme: Theme.of(context).iconTheme.copyWith(color: _homeInk),
      ),
      child: Builder(
        builder: (context) => Scaffold(
          backgroundColor: _homeBackground(context),
          body: SafeArea(
            child: Stack(
              children: [
                CustomScrollView(
                  key: const Key('home-scroll'),
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
                      sliver: SliverList.list(
                        children: [
                          _HomeHeader(
                            profile: _activeProfile,
                            onNotifications: () => _openNotifications(context),
                          ),
                          const SizedBox(height: 22),
                          if (_currentStreakDays case final int days) ...[
                            HomeStreakStrip(
                              currentDays: days,
                              recentDays: _recentStreakDays,
                              localDate: _streakLocalDate,
                            ),
                            const SizedBox(height: 16),
                          ],
                          HomeAdventureCarousel(
                            isActive: _appIsActive && _routeIsCurrent,
                            onRead: () => _openTab(context, AppRoutes.stories),
                            onPlay: () => _openTab(context, AppRoutes.games),
                          ),
                          const SizedBox(height: 27),
                          if (_isLoadingStories)
                            const _StoriesLoadingState()
                          else if (_storiesError != null)
                            _StoriesErrorState(onRetry: _loadStories)
                          else if (_stories.isEmpty)
                            const _StoriesEmptyState()
                          else ...[
                            if (_unfinishedStories.isNotEmpty) ...[
                              const _SectionHeading(title: 'Continue reading'),
                              const SizedBox(height: 12),
                              ContinueReadingCarousel(
                                key: ValueKey(
                                  'continue-${_activeProfile?.parentId}-${_activeProfile?.id}',
                                ),
                                stories: _unfinishedStories,
                                isActive: _appIsActive && _routeIsCurrent,
                                openingStoryId: _openingStoryId,
                                onContinue: _continueStory,
                              ),
                              if (_resumeError != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                    _resumeError!,
                                    key: const Key('home-continue-error'),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ),
                              const SizedBox(height: 30),
                            ] else if (_dailyStory
                                case final StoryDetail story) ...[
                              const _SectionHeading(title: 'Story for the day'),
                              const SizedBox(height: 12),
                              HomeStoryCard(
                                key: const Key('home-story-for-day-card'),
                                story: story,
                                paletteIndex: 0,
                                panelColor: const Color(0xFFFFE4D5),
                                metadata: _storyMetadata(story),
                                onTap: () => _openStoryDetail(context, story),
                              ),
                              const SizedBox(height: 30),
                            ],
                            _SectionHeading(
                              title: 'Explore stories',
                              actionLabel: 'SEE ALL',
                              onAction: () =>
                                  _openTab(context, AppRoutes.stories),
                            ),
                            const SizedBox(height: 13),
                            _CategoryChips(
                              categories: _categories,
                              selectedCategory: _selectedCategory,
                              onSelected: (category) {
                                setState(() => _selectedCategory = category);
                              },
                            ),
                            const SizedBox(height: 18),
                            if (_filteredStories.isEmpty)
                              const _FilteredStoriesEmptyState()
                            else ...[
                              const _SubsectionTitle(title: 'Story picks'),
                              const SizedBox(height: 12),
                              for (
                                var index = 0;
                                index < _storyPicks.length;
                                index++
                              ) ...[
                                HomeStoryCard(
                                  key: ValueKey(
                                    'home-story-pick-${_storyPicks[index].id}',
                                  ),
                                  story: _storyPicks[index],
                                  paletteIndex: index,
                                  metadata: _storyMetadata(_storyPicks[index]),
                                  onTap: () => _openStoryDetail(
                                    context,
                                    _storyPicks[index],
                                  ),
                                ),
                                const SizedBox(height: 15),
                              ],
                            ],
                          ],
                          const SizedBox(height: 110),
                        ],
                      ),
                    ),
                  ],
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: FloatingLiquidNav(
                    selectedRoute: AppRoutes.home,
                    activeProfile: _activeProfile,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void _openStoryDetail(BuildContext context, StoryDetail story) {
  Navigator.of(context).pushNamed(AppRoutes.storyDetail, arguments: story);
}

void _openTab(BuildContext context, String route) {
  Navigator.of(context).pushReplacementNamed(
    route,
    arguments: const TabRouteTransition(fromRoute: AppRoutes.home),
  );
}

String _storyMetadata(StoryDetail story) {
  final parts = <String>[];
  if (story.category.trim().isNotEmpty) parts.add(story.category.trim());
  if (story.estimatedReadSeconds > 0) {
    parts.add('${(story.estimatedReadSeconds / 60).ceil()} min');
  }
  if (parts.isEmpty && story.author.trim().isNotEmpty) {
    parts.add(story.author.trim());
  }
  return parts.join('  •  ');
}

Color _ink(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFFFFFCF6)
    : _homeInk;

Color _paper(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF181B1A)
    : _homePaper;

Color _adaptiveColor(BuildContext context, Color color) {
  if (Theme.of(context).brightness != Brightness.dark) return color;
  return Color.alphaBlend(Colors.black.withValues(alpha: 0.52), color);
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({required this.onNotifications, this.profile});

  final KidProfile? profile;
  final VoidCallback onNotifications;

  @override
  Widget build(BuildContext context) {
    final ink = _ink(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _KidAvatar(profile: profile),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            children: [
              Text(
                profile == null
                    ? 'Hey, explorer!'
                    : 'Hey, ${profile!.displayName}!',
                key: const Key('home-child-name'),
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: ink,
                  fontSize: 20,
                  height: 1.1,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                'Let’s discover together',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: ink.withValues(alpha: 0.6),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        SizedBox.square(
          dimension: 52,
          child: IconButton(
            key: const Key('home-notifications'),
            tooltip: 'Notifications',
            onPressed: onNotifications,
            style: IconButton.styleFrom(
              backgroundColor: Colors.transparent,
              foregroundColor: ink,
              side: BorderSide.none,
              overlayColor: Colors.transparent,
            ),
            icon: const Icon(Icons.notifications_none_rounded, size: 25),
          ),
        ),
      ],
    );
  }
}

class _KidAvatar extends StatelessWidget {
  const _KidAvatar({this.profile});

  final KidProfile? profile;

  @override
  Widget build(BuildContext context) {
    void openProfile() => _openTab(context, AppRoutes.profile);
    return Semantics(
      container: true,
      button: true,
      label: 'Open my profile',
      onTap: openProfile,
      excludeSemantics: true,
      child: Material(
        color: _paper(context),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const Key('home-profile-avatar'),
          excludeFromSemantics: true,
          onTap: openProfile,
          child: SizedBox.square(
            dimension: 52,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: profile == null
                  ? ClipOval(
                      child: Image.asset(
                        'assets/images/characters/kai-avatar.png',
                        fit: BoxFit.cover,
                      ),
                    )
                  : KidProfileAvatar(profile: profile!, size: 51),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, this.actionLabel, this.onAction});

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ink = _ink(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: ink,
                  fontSize: 25,
                  height: 1,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.7,
                ),
              ),
            ],
          ),
        ),
        if (actionLabel != null && onAction != null) ...[
          const SizedBox(width: 10),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onAction,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 7),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      actionLabel!,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: ink,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.arrow_forward_rounded, color: ink, size: 18),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _SubsectionTitle extends StatelessWidget {
  const _SubsectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final ink = _ink(context);
    return Text(
      title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        color: ink,
        fontSize: 21,
        fontWeight: FontWeight.w900,
        letterSpacing: -0.5,
      ),
    );
  }
}

class _CategoryChips extends StatelessWidget {
  const _CategoryChips({
    required this.categories,
    required this.selectedCategory,
    required this.onSelected,
  });

  final List<String> categories;
  final String selectedCategory;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: CategoryFilterPill.railHeight(context),
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      itemCount: categories.length,
      separatorBuilder: (_, _) =>
          const SizedBox(width: CategoryFilterPill.spacing),
      itemBuilder: (context, index) {
        final category = categories[index];
        return CategoryFilterPill(
          key: ValueKey('home-category-$category'),
          label: category,
          selected: category == selectedCategory,
          onTap: () => onSelected(category),
        );
      },
    ),
  );
}

class _StoriesLoadingState extends StatelessWidget {
  const _StoriesLoadingState();

  @override
  Widget build(BuildContext context) {
    return _HomeStateCard(
      key: const Key('home-stories-loading'),
      color: _homePurple,
      icon: Icons.rocket_launch_rounded,
      title: 'Gathering adventures…',
      message: 'The story shelf is getting ready for you.',
      footer: SizedBox.square(
        dimension: 28,
        child: CircularProgressIndicator(strokeWidth: 4, color: _ink(context)),
      ),
    );
  }
}

class _StoriesErrorState extends StatelessWidget {
  const _StoriesErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _HomeStateCard(
      key: const Key('home-stories-error'),
      color: _homeCoral,
      icon: Icons.cloud_off_rounded,
      title: 'Stories couldn\'t load',
      message: 'The cloud took a nap. Check your connection and wake it up!',
      footer: _StateActionButton(
        key: const Key('home-stories-retry'),
        label: 'TRY AGAIN',
        icon: Icons.refresh_rounded,
        onPressed: onRetry,
      ),
    );
  }
}

class _StoriesEmptyState extends StatelessWidget {
  const _StoriesEmptyState();

  @override
  Widget build(BuildContext context) {
    return const _HomeStateCard(
      key: Key('home-stories-empty'),
      color: _homeGreen,
      icon: Icons.auto_stories_rounded,
      title: 'New stories are coming soon',
      message: 'Our storytellers are filling the shelf with something amazing.',
    );
  }
}

class _FilteredStoriesEmptyState extends StatelessWidget {
  const _FilteredStoriesEmptyState();

  @override
  Widget build(BuildContext context) {
    return _HomeStateCard(
      color: _homePink,
      icon: Icons.search_rounded,
      title: 'Nothing hiding here yet!',
      message: 'No stories in this category yet. Try another colorful tab.',
      compact: true,
    );
  }
}

class _HomeStateCard extends StatelessWidget {
  const _HomeStateCard({
    required this.color,
    required this.icon,
    required this.title,
    required this.message,
    this.footer,
    this.compact = false,
    super.key,
  });

  final Color color;
  final IconData icon;
  final String title;
  final String message;
  final Widget? footer;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ink = _ink(context);
    return Container(
      constraints: BoxConstraints(minHeight: compact ? 190 : 276),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(23)),
      child: Material(
        color: _adaptiveColor(context, color),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(23),
          side: BorderSide(color: ink, width: 2.2),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: EdgeInsets.all(compact ? 19 : 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: _paper(context),
                  shape: BoxShape.circle,
                  border: Border.all(color: ink, width: 2.5),
                ),
                child: Icon(icon, color: ink, size: 28),
              ),
              const SizedBox(height: 17),
              Text(
                title,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: ink,
                  fontSize: compact ? 23 : 27,
                  height: 1,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: ink.withValues(alpha: 0.74),
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                ),
              ),
              if (footer != null) ...[const SizedBox(height: 19), footer!],
            ],
          ),
        ),
      ),
    );
  }
}

class _StateActionButton extends StatelessWidget {
  const _StateActionButton({
    required super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ink = _ink(context);
    return FilledButton.icon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: ink,
        foregroundColor: Theme.of(context).brightness == Brightness.dark
            ? _homeInk
            : Colors.white,
        minimumSize: const Size(145, 47),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
      ),
      icon: Icon(icon, size: 19),
      label: Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.6),
      ),
    );
  }
}

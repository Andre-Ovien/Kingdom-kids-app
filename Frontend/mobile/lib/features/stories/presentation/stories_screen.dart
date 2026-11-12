import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../../shared/widgets/scoped_feature_page.dart';

import '../../../app/router.dart';
import '../../../core/errors/app_exception.dart';
import '../../../shared/widgets/floating_liquid_nav.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/kid_profile.dart';
import '../../auth/presentation/session_expiry_navigation.dart';
import '../../home/presentation/home_story_card.dart';
import '../data/story_repository.dart';
import '../domain/story_detail.dart';
import 'story_cover_image.dart';

class StoriesScreen extends StatefulWidget {
  const StoriesScreen({super.key, this.repository, this.authRepository});

  final StoryRepository? repository;
  final AuthRepository? authRepository;

  @override
  State<StoriesScreen> createState() => _StoriesScreenState();
}

class _StoriesScreenState extends State<StoriesScreen> {
  final _searchController = TextEditingController();
  late final StoryRepository _repository;
  late final AuthRepository _authRepository;
  List<StoryDetail> _stories = const [];
  KidProfile? _activeProfile;
  String _query = '';
  String _category = 'All';
  String? _errorMessage;
  bool _isLoading = true;
  Map<String, Object?>? _viewMemory;
  Object? _viewScope;
  FeatureScrollController? _scrollController;

  @override
  void initState() {
    super.initState();
    _authRepository = widget.authRepository ?? AuthRepository();
    _repository =
        widget.repository ??
        RemoteStoryRepository(authRepository: _authRepository);
    _loadLibrary();
    _loadActiveProfile();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_scrollController != null) return;
    _viewMemory = FeatureViewMemory.maybeOf(context);
    _viewScope = FeatureViewMemory.scopeOf(context);
    final stories = _viewScope == null ? null : _viewMemory?['stories'];
    if (stories is List<StoryDetail>) {
      _stories = stories;
      _activeProfile = _viewMemory?['profile'] as KidProfile?;
    }
    _query = _viewMemory?['query'] as String? ?? '';
    _category = _viewMemory?['category'] as String? ?? 'All';
    _searchController.text = _query;
    _scrollController = FeatureScrollController(
      _viewMemory,
      contentReady: stories is List<StoryDetail>,
    );
  }

  @override
  void dispose() {
    _viewMemory?.addAll({
      'query': _query,
      'category': _category,
      'scroll': _scrollController?.rememberedOffset ?? 0.0,
    });
    _scrollController?.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadActiveProfile() async {
    try {
      final profile = await _authRepository.currentKid();
      if (mounted) {
        setState(() => _activeProfile = profile);
        if (_viewScope != null) _viewMemory?['profile'] = profile;
      }
    } catch (_) {
      // Story discovery can continue even when the profile badge is absent.
    }
  }

  Future<void> _loadLibrary() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final stories = await _repository.fetchStories();
      if (!mounted) return;
      final categories = stories.map((story) => story.category).toSet();
      setState(() {
        _stories = stories;
        if (_category != 'All' && !categories.contains(_category)) {
          _category = 'All';
        }
      });
      if (_viewScope != null) _viewMemory?['stories'] = stories;
      _scrollController?.restoreAfterLoad();
    } on AppException catch (error) {
      if (mounted && returnToSignInIfSessionExpired(context, error)) {
        return;
      }
      if (mounted) {
        setState(() => _errorMessage = error.userMessage);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _errorMessage =
              'We could not open the story library. Please try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  List<StoryDetail> get _visibleStories {
    final normalizedQuery = _query.trim().toLowerCase();
    return _stories
        .where((story) {
          final matchesCategory =
              _category == 'All' || story.category == _category;
          final matchesQuery =
              normalizedQuery.isEmpty ||
              story.title.toLowerCase().contains(normalizedQuery) ||
              story.author.toLowerCase().contains(normalizedQuery) ||
              story.category.toLowerCase().contains(normalizedQuery) ||
              story.summary.toLowerCase().contains(normalizedQuery);
          return matchesCategory && matchesQuery;
        })
        .toList(growable: false);
  }

  List<String> get _categories {
    final categories =
        _stories
            .map((story) => story.category.trim())
            .where((category) => category.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    return ['All', ...categories];
  }

  void _setCategory(String category) {
    if (category == _category) return;
    setState(() => _category = category);
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _query = '');
  }

  Future<void> _chooseCategory() async {
    final palette = _StoryPalette.of(context);
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => SafeArea(
        child: Container(
          margin: const EdgeInsets.all(12),
          constraints: const BoxConstraints(maxHeight: 520),
          decoration: BoxDecoration(
            color: palette.paper,
            border: Border.all(color: palette.ink, width: 2),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Material(
            color: Colors.transparent,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
                  child: Text(
                    'PICK A STORY WORLD',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: palette.ink,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.4,
                    ),
                  ),
                ),
                for (final category in _categories)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: ListTile(
                      shape: RoundedRectangleBorder(
                        side: category == _category
                            ? BorderSide(color: palette.ink, width: 2)
                            : BorderSide.none,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      tileColor: category == _category
                          ? const Color(0xFFFFD743)
                          : Colors.transparent,
                      title: Text(
                        category,
                        style: TextStyle(
                          color: palette.ink,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      trailing: category == _category
                          ? Icon(Icons.check_circle, color: palette.ink)
                          : null,
                      onTap: () => Navigator.of(context).pop(category),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      _setCategory(selected);
    }
  }

  void _openStory(StoryDetail story) {
    Navigator.of(context).pushNamed(AppRoutes.storyDetail, arguments: story);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const ink = Color(0xFF121217);
    return Theme(
      data: theme.copyWith(
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: theme.colorScheme.copyWith(
          brightness: Brightness.light,
          surface: Colors.white,
          onSurface: ink,
          primary: ink,
          onPrimary: Colors.white,
        ),
        textTheme: theme.textTheme.apply(bodyColor: ink, displayColor: ink),
        iconTheme: theme.iconTheme.copyWith(color: ink),
      ),
      child: Builder(builder: _buildLibrary),
    );
  }

  Widget _buildLibrary(BuildContext context) {
    final visibleStories = _visibleStories;
    final featuredIndex = visibleStories.isEmpty
        ? -1
        : math.max(0, visibleStories.indexWhere((story) => story.isFeatured));
    final featuredStory = featuredIndex < 0
        ? null
        : visibleStories[featuredIndex];
    final shelfStories = featuredIndex < 0
        ? const <StoryDetail>[]
        : [
            for (var index = 0; index < visibleStories.length; index++)
              if (index != featuredIndex) visibleStories[index],
          ];
    final palette = _StoryPalette.of(context);

    return Scaffold(
      backgroundColor: palette.canvas,
      body: SafeArea(
        child: Stack(
          children: [
            RefreshIndicator(
              color: const Color(0xFFFF5F56),
              onRefresh: () async {
                _authRepository.invalidateFeatureReads();
                await _loadLibrary();
              },
              child: CustomScrollView(
                key: const Key('story-library-scroll'),
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                    sliver: SliverList.list(
                      children: [
                        _LibraryTitle(profile: _activeProfile),
                        const SizedBox(height: 18),
                        _LibrarySearchRow(
                          controller: _searchController,
                          category: _category,
                          hasQuery: _query.isNotEmpty,
                          onChanged: (value) => setState(() => _query = value),
                          onClear: _clearSearch,
                          onFilter: _stories.isEmpty ? null : _chooseCategory,
                        ),
                        const SizedBox(height: 20),
                        if (_errorMessage != null && _stories.isNotEmpty) ...[
                          _StaleLibraryNotice(
                            message: _errorMessage!,
                            onRetry: _loadLibrary,
                          ),
                          const SizedBox(height: 18),
                        ],
                      ],
                    ),
                  ),
                  if (_isLoading && _stories.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: _LibraryLoading(),
                    )
                  else if (_errorMessage != null && _stories.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _LibraryError(
                        message: _errorMessage!,
                        onRetry: _loadLibrary,
                      ),
                    )
                  else if (_stories.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _EmptyStoryLibrary(onRefresh: _loadLibrary),
                    )
                  else if (visibleStories.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _EmptyLibrarySearch(
                        onReset: () {
                          _searchController.clear();
                          setState(() {
                            _query = '';
                            _category = 'All';
                          });
                        },
                      ),
                    )
                  else ...[
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      sliver: SliverToBoxAdapter(
                        child: _FeaturedStoryCard(
                          story: featuredStory!,
                          onTap: () => _openStory(featuredStory),
                        ),
                      ),
                    ),
                    if (shelfStories.isNotEmpty) ...[
                      const SliverPadding(
                        padding: EdgeInsets.fromLTRB(20, 28, 20, 14),
                        sliver: SliverToBoxAdapter(child: _ShelfHeading()),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 124),
                        sliver: SliverLayoutBuilder(
                          builder: (context, constraints) {
                            final width = constraints.crossAxisExtent;
                            final textScale =
                                MediaQuery.textScalerOf(context).scale(14) / 14;
                            final columns = width >= 760
                                ? 3
                                : width < 340
                                ? 1
                                : 2;
                            final scaleAllowance =
                                1 + ((textScale - 1).clamp(0.0, 1.0) * 0.42);
                            final ratio =
                                (columns == 1 ? 1.18 : 0.69) / scaleAllowance;
                            return SliverGrid.builder(
                              itemCount: shelfStories.length,
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    mainAxisSpacing: 18,
                                    crossAxisSpacing: 16,
                                    childAspectRatio: ratio,
                                  ),
                              itemBuilder: (context, index) {
                                final story = shelfStories[index];
                                return _LibraryStoryCard(
                                  story: story,
                                  onTap: () => _openStory(story),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ] else
                      const SliverToBoxAdapter(child: SizedBox(height: 124)),
                  ],
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: FloatingLiquidNav(
                selectedRoute: AppRoutes.stories,
                activeProfile: _activeProfile,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StoryPalette {
  const _StoryPalette({
    required this.canvas,
    required this.paper,
    required this.ink,
    required this.mutedInk,
  });

  final Color canvas;
  final Color paper;
  final Color ink;
  final Color mutedInk;

  factory _StoryPalette.of(BuildContext context) {
    return const _StoryPalette(
      canvas: Colors.white,
      paper: Color(0xFFFFFCF5),
      ink: Color(0xFF121217),
      mutedInk: Color(0xFF352F45),
    );
  }
}

class _LibraryTitle extends StatelessWidget {
  const _LibraryTitle({required this.profile});

  final KidProfile? profile;

  @override
  Widget build(BuildContext context) {
    final palette = _StoryPalette.of(context);
    final name = profile?.displayName.trim();
    return Semantics(
      container: true,
      header: true,
      label: name == null || name.isEmpty
          ? 'Story time'
          : 'Story time for $name',
      child: ExcludeSemantics(
        child: Text(
          'STORY TIME!',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            color: palette.ink,
            fontSize: 24,
            height: 1.1,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.4,
          ),
        ),
      ),
    );
  }
}

class _LibrarySearchRow extends StatelessWidget {
  const _LibrarySearchRow({
    required this.controller,
    required this.category,
    required this.hasQuery,
    required this.onChanged,
    required this.onClear,
    required this.onFilter,
  });

  final TextEditingController controller;
  final String category;
  final bool hasQuery;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final VoidCallback? onFilter;

  @override
  Widget build(BuildContext context) {
    final palette = _StoryPalette.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: TextField(
            key: const Key('story-search-field'),
            controller: controller,
            onChanged: onChanged,
            textInputAction: TextInputAction.search,
            style: TextStyle(
              color: palette.ink,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
            decoration: InputDecoration(
              constraints: const BoxConstraints(minHeight: 48),
              hintText: 'Find an adventure…',
              hintStyle: TextStyle(
                color: palette.mutedInk,
                fontWeight: FontWeight.w600,
              ),
              prefixIcon: Icon(
                Icons.search_rounded,
                color: palette.ink,
                size: 20,
              ),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 44,
                minHeight: 48,
              ),
              suffixIcon: hasQuery
                  ? IconButton(
                      key: const Key('story-search-clear'),
                      tooltip: 'Clear story search',
                      onPressed: onClear,
                      icon: Icon(Icons.close_rounded, color: palette.ink),
                    )
                  : null,
              filled: true,
              fillColor: palette.paper,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: palette.ink, width: 2),
                borderRadius: BorderRadius.circular(99),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: palette.ink, width: 2),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Semantics(
          button: true,
          label: category == 'All'
              ? 'Filter story worlds'
              : 'Filter story worlds. $category selected',
          child: Badge(
            isLabelVisible: category != 'All',
            backgroundColor: const Color(0xFFFF5F56),
            child: IconButton(
              key: const Key('story-filter-button'),
              tooltip: 'Filter story worlds',
              onPressed: onFilter,
              style: IconButton.styleFrom(
                fixedSize: const Size.square(48),
                backgroundColor: palette.paper,
                foregroundColor: const Color(0xFF121217),
                side: BorderSide(color: palette.ink, width: 2),
                shape: const CircleBorder(),
              ),
              icon: const Icon(Icons.filter_list_rounded, size: 21),
            ),
          ),
        ),
      ],
    );
  }
}

class _FeaturedStoryCard extends StatelessWidget {
  const _FeaturedStoryCard({required this.story, required this.onTap});

  final StoryDetail story;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label:
          'Featured story: ${story.title}. ${story.category}. ${_readTime(story)}. Open story.',
      onTap: onTap,
      child: ExcludeSemantics(
        child: HomeStoryCard(
          story: story,
          paletteIndex: 0,
          panelColor: const Color(0xFFFFE4D5),
          onTap: onTap,
          metadata: '${story.category}  •  ${_readTime(story)}',
          tapKey: Key('story-card-${story.slug}'),
        ),
      ),
    );
  }
}

class _ShelfHeading extends StatelessWidget {
  const _ShelfHeading();

  @override
  Widget build(BuildContext context) {
    final palette = _StoryPalette.of(context);
    return Text(
      'MORE BIG ADVENTURES',
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        color: palette.ink,
        fontSize: 19,
        height: 1,
        fontWeight: FontWeight.w900,
        letterSpacing: -0.5,
      ),
    );
  }
}

class _LibraryStoryCard extends StatelessWidget {
  const _LibraryStoryCard({required this.story, required this.onTap});

  final StoryDetail story;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = _StoryPalette.of(context);
    return Semantics(
      button: true,
      label:
          '${story.title}. ${story.category}. ${_readTime(story)}. Open story.',
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: Key('story-card-${story.slug}'),
            borderRadius: BorderRadius.circular(20),
            onTap: onTap,
            child: Ink(
              decoration: BoxDecoration(
                color: palette.paper,
                border: Border.all(color: palette.ink, width: 2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 62,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                      child: StoryCoverImage(
                        story: story,
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 38,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            story.category.toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF5B5362),
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Expanded(
                            child: Text(
                              story.title,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: const Color(0xFF121217),
                                    fontSize: 16,
                                    height: 1,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -0.45,
                                  ),
                            ),
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _readTime(story),
                                  style: const TextStyle(
                                    color: Color(0xFF5B5362),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              const Icon(
                                Icons.arrow_forward_rounded,
                                color: Color(0xFF121217),
                                size: 18,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StaleLibraryNotice extends StatelessWidget {
  const _StaleLibraryNotice({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _OutlinedMessageCard(
      color: const Color(0xFFFFD743),
      icon: Icons.wifi_off_rounded,
      title: 'SHOWING SAVED STORIES',
      message: message,
      actionLabel: 'TRY AGAIN',
      onAction: onRetry,
      compact: true,
    );
  }
}

class _LibraryLoading extends StatelessWidget {
  const _LibraryLoading();

  @override
  Widget build(BuildContext context) {
    final palette = _StoryPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 18, 28, 130),
      child: Center(
        child: Semantics(
          liveRegion: true,
          label: 'Gathering story adventures',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFD743),
                  shape: BoxShape.circle,
                  border: Border.all(color: palette.ink, width: 2),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(19),
                  child: CircularProgressIndicator(
                    color: palette.ink,
                    strokeWidth: 4,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'GATHERING ADVENTURES…',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: palette.ink,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LibraryError extends StatelessWidget {
  const _LibraryError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 130),
      child: Center(
        child: _OutlinedMessageCard(
          color: const Color(0xFFFF9071),
          icon: Icons.cloud_off_rounded,
          title: 'OOPS! STORY CLOUD NAP.',
          message: message,
          actionLabel: 'TRY AGAIN',
          actionKey: const Key('story-library-retry-button'),
          onAction: onRetry,
        ),
      ),
    );
  }
}

class _EmptyStoryLibrary extends StatelessWidget {
  const _EmptyStoryLibrary({required this.onRefresh});

  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 130),
      child: Center(
        child: _OutlinedMessageCard(
          color: const Color(0xFFFFD743),
          icon: Icons.auto_stories_rounded,
          title: 'NEW STORIES ARE ON THE WAY!',
          message:
              'Fresh story adventures are being prepared. Check back soon or refresh now.',
          actionLabel: 'REFRESH STORIES',
          actionKey: const Key('story-library-refresh-button'),
          onAction: onRefresh,
        ),
      ),
    );
  }
}

class _EmptyLibrarySearch extends StatelessWidget {
  const _EmptyLibrarySearch({required this.onReset});

  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 130),
      child: Center(
        child: _OutlinedMessageCard(
          color: const Color(0xFF76D4FF),
          icon: Icons.travel_explore_rounded,
          title: 'NO TALE HIDING HERE!',
          message: 'No stories match that search yet.',
          actionLabel: 'SHOW ALL STORIES',
          actionKey: const Key('story-library-reset-button'),
          onAction: onReset,
        ),
      ),
    );
  }
}

class _OutlinedMessageCard extends StatelessWidget {
  const _OutlinedMessageCard({
    required this.color,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.actionKey,
    this.onAction,
    this.compact = false,
  });

  final Color color;
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final Key? actionKey;
  final VoidCallback? onAction;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = _StoryPalette.of(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 14 : 22),
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: palette.ink, width: 2),
        borderRadius: BorderRadius.circular(22),
      ),
      child: compact
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(icon, color: const Color(0xFF121217), size: 25),
                const SizedBox(width: 12),
                Expanded(
                  child: _MessageCopy(title: title, message: message),
                ),
                if (onAction != null) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: actionLabel,
                    onPressed: onAction,
                    icon: const Icon(
                      Icons.refresh_rounded,
                      color: Color(0xFF121217),
                    ),
                  ),
                ],
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFEF9),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFF121217),
                      width: 2.5,
                    ),
                  ),
                  child: Icon(icon, color: const Color(0xFF121217), size: 34),
                ),
                const SizedBox(height: 16),
                _MessageCopy(title: title, message: message, centered: true),
                if (onAction != null && actionLabel != null) ...[
                  const SizedBox(height: 17),
                  FilledButton.icon(
                    key: actionKey,
                    onPressed: onAction,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF121217),
                      foregroundColor: const Color(0xFFFFFEF9),
                      side: const BorderSide(
                        color: Color(0xFF121217),
                        width: 2,
                      ),
                    ),
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(actionLabel!),
                  ),
                ],
              ],
            ),
    );
  }
}

class _MessageCopy extends StatelessWidget {
  const _MessageCopy({
    required this.title,
    required this.message,
    this.centered = false,
  });

  final String title;
  final String message;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Text(
          title,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: const Color(0xFF121217),
            fontWeight: FontWeight.w900,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          message,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: const Color(0xFF302B32),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

String _readTime(StoryDetail story) {
  final minutes = math.max(1, (story.estimatedReadSeconds / 60).ceil());
  return '$minutes min';
}

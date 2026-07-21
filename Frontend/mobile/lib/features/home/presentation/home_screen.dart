import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../../shared/widgets/floating_liquid_nav.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/kid_profile.dart';
import '../../auth/presentation/kid_profile_avatar.dart';
import '../../stories/data/story_repository.dart';
import '../../stories/domain/story_detail.dart';
import '../../stories/presentation/story_cover_image.dart';

const _homeInk = Color(0xFF171421);
const _homePaper = Color(0xFFFFFCF6);
const _homePurple = Color(0xFFB7A5FF);
const _homePink = Color(0xFFFF9DCF);
const _homeYellow = Color(0xFFFFD34E);
const _homeBlue = Color(0xFF65C8F5);
const _homeGreen = Color(0xFF6FDB9A);
const _homeCoral = Color(0xFFFF795F);

Color _homeBackground(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF473B19)
    : const Color(0xFFF5C84C);

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.authRepository, this.storyRepository});

  final AuthRepository? authRepository;
  final StoryRepository? storyRepository;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final AuthRepository _authRepository;
  late final StoryRepository _storyRepository;
  KidProfile? _activeProfile;
  List<StoryDetail> _stories = const [];
  Object? _storiesError;
  bool _isLoadingStories = true;
  String _selectedCategory = 'All';

  @override
  void initState() {
    super.initState();
    _authRepository = widget.authRepository ?? AuthRepository();
    _storyRepository =
        widget.storyRepository ??
        RemoteStoryRepository(authRepository: _authRepository);
    _loadActiveProfile();
    _loadStories();
  }

  Future<void> _loadActiveProfile() async {
    try {
      final profile = await _authRepository.currentKid();
      if (mounted) setState(() => _activeProfile = profile);
    } catch (_) {
      // The story catalogue remains usable without an active child profile.
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
      setState(() {
        _storiesError = error;
        _isLoadingStories = false;
      });
    }
  }

  List<StoryDetail> get _featuredStories =>
      _stories.where((story) => story.isFeatured).toList(growable: false);

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

  List<StoryDetail> get _moreStories => _filteredStories.skip(2).toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
                      _HomeHeader(profile: _activeProfile),
                      const SizedBox(height: 22),
                      const _SectionHeading(title: 'Pick your adventure'),
                      const SizedBox(height: 12),
                      const _AdventureLauncher(),
                      const SizedBox(height: 27),
                      if (_isLoadingStories)
                        const _StoriesLoadingState()
                      else if (_storiesError != null)
                        _StoriesErrorState(onRetry: _loadStories)
                      else if (_stories.isEmpty)
                        const _StoriesEmptyState()
                      else ...[
                        if (_featuredStories.isNotEmpty) ...[
                          const _SectionHeading(title: 'Ready, set, read!'),
                          const SizedBox(height: 12),
                          _HeroCarousel(stories: _featuredStories),
                          const SizedBox(height: 30),
                        ],
                        _SectionHeading(
                          title: 'Explore stories',
                          actionLabel: 'SEE ALL',
                          onAction: () => _openTab(context, AppRoutes.stories),
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
                            _StoryPickCard(
                              story: _storyPicks[index],
                              paletteIndex: index,
                            ),
                            const SizedBox(height: 15),
                          ],
                          if (_moreStories.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            const _SubsectionTitle(title: 'More stories'),
                            const SizedBox(height: 12),
                            _StoryShelf(stories: _moreStories),
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
  const _HomeHeader({this.profile});

  final KidProfile? profile;

  @override
  Widget build(BuildContext context) {
    final ink = _ink(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                profile == null
                    ? 'Hey, explorer!'
                    : 'Hey, ${profile!.displayName}!',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: ink,
                  fontSize: 34,
                  height: 0.98,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1.1,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                'What will we discover today?',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: ink.withValues(alpha: 0.7),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 14),
        _KidAvatar(profile: profile),
      ],
    );
  }
}

class _KidAvatar extends StatelessWidget {
  const _KidAvatar({this.profile});

  final KidProfile? profile;

  @override
  Widget build(BuildContext context) {
    final ink = _ink(context);
    void openProfile() => _openTab(context, AppRoutes.profile);
    return Semantics(
      container: true,
      button: true,
      label: 'Open my profile',
      onTap: openProfile,
      excludeSemantics: true,
      child: Material(
        color: _paper(context),
        shape: CircleBorder(side: BorderSide(color: ink, width: 2.2)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const Key('home-profile-avatar'),
          excludeFromSemantics: true,
          onTap: openProfile,
          child: SizedBox.square(
            dimension: 59,
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

class _AdventureLauncher extends StatelessWidget {
  const _AdventureLauncher();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _AdventureDoor(
            key: const Key('home-adventure-read'),
            label: 'READ',
            icon: Icons.menu_book_rounded,
            color: _homePurple,
            onTap: () => _openTab(context, AppRoutes.stories),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _AdventureDoor(
            key: const Key('home-adventure-watch'),
            label: 'WATCH',
            icon: Icons.play_arrow_rounded,
            color: _homeBlue,
            onTap: () => _openTab(context, AppRoutes.videos),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _AdventureDoor(
            key: const Key('home-adventure-play'),
            label: 'PLAY',
            icon: Icons.sports_esports_rounded,
            color: _homeCoral,
            onTap: () => _openTab(context, AppRoutes.games),
          ),
        ),
      ],
    );
  }
}

class _AdventureDoor extends StatelessWidget {
  const _AdventureDoor({
    required super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = _ink(context);
    return Semantics(
      button: true,
      label: '$label adventures',
      onTap: onTap,
      excludeSemantics: true,
      child: Container(
        height: 92,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(18)),
        child: Material(
          color: _adaptiveColor(context, color),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: ink, width: 2.2),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            excludeFromSemantics: true,
            onTap: onTap,
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 8, 9),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Icon(icon, color: ink, size: 29),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          label,
                          maxLines: 1,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: ink,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.7,
                              ),
                        ),
                      ),
                    ],
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

class _HeroCarousel extends StatefulWidget {
  const _HeroCarousel({required this.stories});

  final List<StoryDetail> stories;

  @override
  State<_HeroCarousel> createState() => _HeroCarouselState();
}

class _HeroCarouselState extends State<_HeroCarousel> {
  late final PageController _pageController;
  Timer? _slideTimer;
  int _currentIndex = 0;
  bool? _motionEnabled;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.96);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    final motionEnabled =
        !media.disableAnimations && !media.accessibleNavigation;
    if (_motionEnabled == motionEnabled) return;
    _motionEnabled = motionEnabled;
    _configureTimer();
  }

  @override
  void didUpdateWidget(covariant _HeroCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_currentIndex >= widget.stories.length) _currentIndex = 0;
    if (oldWidget.stories.length != widget.stories.length) _configureTimer();
  }

  void _configureTimer() {
    _slideTimer?.cancel();
    _slideTimer = null;
    if (_motionEnabled != true || widget.stories.length < 2) return;
    _slideTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_pageController.hasClients || widget.stories.isEmpty) return;
      final nextIndex = (_currentIndex + 1) % widget.stories.length;
      _pageController.animateToPage(
        nextIndex,
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _slideTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(
      context,
    ).scale(1).clamp(1, 3).toDouble();
    final heroHeight = 315 + ((textScale - 1) * 160);
    return Column(
      children: [
        SizedBox(
          key: const Key('home-featured-carousel'),
          height: heroHeight,
          child: PageView.builder(
            controller: _pageController,
            clipBehavior: Clip.hardEdge,
            itemCount: widget.stories.length,
            onPageChanged: (index) => setState(() => _currentIndex = index),
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.only(right: 10),
              child: _HeroStoryCard(
                story: widget.stories[index],
                paletteIndex: index,
              ),
            ),
          ),
        ),
        if (widget.stories.length > 1) ...[
          const SizedBox(height: 9),
          _HeroDots(count: widget.stories.length, currentIndex: _currentIndex),
        ],
      ],
    );
  }
}

class _HeroStoryCard extends StatelessWidget {
  const _HeroStoryCard({required this.story, required this.paletteIndex});

  final StoryDetail story;
  final int paletteIndex;

  @override
  Widget build(BuildContext context) {
    final ink = _ink(context);
    final palette = [_homePurple, _homePink, _homeGreen, _homeYellow];
    final color = _adaptiveColor(
      context,
      palette[paletteIndex % palette.length],
    );
    return Semantics(
      button: true,
      label: 'Open ${story.title} story',
      child: Container(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(24)),
        child: Material(
          color: color,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: ink, width: 2.2),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _openStoryDetail(context, story),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(17, 15, 15, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: _OutlinedLabel(
                                label: story.category.isEmpty
                                    ? 'BIBLE STORY'
                                    : story.category.toUpperCase(),
                              ),
                            ),
                            const Spacer(),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          story.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                color: ink,
                                fontSize: 28,
                                height: 0.95,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -1,
                              ),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          story.summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: ink.withValues(alpha: 0.77),
                                fontWeight: FontWeight.w600,
                                height: 1.2,
                              ),
                        ),
                        const Spacer(),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _storyMetadata(story),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: ink,
                                      fontWeight: FontWeight.w900,
                                    ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: ink,
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  MediaQuery.withClampedTextScaling(
                                    maxScaleFactor: 1.25,
                                    child: Text(
                                      'READ NOW',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color:
                                                Theme.of(context).brightness ==
                                                    Brightness.dark
                                                ? _homeInk
                                                : Colors.white,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: 0.5,
                                          ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(
                                    Icons.arrow_forward_rounded,
                                    color:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? _homeInk
                                        : Colors.white,
                                    size: 16,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Container(
                  height: 127,
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: ink, width: 2.2)),
                  ),
                  child: StoryCoverImage(story: story),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OutlinedLabel extends StatelessWidget {
  const _OutlinedLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ink = _ink(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: _paper(context),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: ink, width: 2),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: ink,
          fontSize: 9.5,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.7,
        ),
      ),
    );
  }
}

class _HeroDots extends StatelessWidget {
  const _HeroDots({required this.count, required this.currentIndex});

  final int count;
  final int currentIndex;

  @override
  Widget build(BuildContext context) {
    final ink = _ink(context);
    return Semantics(
      label: 'Featured story ${currentIndex + 1} of $count',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(count, (index) {
          final selected = index == currentIndex;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: selected ? 27 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: selected
                  ? _adaptiveColor(context, _homeCoral)
                  : ink.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(99),
              border: selected ? Border.all(color: ink, width: 1.5) : null,
            ),
          );
        }),
      ),
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
  Widget build(BuildContext context) {
    return SizedBox(
      height: 47,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: categories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final category = categories[index];
          final selected = category == selectedCategory;
          final ink = _ink(context);
          return Semantics(
            selected: selected,
            button: true,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(99),
              ),
              child: Material(
                color: selected
                    ? _adaptiveColor(context, _homePurple)
                    : _paper(context),
                shape: StadiumBorder(side: BorderSide(color: ink, width: 2)),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: ValueKey('home-category-$category'),
                  onTap: () => onSelected(category),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 9,
                    ),
                    child: Text(
                      category,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: ink,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _StoryPickCard extends StatelessWidget {
  const _StoryPickCard({required this.story, required this.paletteIndex});

  final StoryDetail story;
  final int paletteIndex;

  @override
  Widget build(BuildContext context) {
    final ink = _ink(context);
    final colors = [_homeGreen, _homePink, _homeBlue, _homeYellow];
    final color = _adaptiveColor(context, colors[paletteIndex % colors.length]);
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    return LayoutBuilder(
      builder: (context, constraints) {
        final vertical = constraints.maxWidth < 335 || textScale > 1.15;
        final cover = SizedBox(
          height: vertical ? 150 : double.infinity,
          width: vertical ? double.infinity : 116,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                right: vertical
                    ? BorderSide.none
                    : BorderSide(color: ink, width: 2.2),
                bottom: vertical
                    ? BorderSide(color: ink, width: 2.2)
                    : BorderSide.none,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: StoryCoverImage(story: story),
          ),
        );
        final details = Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                story.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: ink,
                  fontSize: 19,
                  height: 1,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.45,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                story.summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: ink.withValues(alpha: 0.72),
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _storyMetadata(story),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: ink,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 37,
                    height: 37,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(color: ink, width: 2),
                    ),
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      color: ink,
                      size: 21,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
        return Semantics(
          button: true,
          label: 'Read ${story.title}',
          child: Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(20)),
            child: Material(
              color: _paper(context),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: ink, width: 2.2),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _openStoryDetail(context, story),
                child: vertical
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [cover, details],
                      )
                    : SizedBox(
                        height: 166,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            cover,
                            Expanded(child: details),
                          ],
                        ),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StoryShelf extends StatelessWidget {
  const _StoryShelf({required this.stories});

  final List<StoryDetail> stories;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(
      context,
    ).scale(1).clamp(1, 2).toDouble();
    return SizedBox(
      height: 236 + ((scale - 1) * 42),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: stories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (context, index) =>
            _StoryCard(story: stories[index], paletteIndex: index),
      ),
    );
  }
}

class _StoryCard extends StatelessWidget {
  const _StoryCard({required this.story, required this.paletteIndex});

  final StoryDetail story;
  final int paletteIndex;

  @override
  Widget build(BuildContext context) {
    final ink = _ink(context);
    final colors = [_homeYellow, _homePurple, _homeCoral, _homeGreen];
    final color = _adaptiveColor(context, colors[paletteIndex % colors.length]);
    return Semantics(
      button: true,
      label: 'Read ${story.title}',
      child: Container(
        width: 169,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(18)),
        child: Material(
          color: _paper(context),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: ink, width: 2.2),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _openStoryDetail(context, story),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: ink, width: 2.2),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: StoryCoverImage(story: story),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(11, 9, 10, 9),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              story.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(
                                    color: ink,
                                    height: 1.05,
                                    fontWeight: FontWeight.w900,
                                  ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              _storyMetadata(story),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: ink.withValues(alpha: 0.68),
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 5),
                      Container(
                        width: 29,
                        height: 29,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(color: ink, width: 1.7),
                        ),
                        child: Icon(
                          Icons.arrow_outward_rounded,
                          color: ink,
                          size: 17,
                        ),
                      ),
                    ],
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

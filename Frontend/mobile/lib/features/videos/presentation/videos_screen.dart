import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../../shared/widgets/floating_liquid_nav.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/kid_profile.dart';
import '../data/video_repository.dart';
import '../domain/video_story.dart';

const _watchInk = Color(0xFF14131B);
const _watchYellow = Color(0xFFFFCB35);
const _watchCoral = Color(0xFFFF7658);
const _watchBlue = Color(0xFF62C7F2);
const _watchPurple = Color(0xFF9478FF);
const _watchMint = Color(0xFF62DDA2);

class VideosScreen extends StatefulWidget {
  const VideosScreen({super.key, this.authRepository});

  final AuthRepository? authRepository;

  @override
  State<VideosScreen> createState() => _VideosScreenState();
}

class _VideosScreenState extends State<VideosScreen> {
  static const _allCategory = 'All';

  final _searchController = TextEditingController();
  late final AuthRepository _authRepository;
  KidProfile? _activeProfile;
  String _query = '';
  String _selectedCategory = _allCategory;

  @override
  void initState() {
    super.initState();
    _authRepository = widget.authRepository ?? AuthRepository();
    _loadActiveProfile();
  }

  Future<void> _loadActiveProfile() async {
    try {
      final profile = await _authRepository.currentKid();
      if (mounted) setState(() => _activeProfile = profile);
    } catch (_) {
      // The video catalogue remains available if profile lookup is unavailable.
    }
  }

  List<String> get _categories => <String>{
    _allCategory,
    ...VideoRepository.items.map((video) => video.category),
  }.toList(growable: false);

  List<VideoStory> get _visibleVideos {
    final normalizedQuery = _query.trim().toLowerCase();
    return VideoRepository.items
        .where((video) {
          final matchesCategory =
              _selectedCategory == _allCategory ||
              video.category == _selectedCategory;
          final matchesQuery =
              normalizedQuery.isEmpty ||
              video.title.toLowerCase().contains(normalizedQuery) ||
              video.category.toLowerCase().contains(normalizedQuery) ||
              video.description.toLowerCase().contains(normalizedQuery);
          return matchesCategory && matchesQuery;
        })
        .toList(growable: false);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    final videos = _visibleVideos;
    final continueVideos = videos
        .where((video) => video.progress > 0)
        .toList(growable: false);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = isDark ? const Color(0xFF173747) : _watchBlue;

    return Scaffold(
      key: const Key('videos-screen'),
      backgroundColor: background,
      body: SafeArea(
        child: Stack(
          children: [
            CustomScrollView(
              key: const Key('videos-scroll-view'),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  sliver: SliverList.list(
                    children: [
                      const _WatchHeader(),
                      const SizedBox(height: 19),
                      _VideoSearchField(
                        controller: _searchController,
                        query: _query,
                        onChanged: (value) => setState(() => _query = value),
                        onClear: _clearSearch,
                      ),
                      const SizedBox(height: 15),
                      _VideoCategories(
                        categories: _categories,
                        selected: _selectedCategory,
                        onSelected: (category) {
                          setState(() => _selectedCategory = category);
                        },
                      ),
                      const SizedBox(height: 21),
                      if (videos.isNotEmpty) ...[
                        _FeaturedVideoCard(video: videos.first),
                        if (continueVideos.isNotEmpty) ...[
                          const SizedBox(height: 27),
                          const _WatchSectionHeader(
                            eyebrow: 'JUMP BACK IN',
                            title: 'Keep the adventure going',
                            accent: _watchCoral,
                          ),
                          const SizedBox(height: 12),
                          _ContinueVideoShelf(videos: continueVideos),
                        ],
                        const SizedBox(height: 29),
                        _WatchSectionHeader(
                          eyebrow: 'CHOOSE YOUR SHOW',
                          title: _selectedCategory == _allCategory
                              ? 'Pick your next story'
                              : 'More $_selectedCategory adventures',
                          accent: _watchPurple,
                          count: videos.length,
                        ),
                        const SizedBox(height: 14),
                      ] else ...[
                        _NoVideosFound(
                          onReset: () {
                            _searchController.clear();
                            setState(() {
                              _query = '';
                              _selectedCategory = _allCategory;
                            });
                          },
                        ),
                        const SizedBox(height: 24),
                      ],
                    ],
                  ),
                ),
                if (videos.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 124),
                    sliver: SliverLayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.crossAxisExtent;
                        final textScale =
                            MediaQuery.textScalerOf(context).scale(14) / 14;
                        final columns = textScale > 1.45
                            ? 1
                            : width >= 760
                            ? 3
                            : width < 350
                            ? 1
                            : 2;
                        final aspectRatio = columns == 1
                            ? (textScale > 2.4
                                  ? 0.48
                                  : textScale > 1.45
                                  ? 0.62
                                  : 0.92)
                            : (textScale > 1.25 ? 0.56 : 0.68);
                        return SliverGrid.builder(
                          itemCount: videos.length,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                mainAxisSpacing: 22,
                                crossAxisSpacing: 15,
                                childAspectRatio: aspectRatio,
                              ),
                          itemBuilder: (context, index) {
                            return _VideoGridCard(
                              video: videos[index],
                              color: _videoColor(index),
                            );
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: FloatingLiquidNav(
                selectedRoute: AppRoutes.videos,
                activeProfile: _activeProfile,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _openVideo(BuildContext context, VideoStory video) {
  Navigator.of(context).pushNamed(AppRoutes.videoDetail, arguments: video);
}

Color _videoColor(int index) {
  const colors = [
    _watchBlue,
    _watchYellow,
    _watchMint,
    _watchPurple,
    _watchCoral,
  ];
  return colors[index % colors.length];
}

class _WatchHeader extends StatelessWidget {
  const _WatchHeader();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? Colors.white : _watchInk;
    return Semantics(
      header: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Watch &\nwonder!',
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    color: ink,
                    fontSize: 38,
                    height: 0.95,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1.8,
                  ),
                ),
                const SizedBox(height: 9),
                Text(
                  'Big Bible adventures, ready when you are.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: ink.withValues(alpha: 0.72),
                    fontSize: 14,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: _watchYellow,
              border: Border.all(color: ink, width: 2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(Icons.live_tv_rounded, color: ink, size: 36),
          ),
        ],
      ),
    );
  }
}

class _StickerLabel extends StatelessWidget {
  const _StickerLabel({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: _watchInk, width: 2),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: _watchInk,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.75,
        ),
      ),
    );
  }
}

class _VideoSearchField extends StatelessWidget {
  const _VideoSearchField({
    required this.controller,
    required this.query,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final String query;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? Colors.white : _watchInk;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF262331) : Colors.white,
        border: Border.all(color: ink, width: 2),
        borderRadius: BorderRadius.circular(18),
      ),
      child: TextField(
        key: const Key('video-search-field'),
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: ink,
          fontWeight: FontWeight.w700,
        ),
        decoration: InputDecoration(
          hintText: 'What do you want to watch?',
          hintStyle: TextStyle(
            color: ink.withValues(alpha: 0.48),
            fontWeight: FontWeight.w600,
          ),
          prefixIcon: Icon(Icons.search_rounded, color: ink, size: 25),
          suffixIcon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            child: query.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    key: const Key('video-search-clear'),
                    tooltip: 'Clear search',
                    onPressed: onClear,
                    icon: Icon(Icons.close_rounded, color: ink),
                  ),
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }
}

class _FeaturedVideoCard extends StatelessWidget {
  const _FeaturedVideoCard({required this.video});

  final VideoStory video;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Featured video: ${video.title}, ${video.duration}',
      child: _BouncyTap(
        key: ValueKey('watch-featured-card-${video.id}'),
        onTap: () => _openVideo(context, video),
        child: Container(
          height: 286,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(22)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: _watchInk, width: 2),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(
                    video.imageAsset,
                    fit: BoxFit.cover,
                    alignment: video.imageAlignment,
                  ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x16000000),
                          Color(0x22000000),
                          Color(0xE6000000),
                        ],
                        stops: [0, 0.42, 1],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 15,
                    top: 15,
                    child: _StickerLabel(
                      label: 'TODAY\'S BIG ADVENTURE',
                      color: _watchYellow,
                    ),
                  ),
                  Positioned(
                    right: 15,
                    top: 14,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(color: _watchInk, width: 2),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        video.duration,
                        style: const TextStyle(
                          color: _watchInk,
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 17,
                    right: 17,
                    bottom: 17,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                video.category.toUpperCase(),
                                style: const TextStyle(
                                  color: _watchYellow,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                video.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(
                                      color: Colors.white,
                                      fontSize: 27,
                                      height: 0.98,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: -0.8,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 14),
                        Container(
                          width: 58,
                          height: 58,
                          decoration: BoxDecoration(
                            color: _watchCoral,
                            shape: BoxShape.circle,
                            border: Border.all(color: _watchInk, width: 2),
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 38,
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
      ),
    );
  }
}

class _WatchSectionHeader extends StatelessWidget {
  const _WatchSectionHeader({
    required this.eyebrow,
    required this.title,
    required this.accent,
    this.count,
  });

  final String eyebrow;
  final String title;
  final Color accent;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? Colors.white : _watchInk;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                eyebrow,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: ink.withValues(alpha: 0.76),
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.3,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: ink,
                  fontSize: 23,
                  height: 1,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.7,
                ),
              ),
            ],
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            decoration: BoxDecoration(
              color: accent,
              border: Border.all(color: _watchInk, width: 2),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$count SHOWS',
              style: const TextStyle(
                color: _watchInk,
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.7,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ContinueVideoShelf extends StatelessWidget {
  const _ContinueVideoShelf({required this.videos});

  final List<VideoStory> videos;

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return SizedBox(
      height: textScale > 1.35 ? 190 : 151,
      child: ListView.separated(
        key: const Key('continue-video-shelf'),
        clipBehavior: Clip.none,
        scrollDirection: Axis.horizontal,
        itemCount: videos.length,
        separatorBuilder: (_, _) => const SizedBox(width: 13),
        itemBuilder: (context, index) {
          return _ContinueVideoCard(
            video: videos[index],
            color: _videoColor(index + 2),
          );
        },
      ),
    );
  }
}

class _ContinueVideoCard extends StatelessWidget {
  const _ContinueVideoCard({required this.video, required this.color});

  final VideoStory video;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF262331) : Colors.white;
    final ink = isDark ? Colors.white : _watchInk;
    return Semantics(
      button: true,
      label:
          'Continue ${video.title}, ${_progressPercent(video)} percent watched',
      child: _BouncyTap(
        onTap: () => _openVideo(context, video),
        child: Container(
          width: 284,
          decoration: BoxDecoration(
            color: surface,
            border: Border.all(color: ink, width: 2),
            borderRadius: BorderRadius.circular(20),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              SizedBox(
                width: 112,
                height: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.asset(
                      video.imageAsset,
                      fit: BoxFit.cover,
                      alignment: video.imageAlignment,
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(height: 8, color: color),
                    ),
                    Center(
                      child: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(color: _watchInk, width: 2),
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: _watchInk,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(13, 13, 13, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        video.category.toUpperCase(),
                        style: TextStyle(
                          color: ink.withValues(alpha: 0.68),
                          fontSize: 9.5,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Expanded(
                        child: Text(
                          video.title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: ink,
                                fontSize: 16,
                                height: 1.05,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.35,
                              ),
                        ),
                      ),
                      Text(
                        '${_minutesLeft(video)} min left',
                        style: TextStyle(
                          color: ink.withValues(alpha: 0.58),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: LinearProgressIndicator(
                          value: video.progress,
                          minHeight: 7,
                          backgroundColor: ink.withValues(alpha: 0.12),
                          valueColor: AlwaysStoppedAnimation(color),
                        ),
                      ),
                    ],
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

class _VideoCategories extends StatelessWidget {
  const _VideoCategories({
    required this.categories,
    required this.selected,
    required this.onSelected,
  });

  final List<String> categories;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? Colors.white : _watchInk;
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return Semantics(
      label: 'Video categories',
      child: SizedBox(
        height: 43 + math.max(0, textScale - 1) * 20,
        child: ListView.separated(
          key: const Key('video-category-list'),
          clipBehavior: Clip.none,
          scrollDirection: Axis.horizontal,
          itemCount: categories.length,
          separatorBuilder: (_, _) => const SizedBox(width: 9),
          itemBuilder: (context, index) {
            final category = categories[index];
            final isSelected = category == selected;
            final color = _videoColor(index);
            return ChoiceChip(
              key: ValueKey('video-category-$category'),
              selected: isSelected,
              showCheckmark: false,
              label: Text(category),
              onSelected: (_) => onSelected(category),
              selectedColor: color,
              backgroundColor: isDark ? const Color(0xFF262331) : Colors.white,
              side: BorderSide(color: ink, width: 2),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: ink,
                fontWeight: FontWeight.w900,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            );
          },
        ),
      ),
    );
  }
}

class _VideoGridCard extends StatelessWidget {
  const _VideoGridCard({required this.video, required this.color});

  final VideoStory video;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF262331) : Colors.white;
    final ink = isDark ? Colors.white : _watchInk;
    return Semantics(
      button: true,
      label: '${video.title}, ${video.category}, ${video.duration}',
      child: _BouncyTap(
        key: ValueKey('video-card-${video.id}'),
        onTap: () => _openVideo(context, video),
        child: Container(
          decoration: BoxDecoration(
            color: surface,
            border: Border.all(color: ink, width: 2),
            borderRadius: BorderRadius.circular(21),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 58,
                child: SizedBox(
                  width: double.infinity,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.asset(
                        video.imageAsset,
                        fit: BoxFit.cover,
                        alignment: video.imageAlignment,
                      ),
                      Positioned(
                        left: 9,
                        top: 9,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: color,
                            border: Border.all(color: _watchInk, width: 1.8),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            video.duration,
                            style: const TextStyle(
                              color: _watchInk,
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
                      Center(
                        child: Container(
                          width: 47,
                          height: 47,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.94),
                            shape: BoxShape.circle,
                            border: Border.all(color: _watchInk, width: 2),
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: _watchInk,
                            size: 30,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Container(height: 2.5, color: ink),
              Expanded(
                flex: 42,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(12, 11, 11, 11),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        video.category.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: ink.withValues(alpha: 0.68),
                          fontSize: 9.5,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Expanded(
                        child: Text(
                          video.title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: ink,
                                fontSize: 16.5,
                                height: 1.02,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.45,
                              ),
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'PRESS PLAY',
                              style: TextStyle(
                                color: ink,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.9,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.arrow_forward_rounded,
                            color: ink,
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
    );
  }
}

class _NoVideosFound extends StatelessWidget {
  const _NoVideosFound({required this.onReset});

  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF262331) : Colors.white;
    final ink = isDark ? Colors.white : _watchInk;
    return Container(
      key: const Key('videos-empty-state'),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: surface,
        border: Border.all(color: ink, width: 2),
        borderRadius: BorderRadius.circular(25),
      ),
      child: Column(
        children: [
          Container(
            width: 86,
            height: 70,
            decoration: BoxDecoration(
              color: _watchYellow,
              border: Border.all(color: _watchInk, width: 2),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(Icons.tv_off_rounded, color: _watchInk, size: 38),
          ),
          const SizedBox(height: 19),
          Text(
            'No show hiding here!',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: ink,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.7,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            'Try another word or open the whole video shelf.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: ink.withValues(alpha: 0.66),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 17),
          FilledButton.icon(
            key: const Key('video-filter-reset'),
            style: FilledButton.styleFrom(
              backgroundColor: _watchYellow,
              foregroundColor: _watchInk,
              side: const BorderSide(color: _watchInk, width: 2.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              textStyle: const TextStyle(fontWeight: FontWeight.w900),
            ),
            onPressed: onReset,
            icon: const Icon(Icons.replay_rounded),
            label: const Text('Show me everything'),
          ),
        ],
      ),
    );
  }
}

class _BouncyTap extends StatefulWidget {
  const _BouncyTap({required this.onTap, required this.child, super.key});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_BouncyTap> createState() => _BouncyTapState();
}

class _BouncyTapState extends State<_BouncyTap> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return Listener(
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) => setState(() => _pressed = false),
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed && !reduceMotion ? 0.975 : 1,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOutBack,
          child: widget.child,
        ),
      ),
    );
  }
}

int _progressPercent(VideoStory video) => (video.progress * 100).round();

int _minutesLeft(VideoStory video) {
  final total = int.tryParse(video.duration.split(' ').first) ?? 1;
  return math.max(1, (total * (1 - video.progress)).ceil());
}

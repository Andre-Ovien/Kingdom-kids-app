import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../../shared/widgets/floating_liquid_nav.dart';
import '../../../shared/widgets/liquid_glass.dart';
import '../data/video_repository.dart';
import '../domain/video_story.dart';

class VideosScreen extends StatelessWidget {
  const VideosScreen({super.key});

  static const _categories = ['All', 'Jesus', 'Heroes', 'Miracles', 'Songs'];

  @override
  Widget build(BuildContext context) {
    const videos = VideoRepository.items;
    final continueVideos = videos.where((video) => video.progress > 0).toList();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Stack(
          children: [
            CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
                  sliver: SliverList.list(
                    children: [
                      const _WatchTitle(),
                      const SizedBox(height: 20),
                      const _VideoSearchRow(),
                      const SizedBox(height: 20),
                      _FeaturedVideoCard(video: videos.first),
                      const SizedBox(height: 22),
                      const _WatchSectionHeader(title: 'Continue watching'),
                      const SizedBox(height: 12),
                      for (final video in continueVideos.take(2)) ...[
                        _ContinueVideoRow(video: video),
                        const SizedBox(height: 14),
                      ],
                      const SizedBox(height: 4),
                      const _WatchSectionHeader(title: 'Video library'),
                      const SizedBox(height: 12),
                      const _VideoCategories(categories: _categories),
                      const SizedBox(height: 18),
                    ],
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 116),
                  sliver: SliverGrid.builder(
                    itemCount: videos.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 24,
                          crossAxisSpacing: 18,
                          childAspectRatio: 0.72,
                        ),
                    itemBuilder: (context, index) {
                      return _VideoGridCard(video: videos[index]);
                    },
                  ),
                ),
              ],
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: FloatingLiquidNav(selectedRoute: AppRoutes.videos),
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

class _WatchTitle extends StatelessWidget {
  const _WatchTitle();

  @override
  Widget build(BuildContext context) {
    return Text(
      'Watch',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        color: Theme.of(context).colorScheme.onSurface,
        fontSize: 22,
        fontWeight: FontWeight.w400,
        height: 1.1,
        letterSpacing: 0,
      ),
    );
  }
}

class _VideoSearchRow extends StatelessWidget {
  const _VideoSearchRow();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fieldColor = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : const Color(0xFFF7F0F1).withValues(alpha: 0.64);
    final hintColor = isDark
        ? const Color(0xFFE7DEDC)
        : const Color(0xFF8F8384);

    return Row(
      children: [
        Expanded(
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: fieldColor,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              children: [
                Icon(Icons.search_rounded, color: hintColor, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Search videos',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: hintColor,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 14),
        IconButton(
          visualDensity: VisualDensity.compact,
          color: isDark ? const Color(0xFFD8CECC) : const Color(0xFF786E6F),
          onPressed: () {},
          icon: const Icon(Icons.tune_rounded, size: 22),
        ),
      ],
    );
  }
}

class _FeaturedVideoCard extends StatelessWidget {
  const _FeaturedVideoCard({required this.video});

  final VideoStory video;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openVideo(context, video),
          child: SizedBox(
            height: 198,
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
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Color(0xD7000000),
                        Color(0x78000000),
                        Color(0x12000000),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  right: 14,
                  top: 14,
                  child: LiquidGlass(
                    borderRadius: 28,
                    opacity: 0.1,
                    blur: 26,
                    borderOpacity: 0.42,
                    child: SizedBox.square(
                      dimension: 48,
                      child: Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 32,
                        shadows: [
                          Shadow(
                            color: Colors.black.withValues(alpha: 0.34),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _VideoBadge(label: 'Bible video'),
                      const Spacer(),
                      Text(
                        video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w500,
                          height: 1.02,
                          letterSpacing: 0,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '${video.duration}  •  ${video.category}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.86),
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0,
                        ),
                      ),
                      const SizedBox(height: 11),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFFF7043),
                          foregroundColor: Colors.white,
                          minimumSize: const Size(118, 36),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          textStyle: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0,
                          ),
                        ),
                        onPressed: () => _openVideo(context, video),
                        icon: const Icon(Icons.play_arrow_rounded, size: 18),
                        label: const Text('Watch now'),
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

class _VideoBadge extends StatelessWidget {
  const _VideoBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: const Color(0xFFFF7043),
            fontSize: 10,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}

class _WatchSectionHeader extends StatelessWidget {
  const _WatchSectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 17,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
            ),
          ),
        ),
        Text(
          'See all',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: const Color(0xFFFF7043),
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
          ),
        ),
      ],
    );
  }
}

class _ContinueVideoRow extends StatelessWidget {
  const _ContinueVideoRow({required this.video});

  final VideoStory video;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _openVideo(context, video),
      child: Row(
        children: [
          _VideoThumb(video: video, width: 84, height: 58, radius: 13),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  video.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: video.progress,
                    minHeight: 5,
                    backgroundColor: _isDark(context)
                        ? Colors.white.withValues(alpha: 0.12)
                        : const Color(0xFFF1E7E5),
                    valueColor: const AlwaysStoppedAnimation(Color(0xFFFF7043)),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${((1 - video.progress) * 5).ceil()} min left',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: _mutedText(context),
                    fontSize: 11.5,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(
              color: Color(0xFFFF7043),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.play_arrow_rounded,
              color: Colors.white,
              size: 24,
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoCategories extends StatelessWidget {
  const _VideoCategories({required this.categories});

  final List<String> categories;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: categories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final selected = index == 0;

          return ChoiceChip(
            selected: selected,
            showCheckmark: false,
            label: Text(categories[index]),
            selectedColor: const Color(0xFFFF7043),
            backgroundColor: _isDark(context)
                ? Colors.white.withValues(alpha: 0.08)
                : const Color(0xFFF7F0F1).withValues(alpha: 0.64),
            side: BorderSide.none,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
            ),
            labelStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: selected ? Colors.white : _secondaryText(context),
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
            ),
            onSelected: (_) {},
          );
        },
      ),
    );
  }
}

class _VideoGridCard extends StatelessWidget {
  const _VideoGridCard({required this.video});

  final VideoStory video;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _openVideo(context, video),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _VideoThumb(video: video, width: double.infinity),
          ),
          const SizedBox(height: 8),
          Text(
            video.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 14.5,
              fontWeight: FontWeight.w400,
              height: 1.05,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${video.duration}  •  ${video.category}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: _mutedText(context),
              fontSize: 11,
              height: 1.1,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoThumb extends StatelessWidget {
  const _VideoThumb({
    required this.video,
    required this.width,
    this.height,
    this.radius = 14,
  });

  final VideoStory video;
  final double width;
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              video.imageAsset,
              fit: BoxFit.cover,
              alignment: video.imageAlignment,
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.38),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            Center(
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.34),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.42),
                    width: 1,
                  ),
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

Color _mutedText(BuildContext context) {
  return _isDark(context) ? const Color(0xFF9EA8A6) : const Color(0xFFB8ADAE);
}

Color _secondaryText(BuildContext context) {
  return _isDark(context) ? const Color(0xFFC4BCBA) : const Color(0xFF6B5F5F);
}

import 'package:flutter/material.dart';

import '../../../shared/widgets/liquid_glass.dart';
import '../data/video_repository.dart';
import '../domain/video_story.dart';

class VideoWatchScreen extends StatelessWidget {
  const VideoWatchScreen({required this.video, super.key});

  final VideoStory video;

  @override
  Widget build(BuildContext context) {
    final related = VideoRepository.items
        .where((item) => item.id != video.id)
        .take(3)
        .toList();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 36),
              sliver: SliverList.list(
                children: [
                  const _VideoWatchTopBar(),
                  const SizedBox(height: 18),
                  _VideoPlayerCard(video: video),
                  const SizedBox(height: 22),
                  _VideoInfo(video: video),
                  const SizedBox(height: 28),
                  Text(
                    'More to watch',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 14),
                  for (final item in related) ...[
                    _RelatedVideoRow(video: item),
                    const SizedBox(height: 14),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoWatchTopBar extends StatelessWidget {
  const _VideoWatchTopBar();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        LiquidGlass(
          borderRadius: 28,
          opacity: _isDark(context) ? 0.08 : 0.18,
          blur: 28,
          borderOpacity: _isDark(context) ? 0.34 : 0.58,
          child: SizedBox.square(
            dimension: 48,
            child: IconButton(
              padding: EdgeInsets.zero,
              onPressed: () => Navigator.of(context).maybePop(),
              icon: Icon(
                Icons.arrow_back_ios_new_rounded,
                color: _primaryText(context),
                size: 22,
              ),
            ),
          ),
        ),
        Expanded(
          child: Text(
            'Watch',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: _primaryText(context),
              fontSize: 21,
              fontWeight: FontWeight.w400,
              letterSpacing: 0,
            ),
          ),
        ),
        const SizedBox(width: 48),
      ],
    );
  }
}

class _VideoPlayerCard extends StatelessWidget {
  const _VideoPlayerCard({required this.video});

  final VideoStory video;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: AspectRatio(
        aspectRatio: 16 / 10,
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
                    Colors.black.withValues(alpha: 0.64),
                    Colors.black.withValues(alpha: 0.08),
                  ],
                ),
              ),
            ),
            Center(
              child: LiquidGlass(
                borderRadius: 36,
                opacity: 0.1,
                blur: 28,
                borderOpacity: 0.48,
                child: const SizedBox.square(
                  dimension: 68,
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 46,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        video.duration,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0,
                        ),
                      ),
                      const Spacer(),
                      const Icon(
                        Icons.fullscreen_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: video.progress == 0 ? 0.18 : video.progress,
                      minHeight: 4,
                      backgroundColor: Colors.white.withValues(alpha: 0.28),
                      valueColor: const AlwaysStoppedAnimation(
                        Color(0xFFFF7043),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoInfo extends StatelessWidget {
  const _VideoInfo({required this.video});

  final VideoStory video;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          video.title,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: _primaryText(context),
            fontSize: 25,
            fontWeight: FontWeight.w500,
            height: 1.08,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Icon(
              Icons.play_circle_fill_rounded,
              color: Color(0xFFFF7043),
              size: 18,
            ),
            const SizedBox(width: 6),
            Text(
              '${video.duration}  •  ${video.category}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: _mutedText(context),
                fontSize: 12.5,
                fontWeight: FontWeight.w400,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          video.description,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: _secondaryText(context),
            fontSize: 13.4,
            height: 1.46,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFF7043),
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () {},
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Play video'),
              ),
            ),
            const SizedBox(width: 12),
            LiquidGlass(
              borderRadius: 26,
              opacity: _isDark(context) ? 0.06 : 0.2,
              blur: 24,
              borderOpacity: _isDark(context) ? 0.26 : 0.52,
              child: SizedBox.square(
                dimension: 48,
                child: Icon(
                  Icons.download_rounded,
                  color: _primaryText(context),
                  size: 22,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _RelatedVideoRow extends StatelessWidget {
  const _RelatedVideoRow({required this.video});

  final VideoStory video;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => VideoWatchScreen(video: video),
          ),
        );
      },
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(13),
            child: SizedBox(
              width: 92,
              height: 62,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(
                    video.imageAsset,
                    fit: BoxFit.cover,
                    alignment: video.imageAlignment,
                  ),
                  Center(
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.34),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
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
                    color: _primaryText(context),
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${video.duration}  •  ${video.category}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: _mutedText(context),
                    fontSize: 11.5,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

bool _isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

Color _primaryText(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface;

Color _mutedText(BuildContext context) {
  return _isDark(context) ? const Color(0xFF9EA8A6) : const Color(0xFFB8ADAE);
}

Color _secondaryText(BuildContext context) {
  return _isDark(context) ? const Color(0xFFC9C0BD) : const Color(0xFF847A7A);
}

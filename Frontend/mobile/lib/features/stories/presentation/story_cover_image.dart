import 'package:flutter/material.dart';

import '../domain/story_detail.dart';

class StoryCoverImage extends StatelessWidget {
  const StoryCoverImage({
    required this.story,
    this.fit = BoxFit.cover,
    this.borderRadius,
    super.key,
  });

  final StoryDetail story;
  final BoxFit fit;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final image = story.hasHostedCover
        ? Image.network(
            story.coverImageUrl!,
            fit: fit,
            alignment: story.imageAlignment,
            errorBuilder: (_, _, _) =>
                _AssetOrPlaceholder(story: story, fit: fit),
            loadingBuilder: (context, child, progress) {
              if (progress == null) {
                return child;
              }
              return _CoverPlaceholder(progress: progress);
            },
          )
        : _AssetOrPlaceholder(story: story, fit: fit);

    if (borderRadius == null) {
      return image;
    }
    return ClipRRect(borderRadius: borderRadius!, child: image);
  }
}

class _AssetOrPlaceholder extends StatelessWidget {
  const _AssetOrPlaceholder({required this.story, required this.fit});

  final StoryDetail story;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    if (story.coverAssetKey.isEmpty) {
      return const _CoverPlaceholder();
    }
    return Image.asset(
      story.coverAssetKey,
      fit: fit,
      alignment: story.imageAlignment,
      errorBuilder: (_, _, _) => const _CoverPlaceholder(),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder({this.progress});

  final ImageChunkEvent? progress;

  @override
  Widget build(BuildContext context) {
    final expected = progress?.expectedTotalBytes;
    final value = expected == null
        ? null
        : progress!.cumulativeBytesLoaded / expected;
    return ColoredBox(
      color: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF292D2D)
          : const Color(0xFFF4ECE9),
      child: Center(
        child: progress == null
            ? const Icon(
                Icons.auto_stories_rounded,
                color: Color(0xFFD69A87),
                size: 34,
              )
            : SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(
                  value: value,
                  strokeWidth: 2.2,
                  color: const Color(0xFFFF7043),
                ),
              ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../core/media/content_media_fetcher.dart';
import '../../../core/media/content_media_image.dart';
import '../domain/story_detail.dart';

class StoryCoverImage extends StatelessWidget {
  const StoryCoverImage({
    required this.story,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.mediaPolicy = AppConfig.contentMediaPolicy,
    this.mediaFetcher,
    super.key,
  });

  final StoryDetail story;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final ContentMediaPolicy mediaPolicy;
  final ContentMediaFetcher? mediaFetcher;

  @override
  Widget build(BuildContext context) {
    final image = ContentMediaImage(
      source: story.coverImageUrl,
      mediaPolicy: mediaPolicy,
      mediaFetcher: mediaFetcher,
      fit: fit,
      alignment: story.imageAlignment,
      loadingBuilder: (_) => const _CoverPlaceholder(isLoading: true),
      errorBuilder: (_) => _AssetOrPlaceholder(story: story, fit: fit),
    );

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
    return LayoutBuilder(
      builder: (context, constraints) => Image.asset(
        story.coverAssetKey,
        cacheWidth: contentImageDecodeWidth(context, constraints),
        fit: fit,
        alignment: story.imageAlignment,
        errorBuilder: (_, _, _) => const _CoverPlaceholder(),
      ),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder({this.isLoading = false});

  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF292D2D)
          : const Color(0xFFF4ECE9),
      child: Center(
        child: !isLoading
            ? const Icon(
                Icons.auto_stories_rounded,
                color: Color(0xFFD69A87),
                size: 34,
              )
            : SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: const Color(0xFFFF7043),
                ),
              ),
      ),
    );
  }
}

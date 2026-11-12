import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../core/media/content_media_fetcher.dart';
import '../../../core/media/content_media_image.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/data/media_access_scope.dart';
import '../data/story_repository.dart';
import '../domain/story_detail.dart';

class StoryCoverImage extends StatefulWidget {
  const StoryCoverImage({
    required this.story,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.mediaPolicy = AppConfig.contentMediaPolicy,
    this.mediaFetcher,
    this.authRepository,
    this.storyRepository,
    super.key,
  });

  final StoryDetail story;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final ContentMediaPolicy mediaPolicy;
  final ContentMediaFetcher? mediaFetcher;
  final AuthRepository? authRepository;
  final StoryRepository? storyRepository;

  @override
  State<StoryCoverImage> createState() => _StoryCoverImageState();
}

class _StoryCoverImageState extends State<StoryCoverImage> {
  Future<Object?> Function()? _refreshSource;

  @override
  void initState() {
    super.initState();
    _configureScope();
  }

  @override
  void didUpdateWidget(StoryCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.story.id != widget.story.id ||
        oldWidget.story.slug != widget.story.slug ||
        oldWidget.story.coverImageUrl != widget.story.coverImageUrl ||
        !identical(oldWidget.authRepository, widget.authRepository) ||
        !identical(oldWidget.storyRepository, widget.storyRepository)) {
      _configureScope();
    }
  }

  void _configureScope() {
    final original = widget.story;
    if (!canRefreshPrivateImageSource(original.coverImageUrl)) {
      _refreshSource = null;
      return;
    }
    final auth = widget.authRepository ?? AuthRepository();
    final scope = MediaAccessScope(auth);
    final repository =
        widget.storyRepository ?? RemoteStoryRepository(authRepository: auth);
    _refreshSource = () async {
      await scope.requireCurrent();
      final fresh = await repository.fetchStory(original.slug);
      await scope.requireCurrent();
      if (!mounted ||
          original.id.isEmpty ||
          fresh.id != original.id ||
          fresh.slug != original.slug ||
          widget.story.id != original.id ||
          widget.story.slug != original.slug) {
        return null;
      }
      return fresh.coverImageUrl;
    };
  }

  @override
  Widget build(BuildContext context) {
    final story = widget.story,
        fit = widget.fit,
        borderRadius = widget.borderRadius;
    final image = ContentMediaImage(
      source: story.coverImageUrl,
      mediaPolicy: widget.mediaPolicy,
      mediaFetcher: widget.mediaFetcher,
      sourceRefresher: _refreshSource,
      fit: fit,
      alignment: story.imageAlignment,
      loadingBuilder: (_) => const _CoverPlaceholder(isLoading: true),
      errorBuilder: (_) => _AssetOrPlaceholder(story: story, fit: fit),
    );

    if (borderRadius == null) {
      return image;
    }
    return ClipRRect(borderRadius: borderRadius, child: image);
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

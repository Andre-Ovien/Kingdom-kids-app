import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/router.dart';
import '../../../shared/widgets/liquid_glass.dart';
import '../domain/story_detail.dart';

class StoryDetailScreen extends StatelessWidget {
  const StoryDetailScreen({required this.story, super.key});

  final StoryDetail story;

  @override
  Widget build(BuildContext context) {
    final viewPadding = MediaQuery.paddingOf(context);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _detailOverlayStyle(context),
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: Stack(
          children: [
            CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    24,
                    viewPadding.top,
                    24,
                    viewPadding.bottom + 96,
                  ),
                  sliver: SliverList.list(
                    children: [
                      _StoryIntro(story: story),
                      const SizedBox(height: 24),
                      const _DescriptionHeader(),
                      const SizedBox(height: 17),
                      Text(
                        story.description,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: _mutedText(context),
                          fontSize: 13.4,
                          height: 1.48,
                          letterSpacing: 0,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Positioned(
              top: viewPadding.top,
              left: 24,
              right: 24,
              child: const _StoryDetailTopBar(),
            ),
            Positioned(
              left: 24,
              right: 24,
              bottom: viewPadding.bottom + 18,
              child: const _StartReadingButton(),
            ),
          ],
        ),
      ),
    );
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
                fontSize: 16.5,
                fontWeight: FontWeight.w500,
                height: 1.08,
                letterSpacing: 0,
              ),
            ),
          ),
          Positioned(
            top: 273,
            left: 0,
            right: 0,
            child: Text(
              story.author,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: _softText(context),
                fontSize: 9.5,
                height: 1.1,
                letterSpacing: 0,
              ),
            ),
          ),
          Positioned(
            top: 288,
            left: 0,
            right: 0,
            child: _StoryRating(story: story),
          ),
        ],
      ),
    );
  }
}

class _StoryDetailTopBar extends StatelessWidget {
  const _StoryDetailTopBar();

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
        LiquidGlass(
          borderRadius: 28,
          opacity: glassOpacity,
          blur: 28,
          borderOpacity: glassBorderOpacity,
          child: SizedBox(
            width: 62,
            height: 48,
            child: IconButton(
              padding: EdgeInsets.zero,
              onPressed: () {},
              icon: Icon(
                Icons.more_horiz_rounded,
                color: _iconText(context),
                size: 27,
                shadows: _iconShadows(context),
              ),
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
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Image.asset(
          story.imageAsset,
          fit: BoxFit.cover,
          alignment: story.imageAlignment,
        ),
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
        opacity: 0.34,
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 38, sigmaY: 38),
          child: Transform.scale(
            scale: 1.22,
            child: Image.asset(
              story.imageAsset,
              fit: BoxFit.cover,
              alignment: story.imageAlignment,
            ),
          ),
        ),
      ),
    );
  }
}

class _StoryRating extends StatelessWidget {
  const _StoryRating({required this.story});

  final StoryDetail story;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.star_rounded, color: Color(0xFFFFB642), size: 12.5),
        const SizedBox(width: 3),
        Text(
          '${story.rating} (${story.reviewCount})',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: const Color(0xFFB6ABAB),
            fontSize: 9.5,
            height: 1.1,
            letterSpacing: 0,
          ),
        ),
      ],
    );
  }
}

class _DescriptionHeader extends StatelessWidget {
  const _DescriptionHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          'Description',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: 17,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
          ),
        ),
        const Spacer(),
        const Icon(Icons.favorite_rounded, color: Color(0xFFFF7043), size: 23),
      ],
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
      : const Color(0xFF847A7A);
}

Color _softText(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF9EA8A6)
      : const Color(0xFFC2B8B8);
}

class _StartReadingButton extends StatelessWidget {
  const _StartReadingButton();

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFFFF7043),
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
      onPressed: () => Navigator.of(context).pushNamed(AppRoutes.bible),
      child: const Text('Start Reading'),
    );
  }
}

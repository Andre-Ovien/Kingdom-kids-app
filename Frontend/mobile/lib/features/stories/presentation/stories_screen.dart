import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../../shared/widgets/floating_liquid_nav.dart';
import '../data/story_catalog.dart';
import '../domain/story_detail.dart';

class StoriesScreen extends StatelessWidget {
  const StoriesScreen({super.key});

  @override
  Widget build(BuildContext context) {
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
                    children: const [
                      _LibraryTitle(),
                      SizedBox(height: 20),
                      _LibrarySearchRow(),
                      SizedBox(height: 20),
                    ],
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 112),
                  sliver: SliverGrid.builder(
                    itemCount: StoryCatalog.items.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 22,
                          crossAxisSpacing: 18,
                          childAspectRatio: 0.68,
                        ),
                    itemBuilder: (context, index) {
                      return _LibraryStoryCard(
                        story: StoryCatalog.items[index],
                      );
                    },
                  ),
                ),
              ],
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: FloatingLiquidNav(selectedRoute: AppRoutes.stories),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryTitle extends StatelessWidget {
  const _LibraryTitle();

  @override
  Widget build(BuildContext context) {
    return Text(
      'Library',
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

class _LibrarySearchRow extends StatelessWidget {
  const _LibrarySearchRow();

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
                  'Search your Library',
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

class _LibraryStoryCard extends StatelessWidget {
  const _LibraryStoryCard({required this.story});

  final StoryDetail story;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        Navigator.of(
          context,
        ).pushNamed(AppRoutes.storyDetail, arguments: story);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.asset(
                story.imageAsset,
                fit: BoxFit.cover,
                alignment: story.imageAlignment,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            story.title,
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
          const SizedBox(height: 3),
          Text(
            'by ${story.author}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: const Color(0xFFB8ADAE),
              fontSize: 11,
              fontWeight: FontWeight.w400,
              height: 1.1,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 5),
          const _MiniStars(),
        ],
      ),
    );
  }
}

class _MiniStars extends StatelessWidget {
  const _MiniStars();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(5, (index) {
        return const Padding(
          padding: EdgeInsets.only(right: 2),
          child: Icon(Icons.star_rounded, color: Color(0xFFFFB642), size: 9),
        );
      }),
    );
  }
}

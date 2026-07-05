import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../../shared/widgets/floating_liquid_nav.dart';
import '../../stories/domain/story_detail.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static const _continueStories = [
    _ContinueStory(
      subtitle: '60% complete  •  4 min left',
      progress: 0.6,
      detail: StoryDetail(
        title: 'Noah Builds the Ark',
        author: 'Kingdom Kids',
        category: 'Faith',
        imageAsset: 'assets/images/noahs_ark.png',
        imageAlignment: Alignment(-0.4, 0),
        rating: '4.7',
        reviewCount: '1.8k',
        description:
            'Noah loved God and listened carefully, even when the job seemed '
            'too big. God told Noah to build an ark because a great flood was '
            'coming, and Noah obeyed one step at a time.\n\n'
            'This story helps kids see that obedience matters. Noah trusted '
            'God, cared for his family, and welcomed the animals safely into '
            'the ark.\n\n'
            'After the rain, God placed a rainbow in the sky as a promise. '
            'Kids can remember that God keeps His word and watches over every '
            'family that trusts Him.\n\n'
            'At the end, Noah and his family stepped into a fresh new world. '
            'They praised God together and began again with thankful hearts.',
      ),
    ),
    _ContinueStory(
      subtitle: '40% complete  •  5 min left',
      progress: 0.4,
      detail: StoryDetail(
        title: 'Creation Week',
        author: 'Kingdom Kids',
        category: 'Wonder',
        imageAsset: 'assets/images/creation_week.jpg',
        rating: '4.9',
        reviewCount: '2.4k',
        description:
            'In the beginning, God made the heavens and the earth. Day by day, '
            'He filled the world with light, sky, land, seas, plants, stars, '
            'animals, and people.\n\n'
            'Creation Week invites kids to slow down and notice God\'s good '
            'world with wonder, gratitude, and joy.\n\n'
            'Every flower, ocean, animal, and star points back to God\'s care. '
            'Children can learn to thank Him for the beautiful things they see '
            'each day.\n\n'
            'The story ends with rest, showing that God\'s work was good. It '
            'gives kids a gentle rhythm for wonder, work, worship, and peace.',
      ),
    ),
  ];

  static const _newStories = [
    _StoryTile(
      category: 'Courage',
      detail: StoryDetail(
        title: 'Daniel',
        author: 'Kingdom Kids',
        category: 'Courage',
        imageAsset: 'assets/images/daniel.jpeg',
        imageAlignment: Alignment(0, -0.12),
        description:
            'Daniel kept praying to God even when it became dangerous. When he '
            'was thrown into the lions\' den, God protected him through the '
            'night.\n\n'
            'This story shows kids that faith can stay strong in hard places, '
            'and that God is near when we choose what is right.\n\n'
            'Daniel did not have to be loud to be brave. His quiet trust '
            'teaches children that prayer can give courage even when everyone '
            'else is afraid.\n\n'
            'When morning came, Daniel was safe. The king saw that Daniel\'s '
            'God was powerful, faithful, and worthy of praise.',
      ),
    ),
    _StoryTile(
      category: 'Adventure',
      detail: StoryDetail(
        title: 'Moses',
        author: 'Kingdom Kids',
        category: 'Adventure',
        imageAsset: 'assets/images/moses2.jpeg',
        description:
            'Moses learned that God can use ordinary people for brave work. '
            'From the burning bush to leading God\'s people, Moses had to trust '
            'God one step at a time.\n\n'
            'Kids will follow Moses as he listens, obeys, and discovers that '
            'God gives courage for the journey.\n\n'
            'Moses did not always feel ready, but God stayed with him. This '
            'helps children see that they can ask for help and still take the '
            'next brave step.\n\n'
            'Through each challenge, Moses learned to listen for God\'s voice. '
            'His story reminds kids that leadership starts with obedience.',
      ),
    ),
    _StoryTile(
      category: 'Bravery',
      detail: StoryDetail(
        title: 'Esther',
        author: 'Kingdom Kids',
        category: 'Bravery',
        imageAsset: 'assets/images/esther.jpeg',
        description:
            'Esther became queen at a time when her people needed help. With '
            'wisdom and courage, she spoke up even though it was scary.\n\n'
            'Her story reminds kids that God can place us right where we are '
            'needed, and bravery can begin with one honest choice.\n\n'
            'Esther listened, waited, and chose the right moment to speak. '
            'Kids can learn that courage and wisdom often work together.\n\n'
            'Because Esther cared for others, her brave choice helped save '
            'many lives. Her story makes kindness feel strong.',
      ),
    ),
  ];

  static const _categories = ['All', 'Heroes', 'Jesus', 'Miracles'];

  static const _heroStories = [
    _HeroStory(
      badge: 'Bible story',
      subtitle: 'A brave story about trusting God',
      buttonLabel: 'Start Reading',
      detail: StoryDetail.fallback,
    ),
    _HeroStory(
      badge: 'Ocean story',
      subtitle: 'A second chance after a storm',
      buttonLabel: 'Read Story',
      detail: StoryDetail(
        title: 'Jonah and the Big Fish',
        author: 'Kingdom Kids',
        category: 'Mercy',
        imageAsset: 'assets/images/jonah.jpg',
        rating: '4.6',
        reviewCount: '1.5k',
        description:
            'Jonah tried to run away from what God asked him to do. A storm, '
            'a great fish, and three quiet days helped Jonah learn that God\'s '
            'mercy is bigger than fear.\n\n'
            'This story helps kids talk about second chances, listening to '
            'God, and choosing kindness even when it is hard.\n\n'
            'Jonah learned that God cares for people we may not understand. '
            'Children can see that mercy is wide, patient, and full of hope.\n\n'
            'By the end, Jonah had to learn that God\'s love reaches farther '
            'than his own plans. That lesson is still good for every heart.',
      ),
    ),
    _HeroStory(
      badge: 'Miracle story',
      subtitle: 'God makes a way forward',
      buttonLabel: 'Read Story',
      detail: StoryDetail(
        title: 'Crossing the Red Sea',
        author: 'Kingdom Kids',
        category: 'Miracle',
        imageAsset: 'assets/images/crossing_red_sea.webp',
        imageAlignment: Alignment(-0.38, 0),
        rating: '4.9',
        reviewCount: '3k',
        description:
            'The Israelites stood at the edge of the sea with danger behind '
            'them and no road ahead. God told Moses to lift his staff, and the '
            'water opened into a dry path.\n\n'
            'Kids will see that God can make a way when things feel impossible '
            'and that trusting Him can move us forward.\n\n'
            'Step by step, the people crossed safely. This story reminds kids '
            'that faith can begin with one small step on the path God opens.\n\n'
            'When they reached the other side, the people sang and celebrated. '
            'They remembered that God had rescued them with mighty love.',
      ),
    ),
  ];

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
                  padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
                  sliver: SliverList.list(
                    children: [
                      const _HomeHeader(),
                      const SizedBox(height: 8),
                      const _HeroCarousel(stories: _heroStories),
                      const SizedBox(height: 10),
                      _SectionTitle(
                        title: 'Continue reading',
                        onSeeAll: () =>
                            Navigator.of(context).pushNamed(AppRoutes.stories),
                      ),
                      const SizedBox(height: 10),
                      for (final story in _continueStories) ...[
                        _ContinueStoryRow(story: story),
                        const SizedBox(height: 14),
                      ],
                      const SizedBox(height: 4),
                      _SectionTitle(
                        title: 'New stories',
                        onSeeAll: () =>
                            Navigator.of(context).pushNamed(AppRoutes.stories),
                      ),
                      const SizedBox(height: 12),
                      const _CategoryChips(categories: _categories),
                      const SizedBox(height: 14),
                      _NewStoryShelf(stories: _newStories),
                    ],
                  ),
                ),
              ],
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: FloatingLiquidNav(selectedRoute: AppRoutes.home),
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

class _HomeHeader extends StatelessWidget {
  const _HomeHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Hello, Ethan',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontSize: 27,
                  fontWeight: FontWeight.w400,
                  height: 1.08,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Good morning',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFFB3A8A8),
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        const _KidAvatar(),
      ],
    );
  }
}

class _KidAvatar extends StatelessWidget {
  const _KidAvatar();

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(21),
      onTap: () => Navigator.of(context).pushNamed(AppRoutes.profile),
      child: Ink(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: const Color(0xFFFFE3EA),
          borderRadius: BorderRadius.circular(21),
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: ClipOval(
            child: Image.asset(
              'assets/images/profile_avatar.png',
              fit: BoxFit.cover,
              alignment: Alignment.center,
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroCarousel extends StatefulWidget {
  const _HeroCarousel({required this.stories});

  final List<_HeroStory> stories;

  @override
  State<_HeroCarousel> createState() => _HeroCarouselState();
}

class _HeroCarouselState extends State<_HeroCarousel> {
  late final PageController _pageController;
  Timer? _slideTimer;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _slideTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_pageController.hasClients || widget.stories.isEmpty) {
        return;
      }

      final nextIndex = (_currentIndex + 1) % widget.stories.length;
      _pageController.animateToPage(
        nextIndex,
        duration: const Duration(milliseconds: 420),
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
    return Column(
      children: [
        SizedBox(
          height: 190,
          child: PageView.builder(
            controller: _pageController,
            itemCount: widget.stories.length,
            onPageChanged: (index) {
              setState(() => _currentIndex = index);
            },
            itemBuilder: (context, index) {
              return _HeroStoryCard(story: widget.stories[index]);
            },
          ),
        ),
        const SizedBox(height: 8),
        _HeroDots(count: widget.stories.length, currentIndex: _currentIndex),
      ],
    );
  }
}

class _HeroStoryCard extends StatelessWidget {
  const _HeroStoryCard({required this.story});

  final _HeroStory story;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(15),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openStoryDetail(context, story.detail),
          child: SizedBox(
            height: 190,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.asset(
                  story.detail.imageAsset,
                  fit: BoxFit.cover,
                  alignment: story.detail.imageAlignment,
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Color(0xC9000000),
                        Color(0x78000000),
                        Color(0x00000000),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _StoryBadge(label: story.badge),
                      const Spacer(),
                      Text(
                        story.detail.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontSize: 21,
                          fontWeight: FontWeight.w500,
                          height: 1.02,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        story.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.86),
                          fontSize: 10,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 6),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFFF7043),
                          foregroundColor: Colors.white,
                          minimumSize: const Size(100, 32),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          textStyle: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        onPressed: () =>
                            _openStoryDetail(context, story.detail),
                        child: Text(story.buttonLabel),
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

class _StoryBadge extends StatelessWidget {
  const _StoryBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: const Color(0xFFFF7043),
            fontSize: 9,
            fontWeight: FontWeight.w500,
          ),
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
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (index) {
        final selected = index == currentIndex;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: selected ? 16 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFFF7043) : const Color(0xFFE9DCDC),
            borderRadius: BorderRadius.circular(999),
          ),
        );
      }),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.onSeeAll});

  final String title;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontSize: 17,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        TextButton(onPressed: onSeeAll, child: const Text('See all')),
      ],
    );
  }
}

class _ContinueStoryRow extends StatelessWidget {
  const _ContinueStoryRow({required this.story});

  final _ContinueStory story;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _StoryImageThumb(
          imageAsset: story.detail.imageAsset,
          alignment: story.detail.imageAlignment,
          size: 62,
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                story.detail.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: story.progress,
                  minHeight: 5,
                  backgroundColor: const Color(0xFFF1E7E5),
                  valueColor: const AlwaysStoppedAnimation(Color(0xFFFF7043)),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                story.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFFB3A8A8),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFFF7043),
            foregroundColor: Colors.white,
            minimumSize: const Size(68, 38),
            padding: const EdgeInsets.symmetric(horizontal: 14),
          ),
          onPressed: () => _openStoryDetail(context, story.detail),
          child: const Text('Read'),
        ),
      ],
    );
  }
}

class _CategoryChips extends StatelessWidget {
  const _CategoryChips({required this.categories});

  final List<String> categories;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
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
            selectedColor: const Color(0xFFFFD26A),
            backgroundColor: Colors.transparent,
            side: BorderSide.none,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
            ),
            labelStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: selected ? Colors.white : const Color(0xFF6B5F5F),
              fontWeight: FontWeight.w600,
            ),
            onSelected: (_) {},
          );
        },
      ),
    );
  }
}

class _NewStoryShelf extends StatelessWidget {
  const _NewStoryShelf({required this.stories});

  final List<_StoryTile> stories;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 188,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: stories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (context, index) {
          return _NewStoryCard(story: stories[index]);
        },
      ),
    );
  }
}

class _NewStoryCard extends StatelessWidget {
  const _NewStoryCard({required this.story});

  final _StoryTile story;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 132,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _openStoryDetail(context, story.detail),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StoryImageThumb(
                imageAsset: story.detail.imageAsset,
                alignment: story.detail.imageAlignment,
                size: 132,
              ),
              const SizedBox(height: 8),
              Text(
                story.detail.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                story.category,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFFB3A8A8),
                  fontSize: 12,
                  height: 1.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StoryImageThumb extends StatelessWidget {
  const _StoryImageThumb({
    required this.imageAsset,
    required this.alignment,
    required this.size,
  });

  final String imageAsset;
  final Alignment alignment;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFFF4ECE9),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Image.asset(imageAsset, fit: BoxFit.cover, alignment: alignment),
    );
  }
}

class _ContinueStory {
  const _ContinueStory({
    required this.subtitle,
    required this.progress,
    required this.detail,
  });

  final String subtitle;
  final double progress;
  final StoryDetail detail;
}

class _StoryTile {
  const _StoryTile({required this.category, required this.detail});

  final String category;
  final StoryDetail detail;
}

class _HeroStory {
  const _HeroStory({
    required this.badge,
    required this.subtitle,
    required this.buttonLabel,
    required this.detail,
  });

  final String badge;
  final String subtitle;
  final String buttonLabel;
  final StoryDetail detail;
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../../stories/domain/story_detail.dart';
import 'home_story_card.dart';

/// Keeps unfinished adventures in one small space instead of stacking cards.
class ContinueReadingCarousel extends StatefulWidget {
  const ContinueReadingCarousel({
    required this.stories,
    required this.onContinue,
    required this.isActive,
    this.openingStoryId,
    super.key,
  });

  final List<StoryDetail> stories;
  final ValueChanged<StoryDetail> onContinue;
  final bool isActive;
  final String? openingStoryId;

  @override
  State<ContinueReadingCarousel> createState() =>
      _ContinueReadingCarouselState();
}

class _ContinueReadingCarouselState extends State<ContinueReadingCarousel>
    with WidgetsBindingObserver {
  final PageController _pages = PageController();
  Timer? _slideTimer;
  int _currentPage = 0;
  bool _motionEnabled = false;
  bool _pointerDown = false;
  bool _scrolling = false;
  bool _appForeground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appForeground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Backgrounded apps can defer rebuilds. Cancel here without waiting for
    // Home to pass the updated visibility flag through the widget tree.
    _appForeground = state == AppLifecycleState.resumed;
    _scheduleSlide();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    _motionEnabled = !media.disableAnimations && !media.accessibleNavigation;
    _scheduleSlide();
  }

  @override
  void didUpdateWidget(covariant ContinueReadingCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousIds = oldWidget.stories.map((story) => story.id).join('|');
    final nextIds = widget.stories.map((story) => story.id).join('|');
    if (previousIds != nextIds) {
      _currentPage = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pages.hasClients) _pages.jumpToPage(0);
      });
    }
    _scheduleSlide();
  }

  void _scheduleSlide() {
    _slideTimer?.cancel();
    _slideTimer = null;
    if (!widget.isActive ||
        !_appForeground ||
        !_motionEnabled ||
        _pointerDown ||
        _scrolling ||
        widget.openingStoryId != null ||
        widget.stories.length < 2) {
      return;
    }
    _slideTimer = Timer(const Duration(seconds: 6), () async {
      if (!mounted ||
          !_pages.hasClients ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      await _pages.animateToPage(
        (_currentPage + 1) % widget.stories.length,
        duration: const Duration(milliseconds: 550),
        curve: Curves.easeInOutCubic,
      );
      if (mounted) _scheduleSlide();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _slideTimer?.cancel();
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.stories.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardHeight = widget.stories.fold<double>(0, (height, story) {
          final measured = HomeStoryCard.heightFor(
            context: context,
            width: constraints.maxWidth,
            story: story,
            metadata: '',
          );
          return measured > height ? measured : height;
        });
        return Column(
          key: const Key('home-continue-reading'),
          children: [
            Listener(
              onPointerDown: (_) {
                _pointerDown = true;
                _scheduleSlide();
              },
              onPointerUp: (_) {
                _pointerDown = false;
                _scheduleSlide();
              },
              onPointerCancel: (_) {
                _pointerDown = false;
                _scheduleSlide();
              },
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification.depth != 0) return false;
                  if (notification is ScrollStartNotification) {
                    _scrolling = true;
                    _scheduleSlide();
                  } else if (notification is ScrollEndNotification) {
                    _scrolling = false;
                    _scheduleSlide();
                  }
                  return false;
                },
                child: SizedBox(
                  height: cardHeight,
                  child: PageView.builder(
                    key: const Key('home-continue-pages'),
                    controller: _pages,
                    itemCount: widget.stories.length,
                    onPageChanged: (value) {
                      setState(() => _currentPage = value);
                    },
                    itemBuilder: (context, index) {
                      final story = widget.stories[index];
                      return HomeStoryCard(
                        story: story,
                        paletteIndex: index,
                        metadata: '',
                        semanticActionLabel: 'Continue',
                        tapKey: Key('continue-story-${story.id}'),
                        isOpening: widget.openingStoryId == story.id,
                        onTap: widget.openingStoryId == null
                            ? () => widget.onContinue(story)
                            : null,
                      );
                    },
                  ),
                ),
              ),
            ),
            if (widget.stories.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 9),
                child: Semantics(
                  label:
                      'Story ${_currentPage + 1} of ${widget.stories.length}',
                  child: ExcludeSemantics(
                    child: widget.stories.length > 5
                        ? Text(
                            '${_currentPage + 1} / ${widget.stories.length}',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: const Color(0xFF171421),
                                  fontWeight: FontWeight.w700,
                                ),
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: List.generate(
                              widget.stories.length,
                              (index) => Container(
                                width: index == _currentPage ? 18 : 6,
                                height: 6,
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: index == _currentPage
                                      ? const Color(0xFF171421)
                                      : const Color(
                                          0xFF171421,
                                        ).withValues(alpha: .25),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

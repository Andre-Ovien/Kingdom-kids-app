import 'dart:async';
import 'package:flutter/material.dart';

class HomeAdventureCarousel extends StatefulWidget {
  const HomeAdventureCarousel({
    required this.isActive,
    required this.onRead,
    required this.onPlay,
    super.key,
  });
  final bool isActive;
  final VoidCallback onRead;
  final VoidCallback onPlay;
  @override
  State<HomeAdventureCarousel> createState() => _HomeAdventureCarouselState();
}

class _HomeAdventureCarouselState extends State<HomeAdventureCarousel>
    with WidgetsBindingObserver {
  final _pages = PageController();
  Timer? _timer;
  int _page = 0;
  bool _foreground = true,
      _motion = false,
      _touching = false,
      _scrolling = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    _motion = !media.disableAnimations && !media.accessibleNavigation;
    _schedule();
  }

  @override
  void didUpdateWidget(HomeAdventureCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (!widget.isActive ||
        !_foreground ||
        !_motion ||
        _touching ||
        _scrolling) {
      return;
    }
    _timer = Timer(const Duration(seconds: 6), () async {
      if (!mounted ||
          !_pages.hasClients ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      await _pages.animateToPage(
        (_page + 1) % 2,
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeInOutCubic,
      );
      if (mounted) _schedule();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return Column(
      key: const Key('home-adventure-carousel'),
      children: [
        Listener(
          onPointerDown: (_) {
            _touching = true;
            _schedule();
          },
          onPointerUp: (_) {
            _touching = false;
            _schedule();
          },
          onPointerCancel: (_) {
            _touching = false;
            _schedule();
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.depth != 0) return false;
              if (notification is ScrollStartNotification) _scrolling = true;
              if (notification is ScrollEndNotification) _scrolling = false;
              _schedule();
              return false;
            },
            child: SizedBox(
              height: 245 + ((scale - 1).clamp(0, 1) * 200),
              child: PageView(
                key: const Key('home-adventure-pages'),
                controller: _pages,
                onPageChanged: (page) => setState(() => _page = page),
                children: [
                  _AdventureCard(
                    actionKey: const Key('home-adventure-read'),
                    label: 'Read',
                    title: 'Read a little\nwonder.',
                    subtitle: 'Big stories for curious hearts.',
                    color: const Color(0xFF6B8DFA),
                    artPath: 'assets/images/home/read-premium-v1.png',
                    pageNumber: 1,
                    icon: Icons.auto_stories_rounded,
                    onTap: widget.onRead,
                  ),
                  _AdventureCard(
                    actionKey: const Key('home-adventure-play'),
                    label: 'Play',
                    title: 'Let’s play\nand discover.',
                    subtitle: 'Little games. Joyful learning.',
                    color: const Color(0xFFCD95EA),
                    artPath: 'assets/images/home/play-premium-v1.png',
                    pageNumber: 2,
                    icon: Icons.extension_rounded,
                    onTap: widget.onPlay,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AdventureCard extends StatelessWidget {
  const _AdventureCard({
    required this.actionKey,
    required this.label,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.artPath,
    required this.pageNumber,
    required this.icon,
    required this.onTap,
  });
  final Key actionKey;
  final String label, title, subtitle, artPath;
  final Color color;
  final int pageNumber;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF161528);
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 19;
    return Semantics(
      button: true,
      label: label == 'Read' ? 'READ adventures' : 'PLAY adventures',
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: color,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(46),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: actionKey,
          onTap: onTap,
          customBorder: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(46),
          ),
          child: Stack(
            children: [
              Positioned(
                right: 0,
                bottom: -3,
                width: 164,
                height: 155,
                child: Opacity(
                  opacity: largeText ? 0.24 : 1,
                  child: Image.asset(
                    artPath,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                    cacheWidth: 540,
                    excludeFromSemantics: true,
                    errorBuilder: (_, _, _) => Icon(
                      icon,
                      size: 112,
                      color: ink.withValues(alpha: 0.25),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 32,
                            height: 32,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(icon, size: 17, color: ink),
                          ),
                          const SizedBox(width: 9),
                          Text(
                            label.toUpperCase(),
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  fontSize: 11,
                                  letterSpacing: 1,
                                  fontWeight: FontWeight.w800,
                                  color: ink,
                                ),
                          ),
                          const Spacer(),
                          Container(
                            width: 34,
                            height: 34,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: ink.withValues(alpha: 0.30),
                                width: 1.5,
                              ),
                            ),
                            child: Text(
                              '$pageNumber/2',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: ink,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 10,
                                  ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      FractionallySizedBox(
                        widthFactor: largeText ? 1 : 0.77,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          title,
                          maxLines: 2,
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                fontSize: 28,
                                height: 1.02,
                                letterSpacing: -0.9,
                                fontWeight: FontWeight.w800,
                                color: ink,
                              ),
                        ),
                      ),
                      const SizedBox(height: 7),
                      FractionallySizedBox(
                        widthFactor: largeText ? 1 : 0.70,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          subtitle,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                fontSize: 12,
                                height: 1.25,
                                color: ink,
                              ),
                        ),
                      ),
                      const Spacer(),
                      Container(
                        constraints: const BoxConstraints(
                          minWidth: 112,
                          minHeight: 42,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: ink,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              label,
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(
                                    fontSize: 13,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                            const SizedBox(width: 12),
                            const Icon(
                              Icons.arrow_forward_rounded,
                              size: 17,
                              color: Colors.white,
                            ),
                          ],
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

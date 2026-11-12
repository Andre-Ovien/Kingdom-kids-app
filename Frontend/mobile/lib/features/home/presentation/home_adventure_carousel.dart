import 'dart:async';
import 'package:flutter/material.dart';

import '../../../app/app_route_observer.dart';

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
    with SingleTickerProviderStateMixin, WidgetsBindingObserver, RouteAware {
  final _pages = PageController();
  late final AnimationController _countdown;
  ModalRoute<dynamic>? _route;
  final Set<int> _pointers = {};
  int _page = 0;
  bool _foreground = true;
  bool _motion = false;
  bool _visible = true;
  bool _scrolling = false;
  bool _advancing = false;

  @override
  void initState() {
    super.initState();
    _countdown =
        AnimationController(vsync: this, duration: const Duration(seconds: 6))
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) unawaited(_advance());
          });
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_route != route) {
      appRouteObserver.unsubscribe(this);
      _route = route;
      if (route != null) appRouteObserver.subscribe(this, route);
    }
    _visible = route?.isCurrent ?? true;
    final media = MediaQuery.of(context);
    _motion = !media.disableAnimations && !media.accessibleNavigation;
    _syncClock();
  }

  @override
  void didUpdateWidget(HomeAdventureCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncClock();
  }

  @override
  void didPushNext() {
    _visible = false;
    _syncClock();
  }

  @override
  void didPopNext() {
    _visible = true;
    _syncClock();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncClock();
  }

  bool get _canRun =>
      mounted &&
      widget.isActive &&
      _foreground &&
      _visible &&
      _motion &&
      _pointers.isEmpty &&
      !_scrolling &&
      !_advancing;

  void _syncClock() {
    if (!_canRun) {
      _countdown.stop();
    } else if (_countdown.isCompleted) {
      // A pointer/lifecycle change may coincide with the final clock tick.
      // Resume that completed dwell once, without starting a second timer.
      scheduleMicrotask(() {
        if (mounted) unawaited(_advance());
      });
    } else if (!_countdown.isAnimating) {
      _countdown.forward();
    }
  }

  Future<void> _advance() async {
    if (!_canRun || !_pages.hasClients || _route?.isCurrent == false) return;
    _advancing = true;
    _countdown.stop();
    await _pages.animateToPage(
      (_page + 1) % 2,
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeInOutCubic,
    );
    if (!mounted) return;
    _advancing = false;
    _countdown.value = 0;
    _syncClock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appRouteObserver.unsubscribe(this);
    _countdown.dispose();
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
          onPointerDown: (event) {
            _pointers.add(event.pointer);
            _syncClock();
          },
          onPointerUp: (event) {
            _pointers.remove(event.pointer);
            _syncClock();
          },
          onPointerCancel: (event) {
            _pointers.remove(event.pointer);
            _syncClock();
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.depth != 0) return false;
              if (notification is ScrollStartNotification) _scrolling = true;
              if (notification is ScrollEndNotification) _scrolling = false;
              _syncClock();
              return false;
            },
            child: SizedBox(
              height: 245 + ((scale - 1).clamp(0, 1) * 200),
              child: PageView(
                key: const Key('home-adventure-pages'),
                controller: _pages,
                onPageChanged: (page) {
                  setState(() => _page = page);
                  _countdown.value = 0;
                  _syncClock();
                },
                children: [
                  _AdventureCard(
                    actionKey: const Key('home-adventure-read'),
                    label: 'Read',
                    title: 'Read a little\nwonder.',
                    subtitle: 'Big stories for curious hearts.',
                    color: const Color(0xFF6B8DFA),
                    artPath: 'assets/images/home/read-premium-v1.png',
                    pageNumber: 1,
                    countdown: _countdown,
                    isCurrent: _page == 0,
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
                    countdown: _countdown,
                    isCurrent: _page == 1,
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
    required this.countdown,
    required this.isCurrent,
    required this.icon,
    required this.onTap,
  });
  final Key actionKey;
  final String label, title, subtitle, artPath;
  final Color color;
  final int pageNumber;
  final Animation<double> countdown;
  final bool isCurrent;
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
                          SizedBox(
                            width: 34,
                            height: 34,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Positioned.fill(
                                  child: AnimatedBuilder(
                                    animation: countdown,
                                    builder: (context, _) =>
                                        CircularProgressIndicator(
                                          key: ValueKey(
                                            'home-adventure-countdown-$pageNumber',
                                          ),
                                          value: isCurrent
                                              ? countdown.value
                                              : 0,
                                          strokeWidth: 2.5,
                                          strokeCap: StrokeCap.round,
                                          color: ink,
                                          backgroundColor: ink.withValues(
                                            alpha: 0.18,
                                          ),
                                        ),
                                  ),
                                ),
                                Text(
                                  '$pageNumber/2',
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: ink,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 10,
                                      ),
                                ),
                              ],
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
                        child: Text(
                          label,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                fontSize: 13,
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                              ),
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

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_route_observer.dart';
import '../domain/mini_game.dart';
import 'game_cover_image.dart';
import 'games_course_widgets.dart';

/// The caller supplies the already published, availability-filtered catalogue.
List<MiniGame> buildGamesWeekPool(List<MiniGame> games) {
  final ids = <String>{};
  final slugs = <String>{};
  final pool = <MiniGame>[];
  for (final game in [
    ...games.where((game) => game.isFeatured),
    ...games.where((game) => !game.isFeatured),
  ]) {
    final slug = game.slug.trim();
    final id = game.id.trim();
    if (slug.isEmpty ||
        slugs.contains(slug) ||
        (id.isNotEmpty && ids.contains(id))) {
      continue;
    }
    slugs.add(slug);
    if (id.isNotEmpty) ids.add(id);
    pool.add(game);
    if (pool.length == 5) break;
  }
  return List.unmodifiable(pool);
}

class GamesWeekCarousel extends StatefulWidget {
  const GamesWeekCarousel({
    super.key,
    required this.games,
    required this.scopeId,
    required this.scrollController,
    required this.onOpen,
    this.loading = false,
    this.isActive = true,
  });
  final List<MiniGame> games;
  final String scopeId;
  final ScrollController scrollController;
  final ValueChanged<MiniGame> onOpen;
  final bool loading;
  final bool isActive;
  static const dwellDuration = Duration(seconds: 7);
  static const transitionDuration = Duration(milliseconds: 350);

  @override
  State<GamesWeekCarousel> createState() => _GamesWeekCarouselState();
}

class _GamesWeekCarouselState extends State<GamesWeekCarousel>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver, RouteAware {
  late final AnimationController _clock;
  late List<MiniGame> _pool;
  MiniGame? _previous;
  ModalRoute<dynamic>? _route;
  ScrollPosition? _position;
  final _pointers = <int>{};
  int _index = 0;
  int _warmGeneration = 0;
  bool _foreground = true;
  bool _routeActive = true;
  bool _motionAllowed = false;
  bool _positionCheckScheduled = false;

  MiniGame? get _current => _pool.isEmpty ? null : _pool[_index];
  String _announcement(int index) {
    final slot = index % _pool.length;
    return '${slot + 1} of ${_pool.length}. ${_pool[slot].title}';
  }

  bool get _transitioning => _previous != null;
  bool get _inView {
    if (!widget.scrollController.hasClients) return true;
    final box = context.findRenderObject();
    final height = box is RenderBox && box.hasSize
        ? box.size.height
        : double.infinity;
    return widget.scrollController.offset < height &&
        widget.scrollController.offset + MediaQuery.sizeOf(context).height > 0;
  }

  bool get _canRun =>
      mounted &&
      _pool.length > 1 &&
      !widget.loading &&
      widget.isActive &&
      _foreground &&
      _routeActive &&
      (_route?.isCurrent ?? true) &&
      _motionAllowed &&
      _pointers.isEmpty &&
      _inView &&
      !(_position?.isScrollingNotifier.value ?? false);

  @override
  void initState() {
    super.initState();
    _pool = buildGamesWeekPool(widget.games);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _clock =
        AnimationController(
            vsync: this,
            duration: GamesWeekCarousel.dwellDuration,
          )
          ..addListener(_tick)
          ..addStatusListener(_status);
    WidgetsBinding.instance.addObserver(this);
    widget.scrollController.addListener(_syncClock);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _route)) {
      if (_route != null) appRouteObserver.unsubscribe(this);
      _route = route;
      if (route != null) appRouteObserver.subscribe(this, route);
    }
    _routeActive = route?.isCurrent ?? true;
    final media = MediaQuery.of(context);
    _motionAllowed = !media.disableAnimations && !media.accessibleNavigation;
    if (!_motionAllowed) _previous = null;
    _schedulePositionCheck();
    _warmCovers();
    _syncClock();
  }

  @override
  void didUpdateWidget(covariant GamesWeekCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldSlug = _current?.slug;
    final next = buildGamesWeekPool(widget.games);
    final ownerChanged = oldWidget.scopeId != widget.scopeId;
    final changed =
        _pool.map((game) => game.slug).join('|') !=
        next.map((game) => game.slug).join('|');
    _pool = next;
    if (ownerChanged ||
        (oldSlug != null && !next.any((game) => game.slug == oldSlug))) {
      _clock.stop();
      _clock.value = 0;
      _index = 0;
      _previous = null;
    } else {
      final retained = next.indexWhere((game) => game.slug == oldSlug);
      _index = retained < 0 ? 0 : retained;
      if (changed) _previous = null;
    }
    if (_pool.length < 2) {
      _clock.stop();
      _clock.value = 0;
      _previous = null;
    }
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_syncClock);
      widget.scrollController.addListener(_syncClock);
      _position?.isScrollingNotifier.removeListener(_syncClock);
      _position = null;
    }
    if (changed || ownerChanged) _warmCovers();
    _schedulePositionCheck();
    _syncClock();
  }

  void _schedulePositionCheck() {
    if (_positionCheckScheduled) return;
    _positionCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _positionCheckScheduled = false;
      if (!mounted) return;
      final next = widget.scrollController.hasClients
          ? widget.scrollController.position
          : null;
      if (!identical(next, _position)) {
        _position?.isScrollingNotifier.removeListener(_syncClock);
        _position = next;
        _position?.isScrollingNotifier.addListener(_syncClock);
      }
      _syncClock();
    });
  }

  void _warmCovers() {
    final generation = ++_warmGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _warmGeneration) return;
      final width =
          ((MediaQuery.sizeOf(context).width *
                          MediaQuery.devicePixelRatioOf(context) /
                          64)
                      .ceil() *
                  64)
              .clamp(64, 2048);
      for (final game in _pool) {
        final asset = game.coverAssetKey.trim().isNotEmpty
            ? game.coverAssetKey
            : game.imageAsset;
        if (asset.isEmpty) continue;
        unawaited(
          precacheImage(
            ResizeImage.resizeIfNeeded(width, null, AssetImage(asset)),
            context,
            onError: (_, _) {},
          ).catchError((Object _) {}),
        );
      }
    });
  }

  void _tick() {
    if (!_canRun && _clock.isAnimating) _clock.stop();
    if (_previous != null && _clock.value >= 0.05) {
      setState(() => _previous = null);
    }
  }

  void _status(AnimationStatus status) {
    if (status == AnimationStatus.completed && _canRun) _move(1);
  }

  void _syncClock() {
    if (!_canRun) {
      _clock.stop();
    } else if (!_clock.isAnimating) {
      if (_clock.value >= 1) {
        _move(1);
      } else {
        _clock.forward();
      }
    }
  }

  void _move(int delta) {
    if (_pool.length < 2 || widget.loading) return;
    final old = _current;
    _clock.stop();
    setState(() {
      _index = (_index + delta) % _pool.length;
      _previous = _motionAllowed ? old : null;
    });
    _clock.value = 0;
    _syncClock();
  }

  void _play(MiniGame expected) {
    if (widget.loading ||
        _transitioning ||
        !_foreground ||
        !_routeActive ||
        !widget.isActive ||
        !(_route?.isCurrent ?? true) ||
        !_inView ||
        _current?.slug != expected.slug) {
      return;
    }
    widget.onOpen(_current!);
  }

  @override
  void didPushNext() {
    _routeActive = false;
    _syncClock();
  }

  @override
  void didPopNext() {
    _routeActive = true;
    _syncClock();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _pointers.clear();
    _syncClock();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Semantics(
      key: const Key('games-week-carousel'),
      container: true,
      label: 'Games of the Week',
      value: _current == null
          ? 'No game available'
          : '${_index + 1} of ${_pool.length}. ${_current!.title}',
      increasedValue: _pool.length > 1 && !widget.loading
          ? _announcement(_index + 1)
          : null,
      decreasedValue: _pool.length > 1 && !widget.loading
          ? _announcement(_index - 1)
          : null,
      onIncrease: _pool.length > 1 && !widget.loading ? () => _move(1) : null,
      onDecrease: _pool.length > 1 && !widget.loading ? () => _move(-1) : null,
      child: Listener(
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
        child: GestureDetector(
          onHorizontalDragEnd: (details) {
            if (details.primaryVelocity == null ||
                details.primaryVelocity!.abs() < 100) {
              return;
            }
            _move(details.primaryVelocity! < 0 ? 1 : -1);
          },
          child: Stack(
            children: [
              AnimatedBuilder(
                animation: _clock,
                builder: (context, _) {
                  final current = _current;
                  final transition = _previous == null
                      ? 1.0
                      : Curves.easeOutCubic.transform(
                          (_clock.value / 0.05).clamp(0.0, 1.0),
                        );
                  return GamesCourseHeader(
                    featured: current,
                    previous: _previous,
                    transitionProgress: transition,
                    countdownProgress: _clock.value,
                    showCountdown: _pool.length > 1 && _motionAllowed,
                    loading: widget.loading,
                    onTap: current == null || _transitioning || widget.loading
                        ? null
                        : () => _play(current),
                  );
                },
              ),
              Offstage(
                offstage: true,
                child: TickerMode(
                  enabled: false,
                  child: SizedBox(
                    width: width,
                    height: 340,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        for (final game in _pool)
                          if (game.slug != _current?.slug &&
                              game.slug != _previous?.slug)
                            KeyedSubtree(
                              key: ValueKey(
                                'games-week-preload-${widget.scopeId}-${game.slug}',
                              ),
                              child: GameCoverImage(game: game),
                            ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _warmGeneration++;
    widget.scrollController.removeListener(_syncClock);
    _position?.isScrollingNotifier.removeListener(_syncClock);
    if (_route != null) appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _clock.dispose();
    super.dispose();
  }
}

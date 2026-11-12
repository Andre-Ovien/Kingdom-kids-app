import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_route_observer.dart';
import '../domain/progress_summary.dart';

/// One compact window onto the selected child's six real progress totals.
class ProfileProgressCarousel extends StatefulWidget {
  const ProfileProgressCarousel({
    super.key,
    required this.stats,
    required this.badgeCount,
  });

  final ProfileStats stats;
  final int badgeCount;

  @override
  State<ProfileProgressCarousel> createState() =>
      _ProfileProgressCarouselState();
}

class _ProfileProgressCarouselState extends State<ProfileProgressCarousel>
    with WidgetsBindingObserver, RouteAware {
  // Six divides the starting index. Every automatic advance moves forward,
  // including the sixth-to-first metric, without animating backwards.
  static const _initialPage = 6000;
  final _pages = PageController(initialPage: _initialPage);
  Timer? _timer;
  ModalRoute<dynamic>? _route;
  int _page = _initialPage;
  bool _foreground = true;
  bool _visible = true;
  bool _motionAllowed = false;
  bool _scrolling = false;
  final Set<int> _pointers = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
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
    _motionAllowed = !media.disableAnimations && !media.accessibleNavigation;
    _schedule();
  }

  @override
  void didPushNext() {
    _visible = false;
    _schedule();
  }

  @override
  void didPopNext() {
    _visible = true;
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _schedule();
  }

  bool get _canAdvance =>
      mounted &&
      _foreground &&
      _visible &&
      _motionAllowed &&
      !_scrolling &&
      _pointers.isEmpty;

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (!_canAdvance) return;
    _timer = Timer(const Duration(seconds: 7), () {
      if (!_canAdvance || !_pages.hasClients || _route?.isCurrent == false) {
        return;
      }
      _moveTo(_page + 1);
    });
  }

  Future<void> _moveTo(int page) async {
    _timer?.cancel();
    if (!_pages.hasClients || _scrolling || page < 0) return;
    if (_motionAllowed) {
      await _pages.animateToPage(
        page,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOutCubic,
      );
    } else {
      _pages.jumpToPage(page);
    }
    if (mounted) _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = _progressMetrics(widget.stats, widget.badgeCount);
    final index = _page % items.length;
    final current = items[index];
    return Semantics(
      container: true,
      label: 'Progress overview',
      value:
          '${index + 1} of ${items.length}. ${current.label}, ${current.value}',
      increasedValue: _metricAnnouncement(items, _page + 1),
      decreasedValue: _metricAnnouncement(items, _page - 1),
      onIncrease: () => _moveTo(_page + 1),
      onDecrease: () => _moveTo(_page - 1),
      child: ExcludeSemantics(
        child: Column(
          key: const Key('profile-progress-carousel'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Listener(
              onPointerDown: (event) {
                _pointers.add(event.pointer);
                _schedule();
              },
              onPointerUp: (event) {
                _pointers.remove(event.pointer);
                _schedule();
              },
              onPointerCancel: (event) {
                _pointers.remove(event.pointer);
                _schedule();
              },
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification.depth != 0) return false;
                  if (notification is ScrollStartNotification) {
                    _scrolling = true;
                  } else if (notification is ScrollEndNotification) {
                    _scrolling = false;
                  }
                  _schedule();
                  return false;
                },
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final height = _cardHeight(context, constraints, items);
                    return SizedBox(
                      height: height,
                      child: PageView.builder(
                        key: const Key('profile-progress-pages'),
                        controller: _pages,
                        onPageChanged: (page) => setState(() => _page = page),
                        itemBuilder: (context, page) =>
                            _ProgressCard(metric: items[page % items.length]),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var item = 0; item < items.length; item++)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: item == index ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: item == index
                          ? const Color(0xFF695BC4)
                          : const Color(0xFFD9D5EC),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _metricAnnouncement(List<_ProgressMetric> items, int page) {
  final index = page % items.length;
  final item = items[index];
  return '${index + 1} of ${items.length}. ${item.label}, ${item.value}';
}

List<_ProgressMetric> _progressMetrics(ProfileStats stats, int badgeCount) => [
  _ProgressMetric(
    '${stats.completedGameLevels}/${stats.totalGameLevels}',
    'Levels won',
    Icons.flag_rounded,
    const Color(0xFF9B92F6),
  ),
  _ProgressMetric(
    '${stats.gameStars}/${stats.maxGameStars}',
    'Stars',
    Icons.star_rounded,
    const Color(0xFFE5A0F2),
  ),
  _ProgressMetric(
    '${stats.gamesStarted}',
    'Games tried',
    Icons.extension_rounded,
    const Color(0xFFFFC45B),
  ),
  _ProgressMetric(
    '${stats.earnedBadges}/$badgeCount',
    'Badges',
    Icons.workspace_premium_rounded,
    const Color(0xFF63D276),
  ),
  _ProgressMetric(
    '${stats.storiesStarted}/${stats.totalStories}',
    'Stories explored',
    Icons.auto_stories_rounded,
    const Color(0xFF66C9E8),
  ),
  _ProgressMetric(
    '${stats.storiesCompleted}/${stats.totalStories}',
    'Stories completed',
    Icons.menu_book_rounded,
    const Color(0xFFFF9078),
  ),
];

TextStyle _valueStyle(BuildContext context) =>
    Theme.of(context).textTheme.headlineSmall?.copyWith(
      fontSize: 30,
      fontWeight: FontWeight.w900,
      height: 1.1,
      letterSpacing: -0.8,
    ) ??
    const TextStyle(fontSize: 30, height: 1.1);

TextStyle _labelStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w800,
      height: 1.3,
    ) ??
    const TextStyle(fontSize: 14, height: 1.3);

double _cardHeight(
  BuildContext context,
  BoxConstraints constraints,
  List<_ProgressMetric> items,
) {
  final textWidth = (constraints.maxWidth - 112).clamp(40.0, double.infinity);
  var tallest = 0.0;
  for (final item in items) {
    double measure(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: textWidth);
      final height = painter.height;
      painter.dispose();
      return height;
    }

    final height =
        measure(item.value, _valueStyle(context)) +
        6 +
        measure(item.label, _labelStyle(context));
    if (height > tallest) tallest = height;
  }
  return (tallest + 36).clamp(116.0, double.infinity);
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.metric});
  final _ProgressMetric metric;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? Colors.white : const Color(0xFF171421);
    return Container(
      key: ValueKey('profile-progress-card-${metric.label}'),
      clipBehavior: Clip.antiAlias,
      decoration: ShapeDecoration(
        color: dark
            ? Color.alphaBlend(
                Colors.black.withValues(alpha: 0.28),
                metric.color,
              )
            : metric.color,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(28),
        ),
      ),
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(metric.icon, color: ink, size: 30),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  metric.value,
                  style: _valueStyle(context).copyWith(color: ink),
                ),
                const SizedBox(height: 6),
                Text(
                  metric.label,
                  style: _labelStyle(
                    context,
                  ).copyWith(color: ink.withValues(alpha: 0.8)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressMetric {
  const _ProgressMetric(this.value, this.label, this.icon, this.color);
  final String value;
  final String label;
  final IconData icon;
  final Color color;
}

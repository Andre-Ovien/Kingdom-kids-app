import 'package:flutter/material.dart';

import '../domain/mini_game.dart';
import 'game_cover_image.dart';

const _ink = Color(0xFF25262A);
const _viewportFraction = 1 / 3;
const _coverGap = 18.0;
const _sideWidthScale = 0.82;

/// A manual, front-facing cover selector. There is deliberately no dwell clock.
class GamesCategoryCoverflow extends StatefulWidget {
  const GamesCategoryCoverflow({
    super.key,
    required this.category,
    required this.games,
    required this.onOpen,
    required this.scopeId,
    this.enabled = true,
  });

  final GameCategory category;
  final List<MiniGame> games;
  final ValueChanged<MiniGame> onOpen;
  final String scopeId;
  final bool enabled;

  @override
  State<GamesCategoryCoverflow> createState() => _GamesCategoryCoverflowState();
}

class _GamesCategoryCoverflowState extends State<GamesCategoryCoverflow>
    with AutomaticKeepAliveClientMixin {
  late final PageController _controller;
  late int _selected;
  bool _moving = false;
  bool _recentering = false;
  int _revision = 0;

  bool get _loops => widget.games.length >= 3;
  int get _basePage => _loops ? widget.games.length * 1000 : 0;

  @override
  bool get wantKeepAlive => true;

  static String _identity(MiniGame game) =>
      game.slug.isEmpty ? game.id : game.slug;

  @override
  void initState() {
    super.initState();
    _selected = widget.games.length ~/ 2;
    _controller = PageController(
      initialPage: _basePage + _selected,
      viewportFraction: _viewportFraction,
      keepPage: false,
    );
  }

  @override
  void didUpdateWidget(covariant GamesCategoryCoverflow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.games.isEmpty
        ? null
        : _identity(
            oldWidget.games[_selected.clamp(0, oldWidget.games.length - 1)],
          );
    var next = widget.games.indexWhere((game) => _identity(game) == previous);
    if (widget.scopeId != oldWidget.scopeId || next < 0) {
      next = widget.games.length ~/ 2;
    }
    final revision = ++_revision;
    if (next != _selected ||
        widget.games.length != oldWidget.games.length ||
        widget.scopeId != oldWidget.scopeId) {
      _selected = next;
      _moving = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || revision != _revision || !_controller.hasClients) {
          return;
        }
        _controller.jumpToPage(_basePage + _selected);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _select(int index) {
    if (!_controller.hasClients || index < 0 || index >= widget.games.length) {
      return;
    }
    var target = index;
    if (_loops) {
      final current = (_controller.page ?? (_basePage + _selected).toDouble())
          .round();
      var delta = index - current % widget.games.length;
      if (delta > widget.games.length ~/ 2) delta -= widget.games.length;
      if (delta < -(widget.games.length ~/ 2)) delta += widget.games.length;
      target = current + delta;
    }
    if (MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context)) {
      _controller.jumpToPage(target);
      setState(() {
        _selected = index;
        _moving = false;
      });
    } else {
      setState(() => _moving = true);
      _controller.animateToPage(
        target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _recenterIfNeeded() {
    if (!_loops || !_controller.hasClients || _recentering) return;
    final page = _controller.page?.round();
    if (page == null || (page - _basePage).abs() < widget.games.length * 20) {
      return;
    }
    // Rebase only at rest by a whole number of catalogue cycles. The three
    // visible games remain identical, without retaining an unbounded history.
    final revision = _revision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          revision != _revision ||
          _moving ||
          !_controller.hasClients) {
        return;
      }
      _recentering = true;
      _controller.jumpToPage(_basePage + _selected);
      _recentering = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.games.isEmpty) return const SizedBox.shrink();
    final game = widget.games[_selected.clamp(0, widget.games.length - 1)];
    final canOpen = widget.enabled && !_moving;
    final category = widget.category.name;
    return Padding(
      key: Key('games-section-$category'),
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    widget.category.label,
                    style: Theme.of(context).textTheme.titleLarge!.copyWith(
                      color: _ink,
                      fontSize: 21,
                      height: 1.15,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.45,
                    ),
                  ),
                ),
              ),
              Text(
                '${widget.games.length} ${widget.games.length == 1 ? 'game' : 'games'}',
                style: Theme.of(context).textTheme.bodySmall!.copyWith(
                  color: const Color(0xFF8A8793),
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final slotWidth = constraints.maxWidth * _viewportFraction;
              final centerWidth =
                  (slotWidth - _coverGap) / ((1 + _sideWidthScale) / 2);
              final centerHeight = centerWidth / 0.76;
              return SizedBox(
                height: centerHeight + 16,
                child: Semantics(
                  key: Key('games-coverflow-$category'),
                  container: true,
                  label: '${widget.category.label} game selector',
                  value: '${_selected + 1} of ${widget.games.length}',
                  increasedValue: _loops || _selected < widget.games.length - 1
                      ? widget
                            .games[(_selected + 1) % widget.games.length]
                            .title
                      : null,
                  decreasedValue: _loops || _selected > 0
                      ? widget
                            .games[(_selected - 1) % widget.games.length]
                            .title
                      : null,
                  onIncrease: _loops || _selected < widget.games.length - 1
                      ? () => _select((_selected + 1) % widget.games.length)
                      : null,
                  onDecrease: _loops || _selected > 0
                      ? () => _select((_selected - 1) % widget.games.length)
                      : null,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification.depth != 0 || _recentering) return false;
                      if (notification is ScrollStartNotification && !_moving) {
                        setState(() => _moving = true);
                      } else if (notification is ScrollEndNotification &&
                          _moving) {
                        setState(() => _moving = false);
                        _recenterIfNeeded();
                      }
                      return false;
                    },
                    child: PageView.builder(
                      key: Key('games-coverflow-pages-$category'),
                      controller: _controller,
                      itemCount: _loops ? null : widget.games.length,
                      onPageChanged: (index) => setState(
                        () => _selected = index % widget.games.length,
                      ),
                      itemBuilder: (context, pageIndex) {
                        final index = pageIndex % widget.games.length;
                        final item = widget.games[index];
                        final identity = _identity(item);
                        return AnimatedBuilder(
                          animation: _controller,
                          builder: (context, _) {
                            final page = _controller.hasClients
                                ? _controller.page ??
                                      (_basePage + _selected).toDouble()
                                : (_basePage + _selected).toDouble();
                            final distance = (page - pageIndex).abs().clamp(
                              0.0,
                              1.0,
                            );
                            final selected = index == _selected;
                            return Center(
                              child: OverflowBox(
                                minWidth: 0,
                                maxWidth: centerWidth,
                                minHeight: 0,
                                maxHeight: centerHeight,
                                child: SizedBox(
                                  key: Key('game-coverflow-image-$identity'),
                                  width:
                                      (centerWidth *
                                              (1 -
                                                  distance *
                                                      (1 - _sideWidthScale)))
                                          .clamp(48.0, double.infinity),
                                  height: centerHeight * (1 - distance * 0.26),
                                  child: Semantics(
                                    key: Key('game-coverflow-action-$identity'),
                                    button: true,
                                    selected: selected,
                                    label:
                                        '${selected ? 'Open' : 'Select'} ${item.title}. '
                                        '${item.typeLabel}. ${item.totalLevels} levels.',
                                    onTap: selected
                                        ? canOpen
                                              ? () => widget.onOpen(item)
                                              : null
                                        : () => _select(index),
                                    child: ExcludeSemantics(
                                      child: Material(
                                        color: const Color(0xFFF4F3F7),
                                        borderRadius: BorderRadius.circular(14),
                                        clipBehavior: Clip.antiAlias,
                                        child: InkWell(
                                          key: Key('game-card-$identity'),
                                          onTap: selected
                                              ? canOpen
                                                    ? () => widget.onOpen(item)
                                                    : null
                                              : () => _select(index),
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              GameCoverImage(game: item),
                                              IgnorePointer(
                                                child: ColoredBox(
                                                  color: Colors.black
                                                      .withValues(
                                                        alpha: distance * 0.26,
                                                      ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          _SelectedGame(
            key: Key('game-coverflow-selected-$category'),
            game: game,
            onOpen: canOpen ? () => widget.onOpen(game) : null,
          ),
        ],
      ),
    );
  }
}

class _SelectedGame extends StatelessWidget {
  const _SelectedGame({super.key, required this.game, required this.onOpen});
  final MiniGame game;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
    final progress = game.playerProgress;
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          game.title,
          maxLines: largeText ? null : 2,
          overflow: largeText ? null : TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium!.copyWith(
            color: _ink,
            fontSize: 18,
            height: 1.15,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.35,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          '${game.duration} · ${game.totalLevels} ${game.totalLevels == 1 ? 'level' : 'levels'}',
          style: Theme.of(context).textTheme.bodySmall!.copyWith(
            color: const Color(0xFF8A8793),
            fontSize: 12,
            height: 1.3,
          ),
        ),
        if (game.hasStarted) ...[
          const SizedBox(height: 9),
          Text(
            '${progress.completedLevels}/${game.totalLevels} levels completed',
            style: Theme.of(context).textTheme.bodySmall!.copyWith(
              color: const Color(0xFF6C6876),
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 5),
          LinearProgressIndicator(
            key: Key('game-coverflow-progress-${game.slug}'),
            value: progress.percent,
            minHeight: 3,
            borderRadius: BorderRadius.circular(20),
            color: const Color(0xFF7965C4),
            backgroundColor: const Color(0xFFEDEAF5),
          ),
        ],
      ],
    );
    final play = FilledButton.icon(
      key: Key('game-coverflow-play-${game.slug}'),
      onPressed: onOpen,
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF25262A),
        foregroundColor: Colors.white,
        minimumSize: const Size(84, 48),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
        shape: const StadiumBorder(),
        textStyle: Theme.of(context).textTheme.labelLarge!.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
      icon: const Icon(Icons.play_arrow_rounded, size: 20),
      label: Text(
        game.hasStarted ? 'Continue' : 'Play',
        semanticsLabel:
            '${game.hasStarted ? 'Continue' : 'Play'} ${game.title}',
      ),
    );
    if (largeText) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [info, const SizedBox(height: 12), play],
      );
    }
    return Row(
      children: [
        Expanded(child: info),
        const SizedBox(width: 14),
        play,
      ],
    );
  }
}

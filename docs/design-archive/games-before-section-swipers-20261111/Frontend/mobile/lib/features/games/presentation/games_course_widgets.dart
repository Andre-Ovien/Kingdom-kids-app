import 'package:flutter/material.dart';

import '../domain/mini_game.dart';
import 'game_cover_image.dart';

const gamesCourseOrange = Color(0xFFFFA365);
const _ink = Color(0xFF25262A);

class GamesCourseHeader extends StatelessWidget {
  const GamesCourseHeader({
    super.key,
    required this.featured,
    required this.loading,
    required this.onTap,
    this.previous,
    this.transitionProgress = 1,
    this.countdownProgress = 0,
    this.showCountdown = false,
  });
  final MiniGame? featured;
  final MiniGame? previous;
  final bool loading;
  final VoidCallback? onTap;
  final double transitionProgress;
  final double countdownProgress;
  final bool showCountdown;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final width = MediaQuery.sizeOf(context).width - 44;
    final foreground = featured == null ? _ink : Colors.white;
    final headingStyle = Theme.of(context).textTheme.titleLarge!.copyWith(
      color: foreground,
      fontSize: 20,
      height: 1.1,
      fontWeight: FontWeight.w600,
    );
    final titleStyle = Theme.of(context).textTheme.headlineSmall!.copyWith(
      color: foreground,
      fontSize: 28,
      height: 1.02,
      letterSpacing: -0.7,
      fontWeight: FontWeight.w700,
    );
    final title =
        featured?.title ??
        (loading
            ? 'Loading this week’s games…'
            : 'Discover your next adventure');
    final buttonHeight = (MediaQuery.textScalerOf(context).scale(14) * 1.2 + 24)
        .clamp(48.0, double.infinity)
        .ceilToDouble();
    final currentHeight = _courseTextHeight(
      context,
      title,
      titleStyle,
      width,
      maxLines: 2,
    );
    final previousHeight = previous == null
        ? 0.0
        : _courseTextHeight(
            context,
            previous!.title,
            titleStyle,
            width,
            maxLines: 2,
          );
    final titleHeight = currentHeight > previousHeight
        ? currentHeight
        : previousHeight;
    final contentHeight =
        _courseTextHeight(
          context,
          'Games of the Week',
          headingStyle,
          width,
          maxLines: 2,
        ) +
        8 +
        titleHeight +
        18 +
        buttonHeight;
    final height = (top + contentHeight + 62).clamp(top + 278, double.infinity);
    final t = transitionProgress.clamp(0.0, 1.0);
    final play = FilledButton.icon(
      key: const Key('game-week-play'),
      onPressed: onTap,
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF17191D),
        foregroundColor: Colors.white,
        disabledBackgroundColor: const Color(0xFF17191D),
        disabledForegroundColor: Colors.white70,
        minimumSize: const Size(126, 48),
        padding: const EdgeInsets.symmetric(horizontal: 23, vertical: 12),
        textStyle: Theme.of(context).textTheme.labelLarge!.copyWith(
          fontSize: 14,
          height: 1.2,
          fontWeight: FontWeight.w800,
        ),
        shape: const StadiumBorder(),
      ),
      icon: const Icon(Icons.play_arrow_rounded, size: 22),
      label: Text(
        'Play',
        semanticsLabel: featured == null
            ? 'Play unavailable'
            : 'Play ${featured!.title}',
      ),
    );
    return SizedBox(
      key: const Key('games-course-header'),
      height: height,
      child: Semantics(
        key: const Key('games-featured-banner'),
        container: true,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (featured != null) ...[
              const ColoredBox(color: Color(0xFF17191D)),
              if (previous != null)
                Transform.translate(
                  offset: Offset(-14 * t, 0),
                  child: Opacity(
                    key: ValueKey(
                      'games-week-previous-cover-${previous!.slug}',
                    ),
                    opacity: 1 - t,
                    child: ExcludeSemantics(
                      child: GameCoverImage(game: previous!),
                    ),
                  ),
                ),
              Transform.translate(
                offset: Offset(previous == null ? 0 : 14 * (1 - t), 0),
                child: Opacity(
                  key: ValueKey('games-week-current-cover-${featured!.slug}'),
                  opacity: previous == null ? 1 : t,
                  child: ExcludeSemantics(
                    child: GameCoverImage(
                      key: const Key('games-featured-cover'),
                      game: featured!,
                    ),
                  ),
                ),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x12000000),
                      Color(0x28000000),
                      Color(0xC4000000),
                    ],
                    stops: [0, 0.35, 1],
                  ),
                ),
              ),
            ] else
              const ColoredBox(color: gamesCourseOrange),
            Padding(
              padding: EdgeInsets.fromLTRB(22, top + 36, 22, 26),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      'Games of the Week',
                      maxLines: 2,
                      style: headingStyle,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: titleHeight,
                    child: Stack(
                      children: [
                        if (previous != null)
                          Positioned.fill(
                            child: Transform.translate(
                              offset: Offset(-10 * t, 0),
                              child: Opacity(
                                key: ValueKey(
                                  'games-week-previous-title-${previous!.slug}',
                                ),
                                opacity: 1 - t,
                                child: ExcludeSemantics(
                                  child: Text(
                                    previous!.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: titleStyle,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Positioned.fill(
                          child: Transform.translate(
                            offset: Offset(
                              previous == null ? 0 : 10 * (1 - t),
                              0,
                            ),
                            child: Opacity(
                              key: ValueKey(
                                'games-week-current-title-${featured?.slug ?? 'empty'}',
                              ),
                              opacity: previous == null ? 1 : t,
                              child: Text(
                                title,
                                key: const Key('games-featured-title'),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: titleStyle,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (showCountdown)
                    CustomPaint(
                      key: const Key('games-week-countdown'),
                      foregroundPainter: GamesWeekPillPainter(
                        progress: countdownProgress,
                      ),
                      child: play,
                    )
                  else
                    play,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A full stadium outline around the Play button, driven by the dwell clock.
class GamesWeekPillPainter extends CustomPainter {
  const GamesWeekPillPainter({required this.progress});
  final double progress;
  Path outlineFor(Size size) => Path()
    ..addRRect(
      RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(1.2),
        Radius.circular((size.height - 2.4) / 2),
      ),
    );
  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final path = outlineFor(size);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.2);
    canvas.drawPath(path, track);
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * progress.clamp(0.0, 1.0)),
      track..color = Colors.white.withValues(alpha: 0.94),
    );
  }

  @override
  bool shouldRepaint(GamesWeekPillPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class GamesCourseCategories extends StatelessWidget {
  const GamesCourseCategories({
    super.key,
    required this.available,
    required this.selected,
    required this.onSelected,
  });
  final Set<GameCategory> available;
  final GameCategory? selected;
  final ValueChanged<GameCategory?> onSelected;
  @override
  Widget build(BuildContext context) {
    final options = <GameCategory?>[
      null,
      ...GameCategory.values.where(available.contains),
    ];
    return SizedBox(
      key: const Key('games-category-tabs'),
      height:
          46 +
          (MediaQuery.textScalerOf(context).scale(1).clamp(1, 2.2) - 1) * 16,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (context, index) {
          final category = options[index];
          final active = category == selected;
          return Semantics(
            button: true,
            selected: active,
            child: Material(
              color: active ? const Color(0xFFF0EDFC) : Colors.white,
              borderRadius: BorderRadius.circular(17),
              child: InkWell(
                key: Key('game-category-${category?.name ?? 'all'}'),
                borderRadius: BorderRadius.circular(17),
                onTap: () => onSelected(category),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 11),
                  child: Row(
                    children: [
                      Icon(
                        switch (category) {
                          GameCategory.quiz => Icons.quiz_rounded,
                          GameCategory.puzzle => Icons.extension_rounded,
                          GameCategory.game => Icons.sports_esports_rounded,
                          GameCategory.matching => Icons.compare_arrows_rounded,
                          null => Icons.grid_view_rounded,
                        },
                        size: 16,
                        color: active
                            ? const Color(0xFF7965C4)
                            : const Color(0xFF8A8793),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        category?.label ?? 'All',
                        style: TextStyle(
                          color: _ink,
                          fontSize: 12,
                          fontWeight: active
                              ? FontWeight.w800
                              : FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class GamesCourseSearch extends StatelessWidget {
  const GamesCourseSearch({
    super.key,
    required this.controller,
    required this.onChanged,
  });
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) => TextField(
    key: const Key('game-search-field'),
    controller: controller,
    onChanged: onChanged,
    textInputAction: TextInputAction.search,
    style: const TextStyle(
      color: _ink,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
    decoration: InputDecoration(
      hintText: 'Search a hero or game…',
      filled: true,
      fillColor: const Color(0xFFF6F5FA),
      isDense: true,
      prefixIcon: const Icon(Icons.search_rounded, size: 20, color: _ink),
      suffixIcon: controller.text.isEmpty
          ? null
          : IconButton(
              key: const Key('clear-game-search'),
              tooltip: 'Clear game search',
              onPressed: () {
                controller.clear();
                onChanged('');
              },
              icon: const Icon(Icons.close_rounded, size: 19, color: _ink),
            ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(99),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(99),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(99),
        borderSide: const BorderSide(color: Color(0xFFB7A5FF), width: 1.4),
      ),
    ),
  );
}

class GamesCourseCard extends StatelessWidget {
  const GamesCourseCard({
    super.key,
    required this.game,
    required this.index,
    required this.featured,
    required this.onTap,
  });
  final MiniGame game;
  final int index;
  final bool featured;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = index.isEven;
    final foreground = dark ? Colors.white : _ink;
    final progress = game.playerProgress;
    final typeStyle = Theme.of(context).textTheme.labelSmall!.copyWith(
      color: foreground.withValues(alpha: 0.8),
      fontSize: 9,
      height: 1.2,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.1,
    );
    final durationStyle = Theme.of(context).textTheme.bodySmall!.copyWith(
      color: foreground.withValues(alpha: 0.63),
      fontSize: 10,
      height: 1.2,
      fontWeight: FontWeight.w500,
    );
    final titleStyle = Theme.of(context).textTheme.titleLarge!.copyWith(
      color: foreground,
      fontSize: 20,
      height: 1.05,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
    );
    final metaStyle = Theme.of(context).textTheme.bodySmall!.copyWith(
      color: foreground.withValues(alpha: 0.77),
      fontSize: 11,
      height: 1.25,
      fontWeight: FontWeight.w600,
    );
    final metadata = game.hasStarted
        ? '${progress.completedLevels}/${game.totalLevels} levels completed'
        : '${game.totalLevels} ${game.totalLevels == 1 ? 'level' : 'levels'} · Ready to play';
    return Semantics(
      key: featured ? Key('featured-game-${game.slug}') : null,
      button: true,
      onTap: onTap,
      label: featured
          ? 'Game of the Week. ${game.title}. ${game.typeLabel}. ${game.totalLevels} levels. ${game.hasStarted ? 'Continue' : 'Play now'}.'
          : '${game.title}. ${game.typeLabel}. ${game.totalLevels} levels. ${progress.hasStarted ? '${progress.completedLevels} completed. Continue playing.' : 'Not started. Play now.'}',
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final headerTextHeight =
                _courseTextHeight(
                  context,
                  game.typeLabel.toUpperCase(),
                  typeStyle,
                  width - 82,
                ) +
                3 +
                _courseTextHeight(
                  context,
                  game.duration,
                  durationStyle,
                  width - 82,
                );
            final headerHeight = headerTextHeight.clamp(40.0, double.infinity);
            final titleHeight = _courseTextHeight(
              context,
              game.title,
              titleStyle,
              width - 32,
              maxLines: 2,
            );
            final footerHeight =
                (_courseTextHeight(context, metadata, metaStyle, width - 128) +
                        (game.hasStarted ? 10 : 0))
                    .clamp(78.0, double.infinity);
            final needed =
                32 + headerHeight + 12 + titleHeight + 14 + footerHeight;
            final baseHeight = (width * 0.64).clamp(220.0, 260.0);
            final height = needed > baseHeight ? needed : baseHeight;
            return Material(
              key: Key('game-card-surface-${game.slug}'),
              color: dark ? const Color(0xFF292B30) : const Color(0xFFBBB3F5),
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(42),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: Key('game-card-${game.slug}'),
                onTap: onTap,
                child: SizedBox(
                  height: height,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned(
                        right: -12,
                        top: -10,
                        width: 190,
                        height: height + 20,
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _CourseLines(
                              foreground.withValues(alpha: dark ? 0.08 : 0.12),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 18, 14, 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                SizedBox(
                                  width: 40,
                                  height: 40,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(13),
                                    child: GameCoverImage(game: game),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        game.typeLabel.toUpperCase(),
                                        style: typeStyle,
                                      ),
                                      const SizedBox(height: 3),
                                      Text(game.duration, style: durationStyle),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              game.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: titleStyle,
                            ),
                            const SizedBox(height: 14),
                            const Spacer(),
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(metadata, style: metaStyle),
                                      if (game.hasStarted) ...[
                                        const SizedBox(height: 7),
                                        LinearProgressIndicator(
                                          value: progress.percent,
                                          minHeight: 3,
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                          color: foreground.withValues(
                                            alpha: 0.9,
                                          ),
                                          backgroundColor: foreground
                                              .withValues(alpha: 0.15),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 18),
                                Container(
                                  key: Key('game-card-ring-${game.slug}'),
                                  width: 78,
                                  height: 78,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: foreground.withValues(alpha: 0.58),
                                      width: 1.8,
                                    ),
                                  ),
                                  child: Center(
                                    child: Container(
                                      key: Key('game-card-arrow-${game.slug}'),
                                      width: 64,
                                      height: 64,
                                      decoration: const BoxDecoration(
                                        color: Color(0xFFFFFDF7),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(
                                        Icons.arrow_forward_rounded,
                                        color: _ink,
                                        size: 29,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

double _courseTextHeight(
  BuildContext context,
  String text,
  TextStyle style,
  double width, {
  int? maxLines,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: maxLines,
    ellipsis: maxLines == null ? null : '…',
  )..layout(maxWidth: width.clamp(1.0, double.infinity));
  final height = painter.height;
  painter.dispose();
  return height;
}

class _CourseLines extends CustomPainter {
  const _CourseLines(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(
      Path()
        ..moveTo(size.width * 0.8, -10)
        ..cubicTo(-12, 20, size.width * 1.3, 83, size.width * 0.5, 115)
        ..cubicTo(-22, 146, 36, 174, size.width + 22, size.height + 12),
      paint,
    );
  }

  @override
  bool shouldRepaint(_CourseLines oldDelegate) => oldDelegate.color != color;
}

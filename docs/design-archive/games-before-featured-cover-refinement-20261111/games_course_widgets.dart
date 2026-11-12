import 'package:flutter/material.dart';

import '../domain/mini_game.dart';
import 'game_cover_image.dart';

const gamesCourseOrange = Color(0xFFFFA365);
const _ink = Color(0xFF25262A);

class GamesCourseHeader extends StatelessWidget {
  const GamesCourseHeader({
    super.key,
    required this.games,
    required this.loading,
  });
  final List<MiniGame> games;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final started = games.where((game) => game.hasStarted).length;
    final stars = games.fold<int>(
      0,
      (sum, game) => sum + game.playerProgress.starsEarned,
    );
    final levels = games.fold<int>(0, (sum, game) => sum + game.totalLevels);
    final artwork = ExcludeSemantics(
      child: Image.asset(
        'assets/images/home/play-premium-v1.png',
        fit: BoxFit.contain,
      ),
    );
    final title = Semantics(
      header: true,
      child: Text(
        'Game of the Week',
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
          color: _ink,
          fontSize: 30,
          height: 1.0,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.9,
        ),
      ),
    );
    final summaries = Semantics(
      container: true,
      label: loading
          ? 'Loading games'
          : '${games.length} ${games.length == 1 ? 'quest' : 'quests'} available. $levels ${levels == 1 ? 'level' : 'levels'} available. $started started. $stars ${stars == 1 ? 'star' : 'stars'} earned.',
      child: ExcludeSemantics(
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _SummaryChip(
              icon: Icons.grid_view_rounded,
              text: loading ? 'Loading games' : '${games.length} Games',
              dark: true,
            ),
            _SummaryChip(
              icon: Icons.flag_rounded,
              text: loading ? '…' : '$levels Levels',
              dark: false,
            ),
          ],
        ),
      ),
    );
    if (scale > 1.3) {
      return Padding(
        key: const Key('games-course-header'),
        padding: EdgeInsets.fromLTRB(22, top + 24, 22, 25),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: title),
                const SizedBox(width: 12),
                SizedBox(width: 88, height: 100, child: artwork),
              ],
            ),
            const SizedBox(height: 24),
            summaries,
          ],
        ),
      );
    }
    return SizedBox(
      key: const Key('games-course-header'),
      height: top + 254,
      child: Stack(
        children: [
          Positioned(
            top: top + 22,
            right: 8,
            width: MediaQuery.sizeOf(context).width < 360 ? 140 : 167,
            height: 156,
            child: artwork,
          ),
          Positioned(top: top + 77, left: 24, right: 135, child: title),
          Positioned(left: 22, right: 22, bottom: 25, child: summaries),
        ],
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({
    required this.icon,
    required this.text,
    required this.dark,
  });
  final IconData icon;
  final String text;
  final bool dark;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
    decoration: BoxDecoration(
      color: dark ? _ink : Colors.white.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(24),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: dark ? Colors.white : _ink),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            text,
            style: TextStyle(
              color: dark ? Colors.white : _ink,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
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
    return Semantics(
      key: featured ? Key('featured-game-${game.slug}') : null,
      button: true,
      onTap: onTap,
      label: featured
          ? 'Game of the Week. ${game.title}. ${game.typeLabel}. ${game.totalLevels} levels. ${game.hasStarted ? 'Continue' : 'Play now'}.'
          : '${game.title}. ${game.typeLabel}. ${game.totalLevels} levels. ${progress.hasStarted ? '${progress.completedLevels} completed. Continue playing.' : 'Not started. Play now.'}',
      child: ExcludeSemantics(
        child: Material(
          color: dark ? const Color(0xFF292B30) : const Color(0xFFBBB3F5),
          borderRadius: BorderRadius.circular(30),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: Key('game-card-${game.slug}'),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 186),
              child: Stack(
                children: [
                  Positioned(
                    right: -12,
                    top: -10,
                    width: 170,
                    height: 210,
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _CourseLines(
                          foreground.withValues(alpha: dark ? 0.08 : 0.12),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
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
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    game.typeLabel.toUpperCase(),
                                    style: TextStyle(
                                      color: foreground.withValues(alpha: 0.8),
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 1.1,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    game.duration,
                                    style: TextStyle(
                                      color: foreground.withValues(alpha: 0.63),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
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
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: foreground,
                                fontSize: 20,
                                height: 1.05,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.5,
                              ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    game.hasStarted
                                        ? '${progress.completedLevels}/${game.totalLevels} levels completed'
                                        : '${game.totalLevels} ${game.totalLevels == 1 ? 'level' : 'levels'} · Ready to play',
                                    style: TextStyle(
                                      color: foreground.withValues(alpha: 0.77),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (game.hasStarted) ...[
                                    const SizedBox(height: 7),
                                    LinearProgressIndicator(
                                      value: progress.percent,
                                      minHeight: 3,
                                      borderRadius: BorderRadius.circular(20),
                                      color: foreground.withValues(alpha: 0.9),
                                      backgroundColor: foreground.withValues(
                                        alpha: 0.15,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 18),
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFFDF7),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: foreground.withValues(alpha: 0.35),
                                  width: 1.2,
                                ),
                              ),
                              child: const Icon(
                                Icons.arrow_forward_rounded,
                                color: _ink,
                                size: 22,
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
        ),
      ),
    );
  }
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

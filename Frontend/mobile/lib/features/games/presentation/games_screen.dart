import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../../shared/widgets/floating_liquid_nav.dart';
import '../data/game_repository.dart';
import '../domain/mini_game.dart';

class GamesScreen extends StatelessWidget {
  const GamesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const games = GameRepository.items;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Stack(
          children: [
            CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(22, 12, 22, 116),
                  sliver: SliverList.list(
                    children: [
                      const _GamesHeader(),
                      const SizedBox(height: 18),
                      _EditorialGameCard(
                        game: games.first,
                        eyebrow: 'TODAY\'S QUEST',
                        headline: 'Pair every animal before the rain falls',
                        supporting:
                            'A gentle matching challenge from Noah\'s story.',
                        large: true,
                      ),
                      const SizedBox(height: 22),
                      _AppStoreCollection(
                        eyebrow: 'KID FAVORITES',
                        title: 'Quick Bible Games',
                        games: games.skip(1).take(3).toList(),
                      ),
                      const SizedBox(height: 22),
                      _EditorialGameCard(
                        game: games[2],
                        eyebrow: 'COURAGE CHALLENGE',
                        headline: 'Help David aim with focus and faith',
                        supporting:
                            'Simple puzzles that reward patience and courage.',
                      ),
                      const SizedBox(height: 22),
                      _AppStoreCollection(
                        eyebrow: 'LEARN BY PLAYING',
                        title: 'Memory, Quiz & Puzzle',
                        games: games.skip(4).take(4).toList(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: FloatingLiquidNav(selectedRoute: AppRoutes.games),
            ),
          ],
        ),
      ),
    );
  }
}

void _openGame(BuildContext context, MiniGame game) {
  Navigator.of(context).pushNamed(AppRoutes.gameDetail, arguments: game);
}

class _GamesHeader extends StatelessWidget {
  const _GamesHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Games',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 32,
                  fontWeight: FontWeight.w600,
                  height: 1.05,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                'Bible adventures to play today',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: _mutedText(context),
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          color: _secondaryText(context),
          onPressed: () {},
          icon: const Icon(Icons.search_rounded, size: 25),
        ),
      ],
    );
  }
}

class _EditorialGameCard extends StatelessWidget {
  const _EditorialGameCard({
    required this.game,
    required this.eyebrow,
    required this.headline,
    required this.supporting,
    this.large = false,
  });

  final MiniGame game;
  final String eyebrow;
  final String headline;
  final String supporting;
  final bool large;

  @override
  Widget build(BuildContext context) {
    const playButtonBottom = 32.0;
    const playButtonHeight = 52.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openGame(context, game),
          child: SizedBox(
            height: large ? 430 : 352,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.asset(
                  game.imageAsset,
                  fit: BoxFit.cover,
                  alignment: game.imageAlignment,
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.08),
                        Colors.black.withValues(alpha: 0.18),
                        Colors.black.withValues(alpha: 0.82),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: playButtonBottom + playButtonHeight + 28,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        eyebrow,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.68),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        headline,
                        maxLines: large ? 3 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontSize: large ? 32 : 27,
                          fontWeight: FontWeight.w700,
                          height: 1.04,
                          letterSpacing: 0,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        supporting,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 15,
                          fontWeight: FontWeight.w400,
                          height: 1.28,
                          letterSpacing: 0,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: playButtonBottom,
                  child: Center(child: _FeaturedPlayButton(game: game)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FeaturedPlayButton extends StatelessWidget {
  const _FeaturedPlayButton({required this.game});

  final MiniGame game;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFFFF7043),
        foregroundColor: Colors.white,
        minimumSize: const Size(132, 52),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        textStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
      ),
      onPressed: () => _openGame(context, game),
      icon: const Icon(Icons.play_arrow_rounded, size: 22),
      label: const Text('Play'),
    );
  }
}

class _AppStoreCollection extends StatelessWidget {
  const _AppStoreCollection({
    required this.eyebrow,
    required this.title,
    required this.games,
  });

  final String eyebrow;
  final String title;
  final List<MiniGame> games;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 6),
      decoration: BoxDecoration(
        color: _collectionColor(context),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            eyebrow,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: _mutedText(context),
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 28,
              fontWeight: FontWeight.w700,
              height: 1.05,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 18),
          for (var index = 0; index < games.length; index++) ...[
            _AppStoreGameRow(game: games[index]),
            if (index != games.length - 1)
              Divider(
                height: 18,
                color: _isDark(context)
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.06),
              ),
          ],
        ],
      ),
    );
  }
}

class _AppStoreGameRow extends StatelessWidget {
  const _AppStoreGameRow({required this.game});

  final MiniGame game;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _openGame(context, game),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            _GameIconTile(game: game, size: 62, radius: 16),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    game.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      height: 1.1,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${game.typeLabel} game',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: _mutedText(context),
                      fontSize: 13,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              children: [
                _GetButton(
                  onTap: () => _openGame(context, game),
                  compact: true,
                ),
                const SizedBox(height: 4),
                Text(
                  '+${game.rewardStars} stars',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: _mutedText(context),
                    fontSize: 10,
                    letterSpacing: 0,
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

class _GameIconTile extends StatelessWidget {
  const _GameIconTile({
    required this.game,
    required this.size,
    required this.radius,
  });

  final MiniGame game;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              game.imageAsset,
              fit: BoxFit.cover,
              alignment: game.imageAlignment,
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.36),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GetButton extends StatelessWidget {
  const _GetButton({required this.onTap, this.compact = false});

  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: compact ? 34 : 38,
        constraints: BoxConstraints(minWidth: compact ? 64 : 74),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _isDark(context)
              ? Colors.white.withValues(alpha: 0.15)
              : const Color(0xFFE8EDF5),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          'Play',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: const Color(0xFFFF7043),
            fontSize: compact ? 13 : 15,
            fontWeight: FontWeight.w700,
            height: 1,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}

bool _isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

Color _collectionColor(BuildContext context) {
  return _isDark(context) ? const Color(0xFF1A1D1F) : const Color(0xFFF5F1EF);
}

Color _mutedText(BuildContext context) {
  return _isDark(context) ? const Color(0xFFA7A5AA) : const Color(0xFF928A8A);
}

Color _secondaryText(BuildContext context) {
  return _isDark(context) ? const Color(0xFFC4BCBA) : const Color(0xFF6B5F5F);
}

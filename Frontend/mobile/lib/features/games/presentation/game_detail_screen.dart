import 'package:flutter/material.dart';

import '../../../shared/widgets/liquid_glass.dart';
import '../data/game_repository.dart';
import '../domain/mini_game.dart';

class GameDetailScreen extends StatelessWidget {
  const GameDetailScreen({required this.game, super.key});

  final MiniGame game;

  @override
  Widget build(BuildContext context) {
    final related = GameRepository.items
        .where((item) => item.id != game.id)
        .take(3)
        .toList();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 36),
              sliver: SliverList.list(
                children: [
                  const _GameDetailTopBar(),
                  const SizedBox(height: 18),
                  _GamePreviewCard(game: game),
                  const SizedBox(height: 22),
                  _GameInfo(game: game),
                  const SizedBox(height: 28),
                  Text(
                    'More games',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 14),
                  for (final item in related) ...[
                    _RelatedGameRow(game: item),
                    const SizedBox(height: 14),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GameDetailTopBar extends StatelessWidget {
  const _GameDetailTopBar();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        LiquidGlass(
          borderRadius: 28,
          opacity: _isDark(context) ? 0.08 : 0.18,
          blur: 28,
          borderOpacity: _isDark(context) ? 0.34 : 0.58,
          child: SizedBox.square(
            dimension: 48,
            child: IconButton(
              padding: EdgeInsets.zero,
              onPressed: () => Navigator.of(context).maybePop(),
              icon: Icon(
                Icons.arrow_back_ios_new_rounded,
                color: _primaryText(context),
                size: 22,
              ),
            ),
          ),
        ),
        Expanded(
          child: Text(
            'Game',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: _primaryText(context),
              fontSize: 21,
              fontWeight: FontWeight.w400,
              letterSpacing: 0,
            ),
          ),
        ),
        const SizedBox(width: 48),
      ],
    );
  }
}

class _GamePreviewCard extends StatelessWidget {
  const _GamePreviewCard({required this.game});

  final MiniGame game;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: AspectRatio(
        aspectRatio: 16 / 10,
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
                    Colors.black.withValues(alpha: 0.7),
                    Colors.black.withValues(alpha: 0.08),
                  ],
                ),
              ),
            ),
            Center(
              child: LiquidGlass(
                borderRadius: 38,
                opacity: 0.1,
                blur: 28,
                borderOpacity: 0.48,
                child: SizedBox.square(
                  dimension: 72,
                  child: Icon(
                    _gameIcon(game.type),
                    color: Colors.white,
                    size: 42,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Row(
                children: [
                  _GamePill(label: game.typeLabel),
                  const SizedBox(width: 8),
                  _GamePill(label: game.difficulty),
                  const Spacer(),
                  _GamePill(label: '+${game.rewardStars} stars'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GamePill extends StatelessWidget {
  const _GamePill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: const Color(0xFFFF7043),
            fontSize: 10,
            fontWeight: FontWeight.w500,
            height: 1,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}

class _GameInfo extends StatelessWidget {
  const _GameInfo({required this.game});

  final MiniGame game;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          game.title,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: _primaryText(context),
            fontSize: 25,
            fontWeight: FontWeight.w500,
            height: 1.08,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Icon(
              Icons.extension_rounded,
              color: Color(0xFFFF7043),
              size: 18,
            ),
            const SizedBox(width: 6),
            Text(
              '${game.duration}  •  ${game.totalLevels} levels',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: _mutedText(context),
                fontSize: 12.5,
                fontWeight: FontWeight.w400,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          game.description,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: _secondaryText(context),
            fontSize: 13.4,
            height: 1.46,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 18),
        if (game.progress > 0) ...[
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: game.progress,
                    minHeight: 6,
                    backgroundColor: _isDark(context)
                        ? Colors.white.withValues(alpha: 0.12)
                        : const Color(0xFFF1E7E5),
                    valueColor: const AlwaysStoppedAnimation(Color(0xFFFF7043)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Level ${game.currentLevel}',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: _mutedText(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
        ],
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFF7043),
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () => _showGameStartSheet(context, game),
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(game.progress > 0 ? 'Resume Game' : 'Start Game'),
              ),
            ),
            const SizedBox(width: 12),
            LiquidGlass(
              borderRadius: 26,
              opacity: _isDark(context) ? 0.06 : 0.2,
              blur: 24,
              borderOpacity: _isDark(context) ? 0.26 : 0.52,
              child: SizedBox.square(
                dimension: 48,
                child: Icon(
                  Icons.bookmark_rounded,
                  color: _primaryText(context),
                  size: 22,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _RelatedGameRow extends StatelessWidget {
  const _RelatedGameRow({required this.game});

  final MiniGame game;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => GameDetailScreen(game: game)),
        );
      },
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(13),
            child: SizedBox(
              width: 92,
              height: 62,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(
                    game.imageAsset,
                    fit: BoxFit.cover,
                    alignment: game.imageAlignment,
                  ),
                  Center(
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.34),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _gameIcon(game.type),
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  game.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: _primaryText(context),
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${game.typeLabel}  •  ${game.difficulty}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: _mutedText(context),
                    fontSize: 11.5,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

void _showGameStartSheet(BuildContext context, MiniGame game) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (context) => _GameStartSheet(game: game),
  );
}

class _GameStartSheet extends StatelessWidget {
  const _GameStartSheet({required this.game});

  final MiniGame game;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(14),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        color: _isDark(context) ? const Color(0xFF171D1C) : Colors.white,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: _isDark(context)
                  ? Colors.white.withValues(alpha: 0.18)
                  : const Color(0xFFE7DEDC),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(height: 18),
          Icon(_gameIcon(game.type), color: const Color(0xFFFF7043), size: 34),
          const SizedBox(height: 10),
          Text(
            'Level ${game.currentLevel}',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: _primaryText(context),
              fontSize: 24,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            game.title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: _mutedText(context),
              fontSize: 13,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              _StartStat(label: game.typeLabel, icon: Icons.extension_rounded),
              _StartStat(label: game.difficulty, icon: Icons.bolt_rounded),
              _StartStat(
                label: '+${game.rewardStars}',
                icon: Icons.star_rounded,
              ),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFF7043),
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Ready'),
          ),
        ],
      ),
    );
  }
}

class _StartStat extends StatelessWidget {
  const _StartStat({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: const Color(0xFFFF7043), size: 22),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: _primaryText(context),
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

IconData _gameIcon(MiniGameType type) {
  return switch (type) {
    MiniGameType.dragAndDrop => Icons.touch_app_rounded,
    MiniGameType.matching => Icons.compare_arrows_rounded,
    MiniGameType.memory => Icons.style_rounded,
    MiniGameType.quiz => Icons.quiz_rounded,
    MiniGameType.puzzle => Icons.extension_rounded,
  };
}

bool _isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

Color _primaryText(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface;

Color _mutedText(BuildContext context) {
  return _isDark(context) ? const Color(0xFF9EA8A6) : const Color(0xFFB8ADAE);
}

Color _secondaryText(BuildContext context) {
  return _isDark(context) ? const Color(0xFFC9C0BD) : const Color(0xFF847A7A);
}

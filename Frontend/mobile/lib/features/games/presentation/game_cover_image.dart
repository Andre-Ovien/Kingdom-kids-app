import 'package:flutter/material.dart';

import '../domain/mini_game.dart';

class GameCoverImage extends StatelessWidget {
  const GameCoverImage({
    required this.game,
    super.key,
    this.fit = BoxFit.cover,
    this.borderRadius = BorderRadius.zero,
  });

  final MiniGame game;
  final BoxFit fit;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final url = game.coverImageUrl?.trim() ?? '';
    final asset = game.coverAssetKey.trim().isNotEmpty
        ? game.coverAssetKey
        : game.imageAsset;
    final placeholder = ColoredBox(
      color: _accent(game).withValues(alpha: 0.14),
      child: Center(
        child: Icon(_icon(game.gameType), color: _accent(game), size: 42),
      ),
    );

    return ClipRRect(
      borderRadius: borderRadius,
      child: url.isNotEmpty
          ? Image.network(
              url,
              fit: fit,
              alignment: game.imageAlignment,
              loadingBuilder: (context, child, progress) =>
                  progress == null ? child : placeholder,
              errorBuilder: (_, _, _) => _asset(asset, placeholder),
            )
          : _asset(asset, placeholder),
    );
  }

  Widget _asset(String asset, Widget placeholder) {
    if (asset.isEmpty) return placeholder;
    return Image.asset(
      asset,
      fit: fit,
      alignment: game.imageAlignment,
      errorBuilder: (_, _, _) => placeholder,
    );
  }
}

Color gameAccent(MiniGame game) => _accent(game);

Color _accent(MiniGame game) {
  final value = game.accentColor.replaceFirst('#', '');
  final parsed = int.tryParse(
    value.length == 6 ? 'FF$value' : value,
    radix: 16,
  );
  return parsed == null ? const Color(0xFFFF7043) : Color(parsed);
}

IconData gameTypeIcon(GameType type) => _icon(type);

IconData _icon(GameType type) {
  return switch (type) {
    GameType.quiz => Icons.quiz_rounded,
    GameType.memory => Icons.style_rounded,
    GameType.ordering => Icons.format_list_numbered_rounded,
    GameType.matching => Icons.compare_arrows_rounded,
    GameType.maze => Icons.route_rounded,
    GameType.path => Icons.touch_app_rounded,
    GameType.aim => Icons.gps_fixed_rounded,
  };
}

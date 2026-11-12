import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../core/media/content_media_fetcher.dart';
import '../../../core/media/content_media_image.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/data/media_access_scope.dart';
import '../data/game_repository.dart';
import '../domain/mini_game.dart';

class GameCoverImage extends StatefulWidget {
  const GameCoverImage({
    required this.game,
    super.key,
    this.fit = BoxFit.cover,
    this.borderRadius = BorderRadius.zero,
    this.mediaPolicy = AppConfig.contentMediaPolicy,
    this.mediaFetcher,
    this.authRepository,
    this.gameRepository,
  });

  final MiniGame game;
  final BoxFit fit;
  final BorderRadius borderRadius;
  final ContentMediaPolicy mediaPolicy;
  final ContentMediaFetcher? mediaFetcher;
  final AuthRepository? authRepository;
  final GameRepository? gameRepository;

  @override
  State<GameCoverImage> createState() => _GameCoverImageState();
}

class _GameCoverImageState extends State<GameCoverImage> {
  Future<Object?> Function()? _refreshSource;

  @override
  void initState() {
    super.initState();
    _configureScope();
  }

  @override
  void didUpdateWidget(GameCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.game.id != widget.game.id ||
        oldWidget.game.slug != widget.game.slug ||
        oldWidget.game.coverImageUrl != widget.game.coverImageUrl ||
        !identical(oldWidget.authRepository, widget.authRepository) ||
        !identical(oldWidget.gameRepository, widget.gameRepository)) {
      _configureScope();
    }
  }

  void _configureScope() {
    final original = widget.game;
    if (!canRefreshPrivateImageSource(original.coverImageUrl)) {
      _refreshSource = null;
      return;
    }
    final auth = widget.authRepository ?? AuthRepository();
    final scope = MediaAccessScope(auth);
    final repository =
        widget.gameRepository ?? RemoteGameRepository(authRepository: auth);
    _refreshSource = () async {
      final identity = await scope.requireCurrent();
      final fresh = await repository.fetchGame(
        original.slug,
        profileId: identity.childId,
      );
      await scope.requireCurrent();
      if (!mounted ||
          original.id.isEmpty ||
          fresh.id != original.id ||
          fresh.slug != original.slug ||
          widget.game.id != original.id ||
          widget.game.slug != original.slug) {
        return null;
      }
      return fresh.coverImageUrl;
    };
  }

  @override
  Widget build(BuildContext context) {
    final game = widget.game, borderRadius = widget.borderRadius;
    final asset = game.coverAssetKey.trim().isNotEmpty
        ? game.coverAssetKey
        : game.imageAsset;
    final placeholder = ColoredBox(
      color: _accent(game).withValues(alpha: 0.14),
      child: Center(
        child: Icon(gameIcon(game), color: _accent(game), size: 42),
      ),
    );

    return ClipRRect(
      borderRadius: borderRadius,
      child: ContentMediaImage(
        source: game.coverImageUrl,
        mediaPolicy: widget.mediaPolicy,
        mediaFetcher: widget.mediaFetcher,
        sourceRefresher: _refreshSource,
        fit: widget.fit,
        alignment: widget.game.imageAlignment,
        loadingBuilder: (_) => placeholder,
        errorBuilder: (_) => _asset(asset, placeholder),
      ),
    );
  }

  Widget _asset(String asset, Widget placeholder) {
    if (asset.isEmpty) return placeholder;
    return LayoutBuilder(
      builder: (context, constraints) => Image.asset(
        asset,
        cacheWidth: contentImageDecodeWidth(context, constraints),
        fit: widget.fit,
        alignment: widget.game.imageAlignment,
        errorBuilder: (_, _, _) => placeholder,
      ),
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

IconData gameIcon(MiniGame game) =>
    game.isArkGarden ? Icons.pets_rounded : gameTypeIcon(game.gameType);

IconData _icon(GameType type) {
  return switch (type) {
    GameType.quiz => Icons.quiz_rounded,
    GameType.memory => Icons.style_rounded,
    GameType.ordering => Icons.format_list_numbered_rounded,
    GameType.matching => Icons.compare_arrows_rounded,
    GameType.maze => Icons.route_rounded,
    GameType.path => Icons.touch_app_rounded,
    GameType.aim => Icons.gps_fixed_rounded,
    GameType.puzzle => Icons.extension_rounded,
  };
}

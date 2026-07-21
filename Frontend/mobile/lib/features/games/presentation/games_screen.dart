import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../../core/errors/app_exception.dart';
import '../../../shared/widgets/floating_liquid_nav.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/kid_profile.dart';
import '../../auth/presentation/session_expiry_navigation.dart';
import '../data/game_repository.dart';
import '../domain/mini_game.dart';
import 'game_cover_image.dart';
import 'game_detail_screen.dart';

const _gameInk = Color(0xFF151318);
const _gameCoral = Color(0xFFFF7A59);
const _gameCoralDark = Color(0xFF5A302D);
const _gamePaper = Color(0xFFFFFDF7);

class GamesScreen extends StatefulWidget {
  const GamesScreen({super.key, this.repository, this.authRepository});

  final GameRepository? repository;
  final AuthRepository? authRepository;

  @override
  State<GamesScreen> createState() => _GamesScreenState();
}

class _GamesScreenState extends State<GamesScreen> {
  final _searchController = TextEditingController();
  late final AuthRepository _authRepository;
  late final GameRepository _repository;
  List<MiniGame> _games = const [];
  KidProfile? _activeProfile;
  GameType? _filter;
  String _query = '';
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _authRepository = widget.authRepository ?? AuthRepository();
    _repository =
        widget.repository ??
        RemoteGameRepository(authRepository: _authRepository);
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profile = await _authRepository.currentKid();
      if (!mounted) return;
      if (profile == null) {
        setState(() {
          _activeProfile = null;
          _games = const [];
        });
        return;
      }
      final games = await _repository.fetchGames(profileId: profile.id);
      if (mounted) {
        setState(() {
          _activeProfile = profile;
          _games = games;
        });
      }
    } on AppException catch (error) {
      if (mounted && returnToSignInIfSessionExpired(context, error)) return;
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'We could not open the game room. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<MiniGame> get _visibleGames {
    final query = _query.trim().toLowerCase();
    return _games
        .where((game) {
          final matchesType = _filter == null || game.gameType == _filter;
          final matchesQuery =
              query.isEmpty ||
              game.title.toLowerCase().contains(query) ||
              game.subtitle.toLowerCase().contains(query) ||
              game.description.toLowerCase().contains(query) ||
              game.typeLabel.toLowerCase().contains(query);
          return matchesType && matchesQuery;
        })
        .toList(growable: false);
  }

  Future<void> _open(MiniGame game) async {
    final refreshed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => GameDetailScreen(
          game: game,
          repository: _repository,
          authRepository: _authRepository,
        ),
      ),
    );
    if (refreshed == true && mounted) await _load();
  }

  Future<void> _chooseProfile() async {
    await Navigator.of(context).pushNamed(AppRoutes.profilePicker);
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final visible = _visibleGames;
    final horizontalPadding = MediaQuery.sizeOf(context).width < 380
        ? 16.0
        : 22.0;
    final featured = _games.isEmpty
        ? null
        : _games.firstWhere(
            (game) => game.isFeatured,
            orElse: () => _games.first,
          );

    return Scaffold(
      backgroundColor: isDark ? _gameCoralDark : _gameCoral,
      body: SafeArea(
        child: Stack(
          children: [
            RefreshIndicator(
              color: _gameInk,
              backgroundColor: _gamePaper,
              onRefresh: _load,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      12,
                      horizontalPadding,
                      0,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _GamesHeader(profile: _activeProfile),
                          if (_loading || _games.isNotEmpty) ...[
                            const SizedBox(height: 17),
                            _GameSearch(
                              controller: _searchController,
                              onChanged: (value) =>
                                  setState(() => _query = value),
                            ),
                            const SizedBox(height: 15),
                            _GameFilters(
                              selected: _filter,
                              available: _games
                                  .map((game) => game.gameType)
                                  .toSet(),
                              onSelected: (value) =>
                                  setState(() => _filter = value),
                            ),
                            const SizedBox(height: 22),
                          ],
                          if (_games.isNotEmpty && _activeProfile != null) ...[
                            _GameRoomTicker(games: _games),
                            const SizedBox(height: 24),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (_error != null && _games.isNotEmpty)
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        0,
                        horizontalPadding,
                        18,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: _StaleGamesBanner(
                          message: _error!,
                          loading: _loading,
                          onRetry: _load,
                        ),
                      ),
                    ),
                  if (_loading && _games.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: _GamesLoading(),
                    )
                  else if (_activeProfile == null && _error == null)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _ChooseProfile(onChoose: _chooseProfile),
                    )
                  else if (_error != null && _games.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _GamesError(message: _error!, onRetry: _load),
                    )
                  else if (visible.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: _NoGamesFound(),
                    )
                  else ...[
                    if (_query.trim().isEmpty &&
                        _filter == null &&
                        featured != null)
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          horizontalPadding,
                          0,
                          horizontalPadding,
                          22,
                        ),
                        sliver: SliverToBoxAdapter(
                          child: _FeaturedQuest(
                            game: featured,
                            onTap: () => _open(featured),
                          ),
                        ),
                      ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        0,
                        horizontalPadding,
                        12,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: _GameSectionHeading(
                          title: _query.trim().isNotEmpty || _filter != null
                              ? 'Your matches'
                              : 'Pick your next mission',
                          count: visible.length,
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        0,
                        horizontalPadding,
                        116,
                      ),
                      sliver: SliverLayoutBuilder(
                        builder: (context, constraints) {
                          final columns = constraints.crossAxisExtent >= 900
                              ? 3
                              : constraints.crossAxisExtent >= 560
                              ? 2
                              : 1;
                          final textScale = MediaQuery.textScalerOf(
                            context,
                          ).scale(1).clamp(1, 3);
                          final cardExtent = columns == 1
                              ? 372 + ((textScale - 1) * 96)
                              : 400 + ((textScale - 1) * 76);
                          return SliverGrid.builder(
                            itemCount: visible.length,
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: columns,
                                  mainAxisSpacing: 16,
                                  crossAxisSpacing: 14,
                                  mainAxisExtent: cardExtent.toDouble(),
                                ),
                            itemBuilder: (context, index) => _GameCard(
                              game: visible[index],
                              onTap: () => _open(visible[index]),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: FloatingLiquidNav(
                selectedRoute: AppRoutes.games,
                activeProfile: _activeProfile,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GamesHeader extends StatelessWidget {
  const _GamesHeader({required this.profile});

  final KidProfile? profile;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? Colors.white : _gameInk;
    final copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          profile == null
              ? 'Ready to play?'
              : 'Ready, ${profile!.displayName}?',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            color: ink,
            fontSize: 35,
            fontWeight: FontWeight.w900,
            height: 0.98,
            letterSpacing: -1.25,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Pick a Bible adventure and keep growing.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: ink.withValues(alpha: 0.7),
            fontWeight: FontWeight.w600,
            height: 1.3,
          ),
        ),
      ],
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: copy),
        const SizedBox(width: 14),
        Container(
          key: const Key('games-header-icon'),
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            color: _gamePaper,
            border: Border.all(color: _gameInk, width: 2.1),
            borderRadius: BorderRadius.circular(17),
          ),
          child: const Icon(
            Icons.sports_esports_rounded,
            color: _gameInk,
            size: 29,
            semanticLabel: 'Games',
          ),
        ),
      ],
    );
  }
}

class _GameRoomTicker extends StatelessWidget {
  const _GameRoomTicker({required this.games});

  final List<MiniGame> games;

  @override
  Widget build(BuildContext context) {
    final started = games.where((game) => game.hasStarted).length;
    final stars = games.fold<int>(
      0,
      (total, game) => total + game.playerProgress.starsEarned,
    );
    final items = [
      _TickerItem(
        value: '${games.length}',
        label: games.length == 1 ? 'QUEST' : 'QUESTS',
        icon: Icons.sports_esports_rounded,
        color: const Color(0xFFB6F36B),
      ),
      _TickerItem(
        value: '$started',
        label: 'STARTED',
        icon: Icons.rocket_launch_rounded,
        color: const Color(0xFFFF8FBE),
      ),
      _TickerItem(
        value: '$stars',
        label: 'STARS',
        icon: Icons.star_rounded,
        color: const Color(0xFFFFCF2F),
      ),
    ];
    return Semantics(
      container: true,
      label:
          '${games.length} ${games.length == 1 ? 'quest' : 'quests'} available. $started started. $stars ${stars == 1 ? 'star' : 'stars'} earned.',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: _gamePaper,
            border: Border.all(color: _gameInk, width: 2.1),
            borderRadius: BorderRadius.circular(18),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final largeText =
                  MediaQuery.textScalerOf(context).scale(1) >= 1.55;
              if (largeText || constraints.maxWidth < 310) {
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var index = 0; index < items.length; index++) ...[
                        SizedBox(width: 128, child: items[index]),
                        if (index < items.length - 1)
                          const SizedBox(
                            height: 44,
                            child: VerticalDivider(
                              color: Color(0x332E2940),
                              thickness: 1.5,
                            ),
                          ),
                      ],
                    ],
                  ),
                );
              }
              return Row(
                children: [
                  for (var index = 0; index < items.length; index++) ...[
                    Expanded(child: items[index]),
                    if (index < items.length - 1)
                      const SizedBox(
                        height: 44,
                        child: VerticalDivider(
                          color: Color(0x332E2940),
                          thickness: 1.5,
                        ),
                      ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TickerItem extends StatelessWidget {
  const _TickerItem({
    required this.value,
    required this.label,
    required this.icon,
    required this.color,
  });

  final String value;
  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 62),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  style: const TextStyle(
                    color: _gameInk,
                    fontSize: 23,
                    height: 0.95,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _gameInk,
                    fontSize: 8.5,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.75,
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, color: _gameInk, size: 19),
          ),
        ],
      ),
    );
  }
}

class _GameSectionHeading extends StatelessWidget {
  const _GameSectionHeading({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? Colors.white : _gameInk;
    final titleWidget = Text(
      title,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        color: ink,
        fontSize: 23,
        height: 1,
        fontWeight: FontWeight.w900,
        letterSpacing: -0.65,
      ),
    );
    final countWidget = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: _gamePaper,
        border: Border.all(color: _gameInk, width: 1.8),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        '$count ${count == 1 ? 'GAME' : 'GAMES'}',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: _gameInk,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.7,
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (MediaQuery.textScalerOf(context).scale(1) >= 1.8 ||
            constraints.maxWidth < 300) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [titleWidget, const SizedBox(height: 4), countWidget],
          );
        }
        return Row(
          children: [
            Expanded(child: titleWidget),
            const SizedBox(width: 12),
            countWidget,
          ],
        );
      },
    );
  }
}

class _GameSearch extends StatelessWidget {
  const _GameSearch({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _gamePaper,
        border: Border.all(color: _gameInk, width: 2.1),
        borderRadius: BorderRadius.circular(18),
      ),
      child: TextField(
        key: const Key('game-search-field'),
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: const TextStyle(color: _gameInk, fontWeight: FontWeight.w700),
        cursorColor: _gameInk,
        decoration: InputDecoration(
          hintText: 'Search a hero or game…',
          hintStyle: TextStyle(
            color: _gameInk.withValues(alpha: 0.55),
            fontWeight: FontWeight.w600,
          ),
          prefixIcon: const Icon(Icons.search_rounded, color: _gameInk),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  key: const Key('clear-game-search'),
                  tooltip: 'Clear game search',
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                  icon: const Icon(Icons.close_rounded, color: _gameInk),
                ),
          filled: true,
          fillColor: Colors.transparent,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

class _GameFilters extends StatelessWidget {
  const _GameFilters({
    required this.selected,
    required this.available,
    required this.onSelected,
  });

  final GameType? selected;
  final Set<GameType> available;
  final ValueChanged<GameType?> onSelected;

  @override
  Widget build(BuildContext context) {
    final types = GameType.values.where(available.contains).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'CHOOSE YOUR POWER',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white70
                : _gameInk.withValues(alpha: 0.68),
            fontWeight: FontWeight.w900,
            letterSpacing: 1.35,
          ),
        ),
        const SizedBox(height: 9),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Padding(
            padding: const EdgeInsets.only(right: 6, bottom: 5),
            child: Row(
              children: [
                _GameFilterChip(
                  key: const Key('game-filter-all'),
                  label: 'All quests',
                  icon: Icons.bolt_rounded,
                  color: const Color(0xFFFFCF2F),
                  selected: selected == null,
                  onSelected: () => onSelected(null),
                ),
                for (final type in types) ...[
                  const SizedBox(width: 10),
                  _GameFilterChip(
                    key: Key('game-filter-${type.name}'),
                    label: type.label,
                    icon: gameTypeIcon(type),
                    color: _filterColor(type),
                    selected: selected == type,
                    onSelected: () => onSelected(type),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _GameFilterChip extends StatelessWidget {
  const _GameFilterChip({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12)),
        child: ChoiceChip(
          label: Text(label),
          avatar: Icon(icon, color: _gameInk, size: 17),
          selected: selected,
          showCheckmark: false,
          onSelected: (_) => onSelected(),
          selectedColor: color,
          backgroundColor: _gamePaper,
          side: const BorderSide(color: _gameInk, width: 1.8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          labelStyle: const TextStyle(
            color: _gameInk,
            fontWeight: FontWeight.w900,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 7),
          materialTapTargetSize: MaterialTapTargetSize.padded,
          visualDensity: VisualDensity.standard,
        ),
      ),
    );
  }
}

class _StaleGamesBanner extends StatelessWidget {
  const _StaleGamesBanner({
    required this.message,
    required this.loading,
    required this.onRetry,
  });

  final String message;
  final bool loading;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('stale-games-banner'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFE76E),
        border: Border.all(color: _gameInk, width: 2),
        borderRadius: BorderRadius.circular(17),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final messageWidget = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.cloud_off_rounded, color: _gameInk),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Showing the games already here. $message',
                  style: TextStyle(
                    color: _gameInk,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          );
          final retry = TextButton.icon(
            key: const Key('retry-stale-games'),
            onPressed: loading ? null : onRetry,
            icon: loading
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
            style: TextButton.styleFrom(
              foregroundColor: _gameInk,
              textStyle: const TextStyle(fontWeight: FontWeight.w900),
            ),
          );
          if (MediaQuery.textScalerOf(context).scale(1) >= 1.6 ||
              constraints.maxWidth < 430) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                messageWidget,
                Align(alignment: Alignment.centerRight, child: retry),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: messageWidget),
              const SizedBox(width: 8),
              retry,
            ],
          );
        },
      ),
    );
  }
}

class _FeaturedQuest extends StatelessWidget {
  const _FeaturedQuest({required this.game, required this.onTap});

  final MiniGame game;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = gameAccent(game);
    final foreground = _foregroundFor(accent);
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1, 3);
    return Semantics(
      button: true,
      label:
          'Today’s big quest. ${game.title}. ${game.typeLabel}. ${game.totalLevels} levels. ${game.hasStarted ? 'Continue' : 'Play now'}.',
      child: ExcludeSemantics(
        child: Container(
          height: 425 + ((textScale - 1) * 165),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: _gamePaper,
            borderRadius: BorderRadius.circular(22),
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: _gameInk, width: 2.1),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: Key('featured-game-${game.slug}'),
              onTap: onTap,
              child: Column(
                children: [
                  Expanded(
                    flex: textScale >= 1.7 ? 68 : 58,
                    child: ColoredBox(
                      color: accent,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(19, 18, 19, 17),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 9,
                                        vertical: 5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _gameInk,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const _FixedGameTextScale(
                                        child: Text(
                                          'TODAY’S BIG QUEST',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: 1,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const Spacer(),
                                    Container(
                                      width: 42,
                                      height: 42,
                                      decoration: BoxDecoration(
                                        color: _gamePaper,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: _gameInk,
                                          width: 2.2,
                                        ),
                                      ),
                                      child: Icon(
                                        gameTypeIcon(game.gameType),
                                        color: _gameInk,
                                        size: 22,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 13),
                                Text(
                                  game.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(
                                        color: foreground,
                                        fontSize: 31,
                                        fontWeight: FontWeight.w900,
                                        height: 0.98,
                                        letterSpacing: -1.25,
                                      ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  game.subtitle.trim().isNotEmpty
                                      ? game.subtitle
                                      : game.description,
                                  maxLines: textScale >= 1.7 ? 1 : 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        color: foreground.withValues(
                                          alpha: 0.78,
                                        ),
                                        fontWeight: FontWeight.w700,
                                        height: 1.27,
                                      ),
                                ),
                                const Spacer(),
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    final meta = Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.flag_rounded,
                                          color: foreground,
                                          size: 17,
                                        ),
                                        const SizedBox(width: 5),
                                        Flexible(
                                          child: Text(
                                            '${game.totalLevels} levels · ${game.duration}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: foreground,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ),
                                      ],
                                    );
                                    final action = Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 10,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _gameInk,
                                        borderRadius: BorderRadius.circular(11),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          _FixedGameTextScale(
                                            child: Text(
                                              game.hasStarted
                                                  ? 'CONTINUE'
                                                  : 'PLAY NOW',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 11,
                                                fontWeight: FontWeight.w900,
                                                letterSpacing: 0.7,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          const Icon(
                                            Icons.arrow_forward_rounded,
                                            color: Colors.white,
                                            size: 17,
                                          ),
                                        ],
                                      ),
                                    );
                                    if (textScale >= 1.55 ||
                                        constraints.maxWidth < 290) {
                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          meta,
                                          const SizedBox(height: 10),
                                          action,
                                        ],
                                      );
                                    }
                                    return Row(
                                      children: [
                                        Expanded(child: meta),
                                        const SizedBox(width: 10),
                                        action,
                                      ],
                                    );
                                  },
                                ),
                                if (game.hasStarted) ...[
                                  const SizedBox(height: 11),
                                  LinearProgressIndicator(
                                    value: game.playerProgress.percent,
                                    minHeight: 7,
                                    borderRadius: BorderRadius.circular(99),
                                    backgroundColor: foreground.withValues(
                                      alpha: 0.2,
                                    ),
                                    valueColor: AlwaysStoppedAnimation(
                                      foreground,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(height: 3, color: _gameInk),
                  Expanded(
                    flex: textScale >= 1.7 ? 32 : 42,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        GameCoverImage(game: game),
                        Positioned(
                          left: 15,
                          top: 14,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: _gamePaper,
                              border: Border.all(color: _gameInk, width: 2),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Text(
                              game.typeLabel.toUpperCase(),
                              style: const TextStyle(
                                color: _gameInk,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.9,
                              ),
                            ),
                          ),
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

class _GameCard extends StatelessWidget {
  const _GameCard({required this.game, required this.onTap});

  final MiniGame game;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = gameAccent(game);
    final progress = game.playerProgress;
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1, 3);
    final copy = game.subtitle.trim().isNotEmpty
        ? game.subtitle
        : game.description;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: _gamePaper,
        borderRadius: BorderRadius.circular(22),
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _gameInk, width: 2.1),
      ),
      child: Semantics(
        button: true,
        label:
            '${game.title}. ${game.typeLabel}. ${game.totalLevels} levels. ${progress.hasStarted ? '${progress.completedLevels} completed. Continue playing.' : 'Not started. Play now.'}',
        child: ExcludeSemantics(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: Key('game-card-${game.slug}'),
              onTap: onTap,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: textScale >= 1.7 ? 69 : 59,
                    child: Container(
                      color: _gamePaper,
                      padding: const EdgeInsets.fromLTRB(17, 16, 17, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: accent,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: _gameInk,
                                    width: 2.1,
                                  ),
                                ),
                                child: Icon(
                                  gameTypeIcon(game.gameType),
                                  color: _foregroundFor(accent),
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  game.typeLabel.toUpperCase(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: _gameInk,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ),
                              const Icon(
                                Icons.arrow_outward_rounded,
                                color: _gameInk,
                                size: 20,
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            game.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(
                                  color: _gameInk,
                                  fontSize: 25,
                                  height: 0.98,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.9,
                                ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            copy,
                            maxLines: textScale >= 1.7 ? 1 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: _gameInk.withValues(alpha: 0.72),
                                  fontWeight: FontWeight.w600,
                                  height: 1.28,
                                ),
                          ),
                          const Spacer(),
                          if (progress.hasStarted) ...[
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${progress.completedLevels}/${game.totalLevels} LEVELS',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: _gameInk,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.75,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Icon(
                                  Icons.star_rounded,
                                  color: _gameInk,
                                  size: 17,
                                ),
                                Text(
                                  '${progress.starsEarned}',
                                  style: const TextStyle(
                                    color: _gameInk,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: progress.percent,
                              minHeight: 7,
                              borderRadius: BorderRadius.circular(99),
                              backgroundColor: _gameInk.withValues(alpha: 0.1),
                              valueColor: AlwaysStoppedAnimation(accent),
                            ),
                          ] else
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${game.totalLevels} LEVELS · ${game.duration.toUpperCase()}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: _gameInk,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.65,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Text(
                                  'PLAY',
                                  style: TextStyle(
                                    color: _gameInk,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Icon(
                                  Icons.arrow_forward_rounded,
                                  color: _gameInk,
                                  size: 17,
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                  Container(height: 2.8, color: _gameInk),
                  Expanded(
                    flex: textScale >= 1.7 ? 31 : 41,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ColoredBox(
                          color: accent.withValues(alpha: 0.22),
                          child: GameCoverImage(game: game),
                        ),
                        Positioned(
                          right: 12,
                          bottom: 12,
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: accent,
                              shape: BoxShape.circle,
                              border: Border.all(color: _gameInk, width: 2),
                            ),
                            child: Icon(
                              progress.hasStarted
                                  ? Icons.play_arrow_rounded
                                  : Icons.arrow_outward_rounded,
                              color: _foregroundFor(accent),
                              size: 21,
                            ),
                          ),
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

class _GamesLoading extends StatelessWidget {
  const _GamesLoading();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 120),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 19),
          decoration: BoxDecoration(
            color: _gamePaper,
            border: Border.all(color: _gameInk, width: 2.1),
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(
                  color: _gameInk,
                  strokeWidth: 3,
                ),
              ),
              SizedBox(width: 13),
              Flexible(
                child: Text(
                  'Building your game room…',
                  style: TextStyle(
                    color: _gameInk,
                    fontWeight: FontWeight.w900,
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

class _ChooseProfile extends StatelessWidget {
  const _ChooseProfile({required this.onChoose});

  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) {
    return _CenteredState(
      emoji: '🧭',
      title: 'Choose your explorer',
      message: 'Game progress and earned stars belong to a kid profile.',
      actionLabel: 'Choose a profile',
      onAction: onChoose,
    );
  }
}

class _GamesError extends StatelessWidget {
  const _GamesError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _CenteredState(
      emoji: '🛠️',
      title: 'The game room needs a moment',
      message: message,
      actionLabel: 'Try again',
      onAction: onRetry,
    );
  }
}

class _NoGamesFound extends StatelessWidget {
  const _NoGamesFound();

  @override
  Widget build(BuildContext context) {
    return const _CenteredState(
      emoji: '🔎',
      title: 'No quests found',
      message: 'Try another word or choose a different game type.',
    );
  }
}

class _CenteredState extends StatelessWidget {
  const _CenteredState({
    required this.emoji,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String emoji;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 20, 28, 120),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 430),
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
          decoration: BoxDecoration(
            color: _gamePaper,
            border: Border.all(color: _gameInk, width: 2.1),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 82,
                height: 82,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFCF2F),
                  shape: BoxShape.circle,
                  border: Border.all(color: _gameInk, width: 2),
                ),
                child: Text(emoji, style: const TextStyle(fontSize: 45)),
              ),
              const SizedBox(height: 15),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: _gameInk,
                  fontWeight: FontWeight.w900,
                  height: 1.05,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _gameInk.withValues(alpha: 0.68),
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
              if (onAction != null && actionLabel != null) ...[
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: onAction,
                  style: FilledButton.styleFrom(
                    backgroundColor: _gameInk,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 13,
                    ),
                  ),
                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                  label: Text(actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

Color _foregroundFor(Color background) {
  return background.computeLuminance() > 0.179
      ? const Color(0xFF2E2940)
      : Colors.white;
}

Color _filterColor(GameType type) => switch (type) {
  GameType.quiz => const Color(0xFFFF8FBE),
  GameType.memory => const Color(0xFFB7A5FF),
  GameType.ordering => const Color(0xFFFFCF2F),
  GameType.matching => const Color(0xFF7DE2C1),
  GameType.maze => const Color(0xFF65CAFF),
  GameType.path => const Color(0xFFFF9D68),
  GameType.aim => const Color(0xFFB6F36B),
};

class _FixedGameTextScale extends StatelessWidget {
  const _FixedGameTextScale({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: const TextScaler.linear(1)),
      child: child,
    );
  }
}

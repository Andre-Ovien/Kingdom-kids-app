import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../../core/errors/app_exception.dart';
import '../../../shared/widgets/scoped_feature_page.dart';
import '../../../shared/audio/app_audio_scope.dart';
import '../../../shared/audio/app_sound_cue.dart';
import '../../../shared/widgets/floating_liquid_nav.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/kid_profile.dart';
import '../../auth/presentation/session_expiry_navigation.dart';
import '../data/game_repository.dart';
import '../domain/mini_game.dart';
import '../domain/game_availability.dart';
import 'games_course_widgets.dart';
import 'games_category_coverflow.dart';
import 'games_week_carousel.dart';
import 'game_detail_screen.dart';

const _gameInk = Color(0xFF151318);
const _gamePaper = Color(0xFFFFFDF7);
const _retiredGameSlugs = {
  'daniel-memory',
  'ark-animal-match',
  'moses-match',
  'red-sea-path',
  'creation-order',
  'wise-and-foolish-builders',
  'puzzle-red-sea',
  'puzzle-jonah',
  'puzzle-joseph-colorful-coat',
  'puzzle-good-samaritan',
  'puzzle-walls-of-jericho',
  'puzzle-ruth-and-naomi',
  'creation-quiz',
  'joseph-colorful-coat-quiz',
  'good-samaritan-quiz',
  'walls-of-jericho-quiz',
  'ruth-and-naomi-quiz',
};

class GamesScreen extends StatefulWidget {
  const GamesScreen({super.key, this.repository, this.authRepository});

  final GameRepository? repository;
  final AuthRepository? authRepository;

  @override
  State<GamesScreen> createState() => _GamesScreenState();
}

class _GamesScreenState extends State<GamesScreen> {
  final _searchController = TextEditingController();
  late FeatureScrollController _scrollController;
  Map<String, Object?>? _viewMemory;
  Object? _viewScope;
  bool _viewRestored = false;
  late final AuthRepository _authRepository;
  late final GameRepository _repository;
  List<MiniGame> _games = const [];
  KidProfile? _activeProfile;
  GameCategory? _filter;
  String _query = '';
  String? _error;
  bool _loading = true;
  bool _showSearch = false;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_viewRestored) return;
    _viewRestored = true;
    _viewMemory = FeatureViewMemory.maybeOf(context);
    _viewScope = FeatureViewMemory.scopeOf(context);
    final savedGames = _viewScope == null ? null : _viewMemory?['games'];
    if (savedGames is List<MiniGame>) {
      _games = savedGames;
      _activeProfile = _viewMemory?['profile'] as KidProfile?;
    }
    _query = _viewMemory?['query'] as String? ?? '';
    _searchController.text = _query;
    _filter = _viewMemory?['filter'] as GameCategory?;
    _showSearch = _viewMemory?['search'] as bool? ?? false;
    _scrollController = FeatureScrollController(
      _viewMemory,
      contentReady: savedGames is List<MiniGame>,
    );
  }

  @override
  void dispose() {
    _viewMemory?.addAll({
      'query': _query,
      'filter': _filter,
      'search': _showSearch,
      'scroll': _scrollController.rememberedOffset,
    });
    _searchController.dispose();
    _scrollController.dispose();
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
          // Retired and temporarily paused games must stay hidden when an
          // older backend or cached catalogue still returns them. Filter before
          // featured quests, category chips, search results, and room totals.
          _games = games
              .where(
                (game) =>
                    game.gameType != GameType.memory &&
                    !_retiredGameSlugs.contains(game.slug) &&
                    !pausedActionGameSlugs.contains(game.slug),
              )
              .toList(growable: false);
          if (_filter != null &&
              !_games.any((game) => game.category == _filter)) {
            _filter = null;
          }
        });
        if (_viewScope != null) {
          _viewMemory?.addAll({'games': _games, 'profile': profile});
        }
        _scrollController.restoreAfterLoad();
      }
    } on AppException catch (error) {
      if (mounted && returnToSignInIfSessionExpired(context, error)) return;
      if (mounted) setState(() => _error = error.userMessage);
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

  Future<void> _refresh() async {
    _authRepository.invalidateFeatureReads();
    await _load();
  }

  List<MiniGame> get _visibleGames {
    final query = _query.trim().toLowerCase();
    return _games
        .where((game) {
          final matchesType = _filter == null || game.category == _filter;
          final matchesQuery =
              query.isEmpty ||
              game.title.toLowerCase().contains(query) ||
              game.subtitle.toLowerCase().contains(query) ||
              game.description.toLowerCase().contains(query) ||
              game.typeLabel.toLowerCase().contains(query) ||
              game.category.label.toLowerCase().contains(query);
          return matchesType && matchesQuery;
        })
        .toList(growable: false);
  }

  Future<void> _open(MiniGame game) async {
    final wasComplete = game.playerProgress.isComplete;
    final profileId = _activeProfile?.id;
    final refreshed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        settings: const RouteSettings(name: AppRoutes.gameDetail),
        builder: (_) {
          final detail = GameDetailScreen(
            game: game,
            repository: _repository,
            authRepository: _authRepository,
          );
          return _viewScope == null
              ? detail
              : ScopedFeaturePage(
                  route: '${AppRoutes.gameDetail}/${game.slug}',
                  identityBound: true,
                  authRepository: _authRepository,
                  child: detail,
                );
        },
      ),
    );
    if (refreshed != true || !mounted) return;
    await _load();
    if (!mounted ||
        wasComplete ||
        _error != null ||
        profileId != _activeProfile?.id ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final newlyComplete = _games.any(
      (updated) =>
          updated.slug == game.slug && updated.playerProgress.isComplete,
    );
    if (newlyComplete) {
      // Gameplay keeps its own audio; celebrate only after returning to Games
      // and confirming the full quest's saved completion for the same child.
      AppAudioScope.maybeOf(context)?.playEffect(AppSoundCue.success);
    }
  }

  Future<void> _chooseProfile() async {
    await Navigator.of(context).pushNamed(AppRoutes.profilePicker);
    if (mounted) await _load();
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _query = '';
      _filter = null;
    });
  }

  Future<void> _chooseCategory() async {
    final categories = GameCategory.values
        .where((category) => _games.any((game) => game.category == category))
        .toList(growable: false);
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => SafeArea(
        child: Container(
          margin: const EdgeInsets.all(12),
          constraints: const BoxConstraints(maxHeight: 520),
          decoration: BoxDecoration(
            color: _gamePaper,
            border: Border.all(color: _gameInk, width: 2),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Material(
            color: Colors.transparent,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
                  child: Text(
                    'PICK A GAME CATEGORY',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: _gameInk,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.4,
                    ),
                  ),
                ),
                for (final category in <GameCategory?>[null, ...categories])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: ListTile(
                      key: Key('game-filter-${category?.name ?? 'all'}'),
                      selected: category == _filter,
                      selectedColor: _gameInk,
                      selectedTileColor: const Color(0xFFFFD743),
                      shape: RoundedRectangleBorder(
                        side: category == _filter
                            ? const BorderSide(color: _gameInk, width: 2)
                            : BorderSide.none,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      title: Text(
                        category?.label ?? 'All quests',
                        style: const TextStyle(
                          color: _gameInk,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      trailing: category == _filter
                          ? const Icon(Icons.check_circle, color: _gameInk)
                          : null,
                      onTap: () =>
                          Navigator.of(context).pop(category?.name ?? 'all'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _filter = selected == 'all' ? null : GameCategory.values.byName(selected);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: theme.colorScheme.copyWith(
          brightness: Brightness.light,
          surface: Colors.white,
          onSurface: _gameInk,
          primary: _gameInk,
          onPrimary: Colors.white,
        ),
        textTheme: theme.textTheme.apply(
          bodyColor: _gameInk,
          displayColor: _gameInk,
        ),
        iconTheme: theme.iconTheme.copyWith(color: _gameInk),
      ),
      child: Builder(builder: _buildGameRoom),
    );
  }

  Widget _buildGameRoom(BuildContext context) {
    final visible = _visibleGames;
    final featured = _games.isEmpty
        ? null
        : _games.firstWhere(
            (game) => game.isFeatured,
            orElse: () => _games.first,
          );
    final categories = _games.map((game) => game.category).toSet();
    return Scaffold(
      backgroundColor: featured == null
          ? gamesCourseOrange
          : const Color(0xFF17191D),
      body: Stack(
        children: [
          RefreshIndicator(
            color: _gameInk,
            onRefresh: _refresh,
            child: CustomScrollView(
              key: const Key('games-scroll'),
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: GamesWeekCarousel(
                    games: _games,
                    loading: _loading,
                    scopeId:
                        '${_activeProfile?.parentId ?? ''}:${_activeProfile?.id ?? ''}',
                    scrollController: _scrollController,
                    onOpen: _open,
                  ),
                ),
                DecoratedSliver(
                  key: const Key('games-courses-content-sheet'),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(36),
                    ),
                  ),
                  sliver: SliverMainAxisGroup(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(18, 19, 18, 16),
                        sliver: SliverToBoxAdapter(
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: GamesCourseCategories(
                                      available: categories,
                                      selected: _filter,
                                      onSelected: (value) =>
                                          setState(() => _filter = value),
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  IconButton(
                                    key: const Key('game-search-toggle'),
                                    tooltip: 'Search games',
                                    onPressed: () => setState(
                                      () => _showSearch = !_showSearch,
                                    ),
                                    icon: const Icon(
                                      Icons.search_rounded,
                                      size: 22,
                                    ),
                                  ),
                                  IconButton(
                                    key: const Key('game-filter-button'),
                                    tooltip: 'Filter game categories',
                                    onPressed: _games.isEmpty
                                        ? null
                                        : _chooseCategory,
                                    icon: const Icon(
                                      Icons.filter_list_rounded,
                                      size: 22,
                                    ),
                                  ),
                                ],
                              ),
                              if (_showSearch) ...[
                                const SizedBox(height: 12),
                                GamesCourseSearch(
                                  controller: _searchController,
                                  onChanged: (value) =>
                                      setState(() => _query = value),
                                ),
                              ],
                              if (_games.isNotEmpty) ...[
                                const SizedBox(height: 16),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        _query.trim().isNotEmpty ||
                                                _filter != null
                                            ? 'Your matches'
                                            : 'All games',
                                        style: const TextStyle(
                                          color: Color(0xFF8A8793),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '${visible.length} ${visible.length == 1 ? 'GAME' : 'GAMES'}',
                                      style: const TextStyle(
                                        color: Color(0xFF8A8793),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.8,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      if (_error != null && _games.isNotEmpty)
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                          sliver: SliverToBoxAdapter(
                            child: _StaleGamesBanner(
                              message: _error!,
                              loading: _loading,
                              onRetry: _load,
                            ),
                          ),
                        ),
                      if (_loading && _games.isEmpty)
                        const _GamesStateSliver(child: _GamesLoading())
                      else if (_activeProfile == null && _error == null)
                        _GamesStateSliver(
                          child: _ChooseProfile(onChoose: _chooseProfile),
                        )
                      else if (_error != null && _games.isEmpty)
                        _GamesStateSliver(
                          child: _GamesError(message: _error!, onRetry: _load),
                        )
                      else if (_games.isEmpty)
                        _GamesStateSliver(
                          child: _GamesComingSoon(onRefresh: _load),
                        )
                      else if (visible.isEmpty)
                        _GamesStateSliver(
                          child: _NoGamesFound(onReset: _clearFilters),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                          sliver: SliverList.list(
                            children: [
                              for (final category in const [
                                GameCategory.puzzle,
                                GameCategory.quiz,
                                GameCategory.matching,
                                GameCategory.game,
                              ])
                                if (visible.any(
                                  (game) => game.category == category,
                                ))
                                  GamesCategoryCoverflow(
                                    key: ValueKey(
                                      'games-section-${category.name}-${_activeProfile?.id ?? ''}',
                                    ),
                                    category: category,
                                    games: visible
                                        .where(
                                          (game) => game.category == category,
                                        )
                                        .toList(growable: false),
                                    scopeId:
                                        '${_activeProfile?.parentId ?? ''}:${_activeProfile?.id ?? ''}',
                                    enabled: !_loading,
                                    onOpen: _open,
                                  ),
                            ],
                          ),
                        ),
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: 128 + MediaQuery.paddingOf(context).bottom,
                        ),
                      ),
                    ],
                  ),
                ),
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
    );
  }
}

class _GamesStateSliver extends StatelessWidget {
  const _GamesStateSliver({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: MediaQuery.sizeOf(context).height * 0.6,
      ),
      child: child,
    ),
  );
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
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF2DF),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'SHOWING SAVED QUESTS',
          style: TextStyle(color: _gameInk, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(message, style: const TextStyle(color: _gameInk)),
        TextButton.icon(
          onPressed: loading ? null : onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Try again'),
        ),
      ],
    ),
  );
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

class _GamesComingSoon extends StatelessWidget {
  const _GamesComingSoon({required this.onRefresh});

  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return _CenteredState(
      emoji: '🎲',
      title: 'New quests are being prepared!',
      message:
          'The next game adventures are almost ready. Check back soon or refresh now.',
      actionLabel: 'Refresh game room',
      actionKey: const Key('games-refresh-button'),
      onAction: onRefresh,
    );
  }
}

class _NoGamesFound extends StatelessWidget {
  const _NoGamesFound({required this.onReset});

  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return _CenteredState(
      emoji: '🔎',
      title: 'No quests found',
      message: 'Try another word or choose a different game type.',
      actionLabel: 'Show all quests',
      actionKey: const Key('games-reset-button'),
      onAction: onReset,
    );
  }
}

class _CenteredState extends StatelessWidget {
  const _CenteredState({
    required this.emoji,
    required this.title,
    required this.message,
    this.actionLabel,
    this.actionKey,
    this.onAction,
  });

  final String emoji;
  final String title;
  final String message;
  final String? actionLabel;
  final Key? actionKey;
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
                  key: actionKey,
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

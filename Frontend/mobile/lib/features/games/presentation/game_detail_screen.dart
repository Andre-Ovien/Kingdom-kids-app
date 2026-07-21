import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../../core/errors/app_exception.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/kid_profile.dart';
import '../../auth/presentation/kid_profile_avatar.dart';
import '../../auth/presentation/session_expiry_navigation.dart';
import '../data/game_repository.dart';
import '../domain/mini_game.dart';
import 'game_cover_image.dart';
import 'game_play_screen.dart';

class GameDetailScreen extends StatefulWidget {
  const GameDetailScreen({
    required this.game,
    super.key,
    this.repository,
    this.authRepository,
  });

  final MiniGame game;
  final GameRepository? repository;
  final AuthRepository? authRepository;

  @override
  State<GameDetailScreen> createState() => _GameDetailScreenState();
}

class _GameDetailScreenState extends State<GameDetailScreen> {
  late MiniGame _game;
  late final AuthRepository _authRepository;
  late final GameRepository _repository;
  KidProfile? _profile;
  String? _error;
  bool _loading = true;
  bool _played = false;
  bool _allowPop = false;

  @override
  void initState() {
    super.initState();
    _game = widget.game;
    _authRepository = widget.authRepository ?? AuthRepository();
    _repository =
        widget.repository ??
        RemoteGameRepository(authRepository: _authRepository);
    _load();
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
        setState(() => _profile = null);
        return;
      }
      final game = await _repository.fetchGame(
        _game.slug,
        profileId: profile.id,
      );
      if (mounted) {
        setState(() {
          _profile = profile;
          _game = game;
        });
      }
    } on AppException catch (error) {
      if (mounted && returnToSignInIfSessionExpired(context, error)) return;
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'We could not prepare this quest. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _play() async {
    final profile = _profile;
    if (profile == null || _game.levels.isEmpty || _loading) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => GamePlayScreen(
          game: _game,
          profile: profile,
          repository: _repository,
          authRepository: _authRepository,
        ),
      ),
    );
    if (changed == true && mounted) {
      _played = true;
      await _load();
    }
  }

  Future<void> _chooseProfile() async {
    await Navigator.of(context).pushNamed(AppRoutes.profilePicker);
    if (mounted) await _load();
  }

  void _close() {
    if (_allowPop) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(_played);
    });
  }

  @override
  Widget build(BuildContext context) {
    final progress = _game.playerProgress;
    final hasPlayableDetail = _game.levels.isNotEmpty;
    final horizontalPadding = MediaQuery.sizeOf(context).width < 380
        ? 16.0
        : 22.0;

    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: SafeArea(
          child: RefreshIndicator(
            color: const Color(0xFFFF7043),
            onRefresh: _load,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    10,
                    horizontalPadding,
                    38,
                  ),
                  sliver: SliverList.list(
                    children: [
                      _DetailTopBar(onBack: _close, profile: _profile),
                      const SizedBox(height: 16),
                      _QuestHero(game: _game),
                      const SizedBox(height: 22),
                      Text(
                        _game.title,
                        key: const Key('game-detail-title'),
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              fontWeight: FontWeight.w900,
                              height: 1.06,
                            ),
                      ),
                      if (_game.subtitle.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          _game.subtitle,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: _accentTextColor(
                                  context,
                                  gameAccent(_game),
                                ),
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      _QuestFacts(game: _game),
                      const SizedBox(height: 18),
                      Text(
                        _game.description,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          height: 1.48,
                        ),
                      ),
                      if (_loading) ...[
                        const SizedBox(height: 19),
                        const LinearProgressIndicator(
                          key: Key('game-detail-loading'),
                          minHeight: 3,
                        ),
                      ],
                      if (_profile == null && !_loading && _error == null) ...[
                        const SizedBox(height: 20),
                        _DetailNotice(
                          icon: Icons.person_search_rounded,
                          message:
                              'Choose a kid profile so progress and stars have a home.',
                          actionLabel: 'Choose profile',
                          onAction: _chooseProfile,
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 20),
                        _DetailNotice(
                          icon: Icons.cloud_off_rounded,
                          message: _error!,
                          actionLabel: 'Try again',
                          onAction: _load,
                        ),
                      ],
                      if (progress.hasStarted) ...[
                        const SizedBox(height: 22),
                        _ProgressCard(game: _game),
                      ],
                      const SizedBox(height: 24),
                      if (hasPlayableDetail) ...[
                        Text(
                          'Your adventure map',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 12),
                        _LevelMap(game: _game),
                        const SizedBox(height: 24),
                      ] else if (!_loading && _error == null) ...[
                        const _NoLevelsNotice(),
                        const SizedBox(height: 20),
                      ],
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          key: const Key('play-game-button'),
                          style: FilledButton.styleFrom(
                            backgroundColor: gameAccent(_game),
                            foregroundColor: _buttonForeground(
                              gameAccent(_game),
                            ),
                            minimumSize: const Size.fromHeight(56),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                          ),
                          onPressed:
                              _profile != null && hasPlayableDetail && !_loading
                              ? _play
                              : null,
                          icon: Icon(
                            progress.isComplete
                                ? Icons.replay_rounded
                                : Icons.play_arrow_rounded,
                            size: 27,
                          ),
                          label: Text(
                            progress.isComplete
                                ? 'Replay quest'
                                : progress.hasStarted
                                ? 'Continue level ${progress.currentLevel}'
                                : 'Start the adventure',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
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
    );
  }
}

class _DetailTopBar extends StatelessWidget {
  const _DetailTopBar({required this.onBack, required this.profile});

  final VoidCallback onBack;
  final KidProfile? profile;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final largeText = MediaQuery.textScalerOf(context).scale(1) >= 2.1;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            IconButton.filledTonal(
              key: const Key('game-detail-back'),
              tooltip: 'Back to games',
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Quest details',
                maxLines: largeText ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
              ),
            ),
            const SizedBox(width: 8),
            if (profile == null)
              const SizedBox(width: 48)
            else
              KidProfileAvatar(profile: profile!, size: largeText ? 40 : 46),
          ],
        );
      },
    );
  }
}

class _QuestHero extends StatelessWidget {
  const _QuestHero({required this.game});

  final MiniGame game;

  @override
  Widget build(BuildContext context) {
    final accent = gameAccent(game);
    return AspectRatio(
      aspectRatio: 16 / 10,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(25),
        child: Stack(
          fit: StackFit.expand,
          children: [
            GameCoverImage(game: game),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0xA8242030)],
                ),
              ),
            ),
            Center(
              child: Container(
                width: 78,
                height: 78,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 20),
                  ],
                ),
                child: Icon(
                  gameTypeIcon(game.gameType),
                  color: _buttonForeground(accent),
                  size: 39,
                ),
              ),
            ),
            Positioned(
              left: 13,
              right: 13,
              bottom: 13,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    game.typeLabel,
                    style: TextStyle(
                      color: _buttonForeground(accent),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuestFacts extends StatelessWidget {
  const _QuestFacts({required this.game});

  final MiniGame game;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 9,
      runSpacing: 9,
      children: [
        _Fact(icon: Icons.bolt_rounded, label: game.difficulty),
        _Fact(icon: Icons.schedule_rounded, label: game.duration),
        _Fact(icon: Icons.flag_rounded, label: '${game.totalLevels} levels'),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 5,
        runSpacing: 2,
        children: [
          Icon(icon, size: 17),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.game});

  final MiniGame game;

  @override
  Widget build(BuildContext context) {
    final progress = game.playerProgress;
    final accent = gameAccent(game);
    return Container(
      key: const Key('game-progress-card'),
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(21),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final large =
                  MediaQuery.textScalerOf(context).scale(1) >= 1.7 ||
                  constraints.maxWidth < 300;
              final title = Row(
                children: [
                  Icon(Icons.explore_rounded, color: accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      progress.isComplete
                          ? 'Adventure complete'
                          : 'Level ${progress.currentLevel} is next',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              );
              final percent = Text(
                '${(progress.percent * 100).round()}%',
                style: TextStyle(
                  color: _accentTextColor(context, accent),
                  fontWeight: FontWeight.w900,
                ),
              );
              if (large) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    title,
                    const SizedBox(height: 6),
                    Align(alignment: Alignment.centerRight, child: percent),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: title),
                  const SizedBox(width: 8),
                  percent,
                ],
              );
            },
          ),
          const SizedBox(height: 11),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress.percent,
              minHeight: 8,
              backgroundColor: accent.withValues(alpha: 0.14),
              valueColor: AlwaysStoppedAnimation(accent),
            ),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final completed = Text(
                '${progress.completedLevels} levels completed',
              );
              final stars = Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 3,
                runSpacing: 2,
                children: [
                  const Icon(
                    Icons.star_rounded,
                    color: Color(0xFFFFA000),
                    size: 19,
                  ),
                  Text(
                    '${progress.starsEarned}/${progress.maxStars} stars',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ],
              );
              if (MediaQuery.textScalerOf(context).scale(1) >= 1.6 ||
                  constraints.maxWidth < 300) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [completed, const SizedBox(height: 5), stars],
                );
              }
              return Row(
                children: [
                  Expanded(child: completed),
                  const SizedBox(width: 8),
                  stars,
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _LevelMap extends StatelessWidget {
  const _LevelMap({required this.game});

  final MiniGame game;

  @override
  Widget build(BuildContext context) {
    final progress = game.playerProgress;
    final accent = gameAccent(game);
    return Column(
      children: [
        for (var index = 0; index < game.levels.length; index++)
          _LevelMapRow(
            level: game.levels[index],
            isLast: index == game.levels.length - 1,
            completed:
                game.levels[index].number <= progress.highestCompletedLevel,
            current:
                !progress.isComplete &&
                game.levels[index].number == progress.currentLevel,
            accent: accent,
          ),
      ],
    );
  }
}

class _LevelMapRow extends StatelessWidget {
  const _LevelMapRow({
    required this.level,
    required this.isLast,
    required this.completed,
    required this.current,
    required this.accent,
  });

  final GameLevel level;
  final bool isLast;
  final bool completed;
  final bool current;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 42,
            child: Column(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: completed || current
                        ? accent
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    completed ? Icons.check_rounded : Icons.flag_rounded,
                    size: 19,
                    color: completed || current
                        ? _buttonForeground(accent)
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 3,
                      color: completed
                          ? accent.withValues(alpha: 0.6)
                          : Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 17),
              child: Container(
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color: current
                      ? accent.withValues(alpha: 0.1)
                      : Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                  border: current
                      ? Border.all(color: accent.withValues(alpha: 0.35))
                      : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Level ${level.number} • ${level.title}',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (level.instructions.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        level.instructions,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailNotice extends StatelessWidget {
  const _DetailNotice({
    required this.icon,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(18),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final messageRow = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon),
              const SizedBox(width: 11),
              Expanded(child: Text(message)),
            ],
          );
          final action = TextButton(
            onPressed: onAction,
            child: Text(actionLabel),
          );
          if (MediaQuery.textScalerOf(context).scale(1) >= 1.6 ||
              constraints.maxWidth < 400) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                messageRow,
                Align(alignment: Alignment.centerRight, child: action),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: messageRow),
              const SizedBox(width: 8),
              action,
            ],
          );
        },
      ),
    );
  }
}

class _NoLevelsNotice extends StatelessWidget {
  const _NoLevelsNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
      ),
      child: const Row(
        children: [
          Text('🛠️', style: TextStyle(fontSize: 30)),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Playable levels are still being prepared for this quest.',
            ),
          ),
        ],
      ),
    );
  }
}

Color _buttonForeground(Color background) {
  return background.computeLuminance() > 0.179
      ? const Color(0xFF2E2940)
      : Colors.white;
}

Color _accentTextColor(BuildContext context, Color accent) {
  final surface = Theme.of(context).scaffoldBackgroundColor;
  final lighter = mathMax(
    accent.computeLuminance(),
    surface.computeLuminance(),
  );
  final darker = mathMin(accent.computeLuminance(), surface.computeLuminance());
  final contrast = (lighter + 0.05) / (darker + 0.05);
  return contrast >= 4.5 ? accent : _buttonForeground(surface);
}

double mathMax(double left, double right) => left > right ? left : right;
double mathMin(double left, double right) => left < right ? left : right;

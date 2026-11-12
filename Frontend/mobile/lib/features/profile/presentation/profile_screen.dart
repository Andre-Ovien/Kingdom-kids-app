import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../../core/errors/app_exception.dart';
import '../../../shared/widgets/floating_liquid_nav.dart';
import '../../../shared/widgets/liquid_glass.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/kid_profile.dart';
import '../../auth/presentation/adult_gate.dart';
import '../../auth/presentation/kid_profile_avatar.dart';
import '../../auth/presentation/session_expiry_navigation.dart';
import '../data/profile_repository.dart';
import '../domain/progress_summary.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, this.authRepository, this.profileRepository});

  final AuthRepository? authRepository;
  final ProfileRepository? profileRepository;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final AuthRepository _authRepository;
  late final ProfileRepository _profileRepository;

  KidProfile? _activeProfile;
  ProfileProgressSummary? _summary;
  List<KidProfile> _profiles = const [];
  String? _errorMessage;
  bool _isLoading = true;
  bool _isSwitching = false;
  bool _requiresSignIn = false;

  @override
  void initState() {
    super.initState();
    _authRepository = widget.authRepository ?? AuthRepository();
    _profileRepository =
        widget.profileRepository ??
        RemoteProfileRepository(authRepository: _authRepository);
    _loadProfile();
  }

  Future<void> _loadProfile({bool isRefresh = false}) async {
    if (!isRefresh) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
        _requiresSignIn = false;
      });
    }

    try {
      final existingSession = await _authRepository.restoreSession();
      if (existingSession == null) {
        if (mounted) {
          setState(() {
            _activeProfile = null;
            _summary = null;
            _profiles = const [];
            _requiresSignIn = true;
            _errorMessage = null;
          });
        }
        return;
      }

      final profile = await _authRepository.refreshCurrentKid();
      final refreshedSession = await _authRepository.restoreSession();
      final profiles = refreshedSession?.profiles ?? const <KidProfile>[];
      if (profile == null) {
        if (mounted) {
          setState(() {
            _activeProfile = null;
            _summary = null;
            _profiles = profiles;
            _requiresSignIn = false;
            _errorMessage = null;
          });
        }
        return;
      }

      final summary = await _profileRepository.fetchSummary(
        profileId: profile.id,
      );
      if (!mounted) return;
      setState(() {
        _activeProfile = profile;
        _summary = summary;
        _profiles = profiles;
        _requiresSignIn = false;
        _errorMessage = null;
      });
    } on AppException catch (error) {
      if (mounted && returnToSignInIfSessionExpired(context, error)) return;
      if (!mounted) return;
      if (isRefresh && _summary != null) {
        _showMessage(error.userMessage);
      } else {
        setState(() => _errorMessage = error.userMessage);
      }
    } catch (_) {
      if (!mounted) return;
      const message = 'We could not load this adventure yet. Please try again.';
      if (isRefresh && _summary != null) {
        _showMessage(message);
      } else {
        setState(() => _errorMessage = message);
      }
    } finally {
      if (mounted && !isRefresh) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _openProfileChoice() async {
    if (_isSwitching) return;
    setState(() => _isSwitching = true);
    try {
      final profiles = await _authRepository.fetchKidProfiles();
      if (!mounted) return;
      setState(() => _profiles = profiles);
      final route = profiles.isEmpty
          ? AppRoutes.kidProfileSetup
          : AppRoutes.profilePicker;
      await Navigator.of(context).pushNamed(route, arguments: profiles);
    } on AppException catch (error) {
      if (mounted && returnToSignInIfSessionExpired(context, error)) return;
      if (mounted) _showMessage(error.userMessage);
    } catch (_) {
      if (mounted) {
        _showMessage('We could not open your family profiles. Try again.');
      }
    } finally {
      if (mounted) setState(() => _isSwitching = false);
    }
  }

  Future<void> _editProfile() async {
    final profile = _activeProfile;
    if (profile == null) return;
    final authorized = await showAdultGate(
      context: context,
      repository: _authRepository,
      title: 'Edit child profile',
      reason: 'Enter the parent password before changing this profile.',
    );
    if (!mounted || !authorized) return;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _EditProfileSheet(
        profile: profile,
        onSave: (displayName, avatarKey) =>
            _saveProfile(profile.id, displayName, avatarKey),
      ),
    );
    if (saved == true && mounted) {
      _showMessage('Profile updated! Looking great.');
    }
  }

  Future<String?> _saveProfile(
    String profileId,
    String displayName,
    String avatarKey,
  ) async {
    try {
      final updated = await _authRepository.updateKidProfile(
        profileId: profileId,
        displayName: displayName,
        avatarKey: avatarKey,
      );
      if (mounted) {
        setState(() {
          _activeProfile = updated;
          _profiles = _profiles
              .map((profile) => profile.id == updated.id ? updated : profile)
              .toList(growable: false);
        });
      }
      return null;
    } on AppException catch (error) {
      if (mounted && returnToSignInIfSessionExpired(context, error)) {
        return null;
      }
      return error.userMessage;
    } catch (_) {
      return 'We could not save those changes. Please try again.';
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _goToSignIn() {
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Stack(
          children: [
            const Positioned.fill(child: _ProfileBackdrop()),
            Positioned.fill(
              child: RefreshIndicator(
                color: const Color(0xFF2D7D6F),
                onRefresh: () => _loadProfile(isRefresh: true),
                child: CustomScrollView(
                  key: const Key('profile-scroll'),
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 122),
                      sliver: SliverList.list(
                        children: [
                          _ProfileTopBar(profile: _activeProfile),
                          const SizedBox(height: 22),
                          if (_isLoading)
                            const _ProfileLoadingState()
                          else if (_requiresSignIn)
                            _ProfileSignedOutState(onSignIn: _goToSignIn)
                          else if (_errorMessage != null && _summary == null)
                            _ProfileErrorState(
                              message: _errorMessage!,
                              onRetry: _loadProfile,
                            )
                          else if (_activeProfile == null)
                            _NoActiveProfileState(
                              hasProfiles: _profiles.isNotEmpty,
                              isOpening: _isSwitching,
                              onOpen: _openProfileChoice,
                            )
                          else if (_summary != null)
                            _ProfileContent(
                              summary: _summary!,
                              isSwitching: _isSwitching,
                              onEdit: _editProfile,
                              onSwitch: _openProfileChoice,
                            )
                          else
                            _ProfileErrorState(
                              message:
                                  'This profile did not include any progress yet.',
                              onRetry: _loadProfile,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: FloatingLiquidNav(
                selectedRoute: AppRoutes.profile,
                activeProfile: _activeProfile,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileTopBar extends StatelessWidget {
  const _ProfileTopBar({this.profile});

  final KidProfile? profile;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (profile != null) ...[
          KidProfileAvatar(profile: profile!, size: 50),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                profile == null ? 'My adventure' : 'Hello,',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: _mutedText(context),
                  fontSize: profile == null ? 13.5 : 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                profile?.displayName ?? 'Progress dashboard',
                key: const Key('profile-display-name'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontSize: 23,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.6,
                ),
              ),
            ],
          ),
        ),
        LiquidGlass(
          borderRadius: 28,
          opacity: 0.02,
          blur: 28,
          borderOpacity: 0.38,
          child: SizedBox.square(
            dimension: 50,
            child: IconButton(
              key: const Key('profile-settings'),
              tooltip: 'Parent settings',
              onPressed: () =>
                  Navigator.of(context).pushNamed(AppRoutes.parentalControls),
              icon: Icon(
                Icons.settings_rounded,
                semanticLabel: 'Parent settings',
                color: _primaryText(context),
                size: 23,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ProfileContent extends StatelessWidget {
  const _ProfileContent({
    required this.summary,
    required this.isSwitching,
    required this.onEdit,
    required this.onSwitch,
  });

  final ProfileProgressSummary summary;
  final bool isSwitching;
  final VoidCallback onEdit;
  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    ProfileBadge? nextBadge;
    for (final badge in summary.badges) {
      if (!badge.earned) {
        nextBadge = badge;
        break;
      }
    }
    nextBadge ??= summary.badges.isEmpty ? null : summary.badges.last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ProfileHero(
          level: summary.level,
          nextBadge: nextBadge,
          isSwitching: isSwitching,
          onEdit: onEdit,
          onSwitch: onSwitch,
        ),
        const SizedBox(height: 24),
        _ActivityCard(
          streak: summary.activityStreak,
          weeks: summary.weeklyActivity,
          lastActivityAt: summary.lastActivityAt,
        ),
      ],
    );
  }
}

class _ProfileHero extends StatelessWidget {
  const _ProfileHero({
    required this.level,
    required this.nextBadge,
    required this.isSwitching,
    required this.onEdit,
    required this.onSwitch,
  });

  final ProfileLevel level;
  final ProfileBadge? nextBadge;
  final bool isSwitching;
  final VoidCallback onEdit;
  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
    final levelFloor = math.max(0, (level.number - 1) * 300);
    final levelTarget = math.max(1, level.nextLevelXp - levelFloor);
    final levelXp = (level.xp - levelFloor).clamp(0, levelTarget);
    final foreground = isDark ? Colors.white : const Color(0xFF171421);
    final muted = foreground.withValues(alpha: 0.7);
    final challengeComplete = nextBadge?.earned ?? false;
    return Container(
      key: const Key('profile-live-hero'),
      padding: const EdgeInsets.all(22),
      clipBehavior: Clip.antiAlias,
      decoration: ShapeDecoration(
        color: isDark ? const Color(0xFF514582) : const Color(0xFFB7A5FF),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(46),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: foreground,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      challengeComplete ? 'QUEST BOARD' : 'NEXT QUEST',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: isDark ? const Color(0xFF514582) : Colors.white,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: const Key('profile-edit'),
                    tooltip: 'Edit profile',
                    onPressed: onEdit,
                    style: IconButton.styleFrom(
                      backgroundColor: foreground,
                      foregroundColor: isDark
                          ? const Color(0xFF514582)
                          : Colors.white,
                    ),
                    icon: const Icon(
                      Icons.edit_rounded,
                      semanticLabel: 'Edit profile',
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    key: const Key('profile-switch'),
                    tooltip: 'Switch child',
                    onPressed: isSwitching ? null : onSwitch,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.3),
                      foregroundColor: foreground,
                      disabledBackgroundColor: Colors.white.withValues(
                        alpha: 0.14,
                      ),
                    ),
                    icon: isSwitching
                        ? SizedBox.square(
                            dimension: 17,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: foreground,
                            ),
                          )
                        : const Icon(
                            Icons.switch_account_rounded,
                            semanticLabel: 'Switch child',
                            size: 19,
                          ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final stacked = largeText || constraints.maxWidth < 280;
              final heading = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    nextBadge?.title ?? 'Begin the adventure',
                    maxLines: largeText ? null : 2,
                    overflow: largeText
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: foreground,
                      fontSize: 27,
                      height: 0.98,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    nextBadge?.description ??
                        'Play a game round to start collecting progress.',
                    maxLines: largeText ? null : 3,
                    overflow: largeText
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: muted,
                      fontWeight: FontWeight.w600,
                      height: 1.28,
                    ),
                  ),
                ],
              );
              final chest = Image.asset(
                'assets/images/quest-chest-premium-v1.png',
                key: const Key('profile-quest-chest'),
                width: stacked ? 72 : 96,
                height: stacked ? 72 : 96,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
                cacheWidth: 384,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              );
              if (stacked) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    heading,
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: chest),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: heading),
                  const SizedBox(width: 8),
                  chest,
                ],
              );
            },
          ),
          if (nextBadge != null) ...[
            const SizedBox(height: 13),
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: nextBadge!.completion,
                    minHeight: 7,
                    borderRadius: BorderRadius.circular(9),
                    backgroundColor: foreground.withValues(alpha: 0.16),
                    valueColor: AlwaysStoppedAnimation(foreground),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '${nextBadge!.progress}/${nextBadge!.target}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 15),
          Text(
            'Level ${level.number}  •  ${level.title}',
            key: const Key('profile-level-title'),
            maxLines: 2,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Semantics(
            label: level.isMaxLevel
                ? 'Maximum level achieved. ${level.xp} total experience points'
                : '$levelXp of $levelTarget experience points',
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: level.progress),
              duration: const Duration(milliseconds: 800),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => LinearProgressIndicator(
                key: const Key('profile-level-progress'),
                value: value,
                minHeight: 7,
                borderRadius: BorderRadius.circular(9),
                backgroundColor: foreground.withValues(alpha: 0.16),
                valueColor: AlwaysStoppedAnimation(foreground),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            level.isMaxLevel
                ? 'Maximum level achieved • ${level.xp} total XP'
                : '$levelXp of $levelTarget XP',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: muted,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            'Earn XP with stories, quests, and daily streaks.',
            key: const Key('profile-xp-sources'),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: muted, height: 1.3),
          ),
        ],
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({
    required this.streak,
    required this.weeks,
    required this.lastActivityAt,
  });

  final ProfileActivityStreak streak;
  final List<WeeklyProfileActivity> weeks;
  final DateTime? lastActivityAt;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasActivity = weeks.any((week) => week.activities > 0);
    return Container(
      key: const Key('profile-weekly-activity'),
      padding: const EdgeInsets.fromLTRB(18, 19, 18, 18),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.055)
            : Colors.white.withValues(alpha: 0.84),
        borderRadius: BorderRadius.circular(27),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFF2D7D6F).withValues(alpha: 0.12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Quest activity',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Stories and games over the last five weeks',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _mutedText(context),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _StreakPill(days: streak.currentDays),
            ],
          ),
          const SizedBox(height: 20),
          if (weeks.isEmpty)
            const _InlineEmptyMessage(
              icon: Icons.bar_chart_rounded,
              message: 'Activity will appear after the first story or game.',
            )
          else
            _WeeklyChart(weeks: weeks),
          const SizedBox(height: 13),
          LayoutBuilder(
            builder: (context, constraints) {
              final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
              final shouldStack =
                  constraints.maxWidth < 300 || textScale > 1.35;
              final lastActivity = Row(
                children: [
                  Icon(
                    hasActivity
                        ? Icons.bolt_rounded
                        : Icons.sports_esports_outlined,
                    color: hasActivity
                        ? const Color(0xFFE76E3F)
                        : _mutedText(context),
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _lastActivityLabel(lastActivityAt),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _mutedText(context),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              );
              final best = Text(
                'Best: ${streak.longestDays} ${streak.longestDays == 1 ? 'day' : 'days'}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: _mutedText(context),
                  fontWeight: FontWeight.w700,
                ),
              );

              if (shouldStack) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [lastActivity, const SizedBox(height: 6), best],
                );
              }
              return Row(
                children: [
                  Expanded(child: lastActivity),
                  const SizedBox(width: 8),
                  best,
                ],
              );
            },
          ),
          if (!hasActivity && weeks.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Complete a story or game round and this chart will spring to life!',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: const Color(0xFF2D7D6F),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _WeeklyChart extends StatelessWidget {
  const _WeeklyChart({required this.weeks});

  final List<WeeklyProfileActivity> weeks;

  @override
  Widget build(BuildContext context) {
    final maximum = math.max(
      1,
      weeks.fold<int>(0, (value, week) => math.max(value, week.activities)),
    );
    const colors = [
      Color(0xFF46A994),
      Color(0xFF7185D9),
      Color(0xFF9A78D7),
      Color(0xFFE77772),
      Color(0xFFF0B72F),
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var index = 0; index < weeks.length; index++) ...[
          if (index > 0) const SizedBox(width: 7),
          Expanded(
            child: _ActivityBar(
              week: weeks[index],
              maximum: maximum,
              color: colors[index % colors.length],
              delay: index * 80,
            ),
          ),
        ],
      ],
    );
  }
}

class _ActivityBar extends StatelessWidget {
  const _ActivityBar({
    required this.week,
    required this.maximum,
    required this.color,
    required this.delay,
  });

  final WeeklyProfileActivity week;
  final int maximum;
  final Color color;
  final int delay;

  @override
  Widget build(BuildContext context) {
    final targetHeight = week.activities == 0
        ? 7.0
        : math.max(18.0, week.activities / maximum * 94);
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: _weeklyActivitySemanticLabel(week),
      child: Column(
        children: [
          Text(
            '${week.activities}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: _mutedText(context),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          SizedBox(
            height: 96,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: targetHeight),
                duration: Duration(milliseconds: 620 + delay),
                curve: Curves.easeOutBack,
                builder: (context, height, _) => Container(
                  width: 24,
                  height: height,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            week.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: _mutedText(context),
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

String _weeklyActivitySemanticLabel(WeeklyProfileActivity week) {
  final activityLabel = week.activities == 1 ? 'activity' : 'activities';
  final attemptLabel = week.attempts == 1 ? 'attempt' : 'attempts';
  final completionLabel = week.storyCompletions == 1
      ? 'completion'
      : 'completions';
  return '${week.label}: ${week.activities} learning $activityLabel; '
      '${week.attempts} game $attemptLabel and '
      '${week.storyCompletions} story $completionLabel';
}

class _StreakPill extends StatelessWidget {
  const _StreakPill({required this.days});

  final int days;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFE76E3F).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.local_fire_department_rounded,
            color: Color(0xFFE76E3F),
            size: 18,
          ),
          const SizedBox(width: 4),
          Text(
            days == 0
                ? 'Start a streak'
                : '$days ${days == 1 ? 'day' : 'days'}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: const Color(0xFFE76E3F),
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileLoadingState extends StatelessWidget {
  const _ProfileLoadingState();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('profile-loading'),
      height: 510,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.square(
              dimension: 40,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: Color(0xFF2D7D6F),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Gathering your latest adventure…',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: _mutedText(context),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileErrorState extends StatelessWidget {
  const _ProfileErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _StateCard(
      key: const Key('profile-error'),
      icon: Icons.cloud_off_rounded,
      iconColor: const Color(0xFFE77772),
      title: 'Progress took a little detour',
      message: message,
      action: FilledButton.icon(
        key: const Key('profile-retry'),
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Try again'),
      ),
    );
  }
}

class _ProfileSignedOutState extends StatelessWidget {
  const _ProfileSignedOutState({required this.onSignIn});

  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    return _StateCard(
      key: const Key('profile-signed-out'),
      icon: Icons.lock_person_rounded,
      iconColor: const Color(0xFF8B68C7),
      title: 'Parent sign-in needed',
      message:
          'Sign in to safely load the child profiles and progress saved to your family account.',
      action: FilledButton.icon(
        onPressed: onSignIn,
        icon: const Icon(Icons.login_rounded),
        label: const Text('Sign in'),
      ),
    );
  }
}

class _NoActiveProfileState extends StatelessWidget {
  const _NoActiveProfileState({
    required this.hasProfiles,
    required this.isOpening,
    required this.onOpen,
  });

  final bool hasProfiles;
  final bool isOpening;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('profile-no-selection'),
      padding: const EdgeInsets.fromLTRB(22, 34, 22, 30),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.white.withValues(alpha: 0.055)
            : Colors.white.withValues(alpha: 0.84),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Column(
        children: [
          const SizedBox(
            height: 104,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned(
                  left: 24,
                  child: KidAvatarBadge(avatarKey: 'dove', size: 72),
                ),
                Positioned(
                  right: 24,
                  child: KidAvatarBadge(avatarKey: 'rainbow', size: 72),
                ),
                KidAvatarBadge(avatarKey: 'lion', size: 98),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Text(
            hasProfiles ? 'Choose your explorer' : 'Meet your explorer',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontSize: 25,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 9),
          Text(
            hasProfiles
                ? 'Pick a child profile to see their own levels, stars, badges, and streaks.'
                : 'Create a child profile so every game achievement has a safe place to grow.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: _mutedText(context),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            key: const Key('profile-choose'),
            onPressed: isOpening ? null : onOpen,
            icon: isOpening
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    hasProfiles
                        ? Icons.switch_account_rounded
                        : Icons.person_add_alt_1_rounded,
                  ),
            label: Text(hasProfiles ? 'Choose a profile' : 'Create a profile'),
          ),
        ],
      ),
    );
  }
}

class _StateCard extends StatelessWidget {
  const _StateCard({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.message,
    required this.action,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String message;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 430),
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.white.withValues(alpha: 0.055)
            : Colors.white.withValues(alpha: 0.84),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.13),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: iconColor, size: 35),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 9),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: _mutedText(context),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 22),
          action,
        ],
      ),
    );
  }
}

class _InlineEmptyMessage extends StatelessWidget {
  const _InlineEmptyMessage({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            Icon(icon, color: _mutedText(context), size: 28),
            const SizedBox(height: 7),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: _mutedText(context)),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditProfileSheet extends StatefulWidget {
  const _EditProfileSheet({required this.profile, required this.onSave});

  final KidProfile profile;
  final Future<String?> Function(String displayName, String avatarKey) onSave;

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late String _avatarKey;
  bool _isSaving = false;
  String? _errorMessage;

  List<KidAvatarOption> get _avatarOptions {
    final currentIsCharacter = kidProfileCharacterOptions.any(
      (option) => option.key == widget.profile.avatarKey,
    );
    if (currentIsCharacter) return kidProfileCharacterOptions;
    return [
      ...kidAvatarOptions.where(
        (option) => option.key == widget.profile.avatarKey,
      ),
      ...kidProfileCharacterOptions,
    ];
  }

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.profile.displayName);
    _avatarKey = widget.profile.avatarKey;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_isSaving || !_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    final error = await widget.onSave(_nameController.text, _avatarKey);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _isSaving = false;
      _errorMessage = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171D1C) : const Color(0xFFFFFCF6),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(22, 12, 22, 24 + bottomInset),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: _mutedText(context).withValues(alpha: 0.28),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Make it yours',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                fontSize: 25,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Update the name or choose a character.',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: _mutedText(context)),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: _isSaving
                        ? null
                        : () => Navigator.of(context).pop(false),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              TextFormField(
                key: const Key('profile-name-field'),
                controller: _nameController,
                maxLength: 40,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _save(),
                decoration: InputDecoration(
                  labelText: 'Profile name',
                  prefixIcon: const Icon(Icons.badge_outlined),
                  filled: true,
                  fillColor: isDark
                      ? Colors.white.withValues(alpha: 0.055)
                      : Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(17),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(17),
                    borderSide: BorderSide(
                      color: _mutedText(context).withValues(alpha: 0.15),
                    ),
                  ),
                ),
                validator: (value) {
                  final normalized =
                      value?.trim().split(RegExp(r'\s+')).join(' ') ?? '';
                  if (normalized.isEmpty) return 'Enter a profile name.';
                  if (normalized.length > 40) {
                    return 'Keep the name to 40 characters or fewer.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 15),
              Text(
                'Choose a character',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 11),
              SizedBox(
                height:
                    126 +
                    math.min(
                          2.0,
                          math.max(
                            0.0,
                            MediaQuery.textScalerOf(context).scale(14) / 14 - 1,
                          ),
                        ) *
                        20,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _avatarOptions.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final option = _avatarOptions[index];
                    final selected = option.key == _avatarKey;
                    return _AvatarChoice(
                      option: option,
                      selected: selected,
                      onTap: _isSaving
                          ? null
                          : () => setState(() => _avatarKey = option.key),
                    );
                  },
                ),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: _errorMessage == null
                    ? const SizedBox.shrink()
                    : Padding(
                        key: ValueKey(_errorMessage),
                        padding: const EdgeInsets.only(top: 13),
                        child: Text(
                          _errorMessage!,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.error,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('profile-save'),
                onPressed: _isSaving ? null : _save,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(55),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(17),
                  ),
                ),
                icon: _isSaving
                    ? const SizedBox.square(
                        dimension: 19,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.auto_awesome_rounded),
                label: Text(_isSaving ? 'Saving…' : 'Save changes'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AvatarChoice extends StatelessWidget {
  const _AvatarChoice({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final KidAvatarOption option;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      excludeSemantics: true,
      label: '${option.label}, ${option.tagline}',
      child: InkWell(
        key: ValueKey('profile-avatar-${option.key}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 96,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          decoration: BoxDecoration(
            color: selected
                ? option.color.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? option.color
                  : _mutedText(context).withValues(alpha: 0.14),
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            children: [
              KidAvatarBadge(avatarKey: option.key, size: 67),
              const SizedBox(height: 6),
              Text(
                option.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: selected ? option.color : _primaryText(context),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileBackdrop extends StatelessWidget {
  const _ProfileBackdrop();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            top: 110,
            right: -115,
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                color: const Color(
                  0xFF9A78D7,
                ).withValues(alpha: isDark ? 0.07 : 0.09),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            left: -120,
            bottom: 175,
            child: Container(
              width: 245,
              height: 245,
              decoration: BoxDecoration(
                color: const Color(
                  0xFF46A994,
                ).withValues(alpha: isDark ? 0.06 : 0.08),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _lastActivityLabel(DateTime? value) {
  if (value == null) return 'No game activity yet';
  final local = value.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final activityDay = DateTime(local.year, local.month, local.day);
  final difference = today.difference(activityDay).inDays;
  if (difference == 0) return 'Played today';
  if (difference == 1) return 'Played yesterday';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return 'Last played ${months[local.month - 1]} ${local.day}';
}

Color _primaryText(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFFF8F3EF)
    : const Color(0xFF27263B);

Color _mutedText(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFFB9B5C5)
    : const Color(0xFF777483);

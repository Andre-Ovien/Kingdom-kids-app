import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../../app/theme_controller.dart';
import '../../../core/errors/app_exception.dart';
import '../../../shared/widgets/liquid_glass.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/kid_profile.dart';
import '../../auth/domain/parent_account.dart';
import '../../auth/presentation/kid_profile_avatar.dart';
import '../../auth/presentation/session_expiry_navigation.dart';
import '../data/parental_controls_repository.dart';
import '../domain/parent_settings.dart';

class ParentalControlsScreen extends StatefulWidget {
  const ParentalControlsScreen({
    super.key,
    this.authRepository,
    this.settingsRepository,
  });

  final AuthRepository? authRepository;
  final ParentalControlsRepository? settingsRepository;

  @override
  State<ParentalControlsScreen> createState() => _ParentalControlsScreenState();
}

class _ParentalControlsScreenState extends State<ParentalControlsScreen> {
  late final AuthRepository _authRepository;
  late final ParentalControlsRepository _settingsRepository;

  ParentAccount? _parent;
  KidProfile? _activeProfile;
  List<KidProfile> _profiles = const [];
  ParentSettings? _settings;
  String? _pageError;
  String? _preferencesError;
  bool _isLoading = true;
  bool _isLoadingPreferences = false;
  bool _isSaving = false;
  bool _isSavingTheme = false;
  bool _isOpeningProfiles = false;
  bool _isSigningOut = false;
  bool _requiresSignIn = false;
  int _preferencesRequestId = 0;

  @override
  void initState() {
    super.initState();
    _authRepository = widget.authRepository ?? AuthRepository();
    _settingsRepository =
        widget.settingsRepository ??
        RemoteParentalControlsRepository(authRepository: _authRepository);
    _loadSettings();
  }

  Future<void> _loadSettings({bool refresh = false}) async {
    if (!refresh) {
      setState(() {
        _isLoading = true;
        _pageError = null;
        _preferencesError = null;
        _requiresSignIn = false;
      });
    }

    try {
      final session = await _authRepository.restoreSession();
      if (session == null) {
        if (mounted) {
          setState(() {
            _parent = null;
            _activeProfile = null;
            _profiles = const [];
            _settings = null;
            _isLoadingPreferences = false;
            _requiresSignIn = true;
          });
        }
        return;
      }

      final cachedProfile = await _authRepository.currentKid();
      if (!mounted) return;
      setState(() {
        _parent = session.parent;
        _activeProfile = cachedProfile;
        _profiles = session.profiles;
        _settings = null;
        _pageError = null;
        _preferencesError = null;
        _isLoadingPreferences = false;
        _requiresSignIn = false;
        _isLoading = false;
        _preferencesRequestId += 1;
      });

      final parent = await _authRepository.currentParent();
      final profile = await _authRepository.refreshCurrentKid();
      final refreshedSession = await _authRepository.restoreSession();
      if (!mounted) return;
      setState(() {
        _parent = parent;
        _activeProfile = profile;
        _profiles = refreshedSession?.profiles ?? const [];
        _settings = null;
        _pageError = null;
        _preferencesError = null;
        _isLoadingPreferences = false;
        _requiresSignIn = false;
        _preferencesRequestId += 1;
      });

      if (profile != null) {
        await _loadPreferences(profile, announceFailure: refresh);
      }
    } on AppException catch (error) {
      if (mounted && returnToSignInIfSessionExpired(context, error)) return;
      if (!mounted) return;
      setState(() {
        _pageError = error.message;
        if (_activeProfile != null && _settings == null) {
          _preferencesError =
              'Connect to sync this child’s reading preferences.';
        }
      });
      if (refresh || _parent != null) _showMessage(error.message);
    } catch (_) {
      if (!mounted) return;
      const message = 'We could not load parent settings. Please try again.';
      setState(() {
        _pageError = message;
        if (_activeProfile != null && _settings == null) {
          _preferencesError =
              'Connect to sync this child’s reading preferences.';
        }
      });
      if (refresh || _parent != null) _showMessage(message);
    } finally {
      if (mounted && !refresh) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadPreferences(
    KidProfile profile, {
    bool announceFailure = false,
  }) async {
    final requestId = ++_preferencesRequestId;
    if (mounted) {
      setState(() {
        _isLoadingPreferences = true;
        _preferencesError = null;
      });
    }
    try {
      final settings = await _settingsRepository.fetchSettings(
        profileId: profile.id,
      );
      if (!mounted ||
          requestId != _preferencesRequestId ||
          _activeProfile?.id != profile.id) {
        return;
      }
      setState(() {
        _settings = settings;
        _preferencesError = null;
      });
    } on AppException catch (error) {
      if (mounted && returnToSignInIfSessionExpired(context, error)) return;
      if (!mounted || requestId != _preferencesRequestId) return;
      setState(() => _preferencesError = error.message);
      if (announceFailure) _showMessage(error.message);
    } catch (_) {
      if (!mounted || requestId != _preferencesRequestId) return;
      const message = 'Reading preferences could not load yet.';
      setState(() => _preferencesError = message);
      if (announceFailure) _showMessage(message);
    } finally {
      if (mounted && requestId == _preferencesRequestId) {
        setState(() => _isLoadingPreferences = false);
      }
    }
  }

  Future<void> _updatePreferences({
    StoryTextScale? storyTextScale,
    bool? narrationEnabled,
  }) async {
    final profile = _activeProfile;
    if (profile == null || _isSaving) return;
    _preferencesRequestId += 1;
    setState(() {
      _isSaving = true;
      _isLoadingPreferences = false;
      _preferencesError = null;
    });
    try {
      final settings = await _settingsRepository.updateSettings(
        profileId: profile.id,
        storyTextScale: storyTextScale,
        narrationEnabled: narrationEnabled,
      );
      if (!mounted || _activeProfile?.id != profile.id) return;
      setState(() => _settings = settings);
      _showMessage('Saved for ${profile.displayName}.');
    } on AppException catch (error) {
      if (mounted && returnToSignInIfSessionExpired(context, error)) return;
      if (mounted) {
        setState(() => _preferencesError = error.message);
        _showMessage(error.message);
      }
    } catch (_) {
      if (mounted) {
        const message = 'We could not save that preference. Try again.';
        setState(() => _preferencesError = message);
        _showMessage(message);
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _chooseTextScale() async {
    final settings = _settings;
    if (settings == null || _isSaving) return;
    final selected = await showModalBottomSheet<StoryTextScale>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _ChoiceSheet<StoryTextScale>(
        title: 'Story text size',
        subtitle:
            'This follows ${_activeProfile?.displayName ?? 'this child'} across signed-in devices.',
        selected: settings.storyTextScale,
        options: StoryTextScale.values,
        labelFor: (value) => value.label,
        descriptionFor: (value) => switch (value) {
          StoryTextScale.comfortable => 'Balanced text for most screens',
          StoryTextScale.large => 'Larger text with more breathing room',
          StoryTextScale.extraLarge => 'Our biggest story-reading text',
        },
      ),
    );
    if (selected != null && selected != settings.storyTextScale) {
      await _updatePreferences(storyTextScale: selected);
    }
  }

  Future<void> _chooseThemeMode() async {
    if (_isSavingTheme) return;
    final current = AppThemeController.mode.value;
    final selected = await showModalBottomSheet<ThemeMode>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _ChoiceSheet<ThemeMode>(
        title: 'App appearance',
        subtitle: 'Saved on this device.',
        selected: current,
        options: ThemeMode.values,
        labelFor: _themeModeLabel,
        descriptionFor: (value) => switch (value) {
          ThemeMode.system => 'Match this device automatically',
          ThemeMode.light => 'Use the bright daytime palette',
          ThemeMode.dark => 'Use the softer nighttime palette',
        },
      ),
    );
    if (selected == null || selected == current) return;
    setState(() => _isSavingTheme = true);
    try {
      await AppThemeController.setMode(selected);
      if (mounted) {
        _showMessage('${_themeModeLabel(selected)} appearance saved.');
      }
    } catch (_) {
      if (mounted) {
        _showMessage('We could not save the appearance on this device.');
      }
    } finally {
      if (mounted) setState(() => _isSavingTheme = false);
    }
  }

  Future<void> _openProfiles() async {
    if (_isOpeningProfiles) return;
    setState(() => _isOpeningProfiles = true);
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
      if (mounted) _showMessage(error.message);
    } catch (_) {
      if (mounted) _showMessage('We could not open the family profiles.');
    } finally {
      if (mounted) setState(() => _isOpeningProfiles = false);
    }
  }

  Future<void> _signOut() async {
    if (_isSigningOut) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: Text(
          'This removes the parent session from this device. Progress already saved online stays safe${_parent?.email.isNotEmpty == true ? ' for ${_parent!.email}' : ''}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Stay signed in'),
          ),
          FilledButton(
            key: const Key('settings-confirm-sign-out'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isSigningOut = true);
    try {
      await _authRepository.logout();
    } catch (_) {
      // AuthRepository always clears local credentials in `finally`. A server
      // connectivity error must not trap a family inside a stale local session.
    }
    if (!mounted) return;
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
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
            const Positioned.fill(child: _SettingsBackdrop()),
            RefreshIndicator(
              color: const Color(0xFF2D7D6F),
              onRefresh: () => _loadSettings(refresh: true),
              child: CustomScrollView(
                key: const Key('settings-scroll'),
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 38),
                    sliver: SliverList.list(
                      children: [
                        const _SettingsTopBar(),
                        const SizedBox(height: 22),
                        if (_isLoading)
                          const _SettingsLoadingState()
                        else if (_requiresSignIn)
                          _SettingsSignedOutState(onSignIn: _goToSignIn)
                        else if (_pageError != null && _parent == null)
                          _SettingsErrorState(
                            message: _pageError!,
                            onRetry: _loadSettings,
                          )
                        else
                          _SettingsContent(
                            parent: _parent,
                            activeProfile: _activeProfile,
                            profileCount: _profiles.length,
                            settings: _settings,
                            accountSyncError: _pageError,
                            preferencesError: _preferencesError,
                            isLoadingPreferences: _isLoadingPreferences,
                            isSaving: _isSaving,
                            isSavingTheme: _isSavingTheme,
                            isOpeningProfiles: _isOpeningProfiles,
                            isSigningOut: _isSigningOut,
                            onChooseTheme: _chooseThemeMode,
                            onChooseTextScale: _chooseTextScale,
                            onNarrationChanged: (enabled) =>
                                _updatePreferences(narrationEnabled: enabled),
                            onRetryPreferences: _activeProfile == null
                                ? null
                                : () => _loadPreferences(_activeProfile!),
                            onRetryAccount: () => _loadSettings(refresh: true),
                            onOpenProfiles: _openProfiles,
                            onSignOut: _signOut,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsContent extends StatelessWidget {
  const _SettingsContent({
    required this.parent,
    required this.activeProfile,
    required this.profileCount,
    required this.settings,
    required this.accountSyncError,
    required this.preferencesError,
    required this.isLoadingPreferences,
    required this.isSaving,
    required this.isSavingTheme,
    required this.isOpeningProfiles,
    required this.isSigningOut,
    required this.onChooseTheme,
    required this.onChooseTextScale,
    required this.onNarrationChanged,
    required this.onRetryPreferences,
    required this.onRetryAccount,
    required this.onOpenProfiles,
    required this.onSignOut,
  });

  final ParentAccount? parent;
  final KidProfile? activeProfile;
  final int profileCount;
  final ParentSettings? settings;
  final String? accountSyncError;
  final String? preferencesError;
  final bool isLoadingPreferences;
  final bool isSaving;
  final bool isSavingTheme;
  final bool isOpeningProfiles;
  final bool isSigningOut;
  final VoidCallback onChooseTheme;
  final VoidCallback onChooseTextScale;
  final ValueChanged<bool> onNarrationChanged;
  final VoidCallback? onRetryPreferences;
  final VoidCallback onRetryAccount;
  final VoidCallback onOpenProfiles;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsHero(profile: activeProfile, parent: parent),
        if (accountSyncError != null) ...[
          const SizedBox(height: 11),
          _InlineNotice(
            key: const Key('settings-account-sync-error'),
            message: 'Showing saved account details. $accountSyncError',
            onRetry: onRetryAccount,
            retryKey: const Key('settings-account-retry'),
          ),
        ],
        const SizedBox(height: 24),
        const _SettingsSectionTitle(
          title: 'On this device',
          subtitle: 'Appearance stays with this phone or tablet.',
        ),
        const SizedBox(height: 11),
        _SettingsGroup(
          children: [
            ValueListenableBuilder<ThemeMode>(
              valueListenable: AppThemeController.mode,
              builder: (context, mode, _) => _SettingsActionTile(
                key: const Key('settings-theme'),
                icon: _themeModeIcon(mode),
                title: 'App appearance',
                subtitle: _themeModeLabel(mode),
                onTap: isSavingTheme ? null : onChooseTheme,
              ),
            ),
          ],
        ),
        const SizedBox(height: 25),
        _SettingsSectionTitle(
          title: 'Reading for ${activeProfile?.displayName ?? 'a child'}',
          subtitle: activeProfile == null
              ? 'Choose a profile to manage reading preferences.'
              : 'These choices sync safely with this child profile.',
          trailing: isSaving || isLoadingPreferences
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
        ),
        const SizedBox(height: 11),
        if (activeProfile == null)
          _ChooseProfileCard(
            isOpening: isOpeningProfiles,
            onOpen: onOpenProfiles,
          )
        else if (settings == null && isLoadingPreferences)
          const _PreferencesLoadingCard()
        else if (settings == null)
          _PreferencesErrorCard(
            message:
                preferencesError ?? 'Reading preferences could not load yet.',
            onRetry: onRetryPreferences,
          )
        else ...[
          _SettingsGroup(
            children: [
              _SettingsActionTile(
                key: const Key('settings-text-size'),
                icon: Icons.text_fields_rounded,
                title: 'Story text size',
                subtitle: settings!.storyTextScale.label,
                onTap: isSaving ? null : onChooseTextScale,
              ),
              const _SettingsDivider(),
              _SettingsSwitchTile(
                key: const Key('settings-narration'),
                icon: Icons.record_voice_over_rounded,
                title: 'Narration audio',
                subtitle: settings!.narrationEnabled
                    ? 'Read-aloud voices are available'
                    : 'Read-aloud voices are turned off',
                value: settings!.narrationEnabled,
                onChanged: isSaving ? null : onNarrationChanged,
              ),
            ],
          ),
          if (preferencesError != null) ...[
            const SizedBox(height: 10),
            _InlineNotice(
              key: const Key('settings-preferences-inline-error'),
              message: preferencesError!,
              onRetry: onRetryPreferences,
              retryKey: const Key('settings-preferences-inline-retry'),
            ),
          ],
        ],
        const SizedBox(height: 25),
        const _SettingsSectionTitle(
          title: 'Family account',
          subtitle: 'Live details from the signed-in parent account.',
        ),
        const SizedBox(height: 11),
        _AccountCard(
          parent: parent,
          profileCount: profileCount,
          isOpeningProfiles: isOpeningProfiles,
          onOpenProfiles: onOpenProfiles,
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          key: const Key('settings-sign-out'),
          onPressed: isSigningOut ? null : onSignOut,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(54),
            foregroundColor: const Color(0xFFD9534F),
            side: BorderSide(
              color: const Color(0xFFD9534F).withValues(alpha: 0.46),
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(17),
            ),
          ),
          icon: isSigningOut
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.logout_rounded),
          label: Text(
            isSigningOut ? 'Signing out…' : 'Sign out on this device',
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Notifications, offline downloads, time limits, and video controls will appear here only when their full systems are ready.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: _mutedText(context),
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

class _SettingsTopBar extends StatelessWidget {
  const _SettingsTopBar();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        LiquidGlass(
          borderRadius: 28,
          opacity: 0.02,
          blur: 28,
          borderOpacity: 0.4,
          child: SizedBox.square(
            dimension: 50,
            child: IconButton(
              key: const Key('settings-back'),
              tooltip: 'Back',
              padding: EdgeInsets.zero,
              color: _primaryText(context),
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 21),
            ),
          ),
        ),
        Expanded(
          child: Text(
            'Parent settings',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
        ),
        const SizedBox(width: 50),
      ],
    );
  }
}

class _SettingsHero extends StatelessWidget {
  const _SettingsHero({required this.profile, required this.parent});

  final KidProfile? profile;
  final ParentAccount? parent;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      key: const Key('settings-live-hero'),
      padding: const EdgeInsets.fromLTRB(20, 23, 20, 21),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [Color(0xFF1E423C), Color(0xFF332742)]
              : const [Color(0xFFDDF4EB), Color(0xFFF1E3F7)],
        ),
        borderRadius: BorderRadius.circular(29),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.1)
              : Colors.white.withValues(alpha: 0.82),
        ),
      ),
      child: Column(
        children: [
          if (profile != null)
            KidProfileAvatar(profile: profile!, size: 92)
          else
            Container(
              width: 86,
              height: 86,
              decoration: BoxDecoration(
                color: const Color(0xFF2D7D6F).withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.family_restroom_rounded,
                color: Color(0xFF2D7D6F),
                size: 40,
              ),
            ),
          const SizedBox(height: 13),
          Text(
            profile?.displayName ?? 'Family settings',
            key: const Key('settings-profile-name'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontSize: 25,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            profile == null
                ? 'Choose a child to personalise reading.'
                : 'A parent can shape ${profile!.displayName}’s reading experience here.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: _mutedText(context),
              height: 1.35,
            ),
          ),
          if (parent?.email.isNotEmpty == true) ...[
            const SizedBox(height: 11),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.62),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.verified_user_rounded,
                    color: Color(0xFF2D7D6F),
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Verified parent',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: const Color(0xFF2D7D6F),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SettingsSectionTitle extends StatelessWidget {
  const _SettingsSectionTitle({
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: _mutedText(context),
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ],
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LiquidGlass(
      borderRadius: 23,
      opacity: _isDark(context) ? 0.05 : 0.34,
      blur: 24,
      borderOpacity: _isDark(context) ? 0.18 : 0.46,
      child: Material(
        type: MaterialType.transparency,
        child: Column(children: children),
      ),
    );
  }
}

class _SettingsActionTile extends StatelessWidget {
  const _SettingsActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      leading: _SettingIcon(icon: icon),
      title: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontSize: 15.5,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          subtitle,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: _mutedText(context),
            height: 1.3,
          ),
        ),
      ),
      trailing: onTap == null
          ? null
          : Icon(
              Icons.chevron_right_rounded,
              color: _mutedText(context),
              size: 24,
            ),
    );
  }
}

class _SettingsSwitchTile extends StatelessWidget {
  const _SettingsSwitchTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      value: value,
      onChanged: onChanged,
      activeThumbColor: const Color(0xFFFF7043),
      activeTrackColor: const Color(0xFFFFB39B),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      secondary: _SettingIcon(icon: icon),
      title: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontSize: 15.5,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          subtitle,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: _mutedText(context),
            height: 1.3,
          ),
        ),
      ),
    );
  }
}

class _SettingsDivider extends StatelessWidget {
  const _SettingsDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      indent: 66,
      endIndent: 14,
      color: _mutedText(context).withValues(alpha: 0.12),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.parent,
    required this.profileCount,
    required this.isOpeningProfiles,
    required this.onOpenProfiles,
  });

  final ParentAccount? parent;
  final int profileCount;
  final bool isOpeningProfiles;
  final VoidCallback onOpenProfiles;

  @override
  Widget build(BuildContext context) {
    final email = parent?.email.trim() ?? '';
    return _SettingsGroup(
      children: [
        ListTile(
          key: const Key('settings-parent-email'),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 7,
          ),
          leading: const _SettingIcon(icon: Icons.alternate_email_rounded),
          title: Text(
            'Parent email',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontSize: 15.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              email.isEmpty ? 'Email unavailable' : email,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: _mutedText(context),
                height: 1.3,
              ),
            ),
          ),
          trailing: const Icon(
            Icons.verified_rounded,
            color: Color(0xFF2D7D6F),
            size: 22,
          ),
        ),
        const _SettingsDivider(),
        _SettingsActionTile(
          key: const Key('settings-manage-profiles'),
          icon: Icons.switch_account_rounded,
          title: 'Manage child profiles',
          subtitle:
              '$profileCount ${profileCount == 1 ? 'profile' : 'profiles'} in this family',
          onTap: isOpeningProfiles ? null : onOpenProfiles,
        ),
      ],
    );
  }
}

class _ChooseProfileCard extends StatelessWidget {
  const _ChooseProfileCard({required this.isOpening, required this.onOpen});

  final bool isOpening;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _surfaceCard(context),
        borderRadius: BorderRadius.circular(23),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.switch_account_rounded,
            color: Color(0xFF2D7D6F),
            size: 34,
          ),
          const SizedBox(height: 10),
          Text(
            'Choose who is reading',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            'Text size and narration belong to an individual child profile.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: _mutedText(context),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 15),
          FilledButton.icon(
            key: const Key('settings-choose-profile'),
            onPressed: isOpening ? null : onOpen,
            icon: isOpening
                ? const SizedBox.square(
                    dimension: 17,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.person_search_rounded),
            label: const Text('Choose a profile'),
          ),
        ],
      ),
    );
  }
}

class _PreferencesErrorCard extends StatelessWidget {
  const _PreferencesErrorCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('settings-preferences-error'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _surfaceCard(context),
        borderRadius: BorderRadius.circular(23),
      ),
      child: Row(
        children: [
          const Icon(Icons.sync_problem_rounded, color: Color(0xFFE77772)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: _mutedText(context),
                height: 1.35,
              ),
            ),
          ),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _PreferencesLoadingCard extends StatelessWidget {
  const _PreferencesLoadingCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('settings-preferences-loading'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _surfaceCard(context),
        borderRadius: BorderRadius.circular(23),
      ),
      child: Row(
        children: [
          const SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: Color(0xFF2D7D6F),
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Text(
              'Syncing this child’s reading preferences…',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: _mutedText(context),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({
    super.key,
    required this.message,
    required this.onRetry,
    this.retryKey,
  });

  final String message;
  final VoidCallback? onRetry;
  final Key? retryKey;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            color: Theme.of(context).colorScheme.error,
            size: 18,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
          if (onRetry != null)
            TextButton(
              key: retryKey,
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }
}

class _ChoiceSheet<T> extends StatelessWidget {
  const _ChoiceSheet({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.options,
    required this.labelFor,
    required this.descriptionFor,
  });

  final String title;
  final String subtitle;
  final T selected;
  final List<T> options;
  final String Function(T value) labelFor;
  final String Function(T value) descriptionFor;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171D1C) : const Color(0xFFFFFCF6),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(29)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 11, 18, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: _mutedText(context).withValues(alpha: 0.26),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 19),
              Text(
                title,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: _mutedText(context)),
              ),
              const SizedBox(height: 14),
              for (final option in options)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    key: ValueKey('settings-choice-${labelFor(option)}'),
                    onTap: () => Navigator.of(context).pop(option),
                    selected: option == selected,
                    selectedTileColor: const Color(
                      0xFF2D7D6F,
                    ).withValues(alpha: 0.1),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(17),
                    ),
                    title: Text(
                      labelFor(option),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(descriptionFor(option)),
                    trailing: option == selected
                        ? const Icon(
                            Icons.check_circle_rounded,
                            color: Color(0xFF2D7D6F),
                          )
                        : null,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsLoadingState extends StatelessWidget {
  const _SettingsLoadingState();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('settings-loading'),
      height: 520,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFF2D7D6F)),
            const SizedBox(height: 15),
            Text(
              'Loading family settings…',
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

class _SettingsErrorState extends StatelessWidget {
  const _SettingsErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _SettingsStateCard(
      key: const Key('settings-error'),
      icon: Icons.cloud_off_rounded,
      title: 'Settings took a little detour',
      message: message,
      action: FilledButton.icon(
        key: const Key('settings-retry'),
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Try again'),
      ),
    );
  }
}

class _SettingsSignedOutState extends StatelessWidget {
  const _SettingsSignedOutState({required this.onSignIn});

  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    return _SettingsStateCard(
      key: const Key('settings-signed-out'),
      icon: Icons.lock_person_rounded,
      title: 'Parent sign-in needed',
      message:
          'Sign in to manage your family account and each child’s reading preferences.',
      action: FilledButton.icon(
        onPressed: onSignIn,
        icon: const Icon(Icons.login_rounded),
        label: const Text('Sign in'),
      ),
    );
  }
}

class _SettingsStateCard extends StatelessWidget {
  const _SettingsStateCard({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    required this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 440),
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: _surfaceCard(context),
        borderRadius: BorderRadius.circular(29),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              color: const Color(0xFF8B68C7).withValues(alpha: 0.13),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: const Color(0xFF8B68C7), size: 34),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: _mutedText(context),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          action,
        ],
      ),
    );
  }
}

class _SettingIcon extends StatelessWidget {
  const _SettingIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: _isDark(context)
            ? Colors.white.withValues(alpha: 0.08)
            : const Color(0xFFFFEEE8),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(icon, color: const Color(0xFFFF7043), size: 21),
    );
  }
}

class _SettingsBackdrop extends StatelessWidget {
  const _SettingsBackdrop();

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            top: 120,
            right: -110,
            child: Container(
              width: 245,
              height: 245,
              decoration: BoxDecoration(
                color: const Color(
                  0xFF9A78D7,
                ).withValues(alpha: dark ? 0.06 : 0.08),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            left: -115,
            bottom: 100,
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                color: const Color(
                  0xFF46A994,
                ).withValues(alpha: dark ? 0.05 : 0.07),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _themeModeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.system => 'Follow device',
  ThemeMode.light => 'Light',
  ThemeMode.dark => 'Dark',
};

IconData _themeModeIcon(ThemeMode mode) => switch (mode) {
  ThemeMode.system => Icons.brightness_auto_rounded,
  ThemeMode.light => Icons.light_mode_rounded,
  ThemeMode.dark => Icons.dark_mode_rounded,
};

bool _isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

Color _surfaceCard(BuildContext context) => _isDark(context)
    ? Colors.white.withValues(alpha: 0.055)
    : Colors.white.withValues(alpha: 0.84);

Color _primaryText(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface;

Color _mutedText(BuildContext context) =>
    _isDark(context) ? const Color(0xFFB8B5C1) : const Color(0xFF766F7B);

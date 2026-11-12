import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../../core/errors/app_exception.dart';
import '../data/auth_repository.dart';
import '../domain/kid_profile.dart';
import 'adult_gate.dart';
import 'kid_profile_avatar.dart';
import 'profile_picker_carousel.dart';
import 'session_expiry_navigation.dart';

/// Lets a parent choose which child profile is using the app and add more
/// profiles under the same authenticated parent account.
class ProfilePickerScreen extends StatefulWidget {
  const ProfilePickerScreen({
    super.key,
    this.initialProfiles = const [],
    this.repository,
  });

  final List<KidProfile> initialProfiles;
  final AuthRepository? repository;

  @override
  State<ProfilePickerScreen> createState() => _ProfilePickerScreenState();
}

class _ProfilePickerScreenState extends State<ProfilePickerScreen> {
  late final AuthRepository _repository;
  late List<KidProfile> _profiles;
  bool _isLoading = false;
  bool _isAddingProfile = false;
  String? _selectingProfileId;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? AuthRepository();
    _profiles = List.of(widget.initialProfiles);
    if (_profiles.isEmpty) {
      _loadProfiles();
    }
  }

  Future<void> _loadProfiles() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final profiles = await _repository.fetchKidProfiles();
      if (mounted) {
        setState(() => _profiles = profiles);
      }
    } on AppException catch (error) {
      if (mounted && returnToSignInIfSessionExpired(context, error)) {
        return;
      }
      if (mounted) {
        setState(() => _errorMessage = error.userMessage);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _errorMessage = 'We could not load your family profiles.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _selectProfile(KidProfile profile) async {
    if (_selectingProfileId != null || _isAddingProfile) return;
    setState(() {
      _selectingProfileId = profile.id;
      _errorMessage = null;
    });
    try {
      await _repository.selectKid(profile);
      if (!mounted) {
        return;
      }
      Navigator.of(
        context,
      ).pushNamedAndRemoveUntil(AppRoutes.home, (_) => false);
    } on AppException catch (error) {
      if (mounted && returnToSignInIfSessionExpired(context, error)) return;
      if (mounted) _showSelectionError(error.userMessage);
    } catch (_) {
      if (mounted) _showSelectionError('We could not open that profile.');
    } finally {
      if (mounted) {
        setState(() => _selectingProfileId = null);
      }
    }
  }

  Future<void> _addProfile() async {
    if (_isAddingProfile || _selectingProfileId != null) return;
    setState(() => _isAddingProfile = true);
    try {
      if (_profiles.isNotEmpty) {
        final authorized = await showAdultGate(
          context: context,
          repository: _repository,
          title: 'Add another child',
          reason: 'Enter the parent password before creating another profile.',
        );
        if (!mounted || !authorized) return;
      }
      await Navigator.of(
        context,
      ).pushNamed(AppRoutes.kidProfileSetup, arguments: _profiles);
    } finally {
      if (mounted) setState(() => _isAddingProfile = false);
    }
  }

  void _showSelectionError(String message) {
    setState(() => _errorMessage = message);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_profiles.isNotEmpty && !_isLoading) {
      return ProfilePickerCarousel(
        profiles: _profiles,
        selectingProfileId: _selectingProfileId,
        isAddingProfile: _isAddingProfile,
        onSelectProfile: _selectProfile,
        onAddProfile: _addProfile,
        onBack: Navigator.of(context).canPop()
            ? () => Navigator.of(context).maybePop()
            : null,
      );
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hasBlockingLoadError = !_isLoading && _errorMessage != null;
    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF101414)
          : const Color(0xFFFFFBF7),
      body: SafeArea(
        child: Stack(
          children: [
            _PickerBackdrop(isDark: isDark),
            CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 26, 24, 34),
                  sliver: SliverList.list(
                    children: [
                      const SizedBox(height: 36),
                      const _PickerHero(),
                      const SizedBox(height: 24),
                      Text(
                        hasBlockingLoadError
                            ? 'Let\'s try that again'
                            : _isLoading
                            ? 'Who\'s ready to explore?'
                            : 'Let\'s make a profile',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: _primaryText(context),
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          height: 1.08,
                          letterSpacing: -0.7,
                        ),
                      ),
                      const SizedBox(height: 9),
                      Text(
                        hasBlockingLoadError
                            ? 'We could not gather your family profiles just now.'
                            : _isLoading
                            ? 'Choose a profile to keep stories, badges, and progress just for them.'
                            : 'A parent can make the first child profile in just a moment.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: _secondaryText(context),
                          fontSize: 15,
                          height: 1.42,
                        ),
                      ),
                      const SizedBox(height: 29),
                      if (_isLoading)
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.all(28),
                            child: CircularProgressIndicator(
                              color: Color(0xFF2D7D6F),
                            ),
                          ),
                        )
                      else if (hasBlockingLoadError)
                        _ProfilesLoadError(
                          message: _errorMessage!,
                          onRetry: _loadProfiles,
                        )
                      else
                        _EmptyProfilesCard(onAddProfile: _addProfile),
                      const SizedBox(height: 19),
                      _PickerSafetyNote(isDark: isDark),
                    ],
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

class _PickerBackdrop extends StatelessWidget {
  const _PickerBackdrop({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            top: -100,
            left: -110,
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF9A78D7).withValues(alpha: 0.1)
                    : const Color(0xFFE9DEFA).withValues(alpha: 0.66),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            right: -115,
            bottom: -125,
            child: Container(
              width: 280,
              height: 280,
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFFFFB642).withValues(alpha: 0.08)
                    : const Color(0xFFFFE6AD).withValues(alpha: 0.48),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PickerHero extends StatelessWidget {
  const _PickerHero();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 100,
      child: Stack(
        alignment: Alignment.center,
        children: const [
          Positioned(
            left: 42,
            child: KidAvatarBadge(avatarKey: 'dove', size: 70),
          ),
          KidAvatarBadge(avatarKey: 'lion', size: 98),
          Positioned(
            right: 42,
            child: KidAvatarBadge(avatarKey: 'rainbow', size: 70),
          ),
        ],
      ),
    );
  }
}

class _EmptyProfilesCard extends StatelessWidget {
  const _EmptyProfilesCard({required this.onAddProfile});

  final VoidCallback onAddProfile;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.white.withValues(alpha: 0.79),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.1)
              : const Color(0xFF2D7D6F).withValues(alpha: 0.12),
        ),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.person_add_alt_1_rounded,
            color: Color(0xFF2D7D6F),
            size: 34,
          ),
          const SizedBox(height: 12),
          Text(
            'No child profiles yet',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: _primaryText(context),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'A parent can create the first one now.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: _secondaryText(context)),
          ),
          const SizedBox(height: 17),
          FilledButton.icon(
            key: const Key('profile-picker-create-first-child'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2D7D6F),
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: onAddProfile,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Create a child profile'),
          ),
        ],
      ),
    );
  }
}

class _ProfilesLoadError extends StatelessWidget {
  const _ProfilesLoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      key: const Key('profile-picker-load-error'),
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.white.withValues(alpha: 0.79),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.1)
              : const Color(0xFF2D7D6F).withValues(alpha: 0.12),
        ),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            color: Color(0xFF2D7D6F),
            size: 36,
          ),
          const SizedBox(height: 12),
          Text(
            'Profiles couldn\'t load',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: _primaryText(context),
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: _secondaryText(context),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 17),
          FilledButton.icon(
            key: const Key('profile-picker-retry-button'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2D7D6F),
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

class _PickerSafetyNote extends StatelessWidget {
  const _PickerSafetyNote({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.lock_outline_rounded,
          color: isDark ? const Color(0xFF9AD1C4) : const Color(0xFF2D7D6F),
          size: 17,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Parent account protected · Child profiles do not use passwords.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: _secondaryText(context),
              fontSize: 12.5,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

Color _primaryText(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFFF8F3EF)
      : const Color(0xFF1F2933);
}

Color _secondaryText(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFFB7C1BF)
      : const Color(0xFF68736F);
}

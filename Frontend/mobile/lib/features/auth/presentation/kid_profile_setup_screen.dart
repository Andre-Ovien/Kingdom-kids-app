import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/router.dart';
import '../../../core/errors/app_exception.dart';
import '../data/auth_repository.dart';
import '../domain/auth_requests.dart';
import '../domain/kid_profile.dart';
import 'kid_character_pose.dart';
import 'kid_profile_avatar.dart';
import 'session_expiry_navigation.dart';

/// Parent-controlled setup for a child profile. The only child information we
/// collect is a display name and a playful, non-photo avatar.
class KidProfileSetupScreen extends StatefulWidget {
  const KidProfileSetupScreen({
    super.key,
    this.existingProfiles = const [],
    this.repository,
  });

  final List<KidProfile> existingProfiles;
  final AuthRepository? repository;

  @override
  State<KidProfileSetupScreen> createState() => _KidProfileSetupScreenState();
}

class _KidProfileSetupScreenState extends State<KidProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  late final AuthRepository _repository;
  String _selectedAvatarKey = kidProfileCharacterOptions.first.key;
  String? _creationOperationId;
  String? _creationInputFingerprint;
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? AuthRepository();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _selectAvatar(String avatarKey) {
    if (avatarKey == _selectedAvatarKey) {
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _selectedAvatarKey = avatarKey);
  }

  Future<void> _createProfile() async {
    if (_isSaving) {
      return;
    }

    FocusManager.instance.primaryFocus?.unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      final displayName = _nameController.text
          .trim()
          .split(RegExp(r'\s+'))
          .join(' ');
      final operationId = _operationIdFor(
        displayName: displayName,
        avatarKey: _selectedAvatarKey,
      );
      final profile = await _repository.createKidProfile(
        CreateKidProfileRequest(
          displayName: displayName,
          avatarKey: _selectedAvatarKey,
          operationId: operationId,
        ),
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pushNamedAndRemoveUntil(
        AppRoutes.profilePicker,
        (_) => false,
        arguments: [...widget.existingProfiles, profile],
      );
    } on AppException catch (error) {
      if (mounted && returnToSignInIfSessionExpired(context, error)) {
        return;
      }
      if (mounted) {
        setState(() => _errorMessage = error.message);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _errorMessage = 'We could not create that profile. Try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  String _operationIdFor({
    required String displayName,
    required String avatarKey,
  }) {
    final fingerprint = '$displayName\u0000$avatarKey';
    if (_creationOperationId == null ||
        _creationInputFingerprint != fingerprint) {
      _creationOperationId = newKidProfileCreationOperationId();
      _creationInputFingerprint = fingerprint;
    }
    return _creationOperationId!;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final selectedOption = kidAvatarOptionFor(_selectedAvatarKey);
    final motionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 360);

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF111416)
          : const Color(0xFFFFFCF8),
      body: AnimatedContainer(
        duration: motionDuration,
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [
                    Color.lerp(
                      const Color(0xFF111416),
                      selectedOption.color,
                      0.16,
                    )!,
                    const Color(0xFF111416),
                  ]
                : [
                    Color.lerp(
                      const Color(0xFFFFFCF8),
                      selectedOption.color,
                      0.18,
                    )!,
                    const Color(0xFFFFFCF8),
                    Color.lerp(
                      const Color(0xFFFFFCF8),
                      selectedOption.color,
                      0.06,
                    )!,
                  ],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: _PlayfulBackdrop(
                    accent: selectedOption.color,
                    isDark: isDark,
                    duration: motionDuration,
                  ),
                ),
              ),
              CustomScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 34),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        children: [
                          _TopBar(canGoBack: Navigator.of(context).canPop()),
                          const SizedBox(height: 20),
                          Text(
                            widget.existingProfiles.isEmpty
                                ? 'Choose their story buddy'
                                : 'Another explorer is joining!',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineMedium?.copyWith(
                              color: _primaryText(context),
                              fontSize: 32,
                              fontWeight: FontWeight.w900,
                              height: 1.02,
                              letterSpacing: -1,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Pick a character that feels just right, then give your little explorer a display name.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: _secondaryText(context),
                              fontSize: 15,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 22),
                          _CharacterStage(
                            option: selectedOption,
                            duration: motionDuration,
                            isDark: isDark,
                          ),
                          const SizedBox(height: 18),
                          Text(
                            'Pick a buddy',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: _primaryText(context),
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 11),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (
                                var index = 0;
                                index < kidProfileCharacterOptions.length;
                                index++
                              ) ...[
                                if (index > 0) const SizedBox(width: 9),
                                Expanded(
                                  child: _CharacterChoice(
                                    option: kidProfileCharacterOptions[index],
                                    selected:
                                        kidProfileCharacterOptions[index].key ==
                                        _selectedAvatarKey,
                                    duration: motionDuration,
                                    onTap: () => _selectAvatar(
                                      kidProfileCharacterOptions[index].key,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 22),
                          Form(
                            key: _formKey,
                            child: _NameCard(
                              controller: _nameController,
                              accent: selectedOption.color,
                              isDark: isDark,
                              onSubmitted: _createProfile,
                            ),
                          ),
                          const SizedBox(height: 15),
                          _PrivacyNote(isDark: isDark),
                          if (_errorMessage != null) ...[
                            const SizedBox(height: 14),
                            _InlineError(message: _errorMessage!),
                          ],
                          const SizedBox(height: 20),
                          AnimatedContainer(
                            duration: motionDuration,
                            curve: Curves.easeOutCubic,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: selectedOption.color.withValues(
                                    alpha: isDark ? 0.12 : 0.28,
                                  ),
                                  blurRadius: 24,
                                  offset: const Offset(0, 10),
                                ),
                              ],
                            ),
                            child: FilledButton.icon(
                              key: const Key('create-kid-profile-button'),
                              style: FilledButton.styleFrom(
                                backgroundColor: selectedOption.color,
                                foregroundColor: Colors.white,
                                disabledBackgroundColor: selectedOption.color
                                    .withValues(alpha: 0.55),
                                disabledForegroundColor: Colors.white,
                                minimumSize: const Size.fromHeight(59),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                textStyle: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              onPressed: _isSaving ? null : _createProfile,
                              icon: _isSaving
                                  ? const SizedBox.square(
                                      dimension: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.4,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.auto_awesome_rounded),
                              label: Text(
                                _isSaving
                                    ? 'Creating profile…'
                                    : 'Start the adventure',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.canGoBack});

  final bool canGoBack;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox.square(
          dimension: 48,
          child: canGoBack
              ? IconButton(
                  tooltip: 'Back',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back_ios_new_rounded),
                )
              : null,
        ),
        const Expanded(child: Center(child: _StepLabel())),
        const SizedBox(width: 48),
      ],
    );
  }
}

class _StepLabel extends StatelessWidget {
  const _StepLabel();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.white.withValues(alpha: 0.1)
              : const Color(0xFF243133).withValues(alpha: 0.08),
        ),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          'LAST STEP  •  MAKE IT THEIRS',
          style: TextStyle(
            color: _secondaryText(context),
            fontSize: 10.5,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.55,
          ),
        ),
      ),
    );
  }
}

class _CharacterStage extends StatelessWidget {
  const _CharacterStage({
    required this.option,
    required this.duration,
    required this.isDark,
  });

  final KidAvatarOption option;
  final Duration duration;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: duration,
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            option.color.withValues(alpha: isDark ? 0.28 : 0.22),
            isDark
                ? Colors.white.withValues(alpha: 0.055)
                : Colors.white.withValues(alpha: 0.86),
          ],
        ),
        borderRadius: BorderRadius.circular(34),
        border: Border.all(
          color: option.color.withValues(alpha: isDark ? 0.36 : 0.28),
          width: 1.3,
        ),
        boxShadow: [
          BoxShadow(
            color: option.color.withValues(alpha: isDark ? 0.08 : 0.16),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            left: -24,
            top: -28,
            child: _StageBubble(
              size: 112,
              color: option.color.withValues(alpha: 0.13),
            ),
          ),
          Positioned(
            right: -16,
            bottom: -32,
            child: _StageBubble(
              size: 98,
              color: option.color.withValues(alpha: 0.12),
            ),
          ),
          Positioned(
            top: 28,
            left: 36,
            child: _Sparkle(
              key: ValueKey('left-${option.key}'),
              color: option.color,
              duration: duration,
              size: 25,
            ),
          ),
          Positioned(
            top: 62,
            right: 31,
            child: _Sparkle(
              key: ValueKey('right-${option.key}'),
              color: option.color,
              duration: duration,
              size: 19,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 21),
            child: AnimatedSwitcher(
              duration: duration,
              switchInCurve: Curves.linear,
              switchOutCurve: Curves.linear,
              transitionBuilder: (child, animation) {
                final scale = Tween<double>(begin: 0.86, end: 1).animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutBack,
                    reverseCurve: Curves.easeIn,
                  ),
                );
                return FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(scale: scale, child: child),
                );
              },
              child: Column(
                key: ValueKey(option.key),
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 204,
                    width: 220,
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          left: 23,
                          right: 23,
                          bottom: 1,
                          child: Container(
                            height: 35,
                            decoration: BoxDecoration(
                              color: option.color.withValues(
                                alpha: isDark ? 0.2 : 0.15,
                              ),
                              borderRadius: BorderRadius.circular(99),
                            ),
                          ),
                        ),
                        Positioned.fill(
                          child: KidCharacterPoseImage(
                            key: const Key('kid-profile-stage-pose'),
                            avatarKey: option.key,
                            pose: KidCharacterPose.wave,
                            fit: BoxFit.contain,
                            semanticLabel:
                                '${option.label} waving, selected story buddy',
                            fallbackSize: 148,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 9),
                  Text(
                    'Meet ${option.label}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: _primaryText(context),
                      fontSize: 23,
                      fontWeight: FontWeight.w900,
                      height: 1.05,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: option.color.withValues(
                        alpha: isDark ? 0.18 : 0.14,
                      ),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      option.tagline,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isDark
                            ? Color.lerp(Colors.white, option.color, 0.18)
                            : Color.lerp(
                                const Color(0xFF243133),
                                option.color,
                                0.38,
                              ),
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CharacterChoice extends StatelessWidget {
  const _CharacterChoice({
    required this.option,
    required this.selected,
    required this.duration,
    required this.onTap,
  });

  final KidAvatarOption option;
  final bool selected;
  final Duration duration;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      button: true,
      selected: selected,
      excludeSemantics: true,
      label: '${option.label}, ${option.tagline}',
      child: AnimatedScale(
        scale: selected ? 1.035 : 1,
        duration: duration,
        curve: Curves.easeOutBack,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: Key('kid-avatar-choice-${option.key}'),
            borderRadius: BorderRadius.circular(23),
            onTap: onTap,
            child: AnimatedContainer(
              duration: duration,
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.fromLTRB(7, 9, 7, 10),
              decoration: BoxDecoration(
                color: selected
                    ? option.color.withValues(alpha: isDark ? 0.2 : 0.16)
                    : (isDark
                          ? Colors.white.withValues(alpha: 0.055)
                          : Colors.white.withValues(alpha: 0.7)),
                borderRadius: BorderRadius.circular(23),
                border: Border.all(
                  color: selected
                      ? option.color
                      : (isDark
                            ? Colors.white.withValues(alpha: 0.1)
                            : const Color(0xFF243133).withValues(alpha: 0.09)),
                  width: selected ? 2.2 : 1,
                ),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: option.color.withValues(alpha: 0.17),
                          blurRadius: 16,
                          offset: const Offset(0, 7),
                        ),
                      ]
                    : null,
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Center(
                        child: KidAvatarBadge(avatarKey: option.key, size: 68),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        option.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: _primaryText(context),
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                  if (selected)
                    Positioned(
                      top: -2,
                      right: -1,
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: option.color,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: const Icon(
                          Icons.check_rounded,
                          color: Colors.white,
                          size: 15,
                        ),
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

class _NameCard extends StatelessWidget {
  const _NameCard({
    required this.controller,
    required this.accent,
    required this.isDark,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final Color accent;
  final bool isDark;
  final Future<void> Function() onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 17),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.065)
            : Colors.white.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.1)
              : accent.withValues(alpha: 0.16),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.12 : 0.045),
            blurRadius: 20,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 37,
                height: 37,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: isDark ? 0.2 : 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.edit_rounded, color: accent, size: 19),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'What should we call them?',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: _primaryText(context),
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'A nickname works perfectly.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _secondaryText(context),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 13),
          TextFormField(
            key: const Key('kid-profile-name-field'),
            controller: controller,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => onSubmitted(),
            validator: (value) {
              final name = value?.trim() ?? '';
              if (name.length < 2) {
                return 'Choose a name with at least 2 letters.';
              }
              if (name.length > 30) {
                return 'Keep the name to 30 characters or fewer.';
              }
              return null;
            },
            style: TextStyle(
              color: _primaryText(context),
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
            decoration: InputDecoration(
              hintText: 'Type their display name',
              hintStyle: TextStyle(
                color: _secondaryText(context).withValues(alpha: 0.74),
                fontWeight: FontWeight.w500,
              ),
              filled: true,
              fillColor: isDark
                  ? Colors.black.withValues(alpha: 0.15)
                  : const Color(0xFFFFFCF8),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 16,
              ),
              border: _inputBorder(context),
              enabledBorder: _inputBorder(context),
              focusedBorder: _inputBorder(context, color: accent, width: 1.8),
              errorBorder: _inputBorder(
                context,
                color: Theme.of(context).colorScheme.error,
              ),
              focusedErrorBorder: _inputBorder(
                context,
                color: Theme.of(context).colorScheme.error,
                width: 1.8,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF46A994).withValues(alpha: 0.1)
            : const Color(0xFFE8F6F1),
        borderRadius: BorderRadius.circular(17),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.verified_user_rounded,
            color: Color(0xFF338875),
            size: 20,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              'Parent-created and private. Children never need an email address or password.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: _secondaryText(context),
                height: 1.35,
                fontSize: 12.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(15),
      ),
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onErrorContainer,
        ),
      ),
    );
  }
}

class _PlayfulBackdrop extends StatelessWidget {
  const _PlayfulBackdrop({
    required this.accent,
    required this.isDark,
    required this.duration,
  });

  final Color accent;
  final bool isDark;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          top: 92,
          left: -76,
          child: AnimatedContainer(
            duration: duration,
            width: 176,
            height: 176,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: isDark ? 0.06 : 0.08),
              shape: BoxShape.circle,
            ),
          ),
        ),
        Positioned(
          top: 286,
          right: -54,
          child: AnimatedContainer(
            duration: duration,
            width: 142,
            height: 142,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: isDark ? 0.05 : 0.065),
              shape: BoxShape.circle,
            ),
          ),
        ),
        Positioned(
          top: 545,
          left: 22,
          child: Icon(
            Icons.circle,
            size: 11,
            color: accent.withValues(alpha: isDark ? 0.16 : 0.22),
          ),
        ),
        Positioned(
          top: 610,
          right: 24,
          child: Icon(
            Icons.auto_awesome_rounded,
            size: 20,
            color: accent.withValues(alpha: isDark ? 0.16 : 0.22),
          ),
        ),
      ],
    );
  }
}

class _StageBubble extends StatelessWidget {
  const _StageBubble({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _Sparkle extends StatelessWidget {
  const _Sparkle({
    super.key,
    required this.color,
    required this.duration,
    required this.size,
  });

  final Color color;
  final Duration duration;
  final double size;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.35, end: 1),
      duration: duration,
      curve: Curves.elasticOut,
      builder: (context, value, child) {
        return Transform.rotate(
          angle: (1 - value) * -0.6,
          child: Transform.scale(scale: value, child: child),
        );
      },
      child: Icon(Icons.auto_awesome_rounded, color: color, size: size),
    );
  }
}

OutlineInputBorder _inputBorder(
  BuildContext context, {
  Color? color,
  double width = 1,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return OutlineInputBorder(
    borderRadius: BorderRadius.circular(17),
    borderSide: BorderSide(
      color:
          color ??
          (isDark
              ? Colors.white.withValues(alpha: 0.13)
              : const Color(0xFF243133).withValues(alpha: 0.12)),
      width: width,
    ),
  );
}

Color _primaryText(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFFF8F3EF)
      : const Color(0xFF20292D);
}

Color _secondaryText(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFFBAC3C0)
      : const Color(0xFF66716E);
}

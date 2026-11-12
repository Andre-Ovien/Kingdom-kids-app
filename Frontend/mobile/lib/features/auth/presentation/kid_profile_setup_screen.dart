import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/router.dart';
import '../../../core/errors/app_exception.dart';
import '../../../shared/audio/app_audio_scope.dart';
import '../../../shared/audio/app_sound_cue.dart';
import '../data/auth_repository.dart';
import '../domain/auth_requests.dart';
import '../domain/kid_profile.dart';
import 'spotlight_character.dart';
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

class _KidProfileSetupScreenState extends State<KidProfileSetupScreen>
    with SingleTickerProviderStateMixin {
  final _pages = PageController();
  late final AnimationController _approach;
  bool _enteringName = false;
  bool _reduceMotion = false;
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
    _approach = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );
  }

  @override
  void dispose() {
    _approach.dispose();
    _pages.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
  }

  void _selectAvatar(String avatarKey) {
    if (_isSaving || _enteringName || avatarKey == _selectedAvatarKey) return;
    final index = kidProfileCharacterOptions.indexWhere(
      (o) => o.key == avatarKey,
    );
    if (_reduceMotion) {
      _pages.jumpToPage(index);
    } else {
      _pages.animateToPage(
        index,
        duration: const Duration(milliseconds: 480),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  void _chooseBuddy() {
    if (_enteringName) return;
    AppAudioScope.maybeOf(context)?.playEffect(AppSoundCue.select);
    HapticFeedback.selectionClick();
    setState(() {
      _enteringName = true;
      _errorMessage = null;
    });
    if (_reduceMotion) {
      _approach.value = 1;
    } else {
      _approach.forward();
    }
  }

  void _backToCast() {
    if (_isSaving) return;
    AppAudioScope.maybeOf(context)?.playEffect(AppSoundCue.tap);
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _enteringName = false;
      _errorMessage = null;
    });
    if (_reduceMotion) {
      _approach.value = 0;
    } else {
      _approach.reverse();
    }
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
      final audio = AppAudioScope.maybeOf(context);
      Navigator.of(context).pushNamedAndRemoveUntil(
        AppRoutes.profilePicker,
        (_) => false,
        arguments: [...widget.existingProfiles, profile],
      );
      // Celebrate the confirmed save after the picker owns the route. The
      // controller still rejects muted, background or playback destinations.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        audio?.playEffect(AppSoundCue.success);
      });
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
    final option = kidAvatarOptionFor(_selectedAvatarKey);
    final palette = _StoryBuddyPalette.forAvatar(_selectedAvatarKey);
    final selectedIndex = kidProfileCharacterOptions.indexWhere(
      (buddy) => buddy.key == _selectedAvatarKey,
    );
    return PopScope(
      canPop: !_enteringName && !_isSaving,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _enteringName) _backToCast();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        backgroundColor: palette.backgroundBottom,
        body: Stack(
          children: [
            Positioned.fill(
              child: AnimatedContainer(
                duration: _reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 550),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [palette.backgroundTop, palette.backgroundBottom],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: const _SpotlightPainter()),
              ),
            ),
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 20, 0),
                    child: Row(
                      children: [
                        SizedBox.square(
                          dimension: 48,
                          child: _enteringName || Navigator.of(context).canPop()
                              ? IconButton(
                                  key: const Key('story-buddy-back'),
                                  tooltip: _enteringName
                                      ? 'Choose another buddy'
                                      : 'Back',
                                  color: palette.ink,
                                  onPressed: _isSaving
                                      ? null
                                      : () {
                                          if (_enteringName) {
                                            _backToCast();
                                          } else {
                                            Navigator.of(context).maybePop();
                                          }
                                        },
                                  icon: const Icon(Icons.arrow_back_rounded),
                                )
                              : null,
                        ),
                        Expanded(
                          child: Text(
                            _enteringName
                                ? 'Make it their adventure'
                                : 'Choose their story buddy',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: palette.ink,
                              fontSize: 21,
                              fontWeight: FontWeight.w500,
                              height: 1.2,
                              letterSpacing: -0.3,
                            ),
                          ),
                        ),
                        const SizedBox(width: 28),
                      ],
                    ),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final textScale = MediaQuery.textScalerOf(
                          context,
                        ).scale(1);
                        final stackedFooter =
                            textScale > 1.3 || constraints.maxWidth < 350;
                        final footerHeight = math.min(
                          constraints.maxHeight * (stackedFooter ? 0.78 : 0.48),
                          (stackedFooter ? 197.0 : 128.0) +
                              math.max(0, textScale - 1) * 120,
                        );
                        return Stack(
                          children: [
                            AnimatedBuilder(
                              animation: _approach,
                              builder: (context, child) => Positioned.fill(
                                bottom:
                                    footerHeight *
                                    (1 -
                                        Curves.easeInOutCubic.transform(
                                          _approach.value,
                                        )),
                                child: child!,
                              ),
                              child: IgnorePointer(
                                ignoring: _enteringName,
                                child: PageView.builder(
                                  key: const Key('story-buddy-cast'),
                                  controller: _pages,
                                  itemCount: kidProfileCharacterOptions.length,
                                  onPageChanged: (index) {
                                    final avatarKey =
                                        kidProfileCharacterOptions[index].key;
                                    if (avatarKey == _selectedAvatarKey) return;
                                    AppAudioScope.maybeOf(
                                      context,
                                    )?.playEffect(AppSoundCue.select);
                                    HapticFeedback.selectionClick();
                                    setState(
                                      () => _selectedAvatarKey = avatarKey,
                                    );
                                  },
                                  itemBuilder: (context, index) =>
                                      SpotlightCharacter(
                                        key: ValueKey(
                                          kidProfileCharacterOptions[index].key,
                                        ),
                                        avatarKey:
                                            kidProfileCharacterOptions[index]
                                                .key,
                                        approach: _approach,
                                      ),
                                ),
                              ),
                            ),
                            if (!_enteringName)
                              Positioned(
                                bottom: 0,
                                left: 0,
                                right: 0,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    24,
                                    8,
                                    24,
                                    10,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Flex(
                                        direction: stackedFooter
                                            ? Axis.vertical
                                            : Axis.horizontal,
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment: stackedFooter
                                            ? CrossAxisAlignment.start
                                            : CrossAxisAlignment.center,
                                        children: [
                                          Flexible(
                                            fit: stackedFooter
                                                ? FlexFit.loose
                                                : FlexFit.tight,
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  'Meet ${option.label}',
                                                  style: TextStyle(
                                                    color: palette.ink,
                                                    fontSize: 30,
                                                    height: 1.1,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                const SizedBox(height: 7),
                                                Text(
                                                  option.tagline,
                                                  style: TextStyle(
                                                    color: palette.secondaryInk,
                                                    fontSize: 14,
                                                    height: 1.25,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          SizedBox(
                                            width: stackedFooter ? 0 : 12,
                                            height: stackedFooter ? 12 : 0,
                                          ),
                                          DecoratedBox(
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                                colors: [
                                                  Color.lerp(
                                                    palette.accent,
                                                    Colors.white,
                                                    0.12,
                                                  )!,
                                                  palette.accent,
                                                ],
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: palette.accent
                                                      .withValues(alpha: 0.24),
                                                  blurRadius: 18,
                                                  offset: const Offset(0, 7),
                                                ),
                                              ],
                                            ),
                                            child: FilledButton(
                                              key: const Key(
                                                'select-story-buddy',
                                              ),
                                              onPressed: _isSaving
                                                  ? null
                                                  : _chooseBuddy,
                                              style: FilledButton.styleFrom(
                                                backgroundColor:
                                                    Colors.transparent,
                                                foregroundColor: Colors.white,
                                                minimumSize: const Size(
                                                  126,
                                                  56,
                                                ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 18,
                                                    ),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(20),
                                                  side: BorderSide(
                                                    color: Colors.white
                                                        .withValues(alpha: 0.3),
                                                  ),
                                                ),
                                                textStyle: const TextStyle(
                                                  fontWeight: FontWeight.w800,
                                                  fontSize: 16,
                                                ),
                                              ),
                                              child: const Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.auto_awesome_rounded,
                                                    size: 17,
                                                  ),
                                                  SizedBox(width: 8),
                                                  Text('Select'),
                                                  SizedBox(width: 4),
                                                  Icon(
                                                    Icons.chevron_right_rounded,
                                                    size: 21,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 28),
                                      _StoryBuddyNavigation(
                                        selectedIndex: selectedIndex,
                                        count:
                                            kidProfileCharacterOptions.length,
                                        palette: palette,
                                        reduceMotion: _reduceMotion,
                                        onSelect: _isSaving
                                            ? null
                                            : (index) => _selectAvatar(
                                                kidProfileCharacterOptions[index]
                                                    .key,
                                              ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            if (_enteringName)
                              Positioned(
                                bottom: 0,
                                left: 0,
                                right: 0,
                                child: AnimatedBuilder(
                                  animation: _approach,
                                  builder: (context, child) {
                                    final reveal = _reduceMotion
                                        ? 1.0
                                        : const Interval(
                                            0.35,
                                            1,
                                            curve: Curves.easeOutCubic,
                                          ).transform(_approach.value);
                                    return IgnorePointer(
                                      ignoring: reveal < 0.95,
                                      child: Opacity(
                                        opacity: reveal,
                                        child: Transform.translate(
                                          offset: Offset(0, 45 * (1 - reveal)),
                                          child: child,
                                        ),
                                      ),
                                    );
                                  },
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxHeight: constraints.maxHeight * 0.64,
                                    ),
                                    child: SingleChildScrollView(
                                      keyboardDismissBehavior:
                                          ScrollViewKeyboardDismissBehavior
                                              .onDrag,
                                      padding: const EdgeInsets.fromLTRB(
                                        24,
                                        28,
                                        24,
                                        20,
                                      ),
                                      child: Form(
                                        key: _formKey,
                                        child: Container(
                                          padding: const EdgeInsets.all(20),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFFEFDFC),
                                            borderRadius: BorderRadius.circular(
                                              28,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: palette.accent
                                                    .withValues(alpha: 0.16),
                                                blurRadius: 28,
                                                offset: Offset(0, 12),
                                              ),
                                            ],
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                'What should we call them?',
                                                style: TextStyle(
                                                  color: palette.ink,
                                                  fontSize: 22,
                                                  height: 1.2,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                              const SizedBox(height: 18),
                                              TextFormField(
                                                key: const Key(
                                                  'kid-profile-name-field',
                                                ),
                                                controller: _nameController,
                                                enabled: !_isSaving,
                                                textCapitalization:
                                                    TextCapitalization.words,
                                                textInputAction:
                                                    TextInputAction.done,
                                                onFieldSubmitted: (_) =>
                                                    _createProfile(),
                                                cursorColor: palette.accent,
                                                style: TextStyle(
                                                  color: palette.ink,
                                                  fontSize: 16,
                                                ),
                                                decoration: InputDecoration(
                                                  labelText: 'Display name',
                                                  labelStyle: TextStyle(
                                                    color: palette.secondaryInk,
                                                  ),
                                                  hintText:
                                                      'Their name or nickname',
                                                  filled: true,
                                                  fillColor: Colors.white,
                                                  border: OutlineInputBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          16,
                                                        ),
                                                  ),
                                                  enabledBorder:
                                                      OutlineInputBorder(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              16,
                                                            ),
                                                        borderSide:
                                                            const BorderSide(
                                                              color: Color(
                                                                0xFFDACDDA,
                                                              ),
                                                            ),
                                                      ),
                                                  focusedBorder:
                                                      OutlineInputBorder(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              16,
                                                            ),
                                                        borderSide: BorderSide(
                                                          color: palette.accent,
                                                          width: 2,
                                                        ),
                                                      ),
                                                ),
                                                validator: (value) {
                                                  final name =
                                                      value?.trim() ?? '';
                                                  if (name.length < 2) {
                                                    return 'Choose a name with at least 2 letters.';
                                                  }
                                                  if (name.length > 30) {
                                                    return 'Keep the name to 30 characters or fewer.';
                                                  }
                                                  return null;
                                                },
                                              ),
                                              if (_errorMessage != null) ...[
                                                const SizedBox(height: 12),
                                                Text(
                                                  _errorMessage!,
                                                  style: const TextStyle(
                                                    color: Color(0xFFAB3349),
                                                  ),
                                                ),
                                              ],
                                              const SizedBox(height: 16),
                                              FilledButton(
                                                key: const Key(
                                                  'create-kid-profile-button',
                                                ),
                                                onPressed: _isSaving
                                                    ? null
                                                    : _createProfile,
                                                style: FilledButton.styleFrom(
                                                  backgroundColor:
                                                      palette.accent,
                                                  foregroundColor: Colors.white,
                                                  minimumSize:
                                                      const Size.fromHeight(54),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          16,
                                                        ),
                                                  ),
                                                ),
                                                child: _isSaving
                                                    ? const SizedBox.square(
                                                        dimension: 20,
                                                        child:
                                                            CircularProgressIndicator(
                                                              strokeWidth: 2,
                                                              color:
                                                                  Colors.white,
                                                            ),
                                                      )
                                                    : const Text(
                                                        'Start the adventure',
                                                      ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
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

class _StoryBuddyPalette {
  const _StoryBuddyPalette({
    required this.backgroundTop,
    required this.backgroundBottom,
    required this.accent,
    required this.ink,
    required this.secondaryInk,
  });

  final Color backgroundTop;
  final Color backgroundBottom;
  final Color accent;
  final Color ink;
  final Color secondaryInk;

  static _StoryBuddyPalette forAvatar(String avatarKey) => switch (avatarKey) {
    'dove' => const _StoryBuddyPalette(
      backgroundTop: Color(0xFFF3ECFF),
      backgroundBottom: Color(0xFFCAB5F7),
      accent: Color(0xFF6F41A7),
      ink: Color(0xFF34224E),
      secondaryInk: Color(0xFF635176),
    ),
    'rainbow' => const _StoryBuddyPalette(
      backgroundTop: Color(0xFFFFF0E9),
      backgroundBottom: Color(0xFFFFBBCB),
      accent: Color(0xFF9F3D5C),
      ink: Color(0xFF4F2834),
      secondaryInk: Color(0xFF79515C),
    ),
    _ => const _StoryBuddyPalette(
      backgroundTop: Color(0xFFE9FFF2),
      backgroundBottom: Color(0xFF98E6B7),
      accent: Color(0xFF166A48),
      ink: Color(0xFF183E2D),
      secondaryInk: Color(0xFF456851),
    ),
  };
}

class _StoryBuddyNavigation extends StatelessWidget {
  const _StoryBuddyNavigation({
    required this.selectedIndex,
    required this.count,
    required this.palette,
    required this.reduceMotion,
    required this.onSelect,
  });

  final int selectedIndex;
  final int count;
  final _StoryBuddyPalette palette;
  final bool reduceMotion;
  final ValueChanged<int>? onSelect;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Semantics(
        key: const Key('story-buddy-page-indicator'),
        label: 'Story buddy ${selectedIndex + 1} of $count',
        liveRegion: true,
        container: true,
        explicitChildNodes: true,
        child: SizedBox(
          width: 24 + (count - 1) * 14.0,
          height: 24,
          // Transparent touch areas overlap to keep the visible dots together.
          child: Stack(
            children: [
              for (var index = 0; index < count; index++)
                Positioned(
                  left: index * 14.0,
                  width: 24,
                  height: 24,
                  child: Semantics(
                    key: ValueKey('story-buddy-page-$index'),
                    label: 'Choose story buddy ${index + 1} of $count',
                    button: true,
                    selected: index == selectedIndex,
                    enabled: onSelect != null,
                    onTap: onSelect == null ? null : () => onSelect!(index),
                    child: GestureDetector(
                      excludeFromSemantics: true,
                      behavior: HitTestBehavior.opaque,
                      onTap: onSelect == null ? null : () => onSelect!(index),
                      child: SizedBox.square(
                        dimension: 24,
                        child: Center(
                          child: AnimatedContainer(
                            duration: reduceMotion
                                ? Duration.zero
                                : const Duration(milliseconds: 250),
                            curve: Curves.easeOutCubic,
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: palette.accent.withValues(
                                alpha: index == selectedIndex ? 1 : 0.24,
                              ),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
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

class _SpotlightPainter extends CustomPainter {
  const _SpotlightPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final beam = Path()
      ..moveTo(size.width * 0.43, -30)
      ..lineTo(size.width * 0.04, size.height * 0.8)
      ..quadraticBezierTo(
        size.width / 2,
        size.height * 0.97,
        size.width * 0.96,
        size.height * 0.8,
      )
      ..lineTo(size.width * 0.57, -30)
      ..close();
    canvas.drawPath(
      beam,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x99FFFFFF), Color(0x12FFFFFF)],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter oldDelegate) => false;
}

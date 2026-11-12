import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/errors/app_exception.dart';
import '../data/auth_repository.dart';
import '../domain/auth_requests.dart';
import '../domain/auth_session.dart';
import '../domain/email_verification.dart';
import 'auth_wave_header.dart';

enum AuthScreenMode { register, login }

/// Parent-only authentication. A child profile is created in the next step and
/// never asks a child for an email address or password.
class AuthScreen extends StatefulWidget {
  const AuthScreen({
    super.key,
    this.initialMode = AuthScreenMode.register,
    this.repository,
    this.externalUrlLauncher,
  });

  final AuthScreenMode initialMode;
  final AuthRepository? repository;
  final Future<bool> Function(Uri uri)? externalUrlLauncher;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {
  var _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _emailFocusNode = FocusNode(debugLabel: 'auth-email');
  final _passwordFocusNode = FocusNode(debugLabel: 'auth-password');
  final _confirmPasswordFocusNode = FocusNode(
    debugLabel: 'auth-confirm-password',
  );
  final _formScrollController = ScrollController();

  late final AuthRepository _repository;
  late final AnimationController _modeController;
  late AuthScreenMode _mode;
  bool _isSubmitting = false;
  bool _showPassword = false;
  bool _showConfirmPassword = false;
  bool _reduceMotion = false;
  int _submissionGeneration = 0;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? AuthRepository();
    _mode = widget.initialMode;
    _modeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 680),
      value: _mode == AuthScreenMode.register ? 1 : 0,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.of(context).disableAnimations;
    if (_reduceMotion) {
      _modeController.value = _mode == AuthScreenMode.register ? 1 : 0;
    }
  }

  @override
  void dispose() {
    _submissionGeneration++;
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    _confirmPasswordFocusNode.dispose();
    _formScrollController.dispose();
    _modeController.dispose();
    super.dispose();
  }

  void _changeMode(AuthScreenMode mode) {
    if (mode == _mode || _isSubmitting) return;
    FocusManager.instance.primaryFocus?.unfocus();
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    setState(() {
      _mode = mode;
      _formKey = GlobalKey<FormState>();
    });
    final target = mode == AuthScreenMode.register ? 1.0 : 0.0;
    if (_reduceMotion) {
      _modeController.value = target;
    } else {
      _modeController.animateTo(
        target,
        duration: Duration(
          milliseconds: (680 * (target - _modeController.value).abs()).round(),
        ),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  Future<void> _submit() async {
    if (_isSubmitting || _modeController.isAnimating) {
      return;
    }

    FocusManager.instance.primaryFocus?.unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    final generation = ++_submissionGeneration;
    final submittedMode = _mode;
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    setState(() => _isSubmitting = true);

    try {
      if (_mode == AuthScreenMode.register) {
        final pending = await _withVisibleBusyInterval(
          _repository.register(
            RegisterParentRequest(
              email: _emailController.text,
              password: _passwordController.text,
            ),
          ),
        );
        if (_canPresentSubmission(generation, submittedMode)) {
          _openVerification(pending);
        }
        return;
      }

      final session = await _withVisibleBusyInterval(
        _repository.login(
          LoginRequest(
            email: _emailController.text,
            password: _passwordController.text,
          ),
        ),
      );

      if (!_canPresentSubmission(generation, submittedMode)) {
        return;
      }
      _continueToProfiles(session);
    } on AppException catch (error) {
      if (_canPresentSubmission(generation, submittedMode) &&
          error.code == 'email_verification_required' &&
          _openVerificationFromError(error)) {
        return;
      }
      if (_canPresentSubmission(generation, submittedMode)) {
        _showSubmissionError(error.userMessage);
      }
    } catch (_) {
      if (_canPresentSubmission(generation, submittedMode)) {
        _showSubmissionError('Something went wrong. Please try again.');
      }
    } finally {
      if (mounted && generation == _submissionGeneration) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<T> _withVisibleBusyInterval<T>(Future<T> request) async {
    late T result;
    // Run the minimum interval concurrently: slow requests get no extra delay.
    // Future.wait also waits for it when a fast request fails.
    await Future.wait<void>([
      request.then<void>((value) => result = value),
      Future<void>.delayed(const Duration(milliseconds: 600)),
    ]);
    return result;
  }

  bool _canPresentSubmission(int generation, AuthScreenMode mode) =>
      mounted &&
      generation == _submissionGeneration &&
      mode == _mode &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  void _showSubmissionError(String message) {
    final palette = _AuthPalette.forMode(
      _mode,
      isDark: Theme.of(context).brightness == Brightness.dark,
    );
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: palette.errorBackground,
          content: Text(
            message,
            style: TextStyle(
              fontFamily: 'OnboardingPoppins',
              color: palette.errorText,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ),
      );
  }

  void _openVerification(PendingEmailVerification pending) {
    Navigator.of(
      context,
    ).pushNamed(AppRoutes.emailVerification, arguments: pending);
  }

  bool _openVerificationFromError(AppException error) {
    final pending = PendingEmailVerification.fromJson(
      error.details,
      fallbackEmail: _emailController.text.trim().toLowerCase(),
    );
    if (pending.challengeId.isEmpty ||
        (pending.destinationHint.isEmpty && pending.email.isEmpty)) {
      return false;
    }
    _openVerification(pending);
    return true;
  }

  void _continueToProfiles(AuthSession session) {
    Navigator.of(context).pushNamedAndRemoveUntil(
      session.hasProfiles ? AppRoutes.profilePicker : AppRoutes.kidProfileSetup,
      (_) => false,
      arguments: session.profiles,
    );
  }

  Future<void> _openPrivacyPolicy() async {
    final uri = Uri.parse(AppConstants.privacyPolicyUrl);
    try {
      final opened =
          await (widget.externalUrlLauncher?.call(uri) ??
              launchUrl(uri, mode: LaunchMode.externalApplication));
      if (!opened && mounted) {
        _showPrivacyError();
      }
    } catch (_) {
      if (mounted) _showPrivacyError();
    }
  }

  void _showPrivacyError() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('We could not open the privacy policy on this device.'),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = _AuthPalette.forMode(_mode, isDark: isDark);
    final media = MediaQuery.of(context);
    final keyboardOpen = media.viewInsets.bottom > 0;
    final textScale = media.textScaler.scale(14) / 14;
    // The keyboard reduces Scaffold's body constraints, not the physical page.
    // Keep the approved header and text density tied to the full viewport.
    final fullHeight = media.size.height;
    final compact =
        fullHeight - media.viewPadding.vertical < 650 || textScale > 1.3;
    final bottomInset = keyboardOpen ? 0.0 : media.viewPadding.bottom;
    return Scaffold(
      backgroundColor: palette.background,
      body: AnimatedBuilder(
        animation: _modeController,
        builder: (context, _) => LayoutBuilder(
          builder: (context, constraints) {
            final progress = _modeController.value;
            final headerHeight = compact
                ? media.viewPadding.top +
                      math.max(48.0, media.textScaler.scale(26) * 1.2 + 16)
                : math.min(328.0, fullHeight * 0.39) * (1 - progress) +
                      math.min(210.0, fullHeight * 0.25) * progress;
            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: headerHeight,
                  child: AuthWaveHeader(
                    progress: progress,
                    height: headerHeight,
                    topInset: media.viewPadding.top,
                    compact: compact,
                    color: palette.action,
                  ),
                ),
                Positioned(
                  top: headerHeight,
                  left: 0,
                  right: 0,
                  bottom: bottomInset,
                  child: Transform.translate(
                    offset: Offset(
                      0,
                      _reduceMotion ? 0 : 8 * math.sin(progress * math.pi),
                    ),
                    // Never swap this viewport or its autofill/form subtree
                    // when IME metrics change. Disposing AutofillGroup ends
                    // the iOS autofill context and resigns first responder.
                    child: SingleChildScrollView(
                      key: const Key('auth-form-scroll'),
                      controller: _formScrollController,
                      primary: false,
                      physics: const ClampingScrollPhysics(),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.manual,
                      padding: EdgeInsets.fromLTRB(
                        24,
                        compact ? 4 : 32,
                        24,
                        compact ? 6 : 8,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 430),
                          child: _buildForm(palette, progress, compact),
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
    );
  }

  Widget _buildForm(_AuthPalette palette, double progress, bool compact) {
    final gap = compact ? 4.0 : 10.0;
    final registering = _mode == AuthScreenMode.register;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ModeCaption(
          progress: progress,
          compact: compact,
          color: palette.foreground,
        ),
        SizedBox(height: compact ? 10 : 28),
        AutofillGroup(
          key: const Key('auth-autofill-group'),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _AuthTextField(
                  key: const Key('auth-email-field'),
                  controller: _emailController,
                  focusNode: _emailFocusNode,
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) => _passwordFocusNode.requestFocus(),
                  palette: palette,
                  compact: true,
                  label: 'Email address',
                  hint: 'you@example.com',
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  validator: _validateEmail,
                ),
                SizedBox(height: gap),
                _AuthTextField(
                  key: const Key('auth-password-field'),
                  controller: _passwordController,
                  focusNode: _passwordFocusNode,
                  textInputAction: registering
                      ? TextInputAction.next
                      : TextInputAction.done,
                  palette: palette,
                  compact: true,
                  label: 'Password',
                  hint: registering ? 'At least 8 characters' : 'Your password',
                  obscureText: !_showPassword,
                  autofillHints: [
                    registering
                        ? AutofillHints.newPassword
                        : AutofillHints.password,
                  ],
                  suffixIcon: IconButton(
                    tooltip: _showPassword ? 'Hide password' : 'Show password',
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                    icon: Icon(
                      _showPassword
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                    ),
                  ),
                  validator: _validatePassword,
                  onFieldSubmitted: (_) {
                    if (registering) {
                      _confirmPasswordFocusNode.requestFocus();
                    } else {
                      _submit();
                    }
                  },
                ),
                if (progress < 1)
                  ClipRect(
                    key: const Key('auth-forgot-password-slot'),
                    child: Align(
                      alignment: Alignment.topCenter,
                      heightFactor: 1 - progress,
                      child: Opacity(
                        opacity: 1 - progress,
                        child: IgnorePointer(
                          ignoring: registering,
                          child: ExcludeSemantics(
                            excluding: registering,
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                key: const Key('auth-forgot-password'),
                                onPressed: _isSubmitting
                                    ? null
                                    : () => Navigator.of(
                                        context,
                                      ).pushNamed(AppRoutes.passwordReset),
                                style: TextButton.styleFrom(
                                  foregroundColor: palette.action,
                                  minimumSize: const Size(48, 44),
                                ),
                                child: const Text(
                                  'Forgot password?',
                                  style: TextStyle(
                                    fontFamily: 'OnboardingPoppins',
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (progress > 0)
                  ClipRect(
                    key: const Key('auth-confirm-password-slot'),
                    child: Align(
                      alignment: Alignment.topCenter,
                      heightFactor: progress,
                      child: Opacity(
                        opacity: progress,
                        child: IgnorePointer(
                          ignoring: !registering,
                          child: ExcludeSemantics(
                            excluding: !registering,
                            child: Padding(
                              padding: EdgeInsets.only(top: gap),
                              child: _AuthTextField(
                                key: const Key('auth-confirm-password-field'),
                                controller: _confirmPasswordController,
                                focusNode: _confirmPasswordFocusNode,
                                textInputAction: TextInputAction.done,
                                palette: palette,
                                compact: true,
                                label: 'Confirm password',
                                hint: 'One more time',
                                obscureText: !_showConfirmPassword,
                                autofillHints: const [
                                  AutofillHints.newPassword,
                                ],
                                suffixIcon: IconButton(
                                  tooltip: _showConfirmPassword
                                      ? 'Hide password'
                                      : 'Show password',
                                  onPressed: () => setState(
                                    () => _showConfirmPassword =
                                        !_showConfirmPassword,
                                  ),
                                  icon: Icon(
                                    _showConfirmPassword
                                        ? Icons.visibility_off_rounded
                                        : Icons.visibility_rounded,
                                  ),
                                ),
                                validator: (value) {
                                  if (!registering) return null;
                                  if (value == null || value.isEmpty) {
                                    return 'Please confirm your password.';
                                  }
                                  return value != _passwordController.text
                                      ? 'Those passwords do not match.'
                                      : null;
                                },
                                onFieldSubmitted: (_) => _submit(),
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
        SizedBox(height: compact ? 8 : 14),
        FilledButton(
          key: const Key('auth-submit-button'),
          style:
              FilledButton.styleFrom(
                backgroundColor: palette.action,
                foregroundColor: palette.onAction,
                disabledBackgroundColor: palette.action,
                disabledForegroundColor: palette.onAction,
                overlayColor: Colors.transparent,
                splashFactory: NoSplash.splashFactory,
                elevation: 0,
                shadowColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                textStyle: const TextStyle(
                  fontFamily: 'OnboardingPoppins',
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ).copyWith(
                side: WidgetStateProperty.resolveWith(
                  (states) =>
                      states.contains(WidgetState.focused) &&
                          FocusManager.instance.highlightMode ==
                              FocusHighlightMode.traditional
                      ? BorderSide(color: palette.onAction, width: 2)
                      : BorderSide.none,
                ),
              ),
          onPressed: _isSubmitting || _modeController.isAnimating
              ? null
              : _submit,
          child: _isSubmitting
              ? SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: palette.onAction,
                  ),
                )
              : Semantics(
                  label: registering ? 'Sign up' : 'Sign in',
                  excludeSemantics: true,
                  child: AuthModeWordmark(
                    progress: progress,
                    signInSuffix: 'in',
                    signUpSuffix: 'up',
                    gap: MediaQuery.textScalerOf(context).scale(4),
                    signKey: const Key('auth-submit-sign-label'),
                    suffixKey: const Key('auth-submit-suffix-viewport'),
                    style: TextStyle(
                      fontFamily: 'OnboardingPoppins',
                      color: palette.onAction,
                      fontSize: 15,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
        ),
        _AuthPrivacyPolicyLink(
          mode: _mode,
          palette: palette,
          onPressed: _isSubmitting ? null : _openPrivacyPolicy,
        ),
        _InlineModeLink(mode: _mode, palette: palette, onChanged: _changeMode),
        const SizedBox(height: 4),
        _ParentSafetyNote(palette: palette, compact: true),
      ],
    );
  }

  String? _validateEmail(String? value) {
    final email = value?.trim() ?? '';
    if (email.isEmpty) {
      return 'Please enter your email address.';
    }
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      return 'Enter a valid email address.';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter your password.';
    }
    if (_mode == AuthScreenMode.register && value.length < 8) {
      return 'Use at least 8 characters.';
    }
    return null;
  }
}

class _AuthPalette {
  const _AuthPalette({
    required this.background,
    required this.foreground,
    required this.muted,
    required this.fieldFill,
    required this.fieldText,
    required this.fieldHint,
    required this.focus,
    required this.action,
    required this.onAction,
    required this.errorBackground,
    required this.errorText,
  });
  factory _AuthPalette.forMode(AuthScreenMode mode, {required bool isDark}) =>
      isDark
      ? const _AuthPalette(
          background: Color(0xFF111C35),
          foreground: Color(0xFFF2F6FF),
          muted: Color(0xFFB0BED7),
          fieldFill: Color(0xFF1C2D4C),
          fieldText: Color(0xFFF2F6FF),
          fieldHint: Color(0xFFA9BAD8),
          focus: Color(0xFF84ADFF),
          action: Color(0xFF1457FF),
          onAction: Colors.white,
          errorBackground: Color(0xFF4C2738),
          errorText: Color(0xFFFFC8D4),
        )
      : const _AuthPalette(
          background: Color(0xFFF3F6FD),
          foreground: Color(0xFF23375B),
          muted: Color(0xFF6C7C99),
          fieldFill: Colors.white,
          fieldText: Color(0xFF23375B),
          fieldHint: Color(0xFF6C7C99),
          focus: Color(0xFF1457FF),
          action: Color(0xFF1457FF),
          onAction: Colors.white,
          errorBackground: Color(0xFFFFEBEF),
          errorText: Color(0xFFA3334E),
        );
  final Color background,
      foreground,
      muted,
      fieldFill,
      fieldText,
      fieldHint,
      focus,
      action,
      onAction,
      errorBackground,
      errorText;
}

class _ModeCaption extends StatelessWidget {
  const _ModeCaption({
    required this.progress,
    required this.compact,
    required this.color,
  });
  final double progress;
  final bool compact;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: 'OnboardingPoppins',
      fontSize: compact ? 21 : 25,
      height: 1.2,
      fontWeight: FontWeight.w600,
      color: color,
      letterSpacing: -0.5,
    );
    return SizedBox(
      height: MediaQuery.textScalerOf(context).scale(compact ? 26 : 31),
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (progress < 1)
            Opacity(
              opacity: (1 - 2 * progress).clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(0, -8 * progress),
                child: Text('Welcome back!', style: style),
              ),
            ),
          if (progress > 0)
            Opacity(
              opacity: (2 * progress - 1).clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(0, 8 * (1 - progress)),
                child: Text('Hey, welcome!', style: style),
              ),
            ),
        ],
      ),
    );
  }
}

class _AuthPrivacyPolicyLink extends StatelessWidget {
  const _AuthPrivacyPolicyLink({
    required this.mode,
    required this.palette,
    required this.onPressed,
  });

  final AuthScreenMode mode;
  final _AuthPalette palette;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    const prefix = '';

    return TextButton(
      key: const Key('auth-privacy-policy'),
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: palette.foreground,
        minimumSize: const Size(48, 44),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: prefix,
              style: TextStyle(
                color: palette.muted,
                fontWeight: FontWeight.w500,
              ),
            ),
            TextSpan(
              text: 'Privacy policy',
              style: TextStyle(
                color: palette.foreground,
                fontWeight: FontWeight.w800,
                decoration: TextDecoration.underline,
                decorationColor: palette.foreground,
              ),
            ),
          ],
        ),
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontFamily: 'OnboardingPoppins',
          fontSize: 12,
          height: 1.3,
        ),
      ),
    );
  }
}

class _InlineModeLink extends StatelessWidget {
  const _InlineModeLink({
    required this.mode,
    required this.palette,
    required this.onChanged,
  });

  final AuthScreenMode mode;
  final _AuthPalette palette;
  final ValueChanged<AuthScreenMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final isRegister = mode == AuthScreenMode.register;
    final prefix = isRegister
        ? 'Already have an account? '
        : 'New to Kingdom Kids? ';
    final action = isRegister ? 'Sign in' : 'Sign up';

    return TextButton(
      key: const Key('auth-mode-link'),
      style:
          TextButton.styleFrom(
            foregroundColor: palette.foreground,
            overlayColor: Colors.transparent,
            splashFactory: NoSplash.splashFactory,
            elevation: 0,
            shadowColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            minimumSize: const Size(48, 44),
          ).copyWith(
            side: WidgetStateProperty.resolveWith(
              (states) =>
                  states.contains(WidgetState.focused) &&
                      FocusManager.instance.highlightMode ==
                          FocusHighlightMode.traditional
                  ? BorderSide(color: palette.focus, width: 1.5)
                  : BorderSide.none,
            ),
          ),
      onPressed: () => onChanged(
        isRegister ? AuthScreenMode.login : AuthScreenMode.register,
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: prefix,
              style: TextStyle(
                color: palette.muted,
                fontWeight: FontWeight.w500,
              ),
            ),
            TextSpan(
              text: action,
              style: TextStyle(
                color: palette.foreground,
                fontWeight: FontWeight.w900,
                decoration: TextDecoration.underline,
                decorationColor: palette.foreground,
              ),
            ),
          ],
        ),
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontFamily: 'OnboardingPoppins',
          fontSize: 12.5,
          height: 1.3,
        ),
      ),
    );
  }
}

class _AuthTextField extends StatelessWidget {
  const _AuthTextField({
    super.key,
    required this.controller,
    this.focusNode,
    this.compact = false,
    required this.palette,
    required this.label,
    required this.hint,
    this.keyboardType,
    this.autofillHints,
    this.obscureText = false,
    this.suffixIcon,
    this.validator,
    this.onFieldSubmitted,
    this.textInputAction = TextInputAction.next,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool compact;
  final _AuthPalette palette;
  final String label;
  final String hint;
  final TextInputType? keyboardType;
  final Iterable<String>? autofillHints;
  final bool obscureText;
  final Widget? suffixIcon;
  final FormFieldValidator<String>? validator;
  final ValueChanged<String>? onFieldSubmitted;
  final TextInputAction textInputAction;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      keyboardType: keyboardType,
      autofillHints: autofillHints,
      obscureText: obscureText,
      enableSuggestions: !obscureText,
      autocorrect: !obscureText,
      textInputAction: textInputAction,
      scrollPadding: const EdgeInsets.fromLTRB(8, 12, 8, 24),
      validator: validator,
      onFieldSubmitted: onFieldSubmitted,
      cursorColor: palette.focus,
      style: TextStyle(
        fontFamily: 'OnboardingPoppins',
        color: palette.fieldText,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      decoration: InputDecoration(
        labelText: label,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        suffixIcon: suffixIcon,
        suffixIconColor: palette.fieldHint,
        filled: false,
        labelStyle: TextStyle(
          fontFamily: 'OnboardingPoppins',
          fontSize: 14,
          height: 1.2,
          color: palette.fieldHint,
          fontWeight: FontWeight.w600,
        ),
        floatingLabelStyle: WidgetStateTextStyle.resolveWith(
          (states) => TextStyle(
            fontFamily: 'OnboardingPoppins',
            fontSize: 14,
            height: 1.2,
            color: states.contains(WidgetState.error)
                ? palette.errorText
                : palette.focus,
            fontWeight: FontWeight.w600,
          ),
        ),
        hintStyle: TextStyle(
          fontFamily: 'OnboardingPoppins',
          color: palette.fieldHint,
          fontWeight: FontWeight.w500,
        ),
        helperText: ' ',
        helperStyle: const TextStyle(
          fontFamily: 'OnboardingPoppins',
          fontSize: 11.5,
          height: 1.2,
        ),
        errorStyle: TextStyle(
          fontFamily: 'OnboardingPoppins',
          color: palette.errorText,
          fontSize: 11.5,
          height: 1.2,
          fontWeight: FontWeight.w500,
        ),
        errorMaxLines: 2,
        isDense: compact,
        contentPadding: EdgeInsets.symmetric(
          horizontal: 4,
          vertical: compact ? 0 : 12,
        ),
        border: _border(),
        enabledBorder: _border(),
        focusedBorder: _border(color: palette.focus, width: 2),
        errorBorder: _border(color: palette.errorText, width: 1.5),
        focusedErrorBorder: _border(color: palette.errorText, width: 2),
      ),
    );
  }

  UnderlineInputBorder _border({
    Color color = const Color(0xFFD8E2F4),
    double width = 1.2,
  }) {
    return UnderlineInputBorder(
      borderSide: BorderSide(color: color, width: width),
    );
  }
}

class _ParentSafetyNote extends StatelessWidget {
  const _ParentSafetyNote({required this.palette, this.compact = false});

  final _AuthPalette palette;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('auth-parent-safety-note'),
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: compact ? 4 : 12),
      decoration: BoxDecoration(
        color: palette.fieldFill.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline_rounded, color: palette.foreground, size: 17),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Only parents sign in. Kids use profiles—no child email or password.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'OnboardingPoppins',
                color: palette.muted,
                height: 1.35,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

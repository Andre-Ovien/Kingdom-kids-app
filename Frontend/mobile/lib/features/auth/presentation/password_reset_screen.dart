import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/app_route_observer.dart';
import '../../../app/router.dart';
import '../../../core/errors/app_exception.dart';
import '../data/auth_repository.dart';
import '../domain/auth_requests.dart';
import '../domain/password_reset.dart';
import 'verification_friend.dart';
import 'verification_page.dart';
import 'verification_primary_button.dart';

const passwordResetGenericRequestMessage =
    'If an eligible account exists for that email, a password reset code has been sent.';

enum _PasswordResetStage { request, verify, confirm }

class PasswordResetScreen extends StatefulWidget {
  const PasswordResetScreen({super.key, this.repository});

  final AuthRepository? repository;

  @override
  State<PasswordResetScreen> createState() => _PasswordResetScreenState();
}

class _PasswordResetScreenState extends State<PasswordResetScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver, RouteAware {
  final _requestFormKey = GlobalKey<FormState>();
  final _confirmFormKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _codeFocusNode = FocusNode();
  final _newPasswordFocusNode = FocusNode();
  final _confirmPasswordFocusNode = FocusNode();
  late final Listenable _passwordFocus;

  late final AuthRepository _repository;
  _PasswordResetStage _stage = _PasswordResetStage.request;
  PendingPasswordReset? _pending;
  Timer? _expiryTimer;
  DateTime? _expiresAt;
  int _secondsRemaining = 0;
  bool _isRequesting = false;
  bool _isVerifying = false;
  bool _isConfirming = false;
  bool _showNewPassword = false;
  bool _showConfirmation = false;
  String? _errorMessage;
  String? _verifiedCode;
  late final AnimationController _successBeat;
  ModalRoute<dynamic>? _observedRoute;
  int _verificationGeneration = 0;
  int _rejectionAttempt = 0;
  bool _codeVerified = false;
  bool _glidingToPassword = false;

  bool get _busy => _isRequesting || _isVerifying || _isConfirming;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _repository = widget.repository ?? AuthRepository();
    _successBeat = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      animationBehavior: AnimationBehavior.preserve,
    );
    _passwordFocus = Listenable.merge([
      _newPasswordFocusNode,
      _confirmPasswordFocusNode,
    ]);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncExpiryCountdown();
    } else {
      _cancelForRouteOrBackground();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _observedRoute)) {
      if (_observedRoute != null) appRouteObserver.unsubscribe(this);
      _observedRoute = route;
      if (route != null) appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() => _cancelForRouteOrBackground();

  void _cancelSuccessFeedback() {
    _verificationGeneration++;
    _successBeat.stop(canceled: true);
    _codeVerified = false;
    _glidingToPassword = false;
  }

  void _cancelForRouteOrBackground() {
    if (_codeVerified || _glidingToPassword) {
      _returnToCode(null);
    } else {
      _cancelSuccessFeedback();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _expiryTimer?.cancel();
    _verificationGeneration++;
    _successBeat.dispose();
    if (_observedRoute != null) appRouteObserver.unsubscribe(this);
    _clearInMemoryValues();
    _emailController.dispose();
    _codeController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    _codeFocusNode.dispose();
    _newPasswordFocusNode.dispose();
    _confirmPasswordFocusNode.dispose();
    super.dispose();
  }

  Future<void> _requestReset() async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (_requestFormKey.currentState?.validate() != true) return;

    setState(() {
      _isRequesting = true;
      _errorMessage = null;
    });
    try {
      final pending = await _repository.requestPasswordReset(
        PasswordResetRequest(email: _emailController.text),
      );
      if (!mounted) return;
      _emailController.text = _normalizedEmail(_emailController.text);
      _replaceChallenge(pending);
    } on AppException catch (error) {
      if (mounted) setState(() => _errorMessage = error.userMessage);
    } catch (_) {
      if (mounted) {
        setState(
          () => _errorMessage =
              'We could not start password recovery. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _isRequesting = false);
    }
  }

  Future<void> _requestAnotherCode() async {
    if (_busy) return;
    setState(() {
      _isRequesting = true;
      _errorMessage = null;
    });
    try {
      final pending = await _repository.requestPasswordReset(
        PasswordResetRequest(email: _emailController.text),
      );
      if (!mounted) return;
      _codeController.clear();
      _replaceChallenge(pending);
      _focusCodeOnNextFrame();
    } on AppException catch (error) {
      if (mounted) setState(() => _errorMessage = error.userMessage);
    } catch (_) {
      if (mounted) {
        setState(
          () => _errorMessage =
              'We could not request another code. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _isRequesting = false);
    }
  }

  Future<void> _verifyCode() async {
    if (_busy || _stage != _PasswordResetStage.verify) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (_secondsRemaining <= 0) {
      _returnToCode('This code has expired. Request another code to continue.');
      return;
    }
    final codeError = _validateCode(_codeController.text);
    if (codeError != null) {
      setState(() => _errorMessage = codeError);
      _focusCodeOnNextFrame();
      return;
    }
    final pending = _pending;
    if (pending == null) return;
    final code = _codeController.text;
    final generation = _verificationGeneration;
    setState(() {
      _isVerifying = true;
      _errorMessage = null;
    });
    try {
      await _repository.verifyPasswordResetCode(
        PasswordResetVerifyRequest(
          challengeId: pending.challengeId,
          code: code,
        ),
      );
      if (!mounted ||
          !_verificationIsCurrent(pending.challengeId, generation)) {
        return;
      }
      if (_secondsRemaining <= 0 ||
          _expiresAt == null ||
          !_expiresAt!.isAfter(DateTime.now())) {
        _returnToCode(
          'This code has expired. Request another code to continue.',
        );
        return;
      }
      setState(() {
        _codeVerified = true;
        _errorMessage = null;
      });
      await _successBeat.forward(from: 0).orCancel;
      if (!mounted ||
          !_verificationIsCurrent(pending.challengeId, generation)) {
        return;
      }
      if (_secondsRemaining <= 0 || !_expiresAt!.isAfter(DateTime.now())) {
        _returnToCode(
          'This code has expired. Request another code to continue.',
        );
        return;
      }
      final reduceMotion = MediaQuery.of(context).disableAnimations;
      setState(() {
        _verifiedCode = code;
        _glidingToPassword = !reduceMotion;
        _stage = _PasswordResetStage.confirm;
      });
      if (!reduceMotion) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      if (!mounted ||
          generation != _verificationGeneration ||
          _stage != _PasswordResetStage.confirm) {
        return;
      }
      setState(() {
        _glidingToPassword = false;
        _codeVerified = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _stage == _PasswordResetStage.confirm) {
          _newPasswordFocusNode.requestFocus();
        }
      });
    } on TickerCanceled {
      // Expiry, navigation and backgrounding cancel the success beat.
    } on AppException catch (error) {
      if (!_verificationIsCurrent(pending.challengeId, generation)) return;
      final rejectedCode = error.code == 'invalid_or_expired_password_reset';
      if (rejectedCode) {
        _codeController.clear();
        _signalRejectedCode();
      }
      setState(() => _errorMessage = rejectedCode ? null : error.userMessage);
      _focusCodeOnNextFrame();
    } catch (_) {
      if (_verificationIsCurrent(pending.challengeId, generation)) {
        setState(
          () =>
              _errorMessage = 'We could not check that code. Please try again.',
        );
        _focusCodeOnNextFrame();
      }
    } finally {
      if (mounted) setState(() => _isVerifying = false);
    }
  }

  bool _verificationIsCurrent(String challengeId, int generation) =>
      mounted &&
      generation == _verificationGeneration &&
      _stage == _PasswordResetStage.verify &&
      _pending?.challengeId == challengeId &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  void _signalRejectedCode() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!mounted ||
        !(ModalRoute.of(context)?.isCurrent ?? true) ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      return;
    }
    _rejectionAttempt++;
    unawaited(HapticFeedback.mediumImpact());
  }

  Future<void> _confirmReset() async {
    if (_busy || _stage != _PasswordResetStage.confirm) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (_secondsRemaining <= 0) {
      _returnToCode('This code has expired. Request another code to continue.');
      return;
    }
    if (_confirmFormKey.currentState?.validate() != true) return;
    final pending = _pending;
    final verifiedCode = _verifiedCode;
    if (pending == null || verifiedCode == null) {
      _returnToCode('Verify your reset code before choosing a new password.');
      return;
    }

    setState(() {
      _isConfirming = true;
      _errorMessage = null;
    });
    try {
      await _repository.confirmPasswordReset(
        PasswordResetConfirmRequest(
          challengeId: pending.challengeId,
          code: verifiedCode,
          newPassword: _newPasswordController.text,
          newPasswordConfirmation: _confirmPasswordController.text,
        ),
      );
      if (!mounted) return;
      _expiryTimer?.cancel();
      _clearInMemoryValues();
      Navigator.of(
        context,
      ).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
    } on AppException catch (error) {
      if (!mounted) return;
      if (error.code == 'invalid_or_expired_password_reset') {
        _returnToCode(error.userMessage);
      } else {
        setState(() => _errorMessage = error.userMessage);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _errorMessage =
              'We could not reset the password. Please try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isConfirming = false);
        if (_secondsRemaining <= 0) _handleExpiredChallenge();
      }
    }
  }

  void _replaceChallenge(PendingPasswordReset pending) {
    _cancelSuccessFeedback();
    _rejectionAttempt = 0;
    _expiryTimer?.cancel();
    _verifiedCode = null;
    _codeController.clear();
    _newPasswordController.clear();
    _confirmPasswordController.clear();
    _expiresAt = DateTime.now().add(
      Duration(seconds: pending.expiresInSeconds),
    );
    setState(() {
      _pending = pending;
      _stage = _PasswordResetStage.verify;
      _secondsRemaining = pending.expiresInSeconds;
      _errorMessage = null;
    });
    _expiryTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickExpiryCountdown(),
    );
    _focusCodeOnNextFrame();
  }

  void _syncExpiryCountdown() {
    final expiresAt = _expiresAt;
    final milliseconds = expiresAt == null
        ? 0
        : expiresAt.difference(DateTime.now()).inMilliseconds;
    final next = milliseconds <= 0 ? 0 : (milliseconds / 1000).ceil();
    if (next == _secondsRemaining) return;
    if (mounted) {
      setState(() => _secondsRemaining = next);
    } else {
      _secondsRemaining = next;
    }
    if (next == 0) _handleExpiredChallenge();
  }

  void _tickExpiryCountdown() {
    final next = math.max(0, _secondsRemaining - 1);
    if (mounted) {
      setState(() => _secondsRemaining = next);
    } else {
      _secondsRemaining = next;
    }
    if (next == 0) _handleExpiredChallenge();
  }

  void _handleExpiredChallenge() {
    _expiryTimer?.cancel();
    if (mounted &&
        (_codeVerified ||
            _glidingToPassword ||
            (_stage == _PasswordResetStage.confirm && !_isConfirming))) {
      _returnToCode('This code has expired. Request another code to continue.');
    }
  }

  void _returnToCode(String? message) {
    _cancelSuccessFeedback();
    _verifiedCode = null;
    _codeController.clear();
    _newPasswordController.clear();
    _confirmPasswordController.clear();
    setState(() {
      _stage = _PasswordResetStage.verify;
      _errorMessage = message;
    });
    _focusCodeOnNextFrame();
  }

  void _focusCodeOnNextFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _stage == _PasswordResetStage.verify &&
          (ModalRoute.of(context)?.isCurrent ?? true) &&
          (WidgetsBinding.instance.lifecycleState == null ||
              WidgetsBinding.instance.lifecycleState ==
                  AppLifecycleState.resumed)) {
        _codeFocusNode.requestFocus();
      }
    });
  }

  void _goBack() {
    if (_busy) return;
    switch (_stage) {
      case _PasswordResetStage.request:
        Navigator.of(context).maybePop();
        return;
      case _PasswordResetStage.verify:
        _useDifferentEmail();
        return;
      case _PasswordResetStage.confirm:
        _returnToCode(null);
        return;
    }
  }

  void _useDifferentEmail() {
    if (_busy) return;
    _cancelSuccessFeedback();
    _rejectionAttempt = 0;
    _expiryTimer?.cancel();
    _expiresAt = null;
    _verifiedCode = null;
    _codeController.clear();
    _newPasswordController.clear();
    _confirmPasswordController.clear();
    setState(() {
      _stage = _PasswordResetStage.request;
      _pending = null;
      _secondsRemaining = 0;
      _errorMessage = null;
    });
  }

  void _clearInMemoryValues() {
    _emailController.clear();
    _codeController.clear();
    _newPasswordController.clear();
    _confirmPasswordController.clear();
    _pending = null;
    _expiresAt = null;
    _verifiedCode = null;
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return AnimatedSwitcher(
      duration: _glidingToPassword && !reduceMotion
          ? const Duration(milliseconds: 300)
          : Duration.zero,
      transitionBuilder: (child, animation) {
        if (!_glidingToPassword || reduceMotion) return child;
        final incomingPassword =
            child.key == const ValueKey(_PasswordResetStage.confirm);
        return SlideTransition(
          key: const Key('password-reset-success-glide'),
          position:
              Tween<Offset>(
                begin: Offset(incomingPassword ? 1 : -1, 0),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
          child: child,
        );
      },
      layoutBuilder: (current, previous) => ClipRect(
        child: Stack(children: [if (_glidingToPassword) ...previous, ?current]),
      ),
      child: KeyedSubtree(key: ValueKey(_stage), child: _buildStage(context)),
    );
  }

  Widget _buildStage(BuildContext context) {
    if (_stage == _PasswordResetStage.verify) {
      return _buildCodeVerificationPage();
    }
    final theme = Theme.of(context);
    const background = Color(0xFFF5DEE5);
    const ink = Color(0xFF29293B);
    const muted = Color(0xFF615B68);
    const accent = Color(0xFFFF7482);
    final requesting = _stage == _PasswordResetStage.request;

    return Scaffold(
      backgroundColor: background,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                key: const Key('password-reset-scroll'),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 420,
                      minHeight: math.max(0, constraints.maxHeight - 40),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            IconButton(
                              key: const Key('password-reset-back-button'),
                              tooltip: switch (_stage) {
                                _PasswordResetStage.request => 'Back to login',
                                _PasswordResetStage.verify =>
                                  'Use a different email',
                                _PasswordResetStage.confirm => 'Back to code',
                              },
                              onPressed: _busy ? null : _goBack,
                              style: IconButton.styleFrom(
                                foregroundColor: ink,
                                minimumSize: const Size.square(48),
                              ),
                              icon: const Icon(
                                Icons.arrow_back_rounded,
                                size: 24,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(
                          height: requesting
                              ? (constraints.maxHeight > 700 ? 28 : 8)
                              : 4,
                        ),
                        SizedBox(
                          height: requesting ? 180 : 144,
                          child: Center(
                            child: ListenableBuilder(
                              listenable: _passwordFocus,
                              builder: (context, _) => VerificationFriend(
                                key: const Key('password-reset-friend'),
                                reduceMotion: MediaQuery.of(
                                  context,
                                ).disableAnimations,
                                showMailbox: requesting,
                                eyesClosed:
                                    !requesting &&
                                    (_newPasswordFocusNode.hasFocus ||
                                        _confirmPasswordFocusNode.hasFocus),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(height: requesting ? 18 : 8),
                        Text(
                          switch (_stage) {
                            _PasswordResetStage.request =>
                              'Forgot your password?',
                            _PasswordResetStage.verify => 'Check your email',
                            _PasswordResetStage.confirm =>
                              'Create a new password',
                          },
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            color: ink,
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.8,
                            height: 1.04,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          switch (_stage) {
                            _PasswordResetStage.request =>
                              'No worries. Enter your parent email and we’ll help you get back in.',
                            _PasswordResetStage.verify =>
                              'Enter the six-digit code from your email to continue.',
                            _PasswordResetStage.confirm =>
                              'Choose a strong password to keep your parent account safe.',
                          },
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: muted,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            height: 1.45,
                          ),
                        ),
                        SizedBox(height: requesting ? 30 : 24),
                        Theme(
                          data: theme.copyWith(
                            inputDecorationTheme: InputDecorationTheme(
                              filled: true,
                              fillColor: Colors.white.withValues(alpha: .52),
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.never,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 19,
                                vertical: 20,
                              ),
                              labelStyle: TextStyle(color: muted, fontSize: 14),
                              hintStyle: TextStyle(color: muted, fontSize: 14),
                              prefixIconColor: muted,
                              suffixIconColor: muted,
                              errorStyle: const TextStyle(
                                color: Color(0xFF8C2744),
                                fontSize: 12.5,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(18),
                                borderSide: BorderSide.none,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(18),
                                borderSide: BorderSide.none,
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(18),
                                borderSide: const BorderSide(
                                  color: accent,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                          child: requesting
                              ? _buildRequestForm(accent: accent, ink: ink)
                              : _buildConfirmForm(accent: accent, ink: ink),
                        ),
                        if (_errorMessage != null) ...[
                          const SizedBox(height: 14),
                          _ResetNotice(
                            key: const Key('password-reset-error'),
                            message: _errorMessage!,
                            isError: true,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildRequestForm({required Color accent, required Color ink}) {
    return AutofillGroup(
      child: Form(
        key: _requestFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              key: const Key('password-reset-email-field'),
              enabled: !_busy,
              controller: _emailController,
              style: TextStyle(color: ink, fontSize: 16),
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.email],
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Parent email address',
                hintText: 'you@example.com',
                prefixIcon: Icon(Icons.alternate_email_rounded),
              ),
              validator: _validateEmail,
              onFieldSubmitted: (_) => _requestReset(),
            ),
            const SizedBox(height: 16),
            VerificationPrimaryButton(
              buttonKey: const Key('password-reset-request-button'),
              onPressed: _busy ? null : _requestReset,
              isSubmitting: _isRequesting,
              label: _isRequesting ? 'Requesting code…' : 'Send reset code',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCodeVerificationPage() {
    final expired = _secondsRemaining <= 0;
    final expiryLabel = expired
        ? 'Code expired — request another code'
        : 'Code expires in ${_durationLabel(_secondsRemaining)}';
    return VerificationPage(
      verified: _codeVerified,
      rejectionAttempt: _rejectionAttempt,
      challengeKey: _pending?.challengeId,
      autoSubmitExpiresAt: _expiresAt,
      controller: _codeController,
      focusNode: _codeFocusNode,
      heading: 'Check your email',
      description: 'Enter the six-digit code from your email to continue.',
      submitLabel: 'Verify code',
      scrollKey: const Key('password-reset-scroll'),
      codeInputKey: const Key('password-reset-code-field'),
      submitKey: const Key('password-reset-verify-button'),
      resendKey: const Key('password-reset-request-another-button'),
      backKey: const Key('password-reset-back-button'),
      secondaryKey: const Key('password-reset-use-different-email'),
      errorKey: const Key('password-reset-error'),
      statusKey: const Key('password-reset-status'),
      codeSemanticsLabel: '6 digit password reset code',
      errorMessage: _errorMessage,
      contextDetail: Semantics(
        key: const Key('password-reset-countdown'),
        liveRegion: true,
        label: expired
            ? 'Password reset code expired'
            : 'Password reset code expires in ${_durationLabel(_secondsRemaining)}',
        child: Text(
          expiryLabel,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: expired ? const Color(0xFF8C2744) : const Color(0xFF615B68),
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      resendLabel: 'Request another code',
      resendEnabled: !_busy,
      isResending: _isRequesting,
      isSubmitting: _isVerifying,
      inputEnabled: !_busy,
      canSubmit: !expired && !_busy,
      secondaryLabel: 'Use a different email',
      onSecondary: _busy ? null : _useDifferentEmail,
      onResend: _requestAnotherCode,
      onSubmit: _verifyCode,
      onBack: _goBack,
    );
  }

  Widget _buildConfirmForm({required Color accent, required Color ink}) {
    return AutofillGroup(
      child: Form(
        key: _confirmFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              key: const Key('password-reset-new-password-field'),
              enabled: !_busy,
              controller: _newPasswordController,
              style: TextStyle(color: ink, fontSize: 16),
              focusNode: _newPasswordFocusNode,
              obscureText: !_showNewPassword,
              enableSuggestions: false,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.newPassword],
              decoration: _passwordDecoration(
                'New password',
                suffixIcon: IconButton(
                  tooltip: _showNewPassword
                      ? 'Hide new password'
                      : 'Show new password',
                  onPressed: () =>
                      setState(() => _showNewPassword = !_showNewPassword),
                  icon: Icon(
                    _showNewPassword
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                  ),
                ),
              ),
              validator: _validateNewPassword,
            ),
            const SizedBox(height: 14),
            TextFormField(
              key: const Key('password-reset-confirm-password-field'),
              enabled: !_busy,
              controller: _confirmPasswordController,
              style: TextStyle(color: ink, fontSize: 16),
              focusNode: _confirmPasswordFocusNode,
              obscureText: !_showConfirmation,
              enableSuggestions: false,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.newPassword],
              decoration: _passwordDecoration(
                'Confirm new password',
                suffixIcon: IconButton(
                  tooltip: _showConfirmation
                      ? 'Hide password confirmation'
                      : 'Show password confirmation',
                  onPressed: () =>
                      setState(() => _showConfirmation = !_showConfirmation),
                  icon: Icon(
                    _showConfirmation
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                  ),
                ),
              ),
              validator: (value) => value != _newPasswordController.text
                  ? 'The new passwords do not match.'
                  : null,
              onFieldSubmitted: (_) => _confirmReset(),
            ),
            const SizedBox(height: 18),
            VerificationPrimaryButton(
              buttonKey: const Key('password-reset-confirm-button'),
              onPressed: _busy ? null : _confirmReset,
              isSubmitting: _isConfirming,
              label: _isConfirming ? 'Resetting password…' : 'Reset password',
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _passwordDecoration(
    String label, {
    required Widget suffixIcon,
  }) {
    OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(22),
      borderSide: BorderSide(color: color, width: width),
      gapPadding: 4,
    );
    return InputDecoration(
      labelText: label,
      floatingLabelBehavior: FloatingLabelBehavior.always,
      filled: false,
      labelStyle: const TextStyle(color: Color(0xFF615B68), fontSize: 14),
      floatingLabelStyle: const TextStyle(
        color: Color(0xFF29293B),
        fontSize: 14,
      ),
      border: border(const Color(0xFF8F7D89), 1.2),
      enabledBorder: border(const Color(0xFF8F7D89), 1.2),
      focusedBorder: border(const Color(0xFFFF7482), 2),
      errorBorder: border(const Color(0xFF8C2744), 1.2),
      focusedErrorBorder: border(const Color(0xFF8C2744), 2),
      suffixIcon: suffixIcon,
    );
  }

  String? _validateEmail(String? value) {
    final email = value?.trim() ?? '';
    if (email.isEmpty) return 'Enter the parent email address.';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      return 'Enter a valid email address.';
    }
    return null;
  }

  String? _validateCode(String? value) {
    if (!RegExp(r'^[0-9]{6}$').hasMatch(value ?? '')) {
      return 'Enter the six-digit password reset code.';
    }
    return null;
  }

  String? _validateNewPassword(String? value) {
    if (value == null || value.isEmpty) return 'Enter a new password.';
    if (value.length < 8) return 'Use at least 8 characters.';
    if (value.length > 128) return 'Use no more than 128 characters.';
    return null;
  }
}

class _ResetNotice extends StatelessWidget {
  const _ResetNotice({super.key, required this.message, this.isError = false});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final foreground = isError
        ? const Color(0xFF8C2744)
        : const Color(0xFF615B68);
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: foreground.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: foreground,
            height: 1.35,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

String _normalizedEmail(String value) => value.trim().toLowerCase();

String _durationLabel(int seconds) {
  final safeSeconds = math.max(0, seconds);
  final minutes = safeSeconds ~/ 60;
  final remainder = safeSeconds % 60;
  return '$minutes:${remainder.toString().padLeft(2, '0')}';
}

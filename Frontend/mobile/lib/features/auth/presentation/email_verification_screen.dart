import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../subscription/data/hosted_access_routing.dart';

import '../../../app/app_route_observer.dart';
import '../../../app/router.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/network/feature_view_state_cache.dart';
import '../data/auth_repository.dart';
import '../domain/auth_requests.dart';
import '../domain/auth_session.dart';
import '../domain/email_verification.dart';
import 'verification_page.dart';

class EmailVerificationScreen extends StatefulWidget {
  const EmailVerificationScreen({
    super.key,
    required this.pending,
    this.repository,
  });

  final PendingEmailVerification pending;
  final AuthRepository? repository;

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver, RouteAware {
  static const _codeLength = 6;

  final _codeController = TextEditingController();
  final _codeFocusNode = FocusNode();
  late final AuthRepository _repository;
  late PendingEmailVerification _pending;
  late DateTime _challengeExpiresAt;
  Timer? _resendTimer;
  DateTime? _resendAvailableAt;
  int _resendSeconds = 0;
  bool _isSubmitting = false;
  bool _isResending = false;
  bool _codeVerified = false;
  int? _verifiedIdentityRevision;
  bool _foreground = true;
  int _verificationGeneration = 0;
  int _requestSequence = 0;
  int _rejectionAttempt = 0;
  late final AnimationController _successBeat;
  ModalRoute<dynamic>? _observedRoute;
  String? _errorMessage;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    featureViewStateCache.addListener(_identityChanged);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _successBeat = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      animationBehavior: AnimationBehavior.preserve,
    );
    _repository = widget.repository ?? AuthRepository();
    _pending = widget.pending;
    _challengeExpiresAt = DateTime.now().add(
      Duration(seconds: _pending.expiresInSeconds),
    );
    if (_pending.deliveryDelayed) {
      _statusMessage = 'Email delivery was delayed. Ask for a fresh code.';
    }
    _codeController.addListener(_refreshCode);
    _startResendCountdown(_pending.resendAfterSeconds);
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
  void didUpdateWidget(covariant EmailVerificationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pending.challengeId != widget.pending.challengeId ||
        oldWidget.pending.email != widget.pending.email) {
      _requestSequence++;
      _cancelFeedback();
      _codeController.clear();
      _pending = widget.pending;
      _challengeExpiresAt = DateTime.now().add(
        Duration(seconds: _pending.expiresInSeconds),
      );
      _isSubmitting = false;
      _isResending = false;
      _rejectionAttempt = 0;
      _errorMessage = null;
      _statusMessage = _pending.deliveryDelayed
          ? 'Email delivery was delayed. Ask for a fresh code.'
          : null;
      _startResendCountdown(_pending.resendAfterSeconds);
    }
  }

  @override
  void didPushNext() => _cancelFeedback();

  void _identityChanged() {
    if (_codeVerified &&
        _verifiedIdentityRevision != AuthRepository.sessionIdentityRevision) {
      _cancelFeedback();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _updateResendCountdown();
    } else {
      _cancelFeedback();
    }
  }

  void _cancelFeedback() {
    _verificationGeneration++;
    _successBeat.stop(canceled: true);
    if (!mounted) return;
    final clearVerifiedCode = _codeVerified;
    setState(() {
      _codeVerified = false;
      _verifiedIdentityRevision = null;
      _rejectionAttempt = 0;
    });
    if (clearVerifiedCode) _codeController.clear();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    featureViewStateCache.removeListener(_identityChanged);
    if (_observedRoute != null) appRouteObserver.unsubscribe(this);
    _verificationGeneration++;
    _successBeat.dispose();
    _resendTimer?.cancel();
    _codeController
      ..removeListener(_refreshCode)
      ..dispose();
    _codeFocusNode.dispose();
    super.dispose();
  }

  void _refreshCode() {
    if (mounted) {
      setState(() {
        _errorMessage = null;
        _statusMessage = null;
      });
    }
  }

  void _focusCodeOnNextFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_active && !_isSubmitting && !_isResending && !_codeVerified) {
        _codeFocusNode.requestFocus();
      }
    });
  }

  void _startResendCountdown(int seconds) {
    _resendTimer?.cancel();
    final safeSeconds = seconds < 0 ? 0 : seconds;
    _resendAvailableAt = DateTime.now().add(Duration(seconds: safeSeconds));
    _updateResendCountdown();
    if (_resendSeconds == 0) {
      return;
    }

    _resendTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _updateResendCountdown(),
    );
  }

  void _updateResendCountdown() {
    final deadline = _resendAvailableAt;
    final milliseconds = deadline == null
        ? 0
        : deadline.difference(DateTime.now()).inMilliseconds;
    final nextSeconds = milliseconds <= 0 ? 0 : (milliseconds / 1000).ceil();
    if (nextSeconds == _resendSeconds) {
      return;
    }
    if (mounted) {
      setState(() => _resendSeconds = nextSeconds);
    } else {
      _resendSeconds = nextSeconds;
    }
    if (nextSeconds == 0) {
      _resendTimer?.cancel();
    }
  }

  Future<void> _submit() async {
    if (!_active || _isSubmitting || _isResending || _codeVerified) {
      return;
    }

    final code = _codeController.text;
    final challengeId = _pending.challengeId;
    if (!RegExp(r'^[0-9]{6}$').hasMatch(code)) {
      setState(() => _errorMessage = 'Enter all six digits to continue.');
      _focusCodeOnNextFrame();
      return;
    }
    if (!_challengeExpiresAt.isAfter(DateTime.now())) {
      setState(
        () => _errorMessage = 'This code has expired. Ask for a fresh code.',
      );
      return;
    }

    final request = ++_requestSequence;
    final generation = ++_verificationGeneration;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
      _statusMessage = null;
    });

    try {
      final session = await _repository.verifyEmail(
        VerifyEmailRequest(challengeId: challengeId, code: code),
      );
      final identityRevision = AuthRepository.sessionIdentityRevision;
      if (!_challengeIsCurrent(challengeId, generation)) return;
      setState(() {
        _codeVerified = true;
        _verifiedIdentityRevision = identityRevision;
        _errorMessage = null;
      });
      await _successBeat.forward(from: 0).orCancel;
      if (!_challengeIsCurrent(challengeId, generation) ||
          identityRevision != AuthRepository.sessionIdentityRevision) {
        return;
      }
      await _continueToProfiles(
        session,
        challengeId,
        generation,
        identityRevision,
      );
    } on TickerCanceled {
      // Navigation or backgrounding cancels the green success beat.
    } on AppException catch (error) {
      if (!_challengeIsCurrent(challengeId, generation)) return;
      if (error.code == 'invalid_or_expired_code') {
        _codeController.clear();
        _rejectionAttempt++;
        unawaited(HapticFeedback.mediumImpact());
      }
      setState(() => _errorMessage = error.userMessage);
      _focusCodeOnNextFrame();
    } catch (_) {
      if (_challengeIsCurrent(challengeId, generation)) {
        setState(
          () => _errorMessage = 'We could not check that code. Try again.',
        );
      }
    } finally {
      if (mounted && request == _requestSequence) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<void> _resend() async {
    if (!_active ||
        _isResending ||
        _isSubmitting ||
        _codeVerified ||
        _resendSeconds > 0) {
      return;
    }

    final challengeId = _pending.challengeId;
    final request = ++_requestSequence;
    final generation = ++_verificationGeneration;
    setState(() {
      _isResending = true;
      _errorMessage = null;
      _statusMessage = null;
    });

    try {
      final pending = await _repository.resendEmailVerification(challengeId);
      if (!_challengeIsCurrent(challengeId, generation)) return;
      _verificationGeneration++;
      _codeController.clear();
      setState(() {
        _pending = pending;
        _rejectionAttempt = 0;
        _codeVerified = false;
        _challengeExpiresAt = DateTime.now().add(
          Duration(seconds: pending.expiresInSeconds),
        );
        _statusMessage = pending.deliveryDelayed
            ? 'Email is still delayed. Please try sending again.'
            : 'A fresh code is on its way.';
      });
      _focusCodeOnNextFrame();
      _startResendCountdown(pending.resendAfterSeconds);
    } on AppException catch (error) {
      if (_challengeIsCurrent(challengeId, generation)) {
        if (error.code == 'resend_too_soon') {
          final retryAfter = int.tryParse(
            error.details['retry_after']?.toString() ?? '',
          );
          if (retryAfter != null) {
            _startResendCountdown(retryAfter);
          }
        }
        setState(() => _errorMessage = error.userMessage);
      }
    } catch (_) {
      if (_challengeIsCurrent(challengeId, generation)) {
        setState(
          () => _errorMessage = 'We could not send a new code just yet.',
        );
      }
    } finally {
      if (mounted && request == _requestSequence) {
        setState(() => _isResending = false);
      }
    }
  }

  bool get _active =>
      mounted && _foreground && (ModalRoute.of(context)?.isCurrent ?? true);

  bool _challengeIsCurrent(String challengeId, int generation) =>
      _active &&
      generation == _verificationGeneration &&
      _pending.challengeId == challengeId &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  Future<void> _continueToProfiles(
    AuthSession session,
    String challengeId,
    int generation,
    int identityRevision,
  ) async {
    bool current() =>
        _challengeIsCurrent(challengeId, generation) &&
        identityRevision == AuthRepository.sessionIdentityRevision;
    if (!current()) return;
    final routing = HostedAccessRouting(authRepository: _repository);
    final plans = await routing.requiresPlans();
    if (!current()) return;
    final sameParent = await routing.isCurrentParent(session.parent.id);
    if (!mounted || !sameParent || !current()) return;
    Navigator.of(context).pushNamedAndRemoveUntil(
      plans
          ? AppRoutes.subscription
          : session.hasProfiles
          ? AppRoutes.profilePicker
          : AppRoutes.kidProfileSetup,
      (_) => false,
      arguments: session.profiles,
    );
  }

  @override
  Widget build(BuildContext context) => VerificationPage(
    controller: _codeController,
    focusNode: _codeFocusNode,
    codeLength: _codeLength,
    challengeKey: _pending.challengeId,
    autoSubmitExpiresAt: _challengeExpiresAt,
    heading: 'Enter your magic code.',
    description: 'We sent six little digits to\n${_destinationLabel(_pending)}',
    errorMessage: _errorMessage,
    statusMessage: _statusMessage,
    resendLabel: _resendSeconds > 0
        ? 'Send again in ${_resendSeconds}s'
        : 'Send me a fresh code',
    resendEnabled: _resendSeconds == 0 && !_isResending && !_isSubmitting,
    isResending: _isResending,
    isSubmitting: _isSubmitting,
    inputEnabled: !_isSubmitting && !_isResending && !_codeVerified,
    canSubmit: !_codeVerified && _codeController.text.length == _codeLength,
    verified: _codeVerified,
    rejectionAttempt: _rejectionAttempt,
    onResend: _resend,
    onSubmit: _submit,
    onBack: () {
      _cancelFeedback();
      Navigator.of(context).maybePop();
    },
  );
}

String _destinationLabel(PendingEmailVerification pending) {
  final hint = pending.destinationHint.trim();
  if (hint.isNotEmpty && hint != pending.email) {
    return hint;
  }

  final parts = pending.email.split('@');
  if (parts.length != 2 || parts.first.isEmpty) {
    return pending.email;
  }
  final local = parts.first;
  final visible = local.substring(0, local.length > 2 ? 2 : 1);
  final hidden = List.filled(local.length > 4 ? 4 : 3, '•').join();
  return '$visible$hidden@${parts.last}';
}

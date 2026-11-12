import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../../core/errors/app_exception.dart';
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

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
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
  String? _errorMessage;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
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
  void dispose() {
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
    if (_isSubmitting || _isResending) {
      return;
    }

    final code = _codeController.text;
    final challengeId = _pending.challengeId;
    if (code.length != _codeLength) {
      setState(() => _errorMessage = 'Enter all six digits to continue.');
      _codeFocusNode.requestFocus();
      return;
    }

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
      if (_challengeIsCurrent(challengeId)) {
        _continueToProfiles(session);
      }
    } on AppException catch (error) {
      if (_challengeIsCurrent(challengeId)) {
        setState(() => _errorMessage = error.userMessage);
      }
    } catch (_) {
      if (_challengeIsCurrent(challengeId)) {
        setState(
          () => _errorMessage = 'We could not check that code. Try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<void> _resend() async {
    if (_isResending || _isSubmitting || _resendSeconds > 0) {
      return;
    }

    setState(() {
      _isResending = true;
      _errorMessage = null;
      _statusMessage = null;
    });

    try {
      final pending = await _repository.resendEmailVerification(
        _pending.challengeId,
      );
      if (!mounted) {
        return;
      }
      _codeController.clear();
      setState(() {
        _pending = pending;
        _challengeExpiresAt = DateTime.now().add(
          Duration(seconds: pending.expiresInSeconds),
        );
        _statusMessage = pending.deliveryDelayed
            ? 'Email is still delayed. Please try sending again.'
            : 'A fresh code is on its way.';
      });
      _codeFocusNode.requestFocus();
      _startResendCountdown(pending.resendAfterSeconds);
    } on AppException catch (error) {
      if (mounted) {
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
      if (mounted) {
        setState(
          () => _errorMessage = 'We could not send a new code just yet.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isResending = false);
      }
    }
  }

  bool _challengeIsCurrent(String challengeId) =>
      mounted &&
      _pending.challengeId == challengeId &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  void _continueToProfiles(AuthSession session) {
    Navigator.of(context).pushNamedAndRemoveUntil(
      session.hasProfiles ? AppRoutes.profilePicker : AppRoutes.kidProfileSetup,
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
    canSubmit: _codeController.text.length == _codeLength,
    onResend: _resend,
    onSubmit: _submit,
    onBack: () => Navigator.of(context).maybePop(),
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

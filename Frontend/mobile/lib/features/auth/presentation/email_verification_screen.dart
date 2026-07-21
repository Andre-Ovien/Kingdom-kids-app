import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/router.dart';
import '../../../core/errors/app_exception.dart';
import '../data/auth_repository.dart';
import '../domain/auth_requests.dart';
import '../domain/auth_session.dart';
import '../domain/email_verification.dart';

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
    if (_isSubmitting) {
      return;
    }

    final code = _codeController.text;
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
        VerifyEmailRequest(challengeId: _pending.challengeId, code: code),
      );
      if (mounted) {
        _continueToProfiles(session);
      }
    } on AppException catch (error) {
      if (mounted) {
        setState(() => _errorMessage = error.message);
      }
    } catch (_) {
      if (mounted) {
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
    if (_isResending || _resendSeconds > 0) {
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
        setState(() => _errorMessage = error.message);
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

  void _continueToProfiles(AuthSession session) {
    Navigator.of(context).pushNamedAndRemoveUntil(
      session.hasProfiles ? AppRoutes.profilePicker : AppRoutes.kidProfileSetup,
      (_) => false,
      arguments: session.profiles,
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    const background = Color(0xFFF5DEE5);
    const ink = Color(0xFF29293B);
    const accent = Color(0xFFFF7482);

    return Scaffold(
      backgroundColor: background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
                    child: Column(
                      children: [
                        const SizedBox(height: 26),
                        _VerificationCodeInput(
                          key: const Key('verification-code-field'),
                          controller: _codeController,
                          focusNode: _codeFocusNode,
                          length: _codeLength,
                          accent: accent,
                          ink: ink,
                          onSubmitted: (_) => _submit(),
                        ),
                        const SizedBox(height: 28),
                        _VerificationFriend(reduceMotion: reduceMotion),
                        const SizedBox(height: 24),
                        const Text(
                          'Enter your magic code.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: ink,
                            fontSize: 32,
                            height: 1.04,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.8,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'We sent six little digits to\n${_destinationLabel(_pending)}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFF615B68),
                            fontSize: 14,
                            height: 1.45,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (_errorMessage != null) ...[
                          const SizedBox(height: 14),
                          _VerificationNotice(
                            message: _errorMessage!,
                            isError: true,
                          ),
                        ] else if (_statusMessage != null) ...[
                          const SizedBox(height: 14),
                          _VerificationNotice(message: _statusMessage!),
                        ],
                        const SizedBox(height: 8),
                        TextButton(
                          key: const Key('verification-resend-button'),
                          onPressed: _resendSeconds == 0 && !_isResending
                              ? _resend
                              : null,
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF7131BA),
                            disabledForegroundColor: const Color(0xFF8D8390),
                          ),
                          child: _isResending
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(
                                  _resendSeconds > 0
                                      ? 'Send again in ${_resendSeconds}s'
                                      : 'Send me a fresh code',
                                ),
                        ),
                        const Spacer(),
                        const SizedBox(height: 20),
                        _VerificationActions(
                          largeText: largeText,
                          ink: ink,
                          isSubmitting: _isSubmitting,
                          canSubmit: _codeController.text.length == _codeLength,
                          onBack: () => Navigator.of(context).maybePop(),
                          onSubmit: _submit,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _VerificationActions extends StatelessWidget {
  const _VerificationActions({
    required this.largeText,
    required this.ink,
    required this.isSubmitting,
    required this.canSubmit,
    required this.onBack,
    required this.onSubmit,
  });

  final bool largeText;
  final Color ink;
  final bool isSubmitting;
  final bool canSubmit;
  final VoidCallback onBack;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final backButton = TextButton.icon(
      onPressed: onBack,
      style: TextButton.styleFrom(foregroundColor: ink),
      icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 15),
      label: const Text('Back'),
    );
    final completeButton = FilledButton(
      key: const Key('verification-submit-button'),
      onPressed: canSubmit && !isSubmitting ? onSubmit : null,
      style: FilledButton.styleFrom(
        backgroundColor: ink,
        foregroundColor: Colors.white,
        disabledBackgroundColor: const Color(0xFFAAA0A8),
        minimumSize: const Size(140, 54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      child: isSubmitting
          ? const SizedBox.square(
              dimension: 21,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: Colors.white,
              ),
            )
          : const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Complete', style: TextStyle(fontWeight: FontWeight.w700)),
                SizedBox(width: 8),
                Icon(Icons.arrow_forward_ios_rounded, size: 15),
              ],
            ),
    );

    if (largeText) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [completeButton, const SizedBox(height: 8), backButton],
      );
    }

    return Row(children: [backButton, const Spacer(), completeButton]);
  }
}

class _VerificationCodeInput extends StatelessWidget {
  const _VerificationCodeInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.length,
    required this.accent,
    required this.ink,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final int length;
  final Color accent;
  final Color ink;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    final value = controller.text;
    return Semantics(
      label: '$length digit email verification code',
      value: '${value.length} of $length digits entered',
      textField: true,
      child: SizedBox(
        height: 62,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(length, (index) {
                final filled = index < value.length;
                final active = index == value.length && value.length < length;
                return Flexible(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    constraints: const BoxConstraints(
                      minWidth: 38,
                      maxWidth: 50,
                    ),
                    height: 58,
                    margin: EdgeInsets.only(right: index == length - 1 ? 0 : 5),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: filled
                          ? Colors.white.withValues(alpha: 0.92)
                          : Colors.white.withValues(alpha: 0.42),
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(
                        color: active ? accent : ink.withValues(alpha: 0.42),
                        width: active ? 2 : 1.2,
                      ),
                    ),
                    child: Text(
                      filled ? value[index] : '',
                      style: TextStyle(
                        color: ink,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                );
              }),
            ),
            Opacity(
              opacity: 0.01,
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(length),
                ],
                maxLength: length,
                showCursor: false,
                enableSuggestions: false,
                autocorrect: false,
                onSubmitted: onSubmitted,
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  counterText: '',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VerificationFriend extends StatelessWidget {
  const _VerificationFriend({required this.reduceMotion});

  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 680),
      curve: Curves.easeOutBack,
      builder: (context, value, child) {
        return Transform.translate(
          offset: Offset(0, (1 - value) * 18),
          child: Transform.scale(scale: 0.88 + value * 0.12, child: child),
        );
      },
      child: SizedBox(
        width: 160,
        height: 144,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              top: 4,
              left: 22,
              child: Transform.rotate(angle: -0.28, child: const _FriendEar()),
            ),
            Positioned(
              top: 4,
              right: 22,
              child: Transform.rotate(angle: 0.28, child: const _FriendEar()),
            ),
            Positioned(
              top: 16,
              child: Container(
                width: 126,
                height: 108,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFB04E),
                  borderRadius: BorderRadius.circular(46),
                  border: Border.all(color: const Color(0xFF29293B), width: 2),
                ),
                child: const Stack(
                  children: [
                    Positioned(top: 28, left: 25, child: _FriendEye()),
                    Positioned(top: 28, right: 25, child: _FriendEye()),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 18,
                      child: Icon(
                        Icons.favorite_rounded,
                        color: Color(0xFF29293B),
                        size: 20,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              bottom: 0,
              child: Container(
                width: 72,
                height: 45,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF5DE),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF29293B), width: 2),
                ),
                child: const Icon(
                  Icons.mail_rounded,
                  color: Color(0xFFFF7482),
                  size: 25,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FriendEar extends StatelessWidget {
  const _FriendEar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 52,
      decoration: BoxDecoration(
        color: const Color(0xFFFF7482),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFF29293B), width: 2),
      ),
    );
  }
}

class _FriendEye extends StatelessWidget {
  const _FriendEye();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 32,
      decoration: const BoxDecoration(
        color: Color(0xFFFFF5DE),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: const CircleAvatar(radius: 6, backgroundColor: Color(0xFF7131BA)),
    );
  }
}

class _VerificationNotice extends StatelessWidget {
  const _VerificationNotice({required this.message, this.isError = false});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: isError ? const Color(0xFFFFC9CF) : const Color(0xFFDCCFF2),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFF29293B),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
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

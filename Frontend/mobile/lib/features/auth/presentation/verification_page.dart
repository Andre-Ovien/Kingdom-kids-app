import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/app_route_observer.dart';

import 'verification_code_input.dart';
import 'verification_friend.dart';
import 'verification_primary_button.dart';

/// The shared sign-up and recovery verification presentation. Authentication
/// state, expiry and network requests stay with the calling screen.
class VerificationPage extends StatefulWidget {
  const VerificationPage({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.heading,
    required this.description,
    required this.onSubmit,
    required this.onBack,
    required this.onResend,
    required this.resendLabel,
    required this.resendEnabled,
    this.codeLength = 6,
    this.submitLabel = 'Complete',
    this.canSubmit = true,
    this.isSubmitting = false,
    this.isResending = false,
    this.inputEnabled = true,
    this.errorMessage,
    this.statusMessage,
    this.contextDetail,
    this.secondaryLabel,
    this.onSecondary,
    this.scrollKey,
    this.codeInputKey = const Key('verification-code-field'),
    this.submitKey = const Key('verification-submit-button'),
    this.resendKey = const Key('verification-resend-button'),
    this.backKey,
    this.secondaryKey,
    this.errorKey,
    this.statusKey,
    this.codeSemanticsLabel,
    this.challengeKey,
    this.autoSubmitExpiresAt,
    this.verified = false,
    this.rejectionAttempt = 0,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String heading;
  final String description;
  final Future<void> Function() onSubmit;
  final VoidCallback onBack;
  final VoidCallback onResend;
  final String resendLabel;
  final bool resendEnabled;
  final int codeLength;
  final String submitLabel;
  final bool canSubmit;
  final bool isSubmitting;
  final bool isResending;
  final bool inputEnabled;
  final String? errorMessage;
  final String? statusMessage;
  final Widget? contextDetail;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final Key? scrollKey;
  final Key codeInputKey;
  final Key submitKey;
  final Key resendKey;
  final Key? backKey;
  final Key? secondaryKey;
  final Key? errorKey;
  final Key? statusKey;
  final String? codeSemanticsLabel;
  final Object? challengeKey;
  final DateTime? autoSubmitExpiresAt;
  final bool verified;
  final int rejectionAttempt;

  @override
  State<VerificationPage> createState() => _VerificationPageState();
}

class _VerificationPageState extends State<VerificationPage>
    with WidgetsBindingObserver, RouteAware {
  int _generation = 0;
  bool _queued = false;
  bool _inFlight = false;
  bool _foreground = true;
  String? _lastAttemptedCode;
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_codeChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _route)) {
      if (_route != null) appRouteObserver.unsubscribe(this);
      _route = route;
      if (route != null) appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didUpdateWidget(VerificationPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_codeChanged);
      widget.controller.addListener(_codeChanged);
      _cancelAuto();
    }
    if (oldWidget.challengeKey != widget.challengeKey) {
      _cancelAuto();
      _lastAttemptedCode = null;
    } else if (!widget.canSubmit ||
        !widget.inputEnabled ||
        widget.isResending) {
      _cancelAuto();
    }
  }

  void _cancelAuto({bool rememberCurrent = false}) {
    _generation++;
    _queued = false;
    if (rememberCurrent) _lastAttemptedCode = widget.controller.text;
  }

  bool get _active => mounted && _foreground && (_route?.isCurrent ?? true);

  bool get _canAttempt =>
      _active &&
      !_inFlight &&
      !widget.isSubmitting &&
      !widget.isResending &&
      widget.inputEnabled &&
      widget.canSubmit;

  void _codeChanged() {
    final code = widget.controller.text;
    if (code.length != widget.codeLength ||
        code == _lastAttemptedCode ||
        _queued) {
      return;
    }
    final generation = _generation;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      _queued = false;
      if (!_canAttempt) return;
      // Several edits can happen before this frame (paste/replace/autofill).
      // Verify the latest complete value rather than a stale captured one.
      unawaited(_attemptSubmit(automatic: true));
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> _attemptSubmit({bool automatic = false}) async {
    if (!_canAttempt) return;
    final code = widget.controller.text;
    if (automatic &&
        (code.length != widget.codeLength ||
            code == _lastAttemptedCode ||
            !(widget.autoSubmitExpiresAt?.isAfter(DateTime.now()) ?? true))) {
      return;
    }
    if (code.length == widget.codeLength) _lastAttemptedCode = code;
    _cancelAuto();
    setState(() => _inFlight = true);
    try {
      await widget.onSubmit();
    } finally {
      if (mounted) setState(() => _inFlight = false);
    }
  }

  void _resend() {
    _cancelAuto(rememberCurrent: true);
    widget.onResend();
  }

  void _back() {
    _cancelAuto(rememberCurrent: true);
    widget.onBack();
  }

  void _secondary() {
    _cancelAuto(rememberCurrent: true);
    widget.onSecondary?.call();
  }

  @override
  void didPushNext() => _cancelAuto(rememberCurrent: true);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _cancelAuto(rememberCurrent: true);
  }

  @override
  void dispose() {
    _cancelAuto();
    widget.controller.removeListener(_codeChanged);
    WidgetsBinding.instance.removeObserver(this);
    if (_route != null) appRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<TextEditingValue>(
    valueListenable: widget.controller,
    builder: (context, value, child) {
      final reduceMotion = MediaQuery.of(context).disableAnimations;
      final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
      const ink = Color(0xFF29293B);
      const accent = Color(0xFFFF7482);
      return Scaffold(
        backgroundColor: const Color(0xFFF5DEE5),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              key: widget.scrollKey,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
                    child: Column(
                      children: [
                        const SizedBox(height: 26),
                        VerificationCodeRejectionShake(
                          key: const Key('verification-code-rejection-shake'),
                          attempt: widget.rejectionAttempt,
                          reduceMotion: reduceMotion,
                          child: VerificationCodeInput(
                            key: widget.codeInputKey,
                            controller: widget.controller,
                            focusNode: widget.focusNode,
                            length: widget.codeLength,
                            accent: accent,
                            ink: ink,
                            enabled: widget.inputEnabled && !_inFlight,
                            semanticsLabel: widget.codeSemanticsLabel,
                            verified: widget.verified,
                            rejected:
                                widget.rejectionAttempt > 0 &&
                                value.text.isEmpty,
                            onSubmitted: (_) => _attemptSubmit(),
                          ),
                        ),
                        const SizedBox(height: 28),
                        VerificationFriend(reduceMotion: reduceMotion),
                        const SizedBox(height: 24),
                        Text(
                          widget.heading,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: ink,
                            fontSize: 32,
                            height: 1.04,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.8,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          widget.description,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFF615B68),
                            fontSize: 14,
                            height: 1.45,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (widget.contextDetail != null) ...[
                          const SizedBox(height: 8),
                          widget.contextDetail!,
                        ],
                        if (widget.errorMessage != null) ...[
                          const SizedBox(height: 14),
                          _VerificationNotice(
                            key: widget.errorKey,
                            message: widget.errorMessage!,
                            isError: true,
                          ),
                        ] else if (widget.statusMessage != null) ...[
                          const SizedBox(height: 14),
                          _VerificationNotice(
                            key: widget.statusKey,
                            message: widget.statusMessage!,
                          ),
                        ],
                        const SizedBox(height: 8),
                        TextButton(
                          key: widget.resendKey,
                          onPressed: widget.resendEnabled && !widget.isResending
                              ? _resend
                              : null,
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF7131BA),
                            disabledForegroundColor: const Color(0xFF8D8390),
                          ),
                          child: widget.isResending
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(widget.resendLabel),
                        ),
                        if (widget.secondaryLabel != null)
                          TextButton(
                            key: widget.secondaryKey,
                            onPressed: widget.onSecondary == null
                                ? null
                                : _secondary,
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF7131BA),
                            ),
                            child: Text(widget.secondaryLabel!),
                          ),
                        const Spacer(),
                        const SizedBox(height: 20),
                        _VerificationActions(
                          largeText: largeText,
                          ink: ink,
                          isSubmitting: widget.isSubmitting || _inFlight,
                          canSubmit:
                              widget.canSubmit &&
                              !_inFlight &&
                              value.text.length == widget.codeLength,
                          onBack: _back,
                          onSubmit: _attemptSubmit,
                          submitLabel: widget.submitLabel,
                          submitKey: widget.submitKey,
                          backKey: widget.backKey,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class VerificationCodeRejectionShake extends StatelessWidget {
  const VerificationCodeRejectionShake({
    super.key,
    required this.attempt,
    required this.reduceMotion,
    required this.child,
  });

  final int attempt;
  final bool reduceMotion;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    key: ValueKey(attempt),
    tween: Tween(begin: 0, end: 1),
    duration: attempt > 0 && !reduceMotion
        ? const Duration(milliseconds: 250)
        : Duration.zero,
    builder: (context, value, child) => Transform.translate(
      offset: Offset(
        reduceMotion ? 0 : math.sin(value * math.pi * 6) * (1 - value) * 8,
        0,
      ),
      child: child,
    ),
    child: child,
  );
}

class _VerificationActions extends StatelessWidget {
  const _VerificationActions({
    required this.largeText,
    required this.ink,
    required this.isSubmitting,
    required this.canSubmit,
    required this.onBack,
    required this.onSubmit,
    required this.submitLabel,
    required this.submitKey,
    this.backKey,
  });

  final bool largeText;
  final Color ink;
  final bool isSubmitting;
  final bool canSubmit;
  final VoidCallback onBack;
  final VoidCallback onSubmit;
  final String submitLabel;
  final Key submitKey;
  final Key? backKey;

  @override
  Widget build(BuildContext context) {
    final backButton = TextButton.icon(
      key: backKey,
      onPressed: onBack,
      style: TextButton.styleFrom(foregroundColor: ink),
      icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 15),
      label: const Text('Back'),
    );
    final completeButton = VerificationPrimaryButton(
      buttonKey: submitKey,
      label: submitLabel,
      isSubmitting: isSubmitting,
      onPressed: canSubmit && !isSubmitting ? onSubmit : null,
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

class _VerificationNotice extends StatelessWidget {
  const _VerificationNotice({
    super.key,
    required this.message,
    this.isError = false,
  });

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

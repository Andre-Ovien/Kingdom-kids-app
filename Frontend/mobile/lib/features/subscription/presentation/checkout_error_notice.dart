import 'dart:async';
import 'package:flutter/material.dart';

/// Short errors only; an uncertain payment belongs in persistent status UI.
class CheckoutErrorNotice extends StatefulWidget {
  const CheckoutErrorNotice({
    required this.message,
    required this.onDismiss,
    super.key,
  });
  final String message;
  final VoidCallback onDismiss;
  @override
  State<CheckoutErrorNotice> createState() => _CheckoutErrorNoticeState();
}

class _CheckoutErrorNoticeState extends State<CheckoutErrorNotice>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock;
  Timer? _expiry;
  bool _dismissed = false;
  void _dismiss() {
    if (!_dismissed && mounted) {
      _dismissed = true;
      widget.onDismiss();
    }
  }

  @override
  void initState() {
    super.initState();
    _clock =
        AnimationController(vsync: this, duration: const Duration(seconds: 5))
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) _dismiss();
          })
          ..forward();
    _expiry = Timer(const Duration(seconds: 5), _dismiss);
  }

  @override
  void dispose() {
    _clock.dispose();
    _expiry?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: AnimatedBuilder(
            animation: _clock,
            builder: (context, _) => Opacity(
              opacity: _clock.value < .92 ? 1 : (1 - _clock.value) / .08,
              child: Semantics(
                liveRegion: true,
                child: Material(
                  key: const Key('checkout-error-notice'),
                  color: const Color(0xFFFFF0EF),
                  elevation: 8,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.error_outline_rounded,
                              color: Color(0xFFB3261E),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                widget.message,
                                style: const TextStyle(
                                  color: Color(0xFF632421),
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          key: const Key('checkout-error-countdown'),
                          widthFactor: 1 - _clock.value,
                          child: const ColoredBox(
                            color: Color(0xFFB3261E),
                            child: SizedBox(height: 3, width: double.infinity),
                          ),
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
    ),
  );
}

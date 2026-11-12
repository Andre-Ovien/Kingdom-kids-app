import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared six-slot OTP control. A single native text field handles paste,
/// deletion, numeric input and one-time-code autofill for every slot.
class VerificationCodeInput extends StatelessWidget {
  const VerificationCodeInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.length,
    required this.accent,
    required this.ink,
    required this.onSubmitted,
    this.enabled = true,
    this.semanticsLabel,
    this.filledColor,
    this.emptyColor,
    this.verified = false,
    this.rejected = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final int length;
  final Color accent;
  final Color ink;
  final ValueChanged<String> onSubmitted;
  final bool enabled;
  final String? semanticsLabel;
  final Color? filledColor;
  final Color? emptyColor;
  final bool verified;
  final bool rejected;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, _, child) => _buildSlots(context),
    );
  }

  Widget _buildSlots(BuildContext context) {
    final value = controller.text;
    return Semantics(
      label: semanticsLabel ?? '$length digit email verification code',
      value: verified
          ? 'Code verified'
          : '${value.length} of $length digits entered',
      liveRegion: verified,
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
                    duration: verified || rejected
                        ? Duration.zero
                        : const Duration(milliseconds: 160),
                    constraints: const BoxConstraints(
                      minWidth: 38,
                      maxWidth: 50,
                    ),
                    height: 58,
                    margin: EdgeInsets.only(right: index == length - 1 ? 0 : 5),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: filled
                          ? filledColor ?? Colors.white.withValues(alpha: 0.92)
                          : emptyColor ?? Colors.white.withValues(alpha: 0.42),
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(
                        color: verified
                            ? const Color(0xFF25844F)
                            : rejected
                            ? const Color(0xFFAD3451)
                            : active
                            ? accent
                            : ink.withValues(alpha: 0.42),
                        width: verified || rejected || active ? 2 : 1.2,
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
                enabled: enabled,
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
                  filled: false,
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

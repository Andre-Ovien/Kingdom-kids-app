import 'package:flutter/material.dart';

/// Shared primary action styling for verification and password recovery.
class VerificationPrimaryButton extends StatelessWidget {
  const VerificationPrimaryButton({
    super.key,
    required this.buttonKey,
    required this.label,
    required this.onPressed,
    this.isSubmitting = false,
  });

  final Key buttonKey;
  final String label;
  final VoidCallback? onPressed;
  final bool isSubmitting;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF29293B);
    return FilledButton(
      key: buttonKey,
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: ink,
        foregroundColor: Colors.white,
        textStyle: Theme.of(
          context,
        ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
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
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                SizedBox(width: 8),
                Icon(Icons.arrow_forward_ios_rounded, size: 15),
              ],
            ),
    );
  }
}

import 'package:flutter/material.dart';

/// Shared navigation for the first two photographic onboarding pages.
/// Both pages use the same geometry, with contrast adapted to their backdrop.
class OnboardingProgressDots extends StatelessWidget {
  const OnboardingProgressDots({
    super.key,
    required this.index,
    this.light = true,
  });

  final int index;
  final bool light;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Page ${index + 1} of 3',
    container: true,
    liveRegion: true,
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        final selected = i == index;
        return AnimatedContainer(
          key: ValueKey('onboarding-dot-$i-${light ? "light" : "dark"}'),
          duration: Duration(
            milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 240,
          ),
          curve: Curves.easeOutCubic,
          width: selected ? 18 : 6,
          height: 6,
          margin: EdgeInsets.only(right: i == 2 ? 0 : 6),
          decoration: BoxDecoration(
            color: selected
                ? light
                      ? Colors.white
                      : const Color(0xFF452004)
                : light
                ? const Color(0x75FFFFFF)
                : const Color(0x55452004),
            borderRadius: BorderRadius.circular(8),
          ),
        );
      }),
    ),
  );
}

class OnboardingArrowButton extends StatelessWidget {
  const OnboardingArrowButton({
    super.key,
    required this.onPressed,
    required this.buttonKey,
    this.light = true,
  });

  final VoidCallback onPressed;
  final Key buttonKey;
  final bool light;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Continue to the next onboarding page',
    button: true,
    onTap: onPressed,
    excludeSemantics: true,
    child: IconButton(
      key: buttonKey,
      onPressed: onPressed,
      tooltip: 'Continue to the next onboarding page',
      style: IconButton.styleFrom(
        minimumSize: const Size(52, 52),
        padding: const EdgeInsets.all(4),
        foregroundColor: light ? Colors.white : const Color(0xFF452004),
      ),
      icon: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: light ? const Color(0x20FFFFFF) : const Color(0x14452004),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: SizedBox(
          width: 24,
          height: 24,
          child: CustomPaint(
            painter: _OnboardingArrowPainter(
              color: light ? Colors.white : const Color(0xFF452004),
            ),
          ),
        ),
      ),
    ),
  );
}

class _OnboardingArrowPainter extends CustomPainter {
  const _OnboardingArrowPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
    Path()
      ..moveTo(5, 12)
      ..lineTo(19, 12)
      ..moveTo(13, 6)
      ..lineTo(19, 12)
      ..lineTo(13, 18),
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round,
  );

  @override
  bool shouldRepaint(_OnboardingArrowPainter oldDelegate) =>
      oldDelegate.color != color;
}

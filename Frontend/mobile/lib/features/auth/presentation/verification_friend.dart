import 'package:flutter/material.dart';

/// The original verification bear, shared without changing its default look.
class VerificationFriend extends StatelessWidget {
  const VerificationFriend({
    super.key,
    required this.reduceMotion,
    this.showMailbox = true,
    this.eyesClosed = false,
  });

  final bool reduceMotion;
  final bool showMailbox;
  final bool eyesClosed;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    image: true,
    label: 'Kingdom Kids bear',
    value: eyesClosed
        ? 'Eyes closed while password is being entered'
        : 'Eyes open',
    child: TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 680),
      curve: Curves.easeOutBack,
      builder: (context, value, child) => Transform.translate(
        offset: Offset(0, (1 - value) * 18),
        child: Transform.scale(scale: .88 + value * .12, child: child),
      ),
      child: TweenAnimationBuilder<double>(
        key: const Key('verification-friend-eye-animation'),
        tween: Tween(begin: 0, end: eyesClosed ? 1 : 0),
        duration: reduceMotion
            ? Duration.zero
            : Duration(milliseconds: eyesClosed ? 190 : 260),
        curve: eyesClosed ? Curves.easeInCubic : Curves.easeOutCubic,
        builder: (context, closure, child) => SizedBox(
          width: 160,
          height: 144,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                top: 4,
                left: 22,
                child: Transform.rotate(angle: -.28, child: const _FriendEar()),
              ),
              Positioned(
                top: 4,
                right: 22,
                child: Transform.rotate(angle: .28, child: const _FriendEar()),
              ),
              Positioned(
                top: 16,
                child: Container(
                  width: 126,
                  height: 108,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFB04E),
                    borderRadius: BorderRadius.circular(46),
                    border: Border.all(
                      color: const Color(0xFF29293B),
                      width: 2,
                    ),
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        top: 28,
                        left: 25,
                        child: _FriendEye(closure: closure),
                      ),
                      Positioned(
                        top: 28,
                        right: 25,
                        child: _FriendEye(closure: closure),
                      ),
                      const Positioned(
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
              if (showMailbox)
                Positioned(
                  bottom: 0,
                  child: Container(
                    key: const Key('verification-friend-mailbox'),
                    width: 72,
                    height: 45,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF5DE),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFF29293B),
                        width: 2,
                      ),
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
      ),
    ),
  );
}

class _FriendEar extends StatelessWidget {
  const _FriendEar();

  @override
  Widget build(BuildContext context) => Container(
    width: 42,
    height: 52,
    decoration: BoxDecoration(
      color: const Color(0xFFFF7482),
      borderRadius: BorderRadius.circular(15),
      border: Border.all(color: const Color(0xFF29293B), width: 2),
    ),
  );
}

class _FriendEye extends StatelessWidget {
  const _FriendEye({required this.closure});

  final double closure;

  @override
  Widget build(BuildContext context) {
    final openEye = Container(
      width: 28,
      height: 32,
      decoration: const BoxDecoration(
        color: Color(0xFFFFF5DE),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: const CircleAvatar(radius: 6, backgroundColor: Color(0xFF7131BA)),
    );
    if (closure <= 0) return openEye;
    return SizedBox(
      width: 28,
      height: 32,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Transform.scale(scaleY: 1 - closure.clamp(0, 1), child: openEye),
          Opacity(
            opacity: closure.clamp(0, 1),
            child: const CustomPaint(
              key: Key('verification-friend-closed-eyelid'),
              size: Size(28, 32),
              painter: _ClosedEyePainter(),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClosedEyePainter extends CustomPainter {
  const _ClosedEyePainter();

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
    Path()
      ..moveTo(3, 15)
      ..quadraticBezierTo(14, 21, 25, 15),
    Paint()
      ..color = const Color(0xFF29293B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round,
  );

  @override
  bool shouldRepaint(_ClosedEyePainter oldDelegate) => false;
}

import 'package:flutter/material.dart';

/// A family-friendly last line of defence for unexpected rendering failures.
///
/// It deliberately contains no exception details. Technical diagnostics still
/// flow through Flutter's error reporting without being displayed to a child.
class AppErrorFallback extends StatelessWidget {
  const AppErrorFallback({super.key});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.maybeOf(context) ?? const MediaQueryData();
    final textDirection = Directionality.maybeOf(context) ?? TextDirection.ltr;
    return MediaQuery(
      data: media,
      child: Directionality(
        textDirection: textDirection,
        child: Material(
          color: const Color(0xFFFFFCF6),
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: Semantics(
                  liveRegion: true,
                  label:
                      'This page needs a quick reset. Ask a grown-up to reopen Kingdom Kids.',
                  child: ExcludeSemantics(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 104,
                          height: 104,
                          decoration: const BoxDecoration(
                            color: Color(0xFFFFD34E),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.auto_awesome_rounded,
                            size: 52,
                            color: Color(0xFF211936),
                          ),
                        ),
                        const SizedBox(height: 28),
                        const Text(
                          'Oops—let’s try that again!',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Color(0xFF211936),
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            height: 1.15,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'This page needs a quick reset. Ask a grown-up to reopen Kingdom Kids.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Color(0xFF5E5968),
                            fontSize: 17,
                            fontWeight: FontWeight.w500,
                            height: 1.4,
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
}

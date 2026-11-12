import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../auth/data/auth_repository.dart';
import '../data/subscription_review_launch.dart';
import 'subscription_screen.dart';

/// Non-Release, one-time read-only destination. It cannot perform checkout and
/// rechecks the saved parent identity without fetching/clearing a family session.
class SubscriptionReviewScreen extends StatefulWidget {
  const SubscriptionReviewScreen({
    super.key,
    required this.arguments,
    this.authRepository,
  });
  final SubscriptionReviewArguments arguments;
  final AuthRepository? authRepository;
  @override
  State<SubscriptionReviewScreen> createState() =>
      _SubscriptionReviewScreenState();
}

class _SubscriptionReviewScreenState extends State<SubscriptionReviewScreen> {
  late final Future<bool> _allowed = _check();
  Future<bool> _check() async {
    try {
      final session = await (widget.authRepository ?? AuthRepository())
          .restoreSession();
      return hasSubscriptionReviewSession(session, DateTime.now()) &&
          session!.parent.id == widget.arguments.parentId;
    } catch (_) {
      return false;
    }
  }

  void _finish() => Navigator.of(context).pushReplacementNamed(
    widget.arguments.returnRoute,
    arguments: widget.arguments.returnArguments,
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: _allowed,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (snapshot.data != true) {
        return Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'A saved parent session is needed for this preview.',
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => Navigator.of(
                        context,
                      ).pushReplacementNamed(AppRoutes.login),
                      child: const Text('Parent sign in'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
      return SubscriptionScreen(reviewMode: true, onClose: _finish);
    },
  );
}

import 'package:flutter/material.dart';
import '../../../app/router.dart';
import '../../../core/errors/app_exception.dart';
import '../../auth/data/auth_repository.dart';
import '../../parental_controls/data/parent_settings_store.dart';
import '../../parental_controls/presentation/parental_controls_screen.dart'
    show showParentAccountDeletionDialog;
import '../../streak/data/streak_reminder_service.dart';
import 'hosted_subscription_scope.dart';
import 'checkout_error_notice.dart';

enum _AccountAction { signOut, privacy, passwordHelp, delete }

/// Essential account actions remain available without opening a child/settings shell.
class SubscriptionAccountActions extends StatefulWidget {
  const SubscriptionAccountActions({super.key});
  @override
  State<SubscriptionAccountActions> createState() =>
      _SubscriptionAccountActionsState();
}

class _SubscriptionAccountActionsState
    extends State<SubscriptionAccountActions> {
  bool _busy = false;
  OverlayEntry? _notice;
  AuthRepository get _auth =>
      HostedSubscriptionScope.authOf(context) ?? AuthRepository();

  void _removeNotice() {
    _notice?.remove();
    _notice?.dispose();
    _notice = null;
  }

  void _error(String message) {
    if (!mounted) return;
    _removeNotice();
    _notice = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: CheckoutErrorNotice(message: message, onDismiss: _removeNotice),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_notice!);
  }

  @override
  void dispose() {
    _removeNotice();
    super.dispose();
  }

  Future<void> _accountAction({required bool delete}) async {
    if (_busy) return;
    final auth = _auth;
    final navigator = Navigator.of(context);
    Object? owner;
    setState(() => _busy = true);
    try {
      final origin = await auth.captureParentAccessOwner();
      if (!mounted) return;
      if (origin == null) {
        navigator.pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
        return;
      }
      owner = origin.scope;
      String? password;
      if (delete) {
        password = await showParentAccountDeletionDialog(context);
        if (password == null || !mounted) return;
      }
      if ((await auth.captureParentAccessOwner())?.scope != owner || !mounted) {
        return;
      }
      if (delete) {
        await auth.deleteAccount(password: password!);
      } else {
        try {
          await auth.logout();
        } catch (_) {
          /* Check local exit below. */
        }
      }
      final current = await auth.captureParentAccessOwner();
      if (current != null) {
        if (current.scope == owner) {
          _error('We could not sign out right now. Try again.');
        }
        return; // A newer parent's session and preferences remain untouched.
      }
      if (delete) {
        try {
          await SecureParentSettingsStore().purgeAll();
        } catch (_) {
          /* Continue local cleanup. */
        }
      }
      try {
        await DeviceStreakReminderService().disable();
      } catch (_) {
        /* Account exit remains available. */
      }
      // Clearing the session can replace a restored child's adult-gate branch
      // and dispose this menu. Finish that owned exit through the navigator,
      // while a newer signed-in parent's session still prevents navigation.
      if (await auth.restoreSession() == null && navigator.mounted) {
        navigator.pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
      }
    } on AppException catch (error) {
      if (owner == null ||
          (await auth.captureParentAccessOwner())?.scope == owner) {
        _error(error.userMessage);
      }
    } catch (_) {
      _error('We could not complete that account request. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopupMenuButton<_AccountAction>(
    key: const Key('subscription-account-actions'),
    tooltip: 'Account options',
    enabled: !_busy,
    icon: _busy
        ? const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.more_horiz_rounded),
    itemBuilder: (_) => const [
      PopupMenuItem(value: _AccountAction.signOut, child: Text('Sign out')),
      PopupMenuItem(
        value: _AccountAction.privacy,
        child: Text('Privacy Policy'),
      ),
      PopupMenuItem(
        value: _AccountAction.passwordHelp,
        child: Text('Password help'),
      ),
      PopupMenuItem(
        value: _AccountAction.delete,
        child: Text('Delete account'),
      ),
    ],
    onSelected: (action) {
      switch (action) {
        case _AccountAction.signOut:
          _accountAction(delete: false);
        case _AccountAction.delete:
          _accountAction(delete: true);
        case _AccountAction.privacy:
          Navigator.of(context).pushNamed(AppRoutes.privacy);
        case _AccountAction.passwordHelp:
          Navigator.of(context).pushNamed(AppRoutes.passwordReset);
      }
    },
  );
}

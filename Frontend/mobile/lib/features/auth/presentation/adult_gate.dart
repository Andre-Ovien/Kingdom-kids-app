import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/errors/app_exception.dart';
import '../data/auth_repository.dart';
import 'session_expiry_navigation.dart';

/// Builds parent-only content only after the active parent re-enters their
/// password. The password and cached email never leave the auth layer/UI
/// lifecycle, and authorization lasts only for this widget instance.
class AdultGate extends StatefulWidget {
  const AdultGate({
    super.key,
    required this.protectedBuilder,
    this.repository,
    this.title = 'Parent check',
    this.reason = 'Enter the parent password to continue.',
    this.authorizationDuration = const Duration(minutes: 5),
    this.showBackButton = true,
    this.actions,
  });

  final WidgetBuilder protectedBuilder;
  final AuthRepository? repository;
  final String title;
  final String reason;
  final Duration authorizationDuration;
  final bool showBackButton;
  final Widget? actions;

  @override
  State<AdultGate> createState() => _AdultGateState();
}

class _AdultGateState extends State<AdultGate> with WidgetsBindingObserver {
  late final AuthRepository _repository;
  bool _isAuthorized = false;
  Timer? _authorizationTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _repository = widget.repository ?? AuthRepository();
  }

  @override
  void dispose() {
    _authorizationTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed || !_isAuthorized || !mounted) {
      return;
    }
    _revokeAuthorization();
  }

  void _authorize() {
    _authorizationTimer?.cancel();
    setState(() => _isAuthorized = true);
    _authorizationTimer = Timer(widget.authorizationDuration, () {
      if (mounted) _revokeAuthorization();
    });
  }

  void _revokeAuthorization() {
    _authorizationTimer?.cancel();
    _authorizationTimer = null;
    if (_isAuthorized && mounted) {
      setState(() => _isAuthorized = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isAuthorized) {
      return widget.protectedBuilder(context);
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Scaffold(
      key: const Key('adult-gate-screen'),
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('For parents'),
        automaticallyImplyLeading: widget.showBackButton,
        actions: widget.actions == null ? null : [widget.actions!],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 36),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: const Color(0xFF2D7D6F).withValues(alpha: 0.18),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.07),
                      blurRadius: 28,
                      offset: const Offset(0, 14),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: const BoxDecoration(
                          color: Color(0xFFE4F2ED),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.lock_person_rounded,
                          color: Color(0xFF2D7D6F),
                          size: 31,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        widget.title,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.reason,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.4,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 22),
                      _AdultPasswordForm(
                        repository: _repository,
                        onAuthorized: () {
                          if (mounted) _authorize();
                        },
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
  }
}

/// Requests one password reauthentication before a parent-only action.
///
/// Returning `false` means the parent cancelled or the active session expired;
/// callers must leave the protected action unopened.
Future<bool> showAdultGate({
  required BuildContext context,
  required AuthRepository repository,
  String title = 'Parent check',
  String reason = 'Enter the parent password to continue.',
}) async {
  final authorized = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      final media = MediaQuery.of(dialogContext);
      final availableHeight =
          (media.size.height - media.viewInsets.vertical - 32)
              .clamp(240.0, 720.0)
              .toDouble();
      return Dialog(
        key: const Key('adult-gate-dialog'),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 420,
            maxHeight: availableHeight,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 26, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.lock_person_rounded,
                  color: Color(0xFF2D7D6F),
                  size: 34,
                ),
                const SizedBox(height: 14),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(dialogContext).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(reason, textAlign: TextAlign.center),
                const SizedBox(height: 18),
                _AdultPasswordForm(
                  repository: repository,
                  onAuthorized: () => Navigator.of(dialogContext).pop(true),
                ),
                const SizedBox(height: 4),
                TextButton(
                  key: const Key('adult-gate-cancel'),
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
  return authorized ?? false;
}

class _AdultPasswordForm extends StatefulWidget {
  const _AdultPasswordForm({
    required this.repository,
    required this.onAuthorized,
  });

  final AuthRepository repository;
  final VoidCallback onAuthorized;

  @override
  State<_AdultPasswordForm> createState() => _AdultPasswordFormState();
}

class _AdultPasswordFormState extends State<_AdultPasswordForm> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) {
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      await widget.repository.reauthenticate(_passwordController.text);
      if (!mounted) return;
      _passwordController.clear();
      widget.onAuthorized();
    } on AppException catch (error) {
      if (mounted && returnToSignInIfSessionExpired(context, error)) {
        return;
      }
      if (mounted) {
        setState(() => _errorMessage = error.userMessage);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _errorMessage =
              'We could not complete the parent check. Please try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AutofillGroup(
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              key: const Key('adult-gate-password'),
              controller: _passwordController,
              obscureText: _obscurePassword,
              enabled: !_isSubmitting,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.password],
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Parent password',
                prefixIcon: const Icon(Icons.password_rounded),
                suffixIcon: IconButton(
                  tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                  onPressed: _isSubmitting
                      ? null
                      : () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                  ),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              validator: (value) => value == null || value.isEmpty
                  ? 'Enter the parent password.'
                  : null,
              onFieldSubmitted: (_) => _submit(),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  _errorMessage!,
                  key: const Key('adult-gate-error'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('adult-gate-submit'),
              onPressed: _isSubmitting ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2D7D6F),
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              icon: _isSubmitting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.lock_open_rounded),
              label: Text(_isSubmitting ? 'Checking…' : 'Unlock'),
            ),
          ],
        ),
      ),
    );
  }
}

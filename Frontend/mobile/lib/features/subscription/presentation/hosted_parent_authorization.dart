import 'package:flutter/material.dart';
import '../../../core/errors/app_exception.dart';
import 'checkout_error_notice.dart';

Future<bool> showHostedParentAuthorization(
  BuildContext context, {
  required String title,
  required String disclosure,
  Future<void> Function()? authorize,
  Future<void> Function(String password)? submit,
  bool subscribe = true,
  Listenable? validityChanges,
  bool Function()? isCurrent,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _HostedParentDialog(
        title: title,
        disclosure: disclosure,
        authorize: authorize,
        submit: submit,
        subscribe: subscribe,
        validityChanges: validityChanges,
        isCurrent: isCurrent,
      ),
    ) ??
    false;

class _HostedParentDialog extends StatefulWidget {
  const _HostedParentDialog({
    required this.title,
    required this.disclosure,
    required this.authorize,
    required this.submit,
    required this.subscribe,
    this.validityChanges,
    this.isCurrent,
  });
  final String title, disclosure;
  final Future<void> Function()? authorize;
  final Future<void> Function(String)? submit;
  final bool subscribe;
  final Listenable? validityChanges;
  final bool Function()? isCurrent;
  @override
  State<_HostedParentDialog> createState() => _HostedParentDialogState();
}

class _HostedParentDialogState extends State<_HostedParentDialog>
    with WidgetsBindingObserver {
  final _password = TextEditingController();
  bool _accepted = false, _busy = false, _closing = false;
  String? _error;
  int _notice = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.validityChanges?.addListener(_checkValidity);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkValidity());
  }

  void _closeObsolete() {
    if (!mounted || _closing) return;
    _closing = true;
    _password.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isActive) return;
      if (route.isCurrent) {
        Navigator.of(context).pop(false);
      } else {
        Navigator.of(context).removeRoute(route, false);
      }
    });
    // A covered dialog may have no scheduled frame of its own.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _checkValidity() {
    if (widget.isCurrent?.call() == false) _closeObsolete();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _password.clear();
      if (widget.subscribe) {
        _closeObsolete();
      } else if (mounted) {
        setState(() => _accepted = false);
      }
    }
  }

  @override
  void dispose() {
    widget.validityChanges?.removeListener(_checkValidity);
    WidgetsBinding.instance.removeObserver(this);
    _password.dispose();
    super.dispose();
  }

  void _showError(String message) {
    if (mounted) {
      setState(() {
        _error = message;
        _notice++;
      });
    }
  }

  Future<void> _submit() async {
    if (_busy ||
        _closing ||
        (widget.subscribe ? !_accepted : _password.text.isEmpty)) {
      return;
    }
    if (widget.isCurrent?.call() == false) {
      _closeObsolete();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.subscribe) {
        if (widget.authorize == null) {
          throw const AppException('Checkout is unavailable.');
        }
        await widget.authorize!();
      } else {
        if (widget.submit == null) {
          throw const AppException('This account action is unavailable.');
        }
        await widget.submit!(_password.text);
      }
      _password.clear();
      if (mounted && !_closing) Navigator.of(context).pop(true);
    } on AppException catch (error) {
      if (error.code == 'checkout_interrupted' ||
          error.code == 'account_changed') {
        _closeObsolete();
      } else {
        _showError(error.userMessage);
      }
    } catch (_) {
      _showError('We could not continue. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Stack(
      children: [
        AlertDialog(
          key: const Key('hosted-parent-authorization'),
          scrollable: true,
          title: Text(widget.title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.disclosure,
                key: const Key('hosted-subscription-disclosure'),
              ),
              const SizedBox(height: 16),
              if (!widget.subscribe)
                TextField(
                  key: const Key('hosted-parent-password'),
                  controller: _password,
                  obscureText: true,
                  enabled: !_busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Parent password',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _submit(),
                ),
              if (widget.subscribe)
                CheckboxListTile(
                  key: const Key('hosted-subscription-consent'),
                  contentPadding: EdgeInsets.zero,
                  value: _accepted,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _accepted = value == true),
                  title: const Text(
                    'I agree to the subscription terms shown above.',
                  ),
                ),
            ],
          ),
          actions: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const Key('hosted-authorize-continue'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 52),
                      shape: const StadiumBorder(),
                      textStyle: const TextStyle(
                        fontFamily: 'Avenir Next',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPressed:
                        _busy ||
                            _closing ||
                            (widget.subscribe
                                ? !_accepted
                                : _password.text.isEmpty)
                        ? null
                        : _submit,
                    child: _busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            widget.subscribe
                                ? 'Continue to Square'
                                : 'Stop renewals',
                            style: const TextStyle(fontFamily: 'Avenir Next'),
                          ),
                  ),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
        if (_error != null)
          CheckoutErrorNotice(
            key: ValueKey(_notice),
            message: _error!,
            onDismiss: () {
              if (mounted) setState(() => _error = null);
            },
          ),
      ],
    ),
  );
}

import 'package:flutter/material.dart';
import '../../../core/errors/app_exception.dart';
import 'checkout_error_notice.dart';

Future<bool> showHostedParentAuthorization(
  BuildContext context, {
  required String title,
  required String disclosure,
  required Future<void> Function(String password) submit,
  bool subscribe = true,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _HostedParentDialog(
        title: title,
        disclosure: disclosure,
        submit: submit,
        subscribe: subscribe,
      ),
    ) ??
    false;

class _HostedParentDialog extends StatefulWidget {
  const _HostedParentDialog({
    required this.title,
    required this.disclosure,
    required this.submit,
    required this.subscribe,
  });
  final String title, disclosure;
  final Future<void> Function(String) submit;
  final bool subscribe;
  @override
  State<_HostedParentDialog> createState() => _HostedParentDialogState();
}

class _HostedParentDialogState extends State<_HostedParentDialog>
    with WidgetsBindingObserver {
  final _password = TextEditingController();
  bool _accepted = false, _busy = false;
  String? _error;
  int _notice = 0;

  void _showError(String message) {
    if (mounted) {
      setState(() {
        _error = message;
        _notice++;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _password.clear();
      if (mounted) setState(() => _accepted = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _password.text.isEmpty || (widget.subscribe && !_accepted)) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.submit(_password.text);
      _password.clear();
      if (mounted) Navigator.of(context).pop(true);
    } on AppException catch (error) {
      _showError(error.userMessage);
    } catch (_) {
      _showError('We could not complete the parent check. Please try again.');
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
            TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('hosted-authorize-continue'),
              onPressed:
                  _busy ||
                      _password.text.isEmpty ||
                      (widget.subscribe && !_accepted)
                  ? null
                  : _submit,
              child: _busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      widget.subscribe ? 'Continue to Square' : 'Stop renewals',
                    ),
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

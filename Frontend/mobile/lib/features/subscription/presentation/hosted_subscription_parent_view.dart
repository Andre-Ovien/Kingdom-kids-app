import 'package:flutter/material.dart';
import '../data/hosted_subscription_controller.dart';
import '../domain/hosted_subscription.dart';
import 'hosted_parent_authorization.dart';
import 'subscription_screen.dart';

class HostedSubscriptionParentView extends StatefulWidget {
  const HostedSubscriptionParentView({required this.controller, super.key});
  final HostedSubscriptionController controller;
  @override
  State<HostedSubscriptionParentView> createState() =>
      _HostedSubscriptionParentViewState();
}

class _HostedSubscriptionParentViewState
    extends State<HostedSubscriptionParentView> {
  late final HostedParentAuthorization _authorize;
  late final HostedCancellationAuthorization _cancel;
  @override
  void initState() {
    super.initState();
    _authorize = (HostedQuote quote, submit) => showHostedParentAuthorization(
      context,
      title: 'For parents',
      disclosure: quote.disclosure,
      submit: submit,
    );
    _cancel = (submit) => showHostedParentAuthorization(
      context,
      title: 'Stop future renewals?',
      disclosure:
          'Your current paid access stays active. Future subscription payments will stop.',
      submit: submit,
      subscribe: false,
    );
    widget.controller.authorizeParent = _authorize;
    widget.controller.authorizeCancellation = _cancel;
  }

  @override
  void dispose() {
    if (identical(widget.controller.authorizeParent, _authorize)) {
      widget.controller.authorizeParent = null;
    }
    if (identical(widget.controller.authorizeCancellation, _cancel)) {
      widget.controller.authorizeCancellation = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SubscriptionScreen(sandboxCheckout: widget.controller);
}

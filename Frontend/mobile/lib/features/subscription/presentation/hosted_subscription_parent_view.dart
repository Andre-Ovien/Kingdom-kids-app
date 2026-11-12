import 'package:flutter/material.dart';
import '../data/hosted_subscription_controller.dart';
import '../domain/hosted_subscription.dart';
import 'hosted_parent_authorization.dart';
import 'subscription_screen.dart';
import '../../../app/router.dart';
import 'subscription_access_screen.dart';

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
  bool get _prepared =>
      ModalRoute.of(context)?.settings.arguments ==
      HostedPlansBackStack.prepared;

  void _closePlans() {
    final navigator = Navigator.of(context);
    if (!widget.controller.canBrowse && !_prepared) {
      navigator.pushNamedAndRemoveUntil(
        AppRoutes.subscriptionRequired,
        (_) => false,
      );
    } else if (navigator.canPop()) {
      navigator.pop();
    } else {
      navigator.pushReplacementNamed(
        widget.controller.canBrowse
            ? AppRoutes.home
            : AppRoutes.subscriptionRequired,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _authorize = (HostedQuote quote, submit) {
      final revision = widget.controller.authorizationRevision;
      return showHostedParentAuthorization(
        context,
        title: 'Subscription terms',
        disclosure: quote.disclosure,
        authorize: submit,
        validityChanges: widget.controller,
        isCurrent: () => widget.controller.isAuthorizationCurrent(revision),
      );
    };
    _cancel = (submit) {
      final owner = widget.controller.ownerScope;
      return showHostedParentAuthorization(
        context,
        title: 'Stop future renewals?',
        disclosure:
            'Your current paid access stays active. Future subscription payments will stop.',
        submit: submit,
        subscribe: false,
        validityChanges: widget.controller,
        isCurrent: () =>
            widget.controller.hasCurrentOwner &&
            widget.controller.ownerScope == owner,
      );
    };
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
  Widget build(BuildContext context) => PopScope(
    canPop: _prepared || widget.controller.canBrowse,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _closePlans();
    },
    child: SubscriptionScreen(
      sandboxCheckout: widget.controller,
      onClose: _closePlans,
    ),
  );
}

import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../privacy/presentation/privacy_policy_screen.dart';
import '../data/sandbox_checkout.dart';
import '../data/hosted_subscription_controller.dart';
import '../domain/subscription_plan.dart';

const _blue = Color(0xFF1457FF);
const _ink = Color(0xFF191B24);
const _muted = Color(0xFF797C89);
const _canvas = Color(0xFFF3F4F7);

TextStyle _type(
  double size, {
  Color color = _ink,
  FontWeight weight = FontWeight.w500,
  double height = 1.25,
  double spacing = 0,
}) => TextStyle(
  fontFamily: 'Avenir Next',
  fontFamilyFallback: const ['SF Pro Display', 'Helvetica Neue'],
  fontSize: size,
  height: height,
  fontWeight: weight,
  color: color,
  letterSpacing: spacing,
);

/// Approved plan information. Checkout remains disabled in normal builds and
/// previews. The isolated sandbox route may supply a server-backed test action.
class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({
    super.key,
    this.reviewMode = false,
    this.previewDate,
    this.onClose,
    this.sandboxCheckout,
    this.showClose = true,
    this.accountActions,
  });
  final bool reviewMode;
  final DateTime? previewDate;
  final VoidCallback? onClose;
  final ParentCheckoutController? sandboxCheckout;
  final bool showClose;
  final Widget? accountActions;
  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  SubscriptionBillingPeriod _period = SubscriptionBillingPeriod.monthly;
  late final DateTime _today = widget.previewDate ?? DateTime.now();
  ParentCheckoutController? get _checkout =>
      widget.reviewMode ? null : widget.sandboxCheckout;
  bool get _singlePeriod =>
      _checkout?.configuration.isControlledProductionEnabled == true;

  @override
  void initState() {
    super.initState();
    _checkout?.addListener(_checkoutChanged);
  }

  @override
  void didUpdateWidget(covariant SubscriptionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldCheckout = oldWidget.reviewMode ? null : oldWidget.sandboxCheckout;
    if (oldCheckout != _checkout) {
      oldCheckout?.removeListener(_checkoutChanged);
      _checkout?.addListener(_checkoutChanged);
    }
  }

  @override
  void dispose() {
    _checkout?.removeListener(_checkoutChanged);
    super.dispose();
  }

  void _checkoutChanged() {
    if (mounted) setState(() {});
  }

  String get _sandboxNotice {
    final checkout = _checkout!;
    if (checkout.access?.complimentaryAccess == true) {
      return 'Complimentary access active.';
    }
    if (checkout is HostedSubscriptionController &&
        checkout.persistentStatus != null) {
      return checkout.persistentStatus!;
    }
    if (checkout.checking) return 'Checking access…';
    if (checkout.error != null) return checkout.error!;
    if (checkout.access?.state == SandboxAccessState.paid) {
      return 'Access active. No additional payment is needed.';
    }
    final state = switch (checkout.access?.state) {
      SandboxAccessState.paid => 'Paid access confirmed.',
      SandboxAccessState.unpaid => 'No active subscription.',
      _ => 'Access status unknown.',
    };
    final capability = checkout.access?.checkoutAvailable == true
        ? 'Continue in your browser.'
        : 'Checkout unavailable.';
    return '$state $capability';
  }

  Widget _footer(Widget child) => _checkout == null
      ? child
      : ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .6,
          ),
          child: SingleChildScrollView(
            key: const Key('subscription-sandbox-actions'),
            child: child,
          ),
        );

  void _close() {
    if (!widget.showClose) return;
    if (widget.onClose != null) {
      widget.onClose!();
      return;
    }
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      navigator.pushReplacementNamed(AppRoutes.home);
    }
  }

  void _details() {
    final navigator = Navigator.of(context);
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: _canvas,
      builder: (context) => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Billing details', style: _type(23, weight: FontWeight.w600)),
            const SizedBox(height: 16),
            Text(
              _singlePeriod
                  ? r'Monthly: $9.99 USD for a full 30 days of access. Automatic renewal is off.'
                  : r'Monthly: $9.99 USD today for a full 30 days of access, then $9.99 USD every 30 days.',
              style: _type(14, height: 1.5),
            ),
            const SizedBox(height: 14),
            Text(
              _singlePeriod
                  ? r'Yearly: $99.90 USD for 12 full calendar months of access. Automatic renewal is off. Pay for 10 months and get 12 months of access, saving $19.98 compared with twelve $9.99 payments.'
                  : r'Yearly: $99.90 USD today for 12 full calendar months, renewing on your purchase anniversary each year. A 29 February anniversary renews on 28 February in a non-leap year. Pay for 10 months and get 12 months of access, saving $19.98 compared with twelve $9.99 payments.',
              style: _type(14, height: 1.5),
            ),
            const SizedBox(height: 14),
            Text(
              _checkout is HostedSubscriptionController
                  ? 'Continue to Square to enter your card details and complete payment.'
                  : _checkout != null
                  ? 'Continue to secure card payment in your browser. Sign in with the same parent account if asked.'
                  : 'Checkout is unavailable. Exact dates and the billing timezone will be shown before payment.',
              style: _type(14, height: 1.5),
            ),
            if (widget.accountActions == null) ...[
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  navigator.pushNamed(
                    _checkout is HostedSubscriptionController &&
                            !(_checkout as HostedSubscriptionController)
                                .canBrowse
                        ? AppRoutes.subscriptionRequired
                        : AppRoutes.parentalControls,
                  );
                },
                child: Text(
                  _checkout is HostedSubscriptionController &&
                          !(_checkout as HostedSubscriptionController).canBrowse
                      ? 'Account options'
                      : 'Parent account settings',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final back = IconButton(
      key: const Key('subscription-back'),
      tooltip: 'Back',
      onPressed: _close,
      style: IconButton.styleFrom(
        backgroundColor: Colors.white,
        minimumSize: const Size(44, 44),
      ),
      icon: const Icon(Icons.chevron_left_rounded, size: 24, color: _ink),
    );
    final title = Text(
      'Subscription',
      style: _type(23, weight: FontWeight.w600, spacing: -.6),
    );
    if (MediaQuery.textScalerOf(context).scale(14) > 20) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showClose || widget.accountActions != null) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (widget.showClose) back else const SizedBox.shrink(),
                if (widget.accountActions != null) widget.accountActions!,
              ],
            ),
            const SizedBox(height: 8),
          ],
          title,
        ],
      );
    }
    return Row(
      children: [
        if (widget.showClose) ...[back, const SizedBox(width: 10)],
        Expanded(child: title),
        if (widget.accountActions != null) widget.accountActions!,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_checkout?.access?.complimentaryAccess == true) {
      return Scaffold(
        key: const Key('complimentary-access-screen'),
        backgroundColor: _canvas,
        appBar: AppBar(
          title: const Text('Complimentary access'),
          leading: IconButton(
            onPressed: _close,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
        ),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.auto_stories_rounded,
                      size: 64,
                      color: _blue,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Complimentary access active',
                      style: _type(27, weight: FontWeight.w700),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Your family can explore stories and games. No payment is required for this access.',
                      style: _type(16, height: 1.5),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _close,
                      style: FilledButton.styleFrom(
                        shape: const StadiumBorder(),
                        textStyle: _type(16),
                      ),
                      child: const Text('Continue'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    final yearly = _period == SubscriptionBillingPeriod.yearly;
    final renewal = _period.exampleRenewal(_today);
    final nextLabel = widget.reviewMode
        ? subscriptionDateLabel(renewal, includeYear: yearly)
        : yearly
        ? 'After 12 months'
        : 'After 30 days';
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _blue,
          brightness: Brightness.light,
        ),
        textTheme: theme.textTheme.apply(bodyColor: _ink, displayColor: _ink),
      ),
      child: Scaffold(
        key: const Key('subscription-screen'),
        backgroundColor: _canvas,
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  key: const Key('subscription-scroll'),
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _header(context),
                      const SizedBox(height: 17),
                      _DurationSwitch(
                        yearly: yearly,
                        onChanged: (period) => setState(() => _period = period),
                      ),
                      const SizedBox(height: 16),
                      _PlanCard(yearly: yearly, singlePeriod: _singlePeriod),
                      const SizedBox(height: 20),
                      Text(
                        'How your plan works',
                        style: _type(
                          20,
                          weight: FontWeight.w600,
                          spacing: -.45,
                        ),
                      ),
                      const SizedBox(height: 18),
                      _BillingStep(
                        icon: Icons.lock_open_rounded,
                        title: 'Today · ${_period.price} USD',
                        detail: yearly
                            ? 'Unlock every story, game and read-along for 12 months.'
                            : 'Unlock every story, game and read-along for 30 days.',
                        line: true,
                      ),
                      _BillingStep(
                        icon: Icons.calendar_today_rounded,
                        title: _singlePeriod
                            ? yearly
                                  ? '12 calendar months of access'
                                  : '30 days of access'
                            : '$nextLabel · ${_period.price} USD',
                        detail: _singlePeriod
                            ? 'Your full access period starts after payment is confirmed.'
                            : yearly
                            ? 'Your next full yearly payment after 12 calendar months.'
                            : 'Your next full payment after 30 days of access.',
                        line: true,
                      ),
                      _BillingStep(
                        icon: Icons.autorenew_rounded,
                        title: _singlePeriod
                            ? 'Automatic renewal is off'
                            : yearly
                            ? 'Every year after that'
                            : 'Every 30 days',
                        detail: _singlePeriod
                            ? 'You will not be charged again automatically.'
                            : '${_period.price} USD ${yearly ? 'yearly' : 'every 30 days'}. Stop future renewals anytime.',
                        line: false,
                      ),
                    ],
                  ),
                ),
              ),
              _footer(
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _checkout != null
                            ? _sandboxNotice
                            : widget.reviewMode
                            ? 'Preview only · Example dates · No payment can be made.'
                            : 'Checkout is currently unavailable.',
                        key: Key(
                          _checkout != null
                              ? 'subscription-sandbox-notice'
                              : widget.reviewMode
                              ? 'subscription-review-notice'
                              : 'subscription-unavailable-notice',
                        ),
                        textAlign: TextAlign.center,
                        style: _type(11, color: _muted, height: 1.35),
                      ),
                      const SizedBox(height: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          minWidth: double.infinity,
                          minHeight: 54,
                        ),
                        child: FilledButton(
                          key: const Key('subscription-parent-continue'),
                          onPressed: _checkout?.canOpen == true
                              ? () => _checkout!.openCheckout(
                                  billingPeriod: _period,
                                )
                              : null,
                          style: FilledButton.styleFrom(
                            disabledBackgroundColor: _blue,
                            disabledForegroundColor: Colors.white,
                            backgroundColor: _blue,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 13,
                            ),
                            shape: const StadiumBorder(),
                            textStyle: _type(
                              15,
                              color: Colors.white,
                              weight: FontWeight.w700,
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.lock_outline_rounded,
                                size: 17,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  _checkout != null
                                      ? _checkout!.busy
                                            ? 'Checking…'
                                            : _checkout!.access?.state ==
                                                  SandboxAccessState.paid
                                            ? 'Access active'
                                            : 'Proceed'
                                      : 'Checkout unavailable',
                                  textAlign: TextAlign.center,
                                  style: _type(
                                    15,
                                    color: Colors.white,
                                    weight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Wrap(
                        alignment: WrapAlignment.center,
                        children: [
                          if (_checkout != null)
                            TextButton(
                              key: const Key('subscription-check-access'),
                              onPressed: _checkout!.busy
                                  ? null
                                  : _checkout!.refresh,
                              child: Text(
                                'Check access',
                                style: _type(11, color: _muted),
                              ),
                            ),
                          if (_checkout?.access?.managementAvailable == true)
                            TextButton(
                              key: const Key('subscription-manage'),
                              onPressed: _checkout!.canManage
                                  ? _checkout!.openManagement
                                  : null,
                              child: Text(
                                'Manage subscription',
                                style: _type(11, color: _muted),
                              ),
                            ),
                          TextButton(
                            key: const Key('subscription-billing-details'),
                            onPressed: _details,
                            child: Text(
                              'Billing details',
                              style: _type(11, color: _muted),
                            ),
                          ),
                          TextButton(
                            key: const Key('subscription-privacy-policy'),
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const PrivacyPolicyScreen(),
                              ),
                            ),
                            child: Text(
                              'Privacy Policy',
                              style: _type(11, color: _muted),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.yearly, this.singlePeriod = false});
  final bool yearly;
  final bool singlePeriod;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: ShapeDecoration(
      color: Colors.white,
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(36)),
      shadows: [
        BoxShadow(
          color: const Color(0xFF242A44).withValues(alpha: .035),
          blurRadius: 26,
          offset: const Offset(0, 8),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          runSpacing: 9,
          children: [
            Text(
              yearly ? 'Yearly plan' : 'Monthly plan',
              style: _type(15, weight: FontWeight.w600),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFFEAF0FF),
                borderRadius: BorderRadius.circular(30),
              ),
              child: Text(
                yearly ? '2 MONTHS FREE' : 'ALL ACCESS',
                style: _type(
                  9,
                  color: _blue,
                  weight: FontWeight.w800,
                  spacing: .6,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 15),
        _SubscriptionPrice(yearly: yearly, singlePeriod: singlePeriod),
        const SizedBox(height: 16),
        const Divider(color: Color(0xFFEEF0F5), thickness: 1, height: 1),
        const SizedBox(height: 17),
        const _Benefit('Every Bible story & read-along'),
        const SizedBox(height: 9),
        const _Benefit('Puzzles, quizzes & matching'),
        const SizedBox(height: 9),
        const _Benefit('Progress for every explorer'),
      ],
    ),
  );
}

class _SubscriptionPrice extends StatelessWidget {
  const _SubscriptionPrice({required this.yearly, this.singlePeriod = false});
  final bool yearly;
  final bool singlePeriod;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final value = yearly ? r'$99.90' : r'$9.99';
      final unit = singlePeriod
          ? yearly
                ? 'USD for 12 months'
                : 'USD for 30 days'
          : yearly
          ? 'USD / year'
          : 'USD every 30 days';
      final scaler = MediaQuery.textScalerOf(context);
      final style = _type(44, weight: FontWeight.w600, height: 1, spacing: -2);
      final unitStyle = _type(12, color: _muted, weight: FontWeight.w500);
      double width(String text, TextStyle textStyle) => (TextPainter(
        text: TextSpan(text: text, style: textStyle),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout()).width;
      final priceWidth = width(value, style);
      if (priceWidth + 7 + width(unit, unitStyle) <= constraints.maxWidth) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value, style: style),
            const SizedBox(width: 7),
            Text(unit, style: unitStyle),
          ],
        );
      }
      // Preserve the complete amount, move the unit below, and let large type
      // grow until it reaches available width instead of clipping the currency.
      final fitted = priceWidth > constraints.maxWidth
          ? style.copyWith(
              fontSize: 44 * constraints.maxWidth / priceWidth * .99,
            )
          : style;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: fitted),
          const SizedBox(height: 7),
          Text(unit, style: unitStyle),
        ],
      );
    },
  );
}

class _Benefit extends StatelessWidget {
  const _Benefit(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 19,
        height: 19,
        decoration: const BoxDecoration(color: _ink, shape: BoxShape.circle),
        child: const Icon(Icons.check_rounded, size: 13, color: Colors.white),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Text(label, style: _type(12.5, weight: FontWeight.w500)),
      ),
    ],
  );
}

class _BillingStep extends StatelessWidget {
  const _BillingStep({
    required this.icon,
    required this.title,
    required this.detail,
    required this.line,
  });
  final IconData icon;
  final String title, detail;
  final bool line;
  @override
  Widget build(BuildContext context) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 34,
          child: Column(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: const BoxDecoration(
                  color: _blue,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 16, color: Colors.white),
              ),
              if (line)
                Expanded(
                  child: Container(width: 2, color: const Color(0xFFCDD6FF)),
                ),
            ],
          ),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(top: 1, bottom: line ? 17 : 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: _type(13, weight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(detail, style: _type(11.5, color: _muted, height: 1.35)),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _DurationSwitch extends StatelessWidget {
  const _DurationSwitch({required this.yearly, required this.onChanged});
  final ValueChanged<SubscriptionBillingPeriod> onChanged;
  final bool yearly;
  @override
  Widget build(BuildContext context) => Container(
    height: 48,
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: const Color(0xFFE8EAF0),
      borderRadius: BorderRadius.circular(30),
    ),
    child: Row(
      children: [
        _item('Monthly', !yearly),
        const SizedBox(width: 3),
        _item('Yearly', yearly),
      ],
    ),
  );
  Widget _item(String label, bool selected) => Expanded(
    child: Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? _blue : Colors.transparent,
        borderRadius: BorderRadius.circular(26),
        child: InkWell(
          key: Key('subscription-${label.toLowerCase()}'),
          borderRadius: BorderRadius.circular(26),
          onTap: () => onChanged(
            label == 'Monthly'
                ? SubscriptionBillingPeriod.monthly
                : SubscriptionBillingPeriod.yearly,
          ),
          child: Center(
            child: Text(
              label,
              style: _type(
                12,
                color: selected ? Colors.white : _muted,
                weight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

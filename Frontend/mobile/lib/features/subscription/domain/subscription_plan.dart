/// Approved display terms. These values never authorize a payment.
enum SubscriptionBillingPeriod { monthly, yearly }

extension SubscriptionBillingPeriodDisplay on SubscriptionBillingPeriod {
  int get amountMinor => this == SubscriptionBillingPeriod.monthly ? 999 : 9990;
  String get price =>
      this == SubscriptionBillingPeriod.monthly ? r'$9.99' : r'$99.90';
  String get title => this == SubscriptionBillingPeriod.monthly
      ? 'Monthly plan'
      : 'Yearly plan';
  String get unit => this == SubscriptionBillingPeriod.monthly
      ? 'USD every 30 days'
      : 'USD / year';

  /// Calendar-date examples only. A real purchase must use the server quote's
  /// canonical immutable first_renewal_at and billing timezone, not this
  /// example clock. Annual examples preserve the anniversary, clamping Feb 29.
  DateTime exampleRenewal(DateTime paymentAt) {
    if (this == SubscriptionBillingPeriod.yearly) {
      final paid = paymentAt;
      final lastDay = DateTime.utc(paid.year + 1, paid.month + 1, 0).day;
      final createDate = paid.isUtc ? DateTime.utc : DateTime.new;
      return createDate(
        paid.year + 1,
        paid.month,
        paid.day > lastDay ? lastDay : paid.day,
        paid.hour,
        paid.minute,
        paid.second,
        paid.millisecond,
        paid.microsecond,
      );
    }
    return paymentAt.add(const Duration(days: 30));
  }
}

String subscriptionDateLabel(DateTime date, {bool includeYear = false}) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${date.day} ${months[date.month - 1]}${includeYear ? ' ${date.year}' : ''}';
}

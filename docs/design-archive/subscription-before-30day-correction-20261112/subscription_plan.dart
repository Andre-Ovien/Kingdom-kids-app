/// Approved display terms. These values never authorize a payment.
enum SubscriptionBillingPeriod { monthly, yearly }

extension SubscriptionBillingPeriodDisplay on SubscriptionBillingPeriod {
  int get amountMinor =>
      this == SubscriptionBillingPeriod.monthly ? 999 : 10789;
  String get price =>
      this == SubscriptionBillingPeriod.monthly ? r'$9.99' : r'$107.89';
  String get title => this == SubscriptionBillingPeriod.monthly
      ? 'Monthly plan'
      : 'Yearly plan';
  String get unit =>
      this == SubscriptionBillingPeriod.monthly ? 'USD / month' : 'USD / year';

  /// Calendar-date examples only. A real purchase must use the server quote's
  /// canonical merchant timezone and immutable first_renewal_at, not this clock.
  DateTime exampleRenewal(DateTime today) {
    if (this == SubscriptionBillingPeriod.yearly) {
      return DateTime.utc(today.year + 1, today.month, 28);
    }
    final month = today.day < 28 ? today.month : today.month + 1;
    return DateTime.utc(today.year, month, 28);
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

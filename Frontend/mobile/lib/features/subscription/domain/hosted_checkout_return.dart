/// Correlation only. Neither return link is a credential or proof of payment.
class HostedCheckoutReturn {
  const HostedCheckoutReturn(this.attemptId, this.state);
  final String attemptId;
  final String state;
  static final uuid = RegExp(
    r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$',
  );

  static HostedCheckoutReturn? parse(String raw) {
    if (raw.length > 1024) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.hasPort) {
      return null;
    }
    final https =
        uri.scheme == 'https' &&
        uri.host == 'kingdom-kids.app' &&
        uri.path == '/payments/return/';
    final fallback =
        uri.scheme == 'kingdomkids' &&
        uri.host == 'payments' &&
        uri.path == '/return/';
    if (!https && !fallback) return null;
    final query = uri.queryParametersAll;
    if (query.length != 2 ||
        query.keys.any((key) => key != 'attempt' && key != 'state') ||
        query.values.any((values) => values.length != 1)) {
      return null;
    }
    final attempt = query['attempt']?.single;
    final state = query['state']?.single;
    if (attempt == null ||
        state == null ||
        !uuid.hasMatch(attempt) ||
        !uuid.hasMatch(state)) {
      return null;
    }
    return HostedCheckoutReturn(attempt.toLowerCase(), state.toLowerCase());
  }
}

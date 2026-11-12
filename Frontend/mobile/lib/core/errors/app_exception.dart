class AppException implements Exception {
  const AppException(
    this.message, {
    this.code,
    this.statusCode,
    this.details = const {},
  });

  final String message;
  final String? code;
  final int? statusCode;
  final Map<String, dynamic> details;

  /// A release-safe message for surfaces that are visible to families.
  ///
  /// [message] intentionally keeps the original service message for logging
  /// and diagnostics. UI code should use this getter so an upstream HTML
  /// error page, status code, or stack trace never reaches a child.
  String get userMessage {
    final normalizedCode = code?.trim().toLowerCase();
    if (statusCode == 403 && normalizedCode == 'subscription_required') {
      return 'A parent needs to check your access.';
    }
    if (normalizedCode == 'invalid_credentials') {
      return 'That email or password did not match our records.';
    }
    if (normalizedCode == 'email_verification_required') {
      return 'Please verify your email address before signing in.';
    }
    if (normalizedCode == 'network_error') {
      return 'We couldn’t connect right now. Check your internet and try again.';
    }
    if (normalizedCode == 'request_timeout' ||
        normalizedCode == 'timeout_error' ||
        statusCode == 408) {
      return 'This is taking longer than expected. Please try again.';
    }

    switch (statusCode) {
      case 401:
        return 'Please sign in again to continue.';
      case 403:
        return 'A parent needs to help with that.';
      case 404:
        return 'We couldn’t find that content. It may be unavailable right now.';
      case 429:
        return 'Things are busy right now. Wait a moment, then try again.';
    }
    if (statusCode != null && statusCode! >= 500) {
      return 'Kingdom Kids is having trouble right now. Please try again soon.';
    }

    final candidate = message.trim();
    if (candidate.isEmpty || _looksTechnical(candidate)) {
      return 'Something went wrong. Please try again.';
    }
    return candidate;
  }

  @override
  String toString() => message;
}

bool _looksTechnical(String message) {
  final normalized = message.toLowerCase();
  if (message.length > 240 ||
      normalized.startsWith('{') ||
      normalized.startsWith('[') ||
      normalized.contains('<!doctype') ||
      normalized.contains('<html') ||
      normalized.contains('traceback') ||
      normalized.contains('stack trace') ||
      normalized.contains('socketexception') ||
      normalized.contains('clientexception') ||
      normalized.contains('typeerror') ||
      normalized.contains('null check operator') ||
      normalized.contains('connection refused') ||
      normalized.contains('internal server error') ||
      normalized.contains('csrf') ||
      normalized.contains('django') ||
      normalized.contains('nginx')) {
    return true;
  }

  return RegExp(
        r'\b(?:http|status)(?:\s+code)?\s*[:=-]?\s*[45]\d\d\b',
        caseSensitive: false,
      ).hasMatch(message) ||
      RegExp(r'\b[a-z][a-z0-9]*_[a-z0-9_]+\b').hasMatch(message);
}

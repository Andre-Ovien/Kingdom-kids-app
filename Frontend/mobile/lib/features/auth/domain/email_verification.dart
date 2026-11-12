class PendingEmailVerification {
  const PendingEmailVerification({
    required this.challengeId,
    required this.email,
    required this.destinationHint,
    required this.expiresInSeconds,
    required this.resendAfterSeconds,
    this.deliveryDelayed = false,
  });

  final String challengeId;
  final String email;
  final String destinationHint;
  final int expiresInSeconds;
  final int resendAfterSeconds;
  final bool deliveryDelayed;

  factory PendingEmailVerification.fromJson(
    Map<String, dynamic> json, {
    String fallbackEmail = '',
  }) {
    final verification = _mapFrom(json['verification'] ?? json);
    return PendingEmailVerification(
      challengeId: (verification['challenge_id'] ?? verification['id'] ?? '')
          .toString(),
      email: (verification['email'] ?? json['email'] ?? fallbackEmail)
          .toString(),
      destinationHint:
          (verification['destination_hint'] ??
                  verification['masked_email'] ??
                  verification['email'] ??
                  json['email'] ??
                  '')
              .toString(),
      expiresInSeconds: _intFrom(
        verification['expires_in'] ?? verification['expires_in_seconds'],
        fallback: 600,
      ),
      resendAfterSeconds: _intFrom(
        verification['resend_after'] ?? verification['resend_after_seconds'],
        fallback: 60,
      ),
      deliveryDelayed:
          verification['delivery_delayed'] == true ||
          json['verification_delivery_delayed'] == true ||
          json['code'] == 'verification_delivery_delayed',
    );
  }
}

Map<String, dynamic> _mapFrom(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map(
      (key, nestedValue) => MapEntry(key.toString(), nestedValue),
    );
  }
  return const {};
}

int _intFrom(Object? value, {required int fallback}) {
  if (value is int) {
    return value;
  }
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

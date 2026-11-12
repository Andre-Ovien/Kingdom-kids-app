class PendingPasswordReset {
  const PendingPasswordReset({
    required this.challengeId,
    required this.expiresInSeconds,
  });

  final String challengeId;
  final int expiresInSeconds;

  factory PendingPasswordReset.fromJson(Map<String, dynamic> json) {
    final challengeId = (json['challenge_id'] ?? '').toString().trim();
    final expiresInSeconds = _intFrom(json['expires_in']);
    if (challengeId.isEmpty || expiresInSeconds <= 0) {
      throw const FormatException('Incomplete password reset response.');
    }
    return PendingPasswordReset(
      challengeId: challengeId,
      expiresInSeconds: expiresInSeconds,
    );
  }
}

int _intFrom(Object? value) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

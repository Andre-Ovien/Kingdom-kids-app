import 'dart:math';

class RegisterParentRequest {
  const RegisterParentRequest({required this.email, required this.password});

  final String email;
  final String password;

  Map<String, dynamic> toJson() => {
    'email': email.trim().toLowerCase(),
    'password': password,
    'password_confirmation': password,
  };
}

class LoginRequest {
  const LoginRequest({required this.email, required this.password});

  final String email;
  final String password;

  Map<String, dynamic> toJson() => {
    'email': email.trim().toLowerCase(),
    'password': password,
  };
}

class VerifyEmailRequest {
  const VerifyEmailRequest({required this.challengeId, required this.code});

  final String challengeId;
  final String code;

  Map<String, dynamic> toJson() => {
    'challenge_id': challengeId,
    'code': code.trim(),
  };
}

class CreateKidProfileRequest {
  const CreateKidProfileRequest({
    required this.displayName,
    required this.avatarKey,
    required this.operationId,
  });

  final String displayName;
  final String avatarKey;
  final String operationId;

  Map<String, dynamic> toJson() => {
    'display_name': displayName.trim(),
    'avatar_key': avatarKey,
    'operation_id': operationId,
  };
}

/// Generates an RFC 4122 version 4 identifier for one logical profile-create
/// operation. The presentation layer keeps this value stable across retries.
String newKidProfileCreationOperationId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-'
      '${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

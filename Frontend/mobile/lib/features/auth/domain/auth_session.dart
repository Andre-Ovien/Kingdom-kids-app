import 'kid_profile.dart';
import 'parent_account.dart';

/// The authenticated parent and the profiles currently available to them.
class AuthSession {
  const AuthSession({
    required this.parent,
    required this.accessToken,
    this.refreshToken,
    this.profiles = const [],
  });

  final ParentAccount parent;
  final String accessToken;
  final String? refreshToken;
  final List<KidProfile> profiles;

  bool get hasProfiles => profiles.isNotEmpty;

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    final parentJson = _mapFrom(
      json['parent'] ?? json['user'] ?? json['account'],
    );
    final profilesJson =
        json['profiles'] ??
        json['kid_profiles'] ??
        parentJson['kid_profiles'] ??
        const [];
    final parentId = parentJson['id']?.toString() ?? '';
    final profiles = profilesJson is List
        ? profilesJson
              .whereType<Map>()
              .map((profile) {
                final kidProfile = KidProfile.fromJson(_mapFrom(profile));
                return kidProfile.parentId.isEmpty && parentId.isNotEmpty
                    ? kidProfile.copyWith(parentId: parentId)
                    : kidProfile;
              })
              .toList(growable: false)
        : const <KidProfile>[];

    return AuthSession(
      parent: ParentAccount.fromJson(parentJson),
      accessToken:
          (json['access_token'] ?? json['access'] ?? json['token'] ?? '')
              .toString(),
      refreshToken: _nullableString(json['refresh_token'] ?? json['refresh']),
      profiles: profiles,
    );
  }

  Map<String, dynamic> toJson() => {
    'parent': parent.toJson(),
    'access_token': accessToken,
    if (refreshToken != null) 'refresh_token': refreshToken,
    'profiles': profiles.map((profile) => profile.toJson()).toList(),
  };

  AuthSession copyWith({
    ParentAccount? parent,
    String? accessToken,
    String? refreshToken,
    List<KidProfile>? profiles,
  }) {
    return AuthSession(
      parent: parent ?? this.parent,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      profiles: profiles ?? this.profiles,
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

String? _nullableString(Object? value) {
  final result = value?.toString().trim();
  return result == null || result.isEmpty ? null : result;
}

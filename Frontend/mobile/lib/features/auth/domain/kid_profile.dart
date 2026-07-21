/// A child-facing profile owned by a parent account.
///
/// We intentionally keep this to the minimum information needed to personalise
/// the app. Children never need an email address or a password.
class KidProfile {
  const KidProfile({
    required this.id,
    required this.parentId,
    required this.displayName,
    required this.avatarKey,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String parentId;
  final String displayName;
  final String avatarKey;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory KidProfile.fromJson(Map<String, dynamic> json) {
    return KidProfile(
      id: (json['id'] ?? '').toString(),
      parentId: (json['parent_id'] ?? json['parent'] ?? '').toString(),
      displayName: (json['display_name'] ?? json['name'] ?? '').toString(),
      avatarKey: (json['avatar_key'] ?? json['avatar'] ?? 'lion').toString(),
      createdAt: DateTime.tryParse((json['created_at'] ?? '').toString()),
      updatedAt: DateTime.tryParse((json['updated_at'] ?? '').toString()),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'parent_id': parentId,
    'display_name': displayName,
    'avatar_key': avatarKey,
    if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
    if (updatedAt != null) 'updated_at': updatedAt!.toIso8601String(),
  };

  KidProfile copyWith({
    String? id,
    String? parentId,
    String? displayName,
    String? avatarKey,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return KidProfile(
      id: id ?? this.id,
      parentId: parentId ?? this.parentId,
      displayName: displayName ?? this.displayName,
      avatarKey: avatarKey ?? this.avatarKey,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

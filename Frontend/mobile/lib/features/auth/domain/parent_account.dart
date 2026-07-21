/// The adult account that owns one or more child profiles.
class ParentAccount {
  const ParentAccount({required this.id, required this.email, this.firstName});

  final String id;
  final String email;
  final String? firstName;

  factory ParentAccount.fromJson(Map<String, dynamic> json) {
    return ParentAccount(
      id: json['id'].toString(),
      email: (json['email'] ?? '').toString(),
      firstName: _nullableString(json['first_name'] ?? json['firstName']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'email': email,
    if (firstName != null) 'first_name': firstName,
  };

  ParentAccount copyWith({String? id, String? email, String? firstName}) {
    return ParentAccount(
      id: id ?? this.id,
      email: email ?? this.email,
      firstName: firstName ?? this.firstName,
    );
  }
}

String? _nullableString(Object? value) {
  final result = value?.toString().trim();
  return result == null || result.isEmpty ? null : result;
}

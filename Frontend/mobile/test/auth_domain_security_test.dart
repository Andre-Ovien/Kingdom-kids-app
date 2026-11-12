import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/auth/domain/auth_session.dart';
import 'package:mobile/features/auth/domain/parent_account.dart';

void main() {
  test('missing parent identity stays empty instead of becoming null text', () {
    final parent = ParentAccount.fromJson(const {
      'email': ' Parent@EXAMPLE.com ',
    });

    expect(parent.id, isEmpty);
    expect(parent.email, 'parent@example.com');
  });

  test('rejects child profiles bound to a different parent', () {
    expect(
      () => AuthSession.fromJson(const {
        'parent': {'id': 'parent-1', 'email': 'parent@example.com'},
        'access': 'access-token',
        'profiles': [
          {
            'id': 'kid-1',
            'parent_id': 'parent-2',
            'display_name': 'Other child',
            'avatar_key': 'star',
          },
        ],
      }),
      throwsFormatException,
    );
  });
}

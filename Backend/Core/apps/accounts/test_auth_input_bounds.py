from unittest.mock import patch

from django.core.cache import cache
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APITestCase
from rest_framework_simplejwt.exceptions import TokenError

from .models import User


class LoginInputBoundaryTests(APITestCase):
    def setUp(self):
        cache.clear()

    def test_login_preserves_password_spaces_accepted_by_registration(self):
        password = '  Exact-parent-password-2026!  '
        parent = User.objects.create_user(
            email='exact-password-parent@example.com',
            password=password,
            email_verified_at=timezone.now(),
        )
        response = self.client.post(
            reverse('accounts:login'),
            {'email': parent.email, 'password': password},
            format='json',
        )
        self.assertEqual(response.status_code, 200)
        self.assertIn('access', response.data)

    def test_oversized_login_credentials_are_rejected_before_authentication(self):
        for field, value in (
            ('email', f'{"a" * 255}@example.com'),
            ('password', 'p' * 129),
        ):
            with self.subTest(field=field):
                payload = {
                    'email': 'bounded-parent@example.com',
                    'password': 'Bounded-parent-password-2026!',
                    field: value,
                }
                with patch(
                    'rest_framework_simplejwt.serializers.authenticate',
                    return_value=None,
                ) as authenticate:
                    response = self.client.post(
                        reverse('accounts:login'),
                        payload,
                        format='json',
                    )
                self.assertEqual(response.status_code, 400)
                self.assertIn(field, response.data)
                authenticate.assert_not_called()

    def test_oversized_refresh_is_rejected_before_jwt_decoding(self):
        with patch(
            'apps.accounts.serializers.UntypedToken',
            side_effect=TokenError('Invalid token'),
        ) as decode:
            response = self.client.post(
                reverse('accounts:token-refresh'),
                {'refresh': 'x' * 4097},
                format='json',
            )
        self.assertEqual(response.status_code, 400)
        self.assertIn('refresh', response.data)
        decode.assert_not_called()

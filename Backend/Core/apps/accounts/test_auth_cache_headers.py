import re

from django.core import mail
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APITestCase
from rest_framework_simplejwt.tokens import RefreshToken

from .models import KidProfile, User


@override_settings(EMAIL_BACKEND='django.core.mail.backends.locmem.EmailBackend')
class SensitiveAccountCacheTests(APITestCase):
    password = 'Strong-private-response-password-2026!'

    def setUp(self):
        cache.clear()
        self.parent = User.objects.create_user(
            email='private-parent@example.com',
            password=self.password,
            email_verified_at=timezone.now(),
        )

    def assert_not_stored(self, response):
        self.assertEqual(response.get('Cache-Control'), 'no-store')

    def test_issued_login_and_rotated_session_tokens_are_not_cacheable(self):
        logged_in = self.client.post(
            reverse('accounts:login'),
            {'email': self.parent.email, 'password': self.password},
            format='json',
        )
        self.assertEqual(logged_in.status_code, 200)
        self.assertIn('access', logged_in.data)
        self.assert_not_stored(logged_in)

        refreshed = self.client.post(
            reverse('accounts:token-refresh'),
            {'refresh': logged_in.data['refresh']},
            format='json',
        )
        self.assertEqual(refreshed.status_code, 200)
        self.assertIn('refresh', refreshed.data)
        self.assert_not_stored(refreshed)

    def test_parent_and_child_personal_data_are_not_cacheable(self):
        child = KidProfile.objects.create(
            parent=self.parent,
            display_name='Private child',
            avatar_key='kai',
        )
        access = RefreshToken.for_user(self.parent).access_token
        self.client.credentials(HTTP_AUTHORIZATION=f'Bearer {access}')
        for route, kwargs in (
            ('accounts:me', {}),
            ('accounts:kid-profile-list', {}),
            ('accounts:kid-profile-detail', {'id': child.pk}),
            ('accounts:kid-profile-preferences', {'profile_id': child.pk}),
        ):
            with self.subTest(route=route):
                response = self.client.get(reverse(route, kwargs=kwargs))
                self.assertEqual(response.status_code, 200)
                self.assert_not_stored(response)

    def test_registration_challenges_and_verification_tokens_are_not_cacheable(self):
        with self.captureOnCommitCallbacks(execute=True):
            registered = self.client.post(
                reverse('accounts:register'),
                {
                    'email': 'private-new-parent@example.com',
                    'password': self.password,
                    'password_confirmation': self.password,
                },
                format='json',
            )
        self.assertEqual(registered.status_code, 202)
        self.assert_not_stored(registered)
        code = re.search(r'\b(\d{6})\b', mail.outbox[-1].body).group(1)
        verified = self.client.post(
            reverse('accounts:email-verification-confirm'),
            {
                'challenge_id': registered.data['verification']['challenge_id'],
                'code': code,
            },
            format='json',
        )
        self.assertEqual(verified.status_code, 200)
        self.assertIn('access', verified.data)
        self.assert_not_stored(verified)

    def test_recovery_handles_and_error_responses_are_not_cacheable(self):
        with self.captureOnCommitCallbacks(execute=True):
            requested = self.client.post(
                reverse('accounts:password-reset-request'),
                {'email': self.parent.email},
                format='json',
            )
        self.assertEqual(requested.status_code, 202)
        self.assert_not_stored(requested)

        for route in (
            'accounts:register',
            'accounts:login',
            'accounts:token-refresh',
            'accounts:email-verification-confirm',
            'accounts:email-verification-resend',
            'accounts:password-reset-request',
            'accounts:password-reset-verify',
            'accounts:password-reset-confirm',
            'accounts:account-deletion-request',
            'accounts:account-deletion-confirm',
            'accounts:logout',
        ):
            with self.subTest(route=route):
                response = self.client.post(reverse(route), {}, format='json')
                self.assertIn(response.status_code, (400, 401))
                self.assert_not_stored(response)

        self.assert_not_stored(self.client.get(reverse('accounts:me')))
        self.assert_not_stored(
            self.client.delete(
                reverse('accounts:unverified-account-delete'),
                {},
                format='json',
            )
        )

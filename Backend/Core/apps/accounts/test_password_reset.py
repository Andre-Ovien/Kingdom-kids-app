import re
import uuid
from datetime import timedelta
from unittest.mock import patch

from django.conf import settings
from django.core import mail
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APITestCase
from rest_framework_simplejwt.tokens import RefreshToken

from .models import PasswordResetChallenge, User


OLD_PASSWORD = 'Correct-Horse-Battery-Staple-2026!'
NEW_PASSWORD = 'New-Correct-Horse-Battery-Staple-2026!'


class PasswordResetApiTests(APITestCase):
    def setUp(self):
        super().setUp()
        cache.clear()
        self.user = User.objects.create_user(
            email='parent@example.com',
            password=OLD_PASSWORD,
            email_verified_at=timezone.now(),
        )
        self.request_url = reverse('accounts:password-reset-request')
        self.confirm_url = reverse('accounts:password-reset-confirm')

    def request_reset(self, email='parent@example.com'):
        with self.captureOnCommitCallbacks(execute=True):
            return self.client.post(
                self.request_url,
                {'email': email},
                format='json',
            )

    def code_from_latest_email(self):
        match = re.search(r'\b(\d{6})\b', mail.outbox[-1].body)
        self.assertIsNotNone(match)
        return match.group(1)

    def confirm(self, challenge_id, code, **overrides):
        payload = {
            'challenge_id': str(challenge_id),
            'code': code,
            'new_password': NEW_PASSWORD,
            'new_password_confirmation': NEW_PASSWORD,
        }
        payload.update(overrides)
        return self.client.post(self.confirm_url, payload, format='json')

    @staticmethod
    def public_response_without_handle(response):
        data = dict(response.data)
        data.pop('challenge_id')
        return data

    def test_success_uses_hashed_single_use_code_and_changes_password(self):
        requested = self.request_reset('PARENT@EXAMPLE.COM')

        self.assertEqual(requested.status_code, status.HTTP_202_ACCEPTED)
        self.assertEqual(
            set(requested.data),
            {'detail', 'challenge_id', 'expires_in'},
        )
        self.assertEqual(
            requested.data['expires_in'],
            int(settings.PASSWORD_RESET_TTL.total_seconds()),
        )
        challenge = PasswordResetChallenge.objects.get(
            pk=requested.data['challenge_id']
        )
        code = self.code_from_latest_email()
        self.assertEqual(mail.outbox[-1].to, ['parent@example.com'])
        self.assertNotEqual(challenge.code_digest, code)
        self.assertRegex(challenge.code_digest, r'^[0-9a-f]{64}$')
        self.assertGreater(challenge.expires_at, timezone.now())
        self.assertEqual(challenge.max_attempts, settings.PASSWORD_RESET_MAX_ATTEMPTS)

        confirmed = self.confirm(challenge.pk, code)

        self.assertEqual(confirmed.status_code, status.HTTP_204_NO_CONTENT)
        self.user.refresh_from_db()
        challenge.refresh_from_db()
        self.assertTrue(self.user.check_password(NEW_PASSWORD))
        self.assertFalse(self.user.check_password(OLD_PASSWORD))
        self.assertIsNotNone(challenge.consumed_at)

        reused = self.confirm(challenge.pk, code)
        self.assertEqual(reused.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(
            reused.data['code'],
            'invalid_or_expired_password_reset',
        )

    def test_unknown_and_disabled_accounts_are_indistinguishable(self):
        eligible = self.request_reset()
        eligible_public = self.public_response_without_handle(eligible)
        eligible_id = uuid.UUID(eligible.data['challenge_id'])
        self.assertTrue(PasswordResetChallenge.objects.filter(pk=eligible_id).exists())
        self.assertEqual(len(mail.outbox), 1)

        disabled = User.objects.create_user(
            email='disabled@example.com',
            password=OLD_PASSWORD,
            email_verified_at=timezone.now(),
            is_active=False,
        )
        for email in (
            'unknown@example.com',
            disabled.email,
        ):
            response = self.request_reset(email)
            self.assertEqual(response.status_code, status.HTTP_202_ACCEPTED)
            self.assertEqual(
                self.public_response_without_handle(response),
                eligible_public,
            )
            decoy_id = uuid.UUID(response.data['challenge_id'])
            self.assertFalse(
                PasswordResetChallenge.objects.filter(pk=decoy_id).exists()
            )

        self.assertEqual(PasswordResetChallenge.objects.count(), 1)
        self.assertFalse(
            PasswordResetChallenge.objects.filter(user=disabled).exists()
        )
        self.assertEqual(len(mail.outbox), 1)

    def test_mailbox_owner_can_reclaim_and_verify_a_pending_account(self):
        pending = User.objects.create_user(
            email='pending@example.com',
            password=OLD_PASSWORD,
        )

        requested = self.request_reset(pending.email)
        challenge = PasswordResetChallenge.objects.get(
            pk=requested.data['challenge_id']
        )
        code = self.code_from_latest_email()

        confirmed = self.confirm(challenge.pk, code)

        self.assertEqual(confirmed.status_code, status.HTTP_204_NO_CONTENT)
        pending.refresh_from_db()
        self.assertTrue(pending.check_password(NEW_PASSWORD))
        self.assertFalse(pending.check_password(OLD_PASSWORD))
        self.assertIsNotNone(pending.email_verified_at)

        login = self.client.post(
            reverse('accounts:login'),
            {'email': pending.email, 'password': NEW_PASSWORD},
            format='json',
        )
        self.assertEqual(login.status_code, status.HTTP_200_OK)
        self.assertIn('access', login.data)

    def test_wrong_codes_are_bounded_and_lock_the_challenge(self):
        requested = self.request_reset()
        challenge = PasswordResetChallenge.objects.get(
            pk=requested.data['challenge_id']
        )
        correct_code = self.code_from_latest_email()
        wrong_code = '000000' if correct_code != '000000' else '000001'

        for _ in range(settings.PASSWORD_RESET_MAX_ATTEMPTS):
            rejected = self.confirm(challenge.pk, wrong_code)
            self.assertEqual(rejected.status_code, status.HTTP_400_BAD_REQUEST)
            self.assertEqual(
                rejected.data['code'],
                'invalid_or_expired_password_reset',
            )

        challenge.refresh_from_db()
        self.assertEqual(
            challenge.attempt_count,
            settings.PASSWORD_RESET_MAX_ATTEMPTS,
        )
        self.assertIsNotNone(challenge.invalidated_at)
        correct_after_lock = self.confirm(challenge.pk, correct_code)
        self.assertEqual(
            correct_after_lock.status_code,
            status.HTTP_400_BAD_REQUEST,
        )
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password(OLD_PASSWORD))

    def test_expired_and_decoy_challenges_return_the_same_error(self):
        requested = self.request_reset()
        challenge = PasswordResetChallenge.objects.get(
            pk=requested.data['challenge_id']
        )
        code = self.code_from_latest_email()
        challenge.expires_at = timezone.now() - timedelta(seconds=1)
        challenge.save(update_fields=('expires_at',))

        expired = self.confirm(challenge.pk, code)
        decoy = self.confirm(uuid.uuid4(), code)

        self.assertEqual(expired.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(decoy.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(expired.data, decoy.data)
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password(OLD_PASSWORD))

    def test_password_matching_and_django_validation_do_not_consume_code(self):
        requested = self.request_reset()
        challenge = PasswordResetChallenge.objects.get(
            pk=requested.data['challenge_id']
        )
        code = self.code_from_latest_email()

        mismatch = self.confirm(
            challenge.pk,
            code,
            new_password_confirmation='Different-Password-2026!',
        )
        self.assertEqual(mismatch.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn('new_password_confirmation', mismatch.data)

        weak = self.confirm(
            challenge.pk,
            code,
            new_password='short',
            new_password_confirmation='short',
        )
        self.assertEqual(weak.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn('new_password', weak.data)

        similar_to_user = self.confirm(
            challenge.pk,
            code,
            new_password='parent@example.com',
            new_password_confirmation='parent@example.com',
        )
        self.assertEqual(similar_to_user.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn('new_password', similar_to_user.data)

        challenge.refresh_from_db()
        self.assertIsNone(challenge.consumed_at)
        self.assertEqual(challenge.attempt_count, 0)
        accepted = self.confirm(challenge.pk, code)
        self.assertEqual(accepted.status_code, status.HTTP_204_NO_CONTENT)

    def test_password_change_revokes_existing_access_and_refresh_tokens(self):
        old_refresh = RefreshToken.for_user(self.user)
        old_access = str(old_refresh.access_token)
        requested = self.request_reset()
        code = self.code_from_latest_email()

        confirmed = self.confirm(requested.data['challenge_id'], code)
        self.assertEqual(confirmed.status_code, status.HTTP_204_NO_CONTENT)

        self.client.credentials(HTTP_AUTHORIZATION=f'Bearer {old_access}')
        access_attempt = self.client.get(reverse('accounts:me'))
        self.assertEqual(access_attempt.status_code, status.HTTP_401_UNAUTHORIZED)

        self.client.credentials()
        refresh_attempt = self.client.post(
            reverse('accounts:token-refresh'),
            {'refresh': str(old_refresh)},
            format='json',
        )
        self.assertEqual(refresh_attempt.status_code, status.HTTP_401_UNAUTHORIZED)

        old_login = self.client.post(
            reverse('accounts:login'),
            {'email': self.user.email, 'password': OLD_PASSWORD},
            format='json',
        )
        new_login = self.client.post(
            reverse('accounts:login'),
            {'email': self.user.email, 'password': NEW_PASSWORD},
            format='json',
        )
        self.assertEqual(old_login.status_code, status.HTTP_401_UNAUTHORIZED)
        self.assertEqual(new_login.status_code, status.HTTP_200_OK)

    def test_hashed_email_throttle_is_case_insensitive(self):
        for email in (
            'parent@example.com',
            'PARENT@EXAMPLE.COM',
            '  Parent@Example.Com  ',
        ):
            self.assertEqual(
                self.request_reset(email).status_code,
                status.HTTP_202_ACCEPTED,
            )

        throttled = self.request_reset('parent@example.com')
        self.assertEqual(throttled.status_code, status.HTTP_429_TOO_MANY_REQUESTS)

    def test_request_scope_is_also_rate_limited_by_client_ip(self):
        for index in range(5):
            accepted = self.request_reset(f'unknown-{index}@example.com')
            self.assertEqual(accepted.status_code, status.HTTP_202_ACCEPTED)

        throttled = self.request_reset('another-unknown@example.com')
        self.assertEqual(throttled.status_code, status.HTTP_429_TOO_MANY_REQUESTS)
        self.assertEqual(PasswordResetChallenge.objects.count(), 0)

    @override_settings(
        EMAIL_BACKEND='django.core.mail.backends.console.EmailBackend',
    )
    def test_console_backend_never_prints_password_reset_credentials(self):
        with patch('apps.accounts.password_reset.send_mail') as send:
            response = self.request_reset()

        self.assertEqual(response.status_code, status.HTTP_202_ACCEPTED)
        send.assert_not_called()
        challenge = PasswordResetChallenge.objects.get(
            pk=response.data['challenge_id']
        )
        self.assertIsNotNone(challenge.invalidated_at)

    def test_delivery_failure_keeps_generic_response_and_invalidates_challenge(self):
        with patch(
            'apps.accounts.password_reset.send_mail',
            side_effect=RuntimeError('provider included sensitive context'),
        ):
            response = self.request_reset()

        self.assertEqual(response.status_code, status.HTTP_202_ACCEPTED)
        self.assertNotIn('email', response.data)
        self.assertNotIn('code', response.data)
        challenge = PasswordResetChallenge.objects.get(
            pk=response.data['challenge_id']
        )
        self.assertIsNotNone(challenge.invalidated_at)

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
from rest_framework_simplejwt.token_blacklist.models import OutstandingToken
from rest_framework_simplejwt.tokens import RefreshToken

from .models import (
    AccountDeletionChallenge,
    KidProfile,
    User,
    WaitlistSubscriber,
)


PASSWORD = 'Correct-Horse-Battery-Staple-2026!'


class AccountDeletionApiTests(APITestCase):
    def setUp(self):
        super().setUp()
        cache.clear()
        self.user = User.objects.create_user(
            email='parent@example.com',
            password=PASSWORD,
            email_verified_at=timezone.now(),
        )
        self.request_url = reverse('accounts:account-deletion-request')
        self.confirm_url = reverse('accounts:account-deletion-confirm')

    def request_deletion(self, email='parent@example.com'):
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
            'confirmation': 'DELETE',
        }
        payload.update(overrides)
        return self.client.post(self.confirm_url, payload, format='json')

    @staticmethod
    def public_response_without_handle(response):
        data = dict(response.data)
        data.pop('challenge_id')
        return data

    def test_verified_account_deletion_erases_owned_data_and_tokens(self):
        profile = KidProfile.objects.create(
            parent=self.user,
            display_name='Ada',
            avatar_key=KidProfile.AvatarKey.DOVE,
        )
        WaitlistSubscriber.objects.create(email=self.user.email)
        old_refresh = RefreshToken.for_user(self.user)
        user_id = self.user.pk

        requested = self.request_deletion('PARENT@EXAMPLE.COM')

        self.assertEqual(requested.status_code, status.HTTP_202_ACCEPTED)
        self.assertEqual(requested['Cache-Control'], 'no-store')
        self.assertEqual(
            set(requested.data),
            {'detail', 'challenge_id', 'expires_in'},
        )
        challenge = AccountDeletionChallenge.objects.get(
            pk=requested.data['challenge_id']
        )
        code = self.code_from_latest_email()
        self.assertEqual(mail.outbox[-1].to, ['parent@example.com'])
        self.assertNotEqual(challenge.code_digest, code)
        self.assertRegex(challenge.code_digest, r'^[0-9a-f]{64}$')
        self.assertEqual(
            challenge.max_attempts,
            settings.ACCOUNT_DELETION_MAX_ATTEMPTS,
        )

        confirmed = self.confirm(challenge.pk, code)

        self.assertEqual(confirmed.status_code, status.HTTP_204_NO_CONTENT)
        self.assertEqual(confirmed['Cache-Control'], 'no-store')
        self.assertFalse(User.objects.filter(pk=user_id).exists())
        self.assertFalse(KidProfile.objects.filter(pk=profile.pk).exists())
        self.assertFalse(
            WaitlistSubscriber.objects.filter(email__iexact='parent@example.com').exists()
        )
        self.assertFalse(OutstandingToken.objects.filter(user_id=user_id).exists())
        self.assertFalse(
            AccountDeletionChallenge.objects.filter(pk=challenge.pk).exists()
        )
        replay = self.confirm(challenge.pk, code)
        self.assertEqual(replay.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(
            replay.data['code'],
            'invalid_or_expired_account_deletion',
        )
        refresh_attempt = self.client.post(
            reverse('accounts:token-refresh'),
            {'refresh': str(old_refresh)},
            format='json',
        )
        self.assertEqual(refresh_attempt.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_pending_account_can_prove_email_and_delete_matching_waitlist(self):
        pending = User.objects.create_user(
            email='pending@example.com',
            password=PASSWORD,
        )
        WaitlistSubscriber.objects.create(email='PENDING@example.com')

        requested = self.request_deletion(pending.email)
        code = self.code_from_latest_email()
        confirmed = self.confirm(requested.data['challenge_id'], code)

        self.assertEqual(confirmed.status_code, status.HTTP_204_NO_CONTENT)
        self.assertFalse(User.objects.filter(pk=pending.pk).exists())
        self.assertFalse(
            WaitlistSubscriber.objects.filter(email__iexact=pending.email).exists()
        )

    def test_unknown_disabled_staff_and_superuser_requests_are_indistinguishable(self):
        eligible = self.request_deletion()
        eligible_public = self.public_response_without_handle(eligible)
        self.assertTrue(
            AccountDeletionChallenge.objects.filter(
                pk=eligible.data['challenge_id']
            ).exists()
        )
        self.assertEqual(len(mail.outbox), 1)

        disabled = User.objects.create_user(
            email='disabled@example.com',
            password=PASSWORD,
            is_active=False,
        )
        staff = User.objects.create_user(
            email='staff@example.com',
            password=PASSWORD,
            is_staff=True,
        )
        superuser = User.objects.create_superuser(
            email='superuser@example.com',
            password=PASSWORD,
        )
        for email in (
            'missing@example.com',
            disabled.email,
            staff.email,
            superuser.email,
        ):
            response = self.request_deletion(email)
            self.assertEqual(response.status_code, status.HTTP_202_ACCEPTED)
            self.assertEqual(response['Cache-Control'], 'no-store')
            self.assertEqual(
                self.public_response_without_handle(response),
                eligible_public,
            )
            decoy_id = uuid.UUID(response.data['challenge_id'])
            self.assertFalse(
                AccountDeletionChallenge.objects.filter(pk=decoy_id).exists()
            )

        self.assertEqual(AccountDeletionChallenge.objects.count(), 1)
        self.assertEqual(len(mail.outbox), 1)

    def test_wrong_codes_are_bounded_and_cannot_delete_after_lock(self):
        requested = self.request_deletion()
        challenge = AccountDeletionChallenge.objects.get(
            pk=requested.data['challenge_id']
        )
        correct_code = self.code_from_latest_email()
        wrong_code = '000000' if correct_code != '000000' else '000001'

        for _ in range(settings.ACCOUNT_DELETION_MAX_ATTEMPTS):
            rejected = self.confirm(challenge.pk, wrong_code)
            self.assertEqual(rejected.status_code, status.HTTP_400_BAD_REQUEST)
            self.assertEqual(rejected['Cache-Control'], 'no-store')
            self.assertEqual(
                rejected.data['code'],
                'invalid_or_expired_account_deletion',
            )

        challenge.refresh_from_db()
        self.assertEqual(
            challenge.attempt_count,
            settings.ACCOUNT_DELETION_MAX_ATTEMPTS,
        )
        self.assertIsNotNone(challenge.invalidated_at)
        self.assertEqual(
            self.confirm(challenge.pk, correct_code).status_code,
            status.HTTP_400_BAD_REQUEST,
        )
        self.assertTrue(User.objects.filter(pk=self.user.pk).exists())

    def test_expired_decoy_and_changed_email_challenges_share_generic_error(self):
        requested = self.request_deletion()
        challenge = AccountDeletionChallenge.objects.get(
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

        replacement = self.request_deletion()
        replacement_code = self.code_from_latest_email()
        self.user.email = 'changed@example.com'
        self.user.save(update_fields=('email',))
        changed = self.confirm(replacement.data['challenge_id'], replacement_code)
        self.assertEqual(changed.data, decoy.data)
        self.assertTrue(User.objects.filter(pk=self.user.pk).exists())

    def test_confirmation_requires_exact_delete_and_rejects_unknown_fields(self):
        request_with_unknown = self.client.post(
            self.request_url,
            {'email': self.user.email, 'password': PASSWORD},
            format='json',
        )
        self.assertEqual(
            request_with_unknown.status_code,
            status.HTTP_400_BAD_REQUEST,
        )
        self.assertEqual(
            request_with_unknown.data['password'],
            ['Unknown field.'],
        )

        requested = self.request_deletion()
        code = self.code_from_latest_email()

        wrong_confirmation = self.confirm(
            requested.data['challenge_id'],
            code,
            confirmation='delete',
        )
        self.assertEqual(wrong_confirmation.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn('confirmation', wrong_confirmation.data)

        unknown = self.confirm(
            requested.data['challenge_id'],
            code,
            password=PASSWORD,
        )
        self.assertEqual(unknown.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(unknown.data['password'], ['Unknown field.'])
        self.assertTrue(User.objects.filter(pk=self.user.pk).exists())

    def test_new_request_invalidates_the_previous_code(self):
        first = self.request_deletion()
        first_code = self.code_from_latest_email()
        second = self.request_deletion()
        second_code = self.code_from_latest_email()

        old_challenge = AccountDeletionChallenge.objects.get(
            pk=first.data['challenge_id']
        )
        self.assertIsNotNone(old_challenge.invalidated_at)
        self.assertEqual(
            self.confirm(first.data['challenge_id'], first_code).status_code,
            status.HTTP_400_BAD_REQUEST,
        )
        self.assertEqual(
            self.confirm(second.data['challenge_id'], second_code).status_code,
            status.HTTP_204_NO_CONTENT,
        )

    def test_password_reset_code_cannot_authorize_account_deletion(self):
        with patch(
            'apps.accounts.password_reset.secrets.randbelow',
            return_value=111111,
        ):
            with self.captureOnCommitCallbacks(execute=True):
                reset = self.client.post(
                    reverse('accounts:password-reset-request'),
                    {'email': self.user.email},
                    format='json',
                )
        self.assertEqual(reset.status_code, status.HTTP_202_ACCEPTED)
        reset_code = self.code_from_latest_email()

        with patch(
            'apps.accounts.account_deletion.secrets.randbelow',
            return_value=222222,
        ):
            deletion = self.request_deletion()
        deletion_code = self.code_from_latest_email()
        rejected = self.confirm(deletion.data['challenge_id'], reset_code)

        self.assertEqual(rejected.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertTrue(User.objects.filter(pk=self.user.pk).exists())
        accepted = self.confirm(deletion.data['challenge_id'], deletion_code)
        self.assertEqual(accepted.status_code, status.HTTP_204_NO_CONTENT)

    def test_deletion_rolls_back_if_erasure_cannot_complete(self):
        requested = self.request_deletion()
        code = self.code_from_latest_email()
        challenge_id = requested.data['challenge_id']

        with patch(
            'apps.accounts.account_deletion.WaitlistSubscriber.objects.filter',
        ) as filtered:
            filtered.return_value.delete.side_effect = RuntimeError(
                'simulated erasure failure'
            )
            with self.assertRaises(RuntimeError):
                self.confirm(challenge_id, code)

        self.assertTrue(User.objects.filter(pk=self.user.pk).exists())
        challenge = AccountDeletionChallenge.objects.get(pk=challenge_id)
        self.assertIsNone(challenge.consumed_at)
        self.assertIsNone(challenge.invalidated_at)
        self.assertEqual(challenge.attempt_count, 0)

    def test_endpoints_accept_only_json(self):
        request_response = self.client.post(
            self.request_url,
            {'email': self.user.email},
        )
        confirm_response = self.client.post(
            self.confirm_url,
            {
                'challenge_id': str(uuid.uuid4()),
                'code': '123456',
                'confirmation': 'DELETE',
            },
        )

        self.assertEqual(
            request_response.status_code,
            status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
        )
        self.assertEqual(request_response['Cache-Control'], 'no-store')
        self.assertEqual(
            confirm_response.status_code,
            status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
        )
        self.assertEqual(confirm_response['Cache-Control'], 'no-store')

    @override_settings(
        EMAIL_BACKEND='django.core.mail.backends.console.EmailBackend',
    )
    def test_console_backend_never_prints_account_deletion_credentials(self):
        with patch('apps.accounts.account_deletion.send_mail') as send:
            response = self.request_deletion()

        self.assertEqual(response.status_code, status.HTTP_202_ACCEPTED)
        send.assert_not_called()
        challenge = AccountDeletionChallenge.objects.get(
            pk=response.data['challenge_id']
        )
        self.assertIsNotNone(challenge.invalidated_at)

    def test_delivery_failure_is_generic_and_invalidates_challenge(self):
        with patch(
            'apps.accounts.account_deletion.send_mail',
            side_effect=RuntimeError('provider included sensitive context'),
        ):
            response = self.request_deletion()

        self.assertEqual(response.status_code, status.HTTP_202_ACCEPTED)
        self.assertNotIn('email', response.data)
        self.assertNotIn('code', response.data)
        challenge = AccountDeletionChallenge.objects.get(
            pk=response.data['challenge_id']
        )
        self.assertIsNotNone(challenge.invalidated_at)

    def test_hashed_email_throttle_is_case_insensitive(self):
        for email in (
            'parent@example.com',
            'PARENT@EXAMPLE.COM',
            '  Parent@Example.Com  ',
        ):
            self.assertEqual(
                self.request_deletion(email).status_code,
                status.HTTP_202_ACCEPTED,
            )

        throttled = self.request_deletion('parent@example.com')
        self.assertEqual(throttled.status_code, status.HTTP_429_TOO_MANY_REQUESTS)

    def test_request_scope_is_also_rate_limited_by_client_ip(self):
        for index in range(5):
            accepted = self.request_deletion(f'missing-{index}@example.com')
            self.assertEqual(accepted.status_code, status.HTTP_202_ACCEPTED)

        throttled = self.request_deletion('another-missing@example.com')
        self.assertEqual(throttled.status_code, status.HTTP_429_TOO_MANY_REQUESTS)

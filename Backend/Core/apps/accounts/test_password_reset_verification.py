"""The code page verifies email control before the password-entry page opens."""

import re
import uuid
from datetime import timedelta

from django.conf import settings
from django.core import mail
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APITestCase
from rest_framework_simplejwt.token_blacklist.models import OutstandingToken

from .models import PasswordResetChallenge, User


OLD_PASSWORD = 'Correct-Horse-Battery-Staple-2026!'
NEW_PASSWORD = 'New-Correct-Horse-Battery-Staple-2026!'


@override_settings(EMAIL_BACKEND='django.core.mail.backends.locmem.EmailBackend')
class PasswordResetVerificationTests(APITestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(
            email='three-step-parent@example.com',
            password=OLD_PASSWORD,
            email_verified_at=timezone.now(),
        )
        self.request_url = reverse('accounts:password-reset-request')
        self.verify_url = reverse('accounts:password-reset-verify')
        self.confirm_url = reverse('accounts:password-reset-confirm')

    def request_code(self):
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(
                self.request_url, {'email': self.user.email}, format='json',
            )
        self.assertEqual(response.status_code, 202)
        code = re.search(r'\b(\d{6})\b', mail.outbox[-1].body).group(1)
        return PasswordResetChallenge.objects.get(
            pk=response.data['challenge_id'],
        ), code

    def verify(self, challenge_id, code, **extra):
        return self.client.post(
            self.verify_url,
            {'challenge_id': str(challenge_id), 'code': code, **extra},
            format='json',
        )

    def confirm(self, challenge_id, code):
        return self.client.post(
            self.confirm_url,
            {
                'challenge_id': str(challenge_id),
                'code': code,
                'new_password': NEW_PASSWORD,
                'new_password_confirmation': NEW_PASSWORD,
            },
            format='json',
        )

    def assert_invalid(self, response):
        self.assertEqual(response.status_code, 400)
        self.assertEqual(
            response.data,
            {
                'code': 'invalid_or_expired_password_reset',
                'detail': 'That password reset code is incorrect or has expired.',
            },
        )

    def test_verification_does_not_change_account_consume_proof_or_issue_session(self):
        challenge, code = self.request_code()
        account_before = User.objects.values().get(pk=self.user.pk)
        challenge_before = PasswordResetChallenge.objects.values().get(pk=challenge.pk)
        token_count = OutstandingToken.objects.count()

        verified = self.verify(challenge.pk, code)

        self.assertEqual(verified.status_code, 204)
        self.assertIsNone(verified.data)
        self.assertIn('no-store', verified['Cache-Control'])
        self.assertEqual(User.objects.values().get(pk=self.user.pk), account_before)
        self.assertEqual(
            PasswordResetChallenge.objects.values().get(pk=challenge.pk),
            challenge_before,
        )
        self.assertEqual(OutstandingToken.objects.count(), token_count)
        self.assertEqual(self.verify(challenge.pk, code).status_code, 204)

        # Verification alone cannot authorize a missing/incorrect final proof.
        missing_code = self.client.post(
            self.confirm_url,
            {
                'challenge_id': str(challenge.pk),
                'new_password': NEW_PASSWORD,
                'new_password_confirmation': NEW_PASSWORD,
            },
            format='json',
        )
        self.assertEqual(missing_code.status_code, 400)
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password(OLD_PASSWORD))
        self.assertEqual(self.confirm(challenge.pk, code).status_code, 204)
        self.assert_invalid(self.verify(challenge.pk, code))
        self.assert_invalid(self.confirm(challenge.pk, code))

    def test_wrong_codes_share_the_confirmation_attempt_limit(self):
        challenge, code = self.request_code()
        wrong = '000000' if code != '000000' else '000001'
        for index in range(settings.PASSWORD_RESET_MAX_ATTEMPTS):
            operation = self.verify if index % 2 == 0 else self.confirm
            self.assert_invalid(operation(challenge.pk, wrong))
            challenge.refresh_from_db()
            self.assertEqual(challenge.attempt_count, index + 1)
        self.assertIsNotNone(challenge.invalidated_at)
        self.assert_invalid(self.verify(challenge.pk, code))
        self.assert_invalid(self.confirm(challenge.pk, code))
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password(OLD_PASSWORD))

    def test_unknown_expired_invalidated_and_inactive_proofs_are_generic(self):
        self.assert_invalid(self.verify(uuid.uuid4(), '123456'))
        for state in ('expired', 'invalidated', 'inactive'):
            with self.subTest(state=state):
                challenge, code = self.request_code()
                if state == 'expired':
                    PasswordResetChallenge.objects.filter(pk=challenge.pk).update(
                        expires_at=timezone.now() - timedelta(seconds=1),
                    )
                elif state == 'invalidated':
                    PasswordResetChallenge.objects.filter(pk=challenge.pk).update(
                        invalidated_at=timezone.now(),
                    )
                else:
                    User.objects.filter(pk=self.user.pk).update(is_active=False)
                self.assert_invalid(self.verify(challenge.pk, code))
                challenge.refresh_from_db()
                self.assertEqual(challenge.attempt_count, 0)

    def test_resend_invalidates_even_a_previously_verified_code(self):
        old, old_code = self.request_code()
        self.assertEqual(self.verify(old.pk, old_code).status_code, 204)
        current, current_code = self.request_code()
        self.assertNotEqual(old.pk, current.pk)
        self.assert_invalid(self.verify(old.pk, old_code))
        self.assert_invalid(self.confirm(old.pk, old_code))
        self.assertEqual(self.verify(current.pk, current_code).status_code, 204)
        self.assertEqual(self.confirm(current.pk, current_code).status_code, 204)

    def test_account_change_after_verification_still_blocks_final_confirmation(self):
        challenge, code = self.request_code()
        self.assertEqual(self.verify(challenge.pk, code).status_code, 204)
        User.objects.filter(pk=self.user.pk).update(is_active=False)
        self.assert_invalid(self.confirm(challenge.pk, code))
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password(OLD_PASSWORD))

    def test_verifying_a_pending_account_does_not_verify_or_sign_it_in(self):
        User.objects.filter(pk=self.user.pk).update(email_verified_at=None)
        challenge, code = self.request_code()
        self.assertEqual(self.verify(challenge.pk, code).status_code, 204)
        self.user.refresh_from_db()
        self.assertIsNone(self.user.email_verified_at)
        self.assertEqual(OutstandingToken.objects.count(), 0)
        self.assertTrue(self.user.check_password(OLD_PASSWORD))

    def test_code_page_rejects_password_fields_and_malformed_codes(self):
        challenge, code = self.request_code()
        rejected = self.verify(challenge.pk, code, new_password=NEW_PASSWORD)
        self.assertEqual(rejected.status_code, 400)
        self.assertIn('new_password', rejected.data)
        for malformed in ('12345', '1234567', '１２３４５６', '12x456'):
            with self.subTest(code=malformed):
                response = self.verify(challenge.pk, malformed)
                self.assertEqual(response.status_code, 400)
                self.assertIn('code', response.data)
        challenge.refresh_from_db()
        self.assertEqual(challenge.attempt_count, 0)
        self.assertIsNone(challenge.consumed_at)

    def test_both_endpoints_share_the_ip_throttle_scope(self):
        from .views import PasswordResetConfirmView, PasswordResetVerifyView

        # Exercise the throttle itself, not only the declared scope name.
        self.assertEqual(
            PasswordResetConfirmView.throttle_scope,
            PasswordResetVerifyView.throttle_scope,
        )
        challenge, code = self.request_code()
        rate = settings.REST_FRAMEWORK['DEFAULT_THROTTLE_RATES'][
            'password_reset_confirm'
        ]
        limit = int(rate.split('/')[0])
        for _ in range(limit):
            self.assertEqual(self.verify(challenge.pk, code).status_code, 204)
        limited = self.confirm(challenge.pk, code)
        self.assertEqual(limited.status_code, 429)
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password(OLD_PASSWORD))

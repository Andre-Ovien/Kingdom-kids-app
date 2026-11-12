import re
import uuid
from datetime import timedelta
from unittest.mock import patch

from django.core import mail
from django.core.cache import cache
from django.contrib.auth import get_user_model
from django.db import IntegrityError, connection, transaction
from django.db.migrations.executor import MigrationExecutor
from django.test import TransactionTestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APITestCase, APITransactionTestCase
from rest_framework_simplejwt.token_blacklist.models import OutstandingToken
from rest_framework_simplejwt.tokens import RefreshToken

from .models import (
    EmailVerificationChallenge,
    KidProfile,
    KidProfilePreferences,
    WaitlistSubscriber,
)
from .serializers import RegistrationSerializer


User = get_user_model()
PASSWORD = 'Correct-Horse-Battery-Staple-2026!'
NEW_PASSWORD = 'New-Correct-Horse-Battery-Staple-2026!'


class AccountsApiTests(APITestCase):
    def setUp(self):
        super().setUp()
        cache.clear()

    def register(self, **overrides):
        payload = {
            'email': 'parent@example.com',
            'password': PASSWORD,
            'password_confirmation': PASSWORD,
        }
        payload.update(overrides)
        with self.captureOnCommitCallbacks(execute=True):
            return self.client.post(
                reverse('accounts:register'),
                payload,
                format='json',
            )

    def verification_code(self, message_index=-1):
        match = re.search(r'\b(\d{6})\b', mail.outbox[message_index].body)
        self.assertIsNotNone(match)
        return match.group(1)

    def confirm(self, challenge_id, code):
        return self.client.post(
            reverse('accounts:email-verification-confirm'),
            {'challenge_id': challenge_id, 'code': code},
            format='json',
        )

    def authenticate(self, user):
        refresh = RefreshToken.for_user(user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Bearer {refresh.access_token}')
        return str(refresh)

    def create_parent(self, email='parent@example.com', *, verified=True):
        user = User.objects.create_user(email=email, password=PASSWORD)
        if verified:
            user.email_verified_at = timezone.now()
            user.save(update_fields=('email_verified_at',))
        return user

    def test_registration_creates_pending_parent_and_sends_hashed_code(self):
        response = self.register(email='Parent@Example.COM')

        self.assertEqual(response.status_code, status.HTTP_202_ACCEPTED)
        self.assertNotIn('access', response.data)
        self.assertNotIn('refresh', response.data)
        verification = response.data['verification']
        self.assertEqual(verification['destination_hint'], 'p***@example.com')
        self.assertGreater(verification['expires_in'], 0)
        self.assertGreater(verification['resend_after'], 0)

        user = User.objects.get(email='parent@example.com')
        self.assertTrue(user.check_password(PASSWORD))
        self.assertNotEqual(user.password, PASSWORD)
        self.assertIsNone(user.email_verified_at)

        challenge = EmailVerificationChallenge.objects.get(
            pk=verification['challenge_id']
        )
        code = self.verification_code()
        self.assertEqual(len(mail.outbox), 1)
        self.assertEqual(mail.outbox[0].to, ['parent@example.com'])
        self.assertNotEqual(challenge.code_digest, code)
        self.assertRegex(challenge.code_digest, r'^[0-9a-f]{64}$')

    @override_settings(
        DEBUG=True,
        EMAIL_BACKEND='django.core.mail.backends.console.EmailBackend',
    )
    def test_development_registration_prints_the_code_to_the_terminal(self):
        with patch('builtins.print') as terminal_print:
            response = self.register(email='terminal@example.com')

        self.assertEqual(response.status_code, status.HTTP_202_ACCEPTED)
        terminal_output = '\n'.join(
            str(call.args[0]) for call in terminal_print.call_args_list
        )
        self.assertIn('KINGDOM KIDS DEVELOPMENT CODE', terminal_output)
        self.assertIn('terminal@example.com', terminal_output)
        code_match = re.search(r'Code:\s+(\d{6})', terminal_output)
        self.assertIsNotNone(code_match)
        challenge = EmailVerificationChallenge.objects.get(
            pk=response.data['verification']['challenge_id']
        )
        self.assertNotEqual(challenge.code_digest, code_match.group(1))

    def test_registration_rejects_weak_and_mismatched_passwords(self):
        weak = self.register(password='short', password_confirmation='short')
        self.assertEqual(weak.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn('password', weak.data)

        mismatch = self.register(password_confirmation='different-password')
        self.assertEqual(mismatch.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn('password_confirmation', mismatch.data)

    def test_duplicate_registration_cannot_plant_a_pending_account_password(self):
        first = self.register()
        first_challenge_id = first.data['verification']['challenge_id']
        first_code = self.verification_code()
        original_user = User.objects.get(email='parent@example.com')

        duplicate = self.register(
            email='PARENT@EXAMPLE.COM',
            password=NEW_PASSWORD,
            password_confirmation=NEW_PASSWORD,
        )

        self.assertEqual(duplicate.status_code, status.HTTP_202_ACCEPTED)
        decoy_id = duplicate.data['verification']['challenge_id']
        self.assertNotEqual(decoy_id, first_challenge_id)
        self.assertFalse(
            EmailVerificationChallenge.objects.filter(pk=decoy_id).exists()
        )
        rejected_decoy = self.confirm(decoy_id, '000000')
        self.assertEqual(rejected_decoy.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(User.objects.count(), 1)
        protected_user = User.objects.get(email='parent@example.com')
        self.assertEqual(protected_user.pk, original_user.pk)
        self.assertTrue(protected_user.check_password(PASSWORD))
        self.assertFalse(protected_user.check_password(NEW_PASSWORD))
        self.assertEqual(EmailVerificationChallenge.objects.count(), 1)
        self.assertEqual(len(mail.outbox), 1)
        protected_user.refresh_from_db()
        self.assertEqual(protected_user.email_verification_failed_attempts, 0)

        verified = self.confirm(first_challenge_id, first_code)
        self.assertEqual(verified.status_code, status.HTTP_200_OK)
        attacker_login = self.client.post(
            reverse('accounts:login'),
            {'email': 'parent@example.com', 'password': NEW_PASSWORD},
            format='json',
        )
        self.assertEqual(attacker_login.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_matching_pending_credentials_can_resume_the_live_challenge(self):
        first = self.register()
        first_challenge_id = first.data['verification']['challenge_id']

        second = self.register(email='PARENT@Example.COM')

        self.assertEqual(second.status_code, status.HTTP_202_ACCEPTED)
        self.assertEqual(
            second.data['verification']['challenge_id'],
            first_challenge_id,
        )
        self.assertGreater(second.data['verification']['resend_after'], 0)
        self.assertEqual(EmailVerificationChallenge.objects.count(), 1)
        self.assertEqual(len(mail.outbox), 1)
        parent = User.objects.get(email='parent@example.com')
        self.assertTrue(parent.check_password(PASSWORD))

    def test_verified_parent_is_protected_from_re_registration(self):
        registered = self.register()
        challenge_id = registered.data['verification']['challenge_id']
        verified = self.confirm(challenge_id, self.verification_code())
        self.assertEqual(verified.status_code, status.HTTP_200_OK)
        parent = User.objects.get(email='parent@example.com')

        duplicate = self.register(
            email='PARENT@EXAMPLE.COM',
            password=NEW_PASSWORD,
            password_confirmation=NEW_PASSWORD,
        )

        self.assertEqual(duplicate.status_code, status.HTTP_202_ACCEPTED)
        self.assertNotEqual(
            duplicate.data['verification']['challenge_id'],
            challenge_id,
        )
        self.assertEqual(User.objects.count(), 1)
        parent.refresh_from_db()
        self.assertTrue(parent.check_password(PASSWORD))
        self.assertFalse(parent.check_password(NEW_PASSWORD))
        self.assertIsNotNone(parent.email_verified_at)
        self.assertEqual(EmailVerificationChallenge.objects.count(), 1)
        self.assertEqual(len(mail.outbox), 1)

    def test_disabled_unverified_parent_is_protected_from_re_registration(self):
        parent = self.create_parent(verified=False)
        parent.is_active = False
        parent.save(update_fields=('is_active',))

        duplicate = self.register(
            email='PARENT@EXAMPLE.COM',
            password=NEW_PASSWORD,
            password_confirmation=NEW_PASSWORD,
        )

        self.assertEqual(duplicate.status_code, status.HTTP_202_ACCEPTED)
        self.assertEqual(User.objects.count(), 1)
        parent.refresh_from_db()
        self.assertTrue(parent.check_password(PASSWORD))
        self.assertFalse(parent.check_password(NEW_PASSWORD))
        self.assertFalse(parent.is_active)
        self.assertEqual(EmailVerificationChallenge.objects.count(), 0)
        self.assertEqual(len(mail.outbox), 0)

    def test_unique_insert_race_rechecks_the_winning_pending_user(self):
        parent = self.create_parent(verified=False)
        serializer = RegistrationSerializer(
            data={
                'email': 'PARENT@EXAMPLE.COM',
                'password': NEW_PASSWORD,
                'password_confirmation': NEW_PASSWORD,
            }
        )
        self.assertTrue(serializer.is_valid(), serializer.errors)

        # Model a stale initial lookup followed by another transaction winning
        # the unique-email insert. The retry must not mutate that row.
        with patch.object(
            User.objects,
            'select_for_update',
            side_effect=(User.objects.none(), User.objects.filter(pk=parent.pk)),
        ), patch.object(
            User.objects,
            'create_user',
            side_effect=IntegrityError('duplicate email'),
        ):
            result = serializer.save()

        self.assertFalse(result.issue_challenge)
        self.assertIsNone(result.user)
        self.assertEqual(User.objects.count(), 1)
        parent.refresh_from_db()
        self.assertTrue(parent.check_password(PASSWORD))
        self.assertFalse(parent.check_password(NEW_PASSWORD))
        self.assertIsNone(parent.email_verified_at)

    def test_correct_code_verifies_parent_and_returns_normal_session(self):
        registered = self.register()
        challenge_id = registered.data['verification']['challenge_id']

        response = self.confirm(challenge_id, self.verification_code())

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['user']['email'], 'parent@example.com')
        self.assertTrue(response.data['user']['email_verified'])
        self.assertEqual(response.data['user']['kid_profiles'], [])
        self.assertIn('access', response.data)
        self.assertIn('refresh', response.data)

        user = User.objects.get(email='parent@example.com')
        challenge = EmailVerificationChallenge.objects.get(pk=challenge_id)
        self.assertIsNotNone(user.email_verified_at)
        self.assertIsNotNone(challenge.consumed_at)

        reused = self.confirm(challenge_id, self.verification_code())
        self.assertEqual(reused.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(reused.data['code'], 'invalid_or_expired_code')

    def test_disabled_pending_parent_cannot_confirm_or_receive_tokens(self):
        registered = self.register()
        challenge_id = registered.data['verification']['challenge_id']
        parent = User.objects.get(email='parent@example.com')
        parent.is_active = False
        parent.save(update_fields=('is_active',))

        response = self.confirm(challenge_id, self.verification_code())

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertNotIn('access', response.data)
        self.assertNotIn('refresh', response.data)
        parent.refresh_from_db()
        self.assertIsNone(parent.email_verified_at)

    def test_attempt_budget_survives_rotations_locks_and_then_recovers(self):
        registered = self.register()
        first_id = registered.data['verification']['challenge_id']
        first_code = self.verification_code()
        first_wrong = '000000' if first_code != '000000' else '000001'

        for _ in range(2):
            wrong = self.confirm(first_id, first_wrong)
            self.assertEqual(wrong.status_code, status.HTTP_400_BAD_REQUEST)
            self.assertEqual(wrong.data['code'], 'invalid_or_expired_code')

        first = EmailVerificationChallenge.objects.get(pk=first_id)
        first.resend_available_at = timezone.now() - timedelta(seconds=1)
        first.save(update_fields=('resend_available_at',))
        re_registered = self.register(
            password=PASSWORD,
            password_confirmation=PASSWORD,
        )
        self.assertEqual(re_registered.status_code, status.HTTP_202_ACCEPTED)
        second_id = re_registered.data['verification']['challenge_id']
        self.assertNotEqual(second_id, first_id)
        self.assertEqual(
            User.objects.get(email='parent@example.com')
            .email_verification_failed_attempts,
            2,
        )
        second_code = self.verification_code()
        second_wrong = '000000' if second_code != '000000' else '000001'

        for _ in range(2):
            wrong = self.confirm(second_id, second_wrong)
            self.assertEqual(wrong.status_code, status.HTTP_400_BAD_REQUEST)
            self.assertEqual(wrong.data['code'], 'invalid_or_expired_code')

        second = EmailVerificationChallenge.objects.get(pk=second_id)
        second.resend_available_at = timezone.now() - timedelta(seconds=1)
        second.save(update_fields=('resend_available_at',))
        with self.captureOnCommitCallbacks(execute=True):
            resent = self.client.post(
                reverse('accounts:email-verification-resend'),
                {'challenge_id': second_id},
                format='json',
            )
        self.assertEqual(resent.status_code, status.HTTP_202_ACCEPTED)
        third_id = resent.data['verification']['challenge_id']
        third_code = self.verification_code()
        third_wrong = '000000' if third_code != '000000' else '000001'

        fifth_wrong = self.confirm(third_id, third_wrong)
        self.assertEqual(fifth_wrong.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(fifth_wrong.data['code'], 'invalid_or_expired_code')

        parent = User.objects.get(email='parent@example.com')
        self.assertEqual(parent.email_verification_failed_attempts, 5)
        self.assertIsNotNone(
            parent.email_verification_failure_window_started_at
        )
        self.assertGreater(parent.email_verification_locked_until, timezone.now())

        third = EmailVerificationChallenge.objects.get(pk=third_id)
        third.resend_available_at = timezone.now() - timedelta(seconds=1)
        third.save(update_fields=('resend_available_at',))
        sent_count = len(mail.outbox)
        locked_registration = self.register(
            password=PASSWORD,
            password_confirmation=PASSWORD,
        )
        self.assertEqual(
            locked_registration.status_code,
            status.HTTP_202_ACCEPTED,
        )
        self.assertEqual(
            locked_registration.data['verification']['challenge_id'],
            third_id,
        )
        self.assertGreater(
            locked_registration.data['verification']['resend_after'],
            0,
        )
        self.assertEqual(len(mail.outbox), sent_count)

        locked = self.confirm(third_id, third_code)
        self.assertEqual(locked.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(locked.data['code'], 'invalid_or_expired_code')
        self.assertIsNone(parent.email_verified_at)

        locked_resend = self.client.post(
            reverse('accounts:email-verification-resend'),
            {'challenge_id': third_id},
            format='json',
        )
        self.assertEqual(
            locked_resend.status_code,
            status.HTTP_429_TOO_MANY_REQUESTS,
        )
        self.assertEqual(locked_resend.data['code'], 'resend_too_soon')
        self.assertGreater(locked_resend.data['retry_after'], 0)

        parent.email_verification_locked_until = timezone.now() - timedelta(seconds=1)
        parent.save(update_fields=('email_verification_locked_until',))
        with self.captureOnCommitCallbacks(execute=True):
            recovered = self.client.post(
                reverse('accounts:email-verification-resend'),
                {'challenge_id': third_id},
                format='json',
            )
        self.assertEqual(recovered.status_code, status.HTTP_202_ACCEPTED)
        recovered_id = recovered.data['verification']['challenge_id']
        self.assertNotEqual(recovered_id, third_id)
        verified = self.confirm(recovered_id, self.verification_code())
        self.assertEqual(verified.status_code, status.HTTP_200_OK)

        parent.refresh_from_db()
        self.assertIsNotNone(parent.email_verified_at)
        self.assertEqual(parent.email_verification_failed_attempts, 0)
        self.assertIsNone(parent.email_verification_failure_window_started_at)
        self.assertIsNone(parent.email_verification_locked_until)

    def test_expired_or_unknown_challenge_never_verifies_parent(self):
        registered = self.register()
        challenge_id = registered.data['verification']['challenge_id']
        challenge = EmailVerificationChallenge.objects.get(pk=challenge_id)
        challenge.expires_at = timezone.now() - timedelta(seconds=1)
        challenge.save(update_fields=('expires_at',))

        expired = self.confirm(challenge_id, self.verification_code())
        unknown = self.confirm(
            'a1a5af4c-6e1f-41aa-a64b-b851f953a8c7',
            '123456',
        )

        self.assertEqual(expired.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(expired.data['code'], 'invalid_or_expired_code')
        self.assertEqual(unknown.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(unknown.data['code'], 'invalid_or_expired_code')

    def test_resend_enforces_cooldown_rotates_code_and_invalidates_old_challenge(self):
        registered = self.register()
        old_id = registered.data['verification']['challenge_id']
        old_code = self.verification_code()

        too_soon = self.client.post(
            reverse('accounts:email-verification-resend'),
            {'challenge_id': old_id},
            format='json',
        )
        self.assertEqual(too_soon.status_code, status.HTTP_429_TOO_MANY_REQUESTS)
        self.assertEqual(too_soon.data['code'], 'resend_too_soon')
        self.assertGreater(too_soon.data['retry_after'], 0)
        self.assertIn('Retry-After', too_soon.headers)
        self.assertEqual(len(mail.outbox), 1)

        old_challenge = EmailVerificationChallenge.objects.get(pk=old_id)
        old_challenge.resend_available_at = timezone.now() - timedelta(seconds=1)
        old_challenge.save(update_fields=('resend_available_at',))
        with self.captureOnCommitCallbacks(execute=True):
            resent = self.client.post(
                reverse('accounts:email-verification-resend'),
                {'challenge_id': old_id},
                format='json',
            )

        self.assertEqual(resent.status_code, status.HTTP_202_ACCEPTED)
        replacement = resent.data['verification']
        self.assertNotEqual(replacement['challenge_id'], old_id)
        self.assertEqual(replacement['destination_hint'], 'p***@example.com')
        self.assertEqual(len(mail.outbox), 2)
        new_code = self.verification_code()

        old_challenge.refresh_from_db()
        self.assertIsNotNone(old_challenge.invalidated_at)
        rejected_old = self.confirm(old_id, old_code)
        self.assertEqual(rejected_old.status_code, status.HTTP_400_BAD_REQUEST)
        accepted_new = self.confirm(replacement['challenge_id'], new_code)
        self.assertEqual(accepted_new.status_code, status.HTTP_200_OK)

    def test_unverified_parent_cannot_login_refresh_or_use_a_bearer_token(self):
        parent = self.create_parent(verified=False)
        with self.captureOnCommitCallbacks(execute=True):
            login = self.client.post(
                reverse('accounts:login'),
                {'email': parent.email, 'password': PASSWORD},
                format='json',
            )

        self.assertEqual(login.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(login.data['code'], 'email_verification_required')
        self.assertEqual(
            login.data['verification']['destination_hint'],
            'p***@example.com',
        )
        self.assertNotIn('access', login.data)
        self.assertEqual(len(mail.outbox), 1)

        refresh = RefreshToken.for_user(parent)
        self.client.credentials(
            HTTP_AUTHORIZATION=f'Bearer {refresh.access_token}'
        )
        protected = self.client.get(reverse('accounts:me'))
        self.assertEqual(protected.status_code, status.HTTP_401_UNAUTHORIZED)

        self.client.credentials()
        refreshed = self.client.post(
            reverse('accounts:token-refresh'),
            {'refresh': str(refresh)},
            format='json',
        )
        self.assertEqual(refreshed.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_login_accepts_email_case_insensitively_and_rejects_bad_credentials(self):
        self.create_parent()

        response = self.client.post(
            reverse('accounts:login'),
            {'email': 'PARENT@EXAMPLE.COM', 'password': PASSWORD},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['user']['email'], 'parent@example.com')
        self.assertIn('access', response.data)
        self.assertIn('refresh', response.data)

        bad_login = self.client.post(
            reverse('accounts:login'),
            {'email': 'parent@example.com', 'password': 'not-the-password'},
            format='json',
        )
        self.assertEqual(bad_login.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_refresh_rotation_blacklists_the_old_token(self):
        parent = self.create_parent()
        old_refresh = str(RefreshToken.for_user(parent))

        refreshed = self.client.post(
            reverse('accounts:token-refresh'),
            {'refresh': old_refresh},
            format='json',
        )
        self.assertEqual(refreshed.status_code, status.HTTP_200_OK)
        self.assertIn('access', refreshed.data)
        self.assertIn('refresh', refreshed.data)
        self.assertNotEqual(refreshed.data['refresh'], old_refresh)

        reused = self.client.post(
            reverse('accounts:token-refresh'),
            {'refresh': old_refresh},
            format='json',
        )
        self.assertEqual(reused.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_refresh_rejects_a_token_after_its_parent_is_disabled(self):
        parent = self.create_parent()
        refresh = str(RefreshToken.for_user(parent))
        parent.is_active = False
        parent.save(update_fields=('is_active',))

        response = self.client.post(
            reverse('accounts:token-refresh'),
            {'refresh': refresh},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_password_change_immediately_revokes_access_and_refresh_tokens(self):
        parent = self.create_parent()
        refresh = self.authenticate(parent)

        parent.set_password(NEW_PASSWORD)
        parent.save(update_fields=('password',))

        access_attempt = self.client.get(reverse('accounts:me'))
        self.assertEqual(access_attempt.status_code, status.HTTP_401_UNAUTHORIZED)
        self.client.credentials()
        refresh_attempt = self.client.post(
            reverse('accounts:token-refresh'),
            {'refresh': refresh},
            format='json',
        )
        self.assertEqual(refresh_attempt.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_logout_blacklists_only_the_authenticated_parents_refresh_token(self):
        parent = self.create_parent()
        other_parent = self.create_parent(email='other@example.com')
        own_refresh = self.authenticate(parent)
        other_refresh = str(RefreshToken.for_user(other_parent))

        wrong_owner = self.client.post(
            reverse('accounts:logout'),
            {'refresh': other_refresh},
            format='json',
        )
        self.assertEqual(wrong_owner.status_code, status.HTTP_400_BAD_REQUEST)

        response = self.client.post(
            reverse('accounts:logout'),
            {'refresh': own_refresh},
            format='json',
        )
        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)

        reused = self.client.post(
            reverse('accounts:token-refresh'),
            {'refresh': own_refresh},
            format='json',
        )
        self.assertEqual(reused.status_code, status.HTTP_401_UNAUTHORIZED)

        valid_other = self.client.post(
            reverse('accounts:token-refresh'),
            {'refresh': other_refresh},
            format='json',
        )
        self.assertEqual(valid_other.status_code, status.HTTP_200_OK)

    def test_me_requires_authentication_and_returns_only_current_parent(self):
        unauthenticated = self.client.get(reverse('accounts:me'))
        self.assertEqual(unauthenticated.status_code, status.HTTP_401_UNAUTHORIZED)

        parent = self.create_parent()
        KidProfile.objects.create(
            parent=parent,
            display_name='Ada',
            avatar_key=KidProfile.AvatarKey.DOVE,
        )
        self.authenticate(parent)

        response = self.client.get(reverse('accounts:me'))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['email'], parent.email)
        self.assertEqual(len(response.data['kid_profiles']), 1)
        self.assertEqual(response.data['kid_profiles'][0]['display_name'], 'Ada')

    def test_account_deletion_requires_password_and_erases_owned_data(self):
        parent = self.create_parent()
        profile = KidProfile.objects.create(
            parent=parent,
            display_name='Ada',
            avatar_key=KidProfile.AvatarKey.DOVE,
        )
        WaitlistSubscriber.objects.create(email=parent.email)
        refresh = self.authenticate(parent)
        self.assertTrue(OutstandingToken.objects.filter(user=parent).exists())

        rejected = self.client.delete(
            reverse('accounts:me'),
            {'password': 'wrong-password'},
            format='json',
        )
        self.assertEqual(rejected.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertTrue(User.objects.filter(pk=parent.pk).exists())

        deleted = self.client.delete(
            reverse('accounts:me'),
            {'password': PASSWORD},
            format='json',
        )
        self.assertEqual(deleted.status_code, status.HTTP_204_NO_CONTENT)
        self.assertFalse(User.objects.filter(pk=parent.pk).exists())
        self.assertFalse(KidProfile.objects.filter(pk=profile.pk).exists())
        self.assertFalse(
            WaitlistSubscriber.objects.filter(email=parent.email).exists()
        )
        self.assertFalse(OutstandingToken.objects.filter(user_id=parent.pk).exists())
        old_access = self.client.get(reverse('accounts:me'))
        self.assertEqual(old_access.status_code, status.HTTP_401_UNAUTHORIZED)
        self.client.credentials()
        old_refresh = self.client.post(
            reverse('accounts:token-refresh'),
            {'refresh': refresh},
            format='json',
        )
        self.assertEqual(old_refresh.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_unverified_account_can_be_deleted_without_a_session(self):
        pending = User.objects.create_user(
            email='pending-delete@example.com',
            password=PASSWORD,
        )
        RefreshToken.for_user(pending)
        self.assertTrue(OutstandingToken.objects.filter(user=pending).exists())

        response = self.client.delete(
            reverse('accounts:unverified-account-delete'),
            {
                'email': pending.email,
                'password': PASSWORD,
                'confirmation': 'DELETE',
            },
            format='json',
        )

        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertFalse(User.objects.filter(pk=pending.pk).exists())
        self.assertFalse(OutstandingToken.objects.filter(user_id=pending.pk).exists())

    def test_unverified_deletion_is_generic_and_never_deletes_verified_account(self):
        pending = User.objects.create_user(
            email='pending-stays@example.com',
            password=PASSWORD,
        )
        verified = self.create_parent(email='verified-stays@example.com')
        url = reverse('accounts:unverified-account-delete')

        wrong_password = self.client.delete(
            url,
            {
                'email': pending.email,
                'password': 'wrong-password',
                'confirmation': 'DELETE',
            },
            format='json',
        )
        verified_response = self.client.delete(
            url,
            {
                'email': verified.email,
                'password': PASSWORD,
                'confirmation': 'DELETE',
            },
            format='json',
        )
        missing_response = self.client.delete(
            url,
            {
                'email': 'missing-delete@example.com',
                'password': PASSWORD,
                'confirmation': 'DELETE',
            },
            format='json',
        )

        self.assertEqual(wrong_password.status_code, status.HTTP_204_NO_CONTENT)
        self.assertEqual(verified_response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertEqual(missing_response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertTrue(User.objects.filter(pk=pending.pk).exists())
        self.assertTrue(User.objects.filter(pk=verified.pk).exists())

    def test_parent_can_create_update_and_delete_only_their_kid_profiles(self):
        parent = self.create_parent()
        other_parent = self.create_parent(email='other@example.com')
        other_profile = KidProfile.objects.create(
            parent=other_parent,
            display_name='Noah',
            avatar_key=KidProfile.AvatarKey.LION,
        )
        self.authenticate(parent)

        created = self.client.post(
            reverse('accounts:kid-profile-list'),
            {
                'display_name': '  Ada   Grace ',
                'avatar_key': 'dove',
                'operation_id': str(uuid.uuid4()),
            },
            format='json',
        )
        self.assertEqual(created.status_code, status.HTTP_201_CREATED)
        self.assertEqual(created.data['display_name'], 'Ada Grace')
        self.assertNotIn('parent', created.data)

        profile_url = reverse('accounts:kid-profile-detail', args=[created.data['id']])
        updated = self.client.patch(
            profile_url,
            {'avatar_key': 'star'},
            format='json',
        )
        self.assertEqual(updated.status_code, status.HTTP_200_OK)
        self.assertEqual(updated.data['avatar_key'], 'star')

        hidden_profile_url = reverse('accounts:kid-profile-detail', args=[other_profile.id])
        hidden = self.client.get(hidden_profile_url)
        self.assertEqual(hidden.status_code, status.HTTP_404_NOT_FOUND)

        listed = self.client.get(reverse('accounts:kid-profile-list'))
        self.assertEqual(listed.status_code, status.HTTP_200_OK)
        self.assertEqual([item['id'] for item in listed.data], [created.data['id']])

        deleted = self.client.delete(profile_url)
        self.assertEqual(deleted.status_code, status.HTTP_204_NO_CONTENT)
        self.assertFalse(KidProfile.objects.filter(pk=created.data['id']).exists())

    def test_kid_profile_create_replays_the_same_operation_without_a_duplicate(self):
        parent = self.create_parent()
        self.authenticate(parent)
        operation_id = str(uuid.uuid4())
        payload = {
            'display_name': 'Ada',
            'avatar_key': 'dove',
            'operation_id': operation_id,
        }

        created = self.client.post(
            reverse('accounts:kid-profile-list'),
            payload,
            format='json',
        )
        replayed = self.client.post(
            reverse('accounts:kid-profile-list'),
            payload,
            format='json',
        )

        self.assertEqual(created.status_code, status.HTTP_201_CREATED)
        self.assertEqual(replayed.status_code, status.HTTP_200_OK)
        self.assertEqual(replayed.data, created.data)
        self.assertEqual(
            KidProfile.objects.filter(
                parent=parent,
                creation_operation_id=operation_id,
            ).count(),
            1,
        )

    def test_kid_profile_conflicting_idempotency_replay_returns_conflict(self):
        parent = self.create_parent()
        self.authenticate(parent)
        operation_id = str(uuid.uuid4())
        first = self.client.post(
            reverse('accounts:kid-profile-list'),
            {
                'display_name': 'Ada',
                'avatar_key': 'dove',
                'operation_id': operation_id,
            },
            format='json',
        )
        conflict = self.client.post(
            reverse('accounts:kid-profile-list'),
            {
                'display_name': 'Ada',
                'avatar_key': 'star',
                'operation_id': operation_id,
            },
            format='json',
        )

        self.assertEqual(first.status_code, status.HTTP_201_CREATED)
        self.assertEqual(conflict.status_code, status.HTTP_409_CONFLICT)
        self.assertEqual(KidProfile.objects.filter(parent=parent).count(), 1)

    @override_settings(MAX_KID_PROFILES=2)
    def test_kid_profile_creation_enforces_the_account_limit(self):
        parent = self.create_parent()
        self.authenticate(parent)
        for index in range(2):
            created = self.client.post(
                reverse('accounts:kid-profile-list'),
                {
                    'display_name': f'Kid {index}',
                    'avatar_key': 'dove',
                    'operation_id': str(uuid.uuid4()),
                },
                format='json',
            )
            self.assertEqual(created.status_code, status.HTTP_201_CREATED)

        rejected = self.client.post(
            reverse('accounts:kid-profile-list'),
            {
                'display_name': 'One too many',
                'avatar_key': 'star',
                'operation_id': str(uuid.uuid4()),
            },
            format='json',
        )
        self.assertEqual(rejected.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(KidProfile.objects.filter(parent=parent).count(), 2)

    def test_kid_profile_operation_id_has_a_per_parent_database_barrier(self):
        parent = self.create_parent()
        other_parent = self.create_parent(email='other@example.com')
        operation_id = uuid.uuid4()
        KidProfile.objects.create(
            parent=parent,
            display_name='Ada',
            avatar_key=KidProfile.AvatarKey.DOVE,
            creation_operation_id=operation_id,
        )

        with self.assertRaises(IntegrityError), transaction.atomic():
            KidProfile.objects.create(
                parent=parent,
                display_name='Ada duplicate',
                avatar_key=KidProfile.AvatarKey.STAR,
                creation_operation_id=operation_id,
            )

        KidProfile.objects.create(
            parent=other_parent,
            display_name='Noah',
            avatar_key=KidProfile.AvatarKey.LION,
            creation_operation_id=operation_id,
        )
        self.assertEqual(
            KidProfile.objects.filter(creation_operation_id=operation_id).count(),
            2,
        )

    def test_kid_profile_validation_rejects_blank_names_and_unknown_avatar_keys(self):
        parent = self.create_parent()
        self.authenticate(parent)

        missing_operation_id = self.client.post(
            reverse('accounts:kid-profile-list'),
            {'display_name': 'Ada', 'avatar_key': 'lion'},
            format='json',
        )
        self.assertEqual(
            missing_operation_id.status_code,
            status.HTTP_400_BAD_REQUEST,
        )
        self.assertIn('operation_id', missing_operation_id.data)

        blank_name = self.client.post(
            reverse('accounts:kid-profile-list'),
            {
                'display_name': '   ',
                'avatar_key': 'lion',
                'operation_id': str(uuid.uuid4()),
            },
            format='json',
        )
        self.assertEqual(blank_name.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn('display_name', blank_name.data)

        unknown_avatar = self.client.post(
            reverse('accounts:kid-profile-list'),
            {
                'display_name': 'Ada',
                'avatar_key': 'https://untrusted.example/avatar.png',
                'operation_id': str(uuid.uuid4()),
            },
            format='json',
        )
        self.assertEqual(unknown_avatar.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn('avatar_key', unknown_avatar.data)


class KidProfilePreferencesApiTests(APITestCase):
    def setUp(self):
        self.parent = User.objects.create_user(
            email='preferences@example.com',
            password=PASSWORD,
            email_verified_at=timezone.now(),
        )
        self.profile = KidProfile.objects.create(
            parent=self.parent,
            display_name='Ada',
            avatar_key=KidProfile.AvatarKey.DOVE,
        )

    def authenticate(self, user):
        refresh = RefreshToken.for_user(user)
        self.client.credentials(
            HTTP_AUTHORIZATION=f'Bearer {refresh.access_token}'
        )

    def url(self, profile=None):
        return reverse(
            'accounts:kid-profile-preferences',
            kwargs={'profile_id': profile or self.profile.pk},
        )

    def test_default_preferences_require_a_verified_parent(self):
        unauthenticated = self.client.get(self.url())
        self.assertEqual(
            unauthenticated.status_code,
            status.HTTP_401_UNAUTHORIZED,
        )

        self.authenticate(self.parent)
        response = self.client.get(self.url())
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            set(response.data),
            {
                'profile_id',
                'story_text_scale',
                'narration_enabled',
                'streak_timezone_offset_minutes',
                'updated_at',
            },
        )
        self.assertEqual(response.data['profile_id'], str(self.profile.pk))
        self.assertEqual(response.data['story_text_scale'], 'comfortable')
        self.assertTrue(response.data['narration_enabled'])
        self.assertTrue(response.data['updated_at'])
        self.assertTrue(
            KidProfilePreferences.objects.filter(profile=self.profile).exists()
        )

        unverified = User.objects.create_user(
            email='pending-preferences@example.com',
            password=PASSWORD,
        )
        unverified_profile = KidProfile.objects.create(
            parent=unverified,
            display_name='Pending',
            avatar_key=KidProfile.AvatarKey.LION,
        )
        self.authenticate(unverified)
        rejected = self.client.get(self.url(unverified_profile.pk))
        self.assertEqual(rejected.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_patch_is_partial_and_rejects_invalid_typed_values(self):
        self.authenticate(self.parent)

        fresh_profile = KidProfile.objects.create(
            parent=self.parent,
            display_name='Grace',
            avatar_key=KidProfile.AvatarKey.STAR,
        )
        invalid_fresh_update = self.client.patch(
            self.url(fresh_profile.pk),
            {'story_text_scale': 'enormous'},
            format='json',
        )
        self.assertEqual(
            invalid_fresh_update.status_code,
            status.HTTP_400_BAD_REQUEST,
        )
        self.assertFalse(
            KidProfilePreferences.objects.filter(profile=fresh_profile).exists()
        )

        text_update = self.client.patch(
            self.url(),
            {'story_text_scale': 'extra_large'},
            format='json',
        )
        self.assertEqual(text_update.status_code, status.HTTP_200_OK)
        self.assertEqual(text_update.data['story_text_scale'], 'extra_large')
        self.assertTrue(text_update.data['narration_enabled'])

        narration_update = self.client.patch(
            self.url(),
            {'narration_enabled': False},
            format='json',
        )
        self.assertEqual(narration_update.status_code, status.HTTP_200_OK)
        self.assertEqual(narration_update.data['story_text_scale'], 'extra_large')
        self.assertFalse(narration_update.data['narration_enabled'])

        invalid_scale = self.client.patch(
            self.url(),
            {'story_text_scale': 'enormous'},
            format='json',
        )
        self.assertEqual(invalid_scale.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn('story_text_scale', invalid_scale.data)

        invalid_narration = self.client.patch(
            self.url(),
            {'narration_enabled': 'sometimes'},
            format='json',
        )
        self.assertEqual(
            invalid_narration.status_code,
            status.HTTP_400_BAD_REQUEST,
        )
        self.assertIn('narration_enabled', invalid_narration.data)

        preferences = KidProfilePreferences.objects.get(profile=self.profile)
        self.assertEqual(preferences.story_text_scale, 'extra_large')
        self.assertFalse(preferences.narration_enabled)

    def test_foreign_and_missing_profiles_are_identical_404s(self):
        other_parent = User.objects.create_user(
            email='other-preferences@example.com',
            password=PASSWORD,
            email_verified_at=timezone.now(),
        )
        foreign_profile = KidProfile.objects.create(
            parent=other_parent,
            display_name='Noah',
            avatar_key=KidProfile.AvatarKey.LION,
        )
        self.authenticate(self.parent)

        missing = self.client.get(self.url(uuid.uuid4()))
        foreign = self.client.get(self.url(foreign_profile.pk))
        self.assertEqual(missing.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(foreign.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(missing.data, foreign.data)
        self.assertFalse(
            KidProfilePreferences.objects.filter(profile=foreign_profile).exists()
        )


class EmailDeliveryFailureApiTests(APITransactionTestCase):
    def setUp(self):
        super().setUp()
        cache.clear()

    def registration_payload(self):
        return {
            'email': 'parent@example.com',
            'password': PASSWORD,
            'password_confirmation': PASSWORD,
        }

    def assert_code_not_returned(self, response, delivery_mock):
        message = delivery_mock.call_args.kwargs['message']
        match = re.search(r'\b(\d{6})\b', message)
        self.assertIsNotNone(match)
        response_values = {
            str(value)
            for value in response.data['verification'].values()
        }
        self.assertNotIn(match.group(1), response_values)

    def test_registration_returns_persisted_retryable_challenge_when_email_fails(self):
        with patch(
            'apps.accounts.email_verification.send_mail',
            side_effect=RuntimeError('provider unavailable'),
        ) as delivery:
            response = self.client.post(
                reverse('accounts:register'),
                self.registration_payload(),
                format='json',
            )

        self.assertEqual(response.status_code, status.HTTP_202_ACCEPTED)
        self.assertEqual(response.data['code'], 'verification_delivery_delayed')
        self.assertTrue(response.data['verification_delivery_delayed'])
        self.assertEqual(response.data['verification']['resend_after'], 0)
        self.assertNotIn('access', response.data)
        self.assertNotIn('refresh', response.data)
        self.assert_code_not_returned(response, delivery)

        challenge = EmailVerificationChallenge.objects.get(
            pk=response.data['verification']['challenge_id']
        )
        self.assertLessEqual(challenge.resend_available_at, timezone.now())
        self.assertIsNone(challenge.invalidated_at)
        self.assertIsNone(challenge.consumed_at)
        self.assertIsNone(challenge.user.email_verified_at)

    def test_failed_resend_returns_replacement_id_and_allows_immediate_retry(self):
        registered = self.client.post(
            reverse('accounts:register'),
            self.registration_payload(),
            format='json',
        )
        old_id = registered.data['verification']['challenge_id']
        old_challenge = EmailVerificationChallenge.objects.get(pk=old_id)
        old_challenge.resend_available_at = timezone.now() - timedelta(seconds=1)
        old_challenge.save(update_fields=('resend_available_at',))

        with patch(
            'apps.accounts.email_verification.send_mail',
            side_effect=RuntimeError('provider unavailable'),
        ) as delivery:
            response = self.client.post(
                reverse('accounts:email-verification-resend'),
                {'challenge_id': old_id},
                format='json',
            )

        self.assertEqual(response.status_code, status.HTTP_202_ACCEPTED)
        self.assertEqual(response.data['code'], 'verification_delivery_delayed')
        self.assertTrue(response.data['verification_delivery_delayed'])
        replacement_id = response.data['verification']['challenge_id']
        self.assertNotEqual(replacement_id, old_id)
        self.assertEqual(response.data['verification']['resend_after'], 0)
        self.assert_code_not_returned(response, delivery)

        old_challenge.refresh_from_db()
        replacement = EmailVerificationChallenge.objects.get(pk=replacement_id)
        self.assertIsNotNone(old_challenge.invalidated_at)
        self.assertLessEqual(replacement.resend_available_at, timezone.now())
        self.assertIsNone(replacement.invalidated_at)

        recovered = self.client.post(
            reverse('accounts:email-verification-resend'),
            {'challenge_id': replacement_id},
            format='json',
        )
        self.assertEqual(recovered.status_code, status.HTTP_202_ACCEPTED)
        self.assertNotIn('code', recovered.data)
        self.assertNotEqual(
            recovered.data['verification']['challenge_id'],
            replacement_id,
        )

    def test_unverified_login_reports_delayed_delivery_without_becoming_a_500(self):
        User.objects.create_user(
            email='parent@example.com',
            password=PASSWORD,
        )
        with patch(
            'apps.accounts.email_verification.send_mail',
            side_effect=RuntimeError('provider unavailable'),
        ):
            response = self.client.post(
                reverse('accounts:login'),
                {'email': 'parent@example.com', 'password': PASSWORD},
                format='json',
            )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(response.data['code'], 'email_verification_required')
        self.assertEqual(
            response.data['verification_delivery_code'],
            'verification_delivery_delayed',
        )
        self.assertTrue(response.data['verification_delivery_delayed'])
        self.assertEqual(int(str(response.data['verification']['resend_after'])), 0)


class EmailVerificationMigrationTests(TransactionTestCase):
    """Existing parent accounts must not be locked out by the new gate."""

    migrate_from = [('accounts', '0001_initial')]
    migrate_to = [('accounts', '0003_user_email_verification_lockout')]

    def setUp(self):
        super().setUp()
        executor = MigrationExecutor(connection)
        self.latest_targets = executor.loader.graph.leaf_nodes()
        executor.migrate(self.migrate_from)
        old_apps = executor.loader.project_state(self.migrate_from).apps
        OldUser = old_apps.get_model('accounts', 'User')
        self.user_id = OldUser.objects.create(
            email='existing@example.com',
            password='unusable-for-this-test',
        ).pk

        executor = MigrationExecutor(connection)
        executor.migrate(self.migrate_to)
        self.migrated_apps = executor.loader.project_state(self.migrate_to).apps

    def tearDown(self):
        # Leave the shared test schema at the current migration for any test
        # class that happens to run after this one.
        MigrationExecutor(connection).migrate(self.latest_targets)
        super().tearDown()

    def test_existing_parent_is_marked_verified(self):
        MigratedUser = self.migrated_apps.get_model('accounts', 'User')
        user = MigratedUser.objects.get(pk=self.user_id)
        self.assertIsNotNone(user.email_verified_at)
        self.assertEqual(user.email_verification_failed_attempts, 0)
        self.assertIsNone(user.email_verification_failure_window_started_at)
        self.assertIsNone(user.email_verification_locked_until)

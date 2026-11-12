"""Console recovery codes require an explicit named local-test exception."""

import json
import os
import secrets
import subprocess
import sys
from contextlib import redirect_stdout
from datetime import timedelta
from io import StringIO
from pathlib import Path
from unittest.mock import patch

from django.core import mail
from django.core.cache import cache
from django.test import SimpleTestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APITestCase

from .models import PasswordResetChallenge, User


FIXTURE_EMAIL = 'local-reset-fixture@example.test'
TEST_CODE = '123456'
CONSOLE_BACKEND = 'django.core.mail.backends.console.EmailBackend'
MEMORY_BACKEND = 'django.core.mail.backends.locmem.EmailBackend'


@override_settings(
    PASSWORD_RESET_TTL=timedelta(minutes=5),
    EMAIL_BACKEND=CONSOLE_BACKEND,
    DEBUG=True,
    PASSWORD_RESET_PRINT_LOCAL_TEST_CODES=False,
    PASSWORD_RESET_LOCAL_TEST_EMAILS=frozenset(),
)
class PasswordResetLocalConsoleTests(APITestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(
            email=FIXTURE_EMAIL,
            password='An-existing-test-fixture-password-2026!',
            email_verified_at=timezone.now(),
        )
        self.request_url = reverse('accounts:password-reset-request')
        self.verify_url = reverse('accounts:password-reset-verify')

    def request_code(self):
        output = StringIO()
        with redirect_stdout(output), patch(
            'apps.accounts.password_reset.secrets.randbelow', return_value=123456,
        ), self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(
                self.request_url, {'email': FIXTURE_EMAIL}, format='json',
            )
        self.assertEqual(response.status_code, 202)
        self.assertEqual(set(response.data), {'detail', 'challenge_id', 'expires_in'})
        challenge = PasswordResetChallenge.objects.get(
            pk=response.data['challenge_id'],
        )
        return response, challenge, output.getvalue()

    def verify_code(self, challenge):
        return self.client.post(
            self.verify_url,
            {'challenge_id': str(challenge.pk), 'code': TEST_CODE},
            format='json',
        )

    @override_settings(
        PASSWORD_RESET_PRINT_LOCAL_TEST_CODES=True,
        PASSWORD_RESET_LOCAL_TEST_EMAILS=frozenset({FIXTURE_EMAIL}),
    )
    def test_explicit_debug_fixture_console_delivery_preserves_valid_five_minute_proof(self):
        before = timezone.now()
        response, challenge, printed = self.request_code()
        after = timezone.now()

        self.assertIn(TEST_CODE, printed)
        self.assertIn(FIXTURE_EMAIL, printed)
        self.assertIn('This code expires in 5 minutes.', printed)
        self.assertEqual(response.data['expires_in'], 300)
        self.assertGreaterEqual(challenge.expires_at, before + timedelta(minutes=5))
        self.assertLessEqual(challenge.expires_at, after + timedelta(minutes=5))
        self.assertIsNone(challenge.invalidated_at)
        self.assertIsNone(challenge.consumed_at)
        self.assertNotEqual(challenge.code_digest, TEST_CODE)
        self.assertEqual(self.verify_code(challenge).status_code, 204)
        # Neither the public API nor the ordinary logging path returns a code.
        self.assertNotIn('code', response.data)

    @override_settings(
        PASSWORD_RESET_LOCAL_TEST_EMAILS=frozenset({FIXTURE_EMAIL}),
    )
    def test_console_delivery_without_opt_in_prints_nothing_and_invalidates(self):
        with self.assertLogs('django.request', level='WARNING'):
            _, challenge, printed = self.request_code()
            self.assertEqual(self.verify_code(challenge).status_code, 400)
        self.assertEqual(printed, '')
        self.assertIsNotNone(challenge.invalidated_at)

    @override_settings(
        PASSWORD_RESET_PRINT_LOCAL_TEST_CODES=True,
        PASSWORD_RESET_LOCAL_TEST_EMAILS=frozenset({'a-different-fixture@example.test'}),
    )
    def test_opt_in_never_prints_for_a_different_recipient(self):
        _, challenge, printed = self.request_code()
        self.assertEqual(printed, '')
        self.assertIsNotNone(challenge.invalidated_at)

    @override_settings(
        DEBUG=False,
        PASSWORD_RESET_PRINT_LOCAL_TEST_CODES=True,
        PASSWORD_RESET_LOCAL_TEST_EMAILS=frozenset({FIXTURE_EMAIL}),
    )
    def test_runtime_debug_guard_blocks_console_even_if_startup_is_bypassed(self):
        _, challenge, printed = self.request_code()
        self.assertEqual(printed, '')
        self.assertIsNotNone(challenge.invalidated_at)

    @override_settings(
        PASSWORD_RESET_PRINT_LOCAL_TEST_CODES=True,
        PASSWORD_RESET_LOCAL_TEST_EMAILS=frozenset(),
    )
    def test_empty_allowlist_cannot_print_even_if_startup_is_bypassed(self):
        _, challenge, printed = self.request_code()
        self.assertEqual(printed, '')
        self.assertIsNotNone(challenge.invalidated_at)

    @override_settings(EMAIL_BACKEND=MEMORY_BACKEND)
    def test_normal_mail_delivery_is_unaffected_by_local_console_flags(self):
        for local_flag in (False, True):
            with self.subTest(local_flag=local_flag), override_settings(
                PASSWORD_RESET_PRINT_LOCAL_TEST_CODES=local_flag,
                PASSWORD_RESET_LOCAL_TEST_EMAILS=frozenset(),
            ):
                response, challenge, printed = self.request_code()
                self.assertEqual(printed, '')
                self.assertIsNone(challenge.invalidated_at)
                self.assertEqual(mail.outbox[-1].to, [FIXTURE_EMAIL])
                self.assertIn('This code expires in 5 minutes.', mail.outbox[-1].body)
                self.assertEqual(response.data['expires_in'], 300)
                self.assertEqual(self.verify_code(challenge).status_code, 204)

    @override_settings(
        EMAIL_BACKEND=MEMORY_BACKEND,
        PASSWORD_RESET_PRINT_LOCAL_TEST_CODES=True,
        PASSWORD_RESET_LOCAL_TEST_EMAILS=frozenset({FIXTURE_EMAIL}),
    )
    def test_code_is_valid_just_before_five_minutes_and_invalid_at_the_boundary(self):
        _, challenge, _ = self.request_code()
        boundary = challenge.expires_at
        with patch(
            'apps.accounts.password_reset.timezone.now',
            return_value=boundary - timedelta(microseconds=1),
        ):
            self.assertEqual(self.verify_code(challenge).status_code, 204)
        with patch(
            'apps.accounts.password_reset.timezone.now', return_value=boundary,
        ):
            rejected = self.verify_code(challenge)
        self.assertEqual(rejected.status_code, 400)
        self.assertEqual(rejected.data['code'], 'invalid_or_expired_password_reset')
        self.user.refresh_from_db()
        self.assertTrue(
            self.user.check_password('An-existing-test-fixture-password-2026!'),
        )


class LocalResetConsoleSettingsTests(SimpleTestCase):
    def load_settings(self, **overrides):
        # Isolate from the running developer server's explicit test exception.
        environment = {
            'PATH': os.environ.get('PATH', ''),
            'DJANGO_DEBUG': 'false',
            'DJANGO_SECRET_KEY': secrets.token_urlsafe(64),
            'DJANGO_JWT_SIGNING_KEY': secrets.token_urlsafe(64),
            'EMAIL_VERIFICATION_PEPPER': secrets.token_urlsafe(64),
            'PASSWORD_RESET_PEPPER': secrets.token_urlsafe(64),
            'ACCOUNT_DELETION_PEPPER': secrets.token_urlsafe(64),
            'DJANGO_ALLOWED_HOSTS': 'api.kingdom.test',
            'DJANGO_DATABASE_URL': 'postgresql://check:unused@localhost/check',
            'DJANGO_CACHE_URL': 'rediss://localhost:6379/0',
            'DJANGO_EMAIL_BACKEND': 'django.core.mail.backends.smtp.EmailBackend',
            'DJANGO_EMAIL_HOST': 'smtp.kingdom.test',
            'DJANGO_DEFAULT_FROM_EMAIL': 'Kingdom Kids <no-reply@kingdom.test>',
            'DJANGO_CONTENT_MEDIA_HOSTS': 'cdn.kingdom.test',
        }
        environment.update(overrides)
        source = Path(__file__).resolve().parents[2] / 'Core' / 'settings.py'
        return subprocess.run(
            [
                sys.executable,
                '-c',
                'import json, runpy, sys; values = runpy.run_path(sys.argv[1]); '
                'print(json.dumps({"ttl_seconds": '
                'values["PASSWORD_RESET_TTL"].total_seconds(), '
                '"print_codes": values["PASSWORD_RESET_PRINT_LOCAL_TEST_CODES"], '
                '"allowed_emails": sorted(values["PASSWORD_RESET_LOCAL_TEST_EMAILS"])}))',
                str(source),
            ],
            env=environment,
            text=True,
            capture_output=True,
            timeout=10,
        )

    def test_default_configuration_is_five_minutes_and_never_prints_codes(self):
        result = self.load_settings()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            'ttl_seconds': 300,
            'print_codes': False,
            'allowed_emails': [],
        })

    def test_production_configuration_rejects_local_code_printing(self):
        result = self.load_settings(
            PASSWORD_RESET_PRINT_LOCAL_TEST_CODES='true',
            PASSWORD_RESET_LOCAL_TEST_EMAILS=FIXTURE_EMAIL,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Local reset-code printing requires DJANGO_DEBUG=true.', result.stderr)

    def test_local_printing_requires_a_named_fixture_and_normalizes_the_allowlist(self):
        missing = self.load_settings(
            DJANGO_DEBUG='true', PASSWORD_RESET_PRINT_LOCAL_TEST_CODES='true',
        )
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn('Local reset-code printing requires named test emails.', missing.stderr)
        accepted = self.load_settings(
            DJANGO_DEBUG='true',
            PASSWORD_RESET_PRINT_LOCAL_TEST_CODES='true',
            PASSWORD_RESET_LOCAL_TEST_EMAILS=f' {FIXTURE_EMAIL.upper()} , ',
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertEqual(json.loads(accepted.stdout), {
            'ttl_seconds': 300,
            'print_codes': True,
            'allowed_emails': [FIXTURE_EMAIL],
        })

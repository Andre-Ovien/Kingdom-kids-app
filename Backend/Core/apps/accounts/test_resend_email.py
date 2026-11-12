"""Provider configuration and real Django SMTP composition, without sending mail."""
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
from io import StringIO
from unittest.mock import patch
from uuid import uuid4

from django.test import SimpleTestCase, override_settings
from django.core.management import call_command, CommandError

from .account_deletion import _deliver_account_deletion_email
from .email_verification import _deliver_verification_email
from .password_reset import _deliver_password_reset_email


class ResendSMTPConfigurationTests(SimpleTestCase):
    def settings_result(self, **overrides):
        environment = {
            'PATH': os.environ.get('PATH', ''),
            'DJANGO_DEBUG': 'true',
            'DJANGO_EMAIL_BACKEND': 'django.core.mail.backends.smtp.EmailBackend',
            'DJANGO_EMAIL_HOST': 'smtp.resend.com',
            'DJANGO_DEFAULT_FROM_EMAIL': 'Kingdom Kids <no-reply@notify.kingdom.test>',
            'RESEND_API_KEY': 'test-only-key-not-a-real-credential',
        }
        if overrides.get('DJANGO_DEBUG') == 'false':
            environment.update({
                'DJANGO_SECRET_KEY': secrets.token_urlsafe(64),
                'DJANGO_JWT_SIGNING_KEY': secrets.token_urlsafe(64),
                'EMAIL_VERIFICATION_PEPPER': secrets.token_urlsafe(64),
                'PASSWORD_RESET_PEPPER': secrets.token_urlsafe(64),
                'ACCOUNT_DELETION_PEPPER': secrets.token_urlsafe(64),
                'DJANGO_ALLOWED_HOSTS': 'api.kingdom.test',
                'DJANGO_DATABASE_URL': 'postgresql://check:unused@localhost/check',
                'DJANGO_CACHE_URL': 'rediss://localhost:6379/0',
                'DJANGO_CONTENT_MEDIA_HOSTS': 'cdn.kingdom.test',
            })
        environment.update(overrides)
        source = Path(__file__).resolve().parents[2] / 'Core/settings.py'
        return subprocess.run(
            [sys.executable, '-c',
             'import json, os, runpy, sys; s=runpy.run_path(sys.argv[1]); '
             'print(json.dumps({"host":s["EMAIL_HOST"], "user":s["EMAIL_HOST_USER"], '
             '"password_set": bool(s["EMAIL_HOST_PASSWORD"]), '
             '"uses_server_key": bool(os.environ.get("RESEND_API_KEY")) and s["EMAIL_HOST_PASSWORD"] == os.environ.get("RESEND_API_KEY"), '
             '"uses_explicit_password": bool(os.environ.get("DJANGO_EMAIL_HOST_PASSWORD")) and s["EMAIL_HOST_PASSWORD"] == os.environ.get("DJANGO_EMAIL_HOST_PASSWORD"), '
             '"port":s["EMAIL_PORT"], "tls":s["EMAIL_USE_TLS"], "ssl":s["EMAIL_USE_SSL"]}))',
             str(source)],
            env=environment, text=True, capture_output=True, timeout=10,
        )

    def test_resend_uses_server_only_key_and_fixed_username(self):
        result = self.settings_result()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            'host': 'smtp.resend.com', 'user': 'resend', 'password_set': True,
            'uses_server_key': True, 'uses_explicit_password': False,
            'port': 587, 'tls': True, 'ssl': False,
        })
        self.assertNotIn('test-only-key-not-a-real-credential', result.stdout)

    def test_resend_also_accepts_existing_smtp_password_configuration(self):
        result = self.settings_result(DJANGO_EMAIL_HOST_PASSWORD='explicit-test-smtp-password')
        self.assertEqual(result.returncode, 0, result.stderr)
        values = json.loads(result.stdout)
        self.assertTrue(values['uses_explicit_password'])
        self.assertFalse(values['uses_server_key'])

    def test_a_different_smtp_host_never_receives_the_resend_key(self):
        result = self.settings_result(DJANGO_EMAIL_HOST='smtp.other-provider.test')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)['password_set'])

    def test_missing_key_or_wrong_username_fails_before_network_access(self):
        for overrides, message in (
            ({'RESEND_API_KEY': ''}, 'Set RESEND_API_KEY'),
            ({'RESEND_API_KEY': '   '}, 'Set RESEND_API_KEY'),
            ({'DJANGO_EMAIL_HOST_USER': 'wrong-user'}, 'requires DJANGO_EMAIL_HOST_USER=resend'),
        ):
            with self.subTest(overrides=overrides):
                result = self.settings_result(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertNotIn('test-only-key-not-a-real-credential', result.stderr)

    def test_sender_must_be_valid_and_not_localhost(self):
        for address in ('', 'not-an-email', 'Kingdom Kids <no-reply@localhost>',
                        'Kingdom Kids <no-reply@notify.kingdom.test>\r\nBcc: other@example.com'):
            with self.subTest(address=address):
                result = self.settings_result(DJANGO_DEFAULT_FROM_EMAIL=address)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('DJANGO_DEFAULT_FROM_EMAIL', result.stderr)

    def test_documented_resend_ports_require_matching_encryption(self):
        for port in (25, 587, 2587):
            with self.subTest(port=port, encryption='STARTTLS'):
                result = self.settings_result(DJANGO_EMAIL_PORT=str(port))
                self.assertEqual(result.returncode, 0, result.stderr)
        for port in (465, 2465):
            with self.subTest(port=port, encryption='implicit TLS'):
                result = self.settings_result(DJANGO_EMAIL_PORT=str(port),
                                              DJANGO_EMAIL_USE_TLS='false', DJANGO_EMAIL_USE_SSL='true')
                self.assertEqual(result.returncode, 0, result.stderr)
        for overrides in (
            {'DJANGO_EMAIL_PORT': '465'},
            {'DJANGO_EMAIL_PORT': '587', 'DJANGO_EMAIL_USE_TLS': 'false', 'DJANGO_EMAIL_USE_SSL': 'true'},
            {'DJANGO_EMAIL_PORT': '2525'},
            {'DJANGO_EMAIL_USE_TLS': 'false', 'DJANGO_EMAIL_USE_SSL': 'false'},
        ):
            with self.subTest(overrides=overrides):
                result = self.settings_result(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Resend SMTP requires STARTTLS', result.stderr)

    def test_console_development_does_not_require_a_provider_key(self):
        result = self.settings_result(
            DJANGO_EMAIL_BACKEND='django.core.mail.backends.console.EmailBackend',
            DJANGO_EMAIL_HOST='localhost', DJANGO_DEFAULT_FROM_EMAIL='no-reply@localhost',
            RESEND_API_KEY='',
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)['password_set'])

    def test_production_accepts_verified_domain_configuration_but_not_sandbox_sender(self):
        configured = self.settings_result(DJANGO_DEBUG='false')
        self.assertEqual(configured.returncode, 0, configured.stderr)
        sandbox = self.settings_result(DJANGO_DEBUG='false', DJANGO_DEFAULT_FROM_EMAIL='onboarding@resend.dev')
        self.assertNotEqual(sandbox.returncode, 0)
        self.assertIn('on your verified domain', sandbox.stderr)


@override_settings(
    DEBUG=False,
    EMAIL_BACKEND='django.core.mail.backends.smtp.EmailBackend',
    DEFAULT_FROM_EMAIL='Kingdom Kids <no-reply@notify.kingdom.test>',
    EMAIL_HOST='smtp.resend.com', EMAIL_PORT=587,
    EMAIL_HOST_USER='resend', EMAIL_HOST_PASSWORD='test-only-key-not-a-real-credential',
    EMAIL_USE_TLS=True, EMAIL_USE_SSL=False, EMAIL_TIMEOUT=10,
)
class ResendTransactionalMailTests(SimpleTestCase):
    def test_verification_recovery_and_deletion_use_the_shared_smtp_transport(self):
        deliveries = (
            (_deliver_verification_email, 'Your Kingdom Kids verification code'),
            (_deliver_password_reset_email, 'Reset your Kingdom Kids password'),
            (_deliver_account_deletion_email, 'Confirm your Kingdom Kids account deletion'),
        )
        # Intercept SMTP itself, not the application functions: MIME composition,
        # STARTTLS, authentication and Django's accepted-message count all run.
        with patch('django.core.mail.backends.smtp.smtplib.SMTP') as smtp:
            connection = smtp.return_value
            connection.sendmail.return_value = {}
            for delivery, subject in deliveries:
                with self.subTest(subject=subject):
                    delivery(uuid4(), 'parent@example.test', '123456')
                    sender, recipients, payload = connection.sendmail.call_args.args
                    self.assertEqual(sender, 'no-reply@notify.kingdom.test')
                    self.assertEqual(recipients, ['parent@example.test'])
                    self.assertIn(subject.encode(), payload)
                    self.assertIn(b'123456', payload)
            self.assertEqual(smtp.call_count, 3)
            smtp.assert_called_with('smtp.resend.com', 587, local_hostname=smtp.call_args.kwargs['local_hostname'], timeout=10)
            self.assertEqual(connection.starttls.call_count, 3)
            self.assertEqual(connection.login.call_count, 3)
            connection.login.assert_called_with('resend', 'test-only-key-not-a-real-credential')
            self.assertEqual(connection.sendmail.call_count, 3)


@override_settings(USING_RESEND_SMTP=True)
class ResendDiagnosticCommandTests(SimpleTestCase):
    def test_default_diagnostic_does_not_open_a_network_connection(self):
        with patch('apps.accounts.management.commands.check_resend_email.get_connection') as connect:
            output = StringIO()
            call_command('check_resend_email', stdout=output)
        connect.assert_not_called()
        self.assertIn('No network connection or email was sent.', output.getvalue())

    def test_explicit_connection_authenticates_without_sending(self):
        with patch('apps.accounts.management.commands.check_resend_email.get_connection') as connect:
            output = StringIO()
            call_command('check_resend_email', connect=True, stdout=output)
        connect.return_value.open.assert_called_once_with()
        connect.return_value.close.assert_called_once_with()
        connect.return_value.send_messages.assert_not_called()
        self.assertIn('authentication succeeded', output.getvalue())

    def test_provider_failure_does_not_echo_sensitive_error_contents(self):
        with patch('apps.accounts.management.commands.check_resend_email.get_connection') as connect:
            connect.return_value.open.side_effect = RuntimeError('test-private-key-and-message')
            with self.assertRaises(CommandError) as raised:
                call_command('check_resend_email', connect=True)
        self.assertNotIn('test-private-key-and-message', str(raised.exception))
        self.assertIn('no email was sent', str(raised.exception))
        connect.return_value.close.assert_called_once_with()
        connect.return_value.send_messages.assert_not_called()

    @override_settings(USING_RESEND_SMTP=False)
    def test_probe_refuses_to_authenticate_against_another_transport(self):
        with patch('apps.accounts.management.commands.check_resend_email.get_connection') as connect:
            with self.assertRaises(CommandError):
                call_command('check_resend_email', connect=True)
        connect.assert_not_called()

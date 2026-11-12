"""Explicit staging capability; synthetic settings/users and zero real mail."""
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
from unittest.mock import patch
from uuid import uuid4

from django.core.cache import cache
from django.test import SimpleTestCase, TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.token_blacklist.models import OutstandingToken

from Core.email_capability import EmailDeliveryUnavailable
from Core.mail_backends import DisabledEmailBackend, EmailDeliveryDisabled
from .account_deletion import request_account_deletion, confirm_account_deletion, _deliver_account_deletion_email
from .email_verification import (issue_email_verification_challenge, challenge_for_unverified_login,
    confirm_email_verification, resend_email_verification, _deliver_verification_email)
from .models import User, EmailVerificationChallenge, PasswordResetChallenge, AccountDeletionChallenge
from .password_reset import (request_password_reset, verify_password_reset_code,
    confirm_password_reset, _deliver_password_reset_email)
from .serializers import RegistrationSerializer


class EmailCapabilitySettingsTests(SimpleTestCase):
    def load(self, **changes):
        environment = {
            'PATH': os.environ.get('PATH', ''), 'DJANGO_DEBUG': 'false',
            'DJANGO_SECRET_KEY': secrets.token_urlsafe(64),
            'DJANGO_JWT_SIGNING_KEY': secrets.token_urlsafe(64),
            'EMAIL_VERIFICATION_PEPPER': secrets.token_urlsafe(64),
            'PASSWORD_RESET_PEPPER': secrets.token_urlsafe(64),
            'ACCOUNT_DELETION_PEPPER': secrets.token_urlsafe(64),
            'DJANGO_ALLOWED_HOSTS': 'api.example.test',
            'DJANGO_DATABASE_URL': 'postgresql://synthetic:unused@localhost/synthetic',
            'DJANGO_CACHE_URL': 'rediss://localhost:6379/0',
        }
        environment.update(changes)
        source = Path(__file__).resolve().parents[2] / 'Core/settings.py'
        return subprocess.run([sys.executable, '-c',
            'import json,runpy,sys; s=runpy.run_path(sys.argv[1]); '
            'print(json.dumps({"debug":s["DEBUG"],"email_enabled":s["EMAIL_DELIVERY_ENABLED"],'
            '"backend":s["EMAIL_BACKEND"],"empty_smtp":not any(s[k] for k in '
            '("EMAIL_HOST","EMAIL_HOST_USER","EMAIL_HOST_PASSWORD")),'
            '"https":s["SECURE_SSL_REDIRECT"],"db_tls":s["DATABASES"]["default"]["OPTIONS"]["sslmode"]}))',
            str(source)], env=environment, capture_output=True, text=True, timeout=10)

    def test_explicit_disabled_production_boot_needs_no_smtp_and_ignores_backend_secrets(self):
        result = self.load(DJANGO_EMAIL_DELIVERY_ENABLED='false',
            DJANGO_EMAIL_BACKEND='untrusted.never_import.Backend', DJANGO_EMAIL_HOST='smtp.invalid',
            DJANGO_EMAIL_HOST_PASSWORD='synthetic-private-settings-marker', RESEND_API_KEY='synthetic-private-settings-marker')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'debug':False,'email_enabled':False,
            'backend':'Core.mail_backends.DisabledEmailBackend','empty_smtp':True,'https':True,'db_tls':'require'})
        self.assertNotIn('synthetic-private',result.stdout+result.stderr)

    def test_default_and_explicit_enabled_production_still_require_real_email(self):
        for changes in [{}, {'DJANGO_EMAIL_DELIVERY_ENABLED':'true'},
                        {'DJANGO_EMAIL_BACKEND':'Core.mail_backends.DisabledEmailBackend'},
                        {'DJANGO_EMAIL_BACKEND':'django.core.mail.backends.dummy.EmailBackend'}]:
            result = self.load(**changes)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('DJANGO_EMAIL_BACKEND',result.stderr)

    def test_email_disable_does_not_relax_other_security_or_accept_flag_typo(self):
        for changes in [{'DJANGO_SECRET_KEY':'short'}, {'DJANGO_DATABASE_URL':''},
                        {'DJANGO_CACHE_URL':''}, {'DJANGO_DB_SSLMODE':'disable'},
                        {'DJANGO_JWT_SIGNING_KEY':'short'}, {'DJANGO_EMAIL_DELIVERY_ENABLED':'fales'}]:
            result = self.load(**{'DJANGO_EMAIL_DELIVERY_ENABLED':'false',**changes})
            self.assertNotEqual(result.returncode,0)

    def test_disabled_backend_never_inspects_messages_or_silently_claims_success(self):
        class PoisonMessages:
            def __iter__(self): raise AssertionError('Do not inspect message contents')
            def __repr__(self): raise AssertionError('Do not log message contents')
        output=StringIO()
        with redirect_stdout(output),redirect_stderr(output):
            for silent in (False,True):
                backend=DisabledEmailBackend(fail_silently=silent)
                with self.assertRaises(EmailDeliveryDisabled): backend.send_messages(PoisonMessages())
                with self.assertRaises(EmailDeliveryDisabled): backend.open()
                backend.close()
        self.assertEqual(output.getvalue(),'')


PASSWORD='Synthetic-parent-Strong-2026!'


@override_settings(EMAIL_DELIVERY_ENABLED=True, EMAIL_BACKEND='django.core.mail.backends.locmem.EmailBackend')
class DisabledEmailAccountTests(TestCase):
    def setUp(self):
        cache.clear(); self.api=APIClient()
        self.pending=User.objects.create_user(email='pending-staging@example.test',password=PASSWORD)
        self.verified=User.objects.create_user(email='verified-staging@example.test',password=PASSWORD,email_verified_at=timezone.now())

    def snapshot(self):
        return (User.objects.count(),EmailVerificationChallenge.objects.count(),PasswordResetChallenge.objects.count(),
            AccountDeletionChallenge.objects.count(),OutstandingToken.objects.count(),
            list(User.objects.order_by('pk').values('id','password','email_verified_at','last_login')))

    @override_settings(EMAIL_DELIVERY_ENABLED=False)
    def test_all_email_dependent_routes_uniform_503_before_parse_or_ghost_writes(self):
        before=self.snapshot(); responses=[]
        for name in ('register','email-verification-confirm','email-verification-resend',
                     'password-reset-request','password-reset-verify','password-reset-confirm',
                     'account-deletion-request','account-deletion-confirm'):
            for email in (self.pending.email,self.verified.email,'unknown-staging@example.test'):
                with self.subTest(route=name,email_case=email), self.assertNumQueries(0):
                    response=self.api.post(reverse('accounts:'+name),{'email':email,'password':PASSWORD,
                        'challenge_id':str(uuid4()),'code':'synthetic-private-code'},format='json')
                self.assertEqual(response.status_code,503); responses.append(response.json())
                self.assertEqual(response.headers['Cache-Control'],'no-store')
                self.assertNotIn('synthetic-private',response.content.decode())
            with self.assertNumQueries(0):
                malformed=self.api.post(reverse('accounts:'+name),data='{',content_type='application/json')
            self.assertEqual(malformed.status_code,503)
            with self.assertNumQueries(0):
                unsupported=self.api.post(reverse('accounts:'+name),data='{',content_type='application/json',
                    HTTP_ACCEPT='application/x-unsupported',HTTP_AUTHORIZATION='Bearer synthetic-private-marker')
            self.assertEqual(unsupported.status_code,503)
            self.assertNotIn('synthetic-private',unsupported.content.decode())
        self.assertTrue(all(data==responses[0] for data in responses))
        self.assertEqual(responses[0]['code'],'email_unavailable');self.assertEqual(self.snapshot(),before)

    @override_settings(EMAIL_DELIVERY_ENABLED=False)
    def test_direct_service_and_registration_hooks_reject_before_any_write(self):
        payload={'email':'new-staging@example.test','password':PASSWORD,'password_confirmation':PASSWORD}
        calls=[lambda:RegistrationSerializer().create(payload),
            lambda:issue_email_verification_challenge(self.pending),lambda:challenge_for_unverified_login(self.pending),
            lambda:confirm_email_verification(uuid4(),'synthetic-private-code'),lambda:resend_email_verification(uuid4()),
            lambda:request_password_reset(self.verified.email),lambda:verify_password_reset_code(uuid4(),'synthetic-private-code'),
            lambda:confirm_password_reset(uuid4(),'synthetic-private-code','New-parent-password-2026!'),
            lambda:request_account_deletion(self.verified.email),lambda:confirm_account_deletion(uuid4(),'synthetic-private-code')]
        before=self.snapshot()
        for operation in calls:
            with self.assertNumQueries(0),self.assertRaises(EmailDeliveryUnavailable):operation()
        self.assertEqual(self.snapshot(),before);self.assertIn('password_confirmation',payload)

    @override_settings(EMAIL_DELIVERY_ENABLED=False)
    def test_unverified_login_cannot_create_challenge_or_mint_tokens(self):
        before=self.snapshot()
        response=self.api.post(reverse('accounts:login'),{'email':self.pending.email,'password':PASSWORD},format='json')
        self.assertEqual(response.status_code,503);self.assertEqual(response.json()['code'],'email_unavailable')
        self.assertNotIn('verification',response.json());self.assertEqual(self.snapshot(),before)

    @override_settings(EMAIL_DELIVERY_ENABLED=False)
    def test_verified_parent_login_and_password_account_delete_remain_available(self):
        response=self.api.post(reverse('accounts:login'),{'email':self.verified.email,'password':PASSWORD},format='json')
        self.assertEqual(response.status_code,200);self.assertIn('access',response.json())
        self.api.force_authenticate(self.verified)
        with patch('apps.accounts.account_deletion.send_mail') as send:
            response=self.api.delete(reverse('accounts:me'),{'password':PASSWORD},format='json')
        self.assertEqual(response.status_code,204);send.assert_not_called()
        self.assertFalse(User.objects.filter(pk=self.verified.pk).exists())
        self.api.force_authenticate(user=None)
        response=self.api.delete(reverse('accounts:unverified-account-delete'),
            {'email':self.pending.email,'password':PASSWORD,'confirmation':'DELETE'},format='json')
        self.assertEqual(response.status_code,204)
        self.assertFalse(User.objects.filter(pk=self.pending.pk).exists())

    def test_preexisting_proofs_unchanged_while_disabled_and_work_after_reenable(self):
        with patch('apps.accounts.email_verification.secrets.randbelow',return_value=123456),self.captureOnCommitCallbacks(execute=True):
            verification=issue_email_verification_challenge(self.pending)
        with patch('apps.accounts.password_reset.secrets.randbelow',return_value=654321),self.captureOnCommitCallbacks(execute=True):
            reset=request_password_reset(self.verified.email)
        before=self.snapshot()
        with override_settings(EMAIL_DELIVERY_ENABLED=False):
            for route,data in [('email-verification-confirm',{'challenge_id':str(verification.pk),'code':'123456'}),
                ('password-reset-verify',{'challenge_id':str(reset),'code':'654321'}),
                ('password-reset-confirm',{'challenge_id':str(reset),'code':'654321','new_password':'Renewed-parent-2026!','new_password_confirmation':'Renewed-parent-2026!'})]:
                self.assertEqual(self.api.post(reverse('accounts:'+route),data,format='json').status_code,503)
        self.assertEqual(self.snapshot(),before)
        verification.refresh_from_db();self.assertIsNone(verification.consumed_at)
        response=self.api.post(reverse('accounts:email-verification-confirm'),{'challenge_id':str(verification.pk),'code':'123456'},format='json')
        self.assertEqual(response.status_code,200)
        response=self.api.post(reverse('accounts:password-reset-verify'),{'challenge_id':str(reset),'code':'654321'},format='json')
        self.assertEqual(response.status_code,204)
        response=self.api.post(reverse('accounts:password-reset-confirm'),{'challenge_id':str(reset),'code':'654321',
            'new_password':'Renewed-parent-2026!','new_password_confirmation':'Renewed-parent-2026!'},format='json')
        self.assertEqual(response.status_code,204)
        self.verified.refresh_from_db();self.assertTrue(self.verified.check_password('Renewed-parent-2026!'))

    @override_settings(EMAIL_DELIVERY_ENABLED=False,DEBUG=True,EMAIL_BACKEND='django.core.mail.backends.console.EmailBackend')
    def test_defensive_delivery_helpers_never_print_send_or_invalidate_when_disabled(self):
        output=StringIO();before=self.snapshot()
        with redirect_stdout(output),redirect_stderr(output):
            for delivery in (_deliver_verification_email,_deliver_password_reset_email,_deliver_account_deletion_email):
                with self.assertNumQueries(0),self.assertRaises(EmailDeliveryUnavailable):
                    delivery(uuid4(),'synthetic-private-email@example.test','synthetic-private-code')
        self.assertEqual(output.getvalue(),'');self.assertEqual(self.snapshot(),before)

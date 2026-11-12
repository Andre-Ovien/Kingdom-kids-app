from io import StringIO
import json
from unittest.mock import Mock, patch

from django.core.cache import cache
from django.core.exceptions import ImproperlyConfigured
from django.core.mail import EmailMultiAlternatives
from django.core.management import call_command, CommandError
from django.test import SimpleTestCase, TestCase, override_settings
from django.urls import reverse
from rest_framework.test import APIClient

from Core.resend_backend import EmailBackend, ResendDeliveryError
from .account_deletion import _deliver_account_deletion_email
from .email_verification import _deliver_verification_email
from .password_reset import _deliver_password_reset_email
from . import test_resend_email as smtp_checks


MAIL = dict(
    EMAIL_DELIVERY_ENABLED=True, USING_RESEND_HTTPS=True, USING_RESEND_SMTP=False,
    EMAIL_BACKEND='Core.resend_backend.EmailBackend',
    DEFAULT_FROM_EMAIL='Kingdom Kids <support@notify.kingdom.test>',
    RESEND_API_KEY='re_synthetic-key-not-a-real-credential',
    RESEND_VERIFIED_DOMAIN='notify.kingdom.test', EMAIL_TIMEOUT=10,
    CONTACT_RECIPIENT_EMAIL='operator@example.test',
)


class ResendHTTPSConfigurationTests(SimpleTestCase):
    def result(self, **overrides):
        return smtp_checks.ResendSMTPConfigurationTests.settings_result(self, **{
            'DJANGO_EMAIL_BACKEND': 'Core.resend_backend.EmailBackend',
            'RESEND_VERIFIED_DOMAIN': 'notify.kingdom.test',
            **overrides,
        })

    def test_production_https_configuration_requires_matching_verified_sender_and_key(self):
        result = self.result(DJANGO_DEBUG='false')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)['password_set'])
        for options in ({'RESEND_API_KEY': ''}, {'RESEND_VERIFIED_DOMAIN': ''},
                        {'RESEND_VERIFIED_DOMAIN': 'other.example'},
                        {'DJANGO_DEFAULT_FROM_EMAIL': 'onboarding@resend.dev'},
                        {'RESEND_API_KEY': 'private key with spaces'}):
            with self.subTest(options=tuple(options)):
                result = self.result(DJANGO_DEBUG='false', **options)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Resend HTTPS', result.stderr)
                self.assertNotIn('private key with spaces', result.stderr)


@override_settings(**MAIL)
class ResendHTTPSBackendTests(SimpleTestCase):
    def connection(self, **overrides):
        response = Mock(status=200)
        response.read.return_value = b'{"id":"synthetic-message-id"}'
        response.configure_mock(**overrides)
        connection = Mock()
        connection.getresponse.return_value = response
        return connection

    def message(self):
        message = EmailMultiAlternatives('Subject', 'Plain text', to=['parent@example.test'],
                                        reply_to=['reply@example.test'])
        message.attach_alternative('<p>HTML</p>', 'text/html')
        return message

    def test_fixed_https_origin_text_html_reply_and_retry_key_no_smtp(self):
        connection = self.connection()
        with patch('Core.resend_backend.http.client.HTTPSConnection', return_value=connection) as factory:
            message = self.message()
            backend = EmailBackend()
            self.assertEqual(backend.send_messages([message]), 1)
            self.assertEqual(backend.send_messages([message]), 1)
        self.assertEqual(factory.call_args.args, ('api.resend.com',))
        self.assertEqual(factory.call_args.kwargs['port'], 443)
        args, options = connection.request.call_args
        self.assertEqual(args, ('POST', '/emails'))
        body = json.loads(options['body'])
        self.assertEqual(body['text'], 'Plain text')
        self.assertEqual(body['html'], '<p>HTML</p>')
        self.assertEqual(body['reply_to'], ['reply@example.test'])
        self.assertEqual(connection.request.call_args_list[0].kwargs['headers']['Idempotency-Key'],
                         options['headers']['Idempotency-Key'])
        self.assertEqual(connection.close.call_count, 2)
        connection.set_debuglevel.assert_called_with(0)

    def test_provider_failures_are_bounded_redacted_and_never_retried(self):
        for response in (Mock(status=401, read=Mock(return_value=b'private-provider-response')),
                         Mock(status=302, read=Mock(return_value=b'{}')),
                         Mock(status=200, read=Mock(return_value=b'x' * 65537)),
                         Mock(status=200, read=Mock(return_value=b'{"unexpected":true}'))):
            with self.subTest(response=response.status):
                connection = Mock()
                connection.getresponse.return_value = response
                with patch('Core.resend_backend.http.client.HTTPSConnection', return_value=connection):
                    with self.assertRaises(ResendDeliveryError) as caught:
                        EmailBackend().send_messages([self.message()])
                self.assertNotIn('private-provider-response', str(caught.exception))
                self.assertEqual(connection.request.call_count, 1)
                connection.close.assert_called_once()
                response.read.assert_called_once_with(65537)

    def test_network_exception_is_sanitized_and_fail_silently_returns_zero(self):
        connection = Mock()
        connection.request.side_effect = TimeoutError('synthetic-secret-provider-data')
        with patch('Core.resend_backend.http.client.HTTPSConnection', return_value=connection):
            with self.assertRaises(ResendDeliveryError) as caught:
                EmailBackend().send_messages([self.message()])
            self.assertNotIn('synthetic-secret', str(caught.exception))
            self.assertEqual(EmailBackend(fail_silently=True).send_messages([self.message()]), 0)
        self.assertEqual(connection.request.call_count, 2)  # one per explicit call, no retry

    def test_missing_or_wrong_configuration_and_sender_fail_without_network(self):
        for options in ({'RESEND_API_KEY': ''}, {'RESEND_VERIFIED_DOMAIN': 'other.example'},
                        {'DEFAULT_FROM_EMAIL': 'onboarding@resend.dev'}, {'EMAIL_TIMEOUT': 31}):
            with self.subTest(options=options), override_settings(**options):
                with self.assertRaises(ImproperlyConfigured):
                    EmailBackend()
        with patch('Core.resend_backend.http.client.HTTPSConnection') as connect:
            message = self.message()
            message.from_email = 'attacker@example.test'
            with self.assertRaises(ResendDeliveryError):
                EmailBackend().send_messages([message])
            connect.assert_not_called()

    def test_check_command_is_local_and_cannot_claim_authentication(self):
        output = StringIO()
        with patch('Core.resend_backend.http.client.HTTPSConnection') as connect:
            call_command('check_resend_email', stdout=output)
            with self.assertRaises(CommandError):
                call_command('check_resend_email', connect=True, stdout=output)
            connect.assert_not_called()
        self.assertIn('No network connection or email was sent', output.getvalue())

    def test_existing_auth_email_composition_works_over_https(self):
        from uuid import uuid4
        connection = self.connection()
        with patch('Core.resend_backend.http.client.HTTPSConnection', return_value=connection):
            for deliver in (_deliver_verification_email, _deliver_password_reset_email, _deliver_account_deletion_email):
                deliver(uuid4(), 'parent@example.test', '123456')
        self.assertEqual(connection.request.call_count, 3)
        for call in connection.request.call_args_list:
            body = json.loads(call.kwargs['body'])
            self.assertIn('123456', body['text'])
            self.assertEqual(body['to'], ['parent@example.test'])

    @override_settings(DEBUG=False)
    def test_exception_reporter_hides_provider_message_and_key_in_backend_frames(self):
        from django.views.debug import SafeExceptionReporterFilter
        import sys
        connection = Mock()
        connection.request.side_effect = TimeoutError('synthetic-private-transport-marker')
        with patch('Core.resend_backend.http.client.HTTPSConnection', return_value=connection):
            try:
                EmailBackend().send_messages([self.message()])
            except ResendDeliveryError:
                reporter = SafeExceptionReporterFilter()
                traceback = sys.exc_info()[2]
                checked = 0
                while traceback:
                    if traceback.tb_frame.f_code.co_filename.endswith('Core/resend_backend.py'):
                        variables = repr(list(reporter.get_traceback_frame_variables(None, traceback.tb_frame)))
                        self.assertNotIn(MAIL['RESEND_API_KEY'], variables)
                        self.assertNotIn('parent@example.test', variables)
                        checked += 1
                    traceback = traceback.tb_next
                self.assertGreater(checked, 0)
            else:
                self.fail('Expected synthetic transport failure.')


@override_settings(**{**MAIL, 'EMAIL_BACKEND': 'django.core.mail.backends.locmem.EmailBackend'})
class ContactAPITests(TestCase):
    def setUp(self):
        cache.clear()
        self.client = APIClient()
        self.payload = {'title': 'A question', 'email': 'parent@example.test',
                        'message': '<script>alert("x")</script>\nPlease help.'}

    def post(self, **overrides):
        return self.client.post(reverse('accounts:contact'), {**self.payload, **overrides}, format='json')

    def test_delivery_is_operator_only_escaped_and_repeat_has_same_operation(self):
        from django.core import mail
        first = self.post()
        second = self.post()
        self.assertEqual(first.status_code, 202)
        self.assertEqual(second.status_code, 202)
        message = mail.outbox[-1]
        self.assertEqual(message.to, ['operator@example.test'])
        self.assertEqual(message.reply_to, [self.payload['email']])
        self.assertNotIn('<script>', message.alternatives[0].content)
        self.assertIn('&lt;script&gt;', message.alternatives[0].content)
        self.assertEqual(mail.outbox[-1].extra_headers, mail.outbox[-2].extra_headers)
        self.assertEqual(first['Cache-Control'], 'no-store')

    def test_optional_request_id_is_stable_for_retry_and_changes_for_new_submission(self):
        from django.core import mail
        from uuid import uuid4
        request_id = str(uuid4())
        self.assertEqual(self.post(request_id=request_id).status_code, 202)
        self.assertEqual(self.post(request_id=request_id).status_code, 202)
        self.assertEqual(mail.outbox[-1].extra_headers, mail.outbox[-2].extra_headers)
        self.assertEqual(self.post(request_id=str(uuid4())).status_code, 202)
        self.assertNotEqual(mail.outbox[-1].extra_headers, mail.outbox[-2].extra_headers)

    def test_honeypot_never_sends_and_cannot_override_recipient(self):
        with patch('apps.accounts.contact.EmailMultiAlternatives') as message:
            self.assertEqual(self.post(website='spam.example', to='attacker@example.test').status_code, 202)
            message.assert_not_called()

    def test_invalid_and_oversized_inputs_cannot_send(self):
        for changes in ({'email': 'not-email'}, {'title': 'A\r\nBcc: attacker@example.test'},
                        {'message': 'x' * 5001}, {'title': 'x' * 121}, {'message': 'short'}):
            with self.subTest(changes=tuple(changes)), patch('apps.accounts.contact.EmailMultiAlternatives') as message:
                self.assertEqual(self.post(**changes).status_code, 400)
                message.assert_not_called()
            cache.clear()

    def test_disabled_unconfigured_and_provider_failure_never_claim_success(self):
        with override_settings(EMAIL_DELIVERY_ENABLED=False):
            self.assertEqual(self.post().status_code, 503)
        with override_settings(CONTACT_RECIPIENT_EMAIL=''):
            self.assertEqual(self.post().status_code, 503)
        with patch('apps.accounts.contact.EmailMultiAlternatives.send', side_effect=RuntimeError('private')):
            response = self.post()
        self.assertEqual(response.status_code, 503)
        self.assertNotIn('private', str(response.data))

    def test_public_contact_scope_is_rate_limited(self):
        for _ in range(5):
            self.assertEqual(self.post(website='bot.example').status_code, 202)
        self.assertEqual(self.post().status_code, 429)

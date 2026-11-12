from datetime import timedelta
from threading import Event, Thread
from unittest.mock import Mock, patch

from django.core.cache import cache
from django.db import close_old_connections, connection
from django.test import TestCase, TransactionTestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from .models import WaitlistSubscriber
from .waitlist_email import ensure_waitlist_confirmation


@override_settings(EMAIL_DELIVERY_ENABLED=True, EMAIL_BACKEND='django.core.mail.backends.locmem.EmailBackend')
class WaitlistConfirmationTests(TestCase):
    def setUp(self):
        cache.clear()
        self.client = APIClient()
        self.url = reverse('accounts:waitlist')
        self.email = 'synthetic-waitlist-confirmation@example.test'

    def post(self):
        return self.client.post(self.url, {'email': self.email}, format='json')

    def test_explicit_signup_sends_fixed_text_html_once_and_preserves_consent_on_duplicates(self):
        from django.core import mail
        self.assertEqual(self.post().status_code, 202)
        row = WaitlistSubscriber.objects.get()
        consent = row.consented_at
        self.assertIsNotNone(row.confirmation_sent_at)
        self.assertIsNone(row.confirmation_claim_id)
        message = mail.outbox[0]
        self.assertEqual(message.to, [self.email])
        self.assertIn("You're on the Kingdom Kids waitlist", message.body)
        self.assertIn('launch updates', message.body)
        self.assertIn('launch updates', message.alternatives[0].content)
        self.assertEqual(message.extra_headers['Resend-Idempotency-Key'], f'waitlist-confirmation-v1/{row.pk}')
        self.assertEqual(self.post().status_code, 202)
        with override_settings(EMAIL_DELIVERY_ENABLED=False):
            self.assertEqual(self.post().status_code, 202)
        row.refresh_from_db()
        self.assertEqual(row.consented_at, consent)
        self.assertEqual(len(mail.outbox), 1)

    def test_failure_keeps_signup_and_manual_retry_reuses_the_same_operation(self):
        with patch('apps.accounts.waitlist_email.EmailMultiAlternatives.send', side_effect=[TimeoutError('private'), 1]) as send:
            first = self.post()
            self.assertEqual(first.status_code, 503)
            self.assertEqual(first.data['code'], 'waitlist_confirmation_delayed')
            self.assertEqual(first['Cache-Control'], 'no-store')
            row = WaitlistSubscriber.objects.get()
            consent = row.consented_at
            operation_started = row.confirmation_first_attempt_at
            self.assertIsNone(row.confirmation_sent_at)
            self.assertIsNone(row.confirmation_claim_id)
            self.assertNotIn(self.email, str(first.data))
            self.assertEqual(self.post().status_code, 202)
        self.assertEqual(send.call_count, 2)
        row.refresh_from_db()
        self.assertEqual(row.consented_at, consent)
        self.assertEqual(row.confirmation_first_attempt_at, operation_started)
        self.assertIsNotNone(row.confirmation_sent_at)
        self.assertEqual(WaitlistSubscriber.objects.count(), 1)

    @override_settings(
        EMAIL_BACKEND='Core.resend_backend.EmailBackend',
        DEFAULT_FROM_EMAIL='Kingdom Kids <no-reply@notify.kingdom.test>',
        RESEND_API_KEY='re_synthetic-not-a-real-provider-key',
        RESEND_VERIFIED_DOMAIN='notify.kingdom.test', EMAIL_TIMEOUT=10,
    )
    def test_uncertain_https_result_reuses_exact_provider_body_and_key_then_stops(self):
        connection = Mock()
        response = Mock(status=200)
        response.read.return_value = b'{"id":"synthetic-provider-ack"}'
        connection.getresponse.side_effect = [TimeoutError('synthetic-lost-ack'), response]
        with patch('Core.resend_backend.http.client.HTTPSConnection', return_value=connection):
            self.assertEqual(self.post().status_code, 503)
            self.assertEqual(self.post().status_code, 202)
            self.assertEqual(self.post().status_code, 202)
        self.assertEqual(connection.request.call_count, 2)
        first, second = connection.request.call_args_list
        self.assertEqual(first.kwargs['body'], second.kwargs['body'])
        self.assertEqual(first.kwargs['headers']['Idempotency-Key'], second.kwargs['headers']['Idempotency-Key'])
        self.assertEqual(WaitlistSubscriber.objects.count(), 1)

    def test_active_lease_and_old_unknown_outcome_do_not_send(self):
        from uuid import uuid4
        row = WaitlistSubscriber.objects.create(email=self.email)
        for values in (
            {'confirmation_claim_id': uuid4(), 'confirmation_lease_until': timezone.now() + timedelta(minutes=1)},
            {'confirmation_claim_id': None, 'confirmation_lease_until': None,
             'confirmation_first_attempt_at': timezone.now() - timedelta(hours=24)},
        ):
            WaitlistSubscriber.objects.filter(pk=row.pk).update(**values)
            with patch('apps.accounts.waitlist_email.EmailMultiAlternatives.send') as send:
                response = self.post()
                self.assertEqual(response.status_code, 503)
                self.assertEqual(response.data['code'], 'waitlist_confirmation_delayed')
                send.assert_not_called()

    def test_expired_worker_lease_recovers_with_same_key(self):
        from uuid import uuid4
        row = WaitlistSubscriber.objects.create(
            email=self.email, confirmation_claim_id=uuid4(),
            confirmation_lease_until=timezone.now() - timedelta(seconds=1),
            confirmation_first_attempt_at=timezone.now() - timedelta(minutes=3),
        )
        self.assertEqual(self.post().status_code, 202)
        from django.core import mail
        self.assertEqual(mail.outbox[-1].extra_headers['Resend-Idempotency-Key'], f'waitlist-confirmation-v1/{row.pk}')

    def test_no_bulk_mail_and_disabled_or_bad_configuration_is_recoverable(self):
        old = WaitlistSubscriber.objects.create(email='older-synthetic-subscriber@example.test')
        with override_settings(EMAIL_DELIVERY_ENABLED=False):
            self.assertEqual(self.post().status_code, 503)
        row = WaitlistSubscriber.objects.get(email=self.email)
        self.assertIsNone(row.confirmation_first_attempt_at)
        with patch('apps.accounts.waitlist_email.get_connection', side_effect=RuntimeError('private')):
            self.assertEqual(self.post().status_code, 503)
        row.refresh_from_db()
        self.assertIsNone(row.confirmation_first_attempt_at)
        self.assertEqual(self.post().status_code, 202)
        old.refresh_from_db()
        self.assertIsNone(old.confirmation_sent_at)
        self.assertIsNone(old.confirmation_first_attempt_at)


@override_settings(EMAIL_DELIVERY_ENABLED=True, EMAIL_BACKEND='django.core.mail.backends.locmem.EmailBackend')
class WaitlistParallelConfirmationTests(TransactionTestCase):
    def test_parallel_retry_uses_lease_and_mail_is_outside_atomic(self):
        cache.clear()
        row = WaitlistSubscriber.objects.create(email='parallel-synthetic-waitlist@example.test')
        entered, release = Event(), Event()
        results, atomic_states, errors = [], [], []

        def send(*args, **kwargs):
            atomic_states.append(connection.in_atomic_block)
            entered.set()
            if not release.wait(5):
                raise TimeoutError('Synthetic test synchronization timeout')
            return 1

        def worker():
            close_old_connections()
            try:
                results.append(ensure_waitlist_confirmation(row.pk))
            except Exception as error:
                errors.append(type(error).__name__)
            finally:
                close_old_connections()

        with patch('apps.accounts.waitlist_email.EmailMultiAlternatives.send', side_effect=send) as deliver:
            thread = Thread(target=worker)
            thread.start()
            try:
                self.assertTrue(entered.wait(5))
                self.assertFalse(ensure_waitlist_confirmation(row.pk))
                self.assertEqual(deliver.call_count, 1)
            finally:
                release.set()
                thread.join(6)
        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(results, [True])
        self.assertEqual(atomic_states, [False])
        row.refresh_from_db()
        self.assertIsNotNone(row.confirmation_sent_at)

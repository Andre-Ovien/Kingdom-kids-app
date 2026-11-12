import base64
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
import hashlib
import hmac
import json
from threading import Barrier
from uuid import uuid4
from unittest.mock import Mock, patch

from django.db import DatabaseError, close_old_connections, connections
from django.db.models.query import QuerySet
from django.test import SimpleTestCase, TestCase, TransactionTestCase, override_settings, skipUnlessDBFeature
from django.utils import timezone
from django.views.debug import SafeExceptionReporterFilter
from rest_framework.test import APIClient, APIRequestFactory

from apps.accounts.models import User
from .client import SANDBOX_ORIGIN, SquareClientError, SquareHttpResult, SquareSandboxClient
from .configuration import SquareConfigurationError, SquareDisabled, square_configuration
from .models import (SquareCustomerIdentity, SquareSandboxOperation,
                     SquareSubscriptionIdentity, SquareWebhookReceipt)
from .operations import (SquareOperationConflict, SquareOwnershipError,
                         bind_customer_identity, bind_subscription_identity, reserve_customer_operation)
from .views import SquareSandboxWebhookView
from .webhooks import record_notification, valid_signature


CONFIG = dict(SQUARE_SANDBOX_ENABLED=True, SQUARE_ENVIRONMENT='sandbox',
    SQUARE_API_VERSION='2026-09-16', SQUARE_SANDBOX_ACCESS_TOKEN='not-a-real-access-token',
    SQUARE_SANDBOX_MERCHANT_ID='merchant-test', SQUARE_SANDBOX_WEBHOOK_SIGNATURE_KEY='test-signature-key',
    SQUARE_SANDBOX_WEBHOOK_NOTIFICATION_URL='https://hooks.example.test/api/billing/square/webhook/',
    SQUARE_HTTP_TIMEOUT_SECONDS=5, SQUARE_WEBHOOK_MAX_BODY_BYTES=262144)
PATH = '/api/billing/square/webhook/'


def event_bytes(event_id='event-test', **fields):
    return json.dumps({'event_id': event_id, 'merchant_id': 'merchant-test',
                       'type': 'subscription.created', 'data': {'id': 'subscription-test'}, **fields}).encode()


def signature(raw, config=None):
    config = config or square_configuration(webhook=True)
    return base64.b64encode(hmac.new(config.signature_key.encode(),
        config.notification_url.encode() + raw, hashlib.sha256).digest()).decode()


@override_settings(**CONFIG)
class SandboxClientTests(SimpleTestCase):
    def test_disabled_missing_credentials_and_production_environment_never_dispatch(self):
        transport = Mock()
        client = SquareSandboxClient(transport)
        for settings, exception in [({'SQUARE_SANDBOX_ENABLED': False}, SquareDisabled),
                ({'SQUARE_SANDBOX_ACCESS_TOKEN': ''}, SquareConfigurationError),
                ({'SQUARE_SANDBOX_MERCHANT_ID': ''}, SquareConfigurationError),
                ({'SQUARE_ENVIRONMENT': 'production'}, SquareConfigurationError),
                ({'SQUARE_API_VERSION': 'latest'}, SquareConfigurationError),
                ({'SQUARE_SANDBOX_ACCESS_TOKEN': 'token\ninjection'}, SquareConfigurationError)]:
            with self.subTest(settings=list(settings)), override_settings(**settings):
                with self.assertRaises(exception):
                    client.create_customer(email_address='synthetic@example.test', reference_id='parent-test',
                                           idempotency_key=uuid4())
        transport.send.assert_not_called()
        with self.assertRaises(SquareClientError):
            SquareSandboxClient().create_customer(email_address='synthetic@example.test',
                reference_id='parent-test', idempotency_key=uuid4())

    def test_mocked_customer_request_uses_only_sandbox_version_and_stable_key(self):
        transport = Mock()
        transport.send.return_value = SquareHttpResult(200, b'{"customer":{"id":"customer-test"}}')
        key = uuid4()
        self.assertEqual(SquareSandboxClient(transport).create_customer(
            email_address='synthetic@example.test', reference_id='parent-test', idempotency_key=key), 'customer-test')
        sent = transport.send.call_args.kwargs
        self.assertEqual(sent['url'], SANDBOX_ORIGIN + '/v2/customers')
        self.assertEqual(sent['headers']['Square-Version'], '2026-09-16')
        self.assertEqual(json.loads(sent['body'])['idempotency_key'], str(key))
        self.assertEqual((sent['timeout_seconds'], sent['max_response_bytes']), (5, 1048576))
        self.assertNotIn(CONFIG['SQUARE_SANDBOX_ACCESS_TOKEN'], repr(square_configuration()))
        self.assertNotIn(CONFIG['SQUARE_SANDBOX_WEBHOOK_SIGNATURE_KEY'], repr(square_configuration()))

    def test_uncertain_response_is_sanitized_and_never_automatically_retried(self):
        for result in [TimeoutError('private provider details'), SquareHttpResult(302, b''),
                       SquareHttpResult(200, b'x' * 1048577), SquareHttpResult(200, b'not-json'),
                       SquareHttpResult(200, b'{"customer":{"id":null}}')]:
            transport = Mock()
            if isinstance(result, Exception): transport.send.side_effect = result
            else: transport.send.return_value = result
            with self.subTest(result_type=type(result).__name__), self.assertRaises(SquareClientError) as error:
                SquareSandboxClient(transport).create_customer(email_address='synthetic@example.test',
                    reference_id='parent-test', idempotency_key=uuid4())
            self.assertNotIn('private', str(error.exception))
            self.assertEqual(transport.send.call_count, 1)

    def test_official_public_webhook_signature_vector_and_exact_raw_body_url(self):
        # Public example in Square's step3validate documentation, not credentials.
        config = replace(square_configuration(webhook=True), signature_key='asdf1234',
                         notification_url='https://example.com/webhook')
        raw = b'{"hello":"world"}'
        official = '2kRE5qRU2tR+tBGlDwMEw2avJ7QM4ikPYD/PJ3bd9Og='
        self.assertTrue(valid_signature(raw_body=raw, signature=official, configuration=config))
        self.assertFalse(valid_signature(raw_body=raw + b' ', signature=official, configuration=config))
        self.assertFalse(valid_signature(raw_body=raw, signature=official,
            configuration=replace(config, notification_url=config.notification_url + '/')))
        self.assertFalse(valid_signature(raw_body=raw, signature='é' * 44, configuration=config))


@override_settings(**CONFIG)
class SandboxIdentityTests(TestCase):
    def setUp(self):
        self.parent = User.objects.create_user(email='square-parent@example.test', password='Synthetic-test-123!',
                                               email_verified_at=timezone.now())
        self.other = User.objects.create_user(email='square-other@example.test', password='Synthetic-test-123!',
                                              email_verified_at=timezone.now())

    def test_parent_operation_replay_is_stable_conflicts_reject_and_cross_parent_keys_differ(self):
        key = uuid4()
        first = reserve_customer_operation(parent=self.parent, operation_id=key, email_address='synthetic@example.test')
        replay = reserve_customer_operation(parent=self.parent, operation_id=key, email_address='synthetic@example.test')
        other = reserve_customer_operation(parent=self.other, operation_id=key, email_address='synthetic@example.test')
        self.assertEqual((first.pk, first.provider_idempotency_key), (replay.pk, replay.provider_idempotency_key))
        self.assertNotEqual(first.provider_idempotency_key, other.provider_idempotency_key)
        with self.assertRaises(SquareOperationConflict):
            reserve_customer_operation(parent=self.parent, operation_id=key, email_address='different@example.test')
        self.assertEqual(SquareSandboxOperation.objects.count(), 2)
        self.assertNotIn('email', [field.name for field in SquareSandboxOperation._meta.fields])

    def test_customer_and_subscription_bindings_cannot_cross_parents_or_rebind_existing_ids(self):
        customer = bind_customer_identity(parent=self.parent, customer_id='customer-a')
        self.assertEqual(bind_customer_identity(parent=self.parent, customer_id='customer-a').pk, customer.pk)
        for parent, external_id in [(self.other, 'customer-a'), (self.parent, 'different-id')]:
            with self.assertRaises(SquareOwnershipError):
                bind_customer_identity(parent=parent, customer_id=external_id)
        other = bind_customer_identity(parent=self.other, customer_id='customer-b')
        subscription = bind_subscription_identity(parent=self.parent, customer_identity_id=customer.pk,
                                                   subscription_id='subscription-a')
        with self.assertRaises(SquareOwnershipError):
            bind_subscription_identity(parent=self.other, customer_identity_id=customer.pk, subscription_id='new')
        with self.assertRaises(SquareOwnershipError):
            bind_subscription_identity(parent=self.other, customer_identity_id=other.pk, subscription_id='subscription-a')
        self.assertEqual(subscription.provider_status, '')
        self.assertEqual(SquareSubscriptionIdentity.objects.count(), 1)

    def test_disabled_functions_do_not_write_and_existing_content_access_is_unchanged(self):
        client = APIClient(); client.force_authenticate(self.parent)
        with override_settings(SQUARE_SANDBOX_ENABLED=False):
            with self.assertRaises(SquareDisabled):
                bind_customer_identity(parent=self.parent, customer_id='never-bound')
            self.assertEqual(client.get('/api/stories/').status_code, 200)
        self.assertEqual(SquareCustomerIdentity.objects.count(), 0)


@override_settings(**CONFIG)
class SandboxWebhookTests(TestCase):
    def post(self, raw, signed=True, **headers):
        return self.client.post(PATH, data=raw, content_type='application/json',
            HTTP_X_SQUARE_HMACSHA256_SIGNATURE=signature(raw) if signed else 'invalid', **headers)

    def test_disabled_receiver_never_touches_inbox_and_missing_config_fails_closed(self):
        with override_settings(SQUARE_SANDBOX_ENABLED=False), self.assertNumQueries(0):
            response = self.post(b'not-json', signed=False)
        self.assertEqual(response.status_code, 404)
        for settings in [{'SQUARE_SANDBOX_WEBHOOK_SIGNATURE_KEY': ''},
                         {'SQUARE_SANDBOX_WEBHOOK_NOTIFICATION_URL': ''}]:
            with override_settings(**settings), self.assertNumQueries(0):
                self.assertEqual(self.post(b'not-json', signed=False).status_code, 503)
        # A server explicitly selecting the default-OFF production receiver
        # cannot fall back to enabled Sandbox webhook credentials.
        with override_settings(SQUARE_ENVIRONMENT='production'), self.assertNumQueries(0):
            self.assertEqual(self.post(b'not-json', signed=False).status_code, 404)
        self.assertEqual(SquareWebhookReceipt.objects.count(), 0)

    def test_signature_is_checked_before_parse_and_request_host_is_not_used(self):
        raw = event_bytes()
        with patch('apps.billing.webhooks.strict_json', side_effect=AssertionError('must not parse')):
            self.assertEqual(self.post(raw, signed=False).status_code, 403)
        self.assertEqual(self.post(raw, HTTP_HOST='different-internal-host.test').status_code, 200)
        self.assertEqual(SquareWebhookReceipt.objects.count(), 1)

    def test_duplicate_receipt_is_durable_but_different_body_same_id_is_conflict(self):
        raw = event_bytes()
        self.assertFalse(self.post(raw).json()['duplicate'])
        self.assertTrue(self.post(raw).json()['duplicate'])
        self.assertEqual(self.post(event_bytes(data={'id': 'changed'})).status_code, 409)
        row = SquareWebhookReceipt.objects.get()
        self.assertEqual(row.body_sha256, hashlib.sha256(raw).hexdigest())
        self.assertEqual(SquareCustomerIdentity.objects.count(), 0)
        self.assertEqual(SquareSubscriptionIdentity.objects.count(), 0)

    def test_wrong_merchant_and_pathological_signed_envelopes_never_persist(self):
        malformed = [event_bytes(merchant_id='foreign'), b'\xff', b'{"event_id":"a","event_id":"b"}',
                     b'{"number":NaN}', event_bytes(number=1e308).replace(b'1e+308', b'1e9999'),
                     b'[' * 1100 + b']' * 1100, b'[]', event_bytes(event_id=[]),
                     event_bytes(event_id='\ud800'), event_bytes(data={'id': '\ud800'})]
        for raw in malformed:
            with self.subTest(raw_length=len(raw)):
                self.assertEqual(self.post(raw).status_code, 400)
        self.assertEqual(SquareWebhookReceipt.objects.count(), 0)

    def test_read_is_bounded_with_no_content_length_and_oversized_body_rejects(self):
        limit = 1024
        request = APIRequestFactory().post(PATH, data=b'', content_type='application/json')
        request.META.pop('CONTENT_LENGTH', None)
        request.read = Mock(return_value=b'x' * (limit + 1))
        with override_settings(SQUARE_WEBHOOK_MAX_BODY_BYTES=limit):
            response = SquareSandboxWebhookView.as_view()(request)
        self.assertEqual(response.status_code, 413)
        request.read.assert_called_once_with(limit + 1)
        self.assertEqual(self.post(event_bytes(), HTTP_CONTENT_ENCODING='gzip').status_code, 415)
        self.assertEqual(SquareWebhookReceipt.objects.count(), 0)

    @override_settings(DEBUG=False)
    def test_database_failure_exception_report_redacts_signed_body_and_private_metadata(self):
        marker = 'synthetic-private-event-marker'
        raw = event_bytes(private_metadata=marker)
        request = APIRequestFactory().post(PATH, data=raw, content_type='application/json',
            HTTP_X_SQUARE_HMACSHA256_SIGNATURE=signature(raw))
        with patch.object(SquareWebhookReceipt.objects, 'get_or_create', side_effect=DatabaseError('Synthetic DB outage')):
            try:
                SquareSandboxWebhookView.as_view()(request)
            except DatabaseError as error:
                trace = error.__traceback__
                reporter = SafeExceptionReporterFilter()
                inspected = []
                while trace is not None:
                    frame = trace.tb_frame
                    if frame.f_code.co_name in {'post', 'record_notification'}:
                        inspected.append(frame.f_code.co_name)
                        visible = repr(reporter.get_traceback_frame_variables(None, frame))
                        self.assertNotIn(marker, visible)
                        self.assertNotIn('private_metadata', visible)
                    trace = trace.tb_next
                self.assertIn('post', inspected)
                self.assertIn('record_notification', inspected)
            else:
                self.fail('Expected synthetic database failure')


@override_settings(**CONFIG)
@skipUnlessDBFeature('has_select_for_update')
class SquarePostgreSQLRaceTests(TransactionTestCase):
    def setUp(self):
        self.parent = User.objects.create_user(email='square-race@example.test', password='Synthetic-test-123!',
                                               email_verified_at=timezone.now())
        self.other = User.objects.create_user(email='square-race-other@example.test', password='Synthetic-test-123!',
                                              email_verified_at=timezone.now())

    def race_create(self, model, calls):
        ready = Barrier(2)
        original = QuerySet.create

        def synchronized_create(queryset, **kwargs):
            if queryset.model is model:
                ready.wait(timeout=8)  # Both missed the original get before either inserts.
            return original(queryset, **kwargs)

        def worker(call):
            close_old_connections()
            try: return call()
            finally: connections.close_all()

        with patch.object(QuerySet, 'create', synchronized_create), ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(worker, call) for call in calls]
            return [future.result(timeout=12) for future in futures]

    def test_duplicate_event_race_records_exactly_one_receipt(self):
        raw = event_bytes(); config = square_configuration(webhook=True)
        results = self.race_create(SquareWebhookReceipt, [
            lambda: record_notification(raw_body=raw, configuration=config),
            lambda: record_notification(raw_body=raw, configuration=config)])
        self.assertEqual(sorted(results), [False, True])
        self.assertEqual(SquareWebhookReceipt.objects.count(), 1)

    def test_operation_race_reuses_one_provider_key(self):
        key = uuid4()
        def reserve():
            row = reserve_customer_operation(parent=self.parent, operation_id=key,
                                             email_address='synthetic@example.test')
            return row.provider_idempotency_key
        results = self.race_create(SquareSandboxOperation, [reserve, reserve])
        self.assertEqual(results[0], results[1])
        self.assertEqual(SquareSandboxOperation.objects.count(), 1)

    def test_cross_parent_customer_identity_race_has_one_owner(self):
        def bind(parent):
            try: return bind_customer_identity(parent=parent, customer_id='shared-provider-id').parent_id
            except SquareOwnershipError: return None
        results = self.race_create(SquareCustomerIdentity, [lambda: bind(self.parent), lambda: bind(self.other)])
        self.assertEqual(sum(result is not None for result in results), 1)
        self.assertEqual(SquareCustomerIdentity.objects.count(), 1)

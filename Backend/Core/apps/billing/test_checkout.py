"""Synthetic/mocked checkout tests. No Square Internet requests or live DB."""
from copy import deepcopy
from datetime import timedelta
from unittest.mock import Mock, patch
from uuid import uuid4

from django.core.cache import cache
from django.test import TestCase, SimpleTestCase, override_settings
from django.utils import timezone
from django.db import DatabaseError
from django.views.debug import SafeExceptionReporterFilter
from rest_framework.test import APIClient, APIRequestFactory, force_authenticate

from apps.accounts.models import User
from .checkout import (CheckoutConflict, CheckoutRejected, DISCLOSURE_VERSION, confirm_direct_checkout,
                       public_terms, reserve_checkout, validate_variation, fingerprint, dispatch_hosted_checkout)
from .plans import POLICY_SHA256
from .client import SquareClientError, SquareHttpResult, SquareSandboxClient, SANDBOX_ORIGIN
from .configuration import SquareConfigurationError
from .models import ParentContentEntitlement, SquareCheckoutIntent
from .views import SquareCheckoutConfirmView
from .tests import CONFIG


CHECKOUT_CONFIG = {**CONFIG, 'SQUARE_SANDBOX_CHECKOUT_ENABLED': True,
    # Explicitly enrolled synthetic IDs in the isolated test database only.
    'SQUARE_SANDBOX_TEST_PARENT_IDS': ','.join(str(value) for value in range(1, 101)),
    'SQUARE_SANDBOX_CANCELLATION_ENABLED': True,
    'SQUARE_SANDBOX_TERM_BILLING_ENABLED': True, 'SQUARE_SANDBOX_TERM_RECONCILIATION_ENABLED': True,
    'SQUARE_SANDBOX_RECONCILIATION_ENABLED': True, 'SQUARE_SANDBOX_LOCATION_ID': 'location-test',
    'SQUARE_SANDBOX_PLAN_VARIATION_ID': 'variation-test', 'SQUARE_SANDBOX_TRANSPORT_FACTORY': None}
PASSWORD = 'Synthetic-parent-test-123!'
BASE = '/api/billing/square/checkout-intents/'
STAMP = '2026-11-11T08:00:00Z'


class FixtureSquare:
    """Canonical fixtures only, deliberately not a provider canary."""
    def __init__(self):
        self.calls, self.customer, self.card, self.subscription = [], None, None, None
        self.timeout_subscription = False
        self.variation = {'id': 'variation-test', 'type': 'SUBSCRIPTION_PLAN_VARIATION',
            'present_at_location_ids': ['location-test'], 'subscription_plan_variation_data': {
                'subscription_plan_id': 'plan-test', 'monthly_billing_anchor_date': 28, 'can_prorate': False,
                'phases': [{'ordinal': 0, 'cadence': 'MONTHLY', 'pricing': {
                    'type': 'STATIC', 'price_money': {'amount': 999, 'currency': 'USD'}}}]}}
        self.invoices = {'invoice-a': {'id': 'invoice-a', 'version': 1, 'location_id': 'location-test',
            'order_id': 'charge-order-a', 'subscription_id': 'pending', 'status': 'PAID',
            'created_at': STAMP, 'updated_at': STAMP, 'timezone': 'America/New_York',
            'payment_requests': [{'request_type': 'BALANCE', 'due_date': '2026-11-11',
                                 'computed_amount_money': {'amount': 999, 'currency': 'USD'}}]}}
        self.orders = {'charge-order-a': {'id': 'charge-order-a', 'version': 2, 'location_id': 'location-test',
            'total_money': {'amount': 999, 'currency': 'USD'}, 'tenders': [{'id': 'payment-a'}]}}
        self.payments = {'payment-a': {'id': 'payment-a', 'order_id': 'charge-order-a',
            'location_id': 'location-test', 'status': 'COMPLETED', 'source_type': 'CARD',
            'updated_at': STAMP, 'version_token': 'payment-version1',
            'amount_money': {'amount': 999, 'currency': 'USD'}, 'total_money': {'amount': 999, 'currency': 'USD'},
            'refunded_money': {'amount': 0, 'currency': 'USD'}, 'refund_ids': []}}
        self.refunds = {}

    def retrieve_merchant(self, identifier):
        self.calls.append(('get-merchant', identifier)); return {'id': identifier, 'country': 'US'}

    def retrieve_location(self, identifier):
        self.calls.append(('get-location', identifier)); return {'id': identifier, 'country': 'US',
            'currency': 'USD', 'status': 'ACTIVE', 'timezone': 'America/New_York'}

    def retrieve_catalogue_object(self, identifier):
        self.calls.append(('get-catalogue', identifier))
        return deepcopy(self.variation if identifier == 'variation-test' else {'id': 'plan-test', 'type': 'SUBSCRIPTION_PLAN'})

    def create_customer(self, **kwargs):
        self.calls.append(('create-customer', kwargs['idempotency_key']))
        self.customer = {'id': 'customer-' + kwargs['reference_id'], 'reference_id': kwargs['reference_id']}
        return self.customer['id']

    def create_card(self, **kwargs):
        self.calls.append(('create-card', kwargs['idempotency_key']))
        self.card = {'id': 'card-' + self.customer['reference_id'], 'customer_id': self.customer['id'], 'enabled': True}
        return self.card['id']

    def create_subscription(self, **kwargs):
        self.calls.append(('create-subscription', kwargs['idempotency_key']))
        self.subscription = {'id': 'subscription-' + self.customer['reference_id'], 'version': 1,
            'customer_id': kwargs['customer_id'], 'card_id': kwargs['card_id'], 'location_id': kwargs['location_id'],
            'plan_variation_id': kwargs['variation_id'], 'monthly_billing_anchor_date': 28, 'status': 'ACTIVE',
            'start_date': '2026-11-11', 'timezone': 'America/New_York', 'invoice_ids': ['invoice-a']}
        self.invoices['invoice-a']['subscription_id'] = self.subscription['id']
        if self.timeout_subscription:
            raise SquareClientError('Synthetic ambiguous timeout')
        return {'subscription': deepcopy(self.subscription)}

    def retrieve_subscription(self, identifier):
        self.calls.append(('get-subscription', identifier)); return deepcopy(self.subscription)

    def search_subscriptions(self, **kwargs):
        self.calls.append(('search-subscriptions', kwargs.get('customer_id')))
        return {'subscriptions': [deepcopy(self.subscription)] if self.subscription else []}

    def retrieve_customer(self, identifier): return deepcopy(self.customer)
    def retrieve_card(self, identifier): return deepcopy(self.card)
    def retrieve_invoice(self, identifier): return deepcopy(self.invoices[identifier])
    def retrieve_order(self, identifier): return deepcopy(self.orders[identifier])
    def retrieve_payment(self, identifier): return deepcopy(self.payments[identifier])
    def retrieve_refund(self, identifier): return deepcopy(self.refunds[identifier])


def make_parent(label='one'):
    # Keep fixture enrollment explicit and independent of PostgreSQL sequences,
    # which advance even when a Django TestCase rolls back its inserted users.
    used = set(User.objects.values_list('pk', flat=True))
    identifier = next(value for value in range(1, 101) if value not in used)
    return User.objects.create_user(id=identifier, email=f'square-{label}@example.test', password=PASSWORD,
                                    email_verified_at=timezone.now())


def make_intent(parent):
    """Seed historical state locally; retired financial services are never used."""
    now=timezone.now()
    return SquareCheckoutIntent.objects.create(parent=parent,merchant_id='merchant-test',
        location_id='location-test',variation_id='variation-test',
        policy_id='all-content-monthly-usd-999-v1',policy_sha256=POLICY_SHA256,
        disclosure_version=DISCLOSURE_VERSION,consented_at=now,reauthenticated_at=now,
        request_sha256=fingerprint({'historical_fixture':str(uuid4())}))


def confirmed_fixture(parent):
    intent,client=make_intent(parent),FixtureSquare()
    # Synthetic pre-existing provider objects, not a new runtime dispatch.
    customer=client.create_customer(email_address='historical@example.test',reference_id=str(intent.pk),
        idempotency_key=intent.customer_idempotency_key)
    card=client.create_card(customer_id=customer,source_id='cnon:historical-fixture',
        idempotency_key=intent.card_idempotency_key)
    subscription=client.create_subscription(location_id=intent.location_id,customer_id=customer,
        card_id=card,variation_id=intent.variation_id,idempotency_key=intent.provider_idempotency_key)['subscription']
    intent.customer_id,intent.card_id,intent.subscription_id=customer,card,subscription['id']
    intent.state='subscription_bound';intent.save()
    return intent,client


@override_settings(**CHECKOUT_CONFIG)
class CheckoutTests(TestCase):
    def setUp(self):
        cache.clear();self.parent=make_parent();self.other=make_parent('two')
    def test_disabled_missing_config_and_missing_transport_reserve_nothing(self):
        api=APIClient();api.force_authenticate(self.parent)
        for override,status in [({'SQUARE_SANDBOX_TERM_BILLING_ENABLED':False},404),
                ({'SQUARE_SANDBOX_LOCATION_ID':''},503),({'SQUARE_ENVIRONMENT':'production'},404),({},503)]:
            with override_settings(**override):
                response=api.post(BASE,{'password':PASSWORD,'accepted':True},format='json')
                self.assertEqual(response.status_code,status);self.assertEqual(response['Cache-Control'],'no-store')
        self.assertFalse(SquareCheckoutIntent.objects.exists())
    def test_retired_direct_and_hosted_services_never_create_financial_objects(self):
        client=FixtureSquare();intent=make_intent(self.parent)
        with self.assertRaises(CheckoutRejected):
            reserve_checkout(parent=self.parent,password=PASSWORD,accepted=True,disclosure_version=DISCLOSURE_VERSION)
        for method in [confirm_direct_checkout,dispatch_hosted_checkout]:
            with self.assertRaises(CheckoutRejected):method(parent=self.parent,intent_id=intent.pk,password=PASSWORD,client=client)
        self.assertEqual(client.calls,[])
    def test_parent_historical_status_readonly_tenant_scoped_and_no_card_or_customer_exposure(self):
        intent,provider=confirmed_fixture(self.parent);api=APIClient();api.force_authenticate(self.parent)
        with patch('apps.billing.views.configured_client',side_effect=AssertionError('Status must be DB-only')):
            response=api.get(BASE+str(intent.pk)+'/')
        self.assertEqual(response.status_code,200)
        self.assertNotIn(intent.card_id,repr(response.data));self.assertNotIn(intent.customer_id,repr(response.data))
        api.force_authenticate(self.other);self.assertEqual(api.get(BASE+str(intent.pk)+'/').status_code,404)
        api.force_authenticate(self.parent)
        with patch('apps.billing.views.configured_client',return_value=provider):
            self.assertEqual(api.post(BASE+str(intent.pk)+'/confirm/',{'password':PASSWORD},format='json').status_code,409)
    def test_current_parent_api_reserve_confirm_status_price_and_no_secret_exposure(self):
        from .test_modern_web import ModernWebFixture,CHARGE_SOURCE
        provider=ModernWebFixture();api=APIClient();api.force_authenticate(self.parent)
        with patch('apps.billing.views.configured_client',return_value=provider):
            quote=api.get(BASE).data
            response=api.post(BASE,{'password':PASSWORD,'accepted':True,'billing_period':'monthly',
                'disclosure_version':quote['disclosure_version'],'disclosure_sha256':quote['disclosure_sha256']},format='json')
            self.assertEqual(response.status_code,200);identifier=response.data['id']
            self.assertEqual(api.post(BASE+identifier+'/confirm/',{'password':'wrong','charge_source_id':CHARGE_SOURCE},format='json').status_code,400)
            response=api.post(BASE+identifier+'/confirm/',{'password':PASSWORD,'charge_source_id':CHARGE_SOURCE},format='json')
            self.assertEqual(response.status_code,200);self.assertTrue(response.data['access_granted'])
            self.assertEqual(response.data['current_term']['amount_minor'],999)
            self.assertNotIn(CHARGE_SOURCE,repr(response.data));self.assertNotIn(PASSWORD,repr(response.data))
    def test_account_deletion_retains_historical_cancellation_without_provider_dispatch(self):
        from .models import SquareCancellationOutbox
        intent,provider=confirmed_fixture(self.parent);api=APIClient();api.force_authenticate(self.parent)
        with patch('apps.billing.views.configured_client',side_effect=AssertionError('No provider in delete')):
            response=api.delete('/api/accounts/me/',{'password':PASSWORD},format='json')
        self.assertEqual(response.status_code,204);self.assertFalse(User.objects.filter(pk=self.parent.pk).exists())
        self.assertEqual(SquareCancellationOutbox.objects.get().subscription_id,provider.subscription['id'])


@override_settings(**CHECKOUT_CONFIG)
class CheckoutClientTests(SimpleTestCase):
    def test_card_request_stays_scoped_but_retired_subscription_and_hosted_mutations_send_nothing(self):
        transport,key=Mock(),uuid4();client=SquareSandboxClient(transport)
        transport.send.return_value=SquareHttpResult(200,b'{"card":{"id":"card-a","customer_id":"customer-a","enabled":true}}')
        self.assertEqual(client.create_card(customer_id='customer-a',source_id='cnon:card-nonce-ok',idempotency_key=key),'card-a')
        self.assertEqual(transport.send.call_args.kwargs['url'],SANDBOX_ORIGIN+'/v2/cards')
        with self.assertRaises(SquareClientError):
            client.create_subscription(location_id='location-test',customer_id='customer-a',card_id='card-a',variation_id='variation-test',idempotency_key=key)
        with self.assertRaises(SquareClientError):
            client.create_payment_link(location_id='location-test',variation_id='variation-test',idempotency_key=key)
        self.assertEqual(transport.send.call_count,1)

    def test_bad_config_no_transport_timeout_and_wrong_resource_id_are_sanitized(self):
        with self.assertRaises(SquareClientError): SquareSandboxClient().retrieve_invoice('invoice-a')
        transport = Mock(); transport.send.side_effect = TimeoutError('private-token-marker')
        with self.assertRaises(SquareClientError) as caught:
            SquareSandboxClient(transport).retrieve_invoice('invoice-a')
        self.assertNotIn('private', str(caught.exception)); self.assertEqual(transport.send.call_count, 1)
        transport.send.side_effect = None
        transport.send.return_value = SquareHttpResult(200, b'{"invoice":{"id":"other"}}')
        with self.assertRaises(SquareClientError): SquareSandboxClient(transport).retrieve_invoice('invoice-a')
        for value in (0, 16, True):
            with override_settings(SQUARE_HTTP_TIMEOUT_SECONDS=value), self.assertRaises(SquareConfigurationError):
                SquareSandboxClient(transport).retrieve_invoice('invoice-a')

    def test_variation_rejects_other_price_proration_anchor_and_malformed_types(self):
        for field, value in [('can_prorate', True), ('monthly_billing_anchor_date', 1), ('phases', []), ('phases', None)]:
            variation = FixtureSquare().variation; variation['subscription_plan_variation_data'][field] = value
            with self.subTest(field=field), self.assertRaises(CheckoutRejected):
                validate_variation(variation, variation_id='variation-test', location_id='location-test')

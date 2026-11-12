"""Fake production protocol only: isolated database, no keys or network."""
from copy import deepcopy
from datetime import timedelta
import json
from unittest.mock import Mock, patch
from uuid import uuid4

from django.core.exceptions import ValidationError
from django.db import transaction, IntegrityError
from django.test import SimpleTestCase, TestCase, TransactionTestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from .access_status import parent_content_access
from .checkout import CheckoutRejected, checkout_status, fingerprint
from .client import SquareProductionClient, SquareSandboxClient, SquareHttpResult, SquareClientError
from .configuration import (SquareConfigurationError, SquareDisabled, configured_client,
                            square_configuration, checkout_configuration)
from .coverage import coverage_end, coverage_hash
from .http_transport import ProductionTransport
from .models import (ParentContentEntitlement, SquareBillingTerm, SquareCheckoutIntent,
                     SquareContentAgreement, SquareCustomerIdentity, SquareSubscriptionIdentity,
                     SquarePaymentCardBinding, SquareWebhookReceipt)
from .parent_checkout_web import checkout_capability, public_checkout_configuration
from .permissions import verified_paid_coverage_until
from .reconciliation import process_receipt
from .test_checkout import CHECKOUT_CONFIG, PASSWORD, make_parent, BASE
from .test_modern_web import ModernWebFixture, CHARGE_SOURCE, modern_fixture
from .test_parent_checkout_web import WEB
from .terms import (reserve_term_checkout, confirm_term_checkout, cancel_agreement, term_disclosure,
                    reconcile_term, dispatch_term_payment, prepare_due_term, frozen_term_hash)
from .tests import event_bytes, signature
from .webhooks import valid_signature, record_notification, SquareWebhookInvalid

PRODUCTION = {**WEB, 'SQUARE_ENVIRONMENT': 'production',
    'ALLOWED_HOSTS': ['checkout.example.test', 'testserver'],
    'SQUARE_PRODUCTION_ENABLED': True, 'SQUARE_PRODUCTION_CHECKOUT_ENABLED': True,
    'SQUARE_PRODUCTION_TERM_BILLING_ENABLED': True, 'SQUARE_PRODUCTION_TERM_RECONCILIATION_ENABLED': True,
    'SQUARE_PRODUCTION_HTTP_TRANSPORT_ENABLED': False,
    'SQUARE_PRODUCTION_RENEWALS_ENABLED': False, 'SQUARE_PRODUCTION_RELEASE_QUALIFIED': True,
    'SQUARE_PRODUCTION_ACCESS_TOKEN': 'synthetic-production-token-never-real',
    'SQUARE_PRODUCTION_MERCHANT_ID': 'production-merchant', 'SQUARE_PRODUCTION_LOCATION_ID': 'production-location',
    'SQUARE_PRODUCTION_APPLICATION_ID': 'sq0idp-synthetic-application',
    'SQUARE_PRODUCTION_WEBHOOK_SIGNATURE_KEY': 'synthetic-production-signature',
    'SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL': 'https://checkout.example.test/api/billing/square/webhook/',
    'SQUARE_PRODUCTION_TRANSPORT_FACTORY': lambda: None,
    'PARENT_CHECKOUT_PRODUCTION_ENABLED': True, 'PARENT_CONTENT_ACCESS_STATUS_ENABLED': True,
    'PAID_CONTENT_ENFORCEMENT_ENABLED': True, 'PAID_CONTENT_ENTITLEMENT_ENVIRONMENT': 'production'}


class ProductionFixture(ModernWebFixture):
    environment = 'production'
    def retrieve_location(self, identifier):
        return {**super().retrieve_location(identifier), 'merchant_id': 'production-merchant'}
    def create_card_from_payment(self, **kwargs):
        identifier = super().create_card_from_payment(**kwargs)
        self.stored_cards[identifier]['merchant_id'] = 'production-merchant'
        return identifier


def reserve(parent, client, period='monthly'):
    quote = term_disclosure('America/New_York', billing_period=period, environment='production')
    return reserve_term_checkout(parent=parent, password=PASSWORD, accepted=True,
        disclosure_version=quote['disclosure_version'], disclosure_sha256=quote['disclosure_sha256'],
        billing_period=period, client=client, environment='production')


def paid(parent, period='monthly'):
    client = ProductionFixture(); intent = reserve(parent, client, period)
    confirm_term_checkout(parent=parent, intent_id=intent.pk, password=PASSWORD,
        charge_source_id=CHARGE_SOURCE, client=client, environment='production')
    term = SquareBillingTerm.objects.get(environment='production', agreement__intent_reference=intent.pk)
    return intent, client, term


@override_settings(**PRODUCTION)
class ProductionConfigurationTests(SimpleTestCase):
    def test_credentials_do_not_activate_production_and_no_fallback_to_sandbox(self):
        transport = Mock(environment='production')
        client = SquareProductionClient(transport)
        for changes in ({'SQUARE_PRODUCTION_ENABLED': False}, {'SQUARE_PRODUCTION_RELEASE_QUALIFIED': False},
                {'SQUARE_PRODUCTION_CHECKOUT_ENABLED': False}, {'PARENT_CHECKOUT_PRODUCTION_ENABLED': False},
                {'SQUARE_PRODUCTION_TERM_BILLING_ENABLED': False}, {'PAID_CONTENT_ENFORCEMENT_ENABLED': False},
                {'PARENT_CONTENT_ACCESS_STATUS_ENABLED': False}, {'PAID_CONTENT_ENTITLEMENT_ENVIRONMENT': 'sandbox'},
                {'SQUARE_ENVIRONMENT': 'sandbox'}, {'SQUARE_PRODUCTION_ACCESS_TOKEN': ''}):
            with self.subTest(changes=changes), override_settings(**changes):
                with self.assertRaises((SquareDisabled, SquareConfigurationError)):
                    client.create_customer(email_address='synthetic@example.test',reference_id=str(uuid4()), idempotency_key=uuid4())
        transport.send.assert_not_called()
        with self.assertRaises(SquareConfigurationError): SquareSandboxClient(transport).retrieve_payment('sandbox-id')
        with self.assertRaises(SquareDisabled): checkout_configuration(environment='production')

    def test_production_client_fixed_origin_and_separate_credentials(self):
        transport = Mock(environment='production')
        transport.send.return_value = SquareHttpResult(200, b'{"payment":{"id":"opaque-payment"}}')
        client = SquareProductionClient(transport)
        self.assertEqual(client.retrieve_payment('opaque-payment')['id'], 'opaque-payment')
        request = transport.send.call_args.kwargs
        self.assertEqual(request['url'], 'https://connect.squareup.com/v2/payments/opaque-payment')
        self.assertEqual(request['headers']['Authorization'], 'Bearer ' + PRODUCTION['SQUARE_PRODUCTION_ACCESS_TOKEN'])
        with self.assertRaises(SquareClientError): SquareProductionClient(Mock(environment='sandbox')).retrieve_payment('p')
        with override_settings(SQUARE_PRODUCTION_TRANSPORT_FACTORY=lambda: Mock(environment='sandbox')):
            with self.assertRaises(SquareConfigurationError): configured_client(environment='production')

    def test_production_transport_refuses_sandbox_before_any_socket(self):
        from .test_http_transport import HEADERS
        with override_settings(SQUARE_PRODUCTION_HTTP_TRANSPORT_ENABLED=True), patch(
                'apps.billing.http_transport.http.client.HTTPSConnection', side_effect=AssertionError('No network')) as connection:
            for url in ('https://connect.squareupsandbox.com/v2/payments', 'http://connect.squareup.com/v2/payments',
                        'https://connect.squareup.com.evil.test/v2/payments', 'https://user:secret@connect.squareup.com/v2/payments'):
                with self.assertRaises(SquareClientError): ProductionTransport().send(method='GET', url=url,
                    headers=HEADERS, body=b'', timeout_seconds=5, max_response_bytes=1024)
        connection.assert_not_called()

    def test_write_pause_and_legacy_adapters_cannot_be_bypassed_through_typed_client(self):
        transport = Mock(environment='production'); client = SquareProductionClient(transport)
        for call in (lambda:client.cancel_subscription('s'), lambda:client.delete_payment_link('l'),
                lambda:client.create_term_payment(term_id=uuid4(), location_id='production-location',customer_id='c',
                    card_id='card', idempotency_key=uuid4(),buyer_present=False)):
            with self.assertRaises(SquareDisabled): call()
        transport.send.assert_not_called()

    def test_public_production_sdk_configuration_and_csp_are_separate(self):
        config = public_checkout_configuration()
        self.assertEqual(config['environment'], 'production')
        self.assertNotIn('ACCESS_TOKEN', str(config)); self.assertNotIn(PRODUCTION['SQUARE_PRODUCTION_ACCESS_TOKEN'], str(config))
        result = self.client.get('/parent/checkout/?plan=yearly', secure=True, HTTP_HOST='checkout.example.test')
        self.assertEqual(result.status_code, 200)
        self.assertIn('https://web.squarecdn.com', result['Content-Security-Policy'])
        self.assertIn('https://pci-connect.squareup.com', result['Content-Security-Policy'])
        self.assertNotIn('squareupsandbox', result['Content-Security-Policy'])
        self.assertNotIn('sandbox.web', result['Content-Security-Policy'])
        with override_settings(SQUARE_PRODUCTION_APPLICATION_ID='sandbox-synthetic-application'):
            self.assertEqual(self.client.get('/parent/checkout/?plan=monthly',secure=True,HTTP_HOST='checkout.example.test').status_code,404)


@override_settings(**PRODUCTION)
class ProductionLedgerTests(TestCase):
    def setUp(self):
        self.parent=make_parent('production'); self.other=make_parent('production-other')

    def test_canonical_monthly_and_yearly_capture_proof_repeat_and_cancel(self):
        for parent,period,amount in ((self.parent,'monthly',999),(self.other,'yearly',9990)):
            with self.subTest(period=period):
                intent,client,term=paid(parent,period)
                agreement=term.agreement; end=term.valid_until
                self.assertEqual(term.environment,'production');self.assertEqual(agreement.environment,'production')
                self.assertEqual(term.amount_minor,amount)
                self.assertEqual(term.valid_from,term.captured_at)
                self.assertEqual(end,coverage_end(term.captured_at,term.coverage_rule,agreement.billing_timezone))
                self.assertEqual(SquarePaymentCardBinding.objects.get(agreement=agreement).environment,'production')
                self.assertEqual(verified_paid_coverage_until(parent,environment='production'),end)
                self.assertIsNone(verified_paid_coverage_until(parent,environment='sandbox'))
                confirm_term_checkout(parent=parent,intent_id=intent.pk,password=PASSWORD,client=client,environment='production')
                term.refresh_from_db();self.assertEqual(term.valid_until,end);self.assertEqual(len(client.modern_requests),1)
                cancel_agreement(parent=parent,intent_id=intent.pk,password=PASSWORD,environment='production')
                agreement.refresh_from_db();self.assertFalse(agreement.renewals_enabled)
                self.assertEqual(verified_paid_coverage_until(parent,environment='production'),end)
                with self.assertRaises((SquareDisabled,CheckoutRejected)):
                    prepare_due_term(agreement_id=agreement.pk,environment='production')

    def test_sandbox_paid_proof_and_intent_neither_grant_nor_block_production(self):
        with override_settings(**CHECKOUT_CONFIG):
            sandbox,_,test_term=modern_fixture(self.parent)
        result=parent_content_access(self.parent)
        self.assertEqual(result['access_state'],'unpaid');self.assertIsNone(result['purchase_recovery'])
        self.assertIsNone(verified_paid_coverage_until(self.parent,environment='production'))
        intent=reserve(self.parent,ProductionFixture())
        self.assertNotEqual(intent.pk,sandbox.pk);self.assertEqual(intent.environment,'production')
        # An attacker copying only a test entitlement label still lacks its
        # immutable environment-bound canonical production term/hash.
        proof=ParentContentEntitlement.objects.get(environment='sandbox')
        proof.pk=uuid4();proof._state.adding=True;proof.environment='production';proof.save()
        self.assertIsNone(verified_paid_coverage_until(self.parent,environment='production'))
        with self.assertRaises(SquareBillingTerm.DoesNotExist):
            reconcile_term(term_id=test_term.pk,client=ProductionFixture(),environment='production')

    def test_production_renewal_needs_separate_opt_in_and_keeps_exact_saved_card_term(self):
        intent,client,initial=paid(self.parent,'yearly')
        with self.assertRaises(SquareDisabled):prepare_due_term(agreement_id=initial.agreement_id,environment='production')
        due=initial.valid_until
        with override_settings(SQUARE_PRODUCTION_RENEWALS_ENABLED=True), patch('apps.billing.terms.timezone.now',return_value=due):
            renewal=prepare_due_term(agreement_id=initial.agreement_id,environment='production')
            self.assertIsNone(renewal.valid_from);self.assertIsNone(renewal.valid_until)
            self.assertEqual(renewal.environment,'production');self.assertFalse(renewal.buyer_present)
            self.assertEqual(renewal.card_id,SquarePaymentCardBinding.objects.get().card_id)
            self.assertEqual(dispatch_term_payment(term_id=renewal.pk,client=client,environment='production'),'paid')
            renewal.refresh_from_db()
            self.assertEqual(renewal.valid_from,due)
            self.assertEqual(renewal.valid_until,coverage_end(due,'calendar_year_1',renewal.agreement.billing_timezone))
            self.assertEqual(verified_paid_coverage_until(self.parent,environment='production'),renewal.valid_until)
        self.assertEqual(len(client.modern_requests),2)
        self.assertEqual(client.modern_requests[-1]['buyer_present'],False)

    def test_wrong_environment_clients_and_owner_ids_rejected_before_provider_reads(self):
        intent,client,term=paid(self.parent)
        wrong=ModernWebFixture()
        with self.assertRaises(SquareConfigurationError): reconcile_term(term_id=term.pk,client=wrong,environment='production')
        self.assertFalse(wrong.calls)
        before=list(client.calls)
        with self.assertRaises(SquareCheckoutIntent.DoesNotExist):
            confirm_term_checkout(parent=self.other,intent_id=intent.pk,password=PASSWORD,client=client,environment='production')
        self.assertEqual(client.calls,before)
        api=APIClient();api.force_authenticate(self.other)
        with patch('apps.billing.views.configured_client',side_effect=AssertionError('Unexpected provider setup')):
            self.assertEqual(api.get(BASE+str(intent.pk)+'/').status_code,404)
            self.assertEqual(api.post(BASE+str(intent.pk)+'/confirm/',{'password':PASSWORD},format='json').status_code,404)
            self.assertEqual(api.post(BASE+str(intent.pk)+'/cancel/',{'password':PASSWORD},format='json').status_code,404)

    def test_environment_immutable_and_provider_identifiers_scoped(self):
        first=SquareCustomerIdentity.objects.create(parent=self.parent,environment='sandbox',merchant_id='same',customer_id='same')
        second=SquareCustomerIdentity.objects.create(parent=self.parent,environment='production',merchant_id='same',customer_id='same')
        for customer,environment in ((first,'sandbox'),(second,'production')):
            SquareSubscriptionIdentity.objects.create(customer=customer,environment=environment,subscription_id='same-subscription')
        first.environment='production'
        with self.assertRaises(ValidationError):first.save()
        with self.assertRaises(ValidationError):
            SquareSubscriptionIdentity.objects.create(customer=second,environment='sandbox',subscription_id='foreign')
        intent,client,term=paid(self.other)
        for row in (intent,term,term.agreement,SquarePaymentCardBinding.objects.get(agreement=term.agreement),ParentContentEntitlement.objects.get()):
            row.environment='sandbox'
            with self.assertRaises(ValidationError):row.save()

    def test_bulk_extended_bounds_cannot_turn_a_real_payment_into_extra_production_access(self):
        _intent,_client,term=paid(self.parent)
        zone=term.agreement.billing_timezone
        SquareContentAgreement.objects.filter(pk=term.agreement_id).update(billing_timezone='Invalid/ImportedZone')
        self.assertIsNone(verified_paid_coverage_until(self.parent,environment='production'))
        SquareContentAgreement.objects.filter(pk=term.agreement_id).update(billing_timezone=zone)
        term.valid_until += timedelta(days=1)
        term.coverage_sha256=coverage_hash(term,term.agreement)
        # Simulate an invalid import bypassing ordinary immutable-model saves.
        SquareBillingTerm.objects.filter(pk=term.pk).update(valid_until=term.valid_until,coverage_sha256=term.coverage_sha256)
        ParentContentEntitlement.objects.filter(parent=self.parent).update(valid_until=term.valid_until)
        self.assertIsNone(verified_paid_coverage_until(self.parent,environment='production'))

    def test_canonical_wrong_amount_currency_location_customer_reference_never_grants(self):
        changes=[{'amount_money':{'amount':1,'currency':'USD'}},{'amount_money':{'amount':999,'currency':'EUR'}},
                 {'location_id':'sandbox-location'},{'customer_id':'sandbox-customer'},{'reference_id':str(uuid4())}]
        for index,change in enumerate(changes):
            parent=make_parent('bad-'+str(index));client=ProductionFixture();original=client.create_term_payment
            def corrupt(_original=original,_change=change,**kwargs):
                result=_original(**kwargs);client.payments[result['payment']['id']].update(_change);return result
            client.create_term_payment=corrupt
            intent=reserve(parent,client)
            with self.assertRaises(CheckoutRejected):
                confirm_term_checkout(parent=parent,intent_id=intent.pk,password=PASSWORD,
                    charge_source_id=CHARGE_SOURCE,client=client,environment='production')
            self.assertFalse(ParentContentEntitlement.objects.filter(parent=parent).exists())
            self.assertEqual(len(client.modern_requests),1)

    def test_canonical_sandbox_merchant_location_and_card_fingerprint_fail(self):
        client=ProductionFixture();client.retrieve_location=lambda identifier:{'id':identifier,'merchant_id':'sandbox-merchant',
            'country':'US','currency':'USD','status':'ACTIVE','timezone':'America/New_York'}
        with self.assertRaises(CheckoutRejected):reserve(self.parent,client)
        self.assertFalse(SquareCheckoutIntent.objects.exists())
        client=ProductionFixture();original=client.create_card_from_payment
        def wrong_card(**kwargs):
            identifier=original(**kwargs);client.stored_cards[identifier]['fingerprint']='another-card';return identifier
        client.create_card_from_payment=wrong_card;intent=reserve(self.parent,client)
        with self.assertRaises(CheckoutRejected):confirm_term_checkout(parent=self.parent,intent_id=intent.pk,
            password=PASSWORD,charge_source_id=CHARGE_SOURCE,client=client,environment='production')
        self.assertFalse(SquarePaymentCardBinding.objects.exists());self.assertIsNone(SquareContentAgreement.objects.get().activated_at)

    def test_paid_management_and_read_recovery_survive_new_charge_pause(self):
        intent,client,term=paid(self.parent);end=term.valid_until
        with override_settings(SQUARE_PRODUCTION_CHECKOUT_ENABLED=False,SQUARE_PRODUCTION_TERM_BILLING_ENABLED=False,
                SQUARE_PRODUCTION_RENEWALS_ENABLED=False,PARENT_CHECKOUT_PRODUCTION_ENABLED=False,
                PARENT_CHECKOUT_HANDOFF_ENABLED=True):
            cap=checkout_capability(self.parent,purpose='manage')
            self.assertEqual(cap['state'],'available');self.assertEqual(cap['management_state'],'available')
            self.assertEqual(checkout_capability(self.parent)['state'],'unavailable')
            self.assertTrue(cap['handoff_available']);self.assertFalse(checkout_capability(self.parent)['handoff_available'])
            self.assertEqual(public_checkout_configuration(purpose='manage')['application_id'],'')
            status=parent_content_access(self.parent);self.assertEqual(status['access_state'],'paid')
            self.assertTrue(status['parent_plan_routing_enabled'])
            api=APIClient();api.force_authenticate(self.parent)
            with patch('apps.billing.views.configured_client',return_value=client):
                self.assertEqual(api.get(BASE+str(intent.pk)+'/').status_code,200)
                self.assertEqual(api.post(BASE+str(intent.pk)+'/confirm/',{'password':PASSWORD},format='json').status_code,200)
                self.assertEqual(api.post(BASE+str(intent.pk)+'/cancel/',{'password':PASSWORD},format='json').status_code,200)
                self.assertEqual(api.get(BASE).status_code,404)
            self.assertEqual(len(client.modern_requests),1);term.refresh_from_db();self.assertEqual(term.valid_until,end)
            self.assertEqual(verified_paid_coverage_until(self.parent,environment='production'),end)
            page=self.client.get('/parent/checkout/?purpose=manage',secure=True,HTTP_HOST='checkout.example.test')
            self.assertEqual(page.status_code,200);self.assertNotContains(page,'id="plan-step"')

    def test_canonical_full_refund_revokes_only_exact_environment_and_preserves_end(self):
        intent,client,term=paid(self.parent);end=term.valid_until
        stamp=timezone.now().isoformat();payment=client.payments[term.payment_id]
        client.refunds['owned-refund']={'id':'owned-refund','payment_id':term.payment_id,'location_id':term.location_id,
            'updated_at':stamp,'status':'PENDING','amount_money':{'amount':999,'currency':'USD'}}
        payment.update(refund_ids=['owned-refund'],refunded_money={'amount':0,'currency':'USD'},updated_at=stamp,version_token='v2')
        confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,client=client,environment='production')
        self.assertEqual(verified_paid_coverage_until(self.parent,environment='production'),end)
        completed=timezone.now().isoformat()
        client.refunds['owned-refund'].update(status='COMPLETED',updated_at=completed);payment['refunded_money']['amount']=999
        payment.update(updated_at=completed,version_token='v3')
        confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,client=client,environment='production')
        term.refresh_from_db();self.assertEqual(term.state,'refunded');self.assertEqual(term.valid_until,end)
        self.assertIsNone(verified_paid_coverage_until(self.parent,environment='production'))
        self.assertEqual(len(client.modern_requests),1)

    def test_sandbox_signature_event_and_term_cannot_enter_production_inbox_or_grant(self):
        with override_settings(**CHECKOUT_CONFIG):
            sandbox,client,test_term=modern_fixture(self.parent)
            raw=event_bytes(type='payment.updated',data={'id':test_term.payment_id})
            sandbox_config=square_configuration(webhook=True);sandbox_signature=signature(raw,sandbox_config)
            record_notification(raw_body=raw,configuration=sandbox_config)
        prod_config=square_configuration(webhook=True,environment='production')
        self.assertFalse(valid_signature(raw_body=raw,signature=sandbox_signature,configuration=prod_config))
        with self.assertRaises(SquareWebhookInvalid):record_notification(raw_body=raw,configuration=prod_config)
        sandbox_receipt=SquareWebhookReceipt.objects.get(environment='sandbox')
        with self.assertRaises(SquareWebhookReceipt.DoesNotExist):process_receipt(receipt_id=sandbox_receipt.pk,
            client=ProductionFixture(),environment='production')
        # Even a production-signed envelope can only queue a canonical GET; the
        # reference of an existing Sandbox term is not a production term.
        raw=event_bytes(type='payment.updated',merchant_id='production-merchant',data={'id':test_term.payment_id})
        record_notification(raw_body=raw,configuration=prod_config)
        fake=ProductionFixture();fake.payments=deepcopy(client.payments)
        receipt=SquareWebhookReceipt.objects.get(environment='production')
        self.assertEqual(process_receipt(receipt_id=receipt.pk,client=fake,environment='production'),'ignored')
        self.assertFalse(ParentContentEntitlement.objects.filter(environment='production').exists())
        self.assertFalse(fake.modern_requests)

    def test_server_environment_ignores_body_query_environment_and_never_returns_test_recovery(self):
        with override_settings(**CHECKOUT_CONFIG):modern_fixture(self.parent)
        api=APIClient();api.force_authenticate(self.parent)
        result=api.get('/api/billing/content-access/',{'environment':'sandbox'}).data
        self.assertEqual(result['environment'],'production');self.assertEqual(result['access_state'],'unpaid')
        self.assertIsNone(result['purchase_recovery'])
        quote=term_disclosure('America/New_York',environment='production')
        with patch('apps.billing.views.configured_client',return_value=ProductionFixture()):
            body={'password':PASSWORD,'accepted':True,'disclosure_version':quote['disclosure_version'],
                  'disclosure_sha256':quote['disclosure_sha256']}
            self.assertEqual(api.post(BASE,{**body,'environment':'sandbox'},format='json').status_code,400)
            result=api.post(BASE,body,format='json')
        self.assertEqual(result.status_code,200)
        self.assertEqual(SquareCheckoutIntent.objects.get(pk=result.data['id']).environment,'production')

    def test_charge_and_card_setup_recheck_operator_withdrawal_at_final_boundary(self):
        client=ProductionFixture();intent=reserve(self.parent,client)
        original=client.retrieve_customer
        def withdraw(identifier):
            value=original(identifier)
            from django.conf import settings
            settings.SQUARE_PRODUCTION_CHECKOUT_ENABLED=False
            return value
        client.retrieve_customer=withdraw
        with override_settings(SQUARE_PRODUCTION_CHECKOUT_ENABLED=True):
            with self.assertRaises((SquareDisabled,CheckoutRejected,SquareClientError)):
                confirm_term_checkout(parent=self.parent,intent_id=intent.pk,password=PASSWORD,
                    charge_source_id=CHARGE_SOURCE,client=client,environment='production')
        self.assertFalse(client.modern_requests)
        self.assertFalse(ParentContentEntitlement.objects.exists())

        client=ProductionFixture();client.reject_card_storage=True;intent=reserve(self.other,client)
        with self.assertRaises(SquareClientError):
            confirm_term_checkout(parent=self.other,intent_id=intent.pk,password=PASSWORD,
                charge_source_id=CHARGE_SOURCE,client=client,environment='production')
        term=SquareBillingTerm.objects.get(agreement__parent=self.other)
        self.assertIsNotNone(verified_paid_coverage_until(self.other,environment='production'))
        before=len([c for c in client.calls if c[0]=='store-payment-card'])
        client.reject_card_storage=False
        confirm_term_checkout(parent=self.other,intent_id=intent.pk,password=PASSWORD,
            client=client,environment='production',allow_card_setup=False)
        self.assertEqual(len([c for c in client.calls if c[0]=='store-payment-card']),before)
        self.assertFalse(SquarePaymentCardBinding.objects.filter(agreement=term.agreement).exists())
        self.assertEqual(len(client.modern_requests),1)


@override_settings(**CHECKOUT_CONFIG)
class ExistingSandboxMigrationTests(TransactionTestCase):
    def test_default_migration_preserves_sandbox_hashes_references_and_paid_period(self):
        from django.db import connection
        from django.db.migrations.executor import MigrationExecutor
        parent=make_parent('migration');intent,_,term=modern_fixture(parent)
        receipt=SquareWebhookReceipt.objects.create(merchant_id='merchant-test',event_id='preserved-event',
            event_type='payment.updated',object_id=term.payment_id,body_sha256='a'*64)
        grant=ParentContentEntitlement.objects.get()
        frozen=(intent.request_sha256,intent.disclosure_sha256,term.request_sha256,term.coverage_sha256,
                term.payment_id,term.valid_from,term.valid_until,grant.source_reference)
        executor=MigrationExecutor(connection);latest=executor.loader.graph.leaf_nodes()
        try:
            executor.migrate([('billing','0008_remove_squarebillingterm_square_positive_term_and_more')])
            # The new column's default is constant Sandbox even when an operator
            # has selected production for new work. No row data is rehashed.
            with override_settings(SQUARE_ENVIRONMENT='production'):
                MigrationExecutor(connection).migrate(latest)
            intent.refresh_from_db();term.refresh_from_db();grant.refresh_from_db();receipt.refresh_from_db()
            self.assertEqual((intent.environment,term.environment,term.agreement.environment,
                SquarePaymentCardBinding.objects.get().environment,receipt.environment,grant.environment),('sandbox',)*6)
            self.assertEqual(frozen,(intent.request_sha256,intent.disclosure_sha256,term.request_sha256,term.coverage_sha256,
                term.payment_id,term.valid_from,term.valid_until,grant.source_reference))
            self.assertEqual(term.request_sha256,frozen_term_hash(term,term.agreement))
            self.assertEqual(term.coverage_sha256,coverage_hash(term,term.agreement))
            self.assertEqual(verified_paid_coverage_until(parent,environment='sandbox'),term.valid_until)
        finally:
            MigrationExecutor(connection).migrate(latest)

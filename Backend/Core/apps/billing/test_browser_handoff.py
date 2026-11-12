"""Synthetic checkout-session tests. No provider transport or external I/O."""
from datetime import timedelta
from unittest.mock import patch
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.core.exceptions import ValidationError
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.request import Request
from rest_framework.exceptions import AuthenticationFailed
from rest_framework.test import APIRequestFactory, force_authenticate
from rest_framework_simplejwt.exceptions import InvalidToken

from apps.accounts.authentication import VerifiedEmailJWTAuthentication
from .browser_handoff import (HandoffUnavailable, authenticate_checkout_session,
                              issue_handoff, redeem_handoff)
from .checkout_auth import CheckoutSessionAuthentication
from .handoff_models import ParentCheckoutHandoff
from .handoff_views import CheckoutHandoffIssueView, CheckoutHandoffRedeemView, CheckoutHandoffRevokeView

ORIGIN = 'https://checkout.example.test'


@override_settings(PARENT_CHECKOUT_HANDOFF_ENABLED=True, SQUARE_ENVIRONMENT='sandbox',
                   PARENT_CHECKOUT_ORIGIN=ORIGIN, ALLOWED_HOSTS=['checkout.example.test'],
                   SECURE_SSL_REDIRECT=False)
class BrowserHandoffTests(TestCase):
    def setUp(self):
        cache.clear()
        self.parent = get_user_model().objects.create_user(email='parent@example.test',
            password='synthetic-parent-password', email_verified_at=timezone.now())
        self.other = get_user_model().objects.create_user(email='other@example.test',
            password='different-parent-password', email_verified_at=timezone.now())
        self.factory = APIRequestFactory()
        self.public = patch('apps.billing.parent_checkout_web.public_checkout_configuration',
            return_value={'environment': 'sandbox', 'origin': ORIGIN})
        self.capability = patch('apps.billing.parent_checkout_web.checkout_capability',
                               return_value={'state': 'available'})
        self.public.start(); self.capability.start()
        self.addCleanup(self.public.stop); self.addCleanup(self.capability.stop)
        self.expiry = int((timezone.now() + timedelta(minutes=15)).timestamp())

    def request(self, path='/api/billing/content-access/', *, token=None, method='get', data=None, origin=None):
        kwargs = {'secure': True, 'HTTP_HOST': 'checkout.example.test'}
        if token is not None:
            kwargs['HTTP_AUTHORIZATION'] = 'Bearer ' + token
        if origin is not None:
            kwargs['HTTP_ORIGIN'] = origin
        return getattr(self.factory, method)(path, data=data, format='json', **kwargs)

    def issue(self, *, parent=None, purpose='purchase', period='monthly', expiry=None):
        return issue_handoff(parent=parent or self.parent, access_expiry=expiry or self.expiry,
            purpose=purpose, billing_period=period,
            request=self.request('/api/billing/checkout-handoffs/', method='post'))

    def redeem(self, value, *, origin=ORIGIN):
        return redeem_handoff(code=value['code'], request=self.request(
            '/api/billing/checkout-handoffs/redeem/', method='post', origin=origin))

    def auth(self, result, path='/api/billing/content-access/', *, method='get', data=None, origin=None):
        return CheckoutSessionAuthentication().authenticate(Request(self.request(path,
            token=result['checkout_token'], method=method, data=data,
            origin=origin if origin is not None else (ORIGIN if method == 'post' else None))))

    def test_default_off_mints_nothing_and_reads_no_database(self):
        request = self.request('/api/billing/checkout-handoffs/', method='post',
                               data={'purpose': 'purchase', 'billing_period': 'monthly'})
        force_authenticate(request, user=self.parent, token={'exp': self.expiry})
        with override_settings(PARENT_CHECKOUT_HANDOFF_ENABLED=False), self.assertNumQueries(0):
            response = CheckoutHandoffIssueView.as_view()(request)
        self.assertEqual(response.status_code, 404)
        self.assertEqual(ParentCheckoutHandoff.objects.count(), 0)

    def test_issue_stores_only_digest_and_parent_bound_metadata(self):
        value = self.issue()
        self.assertRegex(value['code'], r'^[A-Za-z0-9_-]{43}$')
        self.assertEqual(value['parent_id'], str(self.parent.pk))
        self.assertLessEqual(value['expires_in'], 90)
        self.assertNotIn('token', value)
        self.assertNotIn('url', value)
        row = ParentCheckoutHandoff.objects.get()
        self.assertNotIn(value['code'], row.code_digest)
        self.assertNotIn(self.parent.password, row.parent_auth_fingerprint)
        self.assertIsNone(row.consumed_at)

    def test_missing_plan_foreign_fields_or_purpose_cannot_mint(self):
        for body in ({'purpose': 'purchase'}, {'purpose': 'purchase', 'billing_period': 'weekly'},
                     {'purpose': 'manage', 'billing_period': 'yearly'},
                     {'purpose': 'purchase', 'billing_period': 'monthly', 'environment': 'production'},
                     {'purpose': 'purchase', 'billing_period': 'monthly', 'parent_id': str(self.other.pk)}):
            request = self.request('/api/billing/checkout-handoffs/', method='post', data=body)
            force_authenticate(request, user=self.parent, token={'exp': self.expiry})
            self.assertEqual(CheckoutHandoffIssueView.as_view()(request).status_code, 400)
        self.assertEqual(ParentCheckoutHandoff.objects.count(), 0)

    def test_disabled_parent_or_capability_cannot_mint(self):
        with patch('apps.billing.parent_checkout_web.checkout_capability', return_value={'state': 'unavailable'}):
            with self.assertRaises(HandoffUnavailable): self.issue()
        self.parent.email_verified_at = None; self.parent.save(update_fields=['email_verified_at'])
        with self.assertRaises(HandoffUnavailable): self.issue()

    def test_exchange_is_single_use_and_does_not_issue_an_app_jwt(self):
        value = self.issue(); result = self.redeem(value)
        self.assertTrue(result['checkout_token'].startswith('kkco.'))
        self.assertEqual(result['parent']['id'], str(self.parent.pk))
        self.assertEqual(result['purpose'], 'purchase')
        with self.assertRaises(HandoffUnavailable): self.redeem(value)
        row = ParentCheckoutHandoff.objects.get()
        self.assertLessEqual(row.session_expires_at, row.origin_access_expires_at)
        self.assertLessEqual(row.session_expires_at, row.consumed_at + timedelta(minutes=10))

    def test_cross_origin_http_and_expired_code_do_not_consume(self):
        value = self.issue()
        for origin in (None, 'https://attacker.example', ORIGIN + '?copied=1'):
            with self.assertRaises(HandoffUnavailable): self.redeem(value, origin=origin)
        insecure = self.factory.post('/api/billing/checkout-handoffs/redeem/',
            HTTP_HOST='checkout.example.test', HTTP_ORIGIN=ORIGIN)
        with self.assertRaises(HandoffUnavailable): redeem_handoff(code=value['code'], request=insecure)
        self.assertIsNone(ParentCheckoutHandoff.objects.get().consumed_at)
        row = ParentCheckoutHandoff.objects.get()
        with patch('apps.billing.browser_handoff.timezone.now', return_value=row.expires_at + timedelta(seconds=1)):
            with self.assertRaises(HandoffUnavailable): self.redeem(value)

    def test_malformed_and_oversized_exchange_is_bounded_and_private(self):
        for raw in (b'[]', b'{"code":"one","code":"two"}', b'{"code":"' + b'a' * 2100 + b'"}'):
            request = self.factory.post('/api/billing/checkout-handoffs/redeem/', raw,
                content_type='application/json', secure=True, HTTP_HOST='checkout.example.test', HTTP_ORIGIN=ORIGIN)
            response = CheckoutHandoffRedeemView.as_view()(request)
            self.assertEqual(response.status_code, 400)
            self.assertIn('no-store', response['Cache-Control'])
        self.assertEqual(ParentCheckoutHandoff.objects.count(), 0)

    def test_code_or_app_access_expiring_during_capability_check_is_not_consumed(self):
        for short_app_access in (False, True):
            with self.subTest(short_app_access=short_app_access):
                expiry = int((timezone.now() + timedelta(seconds=40)).timestamp()) if short_app_access else None
                value = self.issue(expiry=expiry)
                row = ParentCheckoutHandoff.objects.get(code_digest__isnull=False, revoked_at__isnull=True)
                boundary = min(row.expires_at, row.origin_access_expires_at)
                with patch('apps.billing.browser_handoff.timezone.now', side_effect=[
                        boundary - timedelta(seconds=1), boundary + timedelta(seconds=1)]):
                    with self.assertRaises(HandoffUnavailable):
                        self.redeem(value)
                row.refresh_from_db()
                self.assertIsNone(row.consumed_at)
                self.assertIsNone(row.session_expires_at)

    def test_parent_change_password_deletion_or_environment_revokes_session(self):
        result = self.redeem(self.issue())
        self.assertEqual(self.auth(result)[0].pk, self.parent.pk)
        with override_settings(SQUARE_ENVIRONMENT='production'):
            with self.assertRaises(AuthenticationFailed): self.auth(result)
        self.parent.set_password('replacement-synthetic-password'); self.parent.save(update_fields=['password'])
        with self.assertRaises(AuthenticationFailed): self.auth(result)
        result = self.redeem(self.issue())
        self.parent.delete()
        with self.assertRaises(AuthenticationFailed): self.auth(result)

    def test_expired_app_access_or_password_change_before_exchange_is_rejected(self):
        with self.assertRaises(HandoffUnavailable): self.issue(expiry=int(timezone.now().timestamp()))
        value = self.issue()
        self.parent.set_password('changed-before-exchange'); self.parent.save(update_fields=['password'])
        with self.assertRaises(HandoffUnavailable): self.redeem(value)

    def test_short_session_cannot_outlive_app_access_or_be_extended(self):
        value = self.issue(expiry=int((timezone.now() + timedelta(seconds=40)).timestamp()))
        result = self.redeem(value); row = ParentCheckoutHandoff.objects.get()
        self.assertEqual(row.session_expires_at, row.origin_access_expires_at)
        row.session_expires_at += timedelta(seconds=1)
        with self.assertRaises(ValidationError): row.save()
        ParentCheckoutHandoff.objects.update(session_expires_at=timezone.now() - timedelta(seconds=1))
        with self.assertRaises(AuthenticationFailed): self.auth(result)

    def test_new_code_revokes_only_unconsumed_link_not_existing_browser_session(self):
        first = self.issue(); second = self.issue()
        with self.assertRaises(HandoffUnavailable): self.redeem(first)
        session = self.redeem(second); self.issue()
        self.assertEqual(self.auth(session)[0].pk, self.parent.pk)

    def test_scoped_token_cannot_read_account_children_or_mint_more_sessions(self):
        result = self.redeem(self.issue())
        for path in ('/api/accounts/me/', '/api/accounts/kid-profiles/',
                     '/api/stories/', '/api/billing/checkout-handoffs/'):
            with self.assertRaises(AuthenticationFailed): self.auth(result, path, method='post', data={})
        request = Request(self.request('/api/accounts/me/', token=result['checkout_token']))
        with self.assertRaises(InvalidToken): VerifiedEmailJWTAuthentication().authenticate(request)

    def test_manage_session_cannot_reserve_restart_prepare_or_supply_payment_token(self):
        result = self.redeem(self.issue(purpose='manage', period=None))
        intent = str(uuid4()); base = '/api/billing/square/checkout-intents/'
        for path, data in ((base, {'password': 'x'}), (base + intent + '/restart/', {'password': 'x'}),
                           (base + intent + '/prepare-card/', {'password': 'x'}),
                           (base + intent + '/confirm/', {'password': 'x', 'charge_source_id': 'cnon:synthetic'})):
            with self.assertRaises(AuthenticationFailed): self.auth(result, path, method='post', data=data)
        self.assertEqual(self.auth(result, base + intent + '/cancel/', method='post', data={'password': 'x'})[0].pk,
                         self.parent.pk)
        self.assertEqual(self.auth(result, base + intent + '/confirm/', method='post', data={'password': 'x'})[0].pk,
                         self.parent.pk)

    def test_revoke_closes_only_this_checkout_session(self):
        result = self.redeem(self.issue())
        request = self.request('/api/billing/checkout-handoffs/revoke/', method='post',
            data={}, token=result['checkout_token'], origin=ORIGIN)
        response = CheckoutHandoffRevokeView.as_view()(request)
        self.assertEqual(response.status_code, 204)
        self.parent.refresh_from_db(); self.assertTrue(self.parent.is_active)
        with self.assertRaises(AuthenticationFailed): self.auth(result)

    def test_environment_and_parent_identity_are_immutable(self):
        self.issue(); row = ParentCheckoutHandoff.objects.get(); row.environment = 'production'
        with self.assertRaises(ValidationError): row.save()
        row.refresh_from_db(); row.parent = self.other
        with self.assertRaises(ValidationError): row.save()

    def test_explicit_production_session_is_not_a_sandbox_session_or_paid_grant(self):
        with override_settings(SQUARE_ENVIRONMENT='production'), patch(
                'apps.billing.parent_checkout_web.public_checkout_configuration',
                return_value={'environment': 'production', 'origin': ORIGIN}):
            result = self.redeem(self.issue())
            self.assertEqual(result['environment'], 'production')
            self.assertEqual(self.auth(result)[0].pk, self.parent.pk)
        with self.assertRaises(AuthenticationFailed): self.auth(result)
        from .models import ParentContentEntitlement, SquareBillingTerm, SquareCheckoutIntent
        self.assertEqual(ParentContentEntitlement.objects.count(), 0)
        self.assertEqual(SquareBillingTerm.objects.count(), 0)
        self.assertEqual(SquareCheckoutIntent.objects.count(), 0)

    def test_scoped_mutation_requires_current_origin(self):
        result = self.redeem(self.issue(purpose='manage', period=None))
        path = '/api/billing/square/checkout-intents/' + str(uuid4()) + '/cancel/'
        for origin in ('', 'https://attacker.example'):
            with self.assertRaises(AuthenticationFailed):
                self.auth(result, path, method='post', data={'password': 'x'}, origin=origin)

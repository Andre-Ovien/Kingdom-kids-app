"""Parent website configuration/render tests with synthetic IDs only."""
from django.test import SimpleTestCase, override_settings

from .parent_checkout_web import (ParentCheckoutUnavailable, _origin,
                                  public_checkout_configuration)
from .test_checkout import CHECKOUT_CONFIG

WEB = {**CHECKOUT_CONFIG, 'PARENT_CHECKOUT_SANDBOX_ENABLED': True,
       'PARENT_CONTENT_ACCESS_STATUS_ENABLED': True, 'PAID_CONTENT_ENTITLEMENT_ENVIRONMENT': 'sandbox',
       'PARENT_CHECKOUT_ORIGIN': 'https://checkout.example.test',
       'SQUARE_SANDBOX_APPLICATION_ID': 'sandbox-fixture-application',
       'SQUARE_SANDBOX_TRANSPORT_FACTORY': lambda: None,
       'ALLOWED_HOSTS': ['checkout.example.test'], 'SECURE_SSL_REDIRECT': False,
       'STORAGES': {'default': {'BACKEND': 'django.core.files.storage.FileSystemStorage'},
                    'staticfiles': {'BACKEND': 'django.contrib.staticfiles.storage.StaticFilesStorage'}}}


@override_settings(**WEB)
class ParentCheckoutWebTests(SimpleTestCase):
    def get(self, path='/parent/checkout/', **kwargs):
        return self.client.get(path, secure=True, HTTP_HOST='checkout.example.test', **kwargs)

    def test_default_off_is_not_a_checkout_page(self):
        with override_settings(PARENT_CHECKOUT_SANDBOX_ENABLED=False):
            self.assertEqual(self.get().status_code, 404)

    def test_https_exact_origin_and_clean_url_required(self):
        self.assertEqual(self.client.get('/parent/checkout/', HTTP_HOST='checkout.example.test').status_code, 404)
        self.assertEqual(self.get('/parent/checkout/?access=synthetic-token').status_code, 404)
        with override_settings(PARENT_CHECKOUT_ORIGIN='https://different.example.test'):
            self.assertEqual(self.get().status_code, 404)

    def test_render_is_light_parent_checkout_with_only_public_runtime_config(self):
        response = self.get('/parent/checkout/?plan=monthly')
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, 'Parent sign in')
        self.assertContains(response, 'Card details')
        self.assertNotContains(response, 'Sandbox · Test cards only')
        self.assertNotContains(response, 'class="sandbox"')
        self.assertContains(response, '"environment": "sandbox"')
        self.assertNotContains(response, CHECKOUT_CONFIG['SQUARE_SANDBOX_ACCESS_TOKEN'])
        self.assertNotContains(response, 'tokenize-only')
        self.assertIn('no-store', response['Cache-Control'])
        self.assertEqual(response['Referrer-Policy'], 'no-referrer')
        self.assertIn("frame-ancestors 'none'", response['Content-Security-Policy'])
        self.assertIn('https://pci-connect.squareupsandbox.com', response['Content-Security-Policy'])
        self.assertNotIn('connect.squareup.com', response['Content-Security-Policy'])

    def test_selected_plan_is_strict_nonsecret_and_omits_browser_plan_controls(self):
        for period in ('monthly', 'yearly'):
            response = self.get('/parent/checkout/?plan=' + period)
            self.assertEqual(response.status_code, 200)
            self.assertContains(response, '"selected_plan": "' + period + '"')
            self.assertNotContains(response, 'id="monthly"')
            self.assertNotContains(response, 'id="yearly"')
            self.assertNotContains(response, 'id="plan-step"')
            self.assertNotContains(response, 'Every Bible story')
            self.assertNotContains(response, 'class="steps"')
            self.assertNotContains(response, 'id="postal"')
            self.assertNotContains(response, 'id="billing-email"')
            self.assertContains(response, 'id="country"')
        for query in ('plan=', 'plan=weekly', 'plan=MONTHLY', 'plan=monthly&plan=yearly',
                      'plan=monthly&parent=41', 'plan=yearly&access=synthetic-token'):
            self.assertEqual(self.get('/parent/checkout/?' + query).status_code, 404)

    def test_invalid_production_or_secret_like_application_config_fails_closed(self):
        for changes in ({'SQUARE_ENVIRONMENT': 'production'},
                        {'PAID_CONTENT_ENTITLEMENT_ENVIRONMENT': 'production'},
                        {'SQUARE_SANDBOX_APPLICATION_ID': 'sq0idp-production'},
                        {'PARENT_CONTENT_ACCESS_STATUS_ENABLED': False}):
            with self.subTest(changes=changes), override_settings(**changes):
                self.assertEqual(self.get().status_code, 404)

    def test_origin_rejects_http_credentials_queries_paths_and_unsafe_ports(self):
        for value in (None, 'http://checkout.example.test', 'https://user:pass@checkout.example.test',
                      'https://checkout.example.test?x', 'https://checkout.example.test/#fragment',
                      'https://checkout.example.test/subpath', 'https://checkout.example.test:8443'):
            with self.subTest(value=value), self.assertRaises(ParentCheckoutUnavailable):
                _origin(value)

    def test_loopback_sandbox_still_requires_tls_even_with_debug_off(self):
        with override_settings(DEBUG=False):
            self.assertEqual(_origin('https://127.0.0.1:18443'), 'https://127.0.0.1:18443')
            with self.assertRaises(ParentCheckoutUnavailable):
                _origin('http://127.0.0.1:18443')

    def test_public_config_never_returns_access_token_or_webhook_key(self):
        result = public_checkout_configuration()
        self.assertEqual(set(result), {'environment', 'origin', 'purpose', 'application_id', 'location_id', 'billing_mode'})

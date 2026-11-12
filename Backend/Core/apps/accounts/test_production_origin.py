"""Pinned custom-origin routing only; no database, network or provider calls."""
from unittest.mock import Mock

from django.conf import settings
from django.core.exceptions import DisallowedHost
from django.http import HttpResponse
from django.test import RequestFactory, SimpleTestCase, override_settings

from Core.production_origin import ProductionOriginMiddleware, PRODUCTION_CUSTOM_HOST, PRODUCTION_CUSTOM_ORIGIN


PLATFORM_HOST = 'kingdom-kids-checkout-staging.onrender.com'


@override_settings(SQUARE_ENVIRONMENT='production', PARENT_CHECKOUT_ORIGIN=PRODUCTION_CUSTOM_ORIGIN,
                   ALLOWED_HOSTS=[PLATFORM_HOST, PRODUCTION_CUSTOM_HOST])
class ProductionOriginTests(SimpleTestCase):
    def setUp(self):
        self.response = Mock(return_value=HttpResponse(status=200))
        self.middleware = ProductionOriginMiddleware(self.response)
        self.factory = RequestFactory()

    def request(self, pathname, host):
        return self.factory.get(pathname, HTTP_HOST=host, secure=True)

    def test_custom_origin_keeps_normal_account_content_and_checkout_paths(self):
        for pathname in ('/api/accounts/me/', '/api/stories/', '/parent/checkout/', '/admin/'):
            self.assertEqual(self.middleware(self.request(pathname, PRODUCTION_CUSTOM_HOST)).status_code, 200)
        self.assertEqual(self.response.call_count, 4)

    def test_render_handle_is_health_only_before_api_or_security_redirect(self):
        for pathname in ('/api/accounts/login/', '/api/billing/content-access/', '/parent/checkout/',
                '/admin/', '/static/billing/parent_checkout.js', '/health/ready/admin/', '/health/other/'):
            result = self.middleware(self.request(pathname, PLATFORM_HOST))
            self.assertEqual(result.status_code, 404)
            self.assertEqual(result['Cache-Control'], 'no-store')
        self.response.assert_not_called()
        for pathname in ('/health/live/', '/health/ready/'):
            self.assertEqual(self.middleware(self.request(pathname, PLATFORM_HOST)).status_code, 200)
        self.assertEqual(self.response.call_count, 2)
        self.assertLess(settings.MIDDLEWARE.index('Core.production_origin.ProductionOriginMiddleware'),
                        settings.MIDDLEWARE.index('django.middleware.security.SecurityMiddleware'))

    def test_unknown_host_is_not_authorized_by_the_platform_alias_rule(self):
        with self.assertRaises(DisallowedHost):
            self.middleware(self.request('/health/live/', 'attacker.example'))
        self.response.assert_not_called()

    def test_sandbox_and_new_render_origin_alternative_preserve_prior_behavior(self):
        for environment, origin in (('sandbox', PRODUCTION_CUSTOM_ORIGIN),
                                    ('production', 'https://kingdom-kids-release-fixture.onrender.com')):
            with override_settings(SQUARE_ENVIRONMENT=environment, PARENT_CHECKOUT_ORIGIN=origin):
                self.assertEqual(self.middleware(self.request('/api/stories/', PLATFORM_HOST)).status_code, 200)

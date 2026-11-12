from unittest.mock import patch

from django.conf import settings
from django.test import TestCase, override_settings
from django.urls import reverse


class DeploymentHealthTests(TestCase):
    def test_liveness_is_public_and_does_not_expose_details(self):
        response = self.client.get(reverse('health-live'))

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {'status': 'ok'})
        self.assertEqual(
            response.headers['Cache-Control'],
            'max-age=0, no-cache, no-store, must-revalidate, private',
        )

    def test_readiness_checks_database_and_cache(self):
        response = self.client.get(reverse('health-ready'))

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {'status': 'ok'})


@override_settings(
    DEBUG=False,
    ALLOWED_HOSTS=['testserver'],
    SECURE_SSL_REDIRECT=True,
    SECURE_PROXY_SSL_HEADER=None,
)
class DeploymentHealthHTTPSBehaviorTests(TestCase):
    def test_only_exact_health_paths_bypass_https_redirect(self):
        self.assertEqual(
            settings.SECURE_REDIRECT_EXEMPT,
            [r'^health/live/$', r'^health/ready/$'],
        )
        for name in ('health-live', 'health-ready'):
            with self.subTest(name=name):
                response = self.client.get(reverse(name))
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.json(), {'status': 'ok'})

        for path in ('/api/games/', '/admin/', '/health/ready/extra/', '/health/live'):
            with self.subTest(path=path):
                response = self.client.get(path)
                self.assertEqual(response.status_code, 301)
                self.assertTrue(response.headers['Location'].startswith('https://'))

    def test_http_readiness_reports_database_failure_instead_of_healthy_redirect(self):
        with patch('Core.health.connection.cursor', side_effect=RuntimeError('private db detail')):
            response = self.client.get(reverse('health-ready'))

        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json(), {'status': 'unavailable'})
        self.assertNotIn(b'private db detail', response.content)

    def test_http_readiness_reports_cache_failure_instead_of_healthy_redirect(self):
        with patch('Core.health.cache.get', return_value=None):
            response = self.client.get(reverse('health-ready'))

        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json(), {'status': 'unavailable'})

    def test_http_liveness_never_checks_dependencies(self):
        with patch('Core.health.connection.cursor') as cursor, patch('Core.health.cache.set') as cache_set:
            response = self.client.get(reverse('health-live'))

        self.assertEqual(response.status_code, 200)
        cursor.assert_not_called()
        cache_set.assert_not_called()

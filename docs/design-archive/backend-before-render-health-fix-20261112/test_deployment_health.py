from django.test import TestCase
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

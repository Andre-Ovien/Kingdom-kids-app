from django.core.cache import cache
from django.db import IntegrityError, transaction
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APITestCase

from .models import User, WaitlistSubscriber


ACCEPTED_RESPONSE = {
    'detail': 'Thanks. Your waitlist request has been received.',
}


class WaitlistApiTests(APITestCase):
    def setUp(self):
        super().setUp()
        cache.clear()
        self.url = reverse('accounts:waitlist')

    def post(self, email):
        return self.client.post(self.url, {'email': email}, format='json')

    def test_anonymous_signup_normalizes_and_records_footer_consent(self):
        before_signup = timezone.now()

        response = self.post('  Parent@Example.COM  ')

        self.assertEqual(response.status_code, status.HTTP_202_ACCEPTED)
        self.assertEqual(response.data, ACCEPTED_RESPONSE)
        subscriber = WaitlistSubscriber.objects.get()
        self.assertEqual(subscriber.email, 'parent@example.com')
        self.assertEqual(
            subscriber.consent_source,
            WaitlistSubscriber.ConsentSource.WEBSITE_FOOTER,
        )
        self.assertGreaterEqual(subscriber.consented_at, before_signup)
        self.assertEqual(User.objects.count(), 0)

    def test_repeat_signup_is_idempotent_and_does_not_disclose_membership(self):
        first = self.post('parent@example.com')
        subscriber = WaitlistSubscriber.objects.get()
        original_consent_time = subscriber.consented_at

        second = self.post('PARENT@EXAMPLE.COM')

        self.assertEqual(first.status_code, status.HTTP_202_ACCEPTED)
        self.assertEqual(second.status_code, status.HTTP_202_ACCEPTED)
        self.assertEqual(first.data, ACCEPTED_RESPONSE)
        self.assertEqual(second.data, ACCEPTED_RESPONSE)
        self.assertEqual(first['Cache-Control'], 'no-store')
        self.assertEqual(second['Cache-Control'], 'no-store')
        self.assertEqual(WaitlistSubscriber.objects.count(), 1)
        subscriber.refresh_from_db()
        self.assertEqual(subscriber.consented_at, original_consent_time)

    def test_invalid_email_is_rejected_without_creating_a_record(self):
        response = self.post('not-an-email')

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response['Cache-Control'], 'no-store')
        self.assertEqual(WaitlistSubscriber.objects.count(), 0)

    def test_database_constraint_is_case_insensitive(self):
        WaitlistSubscriber.objects.create(email='parent@example.com')

        with self.assertRaises(IntegrityError), transaction.atomic():
            WaitlistSubscriber.objects.bulk_create(
                [WaitlistSubscriber(email='PARENT@EXAMPLE.COM')]
            )

        self.assertEqual(WaitlistSubscriber.objects.count(), 1)

    def test_signup_is_rate_limited_by_the_waitlist_scope(self):
        cache.clear()

        for index in range(10):
            self.assertEqual(
                self.post(f'parent-{index}@example.com').status_code,
                status.HTTP_202_ACCEPTED,
            )
        rejected = self.post('rate-limited@example.com')
        self.assertEqual(rejected.status_code, status.HTTP_429_TOO_MANY_REQUESTS)
        self.assertEqual(rejected['Cache-Control'], 'no-store')

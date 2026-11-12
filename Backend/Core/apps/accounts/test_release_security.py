import bz2
import json
from unittest.mock import patch

from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from django.utils import timezone
from django.utils.http import parse_header_parameters
from rest_framework.test import APITestCase
from rest_framework_simplejwt.tokens import RefreshToken

from .models import User, WaitlistSubscriber


class AuthRequestBoundaryTests(APITestCase):
    @override_settings(DATA_UPLOAD_MAX_MEMORY_SIZE=256)
    def test_json_transform_charset_cannot_bypass_the_body_size_limit(self):
        # A small, harmless fixture proves the expansion path without allocating
        # an attack-sized body: compressed bytes fit the ceiling, decoded JSON
        # does not. Binary transforms must never be accepted as text charsets.
        decoded = json.dumps({
            'email': 'compressed-boundary@example.com',
            'padding': 'x' * 4096,
        }).encode()
        compressed = bz2.compress(decoded)
        self.assertLess(len(compressed), 256)
        self.assertGreater(len(decoded), 256)
        rejected = self.client.generic(
            'POST',
            reverse('accounts:waitlist'),
            compressed,
            content_type='application/json; charset=bz2_codec',
        )
        self.assertEqual(rejected.status_code, 400)
        self.assertEqual(WaitlistSubscriber.objects.count(), 0)

    def test_oversized_accept_tokens_never_reach_the_quoted_header_parser(self):
        oversized_type = 'text/x-unhandled; noise="' + ';' * 1024 + '"'
        with patch(
            'rest_framework.utils.mediatypes.parse_header_parameters',
            wraps=parse_header_parameters,
        ) as parse_header:
            response = self.client.get(
                reverse('accounts:waitlist'),
                HTTP_ACCEPT=f'{oversized_type}, application/json',
            )
        self.assertEqual(response.status_code, 405)
        self.assertFalse(
            any(call.args[0] == oversized_type for call in parse_header.call_args_list),
            'Untrusted oversized Accept token reached the expensive quoted parser.',
        )

    @override_settings(DATA_UPLOAD_MAX_MEMORY_SIZE=256)
    def test_json_body_limit_is_enforced_before_a_public_write(self):
        oversized = self.client.post(
            reverse('accounts:waitlist'),
            {'email': 'boundary-waitlist@example.com', 'padding': 'x' * 512},
            format='json',
        )
        self.assertEqual(oversized.status_code, 400)
        self.assertEqual(WaitlistSubscriber.objects.count(), 0)

        ordinary = self.client.post(
            reverse('accounts:waitlist'),
            {'email': 'boundary-waitlist@example.com'},
            format='json',
        )
        self.assertEqual(ordinary.status_code, 202)
        self.assertEqual(WaitlistSubscriber.objects.count(), 1)

    def test_public_email_flows_reject_non_object_json(self):
        routes = (
            ('POST', 'accounts:register'),
            ('POST', 'accounts:login'),
            ('POST', 'accounts:password-reset-request'),
            ('POST', 'accounts:account-deletion-request'),
            ('DELETE', 'accounts:unverified-account-delete'),
        )
        for method, route in routes:
            for payload in ([], ['reader@example.com'], 'reader@example.com', 42, True, None):
                with self.subTest(route=route, payload=payload):
                    cache.clear()
                    response = self.client.generic(
                        method,
                        reverse(route),
                        json.dumps(payload),
                        content_type='application/json',
                    )
                    self.assertEqual(response.status_code, 400)
        self.assertEqual(User.objects.count(), 0)

    def test_authenticated_logout_rejects_non_object_json(self):
        parent = User.objects.create_user(
            email='boundary-reader@example.com',
            password='A-strong-password-123!',
            email_verified_at=timezone.now(),
        )
        refresh = RefreshToken.for_user(parent)
        self.client.credentials(HTTP_AUTHORIZATION=f'Bearer {refresh.access_token}')
        for payload in ([], 'refresh-token', 42, True, None):
            with self.subTest(payload=payload):
                response = self.client.generic(
                    'POST',
                    reverse('accounts:logout'),
                    json.dumps(payload),
                    content_type='application/json',
                )
                self.assertEqual(response.status_code, 400)
        # Malformed logout input must not revoke the real session.
        RefreshToken(str(refresh))

    def test_invalid_base64_signature_suffix_cannot_authenticate(self):
        parent = User.objects.create_user(
            email='signature-reader@example.com',
            password='A-strong-password-123!',
            email_verified_at=timezone.now(),
        )
        access = str(RefreshToken.for_user(parent).access_token)
        self.client.credentials(HTTP_AUTHORIZATION=f'Bearer {access}!!!!')
        rejected = self.client.get(reverse('accounts:me'))
        self.assertEqual(rejected.status_code, 401)

        self.client.credentials(HTTP_AUTHORIZATION=f'Bearer {access}')
        accepted = self.client.get(reverse('accounts:me'))
        self.assertEqual(accepted.status_code, 200)

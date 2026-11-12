from datetime import datetime, timezone
import hashlib
import json
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from django.core.exceptions import ImproperlyConfigured
from django.http import HttpResponse
from django.test import SimpleTestCase, TestCase, override_settings
from django.utils import timezone as django_timezone
from django.views.debug import SafeExceptionReporterFilter
from rest_framework.test import APIClient

from apps.accounts.models import KidProfile, User
from apps.games.models import Game
from apps.games.serializers import GameListSerializer
from apps.stories.models import NarratorVoice, Story, StoryNarration
from apps.stories.serializers import StoryListSerializer, StoryNarrationSerializer
from Core.media_delivery import PrivateMediaNoStoreMiddleware, _load_map, private_media_url

COVER = 'Frontend/mobile/assets/images/stories/noah-builds-the-ark-v2.webp'
TRACK = 'Backend/media/character_narration/noah-builds-the-ark/kai.mp3'
SAMPLE = 'Backend/media/character_narration/auditions/kai_boy2.mp3'
BODY = 'A canonical story.'
TEXT_HASH = hashlib.sha256(BODY.encode()).hexdigest()
SHA = 'a' * 64


def entry(resource='image', extension='webp', uses=None):
    return {'public_id': 'kingdom-kids/media-v1/sha256-' + SHA,
            'resource_type': resource, 'type': 'authenticated', 'sha256': SHA,
            'bytes': 2048, 'format': extension, 'uses': uses or ['story-cover:noah-builds-the-ark', 'game-cover:noah-quiz']}


def request():
    return SimpleNamespace(
        user=SimpleNamespace(is_authenticated=True, is_active=True, is_email_verified=True),
        build_absolute_uri=lambda url: url,
    )


class MediaFixture:
    def setUp(self):
        super().setUp()
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.map_path = Path(self.temp.name) / 'map.json'
        self.map_data = {'schema_version': 1, 'scope': 'first_release_only', 'cloud_name': 'fixture-cloud', 'remote_originals_verified': True,
                         'assets': {COVER: entry(), TRACK: entry('video', 'mp3', [f'narration:noah-builds-the-ark:lion:{TEXT_HASH}']),
                                    SAMPLE: entry('video', 'mp3', ['sample:lion'])}}
        self.pin = self.write_map()
        self.options = override_settings(
            CLOUDINARY_PRIVATE_DELIVERY_ENABLED=True,
            CLOUDINARY_CLOUD_NAME='fixture-cloud', CLOUDINARY_API_KEY='1234567890',
            CLOUDINARY_API_SECRET='fixture-secret-not-a-real-account',
            CLOUDINARY_PRIVATE_MEDIA_MAP=self.map_path, CLOUDINARY_PRIVATE_MEDIA_MAP_SHA256=self.pin,
            CLOUDINARY_PRIVATE_URL_TTL_SECONDS=300, CONTENT_MEDIA_HOSTS=('api.cloudinary.com',),
            PAID_CONTENT_ENFORCEMENT_ENABLED=False,
        )
        self.options.enable()
        self.addCleanup(self.options.disable)
        self.addCleanup(_load_map.cache_clear)

    def write_map(self):
        payload = json.dumps(self.map_data).encode()
        self.map_path.write_bytes(payload)
        return hashlib.sha256(payload).hexdigest()


class PrivateMediaSigningTests(MediaFixture, SimpleTestCase):
    def test_late_narration_failure_redacts_prior_fields_and_prior_list_items(self):
        narrator = NarratorVoice(avatar_key='lion', voice_key='kai', display_name='Kai',
                                 sample_audio=SAMPLE.removeprefix('Backend/media/'))
        story = Story(slug='noah-builds-the-ark', body=BODY)
        rows = [StoryNarration(story=story, narrator=narrator, status='ready',
                               text_sha256=TEXT_HASH, audio_file=TRACK.removeprefix('Backend/media/'))
                for _ in range(2)]
        with override_settings(DEBUG=False), patch(
            'apps.stories.serializers.validated_narration_words',
            side_effect=[[], RuntimeError('Synthetic late field failure')],
        ):
            try:
                StoryNarrationSerializer(rows, many=True, context={'request': request()}).data
            except RuntimeError:
                traceback = sys.exc_info()[2]
                reporter = SafeExceptionReporterFilter()
                checked = 0
                while traceback:
                    filename = traceback.tb_frame.f_code.co_filename
                    if filename.endswith(('rest_framework/serializers.py', 'Core/media_serializers.py', 'apps/stories/serializers.py')):
                        safe = list(reporter.get_traceback_frame_variables(None, traceback.tb_frame))
                        self.assertNotIn('https://api.cloudinary.com/', repr(safe))
                        checked += 1
                    traceback = traceback.tb_next
                self.assertGreaterEqual(checked, 4)
            else:
                self.fail('The synthetic late-field failure did not execute.')

    def test_production_traceback_masks_keys_and_completed_signed_url(self):
        class RejectMarker(SimpleNamespace):
            def __setattr__(self, name, value):
                if name == '_private_media_signed':
                    raise RuntimeError('Synthetic post-signing failure')
                super().__setattr__(name, value)

        req = RejectMarker(**request().__dict__)
        with override_settings(DEBUG=False):
            try:
                private_media_url(req, COVER, use='story-cover:noah-builds-the-ark')
            except RuntimeError:
                traceback = sys.exc_info()[2]
                while traceback and traceback.tb_frame.f_code.co_name != 'private_media_url':
                    traceback = traceback.tb_next
                self.assertIsNotNone(traceback)
                reporter = SafeExceptionReporterFilter()
                safe = dict(reporter.get_traceback_frame_variables(None, traceback.tb_frame))
                for name in ('api_key', 'api_secret', 'params', 'url'):
                    self.assertEqual(safe[name], reporter.cleansed_substitute)
            else:
                self.fail('The synthetic post-signing failure did not execute.')

    def test_default_off_does_not_load_map_or_read_signing_config(self):
        with override_settings(CLOUDINARY_PRIVATE_DELIVERY_ENABLED=False), patch('Core.media_delivery._load_map') as loader:
            self.assertIsNone(private_media_url(request(), COVER, use='story-cover:noah-builds-the-ark'))
            loader.assert_not_called()

    def test_exact_sdk_equivalent_signature_expiry_and_origin(self):
        url = private_media_url(request(), COVER, use='story-cover:noah-builds-the-ark', now=1_800_000_000)
        parsed = urlsplit(url)
        self.assertEqual((parsed.scheme, parsed.netloc, parsed.path), ('https', 'api.cloudinary.com', '/v1_1/fixture-cloud/image/download'))
        params = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        self.assertEqual(params['type'], 'authenticated')
        self.assertEqual(params['expires_at'], '1800000300')
        self.assertNotIn('fixture-secret', url)
        signed = '&'.join(f'{key}={params[key]}' for key in sorted(params) if key not in {'api_key', 'signature'})
        self.assertEqual(params['signature'], hashlib.sha256((signed + 'fixture-secret-not-a-real-account').encode()).hexdigest())
        self.assertNotIn('transformation', params)

    def test_unknown_owner_unauthorized_and_traversal_never_sign(self):
        for path in (COVER + '/..', COVER.replace('/stories/', '/../stories/'), COVER.replace('noah', '%6eoah'), COVER + '?url=https://evil.test', '/etc/passwd', COVER.replace('/', '\\')):
            self.assertIsNone(private_media_url(request(), path, use='story-cover:noah-builds-the-ark'))
        self.assertIsNone(private_media_url(request(), COVER, use='story-cover:another-story'))
        self.assertIsNone(private_media_url(request(), TRACK, use=f'narration:another-story:lion:{TEXT_HASH}'))
        self.assertIsNone(private_media_url(None, COVER, use='story-cover:noah-builds-the-ark'))
        anonymous = request()
        anonymous.user.is_authenticated = False
        self.assertIsNone(private_media_url(anonymous, COVER, use='story-cover:noah-builds-the-ark'))

    def test_bad_pin_scope_or_untrusted_host_fail_closed_and_sanitized(self):
        with override_settings(CLOUDINARY_PRIVATE_MEDIA_MAP_SHA256='b' * 64):
            with self.assertRaisesMessage(ImproperlyConfigured, 'missing or invalid'):
                private_media_url(request(), COVER, use='story-cover:noah-builds-the-ark')
        with override_settings(CLOUDINARY_CLOUD_NAME='cloud/../other?signature=secret', CONTENT_MEDIA_HOSTS=()):
            with self.assertRaisesMessage(ImproperlyConfigured, 'server configuration is incomplete') as error:
                private_media_url(request(), COVER, use='story-cover:noah-builds-the-ark')
            self.assertNotIn('secret', str(error.exception))
        with override_settings(CLOUDINARY_CLOUD_NAME='another-valid-cloud'):
            with self.assertRaisesMessage(ImproperlyConfigured, 'server configuration is incomplete'):
                private_media_url(request(), COVER, use='story-cover:noah-builds-the-ark')
        self.map_data['remote_originals_verified'] = False
        with override_settings(CLOUDINARY_PRIVATE_MEDIA_MAP_SHA256=self.write_map()):
            with self.assertRaises(ImproperlyConfigured):
                private_media_url(request(), COVER, use='story-cover:noah-builds-the-ark')

    def test_paid_deadline_caps_url_and_missing_or_expired_proof_never_signs(self):
        with override_settings(PAID_CONTENT_ENFORCEMENT_ENABLED=True), patch('apps.billing.permissions.paid_content_access_until') as paid:
            paid.return_value = datetime.fromtimestamp(1_800_000_020, timezone.utc)
            req = request()
            url = private_media_url(req, COVER, use='story-cover:noah-builds-the-ark', now=1_800_000_000)
            self.assertEqual(parse_qs(urlsplit(url).query)['expires_at'], ['1800000020'])
            private_media_url(req, COVER, use='story-cover:noah-builds-the-ark', now=1_800_000_001)
            self.assertEqual(paid.call_count, 1)
            paid.return_value = None
            self.assertIsNone(private_media_url(request(), COVER, use='story-cover:noah-builds-the-ark', now=1_800_000_000))
            paid.return_value = datetime.fromtimestamp(1_799_999_999, timezone.utc)
            self.assertIsNone(private_media_url(request(), COVER, use='story-cover:noah-builds-the-ark', now=1_800_000_000))

    def test_only_signed_responses_get_no_store_and_no_url_is_logged(self):
        req = request()
        def handler(value):
            private_media_url(value, COVER, use='story-cover:noah-builds-the-ark')
            return HttpResponse('response contains media metadata')
        with self.assertNoLogs(level='WARNING'):
            response = PrivateMediaNoStoreMiddleware(handler)(req)
        self.assertIn('no-store', response['Cache-Control'])
        self.assertIn('private', response['Cache-Control'])
        self.assertEqual(response['Expires'], '0')
        untouched = PrivateMediaNoStoreMiddleware(lambda _: HttpResponse('normal'))(request())
        self.assertNotIn('Cache-Control', untouched)

    def test_serializers_use_hosted_audio_without_local_files_but_keep_text_and_owner_checks(self):
        narrator = NarratorVoice(avatar_key='lion', voice_key='kai', display_name='Kai', sample_audio=SAMPLE.removeprefix('Backend/media/'))
        story = Story(slug='noah-builds-the-ark', body=BODY, cover_asset_key=COVER.removeprefix('Frontend/mobile/'))
        narration = StoryNarration(story=story, narrator=narrator, status='ready', text_sha256=TEXT_HASH, audio_file=TRACK.removeprefix('Backend/media/'))
        with patch('django.core.files.storage.filesystem.FileSystemStorage.exists', side_effect=AssertionError('No storage probing in private mode')):
            data = StoryNarrationSerializer(narration, context={'request': request()}).data
            self.assertTrue(data['audio_available'])
            self.assertEqual(urlsplit(data['audio_url']).path, '/v1_1/fixture-cloud/video/download')
            self.assertIsNotNone(data['sample_url'])
            self.assertIsNotNone(StoryListSerializer(story, context={'request': request()}).get_cover_image_url(story))
            narration.story.body = 'Changed editorial text.'
            stale = StoryNarrationSerializer(narration, context={'request': request()}).data
            self.assertFalse(stale['audio_available'])
            self.assertIsNone(stale['audio_url'])
            self.assertEqual(stale['segments'], [])
            narration.narrator.avatar_key = 'dove'
            self.assertIsNone(StoryNarrationSerializer(narration, context={'request': request()}).get_sample_url(narration))
        game = Game(slug='noah-quiz', cover_asset_key=COVER.removeprefix('Frontend/mobile/'))
        self.assertIsNotNone(GameListSerializer(game, context={'request': request()}).get_cover_image_url(game))
        game.slug = 'unreleased-game'
        self.assertIsNone(GameListSerializer(game, context={'request': request()}).get_cover_image_url(game))


class PrivateMediaApiOwnershipTests(MediaFixture, TestCase):
    def test_existing_parent_and_child_guards_precede_signing(self):
        parent = User.objects.create_user(email='private-media@example.test', password='strong-test-password', email_verified_at=django_timezone.now())
        child = KidProfile.objects.create(parent=parent, display_name='Child', avatar_key='lion')
        other = User.objects.create_user(email='other-media@example.test', password='strong-test-password', email_verified_at=django_timezone.now())
        foreign = KidProfile.objects.create(parent=other, display_name='Other', avatar_key='lion')
        client = APIClient()
        with patch('Core.media_delivery._load_map', wraps=_load_map) as loader:
            self.assertEqual(client.get('/api/stories/').status_code, 401)
            loader.assert_not_called()
            client.force_authenticate(parent)
            self.assertEqual(client.get('/api/games/', {'profile_id': foreign.pk}).status_code, 404)
            loader.assert_not_called()
        response = client.get('/api/games/', {'profile_id': child.pk})
        self.assertEqual(response.status_code, 200)
        noah = next(row for row in response.data if row['slug'] == 'noah-quiz')
        self.assertIsNotNone(noah['cover_image_url'])
        self.assertIn('no-store', response['Cache-Control'])
        with override_settings(PAID_CONTENT_ENFORCEMENT_ENABLED=True):
            self.assertEqual(client.get('/api/stories/').status_code, 403)
            self.assertEqual(client.get('/api/games/', {'profile_id': child.pk}).status_code, 403)

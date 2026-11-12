from io import StringIO
from pathlib import Path
from tempfile import TemporaryDirectory

from django.core.exceptions import ValidationError
from django.core.files.uploadedfile import SimpleUploadedFile
from django.core.management import call_command
from django.core.management.base import CommandError
from django.db import IntegrityError, transaction
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from apps.accounts.models import User

from .models import NarratorVoice, Story, StoryNarration


ROUND_ONE_FILES = {
    'lion': ('kai_a_cedar.mp3', 'cedar'),
    'dove': ('nia_a_marin.mp3', 'marin'),
    'rainbow': ('zuri_a_coral.mp3', 'coral'),
}


def write_fake_round_one_samples(media_root: str, *, only=None):
    sample_dir = Path(media_root) / 'voice_auditions'
    sample_dir.mkdir(parents=True, exist_ok=True)
    avatar_keys = set(only or ROUND_ONE_FILES)
    for avatar_key in avatar_keys:
        filename, _ = ROUND_ONE_FILES[avatar_key]
        # The installer checks an ID3 signature and rejects tiny/truncated
        # responses. Decoding is intentionally left to the mobile player.
        (sample_dir / filename).write_bytes(b'ID3' + (b'\0' * 2048))


class StoryApiTests(TestCase):
    list_url = '/api/stories/'

    def setUp(self):
        self.parent = User.objects.create_user(
            email='reader@example.com',
            password='A-strong-password-123!',
            email_verified_at=timezone.now(),
        )
        self.client = APIClient()
        self._authenticate(self.parent)

    def _authenticate(self, user):
        token = RefreshToken.for_user(user).access_token
        self.client.credentials(HTTP_AUTHORIZATION=f'Bearer {token}')

    def test_catalogue_requires_a_verified_parent(self):
        anonymous = APIClient()
        self.assertEqual(anonymous.get(self.list_url).status_code, 401)

        unverified = User.objects.create_user(
            email='pending@example.com',
            password='A-strong-password-123!',
        )
        self._authenticate(unverified)
        response = self.client.get(self.list_url)
        self.assertEqual(response.status_code, 401)

    def test_seeded_catalogue_returns_published_summaries_only(self):
        response = self.client.get(self.list_url)

        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.data), 11)
        self.assertEqual(response.data[0]['slug'], 'david-and-goliath')
        self.assertNotIn('body', response.data[0])
        self.assertNotIn('narrations', response.data[0])
        self.assertEqual(
            {
                story['slug']: story['cover_asset_key']
                for story in response.data
            },
            {
                'david-and-goliath': (
                    'assets/images/stories/david-and-goliath-v2.webp'
                ),
                'jonah-and-the-big-fish': (
                    'assets/images/stories/jonah-and-the-big-fish-v2.webp'
                ),
                'crossing-the-red-sea': (
                    'assets/images/stories/crossing-the-red-sea-v2.webp'
                ),
                'noah-builds-the-ark': (
                    'assets/images/stories/noah-builds-the-ark-v2.webp'
                ),
                'creation-week': 'assets/images/stories/creation-week-v2.webp',
                'daniel-in-the-lions-den': (
                    'assets/images/stories/daniel-in-the-lions-den-v2.webp'
                ),
                'moses-follows-god': (
                    'assets/images/stories/moses-follows-god-v2.webp'
                ),
                'esther-speaks-up': (
                    'assets/images/stories/esther-speaks-up-v2.webp'
                ),
                'joseph-colorful-coat': 'assets/images/stories/joseph-colorful-coat-storybook-v1.webp',
                'walls-of-jericho': 'assets/images/stories/walls-of-jericho-storybook-v1.webp',
                'ruth-and-naomi': 'assets/images/stories/ruth-and-naomi-storybook-v1.webp',
            },
        )
        self.assertTrue(
            all(
                story['cover_focus_x'] == 0 and story['cover_focus_y'] == 0
                for story in response.data
            )
        )
        self.assertIsNone(response.data[0]['cover_image_url'])
        self.assertTrue(response.data[0]['is_featured'])
        self.assertEqual(response.data[0]['estimated_read_seconds'], 120)
        self.assertEqual(NarratorVoice.objects.count(), 3)
        self.assertEqual(StoryNarration.objects.count(), 39)

    def test_detail_returns_body_and_safe_character_narration_metadata(self):
        narrator = NarratorVoice.objects.get(avatar_key='lion')
        narrator.provider = 'private-provider'
        narrator.provider_voice_id = 'do-not-leak-this-id'
        narrator.save(update_fields=('provider', 'provider_voice_id'))

        response = self.client.get('/api/stories/david-and-goliath/')

        self.assertEqual(response.status_code, 200)
        self.assertIn('small hands can do brave things', response.data['body'])
        self.assertEqual(len(response.data['narrations']), 3)
        kai = next(
            item
            for item in response.data['narrations']
            if item['avatar_key'] == 'lion'
        )
        self.assertEqual(kai['voice_key'], 'kai')
        self.assertEqual(kai['character_name'], 'Kai')
        self.assertEqual(kai['status'], 'device_tts')
        self.assertFalse(kai['audio_available'])
        self.assertIsNone(kai['sample_url'])
        self.assertIsNone(kai['audio_url'])
        self.assertNotIn('provider', kai)
        self.assertNotIn('provider_voice_id', kai)

    def test_detail_exposes_absolute_cached_round_one_sample_urls(self):
        with TemporaryDirectory() as media_root, override_settings(
            MEDIA_ROOT=media_root,
            DEBUG=True,
        ):
            write_fake_round_one_samples(media_root)
            call_command('install_round_one_voice_samples', stdout=StringIO())

            response = self.client.get(
                '/api/stories/david-and-goliath/',
                HTTP_HOST='10.166.184.140:8000',
            )

        self.assertEqual(response.status_code, 200)
        samples = {
            item['avatar_key']: item['sample_url']
            for item in response.data['narrations']
        }
        self.assertEqual(
            samples,
            {
                'lion': (
                    'http://10.166.184.140:8000/media/voice_auditions/'
                    'kai_a_cedar.mp3'
                ),
                'dove': (
                    'http://10.166.184.140:8000/media/voice_auditions/'
                    'nia_a_marin.mp3'
                ),
                'rainbow': (
                    'http://10.166.184.140:8000/media/voice_auditions/'
                    'zuri_a_coral.mp3'
                ),
            },
        )
        self.assertTrue(
            all(
                'provider' not in item and 'provider_voice_id' not in item
                for item in response.data['narrations']
            )
        )
        self.assertTrue(
            all(
                item['status'] == StoryNarration.Status.DEVICE_TTS
                for item in response.data['narrations']
            )
        )

    def test_detail_does_not_advertise_a_deleted_cached_sample(self):
        narrator = NarratorVoice.objects.get(avatar_key='lion')
        narrator.sample_audio.name = 'voice_auditions/kai_a_cedar.mp3'
        narrator.save(update_fields=('sample_audio',))

        with TemporaryDirectory() as media_root, override_settings(
            MEDIA_ROOT=media_root,
        ):
            response = self.client.get('/api/stories/david-and-goliath/')

        kai = next(
            item
            for item in response.data['narrations']
            if item['avatar_key'] == 'lion'
        )
        self.assertIsNone(kai['sample_url'])

    @override_settings(CONTENT_MEDIA_HOSTS=('media.example.test',))
    def test_missing_cached_sample_falls_back_to_hosted_sample_url(self):
        narrator = NarratorVoice.objects.get(avatar_key='lion')
        narrator.sample_audio.name = 'voice_auditions/missing.mp3'
        narrator.sample_url = 'https://media.example.test/kai-sample.mp3'
        narrator.save(update_fields=('sample_audio', 'sample_url'))

        with TemporaryDirectory() as media_root, override_settings(
            MEDIA_ROOT=media_root,
        ):
            response = self.client.get('/api/stories/david-and-goliath/')

        kai = next(
            item
            for item in response.data['narrations']
            if item['avatar_key'] == 'lion'
        )
        self.assertEqual(
            kai['sample_url'],
            'https://media.example.test/kai-sample.mp3',
        )

    def test_detail_hides_inactive_and_unavailable_narrators(self):
        story = Story.objects.get(slug='david-and-goliath')
        inactive = NarratorVoice.objects.get(avatar_key='dove')
        inactive.is_active = False
        inactive.save(update_fields=('is_active',))
        unavailable = StoryNarration.objects.get(
            story=story,
            narrator__avatar_key='rainbow',
        )
        unavailable.status = StoryNarration.Status.UNAVAILABLE
        unavailable.save(update_fields=('status',))

        response = self.client.get('/api/stories/david-and-goliath/')

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            [item['avatar_key'] for item in response.data['narrations']],
            ['lion'],
        )

    def test_catalogue_search_category_filter_and_published_visibility(self):
        Story.objects.create(
            slug='hidden-draft',
            title='Hidden Draft',
            category='Mercy',
            summary='Not ready.',
            body='Not ready.',
            is_published=False,
        )

        search = self.client.get(self.list_url, {'search': 'fish'})
        self.assertEqual(search.status_code, 200)
        self.assertEqual(
            [story['slug'] for story in search.data],
            ['jonah-and-the-big-fish'],
        )

        category = self.client.get(self.list_url, {'category': 'mercy'})
        self.assertEqual(category.status_code, 200)
        self.assertEqual(
            [story['slug'] for story in category.data],
            ['jonah-and-the-big-fish'],
        )
        self.assertEqual(
            self.client.get('/api/stories/hidden-draft/').status_code,
            404,
        )

    def test_catalogue_rejects_unbounded_search_and_category_values(self):
        self.assertEqual(
            self.client.get(self.list_url, {'search': 'x' * 101}).status_code,
            400,
        )
        self.assertEqual(
            self.client.get(self.list_url, {'category': 'x' * 81}).status_code,
            400,
        )

    @override_settings(CONTENT_MEDIA_HOSTS=('cdn.kingdom.test',))
    def test_child_facing_media_requires_https_on_an_owned_host(self):
        allowed = Story(
            slug='allowed-media',
            title='Allowed media',
            category='Faith',
            summary='Safe.',
            body='Safe.',
            cover_image_url='https://cdn.kingdom.test/story.webp',
        )
        allowed.full_clean()

        allowed.cover_image_url = 'http://cdn.kingdom.test/story.webp'
        with self.assertRaises(ValidationError):
            allowed.full_clean()

        allowed.cover_image_url = 'https://tracking.example/story.webp'
        with self.assertRaises(ValidationError):
            allowed.full_clean()

        for unsafe_owned_url in (
            'https://user:password@cdn.kingdom.test/story.webp',
            'https://cdn.kingdom.test:8443/story.webp',
            'https://cdn.kingdom.test/story.webp#hidden-target',
        ):
            with self.subTest(url=unsafe_owned_url):
                allowed.cover_image_url = unsafe_owned_url
                with self.assertRaises(ValidationError):
                    allowed.full_clean()

    def test_narrator_upload_rejects_a_spoofed_audio_extension(self):
        narrator = NarratorVoice(
            avatar_key='owl',
            voice_key='owl-voice',
            display_name='Ollie',
            voice_description='Warm',
            sample_audio=SimpleUploadedFile(
                'not-really-audio.mp3',
                b'this is not an audio file',
                content_type='audio/mpeg',
            ),
        )

        with self.assertRaises(ValidationError):
            narrator.full_clean()

    def test_unsafe_stored_media_is_never_serialized(self):
        story = Story.objects.get(slug='david-and-goliath')
        story.cover_image_url = 'https://tracking.example/story.webp'
        story.save(update_fields=('cover_image_url',))
        narration = StoryNarration.objects.get(
            story=story,
            narrator__avatar_key='lion',
        )
        narration.status = StoryNarration.Status.READY
        narration.audio_url = 'https://tracking.example/story.mp3'
        narration.save(update_fields=('status', 'audio_url'))

        response = self.client.get('/api/stories/david-and-goliath/')

        self.assertEqual(response.status_code, 200)
        self.assertIsNone(response.data['cover_image_url'])
        kai = next(
            item
            for item in response.data['narrations']
            if item['avatar_key'] == 'lion'
        )
        self.assertFalse(kai['audio_available'])
        self.assertIsNone(kai['audio_url'])

    def test_story_and_narrator_pair_is_unique(self):
        story = Story.objects.get(slug='david-and-goliath')
        narrator = NarratorVoice.objects.get(avatar_key='lion')

        with self.assertRaises(IntegrityError), transaction.atomic():
            StoryNarration.objects.create(story=story, narrator=narrator)


class RoundOneVoiceSampleCommandTests(TestCase):
    def test_command_attaches_all_three_samples_and_is_idempotent(self):
        with TemporaryDirectory() as media_root, override_settings(
            MEDIA_ROOT=media_root,
        ):
            write_fake_round_one_samples(media_root)
            first_output = StringIO()
            call_command(
                'install_round_one_voice_samples',
                stdout=first_output,
            )
            call_command(
                'install_round_one_voice_samples',
                stdout=StringIO(),
            )

        self.assertIn('Round 1 samples ready', first_output.getvalue())
        for avatar_key, (filename, provider_voice_id) in ROUND_ONE_FILES.items():
            narrator = NarratorVoice.objects.get(avatar_key=avatar_key)
            self.assertEqual(
                narrator.sample_audio.name,
                f'voice_auditions/{filename}',
            )
            self.assertEqual(narrator.provider, 'openai')
            self.assertEqual(narrator.provider_voice_id, provider_voice_id)

    def test_command_fails_atomically_when_any_file_is_missing(self):
        with TemporaryDirectory() as media_root, override_settings(
            MEDIA_ROOT=media_root,
        ):
            write_fake_round_one_samples(media_root, only={'lion'})

            with self.assertRaisesMessage(
                CommandError,
                'nia_a_marin.mp3: file is missing',
            ):
                call_command(
                    'install_round_one_voice_samples',
                    stdout=StringIO(),
                )

        for narrator in NarratorVoice.objects.all():
            self.assertFalse(narrator.sample_audio)
            self.assertEqual(narrator.provider, '')
            self.assertEqual(narrator.provider_voice_id, '')

    def test_command_rejects_a_non_mp3_payload(self):
        with TemporaryDirectory() as media_root, override_settings(
            MEDIA_ROOT=media_root,
        ):
            write_fake_round_one_samples(media_root)
            bad_file = Path(media_root) / 'voice_auditions' / 'kai_a_cedar.mp3'
            bad_file.write_bytes(b'not-an-mp3' * 200)

            with self.assertRaisesMessage(
                CommandError,
                'kai_a_cedar.mp3: file does not have an MP3 signature',
            ):
                call_command(
                    'install_round_one_voice_samples',
                    stdout=StringIO(),
                )

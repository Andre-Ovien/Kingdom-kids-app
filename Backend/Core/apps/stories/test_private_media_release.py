import copy
from io import StringIO
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import patch

from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import TestCase, override_settings

from apps.games.models import Game, GameLevel
from apps.stories.management.commands import install_private_media_release as release
from apps.stories.models import NarratorVoice, Story, StoryNarration
from apps.stories.serializers import StoryNarrationSerializer


class PrivateMediaReleaseTests(TestCase):
    """The test runner applies the complete real migration graph, not fixtures."""

    def install(self, **kwargs):
        call_command('install_private_media_release', stdout=StringIO(), **kwargs)

    def snapshot(self):
        return (list(NarratorVoice.objects.order_by('pk').values()),
                list(StoryNarration.objects.order_by('pk').values()))

    def test_fresh_migrations_matching_and_private_release_resolve_without_local_audio(self):
        call_command('install_published_matching_release', apply=True, publish=True, stdout=StringIO())
        with patch('django.core.files.storage.FileSystemStorage.exists', side_effect=AssertionError('No local media')):
            self.install()
            before = self.snapshot()
            self.install()
            self.assertEqual(self.snapshot(), before)
            self.assertEqual(Game.objects.filter(is_published=True).count(), 15)
            self.assertEqual(GameLevel.objects.filter(game__is_published=True).count(), 45)
            tracks = StoryNarration.objects.filter(status='ready').select_related('story', 'narrator')
            self.assertEqual(tracks.count(), 33)
            self.assertEqual(len({row.story_id for row in tracks}), 11)
            self.assertEqual(NarratorVoice.objects.exclude(sample_audio='').count(), 3)
            media_map = json.loads(release.MAP_PATH.read_bytes())
            request = SimpleNamespace(
                user=SimpleNamespace(is_authenticated=True, is_active=True, is_email_verified=True),
                build_absolute_uri=lambda url: url,
            )
            with override_settings(
                CLOUDINARY_PRIVATE_DELIVERY_ENABLED=True,
                CLOUDINARY_CLOUD_NAME=media_map['cloud_name'], CLOUDINARY_API_KEY='1234567890',
                CLOUDINARY_API_SECRET='synthetic-test-secret-not-a-provider-key',
                CLOUDINARY_PRIVATE_MEDIA_MAP=release.MAP_PATH,
                CLOUDINARY_PRIVATE_MEDIA_MAP_SHA256=release.MAP_SHA256,
                CLOUDINARY_PRIVATE_URL_TTL_SECONDS=300,
                CONTENT_MEDIA_HOSTS=('api.cloudinary.com',), PAID_CONTENT_ENFORCEMENT_ENABLED=False,
            ):
                data = StoryNarrationSerializer(tracks, many=True, context={'request': request}).data
            self.assertEqual(len(data), 33)
            for row in data:
                self.assertTrue(row['audio_available'])
                self.assertTrue(row['audio_url'].startswith('https://api.cloudinary.com/'))
                self.assertTrue(row['sample_url'].startswith('https://api.cloudinary.com/'))
                self.assertTrue(row['segments'])
                self.assertTrue(row['words'])
            self.assertFalse(StoryNarration.objects.exclude(audio_url__isnull=True).exists())
            self.assertFalse(NarratorVoice.objects.exclude(sample_url__isnull=True).exists())

    def test_dry_run_has_no_writes(self):
        before = self.snapshot()
        self.install(dry_run=True)
        self.assertEqual(self.snapshot(), before)

    def test_late_story_revision_rejects_complete_release_without_writes(self):
        slug = release._read_manifest()['tracks'][-1]['story_slug']
        Story.objects.filter(slug=slug).update(body='An edited story revision.')
        before = self.snapshot()
        with self.assertRaisesMessage(CommandError, 'current story text'):
            self.install()
        self.assertEqual(self.snapshot(), before)

    def test_unpublished_story_and_inactive_voice_are_not_changed(self):
        slug = release._read_manifest()['tracks'][0]['story_slug']
        Story.objects.filter(slug=slug).update(is_published=False)
        before = self.snapshot()
        with self.assertRaises(CommandError):
            self.install()
        self.assertEqual(self.snapshot(), before)
        Story.objects.filter(slug=slug).update(is_published=True)
        NarratorVoice.objects.filter(pk='lion').update(is_active=False)
        before = self.snapshot()
        with self.assertRaises(CommandError):
            self.install()
        self.assertEqual(self.snapshot(), before)

    def test_both_packaged_metadata_checksums_are_required(self):
        before = self.snapshot()
        with TemporaryDirectory() as folder:
            bad = Path(folder) / 'metadata.json'
            bad.write_text('{}')
            for constant in ('MANIFEST_PATH', 'MAP_PATH'):
                with self.subTest(constant=constant), patch.object(release, constant, bad):
                    with self.assertRaisesMessage(CommandError, 'checksum'):
                        self.install()
        self.assertEqual(self.snapshot(), before)

    def test_alias_use_and_measured_word_validation_fail_before_writes(self):
        before = self.snapshot()
        manifest = release._read_manifest()
        for mutation in ('words', 'alias'):
            changed = copy.deepcopy(manifest)
            if mutation == 'words':
                changed['tracks'][-1]['words'][-1]['end_offset'] += 1
            else:
                changed['tracks'][-1]['file'] = changed['tracks'][0]['file']
            with self.subTest(mutation=mutation), patch.object(release, '_read_manifest', return_value=changed):
                with self.assertRaises(CommandError):
                    self.install()
            self.assertEqual(self.snapshot(), before)

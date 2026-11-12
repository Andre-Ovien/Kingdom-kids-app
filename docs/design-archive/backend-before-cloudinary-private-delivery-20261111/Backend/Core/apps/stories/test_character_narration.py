import copy
import hashlib
import json
import math
import wave
from io import StringIO
from pathlib import Path, PurePosixPath
import shlex
from tempfile import TemporaryDirectory
from unittest.mock import patch

from django.core.files.storage import FileSystemStorage
from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import SimpleTestCase, TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from apps.accounts.models import User

from .models import NarratorVoice, Story, StoryNarration
from .narration import validated_narration_segments


FIRST_PASSAGE = 'Kai smiled 🌈.'
SECOND_PASSAGE = 'Nia sang.'
STORY_BODY = f'{FIRST_PASSAGE}\n\n{SECOND_PASSAGE}'
AUDIO_DURATION = 0.2


def utf16_length(text):
    return len(text.encode('utf-16-le')) // 2


def measured_segments():
    second_start = utf16_length(FIRST_PASSAGE + '\n\n')
    return [
        {
            'text': FIRST_PASSAGE,
            'start_offset': 0,
            'end_offset': utf16_length(FIRST_PASSAGE),
            'start_seconds': 0,
            'end_seconds': 0.08,
        },
        {
            'text': SECOND_PASSAGE,
            'start_offset': second_start,
            'end_offset': utf16_length(STORY_BODY),
            'start_seconds': 0.08,
            'end_seconds': 0.16,
        },
    ]


def measured_words():
    # Deliberately varied durations and a silence gap between passages.
    words = (
        ('Kai', 0, 0.012),
        ('smiled', 0.012, 0.054),
        ('🌈.', 0.054, 0.08),
        ('Nia', 0.10, 0.12),
        ('sang.', 0.12, 0.16),
    )
    result = []
    cursor = 0
    for text, start, end in words:
        offset = STORY_BODY.index(text, cursor)
        result.append({
            'text': text,
            'start_offset': utf16_length(STORY_BODY[:offset]),
            'end_offset': utf16_length(STORY_BODY[:offset + len(text)]),
            'start_seconds': start,
            'end_seconds': end,
        })
        cursor = offset + len(text)
    return result


def delayed_words():
    cues = measured_words()
    times = ((0.085, 0.09), (0.09, 0.105), (0.105, 0.12), (0.12, 0.14), (0.14, 0.16))
    for cue, (start, end) in zip(cues, times):
        cue.update(start_seconds=start, end_seconds=end)
    return cues


def write_tiny_wav(media_root, filename):
    """Write a decodable 200 ms PCM fixture without any voice provider."""
    path = Path(media_root) / filename
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), 'wb') as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(8000)
        output.writeframes(b'\x00\x00' * 1600)
    return path


def create_test_story():
    return Story.objects.create(
        slug='character-narration-regression',
        title='Character narration regression',
        category='Faith',
        summary='A short passage fixture.',
        body=STORY_BODY,
    )


class CharacterNarrationApiTests(TestCase):
    def setUp(self):
        media_directory = TemporaryDirectory()
        self.addCleanup(media_directory.cleanup)
        self.media_root = media_directory.name
        settings_override = override_settings(
            MEDIA_ROOT=self.media_root,
            MEDIA_URL='/media/',
            DEBUG=True,
            ALLOWED_HOSTS=('testserver',),
            CONTENT_MEDIA_HOSTS=('cdn.kingdom.test',),
        )
        settings_override.enable()
        self.addCleanup(settings_override.disable)

        self.story = create_test_story()
        self.audio_name = 'character_narration/kai-regression.wav'
        self.audio_path = write_tiny_wav(self.media_root, self.audio_name)
        self.narration = StoryNarration.objects.create(
            story=self.story,
            narrator=NarratorVoice.objects.get(avatar_key='lion'),
            status=StoryNarration.Status.READY,
            audio_file=self.audio_name,
            text_sha256=hashlib.sha256(STORY_BODY.encode('utf-8')).hexdigest(),
            duration_seconds=1,
            segments=measured_segments(),
            words=measured_words(),
        )
        parent = User.objects.create_user(
            email='character-reader@example.com',
            password='A-strong-password-123!',
            email_verified_at=timezone.now(),
        )
        self.client = APIClient()
        token = RefreshToken.for_user(parent).access_token
        self.client.credentials(HTTP_AUTHORIZATION=f'Bearer {token}')

    def narration_response(self):
        response = self.client.get(f'/api/stories/{self.story.slug}/')
        self.assertEqual(response.status_code, 200)
        return next(
            item for item in response.data['narrations']
            if item['avatar_key'] == 'lion'
        )

    def assert_not_playable(self, narration):
        self.assertFalse(narration['audio_available'])
        self.assertIsNone(narration['audio_url'])
        self.assertEqual(narration['segments'], [])
        self.assertEqual(narration['words'], [])

    def test_debug_detail_exposes_absolute_cached_track_and_measured_passages(self):
        data = self.narration_response()

        self.assertEqual(data['status'], StoryNarration.Status.READY)
        self.assertTrue(data['audio_available'])
        self.assertEqual(
            data['audio_url'],
            'http://testserver/media/character_narration/kai-regression.wav',
        )
        self.assertEqual(data['segments'], measured_segments())
        self.assertEqual(data['words'], measured_words())
        for private_field in ('audio_file', 'text_sha256', 'provider', 'provider_voice_id'):
            self.assertNotIn(private_field, data)

    def test_production_hides_a_local_track_and_local_audition(self):
        narrator = self.narration.narrator
        narrator.sample_audio.name = self.audio_name
        narrator.save(update_fields=('sample_audio',))

        with override_settings(DEBUG=False):
            data = self.narration_response()

        self.assert_not_playable(data)
        self.assertIsNone(data['sample_url'])

    def test_deleted_cached_track_does_not_advertise_playable_metadata(self):
        self.audio_path.unlink()

        self.assert_not_playable(self.narration_response())

    def test_edited_story_hides_stale_track_and_measured_passages(self):
        self.story.body = STORY_BODY + ' A new ending.'
        self.story.save(update_fields=('body',))

        self.assert_not_playable(self.narration_response())

    def test_cached_track_requires_an_exact_body_hash(self):
        self.narration.text_sha256 = ''
        self.narration.save(update_fields=('text_sha256',))

        self.assert_not_playable(self.narration_response())

    def test_non_ready_track_does_not_advertise_playable_metadata(self):
        for status in (StoryNarration.Status.DEVICE_TTS, StoryNarration.Status.PROCESSING):
            with self.subTest(status=status):
                self.narration.status = status
                self.narration.save(update_fields=('status',))
                self.assert_not_playable(self.narration_response())

    def test_production_accepts_owned_https_cached_file_storage(self):
        storage = FileSystemStorage(
            location=self.media_root,
            base_url='https://cdn.kingdom.test/audio/',
        )
        field = StoryNarration._meta.get_field('audio_file')
        with override_settings(DEBUG=False), patch.object(field, 'storage', storage):
            data = self.narration_response()

        self.assertTrue(data['audio_available'])
        self.assertEqual(
            data['audio_url'],
            'https://cdn.kingdom.test/audio/character_narration/kai-regression.wav',
        )
        self.assertEqual(data['segments'], measured_segments())

    def test_production_accepts_a_cached_audition_on_owned_https_storage(self):
        narrator = self.narration.narrator
        narrator.sample_audio.name = self.audio_name
        narrator.save(update_fields=('sample_audio',))
        storage = FileSystemStorage(
            location=self.media_root,
            base_url='https://cdn.kingdom.test/audio/',
        )
        field = NarratorVoice._meta.get_field('sample_audio')

        with override_settings(DEBUG=False), patch.object(field, 'storage', storage):
            data = self.narration_response()

        self.assertEqual(
            data['sample_url'],
            'https://cdn.kingdom.test/audio/character_narration/kai-regression.wav',
        )

    def test_owned_hosted_track_falls_back_when_cached_file_is_missing(self):
        self.audio_path.unlink()
        self.narration.audio_url = 'https://cdn.kingdom.test/kai-regression.wav'
        self.narration.save(update_fields=('audio_url',))

        with override_settings(DEBUG=False):
            data = self.narration_response()

        self.assertTrue(data['audio_available'])
        self.assertEqual(data['audio_url'], self.narration.audio_url)
        self.assertEqual(data['segments'], measured_segments())

    def test_stale_hosted_track_is_hidden_after_body_changes(self):
        self.narration.audio_url = 'https://cdn.kingdom.test/kai-regression.wav'
        self.narration.save(update_fields=('audio_url',))
        self.story.body = 'A replacement story.'
        self.story.save(update_fields=('body',))

        with override_settings(DEBUG=False):
            self.assert_not_playable(self.narration_response())

    def test_production_rejects_unsafe_stored_hosted_urls(self):
        unsafe_urls = (
            'http://cdn.kingdom.test/kai.wav',
            'https://unowned.example/kai.wav',
            'https://user:password@cdn.kingdom.test/kai.wav',
            'https://cdn.kingdom.test:8443/kai.wav',
            'https://cdn.kingdom.test/kai.wav#hidden-target',
        )
        with override_settings(DEBUG=False):
            for url in unsafe_urls:
                with self.subTest(url=url):
                    self.narration.audio_url = url
                    self.narration.save(update_fields=('audio_url',))
                    self.assert_not_playable(self.narration_response())

    def test_invalid_stored_passage_text_is_not_exposed_for_highlighting(self):
        segments = measured_segments()
        segments[0]['text'] = 'Different words.'
        self.narration.segments = segments
        self.narration.save(update_fields=('segments',))

        data = self.narration_response()

        self.assertTrue(data['audio_available'])
        self.assertEqual(data['segments'], [])
        self.assertEqual(data['words'], [])

    def test_invalid_word_text_is_hidden_without_hiding_playable_audio(self):
        words = measured_words()
        words[0]['text'] = 'Different'
        self.narration.words = words
        self.narration.save(update_fields=('words',))

        data = self.narration_response()

        self.assertTrue(data['audio_available'])
        self.assertEqual(data['segments'], measured_segments())
        self.assertEqual(data['words'], [])

    def test_older_tracks_do_not_invent_word_cues(self):
        self.narration.words = []
        self.narration.save(update_fields=('words',))

        data = self.narration_response()

        self.assertTrue(data['audio_available'])
        self.assertEqual(data['segments'], measured_segments())
        self.assertEqual(data['words'], [])

    def test_incomplete_stored_words_do_not_expose_partial_highlighting(self):
        words = measured_words()
        del words[1]
        self.narration.words = words
        self.narration.save(update_fields=('words',))

        data = self.narration_response()

        self.assertTrue(data['audio_available'])
        self.assertEqual(data['words'], [])

    def test_words_timed_in_another_paragraph_do_not_expose_misaligned_highlighting(self):
        words = delayed_words()
        self.assertEqual(validated_narration_segments(words, STORY_BODY, AUDIO_DURATION), words)
        self.narration.words = words
        self.narration.save(update_fields=('words',))

        data = self.narration_response()

        self.assertTrue(data['audio_available'])
        self.assertEqual(data['words'], [])

    def test_unmounted_cached_storage_does_not_fail_story_detail(self):
        field = StoryNarration._meta.get_field('audio_file')
        with patch.object(field.storage, 'exists', side_effect=OSError('storage unavailable')):
            self.assert_not_playable(self.narration_response())


class NarrationSegmentValidationTests(SimpleTestCase):
    def test_exact_passages_use_utf16_offsets_and_retain_measured_times(self):
        self.assertGreater(utf16_length(FIRST_PASSAGE), len(FIRST_PASSAGE))
        self.assertEqual(
            validated_narration_segments(measured_segments(), STORY_BODY, AUDIO_DURATION),
            measured_segments(),
        )

    def test_boundaries_cannot_split_an_emoji_surrogate_pair(self):
        emoji_start = utf16_length('Kai smiled ')
        for start, end in ((emoji_start, emoji_start + 1), (emoji_start + 1, emoji_start + 2)):
            with self.subTest(start=start, end=end):
                segment = {
                    'text': '🌈',
                    'start_offset': start,
                    'end_offset': end,
                    'start_seconds': 0,
                    'end_seconds': 0.1,
                }
                self.assertEqual(
                    validated_narration_segments([segment], STORY_BODY, AUDIO_DURATION),
                    [],
                )

    def test_text_must_match_the_exact_story_slice(self):
        segments = measured_segments()
        segments[0]['text'] = FIRST_PASSAGE.replace('smiled', 'grinned')

        self.assertEqual(
            validated_narration_segments(segments, STORY_BODY, AUDIO_DURATION),
            [],
        )

    def test_reversed_or_overlapping_text_and_time_ranges_are_rejected(self):
        reversed_passages = list(reversed(measured_segments()))
        overlapping_text = measured_segments()
        overlapping_text[1]['start_offset'] = 0
        overlapping_text[1]['end_offset'] = utf16_length(FIRST_PASSAGE)
        overlapping_text[1]['text'] = FIRST_PASSAGE
        overlapping_time = measured_segments()
        overlapping_time[1]['start_seconds'] = 0.04
        beyond_duration = measured_segments()
        beyond_duration[1]['end_seconds'] = AUDIO_DURATION + 0.01
        for segments in (reversed_passages, overlapping_text, overlapping_time, beyond_duration):
            with self.subTest(segments=segments):
                self.assertEqual(
                    validated_narration_segments(segments, STORY_BODY, AUDIO_DURATION),
                    [],
                )

    def test_nonfinite_and_untyped_offsets_and_times_are_rejected(self):
        invalid_values = (
            ('start_offset', True),
            ('end_offset', 14.0),
            ('start_seconds', False),
            ('end_seconds', '0.08'),
            ('start_seconds', math.nan),
            ('end_seconds', math.inf),
        )
        for field, value in invalid_values:
            with self.subTest(field=field, value=value):
                segments = measured_segments()
                segments[0][field] = value
                self.assertEqual(
                    validated_narration_segments(segments, STORY_BODY, AUDIO_DURATION),
                    [],
                )


class CharacterNarrationInstallCommandTests(TestCase):
    def setUp(self):
        media_directory = TemporaryDirectory()
        self.addCleanup(media_directory.cleanup)
        self.media_root = media_directory.name
        settings_override = override_settings(MEDIA_ROOT=self.media_root, DEBUG=True)
        settings_override.enable()
        self.addCleanup(settings_override.disable)

        self.story = create_test_story()
        self.narrator = NarratorVoice.objects.get(avatar_key='lion')
        self.narrator.sample_audio.name = 'voice_auditions/original.wav'
        self.narrator.provider = 'previous-provider'
        self.narrator.provider_voice_id = 'previous-voice'
        self.narrator.save(update_fields=('sample_audio', 'provider', 'provider_voice_id'))
        write_tiny_wav(self.media_root, self.narrator.sample_audio.name)
        self.narration = StoryNarration.objects.create(
            story=self.story,
            narrator=self.narrator,
            status=StoryNarration.Status.DEVICE_TTS,
        )
        self.sample_name = 'voice_auditions/kai-synthetic.wav'
        self.track_name = 'character_narration/kai-story.wav'
        self.sample_path = write_tiny_wav(self.media_root, self.sample_name)
        self.track_path = write_tiny_wav(self.media_root, self.track_name)
        self.manifest_path = Path(self.media_root) / 'synthetic-manifest.json'

    def audio_record(self, filename):
        return {
            'character': 'kai',
            'avatar_key': 'lion',
            'file': filename,
            'duration_seconds': AUDIO_DURATION,
            'sha256': hashlib.sha256((Path(self.media_root) / filename).read_bytes()).hexdigest(),
        }

    def manifest(self):
        return {
            'version': 1,
            'source': 'description-only synthetic',
            'auditions': [self.audio_record(self.sample_name)],
            'tracks': [{
                **self.audio_record(self.track_name),
                'story_slug': self.story.slug,
                'text_sha256': hashlib.sha256(STORY_BODY.encode('utf-8')).hexdigest(),
                'segments': measured_segments(),
            }],
        }

    def install(self, manifest, **options):
        self.manifest_path.write_text(json.dumps(manifest), encoding='utf-8')
        output = StringIO()
        call_command(
            'install_character_narration',
            manifest=self.manifest_path,
            stdout=output,
            **options,
        )
        return output.getvalue()

    def catalogue_snapshot(self):
        return (
            list(NarratorVoice.objects.order_by('pk').values(
                'pk', 'sample_audio', 'sample_url', 'provider', 'provider_voice_id', 'updated_at',
            )),
            list(StoryNarration.objects.filter(story=self.story).order_by('pk').values(
                'pk', 'narrator_id', 'status', 'audio_file', 'audio_url',
                'duration_seconds', 'text_sha256', 'segments', 'words', 'updated_at',
            )),
        )

    def assert_rejected_without_catalogue_changes(self, manifest):
        before = self.catalogue_snapshot()
        with self.assertRaises(CommandError):
            self.install(manifest)
        self.assertEqual(self.catalogue_snapshot(), before)

    def test_complete_matching_track_and_sample_are_installed_idempotently(self):
        manifest = self.manifest()

        output = self.install(manifest)
        self.install(manifest)

        self.narrator.refresh_from_db()
        self.narration.refresh_from_db()
        self.assertIn('Installed 1 character samples and 1 story tracks.', output)
        self.assertEqual(self.narrator.sample_audio.name, self.sample_name)
        self.assertEqual(self.narrator.provider, 'qwen3-tts-local')
        self.assertEqual(self.narrator.provider_voice_id, 'kai-synthetic-v1')
        self.assertEqual(StoryNarration.objects.filter(story=self.story).count(), 1)
        self.assertEqual(self.narration.status, StoryNarration.Status.READY)
        self.assertEqual(self.narration.audio_file.name, self.track_name)
        self.assertIsNone(self.narration.audio_url)
        self.assertEqual(self.narration.duration_seconds, 1)
        self.assertEqual(self.narration.text_sha256, manifest['tracks'][0]['text_sha256'])
        self.assertEqual(self.narration.segments, measured_segments())
        self.assertEqual(self.narration.words, [])
        self.assertTrue(self.narration.audio_available)
        self.assertTrue(self.narration.matches_story_text)

    def test_word_timings_preserve_exact_unicode_text_and_nonuniform_pace(self):
        manifest = self.manifest()
        manifest['tracks'][0]['words'] = measured_words()

        self.install(manifest)

        self.narration.refresh_from_db()
        self.assertEqual(self.narration.words, measured_words())
        self.assertEqual(self.narration.segments, measured_segments())

    def test_measured_short_phrases_retain_their_exact_text_and_outer_boundaries(self):
        words = measured_words()
        phrase = {
            **words[0],
            'text': 'Kai smiled',
            'end_offset': words[1]['end_offset'],
            'end_seconds': words[1]['end_seconds'],
        }
        words = [phrase, *words[2:]]
        manifest = self.manifest()
        manifest['tracks'][0]['words'] = words

        self.install(manifest)

        self.narration.refresh_from_db()
        self.assertEqual(self.narration.words, words)

    def test_words_cannot_be_timed_in_a_different_recorded_paragraph(self):
        words = delayed_words()
        self.assertEqual(validated_narration_segments(words, STORY_BODY, AUDIO_DURATION), words)
        manifest = self.manifest()
        manifest['tracks'][0]['words'] = words

        self.assert_rejected_without_catalogue_changes(manifest)

    def test_partial_word_coverage_cannot_install_a_track_with_live_highlighting(self):
        for missing_index in (0, 1, 4):
            with self.subTest(missing_index=missing_index):
                manifest = self.manifest()
                words = measured_words()
                del words[missing_index]
                manifest['tracks'][0]['words'] = words
                self.assert_rejected_without_catalogue_changes(manifest)

    def test_invalid_word_text_or_time_does_not_partially_install_audio(self):
        wrong_text = measured_words()
        wrong_text[0]['text'] = 'Another'
        overlapping_times = measured_words()
        overlapping_times[1]['start_seconds'] = 0.005
        beyond_duration = measured_words()
        beyond_duration[-1]['end_seconds'] = AUDIO_DURATION + 0.01

        for words in (wrong_text, overlapping_times, beyond_duration, None):
            with self.subTest(words=words):
                manifest = self.manifest()
                manifest['tracks'][0]['words'] = words
                self.assert_rejected_without_catalogue_changes(manifest)

    def test_missing_or_spoofed_track_leaves_samples_and_tracks_unchanged(self):
        missing = self.manifest()
        missing['tracks'][0]['file'] = 'character_narration/missing.wav'
        spoofed = self.manifest()
        self.track_path.write_bytes(b'this is not WAV audio')
        spoofed['tracks'][0]['sha256'] = hashlib.sha256(self.track_path.read_bytes()).hexdigest()

        for manifest in (missing, spoofed):
            with self.subTest(file=manifest['tracks'][0]['file']):
                self.assert_rejected_without_catalogue_changes(manifest)

    def test_audio_digest_mismatch_leaves_samples_and_tracks_unchanged(self):
        manifest = self.manifest()
        manifest['tracks'][0]['sha256'] = '0' * 64

        self.assert_rejected_without_catalogue_changes(manifest)

    def test_different_story_revision_leaves_samples_and_tracks_unchanged(self):
        manifest = self.manifest()
        self.story.body += ' More story text.'
        self.story.save(update_fields=('body',))

        self.assert_rejected_without_catalogue_changes(manifest)

    def test_partial_story_coverage_cannot_install_a_ready_track(self):
        # Missing opening, ending, and middle prose must all fail, even when
        # the remaining text ranges and measured times are individually valid.
        omitted_opening = self.manifest()
        omitted_opening['tracks'][0]['segments'] = [measured_segments()[1]]
        omitted_ending = self.manifest()
        omitted_ending['tracks'][0]['segments'] = [measured_segments()[0]]
        omitted_middle = self.manifest()
        omitted_middle['tracks'][0]['segments'][0].update(
            text='Kai',
            end_offset=utf16_length('Kai'),
        )

        for manifest in (omitted_opening, omitted_ending, omitted_middle):
            with self.subTest(segments=manifest['tracks'][0]['segments']):
                self.assert_rejected_without_catalogue_changes(manifest)

    def test_wrong_passage_text_or_overlapping_times_do_not_install_samples(self):
        wrong_text = self.manifest()
        wrong_text['tracks'][0]['segments'][0]['text'] = 'Words from another story.'
        overlapping_times = self.manifest()
        overlapping_times['tracks'][0]['segments'][1]['start_seconds'] = 0.04

        for manifest in (wrong_text, overlapping_times):
            with self.subTest(segments=manifest['tracks'][0]['segments']):
                self.assert_rejected_without_catalogue_changes(manifest)

    def test_later_invalid_track_does_not_partially_install_earlier_track_or_sample(self):
        manifest = self.manifest()
        invalid_second_track = copy.deepcopy(manifest['tracks'][0])
        invalid_second_track.update(
            character='nia',
            avatar_key='dove',
            file='character_narration/missing-nia.wav',
        )
        manifest['tracks'].append(invalid_second_track)

        self.assert_rejected_without_catalogue_changes(manifest)

    def test_audio_paths_cannot_escape_media_root(self):
        manifest = self.manifest()
        manifest['tracks'][0]['file'] = '../outside.wav'

        self.assert_rejected_without_catalogue_changes(manifest)

    def test_manifest_must_be_original_synthetic_version_one(self):
        for field, value in (('source', 'copied voice'), ('version', 2)):
            with self.subTest(field=field):
                manifest = self.manifest()
                manifest[field] = value
                self.assert_rejected_without_catalogue_changes(manifest)

    def test_samples_only_does_not_touch_or_validate_story_tracks(self):
        manifest = self.manifest()
        manifest['tracks'][0]['file'] = 'character_narration/missing.wav'
        before_tracks = self.catalogue_snapshot()[1]

        output = self.install(manifest, samples_only=True)

        self.narrator.refresh_from_db()
        self.assertEqual(self.narrator.sample_audio.name, self.sample_name)
        self.assertEqual(self.catalogue_snapshot()[1], before_tracks)
        self.assertIn('Installed 1 character samples and 0 story tracks.', output)

    def test_local_and_hosted_dry_runs_validate_without_any_catalogue_write(self):
        before = self.catalogue_snapshot()
        self.assertIn('dry-run, no data changed', self.install(self.manifest(), dry_run=True))
        with override_settings(DEBUG=False, CONTENT_MEDIA_HOSTS=('media.release.test',)):
            self.assertIn('dry-run, no data changed', self.install(
                self.manifest(), dry_run=True, hosted_base_url='https://media.release.test/release-v1/'))
        self.assertEqual(self.catalogue_snapshot(), before)

    def test_hosted_output_preserves_ids_hashes_and_timings_and_serializes_without_local_files(self):
        from .serializers import StoryNarrationSerializer
        manifest = self.manifest()
        manifest['tracks'][0]['words'] = measured_words()
        track_id, story_id = self.narration.pk, self.story.pk
        with override_settings(DEBUG=False, CONTENT_MEDIA_HOSTS=('media.release.test',)):
            for _ in range(2):
                self.install(manifest, hosted_base_url='https://media.release.test/recordings/')
            self.narration.refresh_from_db(); self.narrator.refresh_from_db()
            self.assertEqual(self.narration.pk, track_id)
            self.assertEqual(self.narration.story_id, story_id)
            self.assertEqual(self.narration.audio_file.name, '')
            self.assertEqual(self.narrator.sample_audio.name, '')
            self.assertEqual(self.narration.audio_url, 'https://media.release.test/recordings/' + self.track_name)
            self.assertEqual(self.narrator.available_sample_url,
                             'https://media.release.test/recordings/' + self.sample_name)
            self.assertEqual(self.narration.text_sha256, manifest['tracks'][0]['text_sha256'])
            self.assertEqual(self.narration.words, measured_words())
            self.track_path.unlink(); self.sample_path.unlink()
            data = StoryNarrationSerializer(self.narration).data
            self.assertTrue(data['audio_available'])
            self.assertEqual(data['audio_url'], self.narration.audio_url)
            self.assertEqual(data['segments'], measured_segments())
            self.story.body += ' A different ending.'
            self.story.save(update_fields=('body',))
            self.narration.refresh_from_db()
            self.assertFalse(StoryNarrationSerializer(self.narration).data['audio_available'])

    def test_hosted_mode_still_rejects_missing_or_corrupt_staged_approved_bytes_atomically(self):
        missing = self.manifest()
        missing['tracks'][0]['file'] = 'missing.wav'
        corrupt = self.manifest()
        corrupt['tracks'][0]['sha256'] = '0' * 64
        before = self.catalogue_snapshot()
        with override_settings(CONTENT_MEDIA_HOSTS=('media.release.test',)):
            for manifest in (missing, corrupt):
                with self.assertRaises(CommandError):
                    self.install(manifest, hosted_base_url='https://media.release.test/')
                self.assertEqual(self.catalogue_snapshot(), before)

    def test_hosted_base_cannot_change_origin_include_credentials_or_unsafe_paths(self):
        invalid = [
            '', 'http://media.release.test/', 'https://unowned.release.test/',
            'https://user:password@media.release.test/', 'https://media.release.test:444/',
            'https://media.release.test/base?query=x', 'https://media.release.test/#fragment',
            'https://media.release.test/?', 'https://media.release.test/#',
            'https://media.release.test/a/../b/', 'https://media.release.test/%2e%2e/',
            'https://media.release.test//other/', 'https://media.release.test/\\escape/',
            'https://media.release.\ntest/',
            'https://media.release.test/' + 'segment' * 40 + '/',
        ]
        before = self.catalogue_snapshot()
        with override_settings(CONTENT_MEDIA_HOSTS=('media.release.test',)):
            for base in invalid:
                with self.subTest(base=base), self.assertRaises(CommandError):
                    self.install(self.manifest(), hosted_base_url=base)
                self.assertEqual(self.catalogue_snapshot(), before)

    def test_hosted_object_paths_reject_escapes_but_encode_unicode_and_spaces(self):
        before = self.catalogue_snapshot()
        with override_settings(CONTENT_MEDIA_HOSTS=('media.release.test',)):
            for path in ('//unowned.test/x.wav', '../outside.wav', './audio.wav',
                         'voice_auditions/../character_narration/kai-story.wav',
                         'file%2fescape.wav', 'folder\\escape.wav', 'x.wav?query', 'x.wav#fragment'):
                manifest = self.manifest(); manifest['tracks'][0]['file'] = path
                with self.subTest(path=path), self.assertRaises(CommandError):
                    self.install(manifest, hosted_base_url='https://media.release.test/')
                self.assertEqual(self.catalogue_snapshot(), before)
            filename = 'character_narration/Song 🌈.wav'
            write_tiny_wav(self.media_root, filename)
            manifest = self.manifest()
            manifest['tracks'][0].update(self.audio_record(filename))
            self.install(manifest, hosted_base_url='https://media.release.test/')
            self.narration.refresh_from_db()
            self.assertTrue(self.narration.audio_url.endswith('/Song%20%F0%9F%8C%88.wav'))


class PublishedNarrationReleaseMetadataTests(TestCase):
    def test_container_packages_only_intended_release_metadata_and_still_excludes_media(self):
        backend = Path(__file__).resolve().parents[3]
        approved = 'content/releases/character_narration_v1_manifest.json'
        self.assertIsInstance(json.loads((backend / approved).read_text()), dict)
        sources = []
        for line in (backend / 'Dockerfile').read_text().splitlines():
            instruction = line.strip().split(maxsplit=1)
            if instruction and instruction[0].upper() == 'COPY':
                operands = (json.loads(instruction[1]) if instruction[1].startswith('[')
                            else [item for item in shlex.split(instruction[1]) if not item.startswith('--')])
                sources.extend(PurePosixPath(item).as_posix() for item in operands[:-1])
        self.assertFalse(any(source == '.' or any(char in source for char in '*?[') for source in sources))
        self.assertEqual([source for source in sources if source == 'content' or source.startswith('content/')],
                         [approved])
        ignore_lines = [line.strip() for line in (backend / '.dockerignore').read_text().splitlines()
                        if line.strip() and not line.lstrip().startswith('#')]
        self.assertIn('media', ignore_lines)
        self.assertEqual([line for line in ignore_lines if line.lstrip('!').startswith('content')],
                         ['content/*', '!content/releases/', 'content/releases/*', '!' + approved])

    def test_reviewed_manifest_is_canonical_published_only_and_retains_repair_tracks(self):
        from .catalogue_policy import UNAVAILABLE_STORY_SLUGS
        from .narration import validated_narration_words
        path = Path(__file__).resolve().parents[3] / 'content/releases/character_narration_v1_manifest.json'
        raw = path.read_text()
        manifest = json.loads(raw)
        self.assertEqual(raw, json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + '\n')
        self.assertEqual(manifest['release_id'], 'published-character-narration-v1')
        stories = {story.slug: story for story in Story.objects.filter(is_published=True)
                   .exclude(slug__in=UNAVAILABLE_STORY_SLUGS)}
        self.assertEqual(len(stories), 11)
        self.assertEqual(len(manifest['tracks']), 33)
        self.assertEqual({(row['story_slug'], row['character']) for row in manifest['tracks']},
                         {(slug, character) for slug in stories for character in ('kai', 'nia', 'zuri')})
        self.assertEqual({row['character'] for row in manifest['auditions']}, {'kai', 'nia', 'zuri'})
        self.assertEqual(len(manifest['auditions']), 3)
        for row in manifest['tracks']:
            story = stories[row['story_slug']]
            self.assertEqual(row['text_sha256'], hashlib.sha256(story.body.encode()).hexdigest())
            segments = validated_narration_segments(row['segments'], story.body, row['duration_seconds'])
            self.assertEqual(segments, row['segments'])
            self.assertEqual(validated_narration_words(row['words'], story.body,
                             row['duration_seconds'], segments), row['words'])
        records = {(row['story_slug'], row['character']): row for row in manifest['tracks']}
        self.assertIn('nia-repair-902b38ce9db85e9a', records[('creation-week', 'nia')]['file'])
        self.assertIn('zuri-repair-3a7a56d2737c4892', records[('david-and-goliath', 'zuri')]['file'])
        self.assertIn('kai-repair-27987927cf7ece05', records[('ruth-and-naomi', 'kai')]['file'])
        self.assertEqual(records[('daniel-in-the-lions-den', 'zuri')]['sha256'],
                         'ff41c086242790293e84fcbf296c1fdf161ab46da4a0aa0458c72cba9301b66a')

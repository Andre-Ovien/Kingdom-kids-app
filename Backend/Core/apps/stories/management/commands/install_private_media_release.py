"""Install only the reviewed, packaged private narration metadata (no media I/O)."""

import hashlib
import json
import math
from pathlib import Path

from django.core.exceptions import ImproperlyConfigured
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from Core.media_delivery import _load_map, canonical_source_path
from apps.stories.catalogue_policy import UNAVAILABLE_STORY_SLUGS
from apps.stories.models import NarratorVoice, Story, StoryNarration
from apps.stories.narration import validated_narration_segments, validated_narration_words


RELEASE_DIR = Path(__file__).resolve().parents[5] / 'content' / 'releases'
MANIFEST_PATH = RELEASE_DIR / 'character_narration_v1_manifest.json'
MAP_PATH = RELEASE_DIR / 'cloudinary_first_release_v1.json'
MANIFEST_SHA256 = 'bd8f16103c504229d4902f33afd39a4331859bad11d16351402b7ef9d951524d'
MAP_SHA256 = '70e57ac281c330383db3e3a8c899c80d1816a41f400dae6a9a269b46c6436876'
CHARACTERS = {'kai': 'lion', 'nia': 'dove', 'zuri': 'rainbow'}


def _read_manifest():
    try:
        with MANIFEST_PATH.open('rb') as handle:
            raw = handle.read(2 * 1024 * 1024 + 1)
        if len(raw) > 2 * 1024 * 1024 or hashlib.sha256(raw).hexdigest() != MANIFEST_SHA256:
            raise ValueError
        manifest = json.loads(raw)
    except (OSError, ValueError) as error:
        raise CommandError('The packaged narration release checksum is invalid.') from error
    if (manifest.get('version') != 1
            or manifest.get('release_id') != 'published-character-narration-v1'
            or manifest.get('source') != 'description-only synthetic'
            or not isinstance(manifest.get('auditions'), list)
            or len(manifest['auditions']) != 3
            or not isinstance(manifest.get('tracks'), list)
            or len(manifest['tracks']) != 33):
        raise CommandError('The approved narration release structure is invalid.')
    return manifest


class Command(BaseCommand):
    help = 'Install the pinned private release: 3 samples and 33 tracks; no media files or network required.'

    def add_arguments(self, parser):
        parser.add_argument('--dry-run', action='store_true', help='Validate the complete release without writes.')

    def handle(self, *args, **options):
        manifest = _read_manifest()
        try:
            media_map = _load_map(str(MAP_PATH), MAP_SHA256)
        except ImproperlyConfigured as error:
            raise CommandError('The packaged private media release checksum or mapping is invalid.') from error

        # Lock the exact catalogue revision through validation and commit. No
        # samples/tracks are changed unless the entire release is compatible.
        with transaction.atomic():
            slugs = {row.get('story_slug') for row in manifest['tracks']}
            if len(slugs) != 11 or not all(isinstance(slug, str) for slug in slugs):
                raise CommandError('The release must contain exactly eleven stories.')
            stories = {story.slug: story for story in Story.objects.select_for_update().filter(
                slug__in=slugs, is_published=True,
            ).exclude(slug__in=UNAVAILABLE_STORY_SLUGS)}
            narrators = {voice.avatar_key: voice for voice in NarratorVoice.objects.select_for_update().filter(
                avatar_key__in=CHARACTERS.values(), is_active=True,
            )}
            if set(stories) != slugs or set(narrators) != set(CHARACTERS.values()):
                raise CommandError('The release requires its eleven published stories and three active narrators.')

            samples, tracks = {}, {}
            for row in manifest['auditions']:
                voice, filename, _ = self._audio(row, narrators, media_map, sample=True)
                if voice.pk in samples:
                    raise CommandError('Duplicate character sample.')
                samples[voice.pk] = (voice, filename)
            for row in manifest['tracks']:
                voice, filename, duration = self._audio(row, narrators, media_map, sample=False)
                story = stories[row['story_slug']]
                key = (story.pk, voice.pk)
                if key in tracks:
                    raise CommandError('Duplicate story narrator.')
                text_hash = hashlib.sha256(story.body.encode('utf-8')).hexdigest()
                if row.get('text_sha256') != text_hash:
                    raise CommandError(f'{story.slug}: narration does not match the current story text.')
                segments = validated_narration_segments(row.get('segments'), story.body, duration)
                words = validated_narration_words(row.get('words'), story.body, duration, segments)
                if not segments or segments != row.get('segments') or not words or words != row.get('words'):
                    raise CommandError(f'{story.slug}: narration passage or word timings are invalid.')
                # Words validator also requires complete non-whitespace text
                # coverage within the measured passages.
                tracks[key] = dict(
                    status=StoryNarration.Status.READY, audio_file=filename, audio_url=None,
                    duration_seconds=math.ceil(duration), text_sha256=text_hash,
                    segments=segments, words=words,
                )
            expected = {(story.pk, voice.pk) for story in stories.values() for voice in narrators.values()}
            if set(samples) != set(narrators) or set(tracks) != expected:
                raise CommandError('The release must cover all eleven stories in all three voices.')
            if options['dry_run']:
                self.stdout.write('Validated 3 samples and 33 tracks; dry-run, no data changed.')
                return

            for voice, filename in samples.values():
                values = dict(sample_audio=filename, sample_url=None, provider='qwen3-tts-local',
                              provider_voice_id=f'{voice.voice_key}-synthetic-v1')
                changed = [name for name, value in values.items() if getattr(voice, name) != value]
                if changed:
                    for name in changed:
                        setattr(voice, name, values[name])
                    voice.save(update_fields=[*changed, 'updated_at'])
            existing = {(row.story_id, row.narrator_id): row for row in
                        StoryNarration.objects.select_for_update().filter(story__in=stories.values())}
            for key, values in tracks.items():
                row = existing.get(key)
                if row is None:
                    StoryNarration.objects.create(story_id=key[0], narrator_id=key[1], **values)
                    continue
                changed = [name for name, value in values.items() if getattr(row, name) != value]
                if changed:
                    for name in changed:
                        setattr(row, name, values[name])
                    row.save(update_fields=[*changed, 'updated_at'])
        self.stdout.write(self.style.SUCCESS('Installed private release: 3 samples and 33 ready tracks.'))

    def _audio(self, row, narrators, media_map, *, sample):
        if not isinstance(row, dict):
            raise CommandError('Invalid audio metadata.')
        character = row.get('character')
        avatar = CHARACTERS.get(character) if isinstance(character, str) else None
        if avatar is None or row.get('avatar_key') != avatar:
            raise CommandError('Invalid character identity.')
        duration = row.get('duration_seconds')
        if type(duration) not in (int, float) or not math.isfinite(duration) or not 0 < duration <= 3600:
            raise CommandError('Invalid measured audio duration.')
        filename = row.get('file')
        alias = canonical_source_path(f'Backend/media/{filename}') if isinstance(filename, str) else None
        if (alias is None or not filename.startswith(('character_narration/', 'character_narration_additional_v1/'))
                or not filename.endswith('.mp3') or len(filename) > 255):
            raise CommandError('Invalid relative audio alias.')
        use = (f'sample:{avatar}' if sample else
               f"narration:{row.get('story_slug')}:{avatar}:{row.get('text_sha256')}")
        asset = media_map['assets'].get(alias)
        if (not asset or asset['sha256'] != row.get('sha256') or asset['uses'] != [use]
                or asset['resource_type'] != 'video' or asset['format'] != 'mp3'):
            raise CommandError('The audio alias, use or content hash is not approved in the private release.')
        return narrators[avatar], filename, duration

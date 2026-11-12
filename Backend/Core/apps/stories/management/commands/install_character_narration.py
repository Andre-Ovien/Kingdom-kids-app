"""Attach locally generated, original character voices to the catalogue."""

import hashlib
import json
import math
from pathlib import Path
import re
from urllib.parse import quote, urlsplit, urlunsplit

from django.conf import settings
from django.core.exceptions import ValidationError
from django.core.files import File
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from apps.stories.models import (NarratorVoice, Story, StoryNarration,
                                validate_audio_upload, validate_owned_https_media_url)
from apps.stories.narration import validated_narration_segments, validated_narration_words


CHARACTERS = {'kai': 'lion', 'nia': 'dove', 'zuri': 'rainbow'}


class Command(BaseCommand):
    help = 'Install generated synthetic character samples and complete story tracks.'

    def add_arguments(self, parser):
        parser.add_argument('--manifest', required=True, type=Path)
        parser.add_argument('--samples-only', action='store_true')
        parser.add_argument('--dry-run', action='store_true', help='Validate all files/timings without database writes.')
        parser.add_argument('--hosted-base-url', default=None,
                            help='Owned allowlisted HTTPS base for already-uploaded approved files; does not upload.')

    def handle(self, *args, **options):
        media_root = Path(settings.MEDIA_ROOT).resolve()
        hosted_base = options.get('hosted_base_url')
        if hosted_base is not None:
            hosted_base = self._hosted_base(hosted_base)
        manifest_path = options['manifest'].resolve()
        try:
            manifest_path.relative_to(media_root)
            if manifest_path.stat().st_size > 2 * 1024 * 1024:
                raise ValueError('Manifest is too large.')
            manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        except (OSError, ValueError) as error:
            raise CommandError('Read a valid manifest beneath MEDIA_ROOT.') from error
        if (
            not isinstance(manifest, dict)
            or manifest.get('version') != 1
            or manifest.get('source') != 'description-only synthetic'
        ):
            raise CommandError('Only version 1 original synthetic voice manifests are supported.')

        auditions = manifest.get('auditions', [])
        tracks = [] if options['samples_only'] else manifest.get('tracks', [])
        if not isinstance(auditions, list) or not isinstance(tracks, list):
            raise CommandError('Auditions and tracks must be lists.')
        if not auditions and not tracks:
            raise CommandError('The manifest contains no audio to install.')
        if len(auditions) > 3 or len(tracks) > 512:
            raise CommandError('The manifest contains too many audio entries.')

        prepared_samples = []
        prepared_tracks = []
        seen_samples = set()
        seen_tracks = set()
        for record in auditions:
            if hosted_base is not None:
                self._hosted_url(hosted_base, record.get('file') if isinstance(record, dict) else None)
            narrator, filename, duration = self._prepare_audio(record, media_root)
            if narrator.pk in seen_samples:
                raise CommandError('A character sample appears more than once.')
            seen_samples.add(narrator.pk)
            url = self._hosted_url(hosted_base, filename) if hosted_base is not None else None
            if url is not None:
                self._validate_url_field(narrator._meta.get_field('sample_url'), url, narrator)
            prepared_samples.append((narrator, filename, url))
        for record in tracks:
            if hosted_base is not None:
                self._hosted_url(hosted_base, record.get('file') if isinstance(record, dict) else None)
            narrator, filename, duration = self._prepare_audio(record, media_root)
            slug = record.get('story_slug')
            try:
                story = Story.objects.get(slug=slug, is_published=True)
            except (Story.DoesNotExist, ValueError, TypeError) as error:
                raise CommandError('A track references an unavailable story.') from error
            if (story.pk, narrator.pk) in seen_tracks:
                raise CommandError('A story and character track appears more than once.')
            seen_tracks.add((story.pk, narrator.pk))
            text_hash = hashlib.sha256(story.body.encode('utf-8')).hexdigest()
            if record.get('text_sha256') != text_hash:
                raise CommandError(f'{story.slug}: audio was generated for different story text.')
            segments = validated_narration_segments(record.get('segments'), story.body, duration)
            if not segments or len(segments) != len(record.get('segments', [])):
                raise CommandError(f'{story.slug}: measured passage timings are invalid.')
            # A track is ready only if every non-whitespace story character is
            # represented. Missing passages must never count as a full reading.
            body_utf16 = story.body.encode('utf-16-le')
            cursor = 0
            for segment in segments:
                gap = body_utf16[cursor * 2:segment['start_offset'] * 2].decode('utf-16-le')
                if gap.strip():
                    raise CommandError(f'{story.slug}: audio omits story text.')
                cursor = segment['end_offset']
            if body_utf16[cursor * 2:].decode('utf-16-le').strip():
                raise CommandError(f'{story.slug}: audio omits the end of the story.')
            raw_words = record.get('words', [])
            words = validated_narration_words(raw_words, story.body, duration, segments)
            if not isinstance(raw_words, list) or len(words) != len(raw_words):
                raise CommandError(f'{story.slug}: recorded word timings are invalid.')
            url = self._hosted_url(hosted_base, filename) if hosted_base is not None else None
            if url is not None:
                self._validate_url_field(StoryNarration._meta.get_field('audio_url'), url, None)
            prepared_tracks.append((story, narrator, filename, duration, text_hash, segments, words, url))

        if options.get('dry_run'):
            self.stdout.write(
                f'Validated {len(prepared_samples)} character samples and {len(prepared_tracks)} story tracks; '
                'dry-run, no data changed. Hosted mode does not upload or verify remote availability.')
            return

        # Validate every file and timing record before changing any catalogue row.
        with transaction.atomic():
            for narrator, filename, url in prepared_samples:
                narrator.sample_audio.name = filename if url is None else ''
                fields = ['sample_audio', 'provider', 'provider_voice_id', 'updated_at']
                if url is not None:
                    narrator.sample_url = url
                    fields.append('sample_url')
                narrator.provider = 'qwen3-tts-local'
                narrator.provider_voice_id = f'{narrator.voice_key}-synthetic-v1'
                narrator.save(update_fields=fields)
            for story, narrator, filename, duration, text_hash, segments, words, url in prepared_tracks:
                StoryNarration.objects.update_or_create(
                    story=story,
                    narrator=narrator,
                    defaults={
                        'status': StoryNarration.Status.READY,
                        'audio_file': filename if url is None else '',
                        'audio_url': url,
                        'duration_seconds': math.ceil(duration),
                        'text_sha256': text_hash,
                        'segments': segments,
                        'words': words,
                    },
                )
        self.stdout.write(self.style.SUCCESS(
            f'Installed {len(prepared_samples)} character samples and {len(prepared_tracks)} story tracks.',
        ))
        if hosted_base is not None:
            self.stdout.write('Stored owned HTTPS metadata only; verify actual uploaded bytes/playback before launch.')

    def _hosted_base(self, value):
        try:
            if (not isinstance(value, str) or not value or any(character in value for character in '\\?#')
                    or any(ord(character) <= 32 or ord(character) == 127 for character in value)):
                raise ValueError('The hosted base must be an owned HTTPS URL.')
            parsed = urlsplit(value)
            validate_owned_https_media_url(value)
            if (parsed.query or parsed.fragment or not re.fullmatch(r'/[A-Za-z0-9._~/-]*', parsed.path or '/')
                    or any(part in {'.', '..'} for part in parsed.path.split('/'))
                    or '//' in parsed.path):
                raise ValueError('The hosted base has an unsafe path, query or fragment.')
            return urlunsplit((parsed.scheme, parsed.netloc, parsed.path.rstrip('/') + '/', '', ''))
        except Exception as error:
            raise CommandError('Use an owned allowlisted HTTPS media base without credentials, query or unsafe path.') from error

    def _hosted_url(self, base, filename):
        if (not isinstance(filename, str) or not filename or filename.startswith('/')
                or any(character in filename for character in '\\%?#')
                or any(ord(character) < 32 or ord(character) == 127 for character in filename)
                or any(part in {'', '.', '..'} for part in filename.split('/'))):
            raise CommandError('Hosted audio paths must be safe relative object paths.')
        url = base + quote(filename, safe='/._~-')
        try:
            validate_owned_https_media_url(url)
        except Exception as error:
            raise CommandError('A hosted audio path is not an owned HTTPS URL.') from error
        return url

    def _validate_url_field(self, field, value, instance):
        try:
            field.clean(value, instance)
        except ValidationError as error:
            raise CommandError('A hosted media URL is invalid or too long for the catalogue.') from error

    def _prepare_audio(self, record, media_root):
        if not isinstance(record, dict):
            raise CommandError('Every audio entry must be an object.')
        character = record.get('character')
        avatar_key = CHARACTERS.get(character) if isinstance(character, str) else None
        if avatar_key is None or record.get('avatar_key') != avatar_key:
            raise CommandError('Audio must reference Kai, Nia, or Zuri correctly.')
        try:
            narrator = NarratorVoice.objects.get(avatar_key=avatar_key, is_active=True)
        except NarratorVoice.DoesNotExist as error:
            raise CommandError('The character narrator is not configured.') from error
        duration = record.get('duration_seconds')
        if type(duration) not in (int, float) or not math.isfinite(duration) or not 0 < duration <= 3600:
            raise CommandError('Audio must have a measured duration under one hour.')
        filename = record.get('file')
        if not isinstance(filename, str) or Path(filename).is_absolute():
            raise CommandError('Audio paths must be relative to MEDIA_ROOT.')
        try:
            path = (media_root / filename).resolve()
            path.relative_to(media_root)
            if path.suffix.lower() not in {'.mp3', '.wav', '.m4a', '.aac'}:
                raise ValueError('Unsupported audio type.')
            with path.open('rb') as handle:
                validate_audio_upload(File(handle, name=path.name))
            if hashlib.sha256(path.read_bytes()).hexdigest() != record.get('sha256'):
                raise ValueError('Audio content does not match the manifest.')
        except Exception as error:
            raise CommandError('An audio file is missing, invalid, or outside MEDIA_ROOT.') from error
        return narrator, path.relative_to(media_root).as_posix(), duration

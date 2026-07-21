from pathlib import Path

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from apps.stories.models import NarratorVoice


ROUND_ONE_SAMPLES = (
    {
        'avatar_key': 'lion',
        'character_name': 'Kai',
        'provider_voice_id': 'cedar',
        'filename': 'kai_a_cedar.mp3',
    },
    {
        'avatar_key': 'dove',
        'character_name': 'Nia',
        'provider_voice_id': 'marin',
        'filename': 'nia_a_marin.mp3',
    },
    {
        'avatar_key': 'rainbow',
        'character_name': 'Zuri',
        'provider_voice_id': 'coral',
        'filename': 'zuri_a_coral.mp3',
    },
)


def _validate_mp3(path: Path, media_root: Path) -> str | None:
    """Return an actionable error instead of attaching an unsafe/broken file."""

    try:
        resolved_path = path.resolve(strict=True)
    except FileNotFoundError:
        return 'file is missing'
    except OSError as exc:
        return f'file cannot be inspected ({exc})'

    if not resolved_path.is_relative_to(media_root):
        return 'file resolves outside MEDIA_ROOT'
    if not resolved_path.is_file():
        return 'path is not a regular file'

    try:
        size = resolved_path.stat().st_size
        with resolved_path.open('rb') as audio_file:
            signature = audio_file.read(3)
    except OSError as exc:
        return f'file cannot be read ({exc})'

    if size < 1024:
        return f'file is unexpectedly small ({size} bytes)'
    is_id3 = signature == b'ID3'
    is_mpeg_frame = (
        len(signature) >= 2
        and signature[0] == 0xFF
        and signature[1] & 0xE0 == 0xE0
    )
    if not (is_id3 or is_mpeg_frame):
        return 'file does not have an MP3 signature'
    return None


class Command(BaseCommand):
    help = (
        'Attach cached Round 1 samples (Kai/Cedar, Nia/Marin, Zuri/Coral) '
        'after all three MP3 files have been generated.'
    )

    def handle(self, *args, **options):
        media_root = Path(settings.MEDIA_ROOT).expanduser().resolve()
        sample_dir = media_root / 'voice_auditions'
        errors = []

        for sample in ROUND_ONE_SAMPLES:
            error = _validate_mp3(sample_dir / sample['filename'], media_root)
            if error:
                errors.append(f"{sample['filename']}: {error}")

        avatar_keys = [sample['avatar_key'] for sample in ROUND_ONE_SAMPLES]
        narrators = {
            narrator.avatar_key: narrator
            for narrator in NarratorVoice.objects.filter(avatar_key__in=avatar_keys)
        }
        for sample in ROUND_ONE_SAMPLES:
            if sample['avatar_key'] not in narrators:
                errors.append(
                    f"{sample['character_name']}: narrator row "
                    f"{sample['avatar_key']!r} is missing"
                )

        if errors:
            formatted_errors = '\n'.join(f'- {error}' for error in errors)
            raise CommandError(
                'Round 1 samples were not installed. Fix every issue first; '
                f'no narrator records were changed.\n{formatted_errors}'
            )

        with transaction.atomic():
            for sample in ROUND_ONE_SAMPLES:
                narrator = narrators[sample['avatar_key']]
                narrator.sample_audio.name = (
                    f"voice_auditions/{sample['filename']}"
                )
                narrator.provider = 'openai'
                narrator.provider_voice_id = sample['provider_voice_id']
                narrator.save(
                    update_fields=(
                        'sample_audio',
                        'provider',
                        'provider_voice_id',
                        'updated_at',
                    ),
                )

        summary = ', '.join(
            f"{sample['character_name']}={sample['provider_voice_id'].title()}"
            for sample in ROUND_ONE_SAMPLES
        )
        self.stdout.write(self.style.SUCCESS(f'Round 1 samples ready: {summary}'))

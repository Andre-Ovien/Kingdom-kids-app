#!/usr/bin/env python3
"""Render original synthetic character voices locally on Apple Silicon.

Runtime: an isolated Python 3.12 environment with mlx-audio==0.5.7 and
soundfile==0.13.1; ffmpeg is needed for MP3 export. No cloud speech API,
API key, payment, or real person's recording is used. Auditions are created
from descriptions. Story generation accepts only our own generated audition
whose provenance and checksum match its manifest.

Run audition and story modes as separate processes to avoid retaining both
large models on an 8 GB Mac. Generated audio and manifests belong in ignored
Backend/media/character_narration, never in the source tree.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path


BACKEND = Path(__file__).resolve().parents[1]
OUTPUT = BACKEND / 'media' / 'character_narration'
DESIGN_MODEL = 'mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit'
BASE_MODEL = 'mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit'
ORIGIN = 'description-only-generated-synthetic-character'
ACCEPTED_REVIEWS = ('acceptable-preview', 'approved')
COMMON_DESCRIPTION = (
    'An original animated child character, approximately nine years old, '
    'speaking clear natural English. The voice has the small, light resonance '
    'and youthful timbre of a child, with relaxed breath and fluid expressive '
    'phrasing. Warm, intelligible story narration for children. Natural pauses '
    'and sincere curiosity. Moderate speaking pace. '
)
CHARACTERS = {
    'kai': {
        'avatar_key': 'lion',
        'seed': 9101,
        'description': COMMON_DESCRIPTION + (
            'A young boy with a bright gentle upper register, rounded vowels '
            'and a warm smile in his voice. Friendly, curious and quietly brave. '
            'His youthful voice sounds effortless, with clear soft consonants '
            'and engaging storytelling expression.'
        ),
    },
    'nia': {
        'avatar_key': 'dove',
        'seed': 9102,
        'description': COMMON_DESCRIPTION + (
            'A young girl with a soft clear voice and smooth, delicate resonance. '
            'Thoughtful, reassuring and gently curious. Her youthful voice has '
            'a calm flowing cadence and tender expression, with crisp words '
            'and quiet confidence.'
        ),
    },
    'zuri': {
        'avatar_key': 'rainbow',
        'seed': 9103,
        'description': COMMON_DESCRIPTION + (
            'A young girl with a bright rounded voice and lively melodic '
            'inflection. Joyful, playful and full of wonder. Her youthful voice '
            'has cheerful expressive energy and clear, easy articulation, '
            'becoming reassuring when the story turns serious.'
        ),
    },
}
KAI_VARIANTS = {
    'boy1': {
        'seed': 9111,
        'description': (
            "An original animated character: an eleven-year-old boy narrating a children's adventure. "
            'An unmistakably youthful male speaking voice, with a natural boyish lower-middle child register, '
            'light forward resonance and a gentle rounded chest note. His tone is warm, curious and quietly brave. '
            'Fluid, relaxed boyish speech inflection and clear natural English, with a friendly smile and expressive '
            'storytelling pauses. His youthful male timbre stays consistent across every sentence. Moderate pace.'
        ),
    },
    'boy2': {
        'seed': 9121,
        'description': (
            'An original ten-year-old boy character with a lively, clearly boyish voice. A prepubescent male child '
            'with a light, slightly husky youthful timbre, compact chest resonance and an easy middle speaking '
            'register. He speaks English naturally with bright curiosity, playful confidence and warm sincerity. '
            'Relaxed conversational boy speech, clear consonants and smooth flowing phrases, with gentle expressive '
            "pauses for children's story narration. His male child voice is natural and effortless. Moderate pace."
        ),
    },
    'child3': {
        'seed': 9131,
        'description': (
            'An original animated eight-year-old African-American boy, an elementary-school child speaking '
            'to his friends. A clearly prepubescent little boy voice with light, small, clear resonance and '
            'an effortless youthful upper speaking range. His sound is soft, bright and boyish, with the '
            'young vowel shapes and playful curious cadence of an eight-year-old child. Natural American '
            'English, with subtle African-American conversational intonation and rhythm. Relaxed, friendly '
            'and gently excited, speaking clearly at a moderate pace. An innocent child telling a story in '
            'his own natural voice. Keep the timbre unmistakably that of a young boy throughout every '
            'sentence, without exaggerated dialect, caricature, mature bass resonance or an announcer tone.'
        ),
    },
    'child4': {
        'seed': 9141,
        'description': (
            'An original African-American boy aged nine to ten, a lively elementary-school child chatting '
            'with his friends. Clearly prepubescent boy speech in a natural youthful middle register. '
            'Light, compact, child-sized resonance with a gently textured, softly nasal boyish timbre. '
            'His speaking voice has the easy everyday sound of a young boy: relaxed, playful, curious, '
            'with clear consonants and small rounded vowel shapes. Natural American English with subtle '
            'Black American conversational cadence and intonation. Warm, sincere expression and an '
            'unhurried, fluid storytelling rhythm. Keep his little-boy timbre consistent throughout '
            'every sentence, with a slight natural texture and the light vocal presence of a school-age '
            'boy. Speak comfortably and conversationally, without exaggerated dialect, caricature, '
            'mature bass weight or an announcer tone.'
        ),
    },
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save_json(path: Path, payload: dict) -> None:
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temporary.replace(path)


def export_installer_manifest(output: Path) -> Path:
    """Expose only completed, checksum-verified assets to the DB installer."""
    auditions, tracks = [], []
    media_root = output.parent
    accepted_references = {}
    for character in CHARACTERS:
        metadata = output / 'auditions' / f'{character}.json'
        if metadata.exists():
            reference = json.loads(metadata.read_text(encoding='utf-8'))
            if reference.get('review_status') in ACCEPTED_REVIEWS:
                accepted_references[character] = reference
    for metadata in sorted(output.glob('*/*.json')):
        if metadata.parent.name == 'story_inputs':
            continue
        item = json.loads(metadata.read_text(encoding='utf-8'))
        if item.get('source') != ORIGIN:
            continue
        if item.get('variant') or item.get('review_status') == 'rejected':
            # Audition alternatives need human selection before installation.
            continue
        character = item['character']
        if character not in accepted_references:
            continue
        if item.get('avatar_key') != CHARACTERS[character]['avatar_key']:
            raise RuntimeError('The generated character and avatar do not match.')
        mp3 = metadata.parent / item['mp3']
        if mp3.resolve().parent != metadata.parent.resolve() or digest(mp3) != item['mp3_sha256']:
            raise RuntimeError('Cannot export an audio file with an invalid checksum.')
        entry = {
            'character': character, 'avatar_key': item['avatar_key'],
            'file': mp3.relative_to(media_root).as_posix(),
            'sha256': item['mp3_sha256'], 'duration_seconds': item['duration_seconds'],
        }
        if metadata.parent.name == 'auditions':
            auditions.append(entry)
        else:
            if item.get('reference_sha256') != accepted_references[character]['wav_sha256']:
                raise RuntimeError('Story audio was generated from a different character reference.')
            entry.update(story_slug=item['story_slug'], text_sha256=item['text_sha256'],
                         segments=item['segments'])
            if 'words' in item:
                entry['words'] = item['words']
            tracks.append(entry)
    manifest = output / 'manifest.json'
    save_json(manifest, {'version': 1, 'source': 'description-only synthetic',
                         'auditions': auditions, 'tracks': tracks})
    return manifest


def utf16_length(text: str) -> int:
    return len(text.encode('utf-16-le')) // 2


def story_segments(body: str) -> list[dict]:
    segments = []
    cursor = 0
    for paragraph in re.split(r'\n[ \t]*\n', body):
        text = paragraph.strip()
        if not text:
            continue
        start = body.index(text, cursor)
        end = start + len(text)
        segments.append({
            'text': text,
            'start_offset': utf16_length(body[:start]),
            'end_offset': utf16_length(body[:end]),
        })
        cursor = end
    return segments


def audition_text(character: str) -> str:
    return (
        f"Hi, I'm {character.title()}! Come with me, little explorer. "
        'Every Bible story has something wonderful to discover. '
        "Ready? Let's turn the page together."
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('audition', 'story', 'select'))
    parser.add_argument('--character', choices=(*CHARACTERS, 'all', 'accepted'), default='kai')
    parser.add_argument('--variant', choices=(*KAI_VARIANTS, 'all'),
                        help='Separate Kai boy alternatives for review; never auto-installed.')
    parser.add_argument('--output-dir', type=Path, default=OUTPUT)
    parser.add_argument('--model-dir', type=Path, help='Previously downloaded model snapshot.')
    parser.add_argument('--cache-dir', type=Path, default=Path.home() / '.cache/kingdom-kids-voices/models')
    story_input = parser.add_mutually_exclusive_group()
    story_input.add_argument('--story-json', type=Path, help='JSON containing slug, title and exact story body.')
    story_input.add_argument('--story-dir', type=Path,
                             help='Generate every exported story JSON with one loaded Base model.')
    parser.add_argument('--force', action='store_true')
    parser.add_argument('--print-plan', action='store_true', help='Show text and offsets without loading a model.')
    return parser.parse_args()


def resolve_model(args: argparse.Namespace) -> tuple[Path, str]:
    model_id = DESIGN_MODEL if args.mode == 'audition' else BASE_MODEL
    if args.model_dir:
        return args.model_dir.expanduser().resolve(strict=True), model_id
    from huggingface_hub import snapshot_download
    path = snapshot_download(
        model_id,
        cache_dir=str(args.cache_dir.expanduser()),
        token=False,
        max_workers=2,
        allow_patterns=['*.json', '*.safetensors', '*.txt', '*.model', 'README.md', 'LICENSE', 'speech_tokenizer/*'],
    )
    return Path(path), model_id


def synthesize(model, text: str, seed: int, *, description: str | None = None,
               reference: Path | None = None, reference_text: str | None = None):
    import mlx.core as mx
    import numpy as np
    mx.random.seed(seed)
    # Bound runaway generation without changing the voice's pitch or timing.
    max_tokens = min(1800, max(384, math.ceil(len(text.split()) * 9 + 120)))
    settings = dict(temperature=0.7, top_p=0.95, top_k=50,
                    repetition_penalty=1.05, max_tokens=max_tokens)
    if description is not None:
        results = model.generate_voice_design(
            text=text, instruct=description, language='English', **settings)
    else:
        results = model.generate(
            text=text, ref_audio=str(reference), ref_text=reference_text,
            lang_code='English', **settings)
    pieces = []
    sample_rate = None
    elapsed = time.monotonic()
    for result in results:
        audio = np.asarray(result.audio, dtype=np.float32).reshape(-1)
        if result.token_count >= max_tokens:
            raise RuntimeError('Generation reached its token limit; refusing a potentially incomplete clip.')
        if sample_rate is not None and sample_rate != result.sample_rate:
            raise RuntimeError('The model changed sample rate during generation.')
        sample_rate = result.sample_rate
        pieces.append(audio)
    if not pieces or not sample_rate:
        raise RuntimeError('The local model did not return audio.')
    audio = np.concatenate(pieces)
    duration = audio.size / sample_rate
    if not np.isfinite(audio).all() or duration < 1.0:
        raise RuntimeError('The local model returned invalid or too-short audio.')
    peak = float(np.max(np.abs(audio)))
    rms = float(np.sqrt(np.mean(audio ** 2)))
    if peak < 0.005 or rms < 0.0005:
        raise RuntimeError('The generated clip is silent or near-silent.')
    clipped_fraction = float(np.mean(np.abs(audio) >= 0.995))
    if clipped_fraction > 0.01:
        raise RuntimeError('The generated clip has excessive clipping.')
    # Lower peaks only. No pitch shifting, speed-up, or adult voice disguise.
    if peak > 0.92:
        audio *= 0.92 / peak
    return audio, sample_rate, {
        'duration_seconds': round(duration, 6),
        'generation_seconds': round(time.monotonic() - elapsed, 3),
        'raw_peak': round(peak, 6), 'raw_rms': round(rms, 6),
        'raw_clipped_fraction': round(clipped_fraction, 8),
        'seed': seed, 'sampling': settings,
    }


def write_audio(directory: Path, stem: str, audio, sample_rate: int) -> dict:
    import soundfile as sf
    directory.mkdir(parents=True, exist_ok=True)
    wav = directory / f'{stem}.wav'
    sf.write(wav, audio, sample_rate, subtype='PCM_16')
    mp3 = directory / f'{stem}.mp3'
    if not shutil.which('ffmpeg'):
        raise RuntimeError('ffmpeg is required to export the mobile MP3 file.')
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                    '-i', str(wav), '-codec:a', 'libmp3lame', '-b:a', '96k', str(mp3)], check=True)
    return {'wav': wav.name, 'mp3': mp3.name, 'wav_sha256': digest(wav),
            'mp3_sha256': digest(mp3), 'sample_rate': sample_rate}


def synthetic_reference(output: Path, character: str) -> tuple[Path, dict]:
    directory = output / 'auditions'
    manifest = json.loads((directory / f'{character}.json').read_text())
    if manifest.get('source') != ORIGIN or manifest.get('character') != character:
        raise RuntimeError('Only a description-created synthetic character audition can be reused.')
    if manifest.get('review_status') not in ACCEPTED_REVIEWS:
        raise RuntimeError('This character reference needs human acceptance before use in stories.')
    audio = directory / manifest['wav']
    if audio.resolve().parent != directory.resolve() or digest(audio) != manifest['wav_sha256']:
        raise RuntimeError('Synthetic reference provenance or checksum does not match.')
    return audio, manifest


def generate_audition(args, model, model_id, character: str, variant: str | None = None) -> None:
    directory = args.output_dir / 'auditions'
    stem = f'{character}_{variant}' if variant else character
    metadata = directory / f'{stem}.json'
    if metadata.exists() and not args.force:
        previous = json.loads(metadata.read_text(encoding='utf-8'))
        if (previous.get('source') != ORIGIN or previous.get('character') != character
                or digest(directory / previous['wav']) != previous['wav_sha256']):
            raise RuntimeError('Existing audition provenance or checksum differs.')
        print(f'Skipping existing validated {stem} audition.', flush=True)
        return
    persona = KAI_VARIANTS[variant] if variant else CHARACTERS[character]
    text = audition_text(character)
    print(f'Generating {stem} description-created audition...', flush=True)
    audio, rate, measurements = synthesize(model, text, persona['seed'], description=persona['description'])
    files = write_audio(directory, stem, audio, rate)
    save_json(metadata, {
        'schema_version': 1, 'source': ORIGIN, 'character': character,
        'avatar_key': CHARACTERS[character]['avatar_key'], 'variant': variant,
        'description': persona['description'],
        'text': text, 'model': model_id, 'model_revision': model_dir_revision(args),
        'mlx_audio_version': importlib.metadata.version('mlx-audio'),
        'created_at': datetime.now(UTC).isoformat(),
        'disclosure': 'Character narration is AI-generated.',
        'quality_review': 'Not yet approved by the user; requires listening.',
        'review_status': 'awaiting-review',
        **measurements, **files,
    })
    export_installer_manifest(args.output_dir)
    print(f'Saved {directory / files["mp3"]}: {measurements}', flush=True)


def model_dir_revision(args) -> str | None:
    return args.model_dir.name if args.model_dir and args.model_dir.parent.name == 'snapshots' else None


def select_kai_reference(output: Path, variant: str) -> None:
    """Apply an explicit human choice while keeping every review audio intact."""
    directory = output / 'auditions'
    candidate_path = directory / f'kai_{variant}.json'
    candidate = json.loads(candidate_path.read_text(encoding='utf-8'))
    if (candidate.get('source') != ORIGIN or candidate.get('character') != 'kai'
            or candidate.get('variant') != variant):
        raise RuntimeError('The selected candidate is not an original synthetic Kai voice.')
    if candidate.get('review_status') == 'rejected':
        raise RuntimeError('This Kai candidate was rejected; generate a new review candidate instead.')
    for kind in ('wav', 'mp3'):
        filename = directory / candidate[kind]
        if filename.resolve().parent != directory.resolve() or digest(filename) != candidate[f'{kind}_sha256']:
            raise RuntimeError('Selected candidate audio does not match its checksum.')
    original = directory / 'kai.json'
    previous = json.loads(original.read_text(encoding='utf-8')) if original.exists() else None
    archive = directory / 'kai_initial_rejected.json'
    if previous and previous.get('review_status') == 'rejected' and not archive.exists():
        save_json(archive, previous)
    candidate.update(variant=None, selected_variant=variant, review_status='approved',
                     quality_review=f'Human selected Kai {variant}.',
                     selected_at=datetime.now(UTC).isoformat())
    # Point the canonical reference at the chosen original files; never modify
    # or replace any of the old or candidate audio used during review.
    save_json(original, candidate)
    print(f'Selected {candidate_path.stem}; manifest: {export_installer_manifest(output)}', flush=True)


def generate_story(args, model, model_id, character: str, story: dict) -> None:
    import numpy as np
    body = story['body']
    segments = story_segments(body)
    directory = args.output_dir / story['slug']
    metadata = directory / f'{character}.json'
    text_hash = hashlib.sha256(body.encode()).hexdigest()
    reference, reference_manifest = synthetic_reference(args.output_dir, character)
    if metadata.exists() and not args.force:
        previous = json.loads(metadata.read_text())
        previous_segments = previous.get('segments', [])
        if (previous.get('source') == ORIGIN
                and previous.get('character') == character
                and previous.get('story_slug') == story['slug']
                and previous.get('text_sha256') == text_hash
                and previous.get('reference_sha256') == reference_manifest['wav_sha256']
                and [(s['text'], s['start_offset'], s['end_offset']) for s in previous_segments]
                    == [(s['text'], s['start_offset'], s['end_offset']) for s in segments]
                and digest(directory / previous['wav']) == previous['wav_sha256']
                and digest(directory / previous['mp3']) == previous['mp3_sha256']):
            print(f'Skipping existing validated {story["slug"]}/{character}.', flush=True)
            return
        raise RuntimeError('Existing story audio differs from its text/checksum; use --force deliberately.')
    pieces = []
    sample_rate = None
    position = 0
    measurements = []
    for index, segment in enumerate(segments):
        print(f'Generating {story["slug"]}/{character}, paragraph {index + 1}/{len(segments)}...', flush=True)
        audio, rate, measure = synthesize(
            model, segment['text'], CHARACTERS[character]['seed'] + index,
            reference=reference, reference_text=reference_manifest['text'])
        if sample_rate is not None and rate != sample_rate:
            raise RuntimeError('Paragraph sample rates must match.')
        sample_rate = rate
        segment['start_seconds'] = round(position / rate, 6)
        pieces.append(audio)
        position += audio.size
        segment['end_seconds'] = round(position / rate, 6)
        measurements.append(measure)
        if index < len(segments) - 1:
            pause = np.zeros(round(rate * 0.35), dtype=np.float32)
            pieces.append(pause)
            position += pause.size
    files = write_audio(directory, character, np.concatenate(pieces), sample_rate)
    save_json(metadata, {
        'schema_version': 1, 'source': ORIGIN, 'character': character,
        'avatar_key': CHARACTERS[character]['avatar_key'], 'story_slug': story['slug'],
        'story_title': story['title'], 'text_sha256': text_hash,
        'segments': segments, 'duration_seconds': round(position / sample_rate, 6),
        'reference_sha256': reference_manifest['wav_sha256'],
        'model': model_id, 'model_revision': model_dir_revision(args),
        'mlx_audio_version': importlib.metadata.version('mlx-audio'),
        'created_at': datetime.now(UTC).isoformat(), 'paragraph_measurements': measurements,
        'quality_review': 'Not yet approved by the user; requires listening.', **files,
    })
    export_installer_manifest(args.output_dir)
    print(f'Saved {directory / files["mp3"]}.', flush=True)


def main() -> int:
    args = parse_args()
    args.output_dir = args.output_dir.expanduser().resolve()
    characters = list(CHARACTERS) if args.character == 'all' else [args.character]
    if args.character == 'accepted':
        characters = []
        for character in CHARACTERS:
            metadata = args.output_dir / 'auditions' / f'{character}.json'
            if metadata.exists():
                review = json.loads(metadata.read_text(encoding='utf-8')).get('review_status')
                if review in ACCEPTED_REVIEWS:
                    characters.append(character)
        if not characters:
            raise ValueError('There are no human-accepted character references.')
    if args.mode == 'select':
        if args.character != 'kai' or args.variant not in KAI_VARIANTS:
            raise ValueError('Select mode needs --character kai and one named --variant.')
        select_kai_reference(args.output_dir, args.variant)
        return 0
    if args.variant and (args.mode != 'audition' or args.character != 'kai'):
        raise ValueError('Voice variants are supported only for Kai audition review.')
    stories = []
    if args.mode == 'story':
        if not args.story_json and not args.story_dir:
            raise ValueError('Story mode requires --story-json or --story-dir.')
        inputs = [args.story_json] if args.story_json else sorted(args.story_dir.glob('*.json'))
        if not inputs:
            raise ValueError('The story directory contains no exported story JSON files.')
        for source in inputs:
            story = json.loads(source.read_text(encoding='utf-8'))
            if not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', story['slug']):
                raise ValueError('Story slug must be a safe lowercase slug.')
            if not isinstance(story['body'], str) or not story['body'].strip():
                raise ValueError('The story body is empty.')
            if not isinstance(story['title'], str) or not story['title'].strip():
                raise ValueError('The story title is empty.')
            if any(previous['slug'] == story['slug'] for previous in stories):
                raise ValueError('Story inputs must have distinct slugs.')
            stories.append(story)
    if args.print_plan:
        descriptions = {c: CHARACTERS[c]['description'] for c in characters}
        if args.variant:
            variants = list(KAI_VARIANTS) if args.variant == 'all' else [args.variant]
            descriptions = {v: KAI_VARIANTS[v]['description'] for v in variants}
        print(json.dumps({'mode': args.mode, 'characters': characters,
                          'stories': [{'slug': story['slug'], 'segments': story_segments(story['body'])}
                                      for story in stories],
                          'descriptions': descriptions}, indent=2))
        return 0
    os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
    model_path, model_id = resolve_model(args)
    args.model_dir = model_path
    # All tokenizers and weights are now local; no account-authenticated network calls.
    os.environ['HF_HUB_OFFLINE'] = '1'
    from mlx_audio.tts.utils import load_model
    import mlx.core as mx
    mx.set_cache_limit(128 * 1024 ** 2)
    print(f'Loading one local model: {model_id}', flush=True)
    model = load_model(model_path)
    expected_type = 'voice_design' if args.mode == 'audition' else 'base'
    if model.config.tts_model_type != expected_type:
        raise RuntimeError('The supplied model snapshot does not match the selected mode.')
    for character in characters:
        if args.mode == 'audition':
            variants = list(KAI_VARIANTS) if args.variant == 'all' else [args.variant]
            for variant in variants:
                generate_audition(args, model, model_id, character, variant)
        else:
            for story in stories:
                generate_story(args, model, model_id, character, story)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f'Local character narration failed: {exc}', file=sys.stderr)
        raise SystemExit(1)

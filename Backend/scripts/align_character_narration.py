#!/usr/bin/env python3
"""Force exact story words onto recorded audio with Whisper attention + DTW.

This utility supplies canonical tokens directly to find_alignment; it never
decodes an ASR transcript or distributes time evenly. Punctuation stays on its
canonical word while boundaries come from the word's spoken token groups.
Zero-duration words may join an adjacent measured short phrase; individual
times are never fabricated. Invalid cues are reported and never installed.
The original audio remains unchanged. Run only when other local speech models
are unloaded.

Example (use the isolated character-voice Python environment):
  align_character_narration.py --model-dir /path/to/whisper/snapshot \
      --story jonah-and-the-big-fish --character zuri --write
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
import time
import wave
from datetime import UTC, datetime
from pathlib import Path

from verify_character_narration import validate_metadata


METHOD = 'whisper-canonical-cross-attention-dtw'


def utf16_length(text: str) -> int:
    return len(text.encode('utf-16-le')) // 2


def canonical_spans(text: str, start_offset: int = 0) -> list[dict]:
    """Keep exact non-whitespace words and punctuation, with UTF16 offsets."""
    return [
        {
            'text': match.group(),
            'start_offset': start_offset + utf16_length(text[:match.start()]),
            'end_offset': start_offset + utf16_length(text[:match.end()]),
        }
        for match in re.finditer(r'\S+', text)
    ]


def atomic_json(path: Path, payload: dict) -> None:
    _atomic_text(path, _encoded_json(payload))


def _encoded_json(payload: dict) -> str:
    return json.dumps(payload, ensure_ascii=False, indent=2, allow_nan=False) + '\n'


def _atomic_text(path: Path, encoded: str) -> None:
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(encoded, encoding='utf-8')
    temporary.replace(path)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def validate_word_cues(cues: list[dict], body: str, duration: float) -> list[str]:
    """Check every supplied word without manufacturing missing boundaries."""
    errors = []
    previous_time = 0.0
    previous_offset = 0
    encoded = body.encode('utf-16-le')
    for index, cue in enumerate(cues, 1):
        start, end = cue.get('start_seconds'), cue.get('end_seconds')
        if (type(start) not in (int, float) or type(end) not in (int, float)
                or not math.isfinite(start) or not math.isfinite(end)
                or not 0 <= previous_time <= start < end <= duration + 1e-6):
            errors.append(f'Word {index} ({cue.get("text")}): invalid or zero-duration timing.')
        if type(start) in (int, float) and type(end) in (int, float) and math.isfinite(end):
            previous_time = end
        first, last = cue.get('start_offset'), cue.get('end_offset')
        if type(first) is not int or type(last) is not int or not previous_offset <= first < last <= len(encoded) // 2:
            errors.append(f'Word {index}: invalid UTF16 offsets.')
            continue
        try:
            actual = encoded[first * 2:last * 2].decode('utf-16-le')
            gap = encoded[previous_offset * 2:first * 2].decode('utf-16-le')
        except UnicodeError:
            actual = None
            gap = 'invalid'
        if actual != cue.get('text'):
            errors.append(f'Word {index}: exact story text differs from UTF16 slice.')
        if gap.strip():
            errors.append(f'Word {index}: cues omit non-whitespace canonical text.')
        previous_offset = last
    try:
        uncovered = encoded[previous_offset * 2:].decode('utf-16-le').strip()
    except UnicodeError:
        uncovered = 'invalid UTF16 boundary'
    if not cues or uncovered:
        errors.append('Word cues do not completely cover canonical non-whitespace text.')
    return errors


def validate_paragraph_cues(cues: list[dict], paragraph: dict, clip: dict) -> list[str]:
    """Keep word boundaries inside the measured paragraph and actual clip."""
    errors = []
    clip_start = clip['audio_offset_seconds']
    clip_end = clip_start + clip['aligned_clip_duration_seconds']
    # Stored paragraph/cue times are rounded to six decimals; one microsecond
    # covers the combined rounding without allowing a padded audio interval.
    tolerance = 1e-6
    for cue in cues:
        start, end = cue['start_seconds'], cue['end_seconds']
        if (not math.isfinite(start) or not math.isfinite(end)
                or start < paragraph['start_seconds'] - tolerance
                or end > paragraph['end_seconds'] + tolerance):
            errors.append(f'{cue["text"]}: timing exceeds measured paragraph bounds.')
        if (not math.isfinite(start) or not math.isfinite(end)
                or start < clip_start - tolerance or end > clip_end + tolerance):
            errors.append(f'{cue["text"]}: timing exceeds actual trimmed audio bounds.')
    return errors


def _paragraph_pcm(path: Path, paragraph: dict):
    """Read one measured paragraph and resample in memory for Whisper."""
    import numpy as np

    with wave.open(str(path), 'rb') as audio:
        if audio.getnchannels() != 1 or audio.getsampwidth() != 2:
            raise ValueError('Alignment expects generated mono PCM16 WAV audio.')
        rate = audio.getframerate()
        first = round(paragraph['start_seconds'] * rate)
        last = round(paragraph['end_seconds'] * rate)
        audio.setpos(first)
        pcm = audio.readframes(last - first)
    values = np.frombuffer(pcm, dtype='<i2').astype(np.float32) / 32768.0
    active = np.flatnonzero(np.abs(values) > 0.001)
    if not len(active):
        raise ValueError('Paragraph contains no measurable speech signal.')
    # Remove only the quiet tails, keeping 40 ms around detected signal.
    margin = round(0.04 * rate)
    trim_first = max(0, int(active[0]) - margin)
    trim_last = min(len(values), int(active[-1]) + margin + 1)
    trimmed_pcm = pcm[trim_first * 2:trim_last * 2]
    completed = subprocess.run(
        [shutil.which('ffmpeg') or 'ffmpeg', '-v', 'error', '-f', 's16le',
         '-ar', str(rate), '-ac', '1', '-i', 'pipe:0', '-f', 'f32le',
         '-ar', '16000', '-ac', '1', 'pipe:1'],
        input=trimmed_pcm, capture_output=True, check=True, timeout=60,
    )
    resampled = np.frombuffer(completed.stdout, dtype='<f4').copy()
    if not len(resampled) or len(resampled) > 30 * 16000:
        raise ValueError('Paragraph alignment requires a nonempty clip no longer than 30 seconds.')
    return resampled, {
        'source_start_sample': first,
        'source_end_sample': last,
        'trim_start_samples': trim_first,
        'trim_end_samples': len(values) - trim_last,
        'trim_start_seconds': trim_first / rate,
        'trim_end_seconds': (len(values) - trim_last) / rate,
        'audio_offset_seconds': (first + trim_first) / rate,
        'aligned_clip_duration_seconds': len(resampled) / 16000,
    }


def _map_alignment(alignment, paragraph: dict, audio_offset: float) -> tuple[list[dict], list[dict]]:
    forced_text = ' ' + paragraph['text']
    raw = []
    cursor = 0
    for timing in alignment:
        word = timing.word
        probability = float(timing.probability)
        raw.append({
            'text': word, 'start_character': cursor, 'end_character': cursor + len(word),
            'start_seconds': float(timing.start), 'end_seconds': float(timing.end),
            'probability': probability if math.isfinite(probability) else None,
        })
        cursor += len(word)
    if ''.join(word['text'] for word in raw) != forced_text:
        raise ValueError('Whisper token groups do not reconstruct the exact forced paragraph.')
    cues = []
    for match, span in zip(re.finditer(r'\S+', forced_text), canonical_spans(paragraph['text'], paragraph['start_offset'])):
        groups = [word for word in raw if word['start_character'] < match.end() and word['end_character'] > match.start()]
        # Punctuation has no spoken duration. Keep it in text, but use lexical
        # token-group boundaries rather than timing a period as an extra pause.
        spoken_groups = [word for word in groups if any(char.isalnum() for char in word['text'])]
        if not spoken_groups:
            spoken_groups = groups
        if not spoken_groups:
            raise ValueError(f'No alignment group for canonical word {span["text"]}.')
        cue = {
            **span,
            'start_seconds': round(audio_offset + spoken_groups[0]['start_seconds'], 6),
            'end_seconds': round(audio_offset + spoken_groups[-1]['end_seconds'], 6),
        }
        cues.append(cue)
    return cues, raw


def merge_collapsed_words(cues: list[dict], body: str) -> tuple[list[dict], list[dict]]:
    """Use existing DTW boundaries for short phrases when a word collapses."""
    cues = [dict(cue) for cue in cues]
    parts = [[cue['text']] for cue in cues]
    encoded = body.encode('utf-16-le')
    merged = []
    index = 0
    while index < len(cues):
        cue = cues[index]
        if cue['end_seconds'] > cue['start_seconds']:
            index += 1
            continue
        left = index if index + 1 < len(cues) else index - 1
        right = left + 1
        if left < 0 or len(parts[left]) + len(parts[right]) > 3:
            index += 1
            continue
        first, last = cues[left], cues[right]
        combined = {
            'text': encoded[first['start_offset'] * 2:last['end_offset'] * 2].decode('utf-16-le'),
            'start_offset': first['start_offset'], 'end_offset': last['end_offset'],
            'start_seconds': first['start_seconds'], 'end_seconds': last['end_seconds'],
        }
        components = parts[left] + parts[right]
        merged.append({**combined, 'canonical_words': components,
                       'reason': 'Zero-duration DTW word joined adjacent measured boundaries.'})
        cues[left:right + 1] = [combined]
        parts[left:right + 1] = [components]
        index = left
    return cues, merged


def align_record(model, tokenizer, metadata: Path) -> dict:
    from mlx_audio.stt.models.whisper.audio import N_FRAMES, N_SAMPLES, pad_or_trim
    from mlx_audio.stt.models.whisper.timing import find_alignment

    structural = validate_metadata(metadata)
    result = {
        'metadata': str(metadata), 'character': structural.get('character'),
        'story_slug': structural.get('story_slug'), 'ok': False,
        'errors': list(structural['errors']), 'warnings': [], 'paragraphs': [], 'words': [],
    }
    if not structural['ok']:
        return result
    result['source_sha256'] = {
        'wav_sha256': structural['details']['wav_hash']['actual_sha256'],
        'mp3_sha256': structural['details']['mp3_hash']['actual_sha256'],
        'text_sha256': structural['details']['text_sha256'],
    }
    for index, paragraph in enumerate(structural['segments'], 1):
        started = time.monotonic()
        audio, diagnostic = _paragraph_pcm(Path(structural['wav_path']), paragraph)
        mel, num_frames = model._prepare_audio(audio, padding=N_SAMPLES)
        mel = pad_or_trim(mel, N_FRAMES, axis=-2).astype(model.dtype)
        tokens = tokenizer.encode(' ' + paragraph['text'])
        if len(tokens) + len(tokenizer.sot_sequence) + 2 > model.dims.n_text_ctx:
            raise ValueError('Canonical paragraph exceeds Whisper text context.')
        alignment = find_alignment(model, tokenizer, tokens, mel, num_frames)
        cues, raw = _map_alignment(alignment, paragraph, diagnostic['audio_offset_seconds'])
        canonical_count = len(cues)
        collapsed = [cue['text'] for cue in cues if cue['end_seconds'] <= cue['start_seconds']]
        cues, merged = merge_collapsed_words(cues, structural['text'])
        boundary_errors = validate_paragraph_cues(cues, paragraph, diagnostic)
        result['errors'].extend(f'Paragraph {index}: {error}' for error in boundary_errors)
        probabilities = [word['probability'] for word in raw if word['probability'] is not None
                         and any(char.isalnum() for char in word['text'])]
        zero_words = [cue['text'] for cue in cues if cue['end_seconds'] <= cue['start_seconds']]
        low_confidence = [word['text'].strip() for word in raw
                          if word['probability'] is not None and word['probability'] < 0.2
                          and any(char.isalnum() for char in word['text'])]
        long_words = [cue['text'] for cue in cues if cue['end_seconds'] - cue['start_seconds'] > 1.2]
        diagnostic.update({
            'paragraph_index': index,
            'canonical_word_count': canonical_count,
            'cue_count': len(cues),
            'original_zero_duration_words': collapsed,
            'merged_groups': merged,
            'boundary_errors': boundary_errors,
            'zero_duration_words': zero_words,
            'low_probability_token_groups': low_confidence,
            'longer_than_1_2_seconds': long_words,
            'minimum_token_group_probability': min(probabilities) if probabilities else None,
            'raw_alignment': raw,
            'processing_seconds': round(time.monotonic() - started, 3),
        })
        result['paragraphs'].append(diagnostic)
        result['words'].extend(cues)
        if low_confidence or long_words:
            result['warnings'].append(f'Paragraph {index}: low-probability or long word boundaries require review.')
        print(f'{metadata.parent.name}/{metadata.stem} paragraph {index}: '
              f'{len(cues)} words, zero={len(zero_words)}, low_probability={len(low_confidence)}', flush=True)
    result['errors'].extend(validate_word_cues(result['words'], structural['text'], structural['duration_seconds']))
    result['ok'] = not result['errors']
    return result


def install_alignment(output: Path, result: dict, model_details: dict) -> None:
    metadata = Path(result['metadata'])
    item = json.loads(metadata.read_text(encoding='utf-8'))
    source = result['source_sha256']
    if any(item.get(key) != expected for key, expected in source.items()):
        raise ValueError('Source checksums changed after alignment; refusing stale word cues.')
    if item.get('story_slug') != result['story_slug'] or item.get('character') != result['character']:
        raise ValueError('Story or character changed after alignment; refusing stale word cues.')
    current_story = json.loads((output / 'story_inputs' / f'{item["story_slug"]}.json').read_text(encoding='utf-8'))
    current_text_hash = hashlib.sha256(current_story['body'].encode('utf-8')).hexdigest()
    if current_text_hash != source['text_sha256']:
        raise ValueError('Exact story text changed after alignment; refusing stale word cues.')
    for kind in ('wav', 'mp3'):
        if sha256(metadata.parent / item[kind]) != source[kind + '_sha256']:
            raise ValueError('Audio changed during alignment; refusing to install stale word cues.')
    item['words'] = result['words']
    item['word_alignment'] = {
        'method': METHOD, **model_details,
        'created_at': datetime.now(UTC).isoformat(),
        'timestamp_resolution_seconds': 0.02,
        'text_sha256': item['text_sha256'], 'wav_sha256': item['wav_sha256'],
        'warnings': result['warnings'],
        'paragraphs': [{key: value for key, value in paragraph.items() if key != 'raw_alignment'}
                       for paragraph in result['paragraphs']],
        'limitation': 'Canonical-text forced alignment estimates acoustic word boundaries; it does not verify voice quality or prove every word was spoken.',
    }
    manifest_path = output / 'manifest.json'
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    matched = False
    for track in manifest.get('tracks', []):
        if track.get('story_slug') == item['story_slug'] and track.get('character') == item['character']:
            if track.get('sha256') != source['mp3_sha256'] or track.get('text_sha256') != source['text_sha256']:
                raise ValueError('Installer manifest differs from aligned audio or story text.')
            track['words'] = result['words']
            matched = True
    if not matched:
        raise ValueError('Aligned story track is absent from the installer manifest.')
    # Validate both payloads before replacing either file. Replacements are
    # atomic individually; re-running recovers an interrupted pair of writes.
    metadata_json = _encoded_json(item)
    manifest_json = _encoded_json(manifest)
    _atomic_text(metadata, metadata_json)
    _atomic_text(manifest_path, manifest_json)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'media' / 'character_narration')
    parser.add_argument('--model-dir', required=True, type=Path, help='Existing local Whisper safetensors snapshot.')
    parser.add_argument('--story', '--story-slug', dest='stories', action='append')
    parser.add_argument('--character', action='append', choices=('nia', 'zuri', 'kai'))
    parser.add_argument('--write', action='store_true', help='Atomically install only complete valid word alignments.')
    parser.add_argument('--report', type=Path, help='Default: output-dir/word_alignment_qa.json.')
    args = parser.parse_args()
    output = args.output_dir.expanduser().resolve()
    selected = []
    for metadata in sorted(output.glob('*/*.json')):
        if metadata.parent.name in ('story_inputs', 'auditions'):
            continue
        if args.stories and metadata.parent.name not in args.stories:
            continue
        item = json.loads(metadata.read_text(encoding='utf-8'))
        if item.get('story_slug') and item.get('character') in (args.character or ['nia', 'zuri']):
            selected.append(metadata)
    if not selected:
        parser.error('No story tracks match the selected story/character.')
    model_path = args.model_dir.expanduser().resolve(strict=True)
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
    import mlx.core as mx
    from mlx_audio.stt.utils import load_model

    mx.set_cache_limit(64 * 1024 ** 2)
    model = load_model(model_path)
    tokenizer = model.get_tokenizer(language='en', task='transcribe')
    tokenizer.hf_tokenizer.clean_up_tokenization_spaces = False
    model_details = {
        'model_path': str(model_path), 'model_revision': model_path.name,
        'mlx_audio_version': importlib.metadata.version('mlx-audio'),
        'alignment_heads': model.alignment_heads.tolist(),
    }
    results = []
    for metadata in selected:
        try:
            result = align_record(model, tokenizer, metadata)
            if args.write and result['ok']:
                install_alignment(output, result, model_details)
                result['installed'] = True
        except Exception as exc:
            result = {'metadata': str(metadata), 'ok': False, 'errors': [f'{type(exc).__name__}: {exc}']}
        results.append(result)
    summary = {
        'records': len(results), 'valid': sum(result['ok'] for result in results),
        'failed': sum(not result['ok'] for result in results),
        'installed': sum(result.get('installed', False) for result in results),
        'word_cues': sum(len(result.get('words', [])) for result in results if result['ok']),
    }
    report = {
        'created_at': datetime.now(UTC).isoformat(), 'method': METHOD,
        'model': model_details, 'summary': summary, 'results': results,
    }
    destination = (args.report or output / 'word_alignment_qa.json').expanduser().resolve()
    atomic_json(destination, report)
    print(json.dumps(summary), flush=True)
    print(f'ALIGNMENT_REPORT={destination}', flush=True)
    return int(bool(summary['failed']))


if __name__ == '__main__':
    raise SystemExit(main())

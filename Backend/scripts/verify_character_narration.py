#!/usr/bin/env python3
"""Verify local character audio structure and optionally transcribe each passage.

Use --structural-only while TTS is generating. After the TTS process exits,
use the isolated mlx-audio environment and --model-dir with a downloaded
Whisper snapshot. ffprobe is required; no cloud speech API or text prompt is
used. Raw transcripts, timestamps, differences and word error rates are
diagnostics and do not establish voice quality. Recognition mismatches never
get removed to produce a passing score. --max-wer optionally sets an ASR
failure threshold; structural errors always produce a nonzero exit status.
"""

from __future__ import annotations

import difflib
import hashlib
import json
import math
import re
import shutil
import subprocess
import unicodedata
import wave
from pathlib import Path


SYNTHETIC_SOURCE = 'description-only-generated-synthetic-character'


def words(text: str) -> list[str]:
    """Normalize case/punctuation while preserving words and contractions."""
    normalized = unicodedata.normalize('NFKC', text).casefold()
    normalized = normalized.replace('\u2019', "'").replace('\u2018', "'")
    return re.findall(r"[^\W_]+(?:'[^\W_]+)*", normalized)


def edit_distance(expected_list: list[str], observed_list: list[str]) -> int:
    """Return word-level Levenshtein distance using one row of storage."""
    if len(observed_list) > len(expected_list):
        expected_list, observed_list = observed_list, expected_list
    previous = list(range(len(observed_list) + 1))
    for expected_index, expected_word in enumerate(expected_list, 1):
        current = [expected_index]
        for observed_index, observed_word in enumerate(observed_list, 1):
            current.append(min(
                previous[observed_index] + 1,
                current[observed_index - 1] + 1,
                previous[observed_index - 1] + (expected_word != observed_word),
            ))
        previous = current
    return previous[-1]


def differences(expected_list: list[str], observed_list: list[str]) -> list[dict]:
    """Describe differing word spans; these opcodes are separate from WER."""
    matcher = difflib.SequenceMatcher(None, expected_list, observed_list, autojunk=False)
    return [
        {
            'operation': operation,
            'expected_start': expected_start,
            'expected_end': expected_end,
            'observed_start': observed_start,
            'observed_end': observed_end,
            'expected': expected_list[expected_start:expected_end],
            'observed': observed_list[observed_start:observed_end],
        }
        for operation, expected_start, expected_end, observed_start, observed_end
        in matcher.get_opcodes()
        if operation != 'equal'
    ]


def _finite_number(value) -> bool:
    try:
        return type(value) in (int, float) and math.isfinite(value)
    except (OverflowError, ValueError):
        return False


def _json_float(value: str) -> float:
    number = float(value)
    if not math.isfinite(number):
        raise ValueError('non-finite JSON number')
    return number


def _invalid_json_constant(value: str):
    raise ValueError(f'invalid JSON numeric constant: {value}')


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def _json_object(path: Path, errors: list[str], label: str) -> dict | None:
    try:
        value = json.loads(path.read_text(encoding='utf-8'),
                           parse_float=_json_float, parse_constant=_invalid_json_constant)
    except (OSError, UnicodeError, ValueError) as exc:
        errors.append(f'{label}: cannot read JSON: {exc}')
        return None
    if not isinstance(value, dict):
        errors.append(f'{label}: expected a JSON object')
        return None
    return value


def _asset_path(directory: Path, filename, errors: list[str], label: str) -> Path | None:
    if not isinstance(filename, str) or not filename:
        errors.append(f'{label}: filename is missing or invalid')
        return None
    try:
        path = (directory / filename).resolve()
        if path.parent != directory.resolve():
            errors.append(f'{label}: filename must resolve inside the metadata directory')
            return None
        if not path.is_file():
            errors.append(f'{label}: file does not exist: {path}')
            return None
    except (OSError, RuntimeError, ValueError) as exc:
        errors.append(f'{label}: cannot resolve file: {exc}')
        return None
    return path


def _check_hash(path: Path, expected, errors: list[str], label: str) -> dict:
    details = {'expected_sha256': expected, 'actual_sha256': None, 'matches': False}
    valid_expected = isinstance(expected, str) and bool(re.fullmatch(r'[0-9a-fA-F]{64}', expected))
    if not valid_expected:
        errors.append(f'{label}: missing or invalid SHA256')
    try:
        details['actual_sha256'] = _sha256(path)
    except OSError as exc:
        errors.append(f'{label}: cannot hash file: {exc}')
        return details
    details['matches'] = valid_expected and details['actual_sha256'] == expected.lower()
    if valid_expected and not details['matches']:
        errors.append(f'{label}: SHA256 mismatch')
    return details


def _wav_details(path: Path, errors: list[str]) -> dict | None:
    try:
        with wave.open(str(path), 'rb') as audio:
            rate = audio.getframerate()
            channels = audio.getnchannels()
            width = audio.getsampwidth()
            frames = audio.getnframes()
            frame_bytes = channels * width
            decoded_bytes = 0
            for chunk in iter(lambda: audio.readframes(65536), b''):
                decoded_bytes += len(chunk)
            if decoded_bytes != frames * frame_bytes:
                errors.append('wav: PCM data length does not match its frame count')
            return {
                'sample_rate': rate,
                'channels': channels,
                'sample_width': width,
                'frames': frames,
                'duration_seconds': frames / rate,
                'compression': audio.getcomptype(),
                'complete_pcm_data': decoded_bytes == frames * frame_bytes,
            }
    except (OSError, EOFError, wave.Error, ValueError, ZeroDivisionError) as exc:
        errors.append(f'wav: cannot read PCM audio: {exc}')
        return None


def _mp3_details(path: Path, errors: list[str]) -> dict | None:
    executable = shutil.which('ffprobe')
    if executable is None:
        errors.append('mp3: ffprobe is required to verify decoded sample count')
        return None
    try:
        completed = subprocess.run(
            [executable, '-v', 'error', '-select_streams', 'a:0', '-show_frames',
             '-show_entries', 'stream=codec_name,sample_rate,channels:frame=nb_samples',
             '-of', 'json', str(path)],
            capture_output=True, text=True, check=True, timeout=120,
        )
        if completed.stderr.strip():
            errors.append(f'mp3: decoder reported errors: {completed.stderr.strip()}')
        probe = json.loads(completed.stdout)
        streams = probe.get('streams', [])
        if len(streams) != 1:
            errors.append('mp3: no readable audio stream')
            return None
        stream = streams[0]
        rate = int(stream['sample_rate'])
        channels = int(stream['channels'])
        decoded_frames = probe.get('frames', [])
        frames = sum(int(frame['nb_samples']) for frame in decoded_frames)
        if rate <= 0 or channels <= 0 or frames <= 0:
            errors.append('mp3: invalid decoded sample rate, channel count, or sample count')
            return None
        if stream.get('codec_name') != 'mp3':
            errors.append('mp3: audio codec is not MP3')
        return {
            'codec': stream.get('codec_name'),
            'sample_rate': rate,
            'channels': channels,
            'decoded_frames': frames,
            'duration_seconds': frames / rate,
        }
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError, AttributeError) as exc:
        reason = exc.stderr.strip() if isinstance(exc, subprocess.CalledProcessError) and exc.stderr else str(exc)
        errors.append(f'mp3: cannot decode audio with ffprobe: {reason}')
        return None


def _gap_details(path: Path, start: float, end: float, wav_info: dict) -> dict:
    rate = wav_info['sample_rate']
    start_frame, end_frame = round(start * rate), round(end * rate)
    with wave.open(str(path), 'rb') as audio:
        audio.setpos(start_frame)
        pcm = audio.readframes(end_frame - start_frame)
    expected_bytes = (end_frame - start_frame) * wav_info['channels'] * wav_info['sample_width']
    # Unsigned PCM8 represents silence as 128; wider integer PCM uses zero.
    silent_value = 128 if wav_info['sample_width'] == 1 else 0
    return {
        'start_seconds': start,
        'end_seconds': end,
        'frames': end_frame - start_frame,
        'duration_seconds': (end_frame - start_frame) / rate,
        'exactly_silent': len(pcm) == expected_bytes and all(value == silent_value for value in pcm),
    }


def validate_metadata(metadata: Path) -> dict:
    """Return JSON-safe findings for an audition or story metadata file.

    Ordinary missing files, malformed metadata, checksum failures and timing
    mismatches become entries in ``errors``. Story inputs are loaded relative
    to the narration output directory, preserving their exact UTF-8 body.
    """
    errors: list[str] = []
    details: dict = {}
    result = {
        'metadata': str(metadata), 'ok': False, 'errors': errors,
        'checks': {}, 'details': details, 'text': None, 'wav': None, 'mp3': None,
        'wav_path': None, 'mp3_path': None, 'duration_seconds': None,
        'sample_rate': None, 'segments': [],
    }
    try:
        metadata = Path(metadata).expanduser().resolve()
    except (OSError, RuntimeError, ValueError) as exc:
        errors.append(f'metadata: cannot resolve path: {exc}')
        return result
    result['metadata'] = str(metadata)
    item = _json_object(metadata, errors, 'metadata')
    if item is None:
        return result
    result['character'] = item.get('character')
    result['story_slug'] = item.get('story_slug')
    result['checks']['source'] = item.get('source') == SYNTHETIC_SOURCE
    if not result['checks']['source']:
        errors.append('source: expected a description-created synthetic character')
    if type(item.get('schema_version')) is not int or item['schema_version'] != 1:
        errors.append('schema_version: expected 1')

    wav_path = _asset_path(metadata.parent, item.get('wav'), errors, 'wav')
    mp3_path = _asset_path(metadata.parent, item.get('mp3'), errors, 'mp3')
    for kind, path in (('wav', wav_path), ('mp3', mp3_path)):
        if path is not None:
            result[kind] = str(path)
            result[kind + '_path'] = str(path)
            details[kind + '_hash'] = _check_hash(path, item.get(kind + '_sha256'), errors, kind)
            result['checks'][kind + '_sha256'] = details[kind + '_hash']['matches']
    wav_info = _wav_details(wav_path, errors) if wav_path else None
    mp3_info = _mp3_details(mp3_path, errors) if mp3_path else None
    details['wav'] = wav_info
    details['mp3'] = mp3_info
    duration = item.get('duration_seconds')
    duration_valid = _finite_number(duration) and duration > 0
    result['duration_seconds'] = duration if duration_valid else None
    if not duration_valid:
        errors.append('duration_seconds: expected a finite positive number')
    sample_rate = item.get('sample_rate')
    result['sample_rate'] = sample_rate if type(sample_rate) is int and sample_rate > 0 else None
    if type(sample_rate) is not int or sample_rate <= 0:
        errors.append('sample_rate: expected a positive integer')
    tolerance = 1 / wav_info['sample_rate'] if wav_info else 0
    if wav_info:
        result['checks']['sample_rate'] = sample_rate == wav_info['sample_rate']
        if not result['checks']['sample_rate']:
            errors.append('wav: sample rate differs from metadata')
        if duration_valid:
            delta = wav_info['duration_seconds'] - duration
            details['wav_duration_delta_seconds'] = delta
            result['checks']['wav_duration'] = abs(delta) <= tolerance + 1e-12
            if not result['checks']['wav_duration']:
                errors.append('wav: duration differs from metadata by more than one sample')
    if wav_info and mp3_info:
        result['checks']['mp3_sample_rate'] = mp3_info['sample_rate'] == wav_info['sample_rate']
        result['checks']['mp3_channels'] = mp3_info['channels'] == wav_info['channels']
        result['checks']['mp3_decoded_frames'] = abs(mp3_info['decoded_frames'] - wav_info['frames']) <= 1
        for key, message in (
            ('mp3_sample_rate', 'mp3: sample rate differs from WAV'),
            ('mp3_channels', 'mp3: channel count differs from WAV'),
            ('mp3_decoded_frames', 'mp3: decoded sample count differs from WAV by more than one sample'),
        ):
            if not result['checks'][key]:
                errors.append(message)

    is_story = 'story_slug' in item
    body = None
    if is_story:
        slug = item.get('story_slug')
        if not isinstance(slug, str) or not slug or slug in ('.', '..') or Path(slug).name != slug:
            errors.append('story_slug: expected a single nonempty filename component')
        else:
            story_path = metadata.parent.parent / 'story_inputs' / f'{slug}.json'
            details['story_input'] = str(story_path)
            story = _json_object(story_path, errors, 'story_input')
            if story is not None:
                if story.get('slug') != slug:
                    errors.append('story_input: slug differs from narration metadata')
                if story.get('title') != item.get('story_title'):
                    errors.append('story_input: title differs from narration metadata')
                body = story.get('body')
    else:
        body = item.get('text')
    if not isinstance(body, str) or not body.strip():
        errors.append('text: expected nonempty exact story body or audition text')
        body = None
    if body is not None:
        try:
            actual_text_hash = hashlib.sha256(body.encode('utf-8')).hexdigest()
            body.encode('utf-16-le')
        except UnicodeError:
            errors.append('text: unpaired Unicode surrogate in exact text')
            body = None
        else:
            result['text'] = body
            details['text_sha256'] = actual_text_hash
            expected_text_hash = item.get('text_sha256')
            # Existing audition metadata stores exact text without a text checksum.
            if is_story or expected_text_hash is not None:
                matches = expected_text_hash == actual_text_hash
                result['checks']['text_sha256'] = matches
                if not matches:
                    errors.append('text_sha256: exact text checksum differs from metadata')

    if is_story:
        character = item.get('character')
        if isinstance(character, str) and character and Path(character).name == character and character not in ('.', '..'):
            reference_path = metadata.parent.parent / 'auditions' / f'{character}.json'
            reference = _json_object(reference_path, errors, 'reference_metadata')
            if reference is not None:
                if reference.get('source') != SYNTHETIC_SOURCE or reference.get('character') != character:
                    errors.append('reference: provenance or character differs from story')
                reference_audio = _asset_path(reference_path.parent, reference.get('wav'), errors, 'reference_wav')
                if reference_audio is not None:
                    details['reference_hash'] = _check_hash(reference_audio, item.get('reference_sha256'), errors, 'reference')
                    result['checks']['reference_sha256'] = details['reference_hash']['matches']
                    if reference.get('wav_sha256') != item.get('reference_sha256'):
                        errors.append('reference: checksum differs from current reference metadata')
        else:
            errors.append('character: cannot locate synthetic reference metadata')

        segments = item.get('segments')
        measurements = item.get('paragraph_measurements')
        if not isinstance(segments, list) or not segments:
            errors.append('segments: expected a nonempty list')
            segments = []
        result['segments'] = segments
        if not isinstance(measurements, list) or len(measurements) != len(segments):
            errors.append('paragraph_measurements: expected one measurement per segment')
            measurements = []
        encoded = body.encode('utf-16-le') if body is not None else None
        text_cursor = 0
        previous_end = None
        segment_details = []
        gaps = []
        for index, segment in enumerate(segments):
            label = f'segment {index + 1}'
            if not isinstance(segment, dict):
                errors.append(f'{label}: expected an object')
                continue
            detail = {'index': index + 1}
            segment_details.append(detail)
            start_offset, end_offset = segment.get('start_offset'), segment.get('end_offset')
            offsets_valid = (
                type(start_offset) is int and type(end_offset) is int
                and encoded is not None
                and 0 <= start_offset < end_offset <= len(encoded) // 2
                and text_cursor <= start_offset
            )
            if not offsets_valid:
                errors.append(f'{label}: UTF16 offsets are invalid, overlapping, or out of bounds')
            else:
                try:
                    actual_text = encoded[start_offset * 2:end_offset * 2].decode('utf-16-le')
                    gap_text = encoded[text_cursor * 2:start_offset * 2].decode('utf-16-le')
                    detail['text_matches'] = actual_text == segment.get('text')
                    if not detail['text_matches']:
                        errors.append(f'{label}: UTF16 slice differs from segment text')
                    if gap_text.strip():
                        errors.append(f'{label}: offsets skip non-whitespace story text')
                    text_cursor = end_offset
                except UnicodeError:
                    errors.append(f'{label}: UTF16 offset splits a surrogate pair')
            start, end = segment.get('start_seconds'), segment.get('end_seconds')
            time_valid = _finite_number(start) and _finite_number(end) and 0 <= start < end
            if not time_valid:
                errors.append(f'{label}: times must be finite, nonnegative, and increasing')
                previous_end = None
                continue
            detail.update(start_seconds=start, end_seconds=end, duration_seconds=end - start)
            bounded = duration_valid and end <= duration + tolerance + 1e-12
            if wav_info:
                bounded = bounded and end <= wav_info['duration_seconds'] + tolerance + 1e-12
            if not bounded:
                errors.append(f'{label}: time extends beyond narration duration')
            if index == 0 and abs(start) > tolerance + 1e-12:
                errors.append(f'{label}: first paragraph must start at the beginning of audio')
            if previous_end is not None:
                if start < previous_end:
                    errors.append(f'{label}: paragraph times overlap or are out of order')
                elif wav_info and wav_path and bounded and start <= wav_info['duration_seconds']:
                    try:
                        gap = _gap_details(wav_path, previous_end, start, wav_info)
                        gaps.append(gap)
                        if not gap['exactly_silent']:
                            errors.append(f'{label}: transition gap contains non-silent or incomplete PCM data')
                    except (OSError, EOFError, wave.Error, ValueError) as exc:
                        errors.append(f'{label}: cannot inspect transition gap: {exc}')
            if index < len(measurements):
                measure = measurements[index]
                measured = measure.get('duration_seconds') if isinstance(measure, dict) else None
                if not _finite_number(measured) or measured <= 0:
                    errors.append(f'{label}: paragraph measurement duration is invalid')
                else:
                    detail['measured_duration_seconds'] = measured
                    detail['measurement_matches'] = abs((end - start) - measured) <= tolerance + 1e-12
                    if not detail['measurement_matches']:
                        errors.append(f'{label}: duration differs from paragraph measurement by more than one sample')
            previous_end = end
        if encoded is not None:
            details['utf16_length'] = len(encoded) // 2
            try:
                complete = not encoded[text_cursor * 2:].decode('utf-16-le').strip()
            except UnicodeError:
                complete = False
            result['checks']['full_text_coverage'] = complete
            if not complete:
                errors.append('segments: offsets do not cover all non-whitespace story text')
        if segments and previous_end is not None and duration_valid:
            result['checks']['final_segment_duration'] = abs(previous_end - duration) <= tolerance + 1e-12
            if not result['checks']['final_segment_duration']:
                errors.append('segments: final paragraph does not end at narration duration')
        details['segments'] = segment_details
        details['transition_gaps'] = gaps
    result['ok'] = not errors
    return result


def _json_safe(value):
    """Retain non-finite decoder metrics as labels in otherwise strict JSON."""
    if isinstance(value, float) and not math.isfinite(value):
        return str(value)
    if isinstance(value, dict):
        return {key: _json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_safe(item) for item in value]
    return value


def _transcribe_record(model, record: dict, settings: dict, seed: int) -> dict:
    import tempfile
    import time

    import mlx.core as mx
    import soundfile as sf

    audio, rate = sf.read(record['wav_path'], dtype='float32')
    passages = record['segments'] or [{
        'text': record['text'], 'start_seconds': 0.0,
        'end_seconds': record['duration_seconds'],
    }]
    transcripts = []
    all_expected, all_observed = [], []
    with tempfile.TemporaryDirectory(prefix='kingdom-kids-asr-') as temporary:
        for index, passage in enumerate(passages):
            first = round(passage['start_seconds'] * rate)
            last = round(passage['end_seconds'] * rate)
            duration = (last - first) / rate
            clip = Path(temporary) / f'paragraph-{index + 1}.wav'
            sf.write(clip, audio[first:last], rate, subtype='PCM_16')
            # Whisper's API calls its decoder token limit sample_len.
            # Derive the bound from audio seconds, independently of expected text.
            sample_len = settings['sample_len'] or min(224, max(48, math.ceil(duration * 8)))
            mx.random.seed(seed + index)
            started = time.monotonic()
            result = model.generate(
                str(clip), language='en', verbose=None,
                temperature=tuple(settings['temperature']),
                condition_on_previous_text=False, return_timestamps=True,
                repetition_penalty=settings['repetition_penalty'], sample_len=sample_len,
            )
            expected, observed = words(passage['text']), words(result.text)
            distance = edit_distance(expected, observed)
            anomalies = []
            for segment_index, segment in enumerate(result.segments or []):
                if not segment.get('text', '').strip():
                    continue
                start, end = segment.get('start'), segment.get('end')
                if (not _finite_number(start) or not _finite_number(end)
                        or start < 0 or end <= start or end > duration + 0.2):
                    anomalies.append({
                        'segment_index': segment_index, 'start': start, 'end': end,
                        'text': segment.get('text'),
                        'reason': 'Invalid timing or timing beyond physical clip duration.',
                    })
            transcripts.append({
                'paragraph_index': index + 1,
                'source_start_sample': first, 'source_end_sample': last,
                'start_seconds': passage['start_seconds'], 'end_seconds': passage['end_seconds'],
                'duration_seconds': duration, 'expected_text': passage['text'],
                'raw_transcript': result.text, 'raw_segments': result.segments,
                'expected_words': len(expected), 'recognized_words': len(observed),
                'edit_distance': distance,
                'word_error_rate': round(distance / max(1, len(expected)), 6),
                'differences': differences(expected, observed),
                'timestamp_anomalies': anomalies, 'sample_len': sample_len,
                'seed': seed + index, 'processing_seconds': round(time.monotonic() - started, 3),
            })
            all_expected.extend(expected)
            all_observed.extend(observed)
    total_distance = sum(item['edit_distance'] for item in transcripts)
    return _json_safe({
        'paragraphs': transcripts,
        'expected_words': len(all_expected), 'recognized_words': len(all_observed),
        'paragraph_edit_distance_total': total_distance,
        'word_error_rate': round(total_distance / max(1, len(all_expected)), 6),
        'joined_word_error_rate': round(edit_distance(all_expected, all_observed) / max(1, len(all_expected)), 6),
        'joined_differences': differences(all_expected, all_observed),
        'needs_review': any(item['differences'] or item['timestamp_anomalies'] for item in transcripts),
    })


def main() -> int:
    import argparse
    import importlib.metadata
    import os
    from datetime import UTC, datetime

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'media' / 'character_narration')
    parser.add_argument('--model-dir', type=Path, help='Downloaded local Whisper snapshot; needed for ASR.')
    parser.add_argument('--structural-only', action='store_true', help='Check audio and metadata without importing MLX.')
    parser.add_argument('--story', '--story-slug', dest='story', action='append', help='Only this story slug; repeat to select several.')
    parser.add_argument('--character', action='append', choices=('kai', 'nia', 'zuri'))
    parser.add_argument('--include-rejected', action='store_true', help='Also inspect rejected review assets.')
    parser.add_argument('--report', type=Path, help='Report path; defaults to structural_qa.json or audio_qa_verified.json.')
    parser.add_argument('--temperature', default='0.0,0.2,0.4,0.6', help='Whisper fallback temperature ladder.')
    parser.add_argument('--repetition-penalty', type=float, default=1.05)
    parser.add_argument('--sample-len', type=int, help='Optional decoder token bound, 1–224; default derives it from clip seconds.')
    parser.add_argument('--max-wer', type=float, help='Optional maximum raw WER per paragraph; never filters transcripts.')
    args = parser.parse_args()
    try:
        temperatures = [float(value) for value in args.temperature.split(',')]
    except ValueError:
        parser.error('--temperature must be comma-separated numbers.')
    if not temperatures or any(not math.isfinite(value) or value < 0 for value in temperatures):
        parser.error('--temperature values must be finite and nonnegative.')
    if not math.isfinite(args.repetition_penalty) or args.repetition_penalty < 1:
        parser.error('--repetition-penalty must be finite and at least 1.')
    if args.sample_len is not None and not 1 <= args.sample_len <= 224:
        parser.error('--sample-len must be between 1 and 224.')
    if args.max_wer is not None and (not math.isfinite(args.max_wer) or args.max_wer < 0):
        parser.error('--max-wer must be finite and nonnegative.')
    if not args.structural_only and args.model_dir is None:
        parser.error('ASR requires --model-dir; use --structural-only during TTS generation.')
    output = args.output_dir.expanduser().resolve()
    if not output.is_dir():
        parser.error('--output-dir must be an existing generated-audio directory.')
    selected = []
    for metadata in sorted(output.glob('*/*.json')):
        if metadata.parent.name == 'story_inputs' or (args.story and metadata.parent.name not in args.story):
            continue
        try:
            item = json.loads(metadata.read_text(encoding='utf-8'))
        except (OSError, UnicodeError, ValueError):
            item = {}
        if isinstance(item, dict):
            if not args.include_rejected and item.get('review_status') == 'rejected':
                continue
            if args.character and item.get('character') not in args.character:
                continue
        selected.append(metadata)
    if not selected:
        parser.error('No completed metadata records match the requested selection.')
    records = [validate_metadata(metadata) for metadata in selected]
    settings = {'temperature': temperatures, 'repetition_penalty': args.repetition_penalty,
                'sample_len': args.sample_len, 'return_timestamps': True,
                'condition_on_previous_text': False, 'expected_text_prompt': False}
    model_details = None
    if not args.structural_only and any(record['ok'] for record in records):
        model_path = args.model_dir.expanduser().resolve(strict=True)
        os.environ['HF_HUB_OFFLINE'] = '1'
        os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
        from mlx_audio.stt.utils import load_model
        import mlx.core as mx
        mx.set_cache_limit(64 * 1024 ** 2)
        model = load_model(model_path)
        model_details = {'path': str(model_path), 'revision': model_path.name,
                         'mlx_audio_version': importlib.metadata.version('mlx-audio')}
        for index, record in enumerate(records):
            if not record['ok']:
                continue
            print(f'Transcribing {Path(record["metadata"]).relative_to(output)}...', flush=True)
            try:
                record['asr'] = _transcribe_record(model, record, settings, 9911 + index * 100)
            except Exception as exc:
                record['asr_error'] = f'{type(exc).__name__}: {exc}'
    failed = sum(not record['ok'] for record in records)
    asr_errors = sum('asr_error' in record for record in records)
    review = sum(record.get('asr', {}).get('needs_review', False) for record in records)
    over_threshold = sum(
        args.max_wer is not None and any(paragraph['word_error_rate'] > args.max_wer
                                      for paragraph in record.get('asr', {}).get('paragraphs', []))
        for record in records
    )
    report = {
        'created_at': datetime.now(UTC).isoformat(), 'output_dir': str(output),
        'method': 'PCM/hash/UTF16/timing checks with optional paragraph-wise timestamped Whisper ASR',
        'structural_only': args.structural_only, 'model': model_details,
        'decoding': None if args.structural_only else settings,
        'limitation': 'Raw ASR mismatches and impossible timestamps are retained for review. Recognition does not establish timbre or subjective voice quality.',
        'summary': {'records': len(records), 'structural_failures': failed,
                    'asr_errors': asr_errors, 'asr_records_needing_review': review,
                    'max_word_error_rate': args.max_wer, 'asr_records_over_threshold': over_threshold},
        'results': records,
    }
    destination = (args.report or output / ('structural_qa.json' if args.structural_only else 'audio_qa_verified.json')).expanduser().resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + '.tmp')
    temporary.write_text(json.dumps(_json_safe(report), ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    temporary.replace(destination)
    print(json.dumps(report['summary']), flush=True)
    print(f'QA_REPORT={destination}', flush=True)
    return 1 if failed or asr_errors or over_threshold else 0


if __name__ == '__main__':
    raise SystemExit(main())

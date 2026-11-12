#!/usr/bin/env python3
"""Make three short, unmodified first-sentence narration listening montages.

By default this validates a completed batch and prints a read-only plan. Run
with --build only after the coordinator confirms that all fifteen measured
tracks and the final additional manifest are complete. No model, database,
voice generation, gain normalization, pitch shift, or speed change is used.
"""

from __future__ import annotations

import argparse
from datetime import UTC, datetime
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import wave


REPO = Path(__file__).resolve().parents[3]
WORK = REPO / 'Motion/story-expansion-blender-v1'
SOURCE = REPO / 'Backend/media/character_narration_additional_v1'
REVIEW = WORK / 'review/narration'
AUDIO = REVIEW / 'audio'
DESTINATION = AUDIO / 'first-sentences-v1'
CHARACTERS = ('kai', 'nia', 'zuri')
SLUGS = ('good-samaritan', 'joseph-colorful-coat', 'lost-sheep',
         'ruth-and-naomi', 'walls-of-jericho')
ORIGIN = 'description-only-generated-synthetic-character'
METHOD = 'whisper-canonical-cross-attention-dtw'


def read_json(path: Path) -> dict:
    value = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(value, dict):
        raise ValueError(f'Expected a JSON object: {path}')
    return value


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def relative(path: Path) -> str:
    return path.resolve().relative_to(REPO.resolve()).as_posix()


def local_asset(directory: Path, filename: object) -> Path:
    if not isinstance(filename, str) or Path(filename).name != filename:
        raise ValueError('Track audio must use a single local filename.')
    path = directory / filename
    if path.resolve().parent != directory.resolve() or not path.is_file():
        raise ValueError(f'Missing or redirected track asset: {path}')
    return path


def utf16_length(text: str) -> int:
    return len(text.encode('utf-16-le')) // 2


def first_sentence(body: str) -> tuple[str, int, int]:
    # These five hash-pinned openings contain no abbreviations. Keep closing
    # punctuation/quotes as part of the exact canonical sentence.
    start = len(body) - len(body.lstrip())
    ending = re.search(r'[.!?][”’"\')\]]*(?=\s|$)', body[start:])
    if ending is None:
        raise ValueError('The canonical opening has no complete sentence.')
    end = start + ending.end()
    return body[start:end], utf16_length(body[:start]), utf16_length(body[:end])


def sentence_cues(words: list[dict], start: int, end: int) -> list[dict]:
    selected = [cue for cue in words
                if cue['start_offset'] < end and cue['end_offset'] > start]
    if (not selected or selected[0]['start_offset'] != start
            or selected[-1]['end_offset'] != end):
        raise ValueError('No exact measured first-sentence boundary exists; '
                         'a grouped cue cannot be split into invented times.')
    return selected


def validators():
    # The actual installer validators are a pure standard-library module.
    # Compiling it directly avoids Django initialization and bytecode writes.
    path = REPO / 'Backend/Core/apps/stories/narration.py'
    namespace = {'__name__': 'sample_installer_validation'}
    exec(compile(path.read_text(encoding='utf-8'), str(path), 'exec'), namespace)
    return namespace['validated_narration_segments'], namespace['validated_narration_words']


def plan(silence_ms: int) -> dict:
    if not 250 <= silence_ms <= 1500:
        raise ValueError('Silence must be between 250 and 1500 milliseconds.')
    stage_path = WORK / 'data/narration-stage.json'
    manifest_path = SOURCE / 'additional-manifest.json'
    prepared_path = REVIEW / 'prepared-tracks.json'
    stage = read_json(stage_path)
    prepared = read_json(prepared_path)
    manifest = read_json(manifest_path)
    if (stage.get('version') != 1 or stage.get('expected_track_count') != 15
            or tuple(item['slug'] for item in stage['stories']) != SLUGS
            or tuple(item['character'] for item in stage['voices']) != CHARACTERS):
        raise ValueError('The stage is not the authorized five-story batch.')
    if (prepared.get('prepared') is not True or prepared.get('track_count') != 15
            or prepared.get('all_canonical_text_covered') is not True
            or prepared.get('existing_narration_unchanged') is not True):
        raise ValueError('Wait for the completed, validated fifteen-track package.')
    tracks = manifest.get('tracks')
    expected_pairs = {(slug, character) for slug in SLUGS for character in CHARACTERS}
    if (manifest.get('version') != 1 or manifest.get('source') != 'description-only synthetic'
            or manifest.get('auditions') != [] or not isinstance(tracks, list)
            or len(tracks) != 15
            or {(item['story_slug'], item['character']) for item in tracks} != expected_pairs):
        raise ValueError('The final manifest must contain exactly fifteen isolated story tracks.')
    installed = {(item['story_slug'], item['character']): item for item in tracks}
    passages_valid, words_valid = validators()
    snapshot = {relative(path): digest(path)
                for path in (stage_path, manifest_path, prepared_path)}
    bodies, references = {}, {}
    for record in stage['stories']:
        slug = record['slug']
        canonical_path = WORK / 'data/stories' / f'{slug}.json'
        staged_path = SOURCE / 'story_inputs' / f'{slug}.json'
        canonical, staged = read_json(canonical_path), read_json(staged_path)
        if (any(canonical[key] != staged.get(key) for key in ('slug', 'title', 'body'))
                or canonical['slug'] != slug or canonical['title'] != record['title']
                or hashlib.sha256(canonical['body'].encode('utf-8')).hexdigest() != record['text_sha256']
                or len(canonical['body'].split()) != record['word_count']):
            raise ValueError(f'Canonical or staged story text changed: {slug}')
        bodies[slug] = canonical
        snapshot.update({relative(path): digest(path) for path in (canonical_path, staged_path)})
    for record in stage['voices']:
        character = record['character']
        path = SOURCE / 'auditions' / f'{character}.json'
        reference = read_json(path)
        if (reference.get('source') != ORIGIN or reference.get('character') != character
                or any(reference.get(key) != record.get(key)
                       for key in ('avatar_key', 'review_status', 'selected_variant'))
                or reference.get('wav_sha256') != record['reference_wav_sha256']):
            raise ValueError(f'The accepted voice reference changed: {character}')
        wav = local_asset(path.parent, reference['wav'])
        if digest(wav) != record['reference_wav_sha256']:
            raise ValueError(f'The accepted reference audio changed: {character}')
        references[character] = record
        snapshot.update({relative(asset): digest(asset) for asset in (path, wav)})
    voices = []
    for character in CHARACTERS:
        clips, total_frames, sample_rate = [], 0, None
        for slug in SLUGS:
            path = SOURCE / slug / f'{character}.json'
            item = read_json(path)
            record, story = installed[(slug, character)], bodies[slug]
            alignment = item.get('word_alignment', {})
            if (type(item.get('schema_version')) is not int or item['schema_version'] != 1
                    or item.get('source') != ORIGIN or item.get('character') != character
                    or item.get('story_slug') != slug or item.get('story_title') != story['title']
                    or item.get('avatar_key') != references[character]['avatar_key']
                    or item.get('reference_sha256') != references[character]['reference_wav_sha256']
                    or item.get('text_sha256') != hashlib.sha256(story['body'].encode()).hexdigest()
                    or alignment.get('method') != METHOD
                    or alignment.get('text_sha256') != item.get('text_sha256')
                    or alignment.get('wav_sha256') != item.get('wav_sha256')):
                raise ValueError(f'Unvalidated or mismatched measured metadata: {path}')
            wav, mp3 = (local_asset(path.parent, item[kind]) for kind in ('wav', 'mp3'))
            for kind, asset in (('wav', wav), ('mp3', mp3)):
                observed = digest(asset)
                if observed != item[kind + '_sha256']:
                    raise ValueError(f'Source {kind.upper()} checksum changed: {asset}')
                snapshot[relative(asset)] = observed
            snapshot[relative(path)] = digest(path)
            duration = item.get('duration_seconds')
            if type(duration) not in (int, float) or not math.isfinite(duration) or duration <= 0:
                raise ValueError(f'Invalid narration duration: {path}')
            segments, words = item.get('segments'), item.get('words')
            if (not isinstance(segments, list) or not segments or not isinstance(words, list)
                    or not words or len(passages_valid(segments, story['body'], duration)) != len(segments)
                    or len(words_valid(words, story['body'], duration, segments)) != len(words)):
                raise ValueError(f'Installer paragraph/word timings are invalid: {path}')
            for key, expected in (
                ('file', mp3.relative_to(SOURCE.parent).as_posix()),
                ('sha256', item['mp3_sha256']), ('text_sha256', item['text_sha256']),
                ('avatar_key', item['avatar_key']), ('duration_seconds', duration),
                ('segments', segments), ('words', words),
            ):
                if record.get(key) != expected:
                    raise ValueError(f'Final installer {key} differs from metadata: {path}')
            sentence, start_offset, end_offset = first_sentence(story['body'])
            selected = sentence_cues(words, start_offset, end_offset)
            with wave.open(str(wav), 'rb') as audio:
                rate, frames = audio.getframerate(), audio.getnframes()
                if (audio.getnchannels(), audio.getsampwidth(), audio.getcomptype()) != (1, 2, 'NONE'):
                    raise ValueError(f'The source must be mono PCM16 WAV: {wav}')
                if rate != item.get('sample_rate') or abs(frames / rate - duration) > 1 / rate + 1e-12:
                    raise ValueError(f'Physical WAV duration/rate differs from metadata: {wav}')
                if sample_rate is not None and rate != sample_rate:
                    raise ValueError('Montage excerpts must share one original sample rate.')
                sample_rate = rate
                first = round(selected[0]['start_seconds'] * rate)
                last = round(selected[-1]['end_seconds'] * rate)
                if not 0 <= first < last <= frames:
                    raise ValueError(f'Measured excerpt exceeds physical PCM data: {wav}')
            silence_frames = round(rate * silence_ms / 1000)
            if clips:
                total_frames += silence_frames
            clips.append({
                'story_slug': slug, 'story_title': story['title'], 'text': sentence,
                'start_offset': start_offset, 'end_offset': end_offset,
                'source_wav': relative(wav), 'source_wav_sha256': item['wav_sha256'],
                'source_metadata': relative(path), 'source_metadata_sha256': snapshot[relative(path)],
                'measured_start_seconds': selected[0]['start_seconds'],
                'measured_end_seconds': selected[-1]['end_seconds'],
                'source_start_frame': first, 'source_end_frame': last,
                'montage_start_frame': total_frames,
                'montage_end_frame': total_frames + last - first,
                'cue_count': len(selected), 'alignment_warnings': alignment.get('warnings', []),
            })
            total_frames += last - first
        voices.append({'character': character, 'avatar_key': references[character]['avatar_key'],
                       'reference_wav_sha256': references[character]['reference_wav_sha256'],
                       'sample_rate': sample_rate, 'channels': 1, 'sample_width_bytes': 2,
                       'silence_frames_between_excerpts': round(sample_rate * silence_ms / 1000),
                       'frames': total_frames, 'duration_seconds': total_frames / sample_rate,
                       'clips': clips})
    fingerprint = hashlib.sha256(json.dumps(
        {'inputs': snapshot, 'silence_ms': silence_ms}, sort_keys=True,
    ).encode()).hexdigest()
    return {'schema_version': 1, 'scope': 'first-sentence-listening-samples',
            'story_order': list(SLUGS), 'silence_ms': silence_ms,
            'input_sha256': fingerprint, 'source_files': snapshot, 'voices': voices}


def assert_snapshot_unchanged(snapshot: dict) -> None:
    for filename, expected in snapshot.items():
        if digest(REPO / filename) != expected:
            raise ValueError(f'Source changed during sample preparation: {filename}')


def checked_mp3(path: Path, voice: dict) -> dict:
    probe = json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-select_streams', 'a:0', '-show_entries',
        'stream=codec_name,sample_rate,channels:format=duration', '-of', 'json', str(path),
    ]))
    streams = probe.get('streams', [])
    if (len(streams) != 1 or streams[0].get('codec_name') != 'mp3'
            or int(streams[0].get('sample_rate', 0)) != voice['sample_rate']
            or streams[0].get('channels') != voice['channels']):
        raise ValueError('Encoded MP3 changes the source rate/channels or codec.')
    decoded = subprocess.run([
        'ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin', '-i', str(path),
        '-map', '0:a:0', '-f', 's16le', '-c:a', 'pcm_s16le', 'pipe:1',
    ], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
    frame_size = voice['channels'] * voice['sample_width_bytes']
    if len(decoded) % frame_size or abs(len(decoded) // frame_size - voice['frames']) > 1:
        raise ValueError('Gapless decoded MP3 sample count differs from montage WAV.')
    return {'decoded_frames': len(decoded) // frame_size,
            'container_duration_seconds': float(probe['format']['duration'])}


def build(value: dict) -> dict:
    for executable in ('ffmpeg', 'ffprobe'):
        if not shutil.which(executable):
            raise ValueError(f'Missing local executable: {executable}')
    assert_snapshot_unchanged(value['source_files'])
    if DESTINATION.exists():
        existing = read_json(DESTINATION / 'manifest.json')
        if (existing.get('schema_version') != 1
                or existing.get('scope') != value['scope']
                or existing.get('input_sha256') != value['input_sha256']
                or existing.get('story_order') != list(SLUGS)
                or len(existing.get('voices', [])) != len(CHARACTERS)
                or tuple(voice['character'] for voice in existing['voices']) != CHARACTERS):
            raise ValueError('Existing samples use different inputs; refusing replacement.')
        for voice, expected in zip(existing['voices'], value['voices']):
            if (voice['frames'] != expected['frames']
                    or voice['sample_rate'] != expected['sample_rate']
                    or len(voice['clips']) != len(SLUGS)
                    or any(clip.get(key) != original[key]
                           for clip, original in zip(voice['clips'], expected['clips'])
                           for key in original)):
                raise ValueError('Existing sample cues differ from the measured plan.')
            for kind in ('wav', 'mp3'):
                asset = local_asset(DESTINATION, voice[kind])
                if digest(asset) != voice[kind + '_sha256']:
                    raise ValueError('Existing listening sample checksum differs; refusing replacement.')
            checked_mp3(DESTINATION / voice['mp3'], voice)
        return existing
    AUDIO.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.first-sentences-', dir=AUDIO) as temporary:
        staging = Path(temporary)
        for voice in value['voices']:
            wav = staging / f'{voice["character"]}.wav'
            mp3 = staging / f'{voice["character"]}.mp3'
            pcm_hash = hashlib.sha256()
            with wave.open(str(wav), 'wb') as target:
                target.setnchannels(voice['channels'])
                target.setsampwidth(voice['sample_width_bytes'])
                target.setframerate(voice['sample_rate'])
                for index, clip in enumerate(voice['clips']):
                    if index:
                        silence = b'\0\0' * voice['silence_frames_between_excerpts']
                        target.writeframesraw(silence)
                        pcm_hash.update(silence)
                    with wave.open(str(REPO / clip['source_wav']), 'rb') as original:
                        original.setpos(clip['source_start_frame'])
                        count = clip['source_end_frame'] - clip['source_start_frame']
                        pcm = original.readframes(count)
                    if len(pcm) != count * voice['sample_width_bytes'] * voice['channels']:
                        raise ValueError('Incomplete source PCM excerpt.')
                    target.writeframesraw(pcm)
                    pcm_hash.update(pcm)
                    clip['pcm_sha256'] = hashlib.sha256(pcm).hexdigest()
            with wave.open(str(wav), 'rb') as check:
                if check.getnframes() != voice['frames']:
                    raise ValueError('Montage WAV frame count differs from measured plan.')
            subprocess.run([
                'ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin',
                '-i', str(wav), '-map', '0:a:0', '-vn', '-map_metadata', '-1',
                '-c:a', 'libmp3lame', '-b:a', '128k', str(mp3),
            ], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            voice.update(wav=wav.name, mp3=mp3.name, wav_sha256=digest(wav),
                         mp3_sha256=digest(mp3), pcm_sha256=pcm_hash.hexdigest(),
                         mp3_validation=checked_mp3(mp3, voice))
        assert_snapshot_unchanged(value['source_files'])
        value.update(created_at=datetime.now(UTC).isoformat(), model_loaded=False,
                     source_audio_unchanged=True, builder_sha256=digest(Path(__file__)),
                     processing='Original PCM frame copies plus real zero-valued silence; '
                                'MP3 encoding only. No gain, pitch, speed, or voice processing.',
                     limitation='Short openings help listening review; they do not establish '
                                'quality or complete spoken coverage for the full recordings.')
        (staging / 'manifest.json').write_text(
            json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n',
            encoding='utf-8',
        )
        # Publish the three WAV/MP3 pairs and their provenance together.
        staging.rename(DESTINATION)
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', action='store_true',
                        help='Produce clips after the coordinator confirms batch completion.')
    parser.add_argument('--silence-ms', type=int, default=750)
    arguments = parser.parse_args()
    value = plan(arguments.silence_ms)
    if arguments.build:
        value = build(value)
    print(json.dumps({'built': arguments.build, 'model_loaded': False,
                      'destination': relative(DESTINATION),
                      'input_sha256': value['input_sha256'],
                      'voices': [{'character': voice['character'],
                                  'duration_seconds': voice['duration_seconds'],
                                  'sentences': [clip['text'] for clip in voice['clips']]}
                                 for voice in value['voices']]}, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError, wave.Error) as error:
        raise SystemExit(f'Listening samples were not produced: {error}')

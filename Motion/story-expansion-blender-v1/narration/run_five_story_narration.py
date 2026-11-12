#!/usr/bin/env python3
"""Prepare/resume only the five staged stories using existing accepted voices.

Preparation uses the standard library only. Heavy phases reuse the established
local generation/alignment/verification tools in separate subprocesses. They
must be launched only after the coordinator clears the shared runtime lane.
No existing story, reference, global manifest, package, or database is changed.
"""

from __future__ import annotations

import argparse
from datetime import UTC, datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import wave


REPO = Path(__file__).resolve().parents[3]
WORK = REPO / 'Motion/story-expansion-blender-v1'
STAGE = WORK / 'data/narration-stage.json'
OUTPUT = REPO / 'Backend/media/character_narration_additional_v1'
REVIEW = WORK / 'review/narration'
LEGACY = REPO / 'Backend/media/character_narration'
SCRIPTS = REPO / 'Backend/scripts'
CACHE = Path.home() / '.cache/kingdom-kids-voices'
PYTHON = CACHE / '.venv/bin/python'
TTS_MODEL = CACHE / 'models/models--mlx-community--Qwen3-TTS-12Hz-0.6B-Base-4bit/snapshots/0d6bb6fe33f92d47a507e23b9148940e8366ab5b'
ASR_MODEL = CACHE / 'models/models--openai--whisper-base.en/snapshots/911407f4214e0e1d82085af863093ec0b66f9cd6'
CHARACTERS = ('kai', 'nia', 'zuri')
SLUGS = ('good-samaritan', 'joseph-colorful-coat', 'lost-sheep', 'ruth-and-naomi', 'walls-of-jericho')
SOURCE = 'description-only-generated-synthetic-character'


def digest(path: Path) -> str:
    checksum = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(chunk)
    return checksum.hexdigest()


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding='utf-8'))


def atomic_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    temporary.replace(path)


def copy_exact(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if digest(source) != digest(destination):
            raise ValueError(f'Existing staged copy differs; refusing replacement: {destination}')
        return
    temporary = destination.with_suffix(destination.suffix + '.tmp')
    shutil.copyfile(source, temporary)
    if digest(source) != digest(temporary):
        raise ValueError(f'Copy checksum mismatch: {source}')
    temporary.replace(destination)


def protected_files() -> dict[str, str]:
    # Retain evidence that all previous stories and accepted voice references
    # remained byte-for-byte unchanged, rather than just relying on paths.
    return {str(path.relative_to(REPO)): digest(path)
            for path in sorted(LEGACY.rglob('*')) if path.is_file()}


def load_tool(filename: str):
    # These modules import no MLX at module scope. This is used only for exact
    # structural and cue validation; model loading lives inside their mains.
    sys.path.insert(0, str(SCRIPTS))
    specification = importlib.util.spec_from_file_location(filename.removesuffix('.py'), SCRIPTS / filename)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def prepare() -> dict:
    stage = read_json(STAGE)
    if stage.get('version') != 1 or stage.get('expected_track_count') != 15:
        raise ValueError('Unexpected staged narration version or track count.')
    if tuple(item['slug'] for item in stage['stories']) != SLUGS:
        raise ValueError('The staged five stories differ from the authorized batch.')
    if tuple(item['character'] for item in stage['voices']) != CHARACTERS:
        raise ValueError('The staged three accepted voices differ from the authorized batch.')
    if not PYTHON.is_file() or not TTS_MODEL.is_dir() or not ASR_MODEL.is_dir():
        raise ValueError('Required existing local runtime/model snapshots are missing.')
    for executable in ('ffmpeg', 'ffprobe'):
        if not shutil.which(executable):
            raise ValueError(f'Missing required local executable: {executable}')
    generator = load_tool('generate_character_narration.py')
    stories = []
    for expected in stage['stories']:
        slug = expected['slug']
        original = WORK / 'data/stories' / f'{slug}.json'
        story = read_json(original)
        checksum = hashlib.sha256(story['body'].encode('utf-8')).hexdigest()
        if checksum != expected['text_sha256'] or story['title'] != expected['title'] or story['slug'] != slug:
            raise ValueError(f'Canonical story changed: {slug}')
        for other in (LEGACY / 'story_inputs' / f'{slug}.json', LEGACY / 'story_inputs/additional' / f'{slug}.json'):
            candidate = read_json(other)
            if any(candidate.get(key) != story[key] for key in ('slug', 'title', 'body')):
                raise ValueError(f'Canonical input mismatch: {other}')
        if len(story['body'].split()) != expected['word_count']:
            raise ValueError(f'Canonical word count changed: {slug}')
        copy_exact(original, OUTPUT / 'story_inputs' / f'{slug}.json')
        segments = generator.story_segments(story['body'])
        stories.append({**expected, 'paragraphs': len(segments),
                        'paragraph_word_counts': [len(segment['text'].split()) for segment in segments],
                        'utf16_length': len(story['body'].encode('utf-16-le')) // 2,
                        'input': str(original.relative_to(REPO)),
                        'staged_input': str((OUTPUT / 'story_inputs' / f'{slug}.json').relative_to(REPO))})
    voices = []
    for expected in stage['voices']:
        character = expected['character']
        original = LEGACY / 'auditions' / f'{character}.json'
        reference = read_json(original)
        if reference.get('source') != SOURCE or reference.get('character') != character:
            raise ValueError(f'Reference provenance mismatch: {character}')
        for key in ('avatar_key', 'review_status', 'selected_variant'):
            if reference.get(key) != expected.get(key):
                raise ValueError(f'Accepted reference {key} changed: {character}')
        if character == 'kai' and reference.get('selected_variant') != 'boy2':
            raise ValueError('Kai must use the approved option 2/boy2.')
        if reference.get('review_status') not in ('approved', 'acceptable-preview'):
            raise ValueError(f'Voice reference was not previously accepted: {character}')
        for kind in ('wav', 'mp3'):
            filename = reference[kind]
            if Path(filename).name != filename:
                raise ValueError('Reference filename must be inside auditions.')
            asset = original.parent / filename
            if digest(asset) != reference[kind + '_sha256']:
                raise ValueError(f'Reference audio changed: {character}/{kind}')
            copy_exact(asset, OUTPUT / 'auditions' / filename)
        if reference['wav_sha256'] != expected['reference_wav_sha256']:
            raise ValueError(f'Staged reference WAV differs: {character}')
        copy_exact(original, OUTPUT / 'auditions' / original.name)
        with wave.open(str(original.parent / reference['wav'])) as audio:
            if (audio.getframerate(), audio.getnchannels(), audio.getsampwidth(), audio.getcomptype()) != (24000, 1, 2, 'NONE'):
                raise ValueError(f'Unexpected accepted reference audio format: {character}')
            duration = audio.getnframes() / audio.getframerate()
        voices.append({**expected, 'wav': str((original.parent / reference['wav']).relative_to(REPO)),
                       'metadata_sha256': digest(original), 'duration_seconds': duration,
                       'format': '24000Hz mono PCM16'})
    baseline = REVIEW / 'existing-narration-fingerprints.json'
    protected = protected_files()
    if baseline.exists():
        if protected != read_json(baseline)['files']:
            raise ValueError('Previous narration files changed after this batch was prepared; review before resuming.')
    else:
        atomic_json(baseline, {'created_at': datetime.now(UTC).isoformat(), 'files': protected})
    report = {'created_at': datetime.now(UTC).isoformat(), 'ok': True, 'model_loaded': False,
              'stage_sha256': digest(STAGE), 'expected_tracks': 15,
              'canonical_words_per_voice': sum(item['word_count'] for item in stories),
              'total_spoken_words': 3 * sum(item['word_count'] for item in stories),
              'stories': stories, 'voices': voices,
              'models': {'tts': str(TTS_MODEL), 'alignment_and_independent_asr': str(ASR_MODEL)},
              'output': str(OUTPUT), 'existing_files_protected': len(protected),
              'phase_order': ['generate', 'structural', 'align', 'asr', 'asr-compatible', 'package'],
              'notes': ['Accepted reference copies are byte-for-byte identical; no audition generation.',
                        'Only five new stories; no force regeneration or live database installation.',
                        'One model process at a time, using existing local snapshots in offline mode.']}
    atomic_json(REVIEW / 'preflight.json', report)
    return report


def selected_args() -> list[str]:
    return [argument for slug in SLUGS for argument in ('--story', slug)] + [argument for character in CHARACTERS for argument in ('--character', character)]


def run_logged(phase: str, command: list[str]) -> None:
    REVIEW.mkdir(parents=True, exist_ok=True)
    environment = {**os.environ, 'HF_HUB_OFFLINE': '1', 'HF_HUB_DISABLE_TELEMETRY': '1', 'TOKENIZERS_PARALLELISM': 'false', 'PYTHONUNBUFFERED': '1'}
    started = time.monotonic()
    with (REVIEW / f'{phase}.log').open('a', encoding='utf-8') as log:
        heading = json.dumps({'at': datetime.now(UTC).isoformat(), 'phase': phase, 'command': command})
        print(heading, flush=True)
        log.write(heading + '\n')
        log.flush()
        process = subprocess.Popen(command, cwd=REPO / 'Backend', env=environment, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, bufsize=1)
        for line in process.stdout:
            print(line, end='', flush=True)
            log.write(line)
            log.flush()
        result = process.wait()
    event = {'at': datetime.now(UTC).isoformat(), 'phase': phase, 'exit_code': result,
             'elapsed_seconds': round(time.monotonic() - started, 3)}
    with (REVIEW / 'batch-events.jsonl').open('a', encoding='utf-8') as stream:
        stream.write(json.dumps(event) + '\n')
    if result:
        raise RuntimeError(f'{phase} failed with status {result}; completed tracks remain resumable.')


def tracks() -> list[Path]:
    return [OUTPUT / slug / f'{character}.json' for slug in SLUGS for character in CHARACTERS]


def refresh_manifest() -> None:
    # Alignment installs two individually atomic files. A stopped process can
    # leave newer metadata than manifest; rebuilding recovers the pair safely.
    generator = load_tool('generate_character_narration.py')
    generator.export_installer_manifest(OUTPUT)


def repair_gapless_exports() -> None:
    """Recover LAME's minimum 47-sample final frame without changing speech.

    With MPEG-2 Layer III at 24kHz, this ffmpeg/LAME build may decode 47 samples
    when the final source frame contains only 1..46. Append precisely that
    existing decoder surplus as zero PCM samples, preserving all generated PCM
    and recording the tiny physical duration extension. Other failures stop.
    """
    verifier = load_tool('verify_character_narration.py')
    for metadata in tracks():
        if not metadata.is_file():
            continue
        result = verifier.validate_metadata(metadata)
        if result['ok']:
            continue
        if result['errors'] != ['mp3: decoded sample count differs from WAV by more than one sample']:
            raise ValueError(f'Invalid completed track requires review: {metadata}: {result["errors"]}')
        wav_info, mp3_info = result['details']['wav'], result['details']['mp3']
        remainder = wav_info['frames'] % 576
        surplus = mp3_info['decoded_frames'] - wav_info['frames']
        if (wav_info['sample_rate'] != 24000 or wav_info['channels'] != 1 or wav_info['sample_width'] != 2
                or not 1 <= remainder <= 46 or surplus != 47 - remainder
                or mp3_info['decoded_frames'] % 576 != 47):
            raise ValueError(f'Unexpected MP3 gapless mismatch; no automatic audio repair: {metadata}')
        item = read_json(metadata)
        if item.get('words') or item.get('word_alignment'):
            raise ValueError('Repair must happen before measured word alignment.')
        wav = metadata.parent / item['wav']
        mp3 = metadata.parent / item['mp3']
        backup = REVIEW / 'export-repairs' / item['story_slug'] / item['character']
        for original in (metadata, wav, mp3):
            copy_exact(original, backup / original.name)
        with wave.open(str(wav)) as original:
            parameters = original.getparams()
            pcm = original.readframes(parameters.nframes)
        padded = wav.with_name(wav.stem + '.gapless.tmp.wav')
        encoded = mp3.with_name(mp3.stem + '.gapless.tmp.mp3')
        with wave.open(str(padded), 'wb') as audio:
            audio.setparams(parameters)
            audio.writeframes(pcm + b'\0' * surplus * parameters.sampwidth * parameters.nchannels)
        subprocess.run([shutil.which('ffmpeg'), '-v', 'error', '-y', '-i', str(padded),
                        '-codec:a', 'libmp3lame', '-b:a', '96k', str(encoded)], check=True)
        errors = []
        decoded = verifier._mp3_details(encoded, errors)
        if errors or decoded['decoded_frames'] != parameters.nframes + surplus:
            raise ValueError(f'Gapless repair did not preserve exact sample count: {errors}')
        with wave.open(str(padded)) as audio:
            if audio.readframes(parameters.nframes) != pcm:
                raise ValueError('Gapless repair changed original generated PCM.')
        old_duration = item['duration_seconds']
        new_duration = round((parameters.nframes + surplus) / parameters.framerate, 6)
        item['duration_seconds'] = new_duration
        item['segments'][-1]['end_seconds'] = new_duration
        measurement = item['paragraph_measurements'][-1]
        measurement['generated_duration_seconds'] = measurement['duration_seconds']
        measurement['duration_seconds'] = round(measurement['duration_seconds'] + surplus / parameters.framerate, 6)
        measurement['export_silence_padding_samples'] = surplus
        repair = {'at': datetime.now(UTC).isoformat(), 'reason': '24kHz LAME minimum 47-sample gapless frame',
                  'original_wav_sha256': item['wav_sha256'], 'original_mp3_sha256': item['mp3_sha256'],
                  'original_pcm_frames': parameters.nframes, 'silence_padding_samples': surplus,
                  'padding_seconds': surplus / parameters.framerate, 'original_pcm_preserved': True,
                  'old_duration_seconds': old_duration, 'new_duration_seconds': new_duration,
                  'originals': str(backup.relative_to(REPO))}
        padded.replace(wav)
        encoded.replace(mp3)
        item['wav_sha256'] = digest(wav)
        item['mp3_sha256'] = digest(mp3)
        item['export_repairs'] = [*item.get('export_repairs', []), repair]
        atomic_json(metadata, item)
        atomic_json(backup / 'repair.json', repair)
        verified = verifier.validate_metadata(metadata)
        if not verified['ok']:
            raise ValueError(f'Repaired track validation failed: {verified["errors"]}')
        print(f'Repaired only gapless silence: {item["story_slug"]}/{item["character"]}, {surplus} zero samples.', flush=True)
    refresh_manifest()


def missing_alignment(metadata: Path) -> bool:
    if not metadata.is_file():
        return True
    item = read_json(metadata)
    alignment = item.get('word_alignment', {})
    if (not item.get('words') or alignment.get('method') != 'whisper-canonical-cross-attention-dtw'
            or alignment.get('text_sha256') != item.get('text_sha256')
            or alignment.get('wav_sha256') != item.get('wav_sha256')):
        return True
    story = read_json(OUTPUT / 'story_inputs' / f"{item['story_slug']}.json")
    aligner = load_tool('align_character_narration.py')
    return bool(aligner.validate_word_cues(item['words'], story['body'], item['duration_seconds']))


def package() -> dict:
    verifier = load_tool('verify_character_narration.py')
    aligner = load_tool('align_character_narration.py')
    refresh_manifest()
    manifest = read_json(OUTPUT / 'manifest.json')
    expected_pairs = {(slug, character) for slug in SLUGS for character in CHARACTERS}
    if len(manifest['tracks']) != 15 or {(track['story_slug'], track['character']) for track in manifest['tracks']} != expected_pairs:
        raise ValueError('Installer manifest must contain exactly the fifteen new tracks.')
    manifest_records = {(track['story_slug'], track['character']): track for track in manifest['tracks']}
    asr = read_json(REVIEW / 'independent-asr.json')
    asr_summary = asr['summary']
    if (asr.get('structural_only') or asr_summary.get('records') != 15
            or asr_summary.get('structural_failures') or asr_summary.get('asr_errors')):
        raise ValueError('All fifteen independent ASR diagnostics must complete before packaging.')
    asr_records = {(record.get('story_slug'), record.get('character')): record for record in asr['results']}
    if set(asr_records) != expected_pairs:
        raise ValueError('Independent ASR diagnostics do not cover exactly the new fifteen tracks.')
    compatible = read_json(REVIEW / 'independent-asr-token-compat.json')
    compatible_records = {(record['story_slug'], record['character']): record for record in compatible['results']}
    if (compatible['summary']['records'] != 15 or set(compatible_records) != expected_pairs
            or compatible['settings'].get('expected_text_prompt') is not False
            or compatible.get('tokenizer_adapter', {}).get('snapshot_no_speech_token_id') != 50361):
        raise ValueError('Completed prompt-free ASR with the verified snapshot token adapter is required.')
    summaries = []
    for path in tracks():
        item = read_json(path)
        result = verifier.validate_metadata(path)
        if not result['ok']:
            raise ValueError(f'Invalid audio metadata: {path}: {result["errors"]}')
        if missing_alignment(path):
            raise ValueError(f'Measured full-coverage word cues are missing: {path}')
        problems = aligner.validate_word_cues(item['words'], result['text'], item['duration_seconds'])
        if problems:
            raise ValueError(f'Invalid word alignment: {path}: {problems}')
        installed = manifest_records[(item['story_slug'], item['character'])]
        expected_file = (path.parent / item['mp3']).relative_to(OUTPUT.parent).as_posix()
        for key, expected in (('file', expected_file), ('sha256', item['mp3_sha256']),
                              ('text_sha256', item['text_sha256']), ('segments', item['segments']),
                              ('words', item['words']), ('duration_seconds', item['duration_seconds']),
                              ('avatar_key', item['avatar_key'])):
            if installed.get(key) != expected:
                raise ValueError(f'Installer manifest {key} differs from validated track: {path}')
        if aligner.validate_word_cues(installed['words'], result['text'], installed['duration_seconds']):
            raise ValueError(f'Installer manifest does not retain complete measured cues: {path}')
        observed = asr_records[(item['story_slug'], item['character'])]
        for kind in ('wav', 'mp3'):
            if observed['details'][kind + '_hash']['actual_sha256'] != item[kind + '_sha256']:
                raise ValueError(f'Audio changed after independent ASR: {path}')
        corrected = compatible_records[(item['story_slug'], item['character'])]
        for key in ('wav_sha256', 'text_sha256', 'reference_sha256'):
            if corrected[key] != item[key]:
                raise ValueError(f'Track changed after corrected independent ASR: {path}')
        if len(corrected['paragraphs']) != len(item['segments']):
            raise ValueError(f'Corrected independent ASR did not inspect every paragraph: {path}')
        if any(paragraph['word_error_rate'] > 0.10 for paragraph in corrected['paragraphs']):
            raise ValueError(f'Large corrected ASR difference needs review before packaging: {path}')
        summaries.append({'story_slug': item['story_slug'], 'story_title': item['story_title'],
                          'character': item['character'], 'duration_seconds': item['duration_seconds'],
                          'text_sha256': item['text_sha256'], 'reference_sha256': item['reference_sha256'],
                          'wav_sha256': item['wav_sha256'], 'mp3_sha256': item['mp3_sha256'],
                          'mp3': str((path.parent / item['mp3']).relative_to(REPO)),
                          'word_cues': len(item['words']), 'full_text_coverage': True,
                          'alignment_warnings': item['word_alignment']['warnings'],
                          'initial_timestamped_asr_word_error_rate': observed['asr']['word_error_rate'],
                          'raw_asr_word_error_rate': corrected['word_error_rate'],
                          'asr_needs_review': corrected['needs_review'],
                          'quality_review': item['quality_review']})
    # Story-only installer manifest deliberately omits accepted narrator samples.
    # Existing samples stay unchanged when root explicitly installs the tracks.
    installer = {**manifest, 'auditions': []}
    atomic_json(OUTPUT / 'additional-manifest.json', installer)
    if protected_files() != read_json(REVIEW / 'existing-narration-fingerprints.json')['files']:
        raise ValueError('An existing narration file changed; refusing to mark preparation complete.')
    report = {'created_at': datetime.now(UTC).isoformat(), 'prepared': True, 'installed': False,
              'tracks': summaries, 'track_count': len(summaries),
              'duration_seconds': sum(item['duration_seconds'] for item in summaries),
              'word_cue_count': sum(item['word_cues'] for item in summaries),
              'all_canonical_text_covered': True, 'existing_narration_unchanged': True,
              'installer_manifest': str(OUTPUT / 'additional-manifest.json'),
              'independent_asr_report': str(REVIEW / 'independent-asr.json'),
              'independent_asr_summary': asr_summary,
              'corrected_independent_asr_report': str(REVIEW / 'independent-asr-token-compat.json'),
              'corrected_independent_asr_summary': compatible['summary'],
              'tokenizer_adapter': compatible['tokenizer_adapter'],
              'disclosure': 'AI-generated narration; these tracks use previously accepted original synthetic character voices.',
              'review_note': 'New recordings require listening review. Original looping decoder reports, corrected raw ASR differences, and alignment warnings are retained; ASR differences do not alone prove speech errors.'}
    atomic_json(REVIEW / 'prepared-tracks.json', report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('prepare', 'generate', 'structural', 'align', 'asr', 'asr-compatible', 'package', 'all'), default='prepare', nargs='?')
    args = parser.parse_args()
    report = prepare()
    if args.phase == 'prepare':
        print(json.dumps({'ok': report['ok'], 'model_loaded': False, 'tracks': 15,
                          'spoken_words': report['total_spoken_words'], 'preflight': str(REVIEW / 'preflight.json')}), flush=True)
        return 0
    if args.phase in ('generate', 'structural', 'align', 'all'):
        repair_gapless_exports()
    phases = ('generate', 'structural', 'align', 'asr', 'asr-compatible', 'package') if args.phase == 'all' else (args.phase,)
    for phase in phases:
        if phase == 'generate':
            if all(path.is_file() for path in tracks()):
                verifier = load_tool('verify_character_narration.py')
                if not all(verifier.validate_metadata(path)['ok'] for path in tracks()):
                    raise ValueError('A completed track is invalid; inspect it without automatic force regeneration.')
                refresh_manifest()
                print('All fifteen completed tracks valid; speech synthesis already done.', flush=True)
                continue
            command = [str(PYTHON), str(SCRIPTS / 'generate_character_narration.py'), 'story', '--character', 'accepted',
                       '--story-dir', str(OUTPUT / 'story_inputs'), '--output-dir', str(OUTPUT), '--model-dir', str(TTS_MODEL)]
        elif phase == 'structural':
            if not all(path.is_file() for path in tracks()):
                raise ValueError('All fifteen tracks are required before structural checks.')
            command = [str(PYTHON), str(SCRIPTS / 'verify_character_narration.py'), '--output-dir', str(OUTPUT),
                       '--structural-only', '--report', str(REVIEW / 'structural.json'), *selected_args()]
        elif phase == 'align':
            if not all(path.is_file() for path in tracks()):
                raise ValueError('All fifteen tracks are required before alignment.')
            refresh_manifest()
            # Character invocations allow safe resume without recomputing complete
            # measured cues. Each invocation releases Whisper before the next.
            for character in CHARACTERS:
                pending = [slug for slug in SLUGS if missing_alignment(OUTPUT / slug / f'{character}.json')]
                if not pending:
                    print(f'{character}: all measured word timings already valid.', flush=True)
                    continue
                run_logged(f'align-{character}', [str(PYTHON), str(SCRIPTS / 'align_character_narration.py'),
                           '--output-dir', str(OUTPUT), '--model-dir', str(ASR_MODEL), '--character', character,
                           '--write', '--report', str(REVIEW / f'align-{character}.json'),
                           *[argument for slug in pending for argument in ('--story', slug)]])
            continue
        elif phase == 'asr':
            command = [str(PYTHON), str(SCRIPTS / 'verify_character_narration.py'), '--output-dir', str(OUTPUT),
                       '--model-dir', str(ASR_MODEL), '--report', str(REVIEW / 'independent-asr.json'), *selected_args()]
        elif phase == 'asr-compatible':
            command = [str(PYTHON), str(WORK / 'narration/verify_plain_asr.py'), '--token-compat']
        else:
            print(json.dumps({'prepared': package()['prepared'], 'tracks': 15, 'installed': False}), flush=True)
            continue
        run_logged(phase, command)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

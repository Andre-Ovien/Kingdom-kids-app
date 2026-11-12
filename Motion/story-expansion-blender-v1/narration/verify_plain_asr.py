#!/usr/bin/env python3
"""Additional prompt-free text-only ASR after timestamp decoder anomalies.

The original timestamped ASR report stays unchanged. This records every raw
text output/difference without filtering repetitions or supplying expected
story text to recognition. It never alters recordings, voice references, cues,
shared tools, or database rows.
"""

from __future__ import annotations

from datetime import UTC, datetime
import hashlib
import argparse
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import time
import wave

REPO = Path(__file__).resolve().parents[3]
OUTPUT = REPO / 'Backend/media/character_narration_additional_v1'
REVIEW = REPO / 'Motion/story-expansion-blender-v1/review/narration'
MODEL = Path.home() / '.cache/kingdom-kids-voices/models/models--openai--whisper-base.en/snapshots/911407f4214e0e1d82085af863093ec0b66f9cd6'
SLUGS = ('good-samaritan', 'joseph-colorful-coat', 'lost-sheep', 'ruth-and-naomi', 'walls-of-jericho')
CHARACTERS = ('kai', 'nia', 'zuri')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--token-compat', action='store_true', help='Use this snapshot\'s actual no-speech token; preserve both unadapted reports.')
    args = parser.parse_args()
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
    sys.path.insert(0, str(REPO / 'Backend/scripts'))
    from verify_character_narration import validate_metadata, words, edit_distance, differences
    import mlx.core as mx
    from mlx_audio.stt.utils import load_model
    import importlib.metadata
    mx.set_cache_limit(64 * 1024 ** 2)
    model = load_model(MODEL)
    adapter = None
    if args.token_compat:
        # This snapshot calls no-speech <|nocaptions|>. mlx-audio's generic
        # <|nospeech|> lookup returns its unknown token, which equals EOS;
        # suppressing that prevents normal recognition termination. Adapt
        # only this model instance and record the exact observed token IDs.
        original_get_tokenizer = model.get_tokenizer
        original = original_get_tokenizer(language='en', task='transcribe')
        actual = original.hf_tokenizer.get_vocab().get('<|nocaptions|>')
        if original.no_speech != original.eot or actual is None or actual == original.eot:
            raise ValueError('The observed snapshot/tokenizer mismatch differs; no adapter applied.')
        adapter = {'scope': 'this model instance only; no package/source files modified',
                   'incorrect_lookup': '<|nospeech|>', 'incorrect_token_id': original.no_speech,
                   'end_of_text_token_id': original.eot,
                   'snapshot_no_speech_token': '<|nocaptions|>', 'snapshot_no_speech_token_id': actual}
        class SnapshotTokenizer(type(original)):
            @property
            def no_speech(self):
                return self.hf_tokenizer.get_vocab()['<|nocaptions|>']
        def snapshot_tokenizer(language=None, task='transcribe'):
            current = original_get_tokenizer(language=language, task=task)
            return SnapshotTokenizer(current.hf_tokenizer, current.multilingual,
                                     current.num_languages, current.language, current.task)
        model.get_tokenizer = snapshot_tokenizer
        print(json.dumps({'tokenizer_compatibility': adapter}), flush=True)
    results = []
    settings = {'language': 'en', 'temperature': 0.0, 'condition_on_previous_text': False,
                'return_timestamps': False, 'repetition_penalty': 1.0,
                'expected_text_prompt': False, 'hotwords': None,
                'sample_len': 'min(224,max(48,ceil(physical_clip_seconds*8)))'}
    with tempfile.TemporaryDirectory(prefix='kingdom-kids-plain-asr-') as directory:
        for slug in SLUGS:
            for character in CHARACTERS:
                metadata = OUTPUT / slug / f'{character}.json'
                item = json.loads(metadata.read_text(encoding='utf-8'))
                verified = validate_metadata(metadata)
                if not verified['ok']:
                    raise ValueError(f'Invalid audio before additional ASR: {verified["errors"]}')
                print(f'Text-only ASR: {slug}/{character}', flush=True)
                with wave.open(verified['wav_path']) as source:
                    parameters = source.getparams()
                    passages = []
                    for index, segment in enumerate(item['segments']):
                        first = round(segment['start_seconds'] * parameters.framerate)
                        last = round(segment['end_seconds'] * parameters.framerate)
                        source.setpos(first)
                        pcm = source.readframes(last - first)
                        clip = Path(directory) / f'{slug}-{character}-{index}.wav'
                        with wave.open(str(clip), 'wb') as target:
                            target.setparams(parameters)
                            target.writeframes(pcm)
                        duration = (last - first) / parameters.framerate
                        bound = min(224, max(48, math.ceil(duration * 8)))
                        mx.random.seed(11001 + len(results) * 100 + index)
                        began = time.monotonic()
                        recognized = model.generate(str(clip), language='en', verbose=None,
                                                    temperature=0.0, condition_on_previous_text=False,
                                                    return_timestamps=False, repetition_penalty=1.0,
                                                    sample_len=bound)
                        expected, observed = words(segment['text']), words(recognized.text)
                        distance = edit_distance(expected, observed)
                        passages.append({'paragraph_index': index + 1,
                                         'start_seconds': segment['start_seconds'],
                                         'end_seconds': segment['end_seconds'], 'physical_duration_seconds': duration,
                                         'source_pcm_sha256': hashlib.sha256(pcm).hexdigest(),
                                         'expected_text': segment['text'], 'raw_transcript': recognized.text,
                                         'raw_segments': recognized.segments,
                                         'expected_words': len(expected), 'recognized_words': len(observed),
                                         'edit_distance': distance, 'word_error_rate': round(distance / max(1, len(expected)), 6),
                                         'differences': differences(expected, observed),
                                         'sample_len': bound, 'processing_seconds': round(time.monotonic() - began, 3)})
                expected_count = sum(p['expected_words'] for p in passages)
                edits = sum(p['edit_distance'] for p in passages)
                results.append({'story_slug': slug, 'character': character,
                                'metadata': str(metadata), 'wav_sha256': item['wav_sha256'],
                                'text_sha256': item['text_sha256'], 'reference_sha256': item['reference_sha256'],
                                'paragraphs': passages, 'expected_words': expected_count,
                                'edit_distance': edits, 'word_error_rate': round(edits / expected_count, 6),
                                'needs_review': bool(edits)})
    report = {'created_at': datetime.now(UTC).isoformat(), 'method': 'Additional independent prompt-free text-only greedy Whisper ASR',
              'reason': 'Timestamped decoder emitted false segments after the physical clips ended; original raw report preserved.',
              'model': {'path': str(MODEL), 'revision': MODEL.name, 'mlx_audio_version': importlib.metadata.version('mlx-audio')},
              'settings': settings, 'summary': {'records': len(results),
                                              'expected_words': sum(r['expected_words'] for r in results),
                                              'edit_distance': sum(r['edit_distance'] for r in results),
                                              'records_needing_review': sum(r['needs_review'] for r in results)},
              'results': results,
              'tokenizer_adapter': adapter,
              'limitation': 'Raw ASR differences may be recognition errors or speech differences; no timbre/voice quality conclusion.'}
    destination = REVIEW / ('independent-asr-token-compat.json' if args.token_compat else 'independent-asr-text-only.json')
    temporary = destination.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(report, indent=2, ensure_ascii=False, allow_nan=False) + '\n', encoding='utf-8')
    temporary.replace(destination)
    print(json.dumps(report['summary']), flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

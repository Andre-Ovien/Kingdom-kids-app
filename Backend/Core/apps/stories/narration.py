"""Validate recorded text boundaries without inventing word timings."""

import math


def validated_narration_segments(segments, body, duration_seconds):
    if not isinstance(segments, list) or len(segments) > 512:
        return []
    if (
        type(duration_seconds) not in (int, float)
        or not math.isfinite(duration_seconds)
        or duration_seconds <= 0
    ):
        return []
    encoded = body.encode('utf-16-le')
    length = len(encoded) // 2
    result = []
    last_offset = 0
    last_time = 0
    for segment in segments:
        if not isinstance(segment, dict):
            return []
        start = segment.get('start_offset')
        end = segment.get('end_offset')
        start_seconds = segment.get('start_seconds')
        end_seconds = segment.get('end_seconds')
        text = segment.get('text')
        if (
            type(start) is not int
            or type(end) is not int
            or not last_offset <= start < end <= length
            or not isinstance(text, str)
            or not text.strip()
            or type(start_seconds) not in (int, float)
            or type(end_seconds) not in (int, float)
            or not math.isfinite(start_seconds)
            or not math.isfinite(end_seconds)
            or not last_time <= start_seconds < end_seconds <= duration_seconds
        ):
            return []
        try:
            actual_text = encoded[start * 2:end * 2].decode('utf-16-le')
        except UnicodeDecodeError:
            return []
        if actual_text != text:
            return []
        result.append({
            'text': text,
            'start_offset': start,
            'end_offset': end,
            'start_seconds': start_seconds,
            'end_seconds': end_seconds,
        })
        last_offset = end
        last_time = end_seconds
    return result


def validated_narration_words(words, body, duration_seconds, segments):
    """Require complete exact text and times inside each recorded paragraph."""
    cues = validated_narration_segments(words, body, duration_seconds)
    passages = validated_narration_segments(segments, body, duration_seconds)
    if not cues or not passages:
        return []
    encoded = body.encode('utf-16-le')
    cursor = 0
    passage_index = 0
    for cue in cues:
        if encoded[cursor * 2:cue['start_offset'] * 2].decode('utf-16-le').strip():
            return []
        cursor = cue['end_offset']
        while passage_index < len(passages) and passages[passage_index]['end_offset'] <= cue['start_offset']:
            passage_index += 1
        if passage_index >= len(passages):
            return []
        passage = passages[passage_index]
        if not (
            passage['start_offset'] <= cue['start_offset'] < cue['end_offset'] <= passage['end_offset']
            and passage['start_seconds'] <= cue['start_seconds'] < cue['end_seconds'] <= passage['end_seconds']
        ):
            return []
    if encoded[cursor * 2:].decode('utf-16-le').strip():
        return []
    return cues

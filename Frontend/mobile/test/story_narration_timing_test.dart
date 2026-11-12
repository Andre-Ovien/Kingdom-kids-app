import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/stories/domain/story_detail.dart';

const _body = 'Kai 😀 trusts God.';

Map<String, dynamic> _cue(
  String text,
  int startOffset,
  int endOffset,
  num startSeconds,
  num endSeconds,
) => {
  'text': text,
  'start_offset': startOffset,
  'end_offset': endOffset,
  'start_seconds': startSeconds,
  'end_seconds': endSeconds,
};

List<Map<String, dynamic>> _words() => [
  _cue('Kai', 0, 3, 0, 0.24),
  _cue('😀', 4, 6, 0.3, 0.5),
  _cue('trusts', 7, 13, 0.58, 0.95),
  _cue('God.', 14, 18, 1.05, 1.44),
];

Map<String, dynamic> _payload() => {
  'avatar_key': 'dove',
  'voice_key': 'nia',
  'character_name': 'Nia',
  'status': 'unavailable',
  'audio_available': false,
  'duration_seconds': 2,
  'segments': [_cue(_body, 0, _body.length, 0, 2)],
};

void _expectWordsRejected(Object? words) {
  final narration = StoryNarration.fromJson({..._payload(), 'words': words});
  expect(narration.wordsForText(_body), isEmpty);
  expect(narration.segmentsForText(_body).single.text, _body);
}

void main() {
  group('StoryNarration measured word timing', () {
    test('parses backend word cues with UTF16 astral character offsets', () {
      final narration = StoryNarration.fromJson({
        ..._payload(),
        'words': _words(),
      });

      final words = narration.wordsForText(_body);
      expect(words.map((word) => word.text), ['Kai', '😀', 'trusts', 'God.']);
      expect(words[1].startOffset, 4);
      expect(words[1].endOffset, 6);
      expect(words[1].startTime, const Duration(milliseconds: 300));
      expect(words[1].endTime, const Duration(milliseconds: 500));
      expect(words.last.startTime, const Duration(milliseconds: 1050));
      expect(words.last.endTime, const Duration(milliseconds: 1440));
      expect(narration.segmentsForText(_body).single.text, _body);
    });

    test(
      'missing words preserves paragraph cues without inventing word times',
      () {
        final narration = StoryNarration.fromJson(_payload());

        expect(narration.words, isEmpty);
        expect(narration.wordsForText(_body), isEmpty);
        expect(
          narration.segmentsForText(_body).single.endTime,
          const Duration(seconds: 2),
        );
      },
    );

    test('mismatched word text leaves paragraph cues available', () {
      final words = _words();
      words[2]['text'] = 'trusted';
      _expectWordsRejected(words);
    });

    test('UTF16 offset ending inside an astral character is rejected', () {
      final words = _words();
      words[1]['end_offset'] = 5;
      _expectWordsRejected(words);
    });

    test('out of bounds offsets leave paragraph cues available', () {
      final words = _words();
      words.last['end_offset'] = _body.length + 1;
      _expectWordsRejected(words);
    });

    test('overlapping text offsets are rejected even when slices match', () {
      final words = _words();
      words[1] = _cue(_body.substring(2, 6), 2, 6, 0.3, 0.5);
      _expectWordsRejected(words);
    });

    test('word text offsets must stay in story order', () {
      final words = _words();
      final first = words[0];
      words[0] = {...words[1], 'start_seconds': 0, 'end_seconds': 0.2};
      words[1] = {...first, 'start_seconds': 0.3, 'end_seconds': 0.5};
      _expectWordsRejected(words);
    });

    for (final value in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      test('nonfinite word times are rejected: $value', () {
        final words = _words();
        words[1]['end_seconds'] = value;
        _expectWordsRejected(words);
      });
    }

    test(
      'overlapping word times are rejected independently of paragraph cues',
      () {
        final words = _words();
        words[1]['start_seconds'] = 0.2;
        _expectWordsRejected(words);
      },
    );

    test('out of order word times are rejected with valid text order', () {
      final words = _words();
      words[2]['start_seconds'] = 0.1;
      words[2]['end_seconds'] = 0.2;
      _expectWordsRejected(words);
    });

    test('missing word times are not inferred from paragraph timing', () {
      final words = _words();
      words[1].remove('start_seconds');
      _expectWordsRejected(words);
    });
  });
}

import 'package:flutter/widgets.dart';

import '../../../core/config/app_config.dart';

/// Provider-neutral narration information for one story character.
///
/// Provider identifiers intentionally do not belong in this model. The API
/// only exposes the safe metadata the app needs to select device speech or a
/// hosted audio track.
class StoryNarration {
  const StoryNarration({
    required this.avatarKey,
    required this.voiceKey,
    required this.characterName,
    required this.voiceDescription,
    required this.locale,
    required this.speechRate,
    required this.pitch,
    required this.status,
    required this.audioAvailable,
    this.sampleUrl,
    this.audioUrl,
    this.durationSeconds,
    this.segments = const [],
    this.words = const [],
  });

  final String avatarKey;
  final String voiceKey;
  final String characterName;
  final String voiceDescription;
  final String locale;
  final double speechRate;
  final double pitch;
  final String? sampleUrl;
  final String status;
  final bool audioAvailable;
  final String? audioUrl;
  final int? durationSeconds;
  final List<StoryNarrationSegment> segments;
  final List<StoryNarrationSegment> words;

  /// Only measured passages that exactly match this edition of the story may
  /// drive highlighting or seeking. Invalid cues leave ordinary audio playback
  /// available, without pretending to have word timing information.
  List<StoryNarrationSegment> segmentsForText(String text) =>
      _validatedCuesForText(segments, text);

  /// Word highlighting uses only supplied measurements that match the exact
  /// story body. Paragraph timings never stand in for missing word timings.
  List<StoryNarrationSegment> wordsForText(String text) =>
      _validatedCuesForText(words, text);

  static List<StoryNarrationSegment> _validatedCuesForText(
    List<StoryNarrationSegment> cues,
    String text,
  ) {
    var previousOffset = 0;
    var previousTime = Duration.zero;
    for (final segment in cues) {
      if (segment.startOffset < previousOffset ||
          segment.endOffset <= segment.startOffset ||
          segment.endOffset > text.length ||
          segment.startTime < previousTime ||
          segment.endTime <= segment.startTime ||
          text.substring(segment.startOffset, segment.endOffset) !=
              segment.text) {
        return const [];
      }
      previousOffset = segment.endOffset;
      previousTime = segment.endTime;
    }
    return List<StoryNarrationSegment>.unmodifiable(cues);
  }

  factory StoryNarration.fromJson(
    Map<String, dynamic> json, {
    ContentMediaPolicy mediaPolicy = AppConfig.contentMediaPolicy,
  }) {
    final rawStatus = _stringFrom(
      json['status'],
      fallback: 'unavailable',
    ).toLowerCase();
    final status = _supportedNarrationStatuses.contains(rawStatus)
        ? rawStatus
        : 'unavailable';
    final audioUrl = mediaPolicy.sanitize(json['audio_url']);
    return StoryNarration(
      avatarKey: _requiredString(
        json['avatar_key'],
        fieldName: 'narration avatar_key',
      ),
      voiceKey: _requiredString(
        json['voice_key'],
        fieldName: 'narration voice_key',
      ),
      characterName: _requiredString(
        json['character_name'],
        fieldName: 'narration character_name',
      ),
      voiceDescription: _stringFrom(json['voice_description']),
      locale: _stringFrom(json['locale'], fallback: 'en-US'),
      speechRate: _doubleFrom(
        json['speech_rate'],
        fallback: 0.45,
      ).clamp(0.1, 1.0).toDouble(),
      pitch: _doubleFrom(json['pitch'], fallback: 1).clamp(0.5, 2.0).toDouble(),
      sampleUrl: mediaPolicy.sanitize(json['sample_url']),
      status: status,
      audioAvailable:
          status == 'ready' &&
          _boolFrom(json['audio_available']) &&
          audioUrl != null,
      audioUrl: audioUrl,
      durationSeconds: _positiveNullableInt(json['duration_seconds']),
      segments: StoryNarrationSegment.listFromJson(json['segments']),
      words: StoryNarrationSegment.listFromJson(json['words']),
    );
  }
}

/// One recorded passage. Offsets use Dart's UTF-16 string indexing; times are
/// measured from the beginning of the hosted audio file.
class StoryNarrationSegment {
  const StoryNarrationSegment({
    required this.text,
    required this.startOffset,
    required this.endOffset,
    required this.startTime,
    required this.endTime,
  });

  final String text;
  final int startOffset;
  final int endOffset;
  final Duration startTime;
  final Duration endTime;

  static List<StoryNarrationSegment> listFromJson(Object? value) {
    if (value is! List) return const [];
    final segments = <StoryNarrationSegment>[];
    for (final item in value) {
      if (item is! Map) return const [];
      final text = item['text'];
      final startOffset = item['start_offset'];
      final endOffset = item['end_offset'];
      final startSeconds = item['start_seconds'];
      final endSeconds = item['end_seconds'];
      if (text is! String ||
          startOffset is! int ||
          endOffset is! int ||
          startOffset < 0 ||
          endOffset <= startOffset ||
          startSeconds is! num ||
          endSeconds is! num ||
          !startSeconds.isFinite ||
          !endSeconds.isFinite ||
          startSeconds < 0 ||
          endSeconds <= startSeconds) {
        return const [];
      }
      segments.add(
        StoryNarrationSegment(
          text: text,
          startOffset: startOffset,
          endOffset: endOffset,
          startTime: Duration(
            microseconds: (startSeconds * Duration.microsecondsPerSecond)
                .round(),
          ),
          endTime: Duration(
            microseconds: (endSeconds * Duration.microsecondsPerSecond).round(),
          ),
        ),
      );
    }
    return List<StoryNarrationSegment>.unmodifiable(segments);
  }
}

/// A story returned by the catalogue or detail API.
///
/// [description], [imageAsset], [imageAlignment], [rating], and [reviewCount]
/// keep older callers source-compatible. New code uses the exact backend
/// values in [summary], [body], [coverAssetKey], [ratingValue], and [reviews].
class StoryDetail {
  const StoryDetail({
    this.id = '',
    this.slug = '',
    required this.title,
    required this.author,
    required this.category,
    String? summary,
    String? body,
    String? description,
    String? coverAssetKey,
    String? imageAsset,
    this.coverImageUrl,
    this.imageAlignment = Alignment.center,
    this.rating = '',
    this.reviewCount = '',
    double? ratingValue,
    int? reviews,
    this.estimatedReadSeconds = 0,
    this.isFeatured = false,
    this.narrations = const [],
  }) : summary = summary ?? description ?? body ?? '',
       body = body ?? description ?? '',
       coverAssetKey = coverAssetKey ?? imageAsset ?? '',
       imageAsset = imageAsset ?? coverAssetKey ?? '',
       _ratingValue = ratingValue,
       _reviews = reviews;

  final String id;
  final String slug;
  final String title;
  final String author;
  final String category;
  final String summary;
  final String body;
  final String coverAssetKey;
  final String? coverImageUrl;
  final double? _ratingValue;
  final int? _reviews;
  final int estimatedReadSeconds;
  final bool isFeatured;
  final List<StoryNarration> narrations;

  /// Compatibility aliases used by the current hardcoded presentation.
  final String imageAsset;
  final Alignment imageAlignment;
  final String rating;
  final String reviewCount;
  String get description => body.isNotEmpty ? body : summary;
  double get coverFocusX => imageAlignment.x;
  double get coverFocusY => imageAlignment.y;
  double get ratingValue => _ratingValue ?? double.tryParse(rating) ?? 0;
  int get reviews => _reviews ?? _expandCompactCount(reviewCount);

  bool get hasHostedCover => coverImageUrl != null;

  factory StoryDetail.fromJson(
    Map<String, dynamic> json, {
    ContentMediaPolicy mediaPolicy = AppConfig.contentMediaPolicy,
  }) {
    final slug = _requiredString(json['slug'], fieldName: 'slug');
    final title = _requiredString(json['title'], fieldName: 'title');
    final rawCoverAssetKey = _stringFrom(
      json['cover_asset_key'] ?? json['image_asset'],
    );
    final coverImageUrl = mediaPolicy.sanitize(
      json['cover_image_url'] ?? json['image_url'],
    );
    final usesLegacyBundledCover =
        coverImageUrl == null && _legacyCoverKeys.containsKey(rawCoverAssetKey);
    final ratingValue = _doubleFrom(json['rating']).clamp(0.0, 5.0).toDouble();
    final reviews = _intFrom(json['review_count']).clamp(0, 0x7fffffff).toInt();
    final coverFocusX = usesLegacyBundledCover
        ? 0.0
        : _doubleFrom(json['cover_focus_x']).clamp(-1.0, 1.0).toDouble();
    final coverFocusY = usesLegacyBundledCover
        ? 0.0
        : _doubleFrom(json['cover_focus_y']).clamp(-1.0, 1.0).toDouble();
    final rawNarrations = json['narrations'];
    final narrations = <StoryNarration>[];
    if (rawNarrations is List) {
      for (final narration in rawNarrations) {
        final payload = _mapFrom(narration);
        if (payload.isEmpty) {
          throw const FormatException('Story narrations must be objects.');
        }
        narrations.add(
          StoryNarration.fromJson(payload, mediaPolicy: mediaPolicy),
        );
      }
    } else if (rawNarrations != null) {
      throw const FormatException('Story narrations must be a list.');
    }

    return StoryDetail(
      id: _stringFrom(json['id']),
      slug: slug,
      title: title,
      author: _stringFrom(json['author'], fallback: 'Kingdom Kids'),
      category: _stringFrom(json['category']),
      summary: _stringFrom(json['summary']),
      // Passage offsets refer to the exact API body, including whitespace.
      body: json['body']?.toString() ?? '',
      coverAssetKey: _normalizeCoverAssetKey(rawCoverAssetKey),
      coverImageUrl: coverImageUrl,
      imageAlignment: Alignment(coverFocusX, coverFocusY),
      rating: _displayRating(ratingValue),
      reviewCount: _compactCount(reviews),
      ratingValue: ratingValue,
      reviews: reviews,
      estimatedReadSeconds: _intFrom(
        json['estimated_read_seconds'] ?? json['read_seconds'],
      ).clamp(0, 0x7fffffff).toInt(),
      isFeatured: _boolFrom(json['is_featured'] ?? json['featured']),
      narrations: List<StoryNarration>.unmodifiable(narrations),
    );
  }

  static const fallback = StoryDetail(
    slug: 'david-and-goliath',
    title: 'David & Goliath',
    author: 'Kingdom Kids',
    category: 'Bible story',
    imageAsset: 'assets/images/stories/david-and-goliath-v2.webp',
    estimatedReadSeconds: 120,
    isFeatured: true,
    summary:
        'David was a young shepherd who trusted God with his whole heart. '
        'When the giant Goliath frightened the army, David remembered how God '
        'had helped him protect his sheep before.\n\n'
        'With a sling, five smooth stones, and brave faith, David stepped '
        'forward. This story reminds kids that courage grows when we remember '
        'God is with us.\n\n'
        'David did not need heavy armor to do what was right. Children can '
        'learn that a faithful heart, a listening spirit, and trust in God are '
        'stronger than fear.\n\n'
        'When the battle was over, everyone saw that the victory belonged to '
        'God. David\'s story helps kids remember that small hands can do brave '
        'things with God\'s help.',
  );

  static const unavailable = StoryDetail(
    title: 'Story unavailable',
    author: 'Kingdom Kids',
    category: '',
    summary: 'Choose another story from the library and try again.',
  );
}

Map<String, dynamic> _mapFrom(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map(
      (key, nestedValue) => MapEntry(key.toString(), nestedValue),
    );
  }
  return const {};
}

String _stringFrom(Object? value, {String fallback = ''}) {
  final result = value?.toString().trim();
  return result == null || result.isEmpty ? fallback : result;
}

String? _nullableString(Object? value) {
  final result = value?.toString().trim();
  return result == null || result.isEmpty ? null : result;
}

String _requiredString(Object? value, {required String fieldName}) {
  final result = _nullableString(value);
  if (result == null) {
    throw FormatException('Story $fieldName is required.');
  }
  return result;
}

double _doubleFrom(Object? value, {double fallback = 0}) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}

int _intFrom(Object? value, {int fallback = 0}) {
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

int? _positiveNullableInt(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is num) {
    final result = value.toInt();
    return result > 0 ? result : null;
  }
  final result = int.tryParse(value.toString());
  return result != null && result > 0 ? result : null;
}

bool _boolFrom(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  return value?.toString().toLowerCase() == 'true';
}

String _displayRating(double value) {
  return value.toStringAsFixed(1);
}

String _compactCount(int value) {
  if (value >= 1000000) {
    final millions = value / 1000000;
    return '${_trimTrailingZero(millions)}m';
  }
  if (value >= 1000) {
    final thousands = value / 1000;
    return '${_trimTrailingZero(thousands)}k';
  }
  return value.toString();
}

String _trimTrailingZero(double value) {
  final fixed = value.toStringAsFixed(1);
  return fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed;
}

int _expandCompactCount(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.endsWith('m')) {
    final millions = double.tryParse(
      normalized.substring(0, normalized.length - 1),
    );
    return ((millions ?? 0) * 1000000).round();
  }
  if (normalized.endsWith('k')) {
    final thousands = double.tryParse(
      normalized.substring(0, normalized.length - 1),
    );
    return ((thousands ?? 0) * 1000).round();
  }
  return int.tryParse(normalized) ?? 0;
}

String _normalizeCoverAssetKey(String value) {
  return _legacyCoverKeys[value] ?? value;
}

const _legacyCoverKeys = <String, String>{
  'assets/images/david_and_goliath.png':
      'assets/images/stories/david-and-goliath-v2.webp',
  'assets/images/jonah.jpg':
      'assets/images/stories/jonah-and-the-big-fish-v2.webp',
  'assets/images/crossing_red_sea.webp':
      'assets/images/stories/crossing-the-red-sea-v2.webp',
  'assets/images/noahs_ark.png':
      'assets/images/stories/noah-builds-the-ark-v2.webp',
  'assets/images/creation_week.jpg':
      'assets/images/stories/creation-week-v2.webp',
  'assets/images/daniel.jpeg':
      'assets/images/stories/daniel-in-the-lions-den-v2.webp',
  'assets/images/moses2.jpeg':
      'assets/images/stories/moses-follows-god-v2.webp',
  'assets/images/esther.jpeg': 'assets/images/stories/esther-speaks-up-v2.webp',
};

const _supportedNarrationStatuses = <String>{
  'device_tts',
  'processing',
  'ready',
  'unavailable',
};

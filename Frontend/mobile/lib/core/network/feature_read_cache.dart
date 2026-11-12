import 'dart:async';

/// A bounded, memory-only cache for validated feature reads. Authentication,
/// billing status and mutations never enter this cache.
class FeatureReadCache {
  FeatureReadCache({this.maxEntries = 48, DateTime Function()? now})
    : assert(maxEntries > 0),
      _now = now ?? DateTime.now;

  final int maxEntries;
  final DateTime Function() _now;
  final _entries = <Object, _ReadEntry>{};
  final _pending = <Object, Future<Object?>>{};
  int _generation = 0;
  int _mediaGeneration = 0;
  int get generation => _generation;
  int get mediaGeneration => _mediaGeneration;

  void invalidate({bool includeMedia = true}) {
    _generation++;
    if (includeMedia) _mediaGeneration++;
    if (includeMedia) {
      _entries.clear();
    } else {
      _entries.removeWhere((_, entry) => !entry.progressIndependent);
    }
    _pending.clear();
  }

  Future<T> read<T>(
    Object key,
    Future<T> Function() load, {
    Duration maxAge = const Duration(minutes: 1),
    DateTime? Function(T value)? expiresAt,
    bool progressIndependent = false,
  }) async {
    final cached = _entries.remove(key);
    if (cached != null && _now().isBefore(cached.expiresAt)) {
      _entries[key] = cached;
      return cached.value as T;
    }
    final pending = _pending[key];
    if (pending != null) return await pending as T;
    final generation = _generation;
    final mediaGeneration = _mediaGeneration;
    Future<T> loadAndStore() async {
      final value = await load();
      var expiry = _now().add(maxAge);
      final mediaExpiry = expiresAt?.call(value);
      if (mediaExpiry != null && mediaExpiry.isBefore(expiry)) {
        expiry = mediaExpiry;
      }
      if ((generation == _generation ||
              (progressIndependent && mediaGeneration == _mediaGeneration)) &&
          _now().isBefore(expiry)) {
        _entries[key] = _ReadEntry(value, expiry, progressIndependent);
        while (_entries.length > maxEntries) {
          _entries.remove(_entries.keys.first);
        }
      }
      return value;
    }

    final request = loadAndStore();
    if (_pending.length < maxEntries) _pending[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_pending[key], request)) _pending.remove(key);
    }
  }
}

class _ReadEntry {
  const _ReadEntry(this.value, this.expiresAt, this.progressIndependent);
  final Object? value;
  final DateTime expiresAt;
  final bool progressIndependent;
}

final featureReadCache = FeatureReadCache();

/// Metadata containing a signed URL can only be reused before that URL expires.
/// Unknown query credentials are conservatively treated as non-cacheable.
DateTime? featureMediaExpiry(Iterable<String?> sources) {
  DateTime? earliest;
  for (final source in sources) {
    if (source == null) continue;
    final uri = Uri.tryParse(source);
    if (uri == null || !uri.hasQuery) continue;
    final seconds = int.tryParse(
      uri.queryParameters['expires_at'] ?? uri.queryParameters['Expires'] ?? '',
    );
    final expiry = seconds == null || seconds < 0 || seconds > 8640000000000
        ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
        : DateTime.fromMillisecondsSinceEpoch(
            seconds * 1000,
            isUtc: true,
          ).subtract(const Duration(seconds: 10));
    if (earliest == null || expiry.isBefore(earliest)) earliest = expiry;
  }
  return earliest;
}

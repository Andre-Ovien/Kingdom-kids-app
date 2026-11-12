import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';

/// The validated, bounded result of one child-facing media download.
class FetchedContentMedia {
  const FetchedContentMedia({
    required this.bytes,
    required this.finalUri,
    this.contentType,
  });

  final Uint8List bytes;
  final Uri finalUri;
  final String? contentType;
}

abstract interface class ContentMediaFetcher {
  Future<FetchedContentMedia> fetch(Object? source);
}

/// Downloads trusted media without allowing the HTTP client to follow an
/// unvalidated redirect.
///
/// Every requested hop is passed through [ContentMediaPolicy], redirect loops
/// and long chains fail closed, and the response stream is cancelled as soon
/// as it exceeds [maxBytes]. No consumer receives a remote URL to load again.
final class HttpContentMediaFetcher implements ContentMediaFetcher {
  HttpContentMediaFetcher({
    required this.policy,
    http.Client? client,
    this.maxRedirects = 3,
    this.maxBytes = 8 * 1024 * 1024,
    this.requestTimeout = const Duration(seconds: 15),
  }) : assert(maxRedirects >= 0),
       assert(maxBytes > 0),
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final ContentMediaPolicy policy;
  final int maxRedirects;
  final int maxBytes;
  final Duration requestTimeout;
  final http.Client _client;
  final bool _ownsClient;
  bool _closed = false;

  @override
  Future<FetchedContentMedia> fetch(Object? source) async {
    if (_closed) {
      throw const ContentMediaFetchException('fetcher_closed');
    }

    var currentUri = _validatedUri(source, code: 'untrusted_media_uri');
    final visited = <String>{currentUri.toString()};
    var redirectsFollowed = 0;

    while (true) {
      final request = http.Request('GET', currentUri)
        ..followRedirects = false
        ..maxRedirects = 0;

      late final http.StreamedResponse response;
      try {
        response = await _client.send(request).timeout(requestTimeout);
      } on TimeoutException {
        throw const ContentMediaFetchException('request_timeout');
      } on http.ClientException {
        throw const ContentMediaFetchException('network_error');
      }

      final responseUri = _validatedUri(
        response.request?.url ?? currentUri,
        code: 'untrusted_final_uri',
      );
      if (responseUri != currentUri) {
        await _cancel(response.stream);
        throw const ContentMediaFetchException('unexpected_final_uri');
      }

      if (_isRedirect(response.statusCode)) {
        await _cancel(response.stream);
        final location = response.headers['location']?.trim();
        if (location == null || location.isEmpty) {
          throw const ContentMediaFetchException('redirect_missing_location');
        }
        if (redirectsFollowed >= maxRedirects) {
          throw const ContentMediaFetchException('too_many_redirects');
        }

        late final Uri resolved;
        try {
          resolved = currentUri.resolve(location);
        } on FormatException {
          throw const ContentMediaFetchException('invalid_redirect');
        }
        final nextUri = _validatedUri(resolved, code: 'untrusted_redirect');
        if (!visited.add(nextUri.toString())) {
          throw const ContentMediaFetchException('redirect_loop');
        }
        redirectsFollowed += 1;
        currentUri = nextUri;
        continue;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await _cancel(response.stream);
        throw const ContentMediaFetchException('unexpected_status');
      }

      final declaredLength = int.tryParse(
        response.headers['content-length'] ?? '',
      );
      if (declaredLength != null && declaredLength > maxBytes) {
        await _cancel(response.stream);
        throw const ContentMediaFetchException('media_too_large');
      }

      final bytes = await _readBounded(response.stream);
      return FetchedContentMedia(
        bytes: bytes,
        finalUri: responseUri,
        contentType: _contentType(response.headers['content-type']),
      );
    }
  }

  Uri _validatedUri(Object? value, {required String code}) {
    final sanitized = policy.sanitize(value);
    if (sanitized == null) {
      throw ContentMediaFetchException(code);
    }
    final uri = Uri.tryParse(sanitized);
    if (uri == null) {
      throw ContentMediaFetchException(code);
    }
    return uri;
  }

  Future<Uint8List> _readBounded(Stream<List<int>> stream) {
    final result = Completer<Uint8List>();
    final bytes = BytesBuilder(copy: false);
    StreamSubscription<List<int>>? subscription;
    late final Timer timeout;
    var completed = false;

    void fail(ContentMediaFetchException error) {
      if (completed) return;
      completed = true;
      unawaited(subscription?.cancel());
      result.completeError(error);
    }

    timeout = Timer(
      requestTimeout,
      () => fail(const ContentMediaFetchException('request_timeout')),
    );
    subscription = stream.listen(
      (chunk) {
        if (completed) return;
        if (bytes.length + chunk.length > maxBytes) {
          fail(const ContentMediaFetchException('media_too_large'));
          return;
        }
        bytes.add(chunk);
      },
      onError: (Object _) {
        fail(const ContentMediaFetchException('network_error'));
      },
      onDone: () {
        if (completed) return;
        completed = true;
        result.complete(bytes.takeBytes());
      },
      cancelOnError: true,
    );
    if (completed) unawaited(subscription.cancel());

    return result.future.whenComplete(timeout.cancel);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
  }
}

/// Shares validated cover downloads and bounds their retained encoded bytes.
/// Non-image responses and failures are never retained.
final class CachedContentMediaFetcher implements ContentMediaFetcher {
  CachedContentMediaFetcher({
    required this.fetcher,
    required this.policy,
    this.maxBytes = 16 * 1024 * 1024,
    this.maxEntries = 32,
    this.maxAge = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : assert(maxBytes > 0),
       assert(maxEntries > 0),
       _now = now ?? DateTime.now;

  final ContentMediaFetcher fetcher;
  final ContentMediaPolicy policy;
  final int maxBytes;
  final int maxEntries;
  final Duration maxAge;
  final DateTime Function() _now;
  final _entries = <String, _CachedMedia>{};
  final _pending = <String, Future<FetchedContentMedia>>{};
  int _retainedBytes = 0;

  @override
  Future<FetchedContentMedia> fetch(Object? source) {
    final key = policy.sanitize(source);
    if (key == null) {
      return Future.error(
        const ContentMediaFetchException('untrusted_media_uri'),
      );
    }
    final cached = _entries.remove(key);
    if (cached != null) {
      _retainedBytes -= cached.media.bytes.length;
      if (_now().difference(cached.savedAt) < maxAge) {
        _entries[key] = cached;
        _retainedBytes += cached.media.bytes.length;
        return Future.value(cached.media);
      }
    }
    final pending = _pending[key];
    if (pending != null) return pending;

    Future<FetchedContentMedia> loadAndStore() async {
      try {
        final media = await Future<FetchedContentMedia>.sync(
          () => fetcher.fetch(key),
        );
        if (media.contentType?.startsWith('image/') == true &&
            media.bytes.length <= maxBytes) {
          _entries[key] = _CachedMedia(media, _now());
          _retainedBytes += media.bytes.length;
          while (_retainedBytes > maxBytes || _entries.length > maxEntries) {
            _retainedBytes -= _entries
                .remove(_entries.keys.first)!
                .media
                .bytes
                .length;
          }
        }
        return media;
      } finally {
        _pending.remove(key);
      }
    }

    final request = loadAndStore();
    _pending[key] = request;
    return request;
  }
}

final class _CachedMedia {
  const _CachedMedia(this.media, this.savedAt);
  final FetchedContentMedia media;
  final DateTime savedAt;
}

final ContentMediaFetcher defaultContentMediaFetcher =
    CachedContentMediaFetcher(
      policy: AppConfig.contentMediaPolicy,
      fetcher: HttpContentMediaFetcher(policy: AppConfig.contentMediaPolicy),
    );

class ContentMediaFetchException implements Exception {
  const ContentMediaFetchException(this.code);

  final String code;

  @override
  String toString() => 'ContentMediaFetchException: $code';
}

bool _isRedirect(int statusCode) {
  return statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;
}

String? _contentType(String? raw) {
  final value = raw?.split(';').first.trim().toLowerCase();
  return value == null || value.isEmpty ? null : value;
}

Future<void> _cancel(Stream<List<int>> stream) async {
  final subscription = stream.listen((_) {}, onError: (_) {});
  await subscription.cancel();
}

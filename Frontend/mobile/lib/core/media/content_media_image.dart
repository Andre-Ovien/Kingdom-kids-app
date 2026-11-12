import 'dart:async';

import 'package:flutter/widgets.dart';

import '../config/app_config.dart';
import '../network/feature_read_cache.dart';
import 'content_media_fetcher.dart';

/// Renders remote image bytes only after the shared media fetch path has
/// validated every redirect and bounded the response size.
class ContentMediaImage extends StatefulWidget {
  const ContentMediaImage({
    required this.source,
    required this.mediaPolicy,
    required this.fit,
    required this.alignment,
    required this.loadingBuilder,
    required this.errorBuilder,
    this.mediaFetcher,
    this.sourceRefresher,
    this.initialMedia,
    this.mediaScope,
    super.key,
  });

  final Object? source;
  final ContentMediaPolicy mediaPolicy;
  final ContentMediaFetcher? mediaFetcher;

  /// Supply only a fresh [CachedContentMediaFetcher.peekScoped] result for
  /// this exact source and the same prevalidated [mediaScope].
  final FetchedContentMedia? initialMedia;
  final Object? mediaScope;

  /// Re-fetches authorized metadata for this exact story/game, never an
  /// arbitrary media endpoint. Called at most once for an expired/denied link.
  final Future<Object?> Function()? sourceRefresher;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final WidgetBuilder loadingBuilder;
  final WidgetBuilder errorBuilder;

  @override
  State<ContentMediaImage> createState() => _ContentMediaImageState();
}

class _ContentMediaImageState extends State<ContentMediaImage> {
  Future<FetchedContentMedia>? _media;
  HttpContentMediaFetcher? _ownedFetcher;
  int _generation = 0;
  FetchedContentMedia? _retainedMedia;
  String? _configuredSource;
  Object? _configuredScope;
  ContentMediaPolicy? _configuredPolicy;
  int _retainedMediaGeneration = -1;
  bool _failed = false;
  Timer? _retainedExpiryTimer;

  @override
  void initState() {
    super.initState();
    _configureFetch();
  }

  @override
  void didUpdateWidget(ContentMediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source?.toString() != widget.source?.toString() ||
        !_samePolicy(oldWidget.mediaPolicy, widget.mediaPolicy) ||
        !identical(oldWidget.mediaFetcher, widget.mediaFetcher) ||
        !identical(oldWidget.sourceRefresher, widget.sourceRefresher) ||
        !identical(oldWidget.initialMedia, widget.initialMedia) ||
        oldWidget.mediaScope != widget.mediaScope ||
        _retainedMediaGeneration != featureReadCache.mediaGeneration) {
      _configureFetch();
    }
  }

  void _configureFetch() {
    final generation = ++_generation;
    _ownedFetcher?.close();
    _ownedFetcher = null;

    final sanitized = widget.mediaPolicy.sanitize(widget.source);
    final sameScope =
        sanitized != null &&
        _configuredScope == widget.mediaScope &&
        _configuredPolicy != null &&
        _samePolicy(_configuredPolicy!, widget.mediaPolicy) &&
        _retainedMediaGeneration == featureReadCache.mediaGeneration;
    final sameIdentity =
        sameScope &&
        (sanitized == _configuredSource ||
            (widget.mediaScope != null &&
                _sameImmutablePrivateImage(
                  _retainedMedia?.sourceUri,
                  Uri.tryParse(sanitized),
                )));
    if (!sameIdentity) _failed = false;
    final previous = sameIdentity
        ? _usableMedia(
            _retainedMedia,
            source: _retainedMedia?.sourceUri?.toString(),
          )
        : null;
    _retainedMedia = _failed
        ? null
        : _usableMedia(widget.initialMedia) ?? previous;
    _configuredSource = sanitized;
    _configuredScope = widget.mediaScope;
    _configuredPolicy = widget.mediaPolicy;
    _retainedMediaGeneration = featureReadCache.mediaGeneration;
    _armRetainedExpiry();
    if (sanitized == null) {
      _media = null;
      _retainedMedia = null;
      return;
    }

    final ContentMediaFetcher fetcher;
    if (widget.mediaFetcher != null) {
      fetcher = widget.mediaFetcher!;
    } else if (_samePolicy(widget.mediaPolicy, AppConfig.contentMediaPolicy)) {
      fetcher = defaultContentMediaFetcher;
    } else {
      final owned = HttpContentMediaFetcher(policy: widget.mediaPolicy);
      _ownedFetcher = owned;
      fetcher = owned;
    }
    _media = _fetchWithRefresh(
      fetcher,
      sanitized,
      widget.sourceRefresher,
      generation,
    );
  }

  FetchedContentMedia? _usableMedia(
    FetchedContentMedia? media, {
    String? source,
  }) {
    if (media == null || widget.mediaPolicy.sanitize(media.finalUri) == null) {
      return null;
    }
    final trusted = widget.mediaPolicy.sanitize(source ?? widget.source);
    if (trusted == null || media.sourceUri != Uri.parse(trusted)) return null;
    if (Uri.parse(trusted).hasQuery ||
        media.finalUri.hasQuery ||
        media.cacheScope != null) {
      if (widget.mediaScope == null ||
          media.cacheScope != widget.mediaScope ||
          media.cacheGeneration != featureReadCache.mediaGeneration) {
        return null;
      }
    }
    final expiry = featureMediaExpiry([trusted, media.finalUri.toString()]);
    if (expiry != null && !DateTime.now().isBefore(expiry)) return null;
    return media;
  }

  void _armRetainedExpiry() {
    _retainedExpiryTimer?.cancel();
    final retained = _retainedMedia;
    if (retained == null) return;
    final expiry = featureMediaExpiry([
      retained.sourceUri?.toString(),
      retained.finalUri.toString(),
    ]);
    if (expiry == null) return;
    final delay = expiry.difference(DateTime.now());
    if (delay <= Duration.zero) return;
    _retainedExpiryTimer = Timer(delay, () {
      if (mounted && identical(retained, _retainedMedia)) {
        setState(() => _retainedMedia = null);
      }
    });
  }

  Future<FetchedContentMedia> _fetchWithRefresh(
    ContentMediaFetcher fetcher,
    String source,
    Future<Object?> Function()? refresh,
    int generation,
  ) async {
    final expiry = _cloudinaryExpiry(source);
    Future<FetchedContentMedia> refreshed() async {
      final replacement = widget.mediaPolicy.sanitize(await refresh!());
      if (!mounted || generation != _generation) {
        throw const ContentMediaFetchException('media_request_stale');
      }
      if (replacement == null || replacement == source) {
        throw const ContentMediaFetchException('media_refresh_failed');
      }
      return fetcher.fetch(replacement);
    }

    if (refresh != null &&
        expiry != null &&
        !expiry.isAfter(DateTime.now().add(const Duration(seconds: 10)))) {
      return refreshed();
    }
    try {
      return await fetcher.fetch(source);
    } on ContentMediaFetchException catch (error) {
      if (refresh == null ||
          expiry == null ||
          error.code != 'unexpected_status') {
        rethrow;
      }
      return refreshed();
    }
  }

  @override
  void dispose() {
    _generation++;
    _retainedExpiryTimer?.cancel();
    _ownedFetcher?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = _media;
    if (media == null) {
      return widget.errorBuilder(context);
    }

    return FutureBuilder<FetchedContentMedia>(
      key: ValueKey(_generation),
      future: media,
      initialData: _retainedMedia,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          _retainedMedia = null;
          _failed = true;
          return widget.errorBuilder(context);
        }
        final fetched = snapshot.data;
        if (fetched == null) {
          return widget.loadingBuilder(context);
        }
        if (snapshot.connectionState != ConnectionState.done &&
            (_retainedMedia == null ||
                _usableMedia(fetched, source: fetched.sourceUri?.toString()) ==
                    null)) {
          return widget.loadingBuilder(context);
        }
        if (snapshot.connectionState == ConnectionState.done) {
          _retainedExpiryTimer?.cancel();
          _retainedMedia = fetched;
          _retainedMediaGeneration = featureReadCache.mediaGeneration;
          _failed = false;
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            // Small cards need small decodes; one dimension preserves the
            // source aspect ratio, and buckets keep image-cache keys stable.
            return Image.memory(
              fetched.bytes,
              cacheWidth: contentImageDecodeWidth(context, constraints),
              fit: widget.fit,
              alignment: widget.alignment,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => widget.errorBuilder(context),
            );
          },
        );
      },
    );
  }
}

/// Only the content-addressed assets emitted by our authenticated metadata API
/// may keep existing pixels while a newly signed URL downloads. The old bytes
/// keep their original source/expiry; they never become a hit for the new URL.
bool _sameImmutablePrivateImage(Uri? oldSource, Uri? newSource) {
  if (oldSource == null ||
      newSource == null ||
      oldSource.scheme != 'https' ||
      newSource.scheme != 'https' ||
      oldSource.host != 'api.cloudinary.com' ||
      oldSource.host != newSource.host ||
      oldSource.port != newSource.port ||
      oldSource.path != newSource.path ||
      !oldSource.path.endsWith('/image/download')) {
    return false;
  }
  final oldQuery = oldSource.queryParametersAll;
  final newQuery = newSource.queryParametersAll;
  if (oldQuery.values.any((values) => values.length != 1) ||
      newQuery.values.any((values) => values.length != 1)) {
    return false;
  }
  final id = oldSource.queryParameters['public_id'] ?? '';
  if (!RegExp(r'^kingdom-kids/media-v1/sha256-[a-f0-9]{64}$').hasMatch(id) ||
      newSource.queryParameters['public_id'] != id ||
      oldSource.queryParameters['type'] != 'authenticated' ||
      newSource.queryParameters['type'] != 'authenticated' ||
      (oldSource.queryParameters['signature'] ?? '').isEmpty ||
      (newSource.queryParameters['signature'] ?? '').isEmpty) {
    return false;
  }
  const renewed = {'signature', 'expires_at', 'timestamp'};
  final stableOld = Map.of(oldQuery)
    ..removeWhere((key, _) => renewed.contains(key));
  final stableNew = Map.of(newQuery)
    ..removeWhere((key, _) => renewed.contains(key));
  if (stableOld.length != stableNew.length ||
      stableOld.entries.any(
        (entry) => stableNew[entry.key]?.single != entry.value.single,
      )) {
    return false;
  }
  final expiry = featureMediaExpiry([newSource.toString()]);
  return expiry != null && DateTime.now().isBefore(expiry);
}

DateTime? _cloudinaryExpiry(String source) {
  final uri = Uri.tryParse(source);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'api.cloudinary.com' ||
      !uri.path.endsWith('/image/download') ||
      uri.queryParameters['type'] != 'authenticated' ||
      (uri.queryParameters['signature'] ?? '').isEmpty) {
    return null;
  }
  final seconds = int.tryParse(uri.queryParameters['expires_at'] ?? '');
  if (seconds == null || seconds < 0 || seconds > 8640000000000) return null;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

bool canRefreshPrivateImageSource(Object? source) =>
    source is String && _cloudinaryExpiry(source) != null;

int? contentImageDecodeWidth(BuildContext context, BoxConstraints constraints) {
  final pixelWidth =
      constraints.maxWidth * (MediaQuery.maybeDevicePixelRatioOf(context) ?? 1);
  return pixelWidth.isFinite && pixelWidth > 0
      ? ((pixelWidth / 64).ceil() * 64).clamp(64, 2048)
      : null;
}

bool _samePolicy(ContentMediaPolicy left, ContentMediaPolicy right) {
  return left.apiBaseUrl == right.apiBaseUrl &&
      left.configuredHosts == right.configuredHosts &&
      left.requireHttps == right.requireHttps;
}

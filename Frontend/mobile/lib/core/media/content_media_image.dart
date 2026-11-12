import 'package:flutter/widgets.dart';

import '../config/app_config.dart';
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
    super.key,
  });

  final Object? source;
  final ContentMediaPolicy mediaPolicy;
  final ContentMediaFetcher? mediaFetcher;

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
        !identical(oldWidget.sourceRefresher, widget.sourceRefresher)) {
      _configureFetch();
    }
  }

  void _configureFetch() {
    final generation = ++_generation;
    _ownedFetcher?.close();
    _ownedFetcher = null;

    final sanitized = widget.mediaPolicy.sanitize(widget.source);
    if (sanitized == null) {
      _media = null;
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
      future: media,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return widget.errorBuilder(context);
        }
        final fetched = snapshot.data;
        if (fetched == null) {
          return widget.loadingBuilder(context);
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

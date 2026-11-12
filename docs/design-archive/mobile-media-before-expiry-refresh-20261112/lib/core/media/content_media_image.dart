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
    super.key,
  });

  final Object? source;
  final ContentMediaPolicy mediaPolicy;
  final ContentMediaFetcher? mediaFetcher;
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
        !identical(oldWidget.mediaFetcher, widget.mediaFetcher)) {
      _configureFetch();
    }
  }

  void _configureFetch() {
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
    _media = fetcher.fetch(sanitized);
  }

  @override
  void dispose() {
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

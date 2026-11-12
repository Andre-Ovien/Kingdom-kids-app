import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/config/app_config.dart';
import 'package:mobile/core/media/content_media_fetcher.dart';
import 'package:mobile/core/media/content_media_image.dart';
import 'package:mobile/core/network/feature_read_cache.dart';

const _policy = ContentMediaPolicy(
  apiBaseUrl: 'https://api.test/api',
  configuredHosts: 'cdn.test',
);
const _source =
    'https://cdn.test/cover.png?signature=private&expires_at=9999999999';
const _scope = ('backend', 'parent', 'child', 'lion', 1);

void main() {
  setUp(featureReadCache.invalidate);
  tearDown(featureReadCache.invalidate);

  testWidgets(
    'validated private bytes paint on the first frame while fresh scope check waits',
    (tester) async {
      final initial = await _seed();
      await tester.pumpWidget(_app(_ReadyFetcher(initial), initial: initial));
      await tester.runAsync(
        () => precacheImage(
          tester.widget<Image>(find.byType(Image)).image,
          tester.element(find.byType(Image)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
      final pending = _PendingFetcher();
      await tester.pumpWidget(_app(pending, initial: initial));
      expect(find.byType(Image), findsOneWidget);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      expect(find.text('loading'), findsNothing);
      pending.response.complete(initial);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same-scope refresh keeps pixels pending and clears them on failure',
    (tester) async {
      final initial = await _seed();
      final first = _PendingFetcher(), second = _PendingFetcher();
      await tester.pumpWidget(_app(first, initial: initial));
      await tester.pumpWidget(_app(second, initial: initial));
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('loading'), findsNothing);
      second.response.completeError(
        const ContentMediaFetchException('network_error'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.text('error'), findsOneWidget);
      first.response.complete(initial);
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a changed source or scope never inherits private pixels from the prior future',
    (tester) async {
      final initial = await _seed();
      final first = _PendingFetcher(),
          second = _PendingFetcher(),
          third = _PendingFetcher();
      await tester.pumpWidget(_app(first, initial: initial));
      expect(find.byType(Image), findsOneWidget);
      await tester.pumpWidget(
        _app(
          second,
          initial: initial,
          scope: ('backend', 'other-parent', 'child', 'lion', 1),
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.text('loading'), findsOneWidget);
      await tester.pumpWidget(
        _app(third, initial: initial, source: '$_source&issued=2'),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.text('loading'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      first.response.complete(initial);
      second.response.complete(initial);
      third.response.complete(initial);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('held initial bytes from a prior media generation do not paint', (
    tester,
  ) async {
    final initial = await _seed();
    featureReadCache.invalidate();
    final pending = _PendingFetcher();
    await tester.pumpWidget(_app(pending, initial: initial));
    expect(find.byType(Image), findsNothing);
    expect(find.text('loading'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.response.complete(initial);
    await tester.pumpAndSettle();
  });
}

Widget _app(
  ContentMediaFetcher fetcher, {
  required FetchedContentMedia initial,
  String source = _source,
  Object? scope = _scope,
}) => MaterialApp(
  home: Center(
    child: SizedBox(
      width: 80,
      height: 80,
      child: ContentMediaImage(
        key: const Key('private-cover'),
        source: source,
        mediaPolicy: _policy,
        mediaFetcher: fetcher,
        initialMedia: initial,
        mediaScope: scope,
        fit: BoxFit.cover,
        alignment: Alignment.center,
        loadingBuilder: (_) => const Text('loading'),
        errorBuilder: (_) => const Text('error'),
      ),
    ),
  ),
);

Future<FetchedContentMedia> _seed() async {
  final cache = CachedContentMediaFetcher(
    policy: _policy,
    fetcher: _ImageFetcher(),
  );
  await cache.fetchScoped(_source, scope: _scope);
  return cache.peekScoped(_source, scope: _scope)!;
}

class _ImageFetcher implements ContentMediaFetcher {
  @override
  Future<FetchedContentMedia> fetch(
    Object? source,
  ) async => FetchedContentMedia(
    bytes: base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    ),
    finalUri: Uri.parse(source.toString()),
    contentType: 'image/png',
  );
}

class _PendingFetcher implements ContentMediaFetcher {
  final response = Completer<FetchedContentMedia>();
  @override
  Future<FetchedContentMedia> fetch(Object? source) => response.future;
}

class _ReadyFetcher implements ContentMediaFetcher {
  _ReadyFetcher(this.media);
  final FetchedContentMedia media;
  @override
  Future<FetchedContentMedia> fetch(Object? source) async => media;
}

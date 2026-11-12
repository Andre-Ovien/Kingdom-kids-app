import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mobile/core/config/app_config.dart';
import 'package:mobile/core/media/content_media_fetcher.dart';
import 'package:mobile/features/games/domain/mini_game.dart';
import 'package:mobile/features/games/presentation/game_cover_image.dart';
import 'package:mobile/features/stories/data/story_voice_sample_service.dart';
import 'package:mobile/features/stories/domain/story_detail.dart';
import 'package:mobile/features/stories/presentation/story_cover_image.dart';

void main() {
  const mediaPolicy = ContentMediaPolicy(
    apiBaseUrl: 'https://api.test/api',
    configuredHosts: 'cdn.test',
  );

  testWidgets('story cover loader falls back to bundled art for unsafe URL', (
    tester,
  ) async {
    const asset = 'assets/images/stories/david-and-goliath-v2.webp';
    const story = StoryDetail(
      slug: 'david-and-goliath',
      title: 'David & Goliath',
      author: 'Kingdom Kids',
      category: 'Courage',
      imageAsset: asset,
      coverImageUrl: 'https://tracking.example/david.webp',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: StoryCoverImage(story: story, mediaPolicy: mediaPolicy),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(_sourceProvider(image.image), isA<AssetImage>());
    expect((_sourceProvider(image.image) as AssetImage).assetName, asset);
    expect(tester.takeException(), isNull);
  });

  testWidgets('game cover loader falls back to bundled art for unsafe URL', (
    tester,
  ) async {
    const asset = 'assets/images/stories/esther-speaks-up-v2.webp';
    const game = MiniGame(
      id: 'esther-quiz',
      slug: 'esther-quiz',
      title: 'Esther Brave Quiz',
      type: MiniGameType.quiz,
      difficulty: 'Easy',
      duration: '3 min',
      imageAsset: asset,
      coverAssetKey: asset,
      coverImageUrl: 'http://cdn.test/esther.webp',
      description: 'Choose courage.',
      rewardStars: 3,
      totalLevels: 1,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: GameCoverImage(game: game, mediaPolicy: mediaPolicy),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(_sourceProvider(image.image), isA<AssetImage>());
    expect((_sourceProvider(image.image) as AssetImage).assetName, asset);
    expect(tester.takeException(), isNull);
  });

  testWidgets('story and game covers render only fetched memory bytes', (
    tester,
  ) async {
    final fetcher = _FakeMediaFetcher(bytes: _transparentPng);
    const story = StoryDetail(
      slug: 'remote-story',
      title: 'Remote story',
      author: 'Kingdom Kids',
      category: 'Faith',
      imageAsset: '',
      coverImageUrl: 'https://cdn.test/story.png?signature=story%2Bsig',
    );
    const game = MiniGame(
      id: 'remote-game',
      slug: 'remote-game',
      title: 'Remote game',
      type: MiniGameType.quiz,
      difficulty: 'Easy',
      duration: '3 min',
      imageAsset: '',
      coverImageUrl: 'https://cdn.test/game.png?signature=game%2Bsig',
      description: 'A game.',
      rewardStars: 3,
      totalLevels: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            StoryCoverImage(
              story: story,
              mediaPolicy: mediaPolicy,
              mediaFetcher: fetcher,
            ),
            GameCoverImage(
              game: game,
              mediaPolicy: mediaPolicy,
              mediaFetcher: fetcher,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images, hasLength(2));
    expect(
      images.every((image) => _sourceProvider(image.image) is MemoryImage),
      isTrue,
    );
    expect(fetcher.requested, [
      'https://cdn.test/story.png?signature=story%2Bsig',
      'https://cdn.test/game.png?signature=game%2Bsig',
    ]);
  });

  test(
    'voice sample loader rejects an unsafe URL before player setup',
    () async {
      final player = _FakeAudioPlayer();
      final errors = <String>[];
      final service = HostedStoryVoiceSampleService(
        audioPlayer: player,
        mediaPolicy: mediaPolicy,
      )..setCallbacks(onError: errors.add);

      await service.play(
        sampleUrl: 'https://user:secret@cdn.test/narrator.mp3',
      );

      expect(player.loadedFiles, isEmpty);
      expect(player.playCalls, 0);
      expect(errors, hasLength(1));
      await service.dispose();
    },
  );

  test('voice sample loader preserves a trusted signed CDN URL', () async {
    final player = _FakeAudioPlayer();
    final fetcher = _FakeMediaFetcher(bytes: [7, 8, 9]);
    final service = HostedStoryVoiceSampleService(
      audioPlayer: player,
      mediaPolicy: mediaPolicy,
      mediaFetcher: fetcher,
    );

    await service.play(
      sampleUrl: 'https://cdn.test/narrator.mp3?signature=abc123',
    );
    await Future<void>.delayed(Duration.zero);

    expect(fetcher.requested, [
      'https://cdn.test/narrator.mp3?signature=abc123',
    ]);
    expect(player.loadedFiles, hasLength(1));
    final preparedFile = File(player.loadedFiles.single);
    expect(await preparedFile.readAsBytes(), orderedEquals([7, 8, 9]));
    expect(player.playCalls, 1);
    await service.dispose();
    expect(await preparedFile.exists(), isFalse);
  });
}

ImageProvider _sourceProvider(ImageProvider provider) =>
    provider is ResizeImage ? provider.imageProvider : provider;

final class _FakeAudioPlayer extends AudioPlayer {
  final loadedFiles = <String>[];
  int playCalls = 0;

  @override
  Future<Duration?> setFilePath(
    String filePath, {
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    loadedFiles.add(filePath);
    return Duration.zero;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> play() async {
    playCalls++;
  }

  @override
  Future<void> dispose() async {}
}

final class _FakeMediaFetcher implements ContentMediaFetcher {
  _FakeMediaFetcher({required List<int> bytes})
    : _bytes = List<int>.unmodifiable(bytes);

  final List<int> _bytes;
  final List<String> requested = [];

  @override
  Future<FetchedContentMedia> fetch(Object? source) async {
    final raw = source.toString();
    requested.add(raw);
    return FetchedContentMedia(
      bytes: Uint8List.fromList(_bytes),
      finalUri: Uri.parse(raw),
      contentType: raw.endsWith('.mp3?signature=abc123')
          ? 'audio/mpeg'
          : 'image/png',
    );
  }
}

final _transparentPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

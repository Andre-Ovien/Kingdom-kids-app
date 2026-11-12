import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// Decodes the approved Blender renders once per rescue and owns their memory.
class ArkTrafficGraphics {
  ArkTrafficGraphics._(
    this.animals,
    this.background,
    this.gate,
    this.decodedBytes,
  );
  static const assetRoot = 'assets/images/games/ark_traffic';
  static const maximumDecodedBytes = 48 * 1024 * 1024;
  final Map<String, ArkTrafficAtlas> animals;
  final ui.Image background;
  final ArkTrafficAtlas? gate;
  final int decodedBytes;
  bool _disposed = false;

  static Future<ArkTrafficGraphics> load(
    int levelNumber, {
    AssetBundle? bundle,
  }) async {
    if (levelNumber < 1 || levelNumber > 3) {
      throw const FormatException('There are three authored Ark maps.');
    }
    final assets = bundle ?? rootBundle;
    final raw = jsonDecode(await assets.loadString('$assetRoot/manifest.json'));
    if (raw is! Map ||
        raw['version'] != 1 ||
        raw['animals'] is! Map ||
        raw['backgrounds'] is! Map) {
      throw const FormatException('The Ark graphics manifest is invalid.');
    }
    final images = <ui.Image>[];
    var decodedBytes = 0;
    Future<ui.Image> decode(String asset) async {
      if (!asset.startsWith('$assetRoot/') || asset.contains('..')) {
        throw const FormatException('An Ark asset path is invalid.');
      }
      final bytes = await assets.load(asset);
      ui.ImmutableBuffer? buffer;
      ui.ImageDescriptor? descriptor;
      ui.Codec? codec;
      try {
        buffer = await ui.ImmutableBuffer.fromUint8List(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
        descriptor = await ui.ImageDescriptor.encoded(buffer);
        if (descriptor.width <= 0 ||
            descriptor.height <= 0 ||
            descriptor.width > 4096 ||
            descriptor.height > 4096) {
          throw const FormatException('An Ark texture is too large.');
        }
        final allocation = descriptor.width * descriptor.height * 4;
        if (decodedBytes + allocation > maximumDecodedBytes) {
          throw const FormatException(
            'The Ark textures exceed their memory budget.',
          );
        }
        codec = await descriptor.instantiateCodec();
        if (codec.frameCount != 1) {
          throw const FormatException('An Ark atlas must be still.');
        }
        final image = (await codec.getNextFrame()).image;
        images.add(image);
        decodedBytes += allocation;
        return image;
      } finally {
        codec?.dispose();
        descriptor?.dispose();
        buffer?.dispose();
      }
    }

    Future<ArkTrafficAtlas> atlas(Object? value) async {
      if (value is! Map ||
          value['asset'] is! String ||
          value['cell'] is! int ||
          value['directions'] is! int ||
          value['frames'] is! int ||
          value['foot_anchor'] is! List ||
          (value['foot_anchor'] as List).length != 2) {
        throw const FormatException('An Ark animation definition is invalid.');
      }
      final cell = value['cell'] as int;
      final directions = value['directions'] as int;
      final frames = value['frames'] as int;
      final anchor = value['foot_anchor'] as List;
      if (cell < 32 ||
          cell > 512 ||
          directions < 1 ||
          directions > 8 ||
          frames < 1 ||
          frames > 16 ||
          anchor.any(
            (value) =>
                value is! num || !value.isFinite || value < 0 || value > cell,
          )) {
        throw const FormatException('An Ark animation exceeds its bounds.');
      }
      final image = await decode(value['asset'] as String);
      if (image.width != frames * cell || image.height != directions * cell) {
        throw const FormatException('The Ark atlas dimensions do not match.');
      }
      return ArkTrafficAtlas(
        image,
        cell,
        directions,
        frames,
        ui.Offset((anchor[0] as num).toDouble(), (anchor[1] as num).toDouble()),
      );
    }

    try {
      final animals = <String, ArkTrafficAtlas>{};
      for (final species in const ['tortoise', 'elephant', 'goat', 'rabbit']) {
        final clip = await atlas((raw['animals'] as Map)[species]);
        if (clip.directions != 8 || clip.frames != 9) {
          throw const FormatException(
            'An Ark animal needs its resting pose and eight walk views.',
          );
        }
        animals[species] = clip;
      }
      final backgroundAsset = (raw['backgrounds'] as Map)['$levelNumber'];
      if (backgroundAsset is! String) {
        throw const FormatException('An Ark map background is missing.');
      }
      final background = await decode(backgroundAsset);
      final gate = raw['gate'] == null ? null : await atlas(raw['gate']);
      if (gate != null && (gate.directions != 1 || gate.frames != 2)) {
        throw const FormatException(
          'An Ark gate needs its two authored hinge states.',
        );
      }
      return ArkTrafficGraphics._(
        Map.unmodifiable(animals),
        background,
        gate,
        decodedBytes,
      );
    } catch (_) {
      for (final image in images) {
        image.dispose();
      }
      rethrow;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final atlas in animals.values) {
      atlas.image.dispose();
    }
    background.dispose();
    gate?.image.dispose();
  }
}

class ArkTrafficAtlas {
  const ArkTrafficAtlas(
    this.image,
    this.cell,
    this.directions,
    this.frames,
    this.footAnchor,
  );
  final ui.Image image;
  final int cell;
  final int directions;
  final int frames;
  final ui.Offset footAnchor;
  ui.Rect source(int direction, int frame) => ui.Rect.fromLTWH(
    (frame % frames) * cell.toDouble(),
    (direction % directions) * cell.toDouble(),
    cell.toDouble(),
    cell.toDouble(),
  );
}

import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';

class CreationWorldGraphics {
  CreationWorldGraphics(this.images, this.animals);
  static const root = 'assets/images/games/creation_world';
  final Map<String, ui.Image> images;
  final Map<String, Map<String, dynamic>> animals;
  bool _disposed = false;

  static Future<CreationWorldGraphics> load(
    int level, {
    AssetBundle? bundle,
  }) async {
    final assets = bundle ?? rootBundle;
    final images = <String, ui.Image>{};
    final animals = <String, Map<String, dynamic>>{};
    var memory = 0;
    Future<ui.Image> decode(String path) async {
      final bytes = await assets.load(path);
      final buffer = await ui.ImmutableBuffer.fromUint8List(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      ui.ImageDescriptor? descriptor;
      ui.Codec? codec;
      try {
        descriptor = await ui.ImageDescriptor.encoded(buffer);
        final size = descriptor.width * descriptor.height * 4;
        if (descriptor.width > 4096 ||
            descriptor.height > 4096 ||
            memory + size > 40 * 1024 * 1024) {
          throw const FormatException(
            'Creation artwork exceeds its memory budget.',
          );
        }
        codec = await descriptor.instantiateCodec();
        final image = (await codec.getNextFrame()).image;
        memory += size;
        return image;
      } finally {
        codec?.dispose();
        descriptor?.dispose();
        buffer.dispose();
      }
    }

    try {
      for (final kind in [
        'background',
        'empty',
        'light',
        'cloud',
        'water',
        'land',
        'forest',
        if (level >= 2) ...['sun', 'moon', 'fish', 'bird'],
      ]) {
        images[kind] = await decode('$root/$kind.png');
      }
      if (level >= 3) {
        final manifest = Map<String, dynamic>.from(
          jsonDecode(
                await assets.loadString(
                  'assets/images/games/ark_traffic/manifest.json',
                ),
              )
              as Map,
        );
        final defs = Map<String, dynamic>.from(manifest['animals'] as Map);
        for (final kind in ['goat', 'rabbit']) {
          final definition = Map<String, dynamic>.from(defs[kind] as Map);
          final path = definition['asset'] as String;
          if (!path.startsWith('assets/images/games/ark_traffic/') ||
              path.contains('..')) {
            throw const FormatException('Invalid creature art.');
          }
          images[kind] = await decode(path);
          animals[kind] = definition;
        }
      }
      return CreationWorldGraphics(images, animals);
    } catch (_) {
      for (final image in images.values.toSet()) {
        image.dispose();
      }
      rethrow;
    }
  }

  ui.Rect source(String kind, int frame, int direction) {
    final image = images[kind]!;
    final animal = animals[kind];
    if (animal != null) {
      final cell = (animal['cell'] as num).toDouble();
      return ui.Rect.fromLTWH(
        (frame % (animal['frames'] as int)) * cell,
        (direction % (animal['directions'] as int)) * cell,
        cell,
        cell,
      );
    }
    if (kind == 'fish' || kind == 'bird') {
      final cell = image.height.toDouble();
      return ui.Rect.fromLTWH((frame % 8) * cell, 0, cell, cell);
    }
    if (['empty', 'water', 'land', 'forest'].contains(kind)) {
      // All four Blender exports share this registration rectangle. Cropping
      // their studio padding makes adjacent ground surfaces join visually.
      return const ui.Rect.fromLTRB(40, 49, 184, 187);
    }
    return ui.Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final image in images.values.toSet()) {
      image.dispose();
    }
  }
}

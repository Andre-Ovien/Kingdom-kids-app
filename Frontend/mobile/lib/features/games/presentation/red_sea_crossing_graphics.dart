import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// Owns the decoded Blender atlases for one Red Sea scene.
///
/// Loading is atomic: a malformed manifest or failed atlas leaves no decoded
/// images behind. The engine owns this object and must dispose it, including a
/// successfully loaded object made stale by a newer loading generation.
class RedSeaCrossingGraphics {
  RedSeaCrossingGraphics._(this._clips, this._images, this.totalDecodedBytes);

  static const maximumTextureDimension = 4096;
  static const defaultMaximumDecodedBytes = 128 * 1024 * 1024;

  final Map<String, RedSeaCrossingGraphicsClip> _clips;
  final List<ui.Image> _images;
  final int totalDecodedBytes;
  bool _disposed = false;

  Iterable<String> get clipNames => _clips.keys;

  RedSeaCrossingGraphicsClip? clip(String name) {
    if (_disposed) throw StateError('The crossing graphics were disposed.');
    return _clips[name];
  }

  static Future<RedSeaCrossingGraphics> load(
    String manifestAsset, {
    AssetBundle? bundle,
    int maximumDecodedBytes = defaultMaximumDecodedBytes,
  }) async {
    if (maximumDecodedBytes <= 0) {
      throw ArgumentError.value(
        maximumDecodedBytes,
        'maximumDecodedBytes',
        'Must be positive.',
      );
    }
    final assets = bundle ?? rootBundle;
    final manifest = jsonDecode(await assets.loadString(manifestAsset));
    if (manifest is! Map ||
        manifest['version'] is! int ||
        manifest['version'] != 1 ||
        manifest['clips'] is! Map) {
      throw const FormatException('Unsupported crossing graphics manifest.');
    }
    final rawClips = manifest['clips'] as Map;
    if (rawClips.isEmpty) {
      throw const FormatException('The crossing graphics contain no clips.');
    }
    final definitions = <String, _ClipDefinition>{};
    for (final entry in rawClips.entries) {
      if (entry.key is! String || (entry.key as String).trim().isEmpty) {
        throw const FormatException('A crossing clip needs a name.');
      }
      definitions[entry.key as String] = _ClipDefinition.parse(entry.value);
    }

    final images = <String, ui.Image>{};
    var decodedBytes = 0;
    try {
      for (final asset
          in definitions.values.map((clip) => clip.asset).toSet()) {
        final data = await assets.load(asset);
        ui.ImmutableBuffer? buffer;
        ui.ImageDescriptor? descriptor;
        ui.Codec? codec;
        try {
          buffer = await ui.ImmutableBuffer.fromUint8List(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          );
          descriptor = await ui.ImageDescriptor.encoded(buffer);
          final width = descriptor.width;
          final height = descriptor.height;
          if (width <= 0 ||
              height <= 0 ||
              width > maximumTextureDimension ||
              height > maximumTextureDimension) {
            throw const FormatException('A crossing atlas is too large.');
          }
          final bytes = width * height * 4;
          if (decodedBytes + bytes > maximumDecodedBytes) {
            throw const FormatException(
              'The crossing atlases exceed the decoded image budget.',
            );
          }
          for (final definition in definitions.values) {
            if (definition.asset == asset) {
              definition.validateTexture(width, height);
            }
          }
          codec = await descriptor.instantiateCodec();
          if (codec.frameCount != 1) {
            throw const FormatException(
              'A crossing atlas must be a single image.',
            );
          }
          final frame = await codec.getNextFrame();
          images[asset] = frame.image;
          decodedBytes += bytes;
        } finally {
          codec?.dispose();
          descriptor?.dispose();
          buffer?.dispose();
        }
      }
      final clips = <String, RedSeaCrossingGraphicsClip>{
        for (final entry in definitions.entries)
          entry.key: RedSeaCrossingGraphicsClip._(
            images[entry.value.asset]!,
            entry.value,
          ),
      };
      return RedSeaCrossingGraphics._(
        Map.unmodifiable(clips),
        List.unmodifiable(images.values),
        decodedBytes,
      );
    } catch (_) {
      for (final image in images.values) {
        image.dispose();
      }
      rethrow;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final image in _images) {
      image.dispose();
    }
  }
}

/// A fixed-cell sequence. Character anchors are in cell pixels, not UV units.
///
/// Environment clips omit both [footAnchor] and [bodyHeight]. Character clips
/// include both so their rendered feet can follow the existing gesture model.
class RedSeaCrossingGraphicsClip {
  RedSeaCrossingGraphicsClip._(this.image, _ClipDefinition definition)
    : cellWidth = definition.cellWidth,
      cellHeight = definition.cellHeight,
      columns = definition.columns,
      frameCount = definition.frameCount,
      footAnchor = definition.footAnchor,
      bodyHeight = definition.bodyHeight,
      durationSeconds = definition.durationSeconds,
      loop = definition.loop;

  /// Owned by the graphics collection; callers must not dispose this image.
  final ui.Image image;
  final int cellWidth;
  final int cellHeight;
  final int columns;
  final int frameCount;
  final ui.Offset? footAnchor;
  final double? bodyHeight;
  final double durationSeconds;
  final bool loop;
  final _paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;

  double get fps => frameCount / durationSeconds;

  int frameIndexAt(double normalizedProgress) {
    if (!normalizedProgress.isFinite) {
      throw ArgumentError.value(
        normalizedProgress,
        'normalizedProgress',
        'Must be finite.',
      );
    }
    final progress = loop
        ? normalizedProgress % 1.0
        : normalizedProgress.clamp(0.0, 1.0);
    return (progress * frameCount).floor().clamp(0, frameCount - 1);
  }

  ui.Rect sourceRect(int frameIndex) {
    if (frameIndex < 0 || frameIndex >= frameCount) {
      throw RangeError.range(frameIndex, 0, frameCount - 1, 'frameIndex');
    }
    return ui.Rect.fromLTWH(
      (frameIndex % columns * cellWidth).toDouble(),
      (frameIndex ~/ columns * cellHeight).toDouble(),
      cellWidth.toDouble(),
      cellHeight.toDouble(),
    );
  }

  ui.Rect sourceRectAt(double normalizedProgress) =>
      sourceRect(frameIndexAt(normalizedProgress));

  void drawFrame(
    ui.Canvas canvas,
    double normalizedProgress,
    ui.Rect destination, {
    ui.Paint? paint,
  }) {
    canvas.drawImageRect(
      image,
      sourceRectAt(normalizedProgress),
      destination,
      paint ?? _paint,
    );
  }
}

class _ClipDefinition {
  const _ClipDefinition({
    required this.asset,
    required this.cellWidth,
    required this.cellHeight,
    required this.columns,
    required this.frameCount,
    required this.footAnchor,
    required this.bodyHeight,
    required this.durationSeconds,
    required this.loop,
  });

  final String asset;
  final int cellWidth;
  final int cellHeight;
  final int columns;
  final int frameCount;
  final ui.Offset? footAnchor;
  final double? bodyHeight;
  final double durationSeconds;
  final bool loop;

  factory _ClipDefinition.parse(Object? value) {
    if (value is! Map ||
        value['asset'] is! String ||
        (value['asset'] as String).trim().isEmpty ||
        value['loop'] is! bool) {
      throw const FormatException('A crossing clip is malformed.');
    }
    int integer(String key) {
      final number = value[key];
      if (number is! int || number <= 0) {
        throw FormatException('A crossing clip needs a positive $key.');
      }
      return number;
    }

    double positiveNumber(String key) {
      final number = value[key];
      if (number is! num || !number.isFinite || number <= 0) {
        throw FormatException('A crossing clip needs a finite positive $key.');
      }
      return number.toDouble();
    }

    final cellWidth = integer('cellWidth');
    final cellHeight = integer('cellHeight');
    final columns = integer('columns');
    final frameCount = integer('frameCount');
    final durationSeconds = positiveNumber('durationSeconds');
    if (!(frameCount / durationSeconds).isFinite) {
      throw const FormatException('A crossing clip needs a finite frame rate.');
    }
    if (cellWidth > RedSeaCrossingGraphics.maximumTextureDimension ||
        cellHeight > RedSeaCrossingGraphics.maximumTextureDimension ||
        columns * cellWidth > RedSeaCrossingGraphics.maximumTextureDimension ||
        ((frameCount + columns - 1) ~/ columns) * cellHeight >
            RedSeaCrossingGraphics.maximumTextureDimension) {
      throw const FormatException('A crossing clip has an oversized grid.');
    }

    ui.Offset? anchor;
    double? bodyHeight;
    if (value.containsKey('footAnchor') || value.containsKey('bodyHeight')) {
      final rawAnchor = value['footAnchor'];
      if (rawAnchor is! List ||
          rawAnchor.length != 2 ||
          rawAnchor.any((number) => number is! num || !number.isFinite)) {
        throw const FormatException(
          'A crossing clip needs a finite foot anchor.',
        );
      }
      anchor = ui.Offset(
        (rawAnchor[0] as num).toDouble(),
        (rawAnchor[1] as num).toDouble(),
      );
      bodyHeight = positiveNumber('bodyHeight');
      if (anchor.dx < 0 ||
          anchor.dx > cellWidth ||
          anchor.dy < 0 ||
          anchor.dy > cellHeight ||
          bodyHeight > cellHeight) {
        throw const FormatException(
          'A crossing character lies outside its cell.',
        );
      }
    }
    return _ClipDefinition(
      asset: value['asset'] as String,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      columns: columns,
      frameCount: frameCount,
      footAnchor: anchor,
      bodyHeight: bodyHeight,
      durationSeconds: durationSeconds,
      loop: value['loop'] as bool,
    );
  }

  void validateTexture(int width, int height) {
    final rows = (frameCount + columns - 1) ~/ columns;
    if (columns * cellWidth > width || rows * cellHeight > height) {
      throw const FormatException('A crossing clip extends beyond its atlas.');
    }
  }
}

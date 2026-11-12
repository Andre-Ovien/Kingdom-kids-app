import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

const milestoneRevealManifestAsset = 'assets/images/milestones/box_reveal.json';
const milestoneRevealPosterAsset =
    'assets/images/milestones/box_reveal_poster.webp';

typedef MilestoneRevealGraphicsLoader =
    Future<MilestoneRevealGraphics> Function();

/// The rendered box contains no rank or level text. Flutter owns that overlay.
/// Each atlas is a consecutive, fixed-cell section of the same camera shot.
class MilestoneRevealGraphics {
  MilestoneRevealGraphics._({
    required this.cellWidth,
    required this.cellHeight,
    required this.columns,
    required this.frameCount,
    required this.durationSeconds,
    required this.badgeAnchor,
    required this.boxAnchor,
    required this.badgeEmergenceAnchor,
    required this.badgeStartSeconds,
    required this.badgeEndSeconds,
    required this.posterAsset,
    required List<_RevealAtlas> atlases,
  }) : _atlases = atlases;

  static const maximumTextureDimension = 4096;
  static const maximumDecodedBytes = 72 * 1024 * 1024;

  final int cellWidth;
  final int cellHeight;
  final int columns;
  final int frameCount;
  final double durationSeconds;
  final ui.Offset badgeAnchor;
  final ui.Offset boxAnchor;
  final ui.Offset badgeEmergenceAnchor;
  final double badgeStartSeconds;
  final double badgeEndSeconds;
  final String posterAsset;
  final List<_RevealAtlas> _atlases;
  final _paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
  bool _disposed = false;

  bool get isDisposed => _disposed;

  static Future<MilestoneRevealGraphics> load({
    AssetBundle? bundle,
    String manifestAsset = milestoneRevealManifestAsset,
  }) async {
    final assets = bundle ?? rootBundle;
    final raw = jsonDecode(await assets.loadString(manifestAsset));
    if (raw is! Map || raw['version'] != 1) {
      throw const FormatException('Unsupported milestone reveal manifest.');
    }
    int positiveInteger(Map value, String key) {
      final number = value[key];
      if (number is! int || number <= 0) {
        throw FormatException('The milestone reveal needs a positive $key.');
      }
      return number;
    }

    final width = positiveInteger(raw, 'cellWidth');
    final height = positiveInteger(raw, 'cellHeight');
    final columns = positiveInteger(raw, 'columns');
    final frames = positiveInteger(raw, 'frameCount');
    final duration = raw['durationSeconds'];
    if (duration is! num ||
        !duration.isFinite ||
        duration <= 0 ||
        duration > 10 ||
        width > maximumTextureDimension ||
        height > maximumTextureDimension ||
        columns * width > maximumTextureDimension) {
      throw const FormatException('Invalid milestone reveal dimensions.');
    }
    ui.Offset anchor(String key, ui.Offset fallback) {
      final value = raw[key];
      if (value == null) return fallback;
      if (value is! List ||
          value.length != 2 ||
          value.any(
            (coordinate) =>
                coordinate is! num ||
                !coordinate.isFinite ||
                coordinate < 0 ||
                coordinate > 1,
          )) {
        throw FormatException('The milestone reveal has an invalid $key.');
      }
      return ui.Offset(
        (value[0] as num).toDouble(),
        (value[1] as num).toDouble(),
      );
    }

    final timings = raw['timings'];
    double seconds(String key, double fallback) {
      final value = timings is Map ? timings[key] : null;
      if (value == null) return fallback.clamp(0, duration).toDouble();
      if (value is! num || !value.isFinite || value < 0 || value > duration) {
        throw FormatException('The milestone reveal has an invalid $key.');
      }
      return value.toDouble();
    }

    final badgeStart = seconds('badgeStart', 2.1);
    final badgeEnd = seconds('badgeEnd', 2.8);
    if (badgeEnd <= badgeStart) {
      throw const FormatException('The milestone badge timing is unordered.');
    }
    final badgeAnchor = anchor('badgeAnchor', const ui.Offset(0.46, 0.1));
    final boxAnchor = anchor('boxAnchor', const ui.Offset(0.5, 0.72));
    final badgeEmergence = anchor(
      'badgeEmergenceAnchor',
      const ui.Offset(0.5, 0.54),
    );
    final pages = raw['atlases'];
    if (pages is! List || pages.isEmpty) {
      throw const FormatException('The milestone reveal needs an atlas.');
    }
    final definitions = <({String asset, int firstFrame, int frameCount})>[];
    var expectedFrame = 0;
    for (final page in pages) {
      if (page is! Map ||
          page['asset'] is! String ||
          (page['asset'] as String).trim().isEmpty ||
          page['firstFrame'] != expectedFrame) {
        throw const FormatException('The milestone atlas sequence is broken.');
      }
      final count = positiveInteger(page, 'frameCount');
      final rows = (count + columns - 1) ~/ columns;
      if (rows * height > maximumTextureDimension ||
          expectedFrame + count > frames) {
        throw const FormatException('The milestone atlas grid is too large.');
      }
      definitions.add((
        asset: page['asset'] as String,
        firstFrame: expectedFrame,
        frameCount: count,
      ));
      expectedFrame += count;
    }
    if (expectedFrame != frames) {
      throw const FormatException('The milestone reveal is missing frames.');
    }

    final atlases = <_RevealAtlas>[];
    var decodedBytes = 0;
    try {
      for (final page in definitions) {
        final data = await assets.load(page.asset);
        ui.ImmutableBuffer? buffer;
        ui.ImageDescriptor? descriptor;
        ui.Codec? codec;
        try {
          buffer = await ui.ImmutableBuffer.fromUint8List(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          );
          descriptor = await ui.ImageDescriptor.encoded(buffer);
          final rows = (page.frameCount + columns - 1) ~/ columns;
          final bytes = descriptor.width * descriptor.height * 4;
          if (descriptor.width > maximumTextureDimension ||
              descriptor.height > maximumTextureDimension ||
              descriptor.width < columns * width ||
              descriptor.height < rows * height ||
              decodedBytes + bytes > maximumDecodedBytes) {
            throw const FormatException(
              'The milestone atlas exceeds its texture budget.',
            );
          }
          codec = await descriptor.instantiateCodec();
          if (codec.frameCount != 1) {
            throw const FormatException('A milestone atlas must be static.');
          }
          final image = (await codec.getNextFrame()).image;
          atlases.add(
            _RevealAtlas(
              image: image,
              firstFrame: page.firstFrame,
              frameCount: page.frameCount,
            ),
          );
          decodedBytes += bytes;
        } finally {
          codec?.dispose();
          descriptor?.dispose();
          buffer?.dispose();
        }
      }
      final poster = raw['posterAsset'];
      return MilestoneRevealGraphics._(
        cellWidth: width,
        cellHeight: height,
        columns: columns,
        frameCount: frames,
        durationSeconds: duration.toDouble(),
        badgeAnchor: badgeAnchor,
        boxAnchor: boxAnchor,
        badgeEmergenceAnchor: badgeEmergence,
        badgeStartSeconds: badgeStart,
        badgeEndSeconds: badgeEnd,
        posterAsset: poster is String && poster.isNotEmpty
            ? poster
            : milestoneRevealPosterAsset,
        atlases: atlases,
      );
    } catch (_) {
      for (final atlas in atlases) {
        atlas.image.dispose();
      }
      rethrow;
    }
  }

  int frameIndexAt(double progress) =>
      (progress.clamp(0.0, 1.0) * frameCount).floor().clamp(0, frameCount - 1);

  void drawFrame(ui.Canvas canvas, double progress, ui.Rect destination) {
    if (_disposed) return;
    final frame = frameIndexAt(progress);
    final atlas = _atlases.firstWhere(
      (page) =>
          frame >= page.firstFrame && frame < page.firstFrame + page.frameCount,
    );
    final local = frame - atlas.firstFrame;
    canvas.drawImageRect(
      atlas.image,
      ui.Rect.fromLTWH(
        (local % columns * cellWidth).toDouble(),
        (local ~/ columns * cellHeight).toDouble(),
        cellWidth.toDouble(),
        cellHeight.toDouble(),
      ),
      destination,
      _paint,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final atlas in _atlases) {
      atlas.image.dispose();
    }
  }
}

class _RevealAtlas {
  const _RevealAtlas({
    required this.image,
    required this.firstFrame,
    required this.frameCount,
  });

  final ui.Image image;
  final int firstFrame;
  final int frameCount;
}

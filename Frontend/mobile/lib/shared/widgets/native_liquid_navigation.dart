import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../features/auth/domain/kid_profile.dart';
import '../../features/auth/presentation/kid_profile_avatar.dart';

/// The native surface supplies Apple's system glass on supported iOS versions.
/// The view stays mounted in the app host while Flutter replaces tab content.
class NativeLiquidNavigation extends StatefulWidget {
  const NativeLiquidNavigation({
    required this.selectedRoute,
    required this.activeProfile,
    required this.reduceMotion,
    required this.onSelect,
    this.currentRoute,
    super.key,
  });

  final String selectedRoute;
  final KidProfile? activeProfile;
  final bool reduceMotion;
  final bool Function(String route) onSelect;
  final String Function()? currentRoute;

  @override
  State<NativeLiquidNavigation> createState() => _NativeLiquidNavigationState();
}

class _NativeLiquidNavigationState extends State<NativeLiquidNavigation> {
  MethodChannel? _channel;
  Uint8List? _profileImage;
  int _imageGeneration = 0;
  int _updateGeneration = 0;

  Map<String, Object?> get _payload => {
    'selectedRoute': widget.currentRoute?.call() ?? widget.selectedRoute,
    'profileImage': _profileImage,
    'reduceMotion': widget.reduceMotion,
  };

  @override
  void initState() {
    super.initState();
    unawaited(_loadProfileImage());
  }

  @override
  void didUpdateWidget(NativeLiquidNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeProfile?.id != widget.activeProfile?.id ||
        oldWidget.activeProfile?.parentId != widget.activeProfile?.parentId ||
        oldWidget.activeProfile?.avatarKey != widget.activeProfile?.avatarKey) {
      unawaited(_loadProfileImage());
    }
    unawaited(_update());
  }

  Future<void> _loadProfileImage() async {
    final generation = ++_imageGeneration;
    final profile = widget.activeProfile;
    // Clear the old child's picture before decoding another identity.
    _profileImage = null;
    await _update();
    if (profile == null) return;
    try {
      final option = kidAvatarOptionFor(profile.avatarKey);
      final Uint8List bytes;
      if (option.assetPath case final String path) {
        final data = await rootBundle.load(path);
        bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } else {
        bytes = await _legacyAvatarImage(option);
      }
      if (!mounted || generation != _imageGeneration) return;
      _profileImage = bytes;
      await _update();
    } catch (_) {
      // A missing portrait leaves the native person symbol, never another child.
    }
  }

  Future<void> _update() async {
    final channel = _channel;
    if (!mounted || channel == null) return;
    final generation = ++_updateGeneration;
    try {
      await channel.invokeMethod<void>('update', _payload);
    } on PlatformException catch (_) {
      // The native platform view may be leaving the composition during shutdown.
      if (!mounted || generation != _updateGeneration) return;
    } on MissingPluginException catch (_) {
      // No native channel remains during teardown or an isolated Flutter test.
    }
  }

  Future<void> _created(int id) async {
    final channel = MethodChannel('kingdom_kids/liquid_navigation/$id');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (!mounted || call.method != 'select') return;
      final arguments = call.arguments;
      final route = arguments is Map ? arguments['route'] : null;
      if (route is! String) return;
      final accepted = widget.onSelect(route);
      // Native feedback is optimistic. Reconcile rejected/repeated input to the
      // real route immediately rather than leaving its lens on the wrong tab.
      if (!accepted) await _update();
    });
    await _update();
  }

  @override
  void dispose() {
    _imageGeneration++;
    _updateGeneration++;
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UiKitView(
    key: const Key('native-liquid-navigation-view'),
    viewType: 'kingdom_kids/liquid_navigation',
    layoutDirection: Directionality.of(context),
    creationParams: _payload,
    creationParamsCodec: const StandardMessageCodec(),
    onPlatformViewCreated: _created,
  );
}

Future<Uint8List> _legacyAvatarImage(KidAvatarOption option) async {
  const size = 108.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawCircle(
    const Offset(size / 2, size / 2),
    size / 2,
    Paint()..color = option.color.withValues(alpha: 0.2),
  );
  canvas.drawCircle(
    const Offset(size / 2, size / 2),
    size / 2 - 1.5,
    Paint()
      ..color = option.color.withValues(alpha: 0.48)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3,
  );
  final painter = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(option.icon.codePoint),
      style: TextStyle(
        fontFamily: option.icon.fontFamily,
        package: option.icon.fontPackage,
        fontSize: size * 0.48,
        color: option.color,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(
    canvas,
    Offset((size - painter.width) / 2, (size - painter.height) / 2),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.toInt(), size.toInt());
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    painter.dispose();
    image.dispose();
    picture.dispose();
  }
}

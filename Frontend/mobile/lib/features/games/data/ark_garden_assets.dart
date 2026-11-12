import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

/// A phone-local origin for bundled ES modules and GLBs. Nothing is served
/// from the filesystem, LAN, Django DEBUG media, or a public network endpoint.
abstract interface class ArkGardenAssetOrigin {
  Uri get entryPoint;
  bool allowsNavigation(String url);
  Future<void> close();
}

class ArkGardenAssetServer implements ArkGardenAssetOrigin {
  ArkGardenAssetServer._(this._server, this._bundle, this._token) {
    _subscription = _server.listen(_serve);
  }

  static const assetPrefix = 'assets/games/ark_garden/';
  static const files = <String>{
    'garden.html',
    'garden.css',
    'preview.css',
    'garden_preview.mjs',
    'garden_contract.mjs',
    'garden_traffic.mjs',
    'garden_asset_integrity.mjs',
    'animal_locomotion.mjs',
    'animal_preview_config.mjs',
    'garden_native_assets.json',
    'garden_course_v2.json',
    'vendor/three.module.js',
    'vendor/three.core.js',
    'vendor/loaders/GLTFLoader.js',
    'vendor/utils/BufferGeometryUtils.js',
    'assets/garden.png',
    'assets/ark-review.glb',
    'assets/noah-review.glb',
    'assets/elephant-review.glb',
    'assets/sheep-review.glb',
    'assets/zebra-review.glb',
    'assets/donkey-review.glb',
    'assets/deer-review.glb',
    'assets/rabbit-review.glb',
    'assets/dove-review.glb',
    'assets/lion-review.glb',
    'assets/camel-review.glb',
    'assets/giraffe-review.glb',
  };

  final HttpServer _server;
  final AssetBundle _bundle;
  final String _token;
  late final StreamSubscription<HttpRequest> _subscription;
  bool _closed = false;

  static Future<ArkGardenAssetServer> open({AssetBundle? bundle}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final token = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return ArkGardenAssetServer._(server, bundle ?? rootBundle, token);
  }

  @override
  Uri get entryPoint => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: _server.port,
    path: '/$_token/garden.html',
    query: 'host=1',
  );

  @override
  bool allowsNavigation(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.scheme == 'http' &&
        uri.host == '127.0.0.1' &&
        uri.port == _server.port &&
        uri.path == entryPoint.path;
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      final prefix = '/$_token/';
      final path = request.uri.path;
      final filename = path.startsWith(prefix)
          ? path.substring(prefix.length)
          : '';
      if (_closed ||
          !files.contains(filename) ||
          !{'GET', 'HEAD'}.contains(request.method)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final bytes = await _bundle.load('$assetPrefix$filename');
      final response = request.response;
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.headers.set('X-Content-Type-Options', 'nosniff');
      response.headers.set(
        'Content-Security-Policy',
        "default-src 'self'; script-src 'self' 'unsafe-inline'; "
            "style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; "
            "connect-src 'self' blob:; object-src 'none'; frame-src 'none'",
      );
      response.headers.contentType = _contentType(filename);
      response.contentLength = bytes.lengthInBytes;
      if (request.method == 'GET') {
        response.add(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      }
      await response.close();
    } on Object {
      try {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      } on Object {
        // Closing the owned origin can cancel a model request mid-transfer.
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    await _server.close(force: true);
  }

  static ContentType _contentType(String path) {
    if (path.endsWith('.html')) return ContentType.html;
    if (path.endsWith('.json')) return ContentType.json;
    if (path.endsWith('.css')) {
      return ContentType('text', 'css', charset: 'utf-8');
    }
    if (path.endsWith('.js') || path.endsWith('.mjs')) {
      return ContentType('application', 'javascript', charset: 'utf-8');
    }
    if (path.endsWith('.png')) return ContentType('image', 'png');
    return ContentType('model', 'gltf-binary');
  }
}

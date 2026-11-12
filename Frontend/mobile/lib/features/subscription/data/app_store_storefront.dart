import 'package:flutter/services.dart';

typedef StorefrontCountryProvider = Future<String?> Function();

/// Storefront is an App Store account signal, never device locale or IP.
class AppStoreStorefront {
  static const _channel = MethodChannel('kingdom_kids/storefront');

  static Future<String?> currentCountryCode() async {
    try {
      return await _channel.invokeMethod<String>('currentCountryCode');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

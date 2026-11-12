/// Returns whether [rawHost] is unsuitable for a production service endpoint.
///
/// This check is deliberately DNS-free and deterministic. It rejects local
/// aliases and literal address ranges that cannot represent a publicly routed
/// production service, while leaving ordinary hostnames for the platform's
/// normal DNS and TLS validation.
bool isUnsafeReleaseEndpointHost(String rawHost) {
  var host = rawHost.trim().toLowerCase();
  while (host.endsWith('.')) {
    host = host.substring(0, host.length - 1);
  }
  if (host.isEmpty) return true;

  if (_localAliases.contains(host) ||
      host.endsWith('.localhost') ||
      host.endsWith('.local')) {
    return true;
  }

  // Scoped IPv6 addresses are local to an interface and never appropriate in
  // a release endpoint. URI implementations may expose either `%` or `%25`.
  if (host.contains('%')) return true;

  final ipv4 = _parseIpv4(host);
  if (ipv4 != null) return _isNonPublicIpv4(ipv4);
  if (_looksLikeLegacyIpv4(host)) return true;

  final ipv6 = _parseIpv6(host);
  if (ipv6 != null) return _isNonPublicIpv6(ipv6);
  if (host.contains(':')) return true;

  return false;
}

/// Validates one lower-case, bare hostname from `CONTENT_MEDIA_HOSTS`.
///
/// Schemes, ports, paths, wildcard labels, empty labels, underscores, and
/// label-edge hyphens are intentionally excluded.
bool isValidConfiguredMediaHost(String value) {
  return RegExp(
    r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*'
    r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$',
  ).hasMatch(value);
}

const _localAliases = {
  'localhost',
  'local',
  'localhost.localdomain',
  'ip6-localhost',
  'ip6-loopback',
  'broadcasthost',
  'host.docker.internal',
  'gateway.docker.internal',
  'host.containers.internal',
};

List<int>? _parseIpv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;

  final octets = <int>[];
  for (final part in parts) {
    if (part.isEmpty ||
        !RegExp(r'^\d+$').hasMatch(part) ||
        (part.length > 1 && part.startsWith('0'))) {
      return null;
    }
    final octet = int.tryParse(part);
    if (octet == null || octet > 255) return null;
    octets.add(octet);
  }
  return octets;
}

bool _looksLikeLegacyIpv4(String host) {
  if (RegExp(r'^[0-9.]+$').hasMatch(host)) return true;
  final labels = host.split('.');
  return labels.isNotEmpty &&
      labels.every(
        (label) => RegExp(r'^(?:0x[0-9a-f]+|0[0-7]+|[0-9]+)$').hasMatch(label),
      );
}

bool _isNonPublicIpv4(List<int> address) {
  final first = address[0];
  final second = address[1];
  final third = address[2];

  return first == 0 || // Unspecified and current-network space.
      first == 10 || // RFC 1918.
      first == 127 || // Loopback.
      (first == 100 && second >= 64 && second <= 127) || // Shared space.
      (first == 169 && second == 254) || // Link-local.
      (first == 172 && second >= 16 && second <= 31) || // RFC 1918.
      (first == 192 && second == 168) || // RFC 1918.
      (first == 192 && second == 0 && third == 2) || // Documentation.
      (first == 198 && (second == 18 || second == 19)) || // Benchmarking.
      (first == 198 && second == 51 && third == 100) || // Documentation.
      (first == 203 && second == 0 && third == 113) || // Documentation.
      first >= 224; // Multicast, reserved, and broadcast space.
}

List<int>? _parseIpv6(String host) {
  if (!host.contains(':')) return null;
  final compressionIndex = host.indexOf('::');
  if (compressionIndex != -1 && compressionIndex != host.lastIndexOf('::')) {
    return null;
  }

  if (compressionIndex == -1) {
    final words = _parseIpv6Section(host);
    return words?.length == 8 ? words : null;
  }

  final left = _parseIpv6Section(host.substring(0, compressionIndex));
  final right = _parseIpv6Section(host.substring(compressionIndex + 2));
  if (left == null || right == null || left.length + right.length >= 8) {
    return null;
  }
  return [
    ...left,
    ...List<int>.filled(8 - left.length - right.length, 0),
    ...right,
  ];
}

List<int>? _parseIpv6Section(String section) {
  if (section.isEmpty) return <int>[];
  final tokens = section.split(':');
  final words = <int>[];
  for (var index = 0; index < tokens.length; index += 1) {
    final token = tokens[index];
    if (token.contains('.')) {
      if (index != tokens.length - 1) return null;
      final ipv4 = _parseIpv4(token);
      if (ipv4 == null) return null;
      words
        ..add((ipv4[0] << 8) | ipv4[1])
        ..add((ipv4[2] << 8) | ipv4[3]);
      continue;
    }
    if (!RegExp(r'^[0-9a-f]{1,4}$').hasMatch(token)) return null;
    words.add(int.parse(token, radix: 16));
  }
  return words;
}

bool _isNonPublicIpv6(List<int> address) {
  final unspecified = address.every((word) => word == 0);
  final loopback =
      address.take(7).every((word) => word == 0) && address.last == 1;
  final first = address.first;
  final uniqueLocal = first & 0xfe00 == 0xfc00;
  final linkLocal = first & 0xffc0 == 0xfe80;
  final deprecatedSiteLocal = first & 0xffc0 == 0xfec0;
  final multicast = first & 0xff00 == 0xff00;
  if (unspecified ||
      loopback ||
      uniqueLocal ||
      linkLocal ||
      deprecatedSiteLocal ||
      multicast) {
    return true;
  }

  final hasIpv4Tail =
      address.take(5).every((word) => word == 0) &&
      (address[5] == 0 || address[5] == 0xffff);
  if (!hasIpv4Tail) return false;
  final ipv4 = [
    address[6] >> 8,
    address[6] & 0xff,
    address[7] >> 8,
    address[7] & 0xff,
  ];
  return _isNonPublicIpv4(ipv4);
}

import 'package:flutter/foundation.dart';

/// Last successful display state, bounded independently of network freshness.
/// It may seed a same-identity screen while its authoritative read runs again.
/// Authentication and billing state must never be stored here.
class FeatureViewStateCache extends ChangeNotifier {
  final _entries = <Object, Map<String, Object?>>{};
  int _identityRevision = 0;
  Object? _knownScope;
  int get identityRevision => _identityRevision;

  FeaturePagePreparation prepare(Object? scope, String route) {
    _knownScope = scope;
    final key = (scope, route);
    final memory = scope == null
        ? <String, Object?>{}
        : _entries.remove(key) ?? <String, Object?>{};
    if (scope != null) _entries[key] = memory;
    while (_entries.length > 12) {
      _entries.remove(_entries.keys.first);
    }
    return FeaturePagePreparation._(scope, memory, _identityRevision);
  }

  FeaturePagePreparation? knownPreparation(String route) =>
      _knownScope == null ? null : prepare(_knownScope, route);

  void clearIdentity() {
    _identityRevision++;
    _knownScope = null;
    _entries.clear();
    notifyListeners();
  }
}

class FeaturePagePreparation {
  const FeaturePagePreparation._(
    this.scope,
    this.memory,
    this.identityRevision,
  );
  final Object? scope;
  final Map<String, Object?> memory;
  final int identityRevision;
  bool get isCurrent =>
      identityRevision == featureViewStateCache.identityRevision;
}

final featureViewStateCache = FeatureViewStateCache();

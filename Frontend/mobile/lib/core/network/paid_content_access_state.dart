import 'package:flutter/foundation.dart';

import 'feature_read_cache.dart';
import 'feature_view_state_cache.dart';

/// Authoritative content denials are separate from authentication and from
/// retryable connectivity failures. No local purchase result grants access.
class PaidContentAccessState extends ChangeNotifier {
  Object? _currentScope;
  final _denied = <Object>{};
  int _denialRevision = 0;
  int get denialRevision => _denialRevision;

  bool get isDenied => _currentScope != null && _denied.contains(_currentScope);

  void selectScope(Object? scope) {
    final wasDenied = isDenied;
    _currentScope = scope;
    if (wasDenied != isDenied) notifyListeners();
  }

  void deny(Object scope) {
    if (scope != _currentScope) return;
    _denialRevision++;
    if (!_denied.add(scope)) return;
    while (_denied.length > 8) {
      _denied.remove(_denied.first);
    }
    // Advance media provenance as well as read freshness. Old private bytes
    // and in-flight successful reads cannot become valid after a denial.
    featureReadCache.invalidate();
    featureViewStateCache.clearIdentity();
    notifyListeners();
  }

  void allow(Object scope, {int? expectedDenialRevision}) {
    if (expectedDenialRevision != null &&
        expectedDenialRevision != _denialRevision) {
      return;
    }
    if (scope == _currentScope && _denied.remove(scope)) notifyListeners();
  }
}

final paidContentAccessState = PaidContentAccessState();

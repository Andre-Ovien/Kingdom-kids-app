import 'dart:async';

import '../../../core/network/paid_content_access_state.dart';
import '../../../core/network/feature_view_state_cache.dart';
import '../../auth/data/auth_repository.dart';
import 'sandbox_checkout.dart';

/// Production-only access freshness. It never launches checkout or changes an
/// unknown/network failure into unpaid. A verified paid term has a hard end.
class ParentContentAccessMonitor {
  ParentContentAccessMonitor({
    this.configuration = const SandboxCheckoutConfiguration(),
    AuthRepository? authRepository,
    SandboxContentAccessRepository? repository,
  }) : _auth = authRepository ?? AuthRepository() {
    if (configuration.isProductionEnabled) {
      featureViewStateCache.addListener(_identityChanged);
      _repository =
          repository ??
          (_ownedRepository = AuthenticatedSandboxContentAccessRepository(
            configuration: configuration,
            authRepository: _auth,
          ));
    }
  }

  final SandboxCheckoutConfiguration configuration;
  final AuthRepository _auth;
  SandboxContentAccessRepository? _repository;
  AuthenticatedSandboxContentAccessRepository? _ownedRepository;
  Timer? _expiryTimer;
  Object? _paidScope;
  DateTime? _paidUntil;
  int _revision = 0;
  bool _disposed = false;
  int _termRevision = 0;

  void _identityChanged() {
    unawaited(refresh());
  }

  Future<void> refresh() async {
    try {
      await _refresh();
    } catch (_) {
      // Protected storage can be temporarily unavailable too. Never turn
      // that into an unpaid decision or an unhandled lifecycle exception.
    }
  }

  Future<void> _refresh() async {
    if (_disposed || _repository == null) return;
    final revision = ++_revision;
    final scope = await _auth.parentAccessScope();
    if (_disposed || revision != _revision) return;
    if (scope == null || (_paidScope != null && scope != _paidScope)) {
      _expiryTimer?.cancel();
      _termRevision++;
      _paidScope = null;
      _paidUntil = null;
    }
    if (scope == null) return;
    if (_paidScope == scope &&
        _paidUntil != null &&
        !DateTime.now().toUtc().isBefore(_paidUntil!)) {
      paidContentAccessState.deny(scope);
    }
    final denialRevision = paidContentAccessState.denialRevision;
    try {
      final access = await _repository!.fetch();
      if (_disposed ||
          revision != _revision ||
          scope != await _auth.parentAccessScope()) {
        return;
      }
      if (denialRevision != paidContentAccessState.denialRevision) return;
      if (!access.enforcementEnabled) {
        _expiryTimer?.cancel();
        _termRevision++;
        _paidScope = null;
        _paidUntil = null;
        paidContentAccessState.allow(
          scope,
          expectedDenialRevision: denialRevision,
        );
        return;
      }
      if (!access.routingEnabled) return;
      if (access.state == SandboxAccessState.unpaid) {
        _expiryTimer?.cancel();
        _termRevision++;
        _paidScope = null;
        _paidUntil = null;
        paidContentAccessState.deny(scope);
      } else if (access.state == SandboxAccessState.paid &&
          access.accessUntil != null) {
        _expiryTimer?.cancel();
        _paidScope = scope;
        _paidUntil = access.accessUntil;
        final termRevision = ++_termRevision;
        final paidUntil = access.accessUntil;
        final remaining = access.accessUntil!.difference(
          DateTime.now().toUtc(),
        );
        if (remaining <= Duration.zero) {
          paidContentAccessState.deny(scope);
        } else {
          paidContentAccessState.allow(
            scope,
            expectedDenialRevision: denialRevision,
          );
          _expiryTimer = Timer(remaining, () {
            if (_disposed ||
                termRevision != _termRevision ||
                _paidScope != scope ||
                _paidUntil != paidUntil) {
              return;
            }
            // Synchronous: an old callback cannot pause in storage, outlive
            // cancellation, and then revoke a newly verified paid term.
            // deny also checks that this remains the selected parent scope.
            paidContentAccessState.deny(scope);
          });
        }
      }
    } catch (_) {
      // Retain a known unexpired paid term, without granting new access or
      // resetting its original expiry. Parent controls remain independent.
    }
  }

  void dispose() {
    _disposed = true;
    _revision++;
    _termRevision++;
    _expiryTimer?.cancel();
    featureViewStateCache.removeListener(_identityChanged);
    _ownedRepository?.dispose();
  }
}

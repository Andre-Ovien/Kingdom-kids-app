import 'dart:async';
import 'dart:math';

import '../../../core/errors/app_exception.dart';
import '../../auth/data/auth_repository.dart';
import '../domain/hosted_checkout_return.dart';
import '../domain/hosted_subscription.dart';
import '../domain/subscription_plan.dart';
import 'app_store_storefront.dart';
import 'hosted_checkout_pending_store.dart';
import 'hosted_subscription_repository.dart';
import 'sandbox_checkout.dart';

typedef HostedParentAuthorization =
    Future<bool> Function(
      HostedQuote quote,
      Future<void> Function(String password) authorize,
    );
typedef HostedCancellationAuthorization =
    Future<bool> Function(Future<void> Function(String password) cancel);

enum HostedFlowState {
  idle,
  preparing,
  awaitingProvider,
  checking,
  pending,
  paid,
  failed,
}

String newHostedOperationId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// One stable parent-owned operation survives network ambiguity and app returns.
/// Only read-only provider reconciliation and canonical access can finish it.
class HostedSubscriptionController extends ParentCheckoutController {
  HostedSubscriptionController({
    required this.configuration,
    required HostedSubscriptionRepository repository,
    required HostedCheckoutPendingStore pendingStore,
    AuthRepository? authRepository,
    required SandboxBrowserLauncher launcher,
    StorefrontCountryProvider? storefrontCountryProvider,
    String Function()? operationId,
    this.pollDelays = const [
      Duration.zero,
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 3),
      Duration(seconds: 5),
    ],
  }) : _repository = repository,
       _store = pendingStore,
       _auth = authRepository ?? AuthRepository(),
       _launcher = launcher,
       _country =
           storefrontCountryProvider ?? AppStoreStorefront.currentCountryCode,
       _operationId = operationId ?? newHostedOperationId;
  @override
  final SandboxCheckoutConfiguration configuration;
  final HostedSubscriptionRepository _repository;
  final HostedCheckoutPendingStore _store;
  final AuthRepository _auth;
  final SandboxBrowserLauncher _launcher;
  final StorefrontCountryProvider _country;
  final String Function() _operationId;
  final List<Duration> pollDelays;
  HostedParentAuthorization? authorizeParent;
  HostedCancellationAuthorization? authorizeCancellation;
  HostedPendingCheckout? _pending;
  Map<String, dynamic>? _recovery;
  HostedAttempt? _attempt;
  SandboxContentAccess? _access;
  Object? _owner;
  bool _busy = false,
      _checking = false,
      _disposed = false,
      _foreground = true,
      _loaded = false;
  int _revision = 0, _noticeSequence = 0, _successSequence = 0;
  String? _error, _completedAttempt;
  Future<void>? _verification;
  HostedFlowState _state = HostedFlowState.idle;
  @override
  SandboxContentAccess? get access => _access;
  @override
  bool get busy => _busy || _checking;
  @override
  bool get checking => _checking;
  @override
  String? get error => _error;
  int get noticeSequence => _noticeSequence;
  int get successSequence => _successSequence;
  HostedFlowState get state => _state;
  HostedPendingCheckout? get pending => _pending;
  String? get persistentStatus => _checking
      ? 'Checking your subscription…'
      : switch (_state) {
          HostedFlowState.preparing => 'Opening secure payment…',
          HostedFlowState.awaitingProvider =>
            'Complete payment on Square. We will check it when you return.',
          HostedFlowState.checking => 'Checking your subscription…',
          HostedFlowState.pending =>
            'Your payment is still being checked. Checking will not make another charge.',
          HostedFlowState.failed =>
            'Payment was not completed. You can try again.',
          _ => null,
        };
  @override
  bool get canOpen =>
      configuration.isHostedProductionEnabled &&
      _foreground &&
      !busy &&
      _access?.state == SandboxAccessState.unpaid &&
      _access?.checkoutAvailable == true &&
      (_pending == null ||
          _state == HostedFlowState.failed ||
          _pending?.attemptId == null ||
          _attempt?.state == 'reserved' ||
          _attempt?.state == 'ready');
  @override
  bool get canManage =>
      configuration.isHostedProductionEnabled &&
      !busy &&
      _access?.managementAvailable == true &&
      _recovery != null;

  void dismissError(int sequence) {
    if (sequence == _noticeSequence) {
      _error = null;
      _notify();
    }
  }

  void _fail(String message) {
    _error = message;
    _noticeSequence++;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<bool> _sameOwner(Object? owner) async {
    if (owner == null) return false;
    try {
      final current = await _auth.captureParentAccessOwner();
      return !_disposed && current?.scope == owner;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _ticket(int revision, Object? owner) async {
    final same = await _sameOwner(owner);
    return same && !_disposed && _foreground && revision == _revision;
  }

  Future<bool> _loadOwner(int revision) async {
    final captured = await _auth.captureParentAccessOwner();
    if (_disposed || revision != _revision) return false;
    if (captured == null) {
      _owner = null;
      _pending = null;
      _access = null;
      _recovery = null;
      _loaded = false;
      _state = HostedFlowState.idle;
      _busy = false;
      return false;
    }
    final scope = captured.scope;
    if (_owner != null && _owner != scope) {
      _pending = null;
      _attempt = null;
      _access = null;
      _loaded = false;
      _recovery = null;
      _state = HostedFlowState.idle;
      _busy = false;
      _error = null;
    }
    _owner = scope;
    if (!_loaded) {
      final saved = await _store.read(captured.parentId);
      if (!await _ticket(revision, scope)) return false;
      _pending = saved?.parentId == captured.parentId ? saved : null;
      _loaded = true;
    }
    return true;
  }

  void _adoptRecovery(String parentId, Map<String, dynamic>? value) {
    if (value == null) return;
    if (_pending == null && value['payment_confirmed'] == true) return;
    try {
      final candidate = HostedPendingCheckout(
        parentId: parentId,
        operationId: hostedUuid(value['operation_id']),
        period: hostedPeriod(value['billing_period']),
        attemptId: hostedUuid(value['attempt_id']),
        returnState: hostedUuid(value['return_state']),
      );
      if (_pending?.attemptId != null &&
          _pending!.attemptId != candidate.attemptId) {
        return;
      }
      if (_pending?.returnState != null &&
          _pending!.returnState != candidate.returnState) {
        return;
      }
      if (_pending == null ||
          (_pending!.operationId == candidate.operationId &&
              _pending!.period == candidate.period)) {
        _pending = candidate;
      }
    } catch (_) {
      /* Malformed recovery never changes a frozen operation. */
    }
  }

  @override
  Future<bool> refresh() async {
    if (_disposed || !configuration.isHostedProductionEnabled || !_foreground) {
      return false;
    }
    final revision = ++_revision;
    _checking = true;
    _notify();
    try {
      if (!await _loadOwner(revision)) return false;
      final owner = _owner;
      final result = await _repository.access();
      if (!await _ticket(revision, owner)) return false;
      _access = result.access;
      _recovery = result.recovery;
      _adoptRecovery(result.access.parentId, result.recovery);
      if (_pending != null) await _store.write(_pending!);
      if (!await _ticket(revision, owner)) return false;
      if (_pending?.attemptId != null) await _checkOnce(owner, revision);
      return true;
    } catch (_) {
      if (_disposed || revision != _revision) return false;
      if (_pending != null) {
        _state = HostedFlowState.pending;
      } else {
        _fail('We could not check your subscription. Try again.');
      }
      return false;
    } finally {
      if (!_disposed && revision == _revision) {
        _checking = false;
        _notify();
      }
    }
  }

  @override
  Future<void> openCheckout({
    required SubscriptionBillingPeriod billingPeriod,
  }) async {
    if (!canOpen) return;
    final revision = ++_revision;
    _busy = true;
    _state = HostedFlowState.preparing;
    _error = null;
    _notify();
    try {
      if (!await _loadOwner(revision)) return;
      final owner = _owner;
      final country = await _country();
      if (!await _ticket(revision, owner)) return;
      if (country != 'USA') {
        _state = HostedFlowState.idle;
        _fail('Checkout is unavailable for this App Store region.');
        return;
      }
      final result = await _repository.access();
      if (!await _ticket(revision, owner)) return;
      _access = result.access;
      _recovery = result.recovery;
      _adoptRecovery(result.access.parentId, result.recovery);
      if (result.access.state != SandboxAccessState.unpaid ||
          !result.access.checkoutAvailable) {
        _state = HostedFlowState.idle;
        return;
      }
      if (_pending?.attemptId != null) {
        await _checkOnce(owner, revision);
        if (_state == HostedFlowState.paid) return;
        if (_state == HostedFlowState.failed) {
          final parent = _pending!.parentId;
          _pending = null;
          await _store.clear(parent);
          if (!await _ticket(revision, owner)) return;
        } else if (_attempt?.state != 'ready' &&
            _attempt?.state != 'reserved') {
          _state = HostedFlowState.pending;
          return;
        }
      }
      if (_pending != null && _pending!.period != billingPeriod) {
        _state = HostedFlowState.pending;
        _fail('Finish your existing payment before choosing another plan.');
        return;
      }
      final quote = await _repository.quote(billingPeriod);
      if (!await _ticket(revision, owner)) return;
      final operation = _pending?.operationId ?? hostedUuid(_operationId());
      HostedAuthorization? grant;
      final presenter = authorizeParent;
      if (presenter == null) {
        _state = HostedFlowState.idle;
        return;
      }
      final accepted = await presenter(quote, (password) async {
        if (!await _ticket(revision, owner)) {
          throw const AppException('The signed-in parent changed.');
        }
        // Persist before the first uncertain request; never keep the password.
        final previous = _pending;
        _pending = HostedPendingCheckout(
          parentId: quote.parentId,
          operationId: operation,
          period: billingPeriod,
          attemptId: previous?.attemptId,
          returnState: previous?.returnState,
        );
        await _store.write(_pending!);
        if (!await _ticket(revision, owner)) {
          throw const AppException('The signed-in parent changed.');
        }
        try {
          grant = await _repository.authorize(quote, operation, password);
        } on AppException catch (error) {
          if (!await _ticket(revision, owner)) rethrow;
          if (error.statusCode == 400 || error.statusCode == 403) {
            _pending = previous;
            if (previous == null) {
              await _store.clear(quote.parentId);
            } else {
              await _store.write(previous);
            }
          }
          if (!await _ticket(revision, owner)) rethrow;
          // The native authorization dialog owns this short error notice.
          rethrow;
        }
        if (!await _ticket(revision, owner)) {
          throw const AppException('The signed-in parent changed.');
        }
        if (previous?.attemptId != null &&
            previous!.attemptId != grant!.attemptId) {
          throw const FormatException('Payment attempt changed.');
        }
        _pending = HostedPendingCheckout(
          parentId: quote.parentId,
          operationId: operation,
          period: billingPeriod,
          attemptId: grant!.attemptId,
          returnState: previous?.returnState,
        );
        await _store.write(_pending!);
        if (!await _ticket(revision, owner)) {
          throw const AppException('The signed-in parent changed.');
        }
      });
      if (!await _ticket(revision, owner)) return;
      if (!accepted || grant == null) {
        _state = _pending == null
            ? HostedFlowState.idle
            : HostedFlowState.pending;
        return;
      }
      if (!await _ticket(revision, owner)) return;
      final attempt = await _repository.prepare(grant!);
      if (!await _ticket(revision, owner)) return;
      _attempt = attempt;
      _pending = HostedPendingCheckout(
        parentId: quote.parentId,
        operationId: operation,
        period: billingPeriod,
        attemptId: attempt.attemptId,
        returnState: attempt.returnState,
      );
      await _store.write(_pending!);
      if (!await _ticket(revision, owner)) return;
      if (attempt.isVerifiedPaid) {
        await _complete(attempt, owner, revision);
        return;
      }
      if (attempt.checkoutUri == null || attempt.state != 'ready') {
        _state = HostedFlowState.pending;
        return;
      }
      final launchCountry = await _country();
      if (!await _ticket(revision, owner)) return;
      if (launchCountry != 'USA') {
        _state = HostedFlowState.pending;
        _fail('Checkout is unavailable for this App Store region.');
        return;
      }
      if (!await _ticket(revision, owner)) return;
      _state = HostedFlowState.awaitingProvider;
      _notify();
      final opened = await _launcher(attempt.checkoutUri!);
      if (!await _ticket(revision, owner)) return;
      if (!opened) {
        _state = HostedFlowState.pending;
        _fail('The browser could not open. Your payment attempt is saved.');
      }
    } catch (_) {
      if (!_disposed && revision == _revision) {
        _state = _pending == null
            ? HostedFlowState.idle
            : HostedFlowState.pending;
        if (_pending == null) {
          _fail('We could not open secure payment. Try again.');
        }
      }
    } finally {
      if (!_disposed && revision == _revision) {
        _busy = false;
        _notify();
      }
    }
  }

  Future<void> _complete(
    HostedAttempt attempt,
    Object? owner,
    int revision,
  ) async {
    final canonical = await _repository.access();
    if (!await _ticket(revision, owner) ||
        canonical.access.state != SandboxAccessState.paid ||
        !attempt.isVerifiedPaid) {
      return;
    }
    final parent = canonical.access.parentId;
    await _store.clear(parent);
    if (!await _ticket(revision, owner) ||
        _pending?.attemptId != attempt.attemptId ||
        _pending?.operationId != attempt.operationId) {
      return;
    }
    _access = canonical.access;
    _recovery = canonical.recovery;
    _state = HostedFlowState.paid;
    _error = null;
    _pending = null;
    if (_completedAttempt != attempt.attemptId) {
      _completedAttempt = attempt.attemptId;
      _successSequence++;
    }
    _notify();
  }

  Future<void> _checkOnce(Object? owner, int revision) async {
    final pending = _pending;
    if (pending?.attemptId == null) return;
    if (!await _ticket(revision, owner)) return;
    final result = await _repository.reconcile(
      pending!.attemptId!,
      pending.operationId,
      pending.period,
      expectedParentId: pending.parentId,
      expectedScope: owner,
    );
    if (!await _ticket(revision, owner)) return;
    _attempt = result;
    if (result.returnState != null &&
        pending.returnState != null &&
        result.returnState != pending.returnState) {
      throw const FormatException('Payment return changed.');
    }
    if (result.isVerifiedPaid) {
      await _complete(result, owner, revision);
    } else if (result.isFailed) {
      _state = HostedFlowState.failed;
      _fail('Payment was not completed. Please try again.');
    } else {
      _state = HostedFlowState.pending;
    }
  }

  Future<bool> handleReturn(HostedCheckoutReturn link) async {
    final current = await _auth.captureParentAccessOwner();
    if (current?.scope == _owner &&
        _pending?.attemptId != null &&
        _pending?.returnState != null) {
      if (_pending!.attemptId != link.attemptId ||
          _pending!.returnState != link.state) {
        return false;
      }
      unawaited(verifyPending());
      return true;
    }
    final revision = ++_revision;
    if (!await _loadOwner(revision)) return false;
    if (_pending?.attemptId != null &&
        (_pending!.attemptId != link.attemptId ||
            (_pending!.returnState != null &&
                _pending!.returnState != link.state))) {
      return false;
    }
    if (_pending?.attemptId == null || _pending?.returnState == null) {
      final owner = _owner;
      final result = await _repository.access();
      if (!await _ticket(revision, owner)) return false;
      _adoptRecovery(result.access.parentId, result.recovery);
    }
    final pending = _pending;
    if (pending == null ||
        pending.attemptId != link.attemptId ||
        pending.returnState != link.state) {
      return false;
    }
    unawaited(verifyPending());
    return true;
  }

  Future<void> verifyPending() {
    final active = _verification;
    if (active != null) return active;
    final request = _verifyPending();
    _verification = request;
    return request.whenComplete(() {
      if (identical(_verification, request)) _verification = null;
    });
  }

  Future<void> _verifyPending() async {
    if (_disposed || !_foreground) return;
    await refresh();
    if (_pending?.attemptId == null || _state == HostedFlowState.paid) return;
    final owner = _owner;
    final revision = ++_revision;
    _checking = true;
    _state = HostedFlowState.checking;
    _notify();
    try {
      for (final delay in pollDelays) {
        if (delay > Duration.zero) await Future<void>.delayed(delay);
        if (!await _ticket(revision, owner)) {
          return;
        }
        try {
          await _checkOnce(owner, revision);
        } catch (_) {
          if (!await _ticket(revision, owner)) return;
          _state = HostedFlowState.pending;
        }
        if (_state == HostedFlowState.paid ||
            _state == HostedFlowState.failed) {
          return;
        }
      }
      if (!await _ticket(revision, owner)) return;
      _state = HostedFlowState.pending;
    } finally {
      if (await _ticket(revision, owner)) {
        _checking = false;
        _notify();
      }
    }
  }

  @override
  Future<void> openManagement() async {
    if (!canManage) return;
    final presenter = authorizeCancellation;
    if (presenter == null) return;
    final owner = _owner;
    final parent = _access!.parentId;
    final recovery = _recovery!;
    final revision = ++_revision;
    _busy = true;
    _notify();
    try {
      await presenter((password) async {
        if (!await _ticket(revision, owner)) {
          throw const AppException('The signed-in parent changed.');
        }
        final result = await _repository.cancel(
          hostedUuid(recovery['attempt_id']),
          hostedUuid(recovery['operation_id']),
          hostedPeriod(recovery['billing_period']),
          password,
          expectedParentId: parent,
          expectedScope: owner,
        );
        if (!await _ticket(revision, owner)) return;
        _attempt = result;
        _busy = false;
        await refresh();
      });
    } catch (_) {
      if (await _ticket(revision, owner)) {
        _fail('We could not update your subscription. Try again.');
      }
    } finally {
      if (await _ticket(revision, owner)) {
        _busy = false;
        _notify();
      }
    }
  }

  void background() {
    _foreground = false;
    _revision++;
    _checking = false;
    _busy = false;
    _verification = null;
  }

  Object? get ownerScope => _owner;

  Future<void> resume() async {
    _foreground = true;
    await verifyPending();
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    super.dispose();
  }
}

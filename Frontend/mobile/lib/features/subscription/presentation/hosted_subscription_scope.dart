import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/router.dart';
import '../../../core/network/feature_view_state_cache.dart';
import '../../auth/data/auth_repository.dart';
import '../../privacy/presentation/privacy_policy_screen.dart';
import '../data/hosted_checkout_pending_store.dart';
import '../data/hosted_subscription_controller.dart';
import '../data/hosted_subscription_repository.dart';
import '../data/parent_checkout_configuration.dart';
import '../domain/hosted_checkout_return.dart';
import 'checkout_error_notice.dart';

class HostedSubscriptionScope extends StatefulWidget {
  const HostedSubscriptionScope({
    required this.navigatorKey,
    required this.child,
    this.configuration = const SandboxCheckoutConfiguration(),
    this.controller,
    this.authRepository,
    this.returnLinks,
    this.initialReturn,
    super.key,
  });
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  final SandboxCheckoutConfiguration configuration;
  final HostedSubscriptionController? controller;
  final AuthRepository? authRepository;
  final Stream<String>? returnLinks;
  final Future<String?>? initialReturn;
  static AuthRepository? authOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_HostedScopeData>()
      ?.authRepository;
  static HostedSubscriptionController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_HostedScopeData>()
      ?.controller;
  @override
  State<HostedSubscriptionScope> createState() =>
      _HostedSubscriptionScopeState();
}

class _HostedScopeData extends InheritedWidget {
  const _HostedScopeData({
    required this.controller,
    required this.authRepository,
    required super.child,
  });
  final AuthRepository authRepository;
  final HostedSubscriptionController? controller;
  @override
  bool updateShouldNotify(_HostedScopeData old) => controller != old.controller;
}

class _HostedSubscriptionScopeState extends State<HostedSubscriptionScope>
    with WidgetsBindingObserver {
  HostedSubscriptionController? _controller;
  HttpHostedSubscriptionRepository? _repository;
  late final AuthRepository _auth;
  StreamSubscription<String>? _links;
  Timer? _returnTimer;
  Timer? _startupRetryTimer;
  int _notice = 0, _success = 0;
  String? _message;
  bool _returnVisible = false,
      _successVisible = false,
      _suppressAutoReturn = false;
  Object? _returnOwner;
  static const _methods = MethodChannel('kingdom_kids/checkout_returns');
  static const _events = EventChannel('kingdom_kids/checkout_return_events');

  @override
  void initState() {
    super.initState();
    _auth = widget.authRepository ?? AuthRepository();
    if (widget.configuration.isHostedProductionEnabled ||
        widget.controller != null) {
      _controller =
          widget.controller ??
          HostedSubscriptionController(
            configuration: widget.configuration,
            repository: _repository = HttpHostedSubscriptionRepository(
              configuration: widget.configuration,
              authRepository: _auth,
            ),
            pendingStore: SecureHostedCheckoutPendingStore(
              widget.configuration.apiBaseUrl,
            ),
            authRepository: _auth,
            launcher: (uri) =>
                launchUrl(uri, mode: LaunchMode.externalApplication),
          );
      _controller!.addListener(_changed);
      featureViewStateCache.addListener(_identityChanged);
      WidgetsBinding.instance.addObserver(this);
      final links =
          widget.returnLinks ??
          _events
              .receiveBroadcastStream()
              .where((value) => value is String)
              .cast<String>();
      _links = links.listen(
        (value) => unawaited(_receive(value)),
        onError: (_) {
          /* Return links do not establish access. */
        },
      );
      unawaited(_start());
    }
  }

  void _identityChanged() {
    unawaited(_controller?.refresh());
  }

  Future<void> _start() async {
    try {
      final owner = await _auth.captureParentAccessOwner();
      await _controller!.refresh();
      if (owner != null) {
        _scheduleStartupRetry(owner.parentId, owner.scope, 0);
      }
      final initial =
          await (widget.initialReturn ??
              _methods.invokeMethod<String>('initialLink'));
      if (initial != null && mounted) await _receive(initial);
    } catch (_) {
      /* Resume and authenticated status remain available. */
    }
  }

  bool get _startupNeedsRetry {
    final controller = _controller;
    return controller != null &&
        !controller.canBrowse &&
        !controller.hasConfirmedUnpaid &&
        !controller.busy &&
        controller.pending == null &&
        controller.state == HostedFlowState.idle &&
        controller.isAuthorizationCurrent(controller.authorizationRevision);
  }

  void _scheduleStartupRetry(String parentId, Object scope, int index) {
    const delays = [Duration(seconds: 1), Duration(seconds: 3)];
    if (!mounted || index >= delays.length || !_startupNeedsRetry) return;
    _startupRetryTimer?.cancel();
    _startupRetryTimer = Timer(delays[index], () async {
      _startupRetryTimer = null;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (!mounted ||
          (lifecycle != null && lifecycle != AppLifecycleState.resumed) ||
          !_startupNeedsRetry) {
        return;
      }
      try {
        final current = await _auth.captureParentAccessOwner();
        if (!mounted ||
            current?.parentId != parentId ||
            current?.scope != scope ||
            _controller?.ownerScope != scope ||
            !_startupNeedsRetry) {
          return;
        }
        await _controller!.refresh();
        if (mounted) _scheduleStartupRetry(parentId, scope, index + 1);
      } catch (_) {
        // Recovery never changes identity or manufactures access proof.
      }
    });
  }

  Future<void> _receive(String value) async {
    final link = HostedCheckoutReturn.parse(value);
    if (link == null || _controller == null) return;
    try {
      if (await _controller!.handleReturn(link) &&
          mounted &&
          !_suppressAutoReturn) {
        setState(() {
          _returnVisible = true;
          _returnOwner = _controller!.ownerScope;
        });
      }
    } catch (_) {
      /* A spoofed or old return must not change another attempt. */
    }
  }

  void _changed() {
    final controller = _controller!;
    if (!mounted) return;
    if (controller.access?.complimentaryAccess == true) {
      _returnVisible = false;
      _successVisible = false;
      _returnTimer?.cancel();
    }
    if (_returnOwner != null &&
        (_returnOwner != controller.ownerScope ||
            !controller.hasCurrentOwner)) {
      _returnTimer?.cancel();
      _returnVisible = false;
      _successVisible = false;
      _message = null;
      _returnOwner = null;
    }
    if (controller.state == HostedFlowState.preparing) {
      _suppressAutoReturn = false;
    }
    if (controller.noticeSequence != _notice) {
      _notice = controller.noticeSequence;
      _message = controller.error;
    }
    if (controller.error == null) _message = null;
    if (controller.successSequence != _success) {
      _success = controller.successSequence;
      unawaited(
        _showSuccess(controller.ownerScope, controller.successSequence),
      );
    }
    setState(() {});
  }

  Future<bool> _validSuccess(Object? owner, int sequence) async {
    try {
      final current = await _auth.captureParentAccessOwner();
      return mounted &&
          owner != null &&
          current?.scope == owner &&
          !_suppressAutoReturn &&
          _controller?.ownerScope == owner &&
          _controller?.successSequence == sequence &&
          _controller?.state == HostedFlowState.paid &&
          _controller?.canBrowse == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _showSuccess(Object? owner, int sequence) async {
    if (!await _validSuccess(owner, sequence)) return;
    setState(() {
      _returnVisible = true;
      _successVisible = true;
      _returnOwner = owner;
    });
    _returnTimer?.cancel();
    _returnTimer = Timer(const Duration(seconds: 2), () async {
      if (!await _validSuccess(owner, sequence)) {
        return;
      }
      final session = await _auth.restoreSession();
      final child = await _auth.currentKid();
      if (!await _validSuccess(owner, sequence)) return;
      final route = session == null
          ? AppRoutes.login
          : child != null
          ? AppRoutes.home
          : session.profiles.isEmpty
          ? AppRoutes.kidProfileSetup
          : AppRoutes.profilePicker;
      setState(() {
        _returnVisible = false;
        _successVisible = false;
      });
      widget.navigatorKey.currentState?.pushNamedAndRemoveUntil(
        route,
        (_) => false,
      );
    });
  }

  void _leaveReturn(String route) {
    _suppressAutoReturn = true;
    _returnTimer?.cancel();
    setState(() => _returnVisible = false);
    widget.navigatorKey.currentState?.pushNamed(route);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_controller?.resume());
    } else {
      _startupRetryTimer?.cancel();
      _startupRetryTimer = null;
      _controller?.background();
    }
  }

  @override
  void dispose() {
    _startupRetryTimer?.cancel();
    _returnTimer?.cancel();
    unawaited(_links?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    _controller?.removeListener(_changed);
    featureViewStateCache.removeListener(_identityChanged);
    if (widget.controller == null) _controller?.dispose();
    _repository?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _HostedScopeData(
    controller: _controller,
    authRepository: _auth,
    child: Stack(
      children: [
        widget.child,
        if (_returnVisible && _controller != null)
          Positioned.fill(
            child: Scaffold(
              key: const Key('hosted-return-status'),
              appBar: AppBar(
                title: const Text('Subscription'),
                automaticallyImplyLeading: false,
              ),
              body: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_successVisible)
                          const Icon(
                            Icons.check_circle_rounded,
                            size: 68,
                            color: Color(0xFF237B55),
                          )
                        else if (_controller!.checking)
                          const CircularProgressIndicator(),
                        const SizedBox(height: 20),
                        Text(
                          _successVisible
                              ? 'Subscription active'
                              : _controller!.persistentStatus ??
                                    'Your payment is still being checked.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        if (!_successVisible) ...[
                          const SizedBox(height: 20),
                          TextButton(
                            onPressed: _controller!.checking
                                ? null
                                : () => _controller!.verifyPending(),
                            child: const Text('Check subscription'),
                          ),
                          TextButton(
                            onPressed: () =>
                                _leaveReturn(AppRoutes.subscription),
                            child: const Text('Subscription plans'),
                          ),
                        ],
                        TextButton(
                          onPressed: () => _leaveReturn(
                            _controller!.canBrowse
                                ? AppRoutes.parentalControls
                                : AppRoutes.subscriptionRequired,
                          ),
                          child: Text(
                            _controller!.canBrowse
                                ? 'Parent account settings'
                                : 'Account options',
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            _returnTimer?.cancel();
                            _suppressAutoReturn = true;
                            setState(() => _returnVisible = false);
                            widget.navigatorKey.currentState?.push(
                              MaterialPageRoute<void>(
                                builder: (_) => const PrivacyPolicyScreen(),
                              ),
                            );
                          },
                          child: const Text('Privacy Policy'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (_message != null && _controller != null)
          Positioned.fill(
            child: CheckoutErrorNotice(
              key: ValueKey(_notice),
              message: _message!,
              onDismiss: () => _controller!.dismissError(_notice),
            ),
          ),
      ],
    ),
  );
}

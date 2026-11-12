import 'dart:async';
import 'package:flutter/material.dart';
import '../../../app/router.dart';
import '../../../core/errors/app_exception.dart';
import '../../auth/data/auth_repository.dart';
import '../../parental_controls/data/parent_settings_store.dart';
import '../../parental_controls/presentation/parental_controls_screen.dart'
    show showParentAccountDeletionDialog;
import '../../streak/data/streak_reminder_service.dart';
import 'hosted_subscription_scope.dart';
import 'checkout_error_notice.dart';

/// Navigation metadata only. It never authorizes access or a purchase.
enum HostedPlansBackStack { prepared }

void openHostedSubscriptionPlans(BuildContext context) {
  final navigator = Navigator.of(context);
  navigator.pushNamedAndRemoveUntil(
    AppRoutes.subscriptionRequired,
    (_) => false,
  );
  navigator.pushNamed(
    AppRoutes.subscription,
    arguments: HostedPlansBackStack.prepared,
  );
}

class SubscriptionAccessScreen extends StatefulWidget {
  const SubscriptionAccessScreen({super.key});
  @override
  State<SubscriptionAccessScreen> createState() =>
      _SubscriptionAccessScreenState();
}

class _SubscriptionAccessScreenState extends State<SubscriptionAccessScreen>
    with WidgetsBindingObserver {
  final _pages = PageController();
  Timer? _rotation;
  bool _artLoaded = false;
  String? _message;
  int _notice = 0;
  bool _busy = false, _resuming = false, _foreground = true;
  // The release artwork is supplied with the reviewed gate assets.
  static const artwork = [
    'assets/images/subscription/access-stories-v1.png',
    'assets/images/subscription/access-games-v1.png',
    'assets/images/subscription/access-together-v1.png',
  ];
  static const messages = [
    'Wonderful stories await',
    'Play, discover, and grow',
    'Every adventure, one subscription',
  ];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _rotation = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted ||
          !_foreground ||
          !_pages.hasClients ||
          !(ModalRoute.of(context)?.isCurrent ?? true) ||
          MediaQuery.disableAnimationsOf(context)) {
        return;
      }
      final next = ((_pages.page ?? 0).round() + 1) % 3;
      if (next == 0) {
        _pages.jumpToPage(0);
      } else {
        _pages.animateToPage(
          next,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeInOut,
        );
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_artLoaded) {
      _artLoaded = true;
      for (final asset in artwork) {
        unawaited(
          precacheImage(
            AssetImage(asset),
            context,
            onError: (_, _) {
              /* A bundled-art error never blocks account controls. */
            },
          ),
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    _rotation?.cancel();
    _pages.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  AuthRepository get _auth =>
      HostedSubscriptionScope.authOf(context) ?? AuthRepository();
  Future<void> _resumePaid() async {
    if (_resuming || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
    _resuming = true;
    final controller = HostedSubscriptionScope.maybeOf(context);
    final owner = controller?.ownerScope;
    try {
      final session = await _auth.restoreSession();
      final child = await _auth.currentKid();
      final current = await _auth.captureParentAccessOwner();
      if (!mounted ||
          !(ModalRoute.of(context)?.isCurrent ?? true) ||
          controller?.canBrowse != true ||
          current?.scope != owner ||
          controller?.ownerScope != owner ||
          session == null) {
        return;
      }
      Navigator.of(context).pushNamedAndRemoveUntil(
        child != null
            ? AppRoutes.home
            : session.hasProfiles
            ? AppRoutes.profilePicker
            : AppRoutes.kidProfileSetup,
        (_) => false,
        arguments: session.profiles,
      );
    } catch (_) {
      // A storage/network issue never creates an unpaid or paid decision.
    } finally {
      _resuming = false;
    }
  }

  void _error(String message) {
    if (mounted) {
      setState(() {
        _message = message;
        _notice++;
      });
    }
  }

  Future<void> _accountAction({required bool delete}) async {
    if (_busy) return;
    final auth = _auth;
    Object? owner;
    setState(() => _busy = true);
    try {
      final origin = await auth.captureParentAccessOwner();
      if (!mounted) return;
      if (origin == null) {
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
        return;
      }
      owner = origin.scope;
      String? password;
      if (delete) {
        password = await showParentAccountDeletionDialog(context);
        if (password == null || !mounted) return;
      }
      if ((await auth.captureParentAccessOwner())?.scope != owner || !mounted) {
        return;
      }
      if (delete) {
        await auth.deleteAccount(password: password!);
      } else {
        try {
          await auth.logout();
        } catch (_) {
          /* Check local exit below. */
        }
      }
      final current = await auth.captureParentAccessOwner();
      if (current != null) {
        if (current.scope == owner) {
          _error('We could not sign out right now. Try again.');
        }
        return; // A newer parent's session and preferences remain untouched.
      }
      if (delete) {
        try {
          await SecureParentSettingsStore().purgeAll();
        } catch (_) {
          /* Continue local cleanup. */
        }
      }
      try {
        await DeviceStreakReminderService().disable();
      } catch (_) {
        /* Account exit remains available. */
      }
      if (mounted && await auth.restoreSession() == null) {
        if (!mounted) return;
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
      }
    } on AppException catch (error) {
      if (owner == null ||
          (await auth.captureParentAccessOwner())?.scope == owner) {
        _error(error.userMessage);
      }
    } catch (_) {
      _error('We could not complete that account request. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = HostedSubscriptionScope.maybeOf(context);
    return AnimatedBuilder(
      animation: controller ?? const AlwaysStoppedAnimation(0),
      builder: (context, _) {
        final unpaid = controller?.hasConfirmedUnpaid == true;
        if (controller?.canBrowse == true) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_resumePaid());
          });
        }
        return PopScope(
          canPop: false,
          child: Scaffold(
            key: const Key('hosted-access-required'),
            backgroundColor: const Color(0xFFF5F6FA),
            body: Stack(
              fit: StackFit.expand,
              children: [
                SafeArea(
                  child: Column(
                    children: [
                      Expanded(
                        child: unpaid
                            ? PageView.builder(
                                key: const Key(
                                  'subscription-required-carousel',
                                ),
                                controller: _pages,
                                itemCount: 3,
                                itemBuilder: (context, index) => Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Image.asset(
                                      artwork[index % 3],
                                      fit: BoxFit.cover,
                                      gaplessPlayback: true,
                                      errorBuilder: (_, _, _) =>
                                          const ColoredBox(
                                            color: Color(0xFFE8EEFF),
                                          ),
                                    ),
                                    const DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            Color(0x00FFFFFF),
                                            Color(0xF5FFFFFF),
                                          ],
                                          stops: [.25, .85],
                                        ),
                                      ),
                                    ),
                                    Align(
                                      alignment: Alignment.bottomCenter,
                                      child: SingleChildScrollView(
                                        child: Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                            24,
                                            30,
                                            24,
                                            24,
                                          ),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                messages[index % 3],
                                                style: const TextStyle(
                                                  fontSize: 29,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                                textAlign: TextAlign.center,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : Center(
                                child: SingleChildScrollView(
                                  child: Padding(
                                    padding: const EdgeInsets.all(28),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (controller?.checking == true ||
                                            controller?.canBrowse == true)
                                          const CircularProgressIndicator(),
                                        const SizedBox(height: 20),
                                        Text(
                                          controller?.canBrowse == true
                                              ? 'Opening your library…'
                                              : controller?.checking == true
                                              ? 'Checking your subscription…'
                                              : 'We could not verify your subscription.',
                                          key: const Key(
                                            'hosted-access-unknown',
                                          ),
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            fontSize: 25,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        TextButton(
                                          onPressed: controller?.busy == false
                                              ? controller?.refresh
                                              : null,
                                          child: const Text(
                                            'Check subscription',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            key: const Key('subscription-required-view-plans'),
                            style: FilledButton.styleFrom(
                              shape: const StadiumBorder(),
                              minimumSize: const Size(48, 52),
                              textStyle: const TextStyle(
                                fontFamily: 'Avenir Next',
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            onPressed: () =>
                                openHostedSubscriptionPlans(context),
                            child: const Text(
                              'View subscription plans',
                              style: TextStyle(
                                fontFamily: 'Avenir Next',
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (controller?.hasCurrentOwner == true &&
                          controller?.access?.managementAvailable == true)
                        TextButton(
                          onPressed: () => openHostedSubscriptionPlans(context),
                          child: const Text('Manage subscription'),
                        ),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(context).height * .28,
                        ),
                        child: SingleChildScrollView(
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            children: [
                              TextButton(
                                key: const Key(
                                  'subscription-required-sign-out',
                                ),
                                onPressed: _busy
                                    ? null
                                    : () => _accountAction(delete: false),
                                child: const Text('Sign out'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.of(
                                  context,
                                ).pushNamed(AppRoutes.privacy),
                                child: const Text('Privacy'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.of(
                                  context,
                                ).pushNamed(AppRoutes.passwordReset),
                                child: const Text('Password help'),
                              ),
                              TextButton(
                                key: const Key(
                                  'subscription-required-delete-account',
                                ),
                                onPressed: _busy
                                    ? null
                                    : () => _accountAction(delete: true),
                                child: const Text('Delete account'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_message != null)
                  CheckoutErrorNotice(
                    key: ValueKey(_notice),
                    message: _message!,
                    onDismiss: () {
                      if (mounted) setState(() => _message = null);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

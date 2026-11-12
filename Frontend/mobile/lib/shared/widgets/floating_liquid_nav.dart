import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/router.dart';
import '../../features/auth/domain/kid_profile.dart';
import '../../features/auth/presentation/kid_profile_avatar.dart';
import 'liquid_glass.dart';
import 'liquid_navigation_controller.dart';
import 'native_liquid_navigation.dart';

/// Existing screens publish their loaded child to the persistent app host.
/// Standalone screens retain a working navigation surface for isolated use.
class FloatingLiquidNav extends StatelessWidget {
  const FloatingLiquidNav({
    required this.selectedRoute,
    this.activeProfile,
    super.key,
  });

  final String selectedRoute;
  final KidProfile? activeProfile;

  @override
  Widget build(BuildContext context) {
    final controller = LiquidNavigationScope.maybeOf(context);
    if (controller != null) {
      controller.publishProfile(selectedRoute, activeProfile);
      return const SizedBox.shrink();
    }
    return LiquidNavigationSurface(
      selectedRoute: selectedRoute,
      activeProfile: activeProfile,
      onSelect: (route) => _openRoute(context, route, selectedRoute),
    );
  }
}

class LiquidNavigationSurface extends StatelessWidget {
  const LiquidNavigationSurface({
    required this.selectedRoute,
    required this.activeProfile,
    required this.onSelect,
    this.currentRoute,
    super.key,
  });

  final String selectedRoute;
  final KidProfile? activeProfile;
  final bool Function(String route) onSelect;
  final String Function()? currentRoute;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final reducedMotion = media.disableAnimations || media.accessibleNavigation;
    final nativeIOS = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, media.padding.bottom + 9),
      child: SizedBox(
        // Leave room for the system tab bar's intrinsic height and shadow.
        height: nativeIOS ? 83 : 69,
        child: nativeIOS
            ? NativeLiquidNavigation(
                selectedRoute: selectedRoute,
                activeProfile: activeProfile,
                reduceMotion: reducedMotion,
                onSelect: onSelect,
                currentRoute: currentRoute,
              )
            : _SlidingCapsuleNavigation(
                selectedRoute: selectedRoute,
                activeProfile: activeProfile,
                reduceMotion: reducedMotion,
                onSelect: onSelect,
              ),
      ),
    );
  }
}

/// Cross-platform approximation. Apple's system material is supplied by the
/// native iOS view above, not by this Flutter BackdropFilter implementation.
class _SlidingCapsuleNavigation extends StatefulWidget {
  const _SlidingCapsuleNavigation({
    required this.selectedRoute,
    required this.activeProfile,
    required this.reduceMotion,
    required this.onSelect,
  });

  final String selectedRoute;
  final KidProfile? activeProfile;
  final bool reduceMotion;
  final bool Function(String route) onSelect;

  @override
  State<_SlidingCapsuleNavigation> createState() =>
      _SlidingCapsuleNavigationState();
}

class _SlidingCapsuleNavigationState extends State<_SlidingCapsuleNavigation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _position;
  double _target = 0;

  @override
  void initState() {
    super.initState();
    final initial = LiquidNavigationController.mainRoutes.indexOf(
      widget.selectedRoute,
    );
    _target = initial < 0 ? 0 : initial.toDouble();
    _position = AnimationController(
      vsync: this,
      lowerBound: 0,
      upperBound: 2,
      value: _target,
      duration: const Duration(milliseconds: 300),
    );
  }

  @override
  void didUpdateWidget(_SlidingCapsuleNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    final index = LiquidNavigationController.mainRoutes.indexOf(
      widget.selectedRoute,
    );
    if (index >= 0) _target = index.toDouble();
    if (widget.reduceMotion) {
      _position.stop();
      _position.value = _target;
    } else if (_position.value != _target) {
      unawaited(
        _position.animateTo(
          _target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profileSelected = widget.selectedRoute == AppRoutes.profile;
    return Material(
      type: MaterialType.transparency,
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              key: const Key('bottom-nav-main-dock'),
              height: 69,
              child: _CapsuleGlass(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final slot = (constraints.maxWidth - 12) / 3;
                    return Stack(
                      children: [
                        AnimatedBuilder(
                          animation: _position,
                          builder: (_, _) => Positioned(
                            left: 6 + slot * _position.value,
                            top: 6,
                            width: slot,
                            height: 57,
                            child: Opacity(
                              opacity: profileSelected ? 0 : 1,
                              child: DecoratedBox(
                                key: const Key('bottom-nav-sliding-capsule'),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(28.5),
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.white.withValues(alpha: 0.65),
                                      Colors.white.withValues(alpha: 0.20),
                                    ],
                                  ),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.88),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(6),
                          child: Row(
                            children: [
                              _CapsuleNavItem(
                                icon: Icons.home_rounded,
                                label: 'Home',
                                route: AppRoutes.home,
                                selectedRoute: widget.selectedRoute,
                                onSelect: widget.onSelect,
                              ),
                              _CapsuleNavItem(
                                icon: Icons.auto_stories_rounded,
                                label: 'Stories',
                                route: AppRoutes.stories,
                                selectedRoute: widget.selectedRoute,
                                onSelect: widget.onSelect,
                              ),
                              _CapsuleNavItem(
                                icon: Icons.extension_rounded,
                                label: 'Games',
                                route: AppRoutes.games,
                                selectedRoute: widget.selectedRoute,
                                onSelect: widget.onSelect,
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Semantics(
            button: true,
            selected: profileSelected,
            label: 'Profile',
            child: GestureDetector(
              key: const Key('bottom-nav-profile'),
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onSelect(AppRoutes.profile),
              child: SizedBox.square(
                dimension: 69,
                child: _CapsuleGlass(
                  child: Center(
                    child: widget.activeProfile == null
                        ? const Icon(
                            Icons.person_rounded,
                            color: Color(0xFF263047),
                            size: 31,
                          )
                        : KidProfileAvatar(
                            profile: widget.activeProfile!,
                            size: 54,
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CapsuleNavItem extends StatelessWidget {
  const _CapsuleNavItem({
    required this.icon,
    required this.label,
    required this.route,
    required this.selectedRoute,
    required this.onSelect,
  });

  final IconData icon;
  final String label;
  final String route;
  final String selectedRoute;
  final bool Function(String route) onSelect;

  @override
  Widget build(BuildContext context) {
    final selected = route == selectedRoute;
    final color = selected ? const Color(0xFF1556CF) : const Color(0xFF263047);
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: GestureDetector(
          key: ValueKey('bottom-nav-item-$route'),
          behavior: HitTestBehavior.opaque,
          onTap: () => onSelect(route),
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: color, size: 23),
                  const SizedBox(height: 2),
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        maxLines: 1,
                        style: TextStyle(
                          color: color,
                          fontSize: 9.5,
                          height: 1,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CapsuleGlass extends StatelessWidget {
  const _CapsuleGlass({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(34.5),
      boxShadow: [
        BoxShadow(
          color: const Color(0xFF263047).withValues(alpha: 0.1),
          blurRadius: 20,
          offset: const Offset(0, 7),
        ),
      ],
    ),
    child: LiquidGlass(
      borderRadius: 34.5,
      blur: 20,
      opacity: 0.16,
      borderOpacity: 0.72,
      child: child,
    ),
  );
}

bool _openRoute(BuildContext context, String route, String selectedRoute) {
  if (route == selectedRoute ||
      !LiquidNavigationController.visibleRoutes.contains(route)) {
    return false;
  }
  unawaited(
    Navigator.of(context).pushReplacementNamed<void, void>(
      route,
      arguments: TabRouteTransition(fromRoute: selectedRoute),
    ),
  );
  return true;
}

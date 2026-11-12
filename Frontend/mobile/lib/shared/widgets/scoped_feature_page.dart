import 'package:flutter/material.dart';

import '../../features/auth/data/auth_repository.dart';
import '../../core/network/feature_view_state_cache.dart';

/// Carries same-identity display seeds and scroll/search/filter preferences.
/// Screen repositories still perform their normal freshness checks.
class FeatureViewMemory extends InheritedWidget {
  const FeatureViewMemory({
    required this.values,
    required super.child,
    this.prevalidatedScope,
    super.key,
  });
  final Map<String, Object?> values;
  final Object? prevalidatedScope;
  static Map<String, Object?>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FeatureViewMemory>()?.values;
  static Object? scopeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<FeatureViewMemory>()
      ?.prevalidatedScope;
  @override
  bool updateShouldNotify(FeatureViewMemory oldWidget) =>
      values != oldWidget.values ||
      prevalidatedScope != oldWidget.prevalidatedScope;
}

class ScopedFeaturePage extends StatefulWidget {
  const ScopedFeaturePage({
    required this.route,
    required this.child,
    this.preparation,
    this.identityBound = false,
    this.authRepository,
    super.key,
  });
  final String route;
  final Widget child;
  final FeaturePagePreparation? preparation;
  final bool identityBound;
  final AuthRepository? authRepository;

  /// Runs while the outgoing tab is still painted. A repeat visit can then
  /// build its scoped display seed synchronously, without an empty route frame.
  static Future<FeaturePagePreparation> prepare(
    String route, {
    AuthRepository? authRepository,
  }) async {
    final auth = authRepository ?? AuthRepository();
    while (true) {
      final revision = featureViewStateCache.identityRevision;
      final scope = await auth.featureCacheScope();
      if (revision == featureViewStateCache.identityRevision) {
        return featureViewStateCache.prepare(scope, route);
      }
    }
  }

  @override
  State<ScopedFeaturePage> createState() => _ScopedFeaturePageState();
}

class _ScopedFeaturePageState extends State<ScopedFeaturePage> {
  FeaturePagePreparation? _prepared;
  Future<FeaturePagePreparation>? _pending;
  bool _identityRevoked = false;

  @override
  void initState() {
    super.initState();
    featureViewStateCache.addListener(_identityChanged);
    _prepared =
        widget.preparation ??
        featureViewStateCache.knownPreparation(widget.route);
    if (_prepared?.isCurrent != true) _pending = _resolve();
  }

  void _identityChanged() {
    if (!mounted) return;
    setState(() {
      _identityRevoked = widget.identityBound;
      _prepared = null;
      _pending = _identityRevoked ? null : _resolve();
    });
  }

  Future<FeaturePagePreparation> _resolve() async {
    try {
      return await ScopedFeaturePage.prepare(
        widget.route,
        authRepository: widget.authRepository,
      );
    } catch (_) {
      return featureViewStateCache.prepare(null, widget.route);
    }
  }

  @override
  void dispose() {
    featureViewStateCache.removeListener(_identityChanged);
    super.dispose();
  }

  Widget _page(FeaturePagePreparation prepared) => FeatureViewMemory(
    values: prepared.memory,
    prevalidatedScope: prepared.scope,
    child: KeyedSubtree(
      key: ValueKey((prepared.scope, prepared.identityRevision)),
      child: widget.child,
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (_identityRevoked) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('This profile changed. Return to the library.'),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Back'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_prepared?.isCurrent == true) return _page(_prepared!);
    return FutureBuilder<FeaturePagePreparation>(
      future: _pending,
      builder: (context, snapshot) =>
          snapshot.hasData && snapshot.data!.isCurrent
          ? _page(snapshot.data!)
          : ColoredBox(color: Theme.of(context).scaffoldBackgroundColor),
    );
  }
}

/// Restores after the loaded content has laid out, rather than allowing the
/// short loading placeholder to clamp a saved deep offset to zero.
class FeatureScrollController extends ScrollController {
  FeatureScrollController(
    Map<String, Object?>? memory, {
    bool contentReady = false,
  }) : _memory = memory,
       _savedOffset = memory?['scroll'] as double? ?? 0,
       _restored = contentReady,
       super(
         initialScrollOffset: contentReady
             ? (memory?['scroll'] as double? ?? 0)
             : 0,
       ) {
    addListener(() {
      if (hasClients) _memory?['scroll'] = offset;
    });
  }
  final Map<String, Object?>? _memory;
  final double _savedOffset;
  double get rememberedOffset =>
      hasClients ? offset : _memory?['scroll'] as double? ?? _savedOffset;
  bool _restored;
  bool _disposed = false;

  void restoreAfterLoad() {
    if (_restored || _disposed) return;
    _restored = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !hasClients) return;
      jumpTo(_savedOffset.clamp(0, position.maxScrollExtent));
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

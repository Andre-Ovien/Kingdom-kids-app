import 'package:flutter/material.dart';

import '../../features/auth/data/auth_repository.dart';

/// Keeps only scroll/search/filter preferences across replaceable tab routes.
/// Read models live in the separately bounded, expiring feature cache.
class FeatureViewMemory extends InheritedWidget {
  const FeatureViewMemory({
    required this.values,
    required super.child,
    super.key,
  });
  final Map<String, Object?> values;
  static Map<String, Object?>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FeatureViewMemory>()?.values;
  @override
  bool updateShouldNotify(FeatureViewMemory oldWidget) =>
      values != oldWidget.values;
}

class ScopedFeaturePage extends StatefulWidget {
  const ScopedFeaturePage({
    required this.route,
    required this.child,
    super.key,
  });
  final String route;
  final Widget child;
  @override
  State<ScopedFeaturePage> createState() => _ScopedFeaturePageState();
}

class _ScopedFeaturePageState extends State<ScopedFeaturePage> {
  static final _memories = <Object, Map<String, Object?>>{};
  late final Future<Map<String, Object?>> _memory = _resolve();

  Future<Map<String, Object?>> _resolve() async {
    try {
      final scope = await AuthRepository().featureCacheScope();
      if (scope == null) return {};
      final key = (scope, widget.route);
      final memory = _memories.remove(key) ?? <String, Object?>{};
      _memories[key] = memory;
      while (_memories.length > 12) {
        _memories.remove(_memories.keys.first);
      }
      return memory;
    } catch (_) {
      return {};
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, Object?>>(
    future: _memory,
    builder: (context, snapshot) => snapshot.hasData
        ? FeatureViewMemory(values: snapshot.data!, child: widget.child)
        : ColoredBox(color: Theme.of(context).scaffoldBackgroundColor),
  );
}

/// Restores after the loaded content has laid out, rather than allowing the
/// short loading placeholder to clamp a saved deep offset to zero.
class FeatureScrollController extends ScrollController {
  FeatureScrollController(Map<String, Object?>? memory)
    : _memory = memory,
      _savedOffset = memory?['scroll'] as double? ?? 0 {
    addListener(() {
      if (hasClients) _memory?['scroll'] = offset;
    });
  }
  final Map<String, Object?>? _memory;
  final double _savedOffset;
  double get rememberedOffset =>
      hasClients ? offset : _memory?['scroll'] as double? ?? _savedOffset;
  bool _restored = false;
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

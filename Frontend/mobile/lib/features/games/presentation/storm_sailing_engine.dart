import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../data/sailing_motion_input.dart';
import '../domain/mini_game.dart';
import 'storm_sailing_model.dart';
import 'storm_sailing_renderer.dart';

class StormSailingEngine extends StatefulWidget {
  const StormSailingEngine({
    required this.level,
    required this.onComplete,
    required this.onExit,
    this.paused = false,
    this.motionInput,
    super.key,
  });
  final GameLevel level;
  final void Function(Map<String, dynamic>) onComplete;
  final VoidCallback onExit;
  final bool paused;
  final SailingMotionInput? motionInput;

  @override
  State<StormSailingEngine> createState() => _StormSailingEngineState();
}

class _StormSailingEngineState extends State<StormSailingEngine>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late SailingRun _run;
  late final Ticker _ticker;
  late final SailingMotionInput _motion;
  StreamSubscription<double>? _motionSubscription;
  final ValueNotifier<int> _frames = ValueNotifier(0);
  final ValueNotifier<int> _hud = ValueNotifier(0);
  Duration? _lastFrame;
  double _sceneTime = 0;
  double _arrival = 0;
  double _lastHudAt = -1;
  double _rawTilt = 0;
  double _neutralTilt = 0;
  double _tilt = 0;
  double _touch = 0;
  double _wheelOrigin = 0;
  bool _touching = false;
  bool _useTilt = true;
  bool _sensorAvailable = false;
  bool _active = true;
  bool _submitted = false;

  bool get _paused => widget.paused || !_active;

  @override
  void initState() {
    super.initState();
    _run = SailingRun(SailingCourse.fromLevel(widget.level));
    _motion = widget.motionInput ?? NativeSailingMotionInput();
    _active =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_tick)..start();
    if (!_paused) _listenForTilt();
  }

  void _listenForTilt() {
    if (_motionSubscription != null || _paused) return;
    _motionSubscription = _motion.tilt.listen(
      (gravity) {
        if (!mounted || _paused) return;
        _rawTilt = gravity;
        if (!_sensorAvailable) {
          _neutralTilt = gravity;
          setState(() => _sensorAvailable = true);
        }
        final offset = gravity - _neutralTilt;
        final target = offset.abs() < .035
            ? 0.0
            : (offset / .32).clamp(-1.0, 1.0);
        _tilt += (target - _tilt) * .22;
      },
      onError: (Object _) {
        if (!mounted) return;
        _stopTilt();
        setState(() {
          _sensorAvailable = false;
          _useTilt = false;
          _tilt = 0;
        });
      },
      onDone: () {
        if (!mounted) return;
        _stopTilt();
        setState(() {
          _sensorAvailable = false;
          _useTilt = false;
        });
      },
    );
  }

  void _stopTilt() {
    final subscription = _motionSubscription;
    _motionSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    _tilt = _touch = 0;
    _touching = false;
  }

  @override
  void didUpdateWidget(covariant StormSailingEngine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.level.id != oldWidget.level.id) {
      _run = SailingRun(SailingCourse.fromLevel(widget.level));
      _submitted = false;
      _arrival = 0;
      _touch = _tilt = 0;
      _hud.value += 1;
    }
    if (widget.paused != oldWidget.paused) {
      _lastFrame = null;
      if (_paused) {
        _stopTilt();
      } else {
        _neutralTilt = _rawTilt;
        _listenForTilt();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    _lastFrame = null;
    if (_paused) {
      _stopTilt();
    } else {
      _neutralTilt = _rawTilt;
      _listenForTilt();
    }
  }

  void _tick(Duration stamp) {
    final previous = _lastFrame;
    _lastFrame = stamp;
    if (_paused || previous == null) return;
    final delta = ((stamp - previous).inMicroseconds / 1000000).clamp(0.0, .1);
    _sceneTime += delta;
    final oldHits = _run.hits;
    final wasWrecked = _run.wrecked;
    _run.advance(delta, _touching || !_useTilt ? _touch : _tilt);
    if (_run.hits != oldHits) {
      unawaited(HapticFeedback.mediumImpact());
    }
    if (_run.wrecked && !wasWrecked) {
      _stopTilt();
      setState(() {});
    }
    if (_run.finished && !_submitted) {
      _arrival += delta;
      if (_arrival >= 1.25) {
        _submitted = true;
        _stopTilt();
        unawaited(HapticFeedback.heavyImpact());
        widget.onComplete(_run.result());
      }
    }
    if (_sceneTime - _lastHudAt >= .1) {
      _lastHudAt = _sceneTime;
      _hud.value += 1;
    }
    _frames.value += 1;
  }

  void _start() {
    if (_paused) return;
    setState(() {
      _run.start();
      _submitted = false;
      _arrival = 0;
      _touch = _tilt = 0;
      _neutralTilt = _rawTilt;
    });
    _listenForTilt();
    _hud.value += 1;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _stopTilt();
    _frames.dispose();
    _hud.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final compact = MediaQuery.sizeOf(context).height < 650 || textScale >= 1.6;
    return ColoredBox(
      color: const Color(0xFF164B60),
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: CustomPaint(
              key: const Key('sailing-scene'),
              painter: StormSailingPainter(
                run: _run,
                time: () => _sceneTime,
                arrival: () => (_arrival / 1.25).clamp(0, 1),
                reducedMotion: MediaQuery.disableAnimationsOf(context),
                repaint: _frames,
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            top: MediaQuery.paddingOf(context).top + 12,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _GlassButton(
                  key: const Key('sailing-exit'),
                  label: 'Leave voyage',
                  icon: Icons.close_rounded,
                  onTap: widget.onExit,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ValueListenableBuilder<int>(
                    valueListenable: _hud,
                    builder: (_, _, _) => _distanceHud(),
                  ),
                ),
              ],
            ),
          ),
          if (!_run.started || _run.wrecked)
            Positioned(
              left: 22,
              right: 22,
              bottom: bottom + 24,
              child: _readyCard(compact),
            )
          else
            Positioned(
              left: 18,
              right: 18,
              bottom: bottom + 14,
              child: ValueListenableBuilder<int>(
                valueListenable: _hud,
                builder: (_, _, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_run.finished)
                      const _GlassLabel(
                        label: 'Safe harbour ahead!',
                        icon: Icons.anchor_rounded,
                      )
                    else if (_run.elapsed - _run.lastHitAt < 1.2)
                      const _GlassLabel(
                        label: 'A reef! Keep sailing.',
                        icon: Icons.water_rounded,
                      )
                    else if (_run.elapsed < 5)
                      _GlassLabel(
                        label: _useTilt && _sensorAvailable
                            ? 'Tilt gently left or right'
                            : 'Drag the wheel to steer',
                        icon: _useTilt && _sensorAvailable
                            ? Icons.screen_rotation_rounded
                            : Icons.touch_app_rounded,
                      ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Semantics(
                          button: true,
                          label: _useTilt
                              ? 'Switch to touch steering'
                              : 'Switch to tilt steering',
                          child: GestureDetector(
                            onTap: _sensorAvailable
                                ? () => setState(() {
                                    _useTilt = !_useTilt;
                                    _neutralTilt = _rawTilt;
                                    _tilt = 0;
                                  })
                                : null,
                            child: _GlassLabel(
                              label: _useTilt && _sensorAvailable
                                  ? 'Tilt'
                                  : 'Touch',
                              icon: _useTilt && _sensorAvailable
                                  ? Icons.screen_rotation_rounded
                                  : Icons.pan_tool_alt_rounded,
                            ),
                          ),
                        ),
                        _steeringWheel(compact),
                        _GlassButton(
                          label: 'Centre steering',
                          icon: Icons.my_location_rounded,
                          onTap: () {
                            _neutralTilt = _rawTilt;
                            _tilt = _touch = 0;
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _distanceHud() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
    decoration: _glass,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(
              Icons.anchor_rounded,
              color: Color(0xFFFFDA81),
              size: 17,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                _run.finished
                    ? 'You made it!'
                    : '${_run.remainingMetres} m to harbour',
                maxLines: 2,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 5),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < _run.course.maxHits; i++)
                  Padding(
                    padding: const EdgeInsets.only(left: 3),
                    child: Icon(
                      i < _run.hits
                          ? Icons.favorite_border_rounded
                          : Icons.favorite_rounded,
                      size: 14,
                      color: i < _run.hits
                          ? const Color(0xFF7DABB5)
                          : const Color(0xFFFFC2A6),
                    ),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 9),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: LinearProgressIndicator(
            key: const Key('sailing-distance-progress'),
            value: _run.progress,
            minHeight: 5,
            backgroundColor: const Color(0xFF386772),
            valueColor: const AlwaysStoppedAnimation(Color(0xFF75E4DC)),
          ),
        ),
      ],
    ),
  );

  Widget _readyCard(bool compact) => Container(
    decoration: _glass.copyWith(
      color: const Color(0xEE133D50),
      borderRadius: BorderRadius.circular(25),
    ),
    padding: EdgeInsets.all(compact ? 17 : 23),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _run.wrecked ? 'Let’s try calmer steering' : 'Sail through the storm',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: compact ? 21 : 25,
            fontWeight: FontWeight.w800,
            height: 1.12,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          _run.wrecked
              ? 'Steer around the rocks. Your next voyage starts with a fresh ship.'
              : 'One minute to safe harbour.\nTilt your phone or drag the wheel\nto glide around the rocks.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFFD2E7EA),
            fontSize: 14,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: Key(_run.wrecked ? 'sailing-retry' : 'sailing-start'),
            onPressed: _start,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFFD17B),
              foregroundColor: const Color(0xFF153E4C),
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            icon: const Icon(Icons.sailing_rounded),
            label: Text(
              _run.wrecked ? 'Try again' : 'Set sail',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _steeringWheel(bool compact) {
    final diameter = compact ? 78.0 : 96.0;
    return Semantics(
      label: 'Steering wheel. Drag left or right to steer.',
      child: GestureDetector(
        key: const Key('sailing-steering'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _run.active && !_paused
            ? (d) {
                _touching = true;
                _wheelOrigin = d.globalPosition.dx;
              }
            : null,
        onHorizontalDragUpdate: _run.active && !_paused
            ? (d) {
                _touch = ((d.globalPosition.dx - _wheelOrigin) / 75).clamp(
                  -1,
                  1,
                );
              }
            : null,
        onHorizontalDragEnd: (_) {
          _touching = false;
          _touch = 0;
        },
        onHorizontalDragCancel: () {
          _touching = false;
          _touch = 0;
        },
        child: SizedBox(
          width: diameter,
          height: diameter,
          child: CustomPaint(
            painter: _WheelPainter(
              () => (_touching || !_useTilt ? _touch : _tilt) * .65,
              repaint: _frames,
            ),
          ),
        ),
      ),
    );
  }
}

const _glass = BoxDecoration(
  color: Color(0xC5163D51),
  borderRadius: BorderRadius.all(Radius.circular(19)),
  border: Border.fromBorderSide(BorderSide(color: Color(0x337ECDD5))),
);

class _GlassButton extends StatelessWidget {
  const _GlassButton({
    required this.label,
    required this.icon,
    required this.onTap,
    super.key,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Container(
    decoration: _glass,
    child: IconButton(
      tooltip: label,
      onPressed: onTap,
      color: Colors.white,
      icon: Icon(icon),
      constraints: const BoxConstraints(minWidth: 46, minHeight: 46),
    ),
  );
}

class _GlassLabel extends StatelessWidget {
  const _GlassLabel({required this.label, required this.icon});
  final String label;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    decoration: _glass,
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: const Color(0xFFBEEAE9), size: 17),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

class _WheelPainter extends CustomPainter {
  _WheelPainter(this.angle, {super.repaint});
  final double Function() angle;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(angle());
    final radius = size.width * .32;
    canvas.drawCircle(
      Offset.zero,
      size.width * .48,
      Paint()..color = const Color(0x77103547),
    );
    canvas.drawCircle(
      Offset.zero,
      radius,
      Paint()
        ..color = const Color(0xFF51382C)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9,
    );
    canvas.drawCircle(
      Offset.zero,
      radius,
      Paint()
        ..color = const Color(0xFFD3A367)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5,
    );
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      final direction = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(
        direction * 8,
        direction * (radius + 8),
        Paint()
          ..color = const Color(0xFFE6BB7B)
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.drawCircle(Offset.zero, 9, Paint()..color = const Color(0xFFD5E7DB));
    canvas.drawCircle(Offset.zero, 4, Paint()..color = const Color(0xFF507879));
  }

  @override
  bool shouldRepaint(covariant _WheelPainter oldDelegate) => false;
}

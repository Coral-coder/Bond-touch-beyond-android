import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/touch_message.dart';
import 'theme.dart';

/// The touch bar, like the Bond Touch More's: the first touch opens a 5 s window, the finger's
/// position on the bar's 9 places is recorded as it moves, and the touch is sent when the
/// window ends (or on Send). A held finger feels like a steady buzz; moving ticks.
class TouchPad extends StatefulWidget {
  const TouchPad({
    super.key,
    required this.color,
    required this.onSend,
    this.window = 5,
  });
  final int color;
  final double window;
  final void Function(List<int> samples) onSend;

  @override
  State<TouchPad> createState() => _TouchPadState();
}

class _TouchPadState extends State<TouchPad> {
  final _events = <BarEvent>[];
  final _watch = Stopwatch();
  Timer? _timer;
  double? _pos; // 0…1 from the left
  int _last = -1;
  double _remaining = 0;

  bool get _recording => _watch.isRunning;

  void _touch(double? f) {
    setState(() => _pos = f);
    if (f != null && !_recording) _start();
    if (!_recording) return;
    final bar = f == null
        ? <int>[]
        : [(f * (TouchPattern.positions - 1)).round()];
    final key = bar.isEmpty ? -1 : bar.first;
    if (key == _last) return;
    _last = key;
    _events.add(BarEvent(_watch.elapsedMilliseconds / 1000, bar));
    if (bar.isNotEmpty) HapticFeedback.selectionClick();
  }

  void _start() {
    _events.clear();
    _last = -1;
    _watch
      ..reset()
      ..start();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final left = widget.window - _watch.elapsedMilliseconds / 1000;
      setState(() => _remaining = left.clamp(0, widget.window));
      if (left <= 0) _finish();
    });
  }

  void _finish() {
    if (!_recording) return;
    final duration = (_watch.elapsedMilliseconds / 1000).clamp(
      0.0,
      widget.window,
    );
    _watch.stop();
    _timer?.cancel();
    final samples = TouchPattern.trimmed(
      TouchPattern.samples(_events, duration),
    );
    setState(() {
      _remaining = 0;
      _pos = null;
    });
    if (samples.isNotEmpty) widget.onSend(samples);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.rgb(widget.color);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, box) {
            double frac(Offset o) => (o.dx / box.maxWidth).clamp(0.0, 1.0);
            return GestureDetector(
              onPanDown: (d) => _touch(frac(d.localPosition)),
              onPanUpdate: (d) => _touch(frac(d.localPosition)),
              onPanEnd: (_) => _touch(null),
              onPanCancel: () => _touch(null),
              child: Container(
                height: 84,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(42),
                  gradient: LinearGradient(
                    colors: [
                      c.withValues(alpha: 0.25),
                      c.withValues(alpha: 0.55),
                    ],
                  ),
                  border: Border.all(color: Colors.white24),
                ),
                child: Stack(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        for (var i = 0; i < TouchPattern.positions; i++)
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              color: Colors.white38,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                    if (_pos != null)
                      Positioned(
                        left: (_pos! * (box.maxWidth - 64)).clamp(
                          0,
                          box.maxWidth - 64,
                        ),
                        top: 10,
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            boxShadow: [BoxShadow(color: c, blurRadius: 24)],
                          ),
                        ),
                      ),
                    if (!_recording && _pos == null)
                      const Center(
                        child: Text(
                          'Touch and slide to send',
                          style: TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 36,
          child: _recording
              ? Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: 1 - _remaining / widget.window,
                        color: c,
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(onPressed: _finish, child: const Text('Send')),
                  ],
                )
              : null,
        ),
      ],
    );
  }
}
